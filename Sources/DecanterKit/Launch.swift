import Foundation

public struct Launcher {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    /// Default grants: the game's own folder and the shared games dir.
    /// Nothing else on the Mac is reachable.
    public func defaultScopes(for exe: URL) -> [ScopeGrant] {
        var s = [ScopeGrant(letter: "h", hostPath: exe.deletingLastPathComponent())]
        if fm.fileExists(atPath: paths.gamesDir.path) {
            s.append(ScopeGrant(letter: "g", hostPath: paths.gamesDir, readOnly: true))
        }
        return s
    }

    public func windowsPath(for exe: URL, scopes: [ScopeGrant]) throws -> String {
        let p = exe.path
        // Longest matching grant wins, so a nested grant beats a broad one.
        for s in scopes.sorted(by: { $0.hostPath.path.count > $1.hostPath.path.count }) {
            let base = s.hostPath.path
            if p == base || p.hasPrefix(base + "/") {
                let rel = String(p.dropFirst(base.count)).drop(while: { $0 == "/" })
                let win = rel.replacingOccurrences(of: "/", with: #"\"#)
                return "\(s.letter.uppercased()):\\\(win)"
            }
        }
        throw DecanterError.pathEscapesScope(exe)
    }

    public struct Plan: Sendable {
        public var runtime: RuntimeSpec
        public var bottle: Bottle
        public var env: [String: String]
        public var winPath: String
        public var arguments: [String] = []
        public var cwd: URL
        public var logFile: URL
    }

    public func plan(game: Game, bottle: Bottle, runtime: RuntimeSpec,
                     verbose: Bool = false, showHUD: Bool = false) throws -> Plan {
        let pb = PrefixBuilder(paths: paths)
        var env = pb.baseEnv(prefix: bottle.prefixPath, runtime: runtime)
        let gfx = pb.graphicsEnv(bottle.backend, runtime: runtime)
        // Merge WINEDLLOVERRIDES rather than letting one source clobber another.
        var overrides: [String] = []
        // Only Gecko is disabled. Disabling mscoree as well used to seem
        // harmless, but it silently breaks anything that launches a .NET
        // process — BepInEx's splash screen is a separate .NET executable, and
        // killing it takes the whole game down with a NullReferenceException.
        // Wine ships wine-mono, so .NET works without any dialog.
        overrides.append("mshtml=")
        if let a = gfx["WINEDLLOVERRIDES"] { overrides.append(a) }
        // BepInEx / Doorstop loads through a proxy winhttp.dll sitting next to
        // the game. Wine prefers its own builtin winhttp unless told otherwise,
        // so without this the game starts perfectly and simply runs vanilla —
        // a failure that produces no error at all.
        if game.detection.modded, game.dllOverrides["winhttp"] == nil {
            overrides.append("winhttp=n,b")
        }
        for (dll, mode) in game.dllOverrides.sorted(by: { $0.key < $1.key }) {
            overrides.append("\(dll)=\(mode)")
        }
        for (k, v) in gfx where k != "WINEDLLOVERRIDES" { env[k] = v }
        if !overrides.isEmpty { env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";") }
        for (k, v) in game.envOverrides { env[k] = v }

        // Troubleshoot mode. A game that renders wrongly without crashing
        // produces an almost empty log by default, which is precisely the
        // case that is hardest to report. This makes the graphics stack talk.
        if verbose {
            env["WINEDEBUG"] = "+d3d,+dxgi,+vulkan,fixme-all"
            env["DXVK_LOG_LEVEL"] = "info"
            env["MVK_CONFIG_LOG_LEVEL"] = "2"
        }
        // The on-screen overlay is a separate choice from verbose logging.
        // Bundling them meant troubleshooting a game also defaced it.
        if showHUD {
            env["DXVK_HUD"] = "devinfo,version,api,fps"
            if bottle.backend == .d3dmetal { env["MTL_HUD_ENABLED"] = "1" }
        } else {
            env["DXVK_HUD"] = "0"
            env["MTL_HUD_ENABLED"] = "0"
        }

        let scopes = game.scopes.isEmpty ? defaultScopes(for: game.exePath) : game.scopes
        try pb.applyScopes(prefix: bottle.prefixPath, scopes: scopes)
        let win = try windowsPath(for: game.exePath, scopes: scopes)
        let log = paths.logs.appending(path: "\(game.name.replacingOccurrences(of: "/", with: "_")).log")
        return Plan(runtime: runtime, bottle: bottle, env: env, winPath: win,
                    arguments: game.launchArguments ?? [],
                    cwd: game.exePath.deletingLastPathComponent(), logFile: log)
    }

    @discardableResult
    public func launch(_ plan: Plan) throws -> Process {
        try fm.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        return try Shell.spawn(plan.runtime.winePath, [plan.winPath] + plan.arguments,
                               env: plan.env, cwd: plan.cwd, logFile: plan.logFile)
    }
}
