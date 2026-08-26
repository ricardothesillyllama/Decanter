import Foundation

/// Reads a Windows PE executable well enough to answer the two questions that
/// actually decide whether a game runs: how wide is it, and which Direct3D
/// does it ask for.
public struct PEReader {
    public struct Info: Sendable {
        public var bitness: Bitness
        public var importedDLLs: [String]
    }

    public static func read(_ url: URL) -> Info? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let mz = try? fh.read(upToCount: 2), mz == Data([0x4D, 0x5A]) else { return nil }
        try? fh.seek(toOffset: 0x3c)
        guard let lfaData = try? fh.read(upToCount: 4), lfaData.count == 4 else { return nil }
        let peOff = lfaData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        try? fh.seek(toOffset: UInt64(peOff))
        guard let sig = try? fh.read(upToCount: 4), sig == Data([0x50, 0x45, 0, 0]) else { return nil }
        guard let machData = try? fh.read(upToCount: 2), machData.count == 2 else { return nil }
        let machine = machData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let bits: Bitness = switch machine {
            case 0x014c: .x86
            case 0x8664: .x64
            default: .unknown
        }
        // Rather than walking the import directory (which needs full section
        // mapping), scan for known DLL name strings. This must stay cheap:
        // Unity's GameAssembly.dll is routinely 200MB+, and a naive
        // lowercase-the-whole-file-then-search-per-needle approach took 33s
        // on a 220MB binary. One pass, no copies, bounded window.
        let dlls = Self.scanForDLLNames(url)
        return Info(bitness: bits, importedDLLs: dlls)
    }

    static let probeNames = ["d3d9.dll", "d3d10.dll", "d3d11.dll", "d3d12.dll",
                             "dxgi.dll", "vulkan-1.dll", "opengl32.dll", "ddraw.dll",
                             "xaudio2_7.dll", "mscoree.dll"]

    /// Upper bound on how much of a binary we will scan. Import tables live
    /// near the start; beyond this it is asset payload, not names.
    static let scanLimit = 96 * 1024 * 1024

    /// One pass over the mapped bytes, matching every needle simultaneously
    /// and comparing case-insensitively without materialising a copy.
    static func scanForDLLNames(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let needles: [[UInt8]] = probeNames.map { Array($0.utf8) }
        // Flat 256-entry table, not a Dictionary: this is inspected once per
        // byte of a possibly 96MB window, and a hashed lookup there dominates.
        var byFirst = [[Int]](repeating: [], count: 256)
        var isStart = [Bool](repeating: false, count: 256)
        for (i, n) in needles.enumerated() {
            byFirst[Int(n[0])].append(i)
            isStart[Int(n[0])] = true
        }
        var hit = [Bool](repeating: false, count: needles.count)
        var remaining = needles.count

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = min(raw.count, scanLimit)
            var i = 0
            while i < count && remaining > 0 {
                // ASCII lowercase, branch-free enough for a hot loop.
                let c = base[i]
                let lower = (c >= 65 && c <= 90) ? c + 32 : c
                if isStart[Int(lower)] {
                    for idx in byFirst[Int(lower)] where !hit[idx] {
                        let n = needles[idx]
                        if i + n.count <= count {
                            var j = 1
                            while j < n.count {
                                let b = base[i + j]
                                let bl = (b >= 65 && b <= 90) ? b + 32 : b
                                if bl != n[j] { break }
                                j += 1
                            }
                            if j == n.count { hit[idx] = true; remaining -= 1 }
                        }
                    }
                }
                i += 1
            }
        }
        return needles.indices.filter { hit[$0] }.map { probeNames[$0] }
    }
}

/// Identifies the game engine from file layout, then maps that to a runtime,
/// a graphics backend, and a dependency recipe list.
public struct Detector {
    let fm = FileManager.default
    public init() {}

