import Foundation

/// Graphics components that get baked into the golden template so every
/// cloned prefix inherits them. Staged copies live under Decanter's root, so
/// an upstream release disappearing cannot break existing games.
public struct DXVKInstaller {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    public var stagedRoot: URL { paths.runtimes.appending(path: "dxvk") }

    /// Every staged version, newest-looking first. Games differ in which one
    /// they tolerate: 2.x and 3.x need Vulkan 1.3 features MoltenVK does not
    /// fully implement, while 1.10.3 targets Vulkan 1.1 and is far more
    /// forgiving here. Keeping several lets a game pick what works.
    public func stagedVersions() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: stagedRoot.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") &&
                      fm.fileExists(atPath: stagedRoot.appending(path: "\($0)/x64/d3d11.dll").path) }
            .sorted { compareVersions($0, $1) }
    }

    /// Newest first, comparing numerically so 10 sorts above 9.
    func compareVersions(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return a > b
    }

    public func versionRoot(_ version: String) -> URL { stagedRoot.appending(path: version) }

    public var isStaged: Bool { !stagedVersions().isEmpty }

    /// The version used when a game does not name one.
    public var defaultVersion: String? { defaultVersionOverride ?? stagedVersions().first }

    public var stagedVersion: String? { defaultVersion }

    /// Unpacks a dxvk-*.tar.gz into Decanter's own store.
    /// Version used for new templates. Defaults to the newest staged, but on
    /// this platform newest is often wrong: MoltenVK cannot satisfy DXVK 2.x/3.x.
    public var preferredVersionFile: URL { stagedRoot.appending(path: "PREFERRED") }

    public var defaultVersionOverride: String? {
        guard let v = try? String(contentsOf: preferredVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return stagedVersions().contains(v) ? v : nil
    }

    public func setPreferred(_ version: String) throws {
        guard stagedVersions().contains(version) else {
            throw DecanterError.notFound("DXVK \(version) is not staged")
        }
        try version.write(to: preferredVersionFile, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public func stage(tarball: URL, progress: (String) -> Void = { _ in }) throws -> String {
        let tmp = paths.root.appending(path: "tmp-dxvk")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        if let size = DiskSpace.sizeOfFile(at: tarball) {
            try DiskSpace.require(DiskSpace.unpackEstimate(forArchiveOf: size), at: paths.root,
                                  toDo: "Unpacking \(tarball.lastPathComponent)")
        }
        progress("unpacking \(tarball.lastPathComponent)")
        let r = try Shell.run(URL(filePath: "/usr/bin/tar"), ["xzf", tarball.path, "-C", tmp.path], timeout: 300)
        guard r.code == 0 else { throw DecanterError.cloneFailed("tar: \(r.err)") }

        guard let top = (try? fm.contentsOfDirectory(atPath: tmp.path))?
                .first(where: { $0.hasPrefix("dxvk") }) else {
            throw DecanterError.notFound("dxvk directory inside archive")
        }
        let version = top.replacingOccurrences(of: "dxvk-", with: "")
        let dest = versionRoot(version)
        try fm.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp.appending(path: top), to: dest)
        try? fm.removeItem(at: tmp)
        progress("staged DXVK \(version)")
        return version
    }

    /// Folds a pre-versioning layout (dxvk/x64) into dxvk/<version>/x64.
    public func migrateLegacyLayout() throws {
        let legacyX64 = stagedRoot.appending(path: "x64")
        guard fm.fileExists(atPath: legacyX64.path) else { return }
        let v = (try? String(contentsOf: stagedRoot.appending(path: "VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let dest = versionRoot(v)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in ["x32", "x64"] {
            let src = stagedRoot.appending(path: item)
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dest.appending(path: item)) }
        }
        try? fm.removeItem(at: stagedRoot.appending(path: "VERSION"))
    }

    /// Copies DXVK's DLLs over Wine's builtin ones inside a prefix.
    /// 64-bit DLLs go to system32, 32-bit to syswow64 — that is Wine's WoW64
    /// layout, and getting it backwards silently breaks every 32-bit game.
    @discardableResult
    public func install(into prefix: URL, runtime: RuntimeSpec, version: String? = nil,
                        progress: (String) -> Void = { _ in }) throws -> [String] {
        guard let v = version ?? defaultVersion else {
            throw DecanterError.notFound("DXVK not staged — run `decanter dxvk stage <tarball>`")
        }
        guard fm.fileExists(atPath: versionRoot(v).path) else {
            throw DecanterError.notFound("DXVK \(v) is not staged")
        }
        progress("installing DXVK \(v)")
        var installed: [String] = []
        let map = [("x64", "drive_c/windows/system32"), ("x32", "drive_c/windows/syswow64")]
        for (arch, dest) in map {
            let src = versionRoot(v).appending(path: arch)
            let dst = prefix.appending(path: dest)
            guard fm.fileExists(atPath: src.path), fm.fileExists(atPath: dst.path) else { continue }
            for dll in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where dll.hasSuffix(".dll") {
                let s = src.appending(path: dll), d = dst.appending(path: dll)
                if fm.fileExists(atPath: d.path) {
                    // Keep Wine's original once, so a rollback is possible.
                    let backup = dst.appending(path: dll + ".wine-builtin")
                    if !fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: d, to: backup) }
                    else { try? fm.removeItem(at: d) }
                }
                try fm.copyItem(at: s, to: d)
                installed.append("\(arch)/\(dll)")
            }
        }
        // Write the overrides straight into user.reg. Shelling out to
        // `wine reg add` started a wineserver and flashed Wine's desktop
        // windows on screen just for a settings change.
        progress("registering DLL overrides")
        var overrides: [String: String] = [:]
        for dll in ["d3d9", "d3d10core", "d3d11", "dxgi"] { overrides[dll] = "native,builtin" }
        try? PrefixRegistry().setDllOverrides(overrides, in: prefix)
        markInstalled(v, in: prefix)
        progress("installed \(installed.count) DXVK DLLs (version \(v))")
        return installed
    }

    /// True if a prefix actually has DXVK in it — used so the UI never claims
    /// a backend the prefix cannot deliver.
    public func isInstalled(in prefix: URL) -> Bool {
        // The `.wine-builtin` backup alone is not proof of DXVK: DXMT replaces
        // the same DLLs and leaves the same backup behind. Without this second
        // test a DXMT prefix reported itself as DXVK, in the UI and in reports.
        guard !fm.fileExists(atPath: prefix.appending(path: ".decanter-dxmt").path) else { return false }
        return fm.fileExists(atPath: prefix.appending(path: "drive_c/windows/system32/d3d11.dll.wine-builtin").path)
    }

    /// Records which DXVK version a prefix currently carries, so the UI and
    /// reports can state it rather than guess.
    public func markInstalled(_ version: String, in prefix: URL) {
        try? version.write(to: prefix.appending(path: ".decanter-dxvk"),
                           atomically: true, encoding: .utf8)
    }

    public func installedVersion(in prefix: URL) -> String? {
        if let v = try? String(contentsOf: prefix.appending(path: ".decanter-dxvk"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        return identifyByContent(in: prefix)
    }

    /// Names the DXVK build in a prefix that carries no version marker.
    ///
    /// Prefixes cloned from a template built before markers existed report no
    /// version, which surfaced as a bare "DXVK ?" in every problem report — the
    /// one line you most want to be exact when asking why rendering is broken.
    /// Every staged build is on disk, so a byte-for-byte match names it with
    /// certainty rather than guessing from a version resource.
    func identifyByContent(in prefix: URL) -> String? {
        let installed = prefix.appending(path: "drive_c/windows/system32/d3d11.dll")
        guard let data = try? Data(contentsOf: installed) else { return nil }
        for v in stagedVersions() {
            let candidate = versionRoot(v).appending(path: "x64/d3d11.dll")
            guard let c = try? Data(contentsOf: candidate), c.count == data.count else { continue }
            if c == data { return v }
        }
        return nil
    }
}

/// DXMT: Direct3D 11 translated straight to Metal, without Vulkan in between.
/// Decanter stages a build the user supplies, exactly as it does for DXVK —
/// nothing is fetched.
///
/// DXMT is *not* installed the way DXVK is, and the difference was found by
/// measuring a real release rather than by reading its README:
///
///  * Its releases ship Wine's own directory layout (`x86_64-windows`,
///    `i386-windows`, `x86_64-unix`), not DXVK's `x64`/`x32`. The DLLs are
///    built to be loaded as Wine *builtins*, so they go on WINEDLLPATH and are
///    selected with `=b` overrides. Nothing is copied into a prefix, which
///    means DXMT and DXVK can no longer collide over the same files.
///
///  * Its Unix half, `winemetal.so`, carries a hard `LC_LOAD_DYLIB` on
///    `@rpath/winemac.so` and an `LC_RPATH` of `@loader_path/`. So it will only
///    load from a directory that also contains a file named exactly
///    `winemac.so` — and Wine names that file `winemac.drv.so`. Decanter builds
///    a small per-runtime directory of links to satisfy that, rather than
///    modifying the pinned runtime.
public struct DXMTInstaller {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    public var stagedRoot: URL { paths.runtimes.appending(path: "dxmt") }
    public func versionRoot(_ version: String) -> URL { stagedRoot.appending(path: version) }

    /// A staged build is one whose 64-bit PE payload is present.
    public func stagedVersions() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: stagedRoot.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") &&
                      fm.fileExists(atPath: stagedRoot.appending(path: "\($0)/x86_64-windows/d3d11.dll").path) }
            .sorted { DXVKInstaller(paths: paths).compareVersions($0, $1) }
    }

    public var isStaged: Bool { !stagedVersions().isEmpty }
    public var defaultVersion: String? { stagedVersions().first }

    /// Wine's directory names, mapped from whatever the archive called them.
    /// Getting 32- and 64-bit the wrong way round silently breaks every
    /// 32-bit game, which is why this is a table and not a guess.
    static func wineArchDirectory(_ name: String) -> String? {
        switch name.lowercased() {
        case "x86_64-windows", "x64", "x86_64": "x86_64-windows"
        case "i386-windows", "x32", "x86", "win32", "i386": "i386-windows"
        case "x86_64-unix", "unix": "x86_64-unix"
        default: nil
        }
    }

    @discardableResult
    public func stage(archive: URL, progress: (String) -> Void = { _ in }) throws -> String {
        let tmp = paths.root.appending(path: "tmp-dxmt")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        if let size = DiskSpace.sizeOfFile(at: archive) {
            try DiskSpace.require(DiskSpace.unpackEstimate(forArchiveOf: size), at: paths.root,
                                  toDo: "Unpacking \(archive.lastPathComponent)")
        }
        progress("unpacking \(archive.lastPathComponent)")
        let name = archive.lastPathComponent.lowercased()
        let r: (code: Int32, out: String, err: String)
        if name.hasSuffix(".zip") {
            r = try Shell.run(URL(filePath: "/usr/bin/unzip"), ["-q", archive.path, "-d", tmp.path], timeout: 300)
        } else {
            r = try Shell.run(URL(filePath: "/usr/bin/tar"), ["xf", archive.path, "-C", tmp.path], timeout: 300)
        }
        guard r.code == 0 else { throw DecanterError.cloneFailed("unpack: \(r.err)") }

        // Find the payload rather than assume its depth: the v0.80 archive puts
        // everything under a `v0.80/` directory, and that is not a contract.
        var found: [String: URL] = [:]   // wine arch dir -> source directory
        if let walk = fm.enumerator(at: tmp, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let u as URL in walk {
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let arch = Self.wineArchDirectory(u.lastPathComponent) else { continue }
                if found[arch] == nil { found[arch] = u }
            }
        }
        guard let pe64 = found["x86_64-windows"],
              fm.fileExists(atPath: pe64.appending(path: "d3d11.dll").path) else {
            throw DecanterError.notFound(
                "no x86_64-windows/d3d11.dll inside \(archive.lastPathComponent) — that does not look like a DXMT build")
        }

        let version = Self.version(fromArchive: archive.lastPathComponent, payload: pe64)
        let dest = versionRoot(version)
        try fm.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for (arch, src) in found {
            try? fm.copyItem(at: src, to: dest.appending(path: arch))
        }
        let unix = found["x86_64-unix"] != nil
        progress("staged DXMT \(version)" + (unix ? "" : " (no Metal bridge in this archive — it will not load)"))
        return version
    }

    /// Version from the archive name. The directory inside the archive is
    /// named for the version too, but only the file name is guaranteed to
    /// reach us intact.
    public static func version(fromArchive name: String, payload: URL) -> String {
        var scalars = name
        for suffix in [".tar.gz", ".tar.zst", ".tgz", ".zip"] {
            if scalars.lowercased().hasSuffix(suffix) { scalars = String(scalars.dropLast(suffix.count)); break }
        }
        for part in scalars.split(separator: "-").map(String.init) {
            let t = part.hasPrefix("v") ? String(part.dropFirst()) : part
            if let f = t.first, f.isNumber, t.contains(".") { return t }
        }
        return "unknown"
    }

    // MARK: The bridge directory

    /// The suffix marking a runtime that carries DXMT.
    public static let hostSuffix = "-dxmt"

    /// A clone of `runtime` with DXMT baked in, created on first use.
    ///
    /// DXMT has to be installed as Wine *builtins*, in the runtime's own dll
    /// directory — three attempts established that, each ruled out by running
    /// it rather than by reading:
    ///
    ///  * On WINEDLLPATH with `=b`: the game ran on Wine's own `wined3d` while
    ///    reporting DXMT. WINEDLLPATH does not move where Wine finds builtins.
    ///  * Copied into the prefix as native `=n`, the way DXVK is installed:
    ///    `Library d3d11.dll not found`. Wine only associates a unixlib —
    ///    DXMT's `winemetal.so` — with a module loaded as a builtin from its
    ///    own dll directory, so a native copy has no Metal bridge and its whole
    ///    import chain fails.
    ///  * As builtins in the runtime's dll directory: loads, and Unity 6 runs.
    ///
    /// That last one is global to the runtime, and `=b` is also what WineD3D
    /// games use — so baking DXMT into a shared runtime would silently switch
    /// them onto it. Hence a clone. On APFS this is a clonefile: near-zero
    /// bytes and about a second, the same trick `pin` already relies on.
    public func hostRuntime(basedOn runtime: RuntimeSpec, version: String, store: Store,
                            progress: (String) -> Void = { _ in }) throws -> RuntimeSpec {
        // Being *named* a DXMT runtime is not the same as being one. A spec can
        // outlive its directory, and returning it unchecked hands back a
        // runtime whose `bin/wine` does not exist — which is exactly what
        // happened the first time this ran.
        let base = runtime.id.hasSuffix(Self.hostSuffix)
            ? (store.state.runtimes.first { $0.id == String(runtime.id.dropLast(Self.hostSuffix.count)) } ?? runtime)
            : runtime
        // Cloning is not the hard part; hosting is. DXMT resolves the Mac
        // driver's Metal entry points by dlsym at the first frame, so a build
        // whose winemac driver is a bundle, or exports nothing, can carry every
        // DXMT DLL and still never draw. Copying such a runtime produced an
        // 800 MB clone that `check` immediately reported as unable to host
        // DXMT — work done to reach a dead end. Refuse before copying.
        let hosting = RuntimeManager.metalHosting(root: base.root)
        guard hosting.looksCapable else {
            throw DecanterError.noRuntime(
                "\(base.id) cannot host DXMT — \(hosting.unavailableReason?.replacingOccurrences(of: "\n", with: " ") ?? "its Mac driver does not expose the Metal view API"). This needs a Wine build whose Mac driver is a dylib exporting macdrv_functions; Sikarugir's is one.")
        }

        let id = base.id.hasSuffix(Self.hostSuffix) ? base.id : base.id + Self.hostSuffix
        let dest = paths.runtimes.appending(path: id)
        let runtime = base

        if let existing = store.state.runtimes.first(where: { $0.id == id }),
           fm.fileExists(atPath: WineLayout.hostPath(under: dest, "winemetal.so").path) {
            return existing
        }

        if !fm.fileExists(atPath: dest.path) {
            progress("making a copy of \(runtime.id) to carry DXMT")
            let r = try Shell.run(URL(filePath: "/bin/cp"), ["-Rc", runtime.root.path, dest.path], timeout: 600)
            if r.code != 0 {
                let r2 = try Shell.run(URL(filePath: "/bin/cp"), ["-R", runtime.root.path, dest.path], timeout: 900)
                guard r2.code == 0 else { throw DecanterError.cloneFailed(r2.err) }
            }
        }

        progress("installing DXMT \(version) as builtins")
        let src = versionRoot(version)
        for (arch, dir) in [("x86_64-windows", "lib/wine/x86_64-windows"),
                            ("i386-windows", "lib/wine/i386-windows")] {
            let from = src.appending(path: arch)
            let into = dest.appending(path: dir)
            guard fm.fileExists(atPath: from.path), fm.fileExists(atPath: into.path) else { continue }
            for dll in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where dll.hasSuffix(".dll") {
                let d = into.appending(path: dll)
                try? fm.removeItem(at: d)
                try fm.copyItem(at: from.appending(path: dll), to: d)
            }
        }
        // The Metal bridge goes beside winemac.so and ntdll.so, which is where
        // its own load commands look: its rpath is @loader_path/ and it hard
        // links both by name.
        let bridge = src.appending(path: "x86_64-unix/winemetal.so")
        guard fm.fileExists(atPath: bridge.path) else {
            throw DecanterError.notFound("DXMT \(version) has no x86_64-unix/winemetal.so — its Metal bridge is missing")
        }
        let bridgeDest = WineLayout.hostPath(under: dest, "winemetal.so")
        try? fm.removeItem(at: bridgeDest)
        try fm.copyItem(at: bridge, to: bridgeDest)

        // The clone needs a golden template, and the base runtime's is already
        // correct for it: same Wine, same prefix layout — only the Direct3D
        // builtins differ, and those live in the runtime, not the prefix.
        // Rebuilding one from scratch would take minutes and produce the same
        // thing; cloning it is a clonefile.
        let baseTemplate = paths.template(for: runtime.id)
        let ownTemplate = paths.template(for: id)
        if fm.fileExists(atPath: baseTemplate.path), !fm.fileExists(atPath: ownTemplate.path) {
            progress("copying \(runtime.id)'s Windows environment across")
            try fm.createDirectory(at: paths.templateRoot, withIntermediateDirectories: true)
            let r = try Shell.run(URL(filePath: "/bin/cp"),
                                  ["-Rc", baseTemplate.path, ownTemplate.path], timeout: 600)
            if r.code != 0 {
                _ = try? Shell.run(URL(filePath: "/bin/cp"),
                                   ["-R", baseTemplate.path, ownTemplate.path], timeout: 900)
            }
            try? store.mutate { $0.templates[id] = Date() }
        }

        // Wine resolves a builtin by *name* through a file of that name in the
        // prefix's system32 — wineboot creates one for every DLL Wine knows
        // about. `winemetal.dll` is not a Wine DLL, so no such file exists and
        // the name never resolves: "Library winemetal.dll ... not found", even
        // with the real builtin sitting in the runtime's dll directory. Putting
        // a copy in the template gives the name somewhere to land; `=b` still
        // makes Wine load the builtin, which is the one with the Metal bridge
        // bound to it.
        for arch in ["x86_64-windows": "system32", "i386-windows": "syswow64"] {
            let from = src.appending(path: "\(arch.key)/winemetal.dll")
            let into = ownTemplate.appending(path: "drive_c/windows/\(arch.value)")
            guard fm.fileExists(atPath: from.path), fm.fileExists(atPath: into.path) else { continue }
            let d = into.appending(path: "winemetal.dll")
            try? fm.removeItem(at: d)
            try? fm.copyItem(at: from, to: d)
        }

        let rel = runtime.winePath.path.replacingOccurrences(of: runtime.root.path + "/", with: "")
        let spec = RuntimeSpec(id: id, kind: runtime.kind, version: runtime.version, root: dest,
                               winePath: dest.appending(path: rel),
                               wineserverPath: dest.appending(path: "bin/wineserver"),
                               supports32Bit: runtime.supports32Bit,
                               backends: [.dxmt])
        try store.mutate { s in
            s.runtimes.removeAll { $0.id == id }
            s.runtimes.append(spec)
        }
        progress("DXMT \(version) ready on \(id)")
        return spec
    }

    /// Records which version a bottle is running, so reports state it rather
    /// than infer it. DXMT puts nothing in a prefix, so this is the only record.
    public func mark(_ version: String, in prefix: URL) {
        try? version.write(to: prefix.appending(path: ".decanter-dxmt"), atomically: true, encoding: .utf8)
    }

    public func isInstalled(in prefix: URL) -> Bool {
        fm.fileExists(atPath: prefix.appending(path: ".decanter-dxmt").path)
    }

    public func installedVersion(in prefix: URL) -> String? {
        try? String(contentsOf: prefix.appending(path: ".decanter-dxmt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func clearMarker(in prefix: URL) {
        try? fm.removeItem(at: prefix.appending(path: ".decanter-dxmt"))
    }

    /// Wine's Unix-side Mac driver, under whichever of its names this build uses.
    public static func wineMacDriver(in runtime: RuntimeSpec) -> URL? {
        let fm = FileManager.default
        for name in ["winemac.so", "winemac.drv.so"] {
            let u = WineLayout.hostPath(under: runtime.root, name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

}
