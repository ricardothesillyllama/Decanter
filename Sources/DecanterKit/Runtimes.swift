import Foundation

/// Finds Wine builds on the system and *pins* them: takes Decanter's own
/// APFS-cloned copy so that a Homebrew upgrade, a cask conflict, or a deleted
/// upstream repo can't pull the runtime out from under an installed game.
/// This is the specific failure that killed Whisky.
public struct RuntimeManager {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    public struct Candidate: Sendable {
        public var kind: RuntimeKind
        public var wineRoot: URL       // .../Contents/Resources/wine
        public var winePath: URL
        public var version: String
        public var supports32Bit: Bool
    }

    /// Known install locations, in preference order.
    /// Whether a Wine build could host DXMT, Direct3D 11 translated straight
    /// to Metal.
    ///
    /// DXMT attaches to Wine's macOS driver, and those symbols are hidden by
    /// default — a build compiled with `-fvisibility=hidden` and no patch
    /// exports nothing, so DXMT cannot load however it is installed. That is a
    /// property of the binary, so it can be measured rather than guessed at.
    ///
    /// Measured on this machine: Gcenx's Wine 11.0 exports 0 `macdrv_*`
    /// symbols; Apple's Game Porting Toolkit 7.7 exports several, including
    /// `macdrv_get_cocoa_view` and a `WineMetalView` class. DXMT's own
    /// documentation names FOSS CrossOver Wine 24+ as sufficient and says
    /// nothing about the Game Porting Toolkit, so a positive result here means
    /// "worth trying", not "supported".
    public struct MetalHosting: Sendable {
        public var driverPath: URL?
        public var exportedSymbols: [String] = []
        /// The view accessors DXMT needs to hand Metal a surface to draw into.
        /// Recorded for `doctor`; not the verdict — see `hasMetalViewAPI`.
        public var hasCocoaViewAccess = false
        public var hasMetalView = false

        /// Whether the driver exposes the way in to Wine's Metal view.
        ///
        /// DXMT's `winemetal.so` has no undefined `macdrv_*` symbols — checked
        /// with `nm -u`, there are none at all — so it resolves them with
        /// `dlsym` at the moment a drawable is first wanted. The names it
        /// carries are `macdrv_functions` and the three view calls
        /// (`macdrv_view_create_metal_view` and siblings). Either family being
        /// exported means the driver was built to expose this; ordinary builds
        /// hide all of it behind `-fvisibility=hidden`.
        ///
        /// `macdrv_functions` is the one that separates real builds in
        /// practice: the Game Porting Toolkit exports it, mainline Wine 11
        /// exports neither, and Gcenx's Sikarugir build of Wine 10 exports it —
        /// which is why that build is the one projects running DXMT use.
        public var hasMetalViewAPI = false

        /// Whether the Mac driver is a Mach-O *dylib* rather than a *bundle*.
        ///
        /// This is the condition that actually decides it, and it was found by
        /// trying: DXMT's `winemetal.so` carries a hard `LC_LOAD_DYLIB` on
        /// `@rpath/winemac.so`, and dyld refuses with "cannot link against
        /// bundle" when handed one. The Game Porting Toolkit builds its driver
        /// as MH_BUNDLE; CrossOver-derived builds ship an MH_DYLIB named
        /// `winemac.so`. No amount of renaming bridges that — the file type is
        /// part of the binary.
        public var driverIsLinkable = false

        /// Both halves are needed, and each was learned by being wrong about it.
        ///
        /// Linking is the first gate: DXMT's `winemetal.so` carries a hard
        /// `LC_LOAD_DYLIB` on `@rpath/winemac.so`, and dyld refuses a bundle
        /// outright. The Game Porting Toolkit's driver is MH_BUNDLE, so DXMT
        /// never loads there at all.
        ///
        /// Presenting is the second, and for a while this said linking was the
        /// whole test — because a real `dlopen` of mainline Wine 11 succeeded.
        /// It does succeed. Running a game then showed what that proves and
        /// what it does not: DXMT loaded, created a D3D11 device at feature
        /// level 11_1 on the real GPU, and only then said "Failed to create
        /// metal view, it seems like your Wine has no exported symbols needed
        /// by DXMT". The accessors are resolved when a drawable is first
        /// wanted, not at load, so nothing about linking predicts them.
        ///
        /// Measured on this machine: mainline Wine 11 is a dylib and exports
        /// nothing of either family; the Game Porting Toolkit exports
        /// `macdrv_functions` but is a bundle, so it fails the first gate. DXMT
        /// asks for "a FOSS CrossOver Wine 24+ built from the sources", and
        /// Gcenx's Sikarugir build of Wine 10 is a ready-made one — a dylib
        /// that exports `macdrv_functions`, which is what other projects
        /// running DXMT on Apple Silicon ship.
        public var looksCapable: Bool { driverIsLinkable && hasMetalViewAPI }