    public func detect(exe: URL) -> DetectionResult {
        var r = DetectionResult()
        let dir = exe.deletingLastPathComponent()
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let lower = Set(names.map { $0.lowercased() })
        func has(_ n: String) -> Bool { lower.contains(n.lowercased()) }
        func hasSuffix(_ s: String) -> Bool { lower.contains { $0.hasSuffix(s) } }

        var apis = Set<String>()
        if let pe = PEReader.read(exe) {
            r.bitness = pe.bitness
            apis.formUnion(pe.importedDLLs.filter { $0.hasPrefix("d3d") || $0 == "dxgi.dll" || $0 == "ddraw.dll" })
            r.signals.append(.init("PE machine field -> \(pe.bitness.label)", path: exe.lastPathComponent, weight: 0.35))
        }
        // The launcher .exe is often a thin stub — Unity, nw.js and Godot all
        // keep the real Direct3D imports in a sibling runtime DLL. Look there
        // too, or every Unity game looks like it needs no graphics at all.
        let siblingProbes = ["UnityPlayer.dll", "nw.dll", "libGLESv2.dll", "GameAssembly.dll"]
        // Unreal's launcher is a thin shim too: the Direct3D imports live in
        // <Game>/Binaries/Win64/<Game>-Win64-Shipping.exe. Without this an
        // Unreal game looks like it needs no graphics at all.
        var extraProbes: [URL] = []
        if let inner = unrealShippingBinary(under: dir) { extraProbes.append(inner) }
        for probe in siblingProbes.map({ dir.appending(path: $0) }) + extraProbes {
            let u = probe
            guard fm.fileExists(atPath: u.path), let pe = PEReader.read(u) else { continue }
            let found = pe.importedDLLs.filter { $0.hasPrefix("d3d") || $0 == "dxgi.dll" }
            if !found.isEmpty {
                apis.formUnion(found)
                r.signals.append(.init("graphics APIs from \(u.lastPathComponent): \(found.joined(separator: ", "))",
                                       path: u.lastPathComponent, weight: 0.1))
            }
        }
        r.graphicsAPIs = apis.sorted()

        // --- engine probes, most specific first -------------------------
        if has("UnityPlayer.dll") || hasSuffix("_data") {
            if has("GameAssembly.dll") {
                r.engine = .unityIL2CPP
                r.signals.append(.init("GameAssembly.dll present (IL2CPP)", weight: 0.4))
            } else {
                r.engine = .unityMono
                r.signals.append(.init("UnityPlayer.dll / *_Data present (Mono)", weight: 0.35))
            }
            r.recipes = []          // Unity is usually self-contained
        } else if has("nw.dll") || has("package.nw") || hasSuffix(".nw") {
            r.engine = .rpgMakerNW
            r.signals.append(.init("nw.js runtime present (RPG Maker MV/MZ)", weight: 0.4))
        } else if has("renpy") || hasSuffix(".rpa") {
            r.engine = .renpy
            r.signals.append(.init("renpy/ or .rpa archive present", weight: 0.4))
        } else if hasSuffix(".pck") {
            r.engine = .godot
            r.signals.append(.init("Godot .pck package present", weight: 0.35))
        } else if names.contains(where: { $0 == "Engine" }) || dir.path.contains("/Binaries/Win") {
            r.engine = .unreal
            r.signals.append(.init("Unreal Engine/ + Binaries layout", weight: 0.35))
            r.recipes = ["vcrun2019"]
        }

        r.engineVersion = engineVersion(dir: dir)
        if let v = r.engineVersion {
            r.signals.append(.init("engine version \(v)", weight: 0.05))
            if v.hasPrefix("6000.") {
                // Measured across every available combination on this machine:
                // D3DMetal lacks the D3D11 fence/multithread interfaces Unity 6
                // requires; its D3D12 path needs D3D11On12, also missing;
                // WineD3D cannot create the device at all; and Unity's Vulkan
                // renderer only works if the game shipped Vulkan shaders.
                r.knownUnsupported = """
                Unity 6 (\(v)). No graphics backend available here provides what it needs: \
                D3DMetal has no ID3D11Fence/ID3D11Multithread and no D3D11On12 for its D3D12 \
                path, and WineD3D cannot create a D3D11 device for it. Unity 2022 and earlier \
                are fine.
                """
            }
        }

        // Does this game play video? It is the single most important question
        // for backend choice on Apple Silicon, because D3DMetal cannot serve
        // Unity's video player.
        r.usesVideo = detectsVideo(dir: dir, exe: exe)
        if r.usesVideo {
            r.signals.append(.init("video playback detected (FMV or cutscenes)", weight: 0.05))
        }

        // --- modding / cache signals ------------------------------------
        if has("BepInEx") || has("doorstop_config.ini") || has("winhttp.dll") {
            r.modded = true
            r.signals.append(.init("BepInEx / Doorstop mod loader present", weight: 0.15))
        }
        if hasSuffix(".dxvk-cache") {
            r.hasWarmDXVKCache = true
            r.signals.append(.init("Warm .dxvk-cache from a previous DXVK run", weight: 0.2))
        }

        // --- choose runtime + backend -----------------------------------
        // Default is Wine 11 + DXVK: modern Wine, real 32-bit support, and the
        // backend that already had a warm cache on this machine. GPTK is
        // reserved for the case it actually wins: D3D12.
        // Default to GPTK/D3DMetal for modern 64-bit games. On Apple Silicon
        // this is not a close call: D3DMetal is the only backend that reaches
        // D3D feature level 11_1, which modern Unity and Unreal demand. Wine 11
        // is the newer, better Wine in every other respect — WoW64, Media
        // Foundation — but it has no D3DMetal, so its 3D options are DXVK
        // (capped below 11_1 on MoltenVK) or WineD3D (OpenGL, slow).
        let modern3D: Set<GameEngineKind> = [.unityIL2CPP, .unityMono, .unreal, .godot]
        if r.bitness == .x64 && modern3D.contains(r.engine) {
            r.recommendedRuntimeKind = .gptk
            r.recommendedBackend = .d3dmetal
        } else {
            r.recommendedRuntimeKind = .wine
            r.recommendedBackend = .dxvk
        }
        // D3D12 alone is not evidence a game *uses* D3D12: Unity and Unreal
        // both link it optionally and then render D3D11. Only prefer
        // GPTK/D3DMetal when D3D12 is present AND the engine isn't one of the
        // known optional-linkers.
        let optionalLinker = (r.engine == .unityIL2CPP || r.engine == .unityMono)
        if r.graphicsAPIs.contains("d3d12.dll") {
            r.recommendedRuntimeKind = .gptk
            r.recommendedBackend = .d3dmetal
            r.signals.append(.init("D3D12 referenced -> only D3DMetal can translate it here", weight: 0.1))
        }
        _ = optionalLinker
        // Hard evidence beats inference: a warm cache means DXVK really ran.
        if r.hasWarmDXVKCache {
            // Noted, but not decisive: that cache usually comes from an older
            // CrossOver-based bottle, and DXVK cannot reach 11_1 on MoltenVK.
            r.signals.append(.init("warm DXVK cache present (from a previous setup)", weight: 0.05))
        }
        // GPTK's Wine is 2022-era; for 32-bit, modern Wine is the safer bet.
        if r.bitness == .x86 && r.recommendedRuntimeKind == .gptk {
            r.recommendedRuntimeKind = .wine
            r.recommendedBackend = .dxvk
            r.signals.append(.init("32-bit -> fall back to Wine 11 (newer WoW64)", weight: 0.1))
        }
        if r.usesVideo && r.recommendedBackend == .d3dmetal {
            r.recommendedBackend = .wined3d
            r.signals.append(.init("plays video -> WineD3D, since D3DMetal lacks ID3D11Multithread", weight: 0.1))
        }
        if r.engine == .renpy || r.engine == .rpgMakerNW {
            // These are 2D and chromium/SDL based; DXVK buys nothing and
            // WineD3D avoids a whole class of Vulkan surface bugs.
            r.recommendedBackend = .wined3d
            r.signals.append(.init("2D engine -> WineD3D is sufficient and more stable", weight: 0.1))
        }

        r.confidence = min(1.0, r.signals.reduce(0) { $0 + $1.weight })
        return r
    }

