import Foundation

/// Runs winetricks verbs inside a bottle, and remembers what was applied so a
/// re-derived prefix can be brought back to the same state.
///
/// Recipes are how a game gets the Windows pieces Wine does not ship: codecs
/// for FMV, Visual C++ runtimes, fonts. Without this, "re-derive, never repair"
/// would quietly throw away every dependency a game needed.
public struct RecipeRunner {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    var toolsDir: URL { paths.runtimes.appending(path: "tools") }
    var winetricks: URL { toolsDir.appending(path: "winetricks") }

    /// Named bundles of verbs, so the common cases do not require knowing
    /// winetricks' vocabulary.
    public static let presets: [String: (verbs: [String], blurb: String)] = [
        "fmv": (["quartz", "devenum", "lavfilters702"],
                "Video playback for FMV games: DirectShow plus the LAV codec pack."),
        "media": (["quartz", "devenum", "lavfilters702", "xact"],
                  "Everything in fmv, plus XAudio for game sound."),
        "vcrun": (["vcrun2019"],
                  "Visual C++ 2015-2022 runtime — the usual answer when a game demands it by name."),
        "vcrun2013": (["vcrun2013"],
                      "Visual C++ 2013. For games from roughly 2013-2016."),
        "vcrun2010": (["vcrun2010"],
                      "Visual C++ 2010. Older titles and many RPG Maker VX games."),
        "vcrun-all": (["vcrun2010", "vcrun2013", "vcrun2019"],
                      "Every commonly-needed Visual C++ runtime. Slow, but ends the guessing."),
        "dotnet": (["dotnet48"],
                   ".NET Framework 4.8. Slow to install and often unnecessary."),
        "fonts": (["corefonts"],
                  "Core web fonts. Fixes blank or boxed text, especially in older games."),
        "d3dcompiler": (["d3dcompiler_47"],
                        "Shader compiler some Unity and Unreal titles expect to find."),
    ]

    public struct Tooling: Sendable {
        public var winetricks = false
        public var cabextract = false
        public var sevenZip = false
        public var missing: [String] {
            var m: [String] = []
            if !winetricks { m.append("winetricks") }
            if !cabextract { m.append("cabextract") }
            return m
        }
    }

    /// Checked before running, so a missing helper produces a clear message
    /// instead of an obscure winetricks failure halfway through.
    public func tooling() -> Tooling {
        var t = Tooling()
        t.winetricks = fm.isExecutableFile(atPath: winetricks.path)
        t.cabextract = fm.isExecutableFile(atPath: toolsDir.appending(path: "cabextract").path)
            || which("cabextract") != nil
        t.sevenZip = fm.isExecutableFile(atPath: toolsDir.appending(path: "7z").path)
            || which("7z") != nil
        return t
    }

    func which(_ name: String) -> String? {
        let r = try? Shell.run(URL(filePath: "/usr/bin/which"), [name], timeout: 15)
        let p = r?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.isEmpty ? nil : p
    }

    public struct Result: Sendable {
        public var verbs: [String] = []
        public var succeeded: [String] = []
        public var failed: [String] = []
        public var logPath: URL?
    }

    /// Expands presets into concrete winetricks verbs.
    public static func expand(_ names: [String]) -> [String] {
        var out: [String] = []
        for n in names {
            if let p = presets[n.lowercased()] { out.append(contentsOf: p.verbs) }
            else { out.append(n) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public func run(verbs raw: [String], prefix: URL, runtime: RuntimeSpec,
                    progress: (String) -> Void = { _ in }) throws -> Result {
        let t = tooling()
        guard t.winetricks else {
            throw DecanterError.notFound("winetricks is not pinned. Expected it at \(winetricks.path)")
        }
        if !t.cabextract {
            throw DecanterError.notFound(
                "cabextract is required by most winetricks verbs and was not found. Install it with `brew install cabextract`.")
        }
        let verbs = Self.expand(raw)
        var result = Result(verbs: verbs)

        var env = PrefixBuilder(paths: paths).baseEnv(prefix: prefix, runtime: runtime)
        env["WINE"] = runtime.winePath.path
        if let ws = runtime.wineserverPath { env["WINESERVER"] = ws.path }
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        env["W_CACHE"] = paths.root.appending(path: "cache/winetricks").path
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="   // no Mono/Gecko popups
        // Prefer Decanter's pinned helpers, then the system.
        env["PATH"] = toolsDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        try? fm.createDirectory(at: URL(filePath: env["W_CACHE"]!), withIntermediateDirectories: true)

        let logDir = paths.logs
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = logDir.appending(path: "recipes-\(Int(Date().timeIntervalSince1970)).log")
        var transcript = ""

        for verb in verbs {
            progress("installing \(verb) (this can take a while and may download)")
            let r = try Shell.run(URL(filePath: "/bin/sh"),
                                  ["-c", "\"\(winetricks.path)\" -q -f \(verb) 2>&1"],
                                  env: env, timeout: 1800)
            transcript += "\n===== \(verb) (exit \(r.code)) =====\n\(r.out)\n\(r.err)\n"
            // winetricks is not reliable about exit codes; check its own words.
            let out = (r.out + r.err).lowercased()
            let failed = r.code != 0 || out.contains("failed") && !out.contains("already installed")
            if failed { result.failed.append(verb); progress("  \(verb) failed") }
            else { result.succeeded.append(verb); progress("  \(verb) ok") }
        }
        try? transcript.write(to: log, atomically: true, encoding: .utf8)
        result.logPath = log
        return result
    }
}

/// Engine switches that change which renderer a game uses. These are often the
/// only way past a mismatch between what the engine wants and what a
/// translation layer provides — Unity 6, for instance, wants D3D11 features
/// D3DMetal does not implement, but will happily render through D3D12 instead.
public enum LaunchPresets {
    public static let unity: [(flag: String, blurb: String)] = [
        ("-force-d3d12", "Render with Direct3D 12. Best first try for Unity 6 on D3DMetal, which translates D3D12 natively."),
        ("-force-d3d11", "Force Direct3D 11, for games that default to something else."),
        ("-force-vulkan", "Render with Vulkan, which reaches Metal through MoltenVK."),
        ("-force-glcore", "Render with OpenGL. Slow, but it avoids the D3D layer entirely."),
        ("-screen-fullscreen 0", "Start windowed, which makes a broken fullscreen mode diagnosable."),
    ]

    public static func suggestions(for d: DetectionResult) -> [(flag: String, blurb: String)] {
        switch d.engine {
        case .unityIL2CPP, .unityMono: return unity
        default: return []
        }
    }
}