        /// Why this build cannot host DXMT, in the terms the person asking
        /// would use. `nil` when it can.
        public var unavailableReason: String? {
            if looksCapable { return nil }
            if driverPath == nil {
                return """
                This Wine build has no Unix-side Mac driver, so there is nothing for DXMT \
                to draw through. Mainline Wine builds its Mac driver as PE only.
                """
            }
            if !driverIsLinkable {
                return """
                This Wine build's Mac driver is a Mach-O bundle, and DXMT's Metal bridge links \
                against it as a dylib — macOS refuses that outright, with "cannot link against \
                bundle". A build that ships the driver as a dylib is needed instead.
                """
            }
            return """
            This Wine build's Mac driver does not export the three calls DXMT uses to get \
            something to draw into (macdrv_view_create_metal_view and its two siblings). It \
            would load, reach a Direct3D 11 device, and then fail at the first frame. Wine \
            has these calls; ordinary builds hide them. DXMT asks for a FOSS CrossOver \
            Wine 24+ built from source, which exposes them.
            """
        }
    }

    public func metalHosting(of runtime: RuntimeSpec) -> MetalHosting {
        Self.metalHosting(root: runtime.root)
    }

    /// Same test against a build that has not been pinned yet, so `pin` can
    /// record what it is taking on, and `use` can say so before copying 2 GB.
    /// Static because it reads a file and nothing else.
    public static func metalHosting(root: URL) -> MetalHosting {
        var out = MetalHosting()
        let fm = FileManager.default
        for name in ["winemac.drv.so", "winemac.so"] {
            let u = root.appending(path: "lib/wine/x86_64-unix/\(name)")
            if fm.fileExists(atPath: u.path) { out.driverPath = u; break }
        }
        guard let driver = out.driverPath,
              let data = try? Data(contentsOf: driver, options: .mappedIfSafe) else { return out }

        // The verdict comes from a byte scan of the symbol table, not from
        // `nm`: the developer tools are not installed on every Mac, and a
        // capability gate that answers "no" because a command is missing is
        // worse than no gate at all. Mach-O keeps symbol names in the string
        // table as plain ASCII, so the two agree — checked against both
        // runtimes Decanter pins.
        out.hasCocoaViewAccess = Self.contains(data, "_macdrv_get_client_cocoa_view")
                              || Self.contains(data, "_macdrv_get_cocoa_view")
        out.hasMetalView = Self.contains(data, "WineMetalView")
        // One of the three is enough to tell a build that exposes them from one
        // that does not: they are exported together or not at all.
        out.hasMetalViewAPI = Self.contains(data, "_macdrv_functions")
                           || Self.contains(data, "macdrv_functions")
                           || Self.contains(data, "_macdrv_view_create_metal_view")
                           || Self.contains(data, "macdrv_view_create_metal_view")
        out.driverIsLinkable = Self.machOFileType(data) == Self.MH_DYLIB

        // `nm -gU` lists external, defined symbols. Kept purely as detail for
        // `doctor` output, and absent without the developer tools — which is
        // exactly why the verdict above does not depend on it.
        if let r = try? Shell.run(URL(filePath: "/usr/bin/nm"), ["-gU", driver.path], timeout: 60) {
            out.exportedSymbols = r.out.split(separator: "\n").compactMap { line in
                guard let last = line.split(separator: " ").last else { return nil }
                let name = String(last)
                return name.contains("macdrv") || name.contains("WineMetalView") ? name : nil
            }
        }
        return out
    }

    static let MH_DYLIB: UInt32 = 6
    static let MH_BUNDLE: UInt32 = 8