    /// The executable a Unity game's `<Name>_Data` folder belongs to.
    func unityExecutable(in folder: URL) -> URL? {
        var dir = folder.standardizedFileURL
        var isDir: ObjCBool = false
        fm.fileExists(atPath: dir.path, isDirectory: &isDir)
        if !isDir.boolValue { dir = dir.deletingLastPathComponent() }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for n in names where n.hasSuffix("_Data") {
            let stem = String(n.dropLast("_Data".count))
            let exe = dir.appending(path: "\(stem).exe")
            if fm.fileExists(atPath: exe.path) { return exe }
        }
        return nil
    }

    /// A packaged Unreal build has a launcher .exe sitting beside an `Engine`
    /// directory; the real binary lives in <Game>/Binaries/Win64 and must NOT
    /// be launched directly — it resolves paths relative to itself and fails
    /// with "Failed to open descriptor file '../../X.uproject'".
    func unrealLauncher(near folder: URL) -> URL? {
        // Look at the folder itself and its parents: people often point at the
        // inner game directory rather than the packaged root.
        var dir = folder.standardizedFileURL
        // Deep enough to climb from <Game>/Binaries/Win64 to the packaged root,
        // which is four levels up — people drop any of these.
        for _ in 0..<6 {
            let engine = dir.appending(path: "Engine")
            if fm.fileExists(atPath: engine.path) {
                let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                let exes = names.filter { $0.lowercased().hasSuffix(".exe") }
                // The launcher is the only .exe at the packaged root.
                if let exe = exes.first { return dir.appending(path: exe) }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Unity stamps its version into UnityPlayer.dll as plain ASCII.
    ///
    /// Decoding the binary as UTF-8 and regexing it does not work: the bytes
    /// are not valid UTF-8 and the string arrives mangled. Scan for the digit
    /// pattern byte by byte, the way `strings` does.
    func engineVersion(dir: URL) -> String? {
        let u = dir.appending(path: "UnityPlayer.dll")
        guard fm.fileExists(atPath: u.path),
              let data = try? Data(contentsOf: u, options: .mappedIfSafe) else { return nil }

        func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        func isTag(_ b: UInt8) -> Bool { b == 97 || b == 98 || b == 102 || b == 112 }  // a b f p

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = min(raw.count, 96 * 1024 * 1024)
            var counts: [String: Int] = [:]
            var i = 0
            while i + 12 < count {
                guard isDigit(base[i]), i == 0 || !isDigit(base[i - 1]) else { i += 1; continue }
                var j = i, dots = 0, tagSeen = false
                var chunk: [UInt8] = []
                while j < count, chunk.count < 20 {
                    let c = base[j]
                    if isDigit(c) { chunk.append(c) }
                    else if c == 46 && !tagSeen { dots += 1; chunk.append(c) }
                    else if isTag(c) && dots == 2 && !tagSeen { tagSeen = true; chunk.append(c) }
                    else { break }
                    j += 1
                }
                if dots == 2, tagSeen, chunk.count >= 8,
                   let str = String(bytes: chunk, encoding: .ascii),
                   let major = str.split(separator: ".").first.map(String.init),
                   major == "6000" || (major.count == 4 && major.hasPrefix("20")) {
                    counts[str, default: 0] += 1
                }
                i = max(i + 1, j)
            }
            // Returning the FIRST match is wrong: UnityPlayer.dll carries older
            // version constants (e.g. 2018.3.0a1) before the real one. The
            // actual engine version is the one repeated most often.
            return counts.max { a, b in
                a.value != b.value ? a.value < b.value : compareVersions(a.key, b.key)
            }?.key
        }
    }

    /// True when `a` sorts before `b` numerically.
    func compareVersions(_ a: String, _ b: String) -> Bool {
        let pa = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let pb = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// Whether the game actually ships video.
    ///
    /// Only real video assets count. Checking for "WindowsVideoMedia" inside
    /// UnityPlayer.dll seemed clever but is worthless: Unity links its video
    /// backend into every build, so that test marks EVERY Unity game as a video
    /// game and pushes them all onto the slower backend.
    func detectsVideo(dir: URL, exe: URL) -> Bool {
        let videoExts: Set<String> = ["mp4", "webm", "mov", "avi", "mkv", "bk2", "usm", "ogv", "wmv"]
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return false }
        var looked = 0
        for case let f as URL in en {
            looked += 1
            if looked > 8000 { break }   // large games: sample rather than crawl
            if videoExts.contains(f.pathExtension.lowercased()) { return true }
        }
        return false
    }

    /// Video packed inside engine archives is invisible to a file scan, so the
    /// only reliable evidence is the engine's own log after a run. Callers fold
    /// this in once a game has been launched.
    public static func playerLogShowsVideo(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("windowsvideomedia") || l.contains("[playvideo]")
            || l.contains("videoplayer") || l.contains("video frame")
            // The usual way a Unity video failure actually appears — neither
            // of these mentions "VideoPlayer", so matching only on that name
            // missed almost every real case.
            || l.contains("multithread protection failed")
            || l.contains("software video decoding")
    }

    /// The real Unreal binary beneath a packaged root.
    func unrealShippingBinary(under root: URL) -> URL? {
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        for entry in entries where entry != "Engine" {
            let win64 = root.appending(path: "\(entry)/Binaries/Win64")
            guard let bins = try? fm.contentsOfDirectory(atPath: win64.path) else { continue }
            if let shipping = bins.first(where: { $0.lowercased().hasSuffix(".exe") }) {
                return win64.appending(path: shipping)
            }
        }
        return nil
    }

    public struct ExecutableChoice: Sendable, Identifiable {
        /// What this executable is for. A big game folder can hold thirty
        /// .exe files and only one of them is the game; listing them flat
        /// makes the picker useless exactly when it is most needed.
        public enum Kind: Int, Sendable, Comparable {
            case game = 0        // the game, or something that could be
            case tool = 1        // config editors, launchers, editors
            case installer = 2   // redistributables and setup programs
            case noise = 3       // crash handlers, uninstallers, updaters
            public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        }
        public var id: String { url.path }
        public var url: URL
        public var bytes: Int
        public var relativePath: String
        public var note: String?
        public var isLikelyGame: Bool
        public var kind: Kind = .game
    }

    /// Every executable under a folder, ranked, with a note explaining what
    /// each one probably is. The automatic pick is a guess; this is how a
    /// person overrules it.
    /// Classifies one executable by name and location.
    ///
    /// Names are the only honest signal short of running the thing, but they
    /// are a good one: nobody ships a game called UnityCrashHandler64.exe.
    public static func classify(name rawName: String, path: String) -> (ExecutableChoice.Kind, String?) {
        let name = rawName.lowercased()
        if name.contains("crashhandler") || name.contains("crashreport")
            || name.contains("crashpad") || name.contains("errorreport") {
            return (.noise, "crash reporter")
        }
        if name.contains("unins") || name.contains("uninstall") { return (.noise, "uninstaller") }
        if name.contains("updater") || name.contains("update.exe") { return (.noise, "updater") }
        if name.contains("vcredist") || name.contains("dxsetup") || name.contains("dxwebsetup")
            || name.contains("prereqsetup") || name.contains("directx") || name.contains("dotnetfx")
            || name.contains("ndp4") || name.contains("oalinst") || name.contains("xnafx") {
            return (.installer, "prerequisite installer — worth running once")
        }
        if name.contains("setup") || name.contains("install") { return (.installer, "installer") }
        if name.contains("config") || name.contains("setting") || name.contains("options") {
            return (.tool, "configuration tool")
        }
        if name.contains("editor") || name.contains("tool") || name.contains("benchmark") {
            return (.tool, "bundled tool")
        }
        if name.contains("launcher") { return (.tool, "launcher") }
        if path.contains("/Binaries/Win") { return (.tool, "Unreal inner binary — launch the root .exe instead") }
        return (.game, nil)
    }

    /// Every executable under a folder, ranked, with a note explaining what
    /// each one probably is. The automatic pick is a guess; this is how a
    /// person overrules it.
    ///
    /// Depth-limited because game folders bundle redistributables several
    /// levels down, and a flat walk of a large install turns up dozens of
    /// executables nobody would ever want to launch.
    public func listExecutables(in folder: URL, limit: Int = 60, maxDepth: Int = 4) -> [ExecutableChoice] {
        var root = folder.standardizedFileURL
        var isDir: ObjCBool = false
        fm.fileExists(atPath: root.path, isDirectory: &isDir)
        if !isDir.boolValue { root = root.deletingLastPathComponent() }
        if let launcher = unrealLauncher(near: root) { root = launcher.deletingLastPathComponent() }

        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let best = findExecutable(in: root)?.pathKey
        var out: [ExecutableChoice] = []
        for case let u as URL in en {
            if en.level > maxDepth { en.skipDescendants(); continue }
            guard u.pathExtension.lowercased() == "exe" else { continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rel = Self.relative(u, under: root)
            let (kind, note) = Self.classify(name: u.lastPathComponent, path: u.path)
            let same = u.pathKey == best
            out.append(ExecutableChoice(url: u, bytes: size, relativePath: rel,
                                        note: note, isLikelyGame: same,
                                        kind: same ? .game : kind))
            if out.count >= limit { break }
        }
        // The chosen one first, then by purpose, then largest — a game binary
        // is almost always bigger than the tools shipped beside it.
        return out.sorted { a, b in
            if a.isLikelyGame != b.isLikelyGame { return a.isLikelyGame }
            if a.kind != b.kind { return a.kind < b.kind }
            return a.bytes > b.bytes
        }
    }

    static func relative(_ u: URL, under base: URL) -> String {
        let b = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let p = u.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard p.count > b.count, Array(p.prefix(b.count)) == b else { return u.lastPathComponent }
        return p.dropFirst(b.count).joined(separator: "/")
    }

    /// Finds the most plausible game executable in a dropped folder.
    public func findExecutable(in folder: URL) -> URL? {
        // Unreal first: its layout is unambiguous, and picking the inner
        // shipping binary produces a confusing failure rather than a game.
        if let launcher = unrealLauncher(near: folder) { return launcher }

        // Unity is unambiguous too: the data folder is always named
        // "<ExeName>_Data". Scoring by file size picked a config tool whenever
        // it happened to be larger than the game's own launcher stub.
        if let unity = unityExecutable(in: folder) { return unity }

        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        var best: (URL, Int)? = nil
        let noise = ["unins", "crashhandler", "crashreport", "setup", "vcredist",
                     "dxsetup", "unitycrash", "notification_helper", "updater"]
        for case let u as URL in en {
            guard u.pathExtension.lowercased() == "exe" else { continue }
            let n = u.lastPathComponent.lowercased()
            if noise.contains(where: { n.contains($0) }) { continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Prefer an exe sitting next to engine markers over the biggest one.
            let sib = (try? fm.contentsOfDirectory(atPath: u.deletingLastPathComponent().path)) ?? []
            let sibLower = Set(sib.map { $0.lowercased() })
            var score = size / 1024
            if sibLower.contains("unityplayer.dll") || sibLower.contains(where: { $0.hasSuffix("_data") }) { score += 500_000 }
            if sibLower.contains("nw.dll") || sibLower.contains("renpy") { score += 500_000 }
            // Never prefer the inner Unreal binary over a packaged launcher.
            if u.path.contains("/Binaries/Win") { score -= 400_000 }
            if best == nil || score > best!.1 { best = (u, score) }
        }
        return best?.0
    }
}

/// Inspects a BepInEx installation sitting next to a game.
public struct ModInspector {
    let fm = FileManager.default
    public init() {}

    public struct Plugin: Sendable, Identifiable {
        public var id: String { fileName }
        public var fileName: String
        public var bytes: Int
    }

    public struct Status: Sendable {
        public var installed = false
        public var plugins: [Plugin] = []
        public var pluginsDir: URL?
        public var configDir: URL?
        public var logPath: URL?
        public var loaderRan = false
        public var loaderVersion: String?
        public var isIL2CPP = false
        public var note: String?
        public init() {}

        /// Failures the mod loader reported, newest last.
        ///
        /// A plugin that throws does not stop BepInEx from writing a cheerful
        /// startup banner, so `loaderRan` can be true while the game dies on
        /// launch. The reason is always in this log and nowhere else — the
        /// game's own window is gone by the time you could read it.
        public var errors: [String] = []
    }

    /// Pulls the failure lines out of a loader log.
    ///
    /// Matched on BepInEx's severity tags rather than the word "error", because
    /// plugin names and config keys contain "error" constantly and a log full
    /// of false positives gets ignored — which defeats the point of surfacing
    /// it. The tag is `[Error  :   Source]`, so the character after the level
    /// has to be checked too: `[ErrorHandler 1.2.0]` is a plugin name, not a
    /// severity.
    public static func failures(in lines: [String]) -> [String] {
        func severityTag(_ line: String, _ level: String) -> Bool {
            guard let r = line.range(of: "[" + level) else { return false }
            guard r.upperBound < line.endIndex else { return true }
            // A real tag is padded to a fixed width and closed with a colon.
            return line[r.upperBound] == " " || line[r.upperBound] == ":"
        }
        var out: [String] = []
        var lastWasFailure = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Stack frames arrive as separate indented lines and are the part
            // that actually names the plugin at fault, so a frame following a
            // failure is kept with it.
            let isFrame = lastWasFailure && trimmed.hasPrefix("at ")
            let isFailure = severityTag(line, "Error") || severityTag(line, "Fatal")
                || line.contains("FATAL UNHANDLED EXCEPTION")
                || trimmed.hasPrefix("Unhandled exception")
            guard isFailure || isFrame else { lastWasFailure = false; continue }
            lastWasFailure = true
            guard !trimmed.isEmpty, !out.contains(trimmed) else { continue }
            out.append(trimmed)
        }
        // Keep the tail: the first failure is usually a symptom of an earlier
        // plugin, but the last one is what actually took the process down.
        return Array(out.suffix(8))
    }

    /// Turns one loader log line into something a person can act on.
    ///
    /// The raw line is accurate and useless to most people: "Could not load
    /// [UIScale 0.9.0] : missing dependency" does not say that a mod is broken,
    /// which mod, or what to do. The original is kept and shown underneath —
    /// it is what you paste when asking for help.
    public static func explain(_ line: String) -> String {
        func bracketed() -> String? {
            guard let o = line.firstIndex(of: "["), let c = line[o...].firstIndex(of: "]"),
                  line.index(after: o) < c else { return nil }
            let inner = String(line[line.index(after: o)..<c])
            // Skip BepInEx's own severity tag, which is also bracketed.
            if inner.hasPrefix("Error") || inner.hasPrefix("Info")
                || inner.hasPrefix("Message") || inner.hasPrefix("Warning")
                || inner.hasPrefix("Fatal") || inner.hasPrefix("Debug") {
                let rest = line[c...].dropFirst()
                return Self.explainName(String(rest))
            }
            return inner
        }
        let low = line.lowercased()
        let name = bracketed().map { "“\($0)”" } ?? "A mod"

        if low.contains("missing dependency") || low.contains("missing dependencies") {
            return "\(name) needs another mod that is not installed."
        }
        if low.contains("incompatible") {
            return "\(name) does not work with this version of the game."
        }
        // Checked before the per-mod cases: a fatal crash usually *also*
        // mentions an exception type, and "the loader died" is the more
        // important fact — the game will not start at all.
        if low.contains("fatal unhandled exception") {
            return "The mod loader itself crashed, which stops the game from starting."
        }
        if low.contains("nullreferenceexception") {
            return "\(name) crashed. Usually it does not match this version of the game."
        }
        if low.contains("could not load") || low.contains("failed to load") {
            return "\(name) failed to load."
        }
        if low.contains("filenotfound") || low.contains("could not find file") {
            return "\(name) is missing a file it needs."
        }
        return "\(name) reported a problem."
    }

    /// Pulls a plugin name out of the text after the severity tag.
    static func explainName(_ rest: String) -> String? {
        guard let o = rest.firstIndex(of: "["), let c = rest[o...].firstIndex(of: "]"),
              rest.index(after: o) < c else { return nil }
        return String(rest[rest.index(after: o)..<c])
    }

    public func inspect(game: Game) -> Status {
        var st = Status()
        let dir = game.exePath.deletingLastPathComponent()
        let bep = dir.appending(path: "BepInEx")
        guard fm.fileExists(atPath: bep.path)
                || fm.fileExists(atPath: dir.appending(path: "doorstop_config.ini").path) else { return st }
        st.installed = true
        st.isIL2CPP = game.detection.engine == .unityIL2CPP

        let plugins = bep.appending(path: "plugins")
        if fm.fileExists(atPath: plugins.path) {
            st.pluginsDir = plugins
            let names = (try? fm.contentsOfDirectory(atPath: plugins.path)) ?? []
            for n in names where !n.hasPrefix(".") {
                let u = plugins.appending(path: n)
                let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                st.plugins.append(Plugin(fileName: n, bytes: size))
            }
            st.plugins.sort { $0.fileName < $1.fileName }
        }
        let config = bep.appending(path: "config")
        if fm.fileExists(atPath: config.path) { st.configDir = config }

        // BepInEx writes its own log; that is the only honest proof it ran.
        for candidate in ["LogOutput.log", "BepInEx/LogOutput.log"] {
            let u = dir.appending(path: candidate)
            if fm.fileExists(atPath: u.path) {
                st.logPath = u
                if let text = try? String(contentsOf: u, encoding: .utf8) {
                    st.loaderRan = text.contains("BepInEx") || text.contains("Chainloader")
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    for line in lines.prefix(12) where line.contains("BepInEx") {
                        if let r = line.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                            st.loaderVersion = String(line[r]); break
                        }
                    }
                    st.errors = Self.failures(in: lines.map(String.init))
                }
                break
            }
        }
        if st.isIL2CPP && !st.loaderRan {
            st.note = "IL2CPP games need BepInEx 6, which downloads a .NET runtime on first launch. That run is slow and can look like a hang."
        }
        return st
    }
}
