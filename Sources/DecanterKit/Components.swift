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
        fm.fileExists(atPath: prefix.appending(path: "drive_c/windows/system32/d3d11.dll.wine-builtin").path)
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