    /// The Mach-O `filetype` field, or nil if this is not a thin Mach-O.
    ///
    /// Only thin images are read: Wine's Unix libraries are single-architecture
    /// by construction, and guessing which slice of a fat file matters would be
    /// inventing an answer.
    static func machOFileType(_ data: Data) -> UInt32? {
        guard data.count >= 16 else { return nil }
        func u32(_ off: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                var v: UInt32 = 0
                withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[off..<off+4])) }
                return v
            }
        }
        let magic = u32(0)
        // 64- and 32-bit, little-endian only: every Mac Decanter runs on is LE.
        guard magic == 0xFEED_FACF || magic == 0xFEED_FACE else { return nil }
        return u32(12)
    }

    /// Whole-file byte search. Explicit rather than `Data.range(of:)` so it is
    /// obvious the entire file is scanned — a partial scan is how this project
    /// has been wrong before.
    static func contains(_ haystack: Data, _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard !n.isEmpty, haystack.count >= n.count else { return false }
        return haystack.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let last = raw.count - n.count
            var i = 0
            while i <= last {
                if base[i] == n[0] {
                    var k = 1
                    while k < n.count, base[i + k] == n[k] { k += 1 }
                    if k == n.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    public func discover() -> [Candidate] {
        var found: [Candidate] = []
        let wineApps = [
            ("/Applications/Wine Stable.app/Contents/Resources/wine", RuntimeKind.wine),
            ("/Applications/Wine Devel.app/Contents/Resources/wine", .wine),
            ("/Applications/Wine Staging.app/Contents/Resources/wine", .wine),
            ("/Applications/Game Porting Toolkit.app/Contents/Resources/wine", .gptk),
        ]
        for (path, kind) in wineApps {
            let root = URL(filePath: path)
            guard fm.fileExists(atPath: root.path) else { continue }
            let bin = root.appending(path: "bin/wine")
            let bin64 = root.appending(path: "bin/wine64")
            let exe = fm.isExecutableFile(atPath: bin.path) ? bin
                    : (fm.isExecutableFile(atPath: bin64.path) ? bin64 : nil)
            guard let exe else { continue }
            let ver = (try? Shell.run(exe, ["--version"], timeout: 20).out
                        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
            // 32-bit support means a 32-bit PE module dir exists in the build.
            let has32 = fm.fileExists(atPath: root.appending(path: "lib/wine/i386-windows").path)
                     || fm.fileExists(atPath: root.appending(path: "lib/wine/i386-unix").path)
                     || fm.fileExists(atPath: root.appending(path: "lib/wine/x86_32on64-unix").path)
            found.append(.init(kind: kind, wineRoot: root, winePath: exe,
                               version: ver.replacingOccurrences(of: "wine-", with: ""),
                               supports32Bit: has32))
        }
        return found
    }

    /// Builds a Candidate from an arbitrary Wine root (e.g. an extracted
    /// Game Porting Toolkit.app/Contents/Resources/wine), so a runtime can be
    /// pinned without installing it into /Applications first.
    public func inspect(wineRoot: URL, kindHint: RuntimeKind? = nil) throws -> Candidate {
        let bin = wineRoot.appending(path: "bin/wine")
        let bin64 = wineRoot.appending(path: "bin/wine64")
        let exe = fm.isExecutableFile(atPath: bin.path) ? bin
                : (fm.isExecutableFile(atPath: bin64.path) ? bin64 : nil)
        guard let exe else { throw DecanterError.notFound("no wine binary under \(wineRoot.path)") }
        let isGPTK = fm.fileExists(atPath: wineRoot.appending(path: "lib/external/D3DMetal.framework").path)
        let ver = (try? Shell.run(exe, ["--version"], timeout: 30).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        let has32 = fm.fileExists(atPath: wineRoot.appending(path: "lib/wine/i386-windows").path)
                 || fm.fileExists(atPath: wineRoot.appending(path: "lib/wine/x86_32on64-unix").path)
        return .init(kind: kindHint ?? (isGPTK ? .gptk : .wine),
                     wineRoot: wineRoot, winePath: exe,
                     version: ver.replacingOccurrences(of: "wine-", with: ""),
                     supports32Bit: has32)
    }

    /// Copies a discovered build into Decanter's runtimes dir via APFS clone,
    /// then records it. Cheap on APFS; independent of the source afterwards.
    /// `wine --version` can return "wine-7.7 (Game Porting Toolkit 1.1)".
    /// Only the leading version token is safe to put in a directory name.
    static func sanitize(version: String) -> String {
        let token = version.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? version
        return token.filter { $0.isNumber || $0 == "." || $0.isLetter || $0 == "-" }
    }

    @discardableResult
    public func pin(_ c: Candidate, store: Store) throws -> RuntimeSpec {
        let id = "\(c.kind.rawValue)-\(Self.sanitize(version: c.version))"
        let dest = paths.runtimes.appending(path: id)
        if !fm.fileExists(atPath: dest.path) {
            try fm.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
            let r = try Shell.run(URL(filePath: "/bin/cp"),
                                  ["-Rc", c.wineRoot.path, dest.path], timeout: 600)
            if r.code != 0 {
                // -c (clonefile) fails across filesystems; fall back to a real copy.
                let r2 = try Shell.run(URL(filePath: "/bin/cp"),
                                       ["-R", c.wineRoot.path, dest.path], timeout: 900)
                guard r2.code == 0 else { throw DecanterError.cloneFailed(r2.err) }
            }
        }
        let rel = c.winePath.path.replacingOccurrences(of: c.wineRoot.path + "/", with: "")
        let spec = RuntimeSpec(id: id, kind: c.kind, version: Self.sanitize(version: c.version), root: dest,
                               winePath: dest.appending(path: rel),
                               wineserverPath: dest.appending(path: "bin/wineserver"),
                               supports32Bit: c.supports32Bit,
                               backends: Self.backends(for: c.kind, root: dest))
        try store.mutate { s in
            s.runtimes.removeAll { $0.id == id }
            s.runtimes.append(spec)
        }
        return spec
    }

    /// What this build can actually offer, decided by inspecting it.
    ///
    /// D3DMetal ships inside the Game Porting Toolkit, so that one is a
    /// property of the kind. DXMT is not: it needs a Mac driver that exposes a
    /// Cocoa view to Unix libraries, which some builds have and some do not,
    /// so it is tested for rather than inferred from a version number.
    /// Whether this build can reach Vulkan at all.
    ///
    /// DXVK talks to Vulkan, and on macOS the only Vulkan is MoltenVK, which
    /// Wine builds ship inside themselves. `winevulkan.so` being present is not
    /// enough — it is the Wine side of the bridge and exists either way.
    ///
    /// Measured: the Game Porting Toolkit and mainline Wine 11 both ship
    /// `libMoltenVK.dylib` and run DXVK; Gcenx's Sikarugir build of Wine 10
    /// ships `winevulkan.so` and no MoltenVK, and DXVK on it fails with
    /// "Required Vulkan extension VK_KHR_surface not supported". Offering DXVK
    /// there is the same mistake as offering DXMT on a Wine that cannot present
    /// — a backend the runtime cannot deliver.
    public static func hasVulkan(root: URL) -> Bool {
        let fm = FileManager.default
        for p in ["lib/libMoltenVK.dylib", "lib/wine/x86_64-unix/libMoltenVK.dylib"] {
            if fm.fileExists(atPath: root.appending(path: p).path) { return true }
        }
        // Some builds tuck it into a Frameworks directory rather than lib/.
        guard let walk = fm.enumerator(at: root.appending(path: "lib"),
                                       includingPropertiesForKeys: nil) else { return false }
        for case let u as URL in walk where u.lastPathComponent.hasPrefix("libMoltenVK") { return true }
        return false
    }

    public static func backends(for kind: RuntimeKind, root: URL) -> [GraphicsBackend] {
        var out: [GraphicsBackend] = kind == .gptk ? [.d3dmetal, .wined3d] : [.wined3d]
        if hasVulkan(root: root) { out.insert(.dxvk, at: out.count - 1) }
        if metalHosting(root: root).looksCapable { out.append(.dxmt) }
        return out
    }

    /// Picks the best pinned runtime for a detection result, honouring the
    /// 32-bit constraint above all else — a game that can't start is worse
    /// than a game that renders a little slower.
    public func choose(for d: DetectionResult, store: Store) -> RuntimeSpec? {
        let all = store.state.runtimes
        guard !all.isEmpty else { return nil }
        let needs32 = d.bitness == .x86
        let preferred = all.filter { $0.kind == d.recommendedRuntimeKind }
        let pool = (needs32 ? preferred.filter(\.supports32Bit) : preferred)
        if let r = pool.sorted(by: { $0.version > $1.version }).first { return r }
        let fallback = needs32 ? all.filter(\.supports32Bit) : all
        return fallback.sorted(by: { $0.version > $1.version }).first
    }
}
