import Foundation

/// The facade both the CLI and the SwiftUI app drive. Keeping this the single
/// entry point is what stops the two front-ends from drifting apart.
public final class Engine: @unchecked Sendable {
    public let paths: Paths
    public let store: Store
    public let runtimes: RuntimeManager
    public let prefixes: PrefixBuilder
    public let launcher: Launcher
    public let detector = Detector()
    public lazy var saves = SaveStore(paths: paths)
    public lazy var knowledge = Knowledge.load(at: paths.knowledgePath)

    public init(paths: Paths = Paths()) throws {
        self.paths = paths
        self.store = try Store(paths: paths)
        self.runtimes = RuntimeManager(paths: paths)
        self.prefixes = PrefixBuilder(paths: paths)
        self.launcher = Launcher(paths: paths)
    }

    // MARK: Setup

    /// How much longer x86_64 Wine can run on this Mac.
    ///
    /// Everything Decanter manages is an x86_64 program executed through
    /// Rosetta 2. Apple has said macOS 27 is the last release with full Rosetta
    /// and that macOS 28 removes it, keeping only a subset aimed at older
    /// unmaintained games — a carve-out Wine is unlikely to fall under.
    ///
    /// This is not a Unity 6 style problem that belongs upstream. It is an
    /// assumption in this codebase, and the recommendation that routes 32-bit
    /// games to mainline Wine rests on it.
    public enum RosettaHorizon: Sendable, Equatable {
        case fine(untilMajor: Int)
        case lastSupportedRelease
        case removed
        public var note: String {
            switch self {
            case .fine(let m):
                "Rosetta 2 is present. Apple has said macOS \(m) is the last release to include it in full."
            case .lastSupportedRelease:
                "This is the last macOS release with full Rosetta 2. The next one removes it, and Wine is an x86_64 program."
            case .removed:
                "This macOS no longer includes full Rosetta 2, which x86_64 Wine needs."
            }
        }
    }

    /// macOS 27 is the last release with full Rosetta 2; 28 removes it.
    public static let lastRosettaMajorVersion = 27

    public static func rosettaHorizon(majorVersion: Int) -> RosettaHorizon {
        if majorVersion < lastRosettaMajorVersion { return .fine(untilMajor: lastRosettaMajorVersion) }
        if majorVersion == lastRosettaMajorVersion { return .lastSupportedRelease }
        return .removed
    }

    public struct Health: Sendable {
        public var rosetta = false
        public var rosettaHorizon: RosettaHorizon = .fine(untilMajor: 27)
        public var macOSMajor = 0
        public var pinnedRuntimes: [RuntimeSpec] = []
        public var discovered: [RuntimeManager.Candidate] = []
        public var templateBuilt = false
        public var templateAge: TimeInterval?
        public var gamesDirExists = false
    }

    public func doctor() -> Health {
        var h = Health()
        h.rosetta = FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta")
        h.macOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        h.rosettaHorizon = Self.rosettaHorizon(majorVersion: h.macOSMajor)
        h.pinnedRuntimes = store.state.runtimes
        h.discovered = runtimes.discover()
        h.templateBuilt = FileManager.default.fileExists(atPath: paths.template.path)
        if let t = store.state.templateBuiltAt { h.templateAge = Date().timeIntervalSince(t) }
        h.gamesDirExists = FileManager.default.fileExists(atPath: paths.gamesDir.path)
        return h
    }

    @discardableResult
    public func pinAll(progress: (String) -> Void = { _ in }) throws -> [RuntimeSpec] {
        var out: [RuntimeSpec] = []
        for c in runtimes.discover() {
            progress("pinning \(c.kind.rawValue) \(c.version)")
            out.append(try runtimes.pin(c, store: store))
        }
        return out
    }

    public func buildTemplate(runtimeID: String? = nil,
                              progress: @escaping (String) -> Void = { _ in }) throws {
        let rt: RuntimeSpec
        if let runtimeID {
            guard let found = store.runtime(runtimeID) else { throw DecanterError.noRuntime(runtimeID) }
            rt = found
        } else {
            guard let found = store.state.runtimes.sorted(by: { $0.version > $1.version })
                .first(where: { $0.kind == .wine }) ?? store.state.runtimes.first else {
                throw DecanterError.noRuntime("nothing pinned yet — run `decanter pin` first")
            }
            rt = found
        }
        try prefixes.buildGoldenTemplate(runtime: rt, store: store, progress: progress)
    }

    /// Runtimes that have no template yet — these cannot host a game.
    public func runtimesWithoutTemplate() -> [RuntimeSpec] {
        store.state.runtimes.filter {
            !FileManager.default.fileExists(atPath: paths.template(for: $0.id).path)
        }
    }

    // MARK: Games

    @discardableResult
    public func add(path: URL, name: String? = nil,
                    progress: (String) -> Void = { _ in }) throws -> Game {
        var exe = path
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
        if isDir.boolValue {
            progress("scanning folder for a game executable")
            guard let found = detector.findExecutable(in: path) else {
                throw DecanterError.notAnExecutable(path)
            }
            exe = found
        }
        guard exe.pathExtension.lowercased() == "exe" else { throw DecanterError.notAnExecutable(exe) }

        // A folder can legitimately hold two separate games, so sharing a
        // directory is allowed — but the same executable twice is always a
        // mistake, and silently making a second prefix for it wastes a rebuild.
        let target = exe.pathKey
        if let clash = store.state.games.first(where: { $0.exePath.pathKey == target }) {
            throw DecanterError.notFound("\(exe.lastPathComponent) is already in the library as \"\(clash.name)\"")
        }

        progress("inspecting \(exe.lastPathComponent)")
        var det = detector.detect(exe: exe)
        guard let rt = runtimes.choose(for: det, store: store) else {
            throw DecanterError.noRuntime("no pinned runtime fits this game")
        }
        if det.bitness == .x86 && !rt.supports32Bit {
            throw DecanterError.runtimeLacks32Bit(rt.id)
        }
        // Clamp the backend to something this runtime can actually provide.
        // D3DMetal only exists inside GPTK; storing it against Wine would
        // silently degrade to no acceleration at all.
        var backend = det.recommendedBackend
        if !rt.backends.contains(backend) {
            let fallback = rt.backends.first ?? .wined3d
            det.signals.append(.init("\(backend.label) unavailable on \(rt.id) -> using \(fallback.label)", weight: 0))
            backend = fallback
        }

        progress("deriving prefix from golden template")
        let bottleID = UUID()
        var bottle = try prefixes.derive(bottleID: bottleID, runtime: rt, backend: backend)
        bottle.appliedRecipes = det.recipes

        // "Game.exe", "Start.exe", "Launcher.exe" tell you nothing in a list;
        // the folder the game lives in almost always does.
        let generic: Set<String> = ["game", "start", "launcher", "play", "app", "run",
                                    "main", "win64", "win32", "shipping", "client"]
        var derived = exe.deletingPathExtension().lastPathComponent
        if generic.contains(derived.lowercased()) {
            let folder = exe.deletingLastPathComponent().lastPathComponent
            if !folder.isEmpty { derived = folder }
        }
        let gname = name ?? derived
        let game = Game(name: gname, exePath: exe, bottleID: bottleID, detection: det,
                        scopes: launcher.defaultScopes(for: exe))
        try store.mutate { s in
            // Replacing a game by name must not leave its old prefix behind.
            if let prior = s.games.first(where: { $0.name.lowercased() == gname.lowercased() }) {
                if let ob = s.bottles.first(where: { $0.id == prior.bottleID }) {
                    try? FileManager.default.removeItem(at: ob.prefixPath)
                }
                s.bottles.removeAll { $0.id == prior.bottleID }
            }
            s.bottles.append(bottle)
            s.games.removeAll { $0.name.lowercased() == gname.lowercased() }
            s.games.append(game)
        }
        return game
    }

    public func run(_ game: Game, verbose: Bool = false, showHUD: Bool = false) throws -> Launcher.Plan {
        guard let bottle = store.bottle(game.bottleID) else {
            throw DecanterError.notFound("bottle for \(game.name)")
        }
        guard let rt = store.runtime(bottle.runtimeID) else {
            throw DecanterError.noRuntime(bottle.runtimeID)
        }
        let plan = try launcher.plan(game: game, bottle: bottle, runtime: rt,
                                     verbose: verbose, showHUD: showHUD)
        try launcher.launch(plan)
        try store.mutate { s in
            if let i = s.games.firstIndex(where: { $0.id == game.id }) {
                s.games[i].lastPlayed = Date()
            }
        }
        return plan
    }

    public struct PreflightReport: Sendable {
        public var winPath = ""
        public var runtimeID = ""
        public var backend = ""
        public var scopesApplied: [String] = []
        public var exeVisibleToWine = false
        public var fullFilesystemExposed = true
        public var dxvkPresent = false
        public var escapingUserFolders: [String] = []
        public var effectiveD3D = ""
        public var problems: [String] = []
        public var ok: Bool {
            problems.isEmpty && exeVisibleToWine && !fullFilesystemExposed
                && escapingUserFolders.isEmpty
        }
    }

    /// Everything `run` does, minus starting the game. Applies the scopes,
    /// resolves the DOS path, then asks Wine itself whether it can see the
    /// executable. This is the command to reach for when a game won't start.
    public func preflight(_ game: Game) throws -> PreflightReport {
        var rep = PreflightReport()
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }
        rep.runtimeID = rt.id
        rep.backend = bottle.backend.label

        if game.detection.bitness == .x86 && !rt.supports32Bit {
            rep.problems.append("game is 32-bit but \(rt.id) has no 32-bit support")
        }
        if !rt.backends.contains(bottle.backend) {
            rep.problems.append("\(bottle.backend.label) is not provided by \(rt.id)")
        }
        if bottle.backend == .dxvk && !DXVKInstaller(paths: paths).isInstalled(in: bottle.prefixPath) {
            rep.problems.append("backend is DXVK but this prefix has Wine's builtin D3D")
        }
        rep.dxvkPresent = DXVKInstaller(paths: paths).isInstalled(in: bottle.prefixPath)
        rep.effectiveD3D = switch bottle.backend {
            case .dxvk:
                rep.dxvkPresent
                    ? "DXVK \(DXVKInstaller(paths: paths).installedVersion(in: bottle.prefixPath) ?? "(build not among those staged)") (native DLLs in prefix)"
                    : "Wine builtin D3D (DXVK missing!)"
            case .d3dmetal: "Apple D3DMetal (builtin, via \(rt.id))"
            case .wined3d:  "Wine builtin D3D on OpenGL"
        }

        let plan = try launcher.plan(game: game, bottle: bottle, runtime: rt)
        rep.winPath = plan.winPath
        let dd = bottle.prefixPath.appending(path: "dosdevices")
        rep.scopesApplied = ((try? FileManager.default.contentsOfDirectory(atPath: dd.path)) ?? []).sorted()
        rep.fullFilesystemExposed = rep.scopesApplied.contains("z:")
        // Check the user folders too: they are a second route to the host home
        // directory, and claiming containment without testing them was wrong.
        rep.escapingUserFolders = PrefixBuilder(paths: paths).escapingUserFolders(prefix: bottle.prefixPath)
        if !rep.escapingUserFolders.isEmpty {
            rep.problems.append("these Windows user folders reach outside the prefix: "
                                + rep.escapingUserFolders.joined(separator: ", "))
        }

        // Resolve the DOS path back through the drive symlink ourselves.
        // (Wine's cmd mishandles `if exist "H:\..."` when H: is not the
        // current drive, so shelling out for this answers the wrong question.)
        let fm = FileManager.default
        let letter = String(plan.winPath.prefix(1)).lowercased()
        let link = dd.appending(path: "\(letter):")
        if let hostBase = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let rel = plan.winPath.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
            var base = URL(filePath: hostBase)
            if !hostBase.hasPrefix("/") {   // c: is stored relative to the prefix
                base = bottle.prefixPath.appending(path: hostBase).standardizedFileURL
            }
            let resolved = base.appending(path: rel)
            rep.exeVisibleToWine = fm.fileExists(atPath: resolved.path)
            if !rep.exeVisibleToWine {
                rep.problems.append("drive \(letter.uppercased()): does not contain \(rel)")
            }
        } else {
            rep.problems.append("drive \(letter.uppercased()): is not mapped in this prefix")
        }
        return rep
    }

    /// The failure model: never repair, re-derive. Cheap because of APFS clone.
    public func rederive(_ game: Game, progress: (String) -> Void = { _ in }) throws -> Bottle {
        guard let old = store.bottle(game.bottleID) else {
            throw DecanterError.notFound("bottle for \(game.name)")
        }
        guard let rt = store.runtime(old.runtimeID) else { throw DecanterError.noRuntime(old.runtimeID) }
        // Re-derive destroys the prefix contents, so capture saves first.
        // This is what makes "never repair, always re-derive" safe to use.
        progress("snapshotting saves first")
        _ = try? saves.snapshot(game: game, prefix: old.prefixPath, template: template(for: game),
                                note: "taken automatically before rebuilding", progress: progress)
        progress("re-deriving prefix from golden template")
        var fresh = try prefixes.derive(bottleID: old.id, runtime: rt, backend: old.backend)
        fresh.generation = old.generation + 1
        fresh.appliedRecipes = old.appliedRecipes
        fresh.dxvkVersion = old.dxvkVersion
        // The template carries the default DXVK; if this game pinned a
        // different version, put it back.
        if let v = old.dxvkVersion {
            let dx = DXVKInstaller(paths: paths)
            if dx.installedVersion(in: fresh.prefixPath) != v {
                progress("restoring DXVK \(v)")
                _ = try? dx.install(into: fresh.prefixPath, runtime: rt, version: v, progress: progress)
            }
        }
        try store.mutate { s in
            s.bottles.removeAll { $0.id == old.id }
            s.bottles.append(fresh)
        }
        // Re-attach externalised saves so the fresh prefix sees them again.
        if saves.isExternalised(game: game) {
            let n = (try? saves.relink(game: game, prefix: fresh.prefixPath,
                                       template: prefixes.templateURL(for: rt), progress: progress)) ?? 0
            if n > 0 { progress("re-attached \(n) externalised save folder(s)") }
        }
        // Dependencies live inside the prefix, so a fresh one has none of them.
        // Without replaying them, "re-derive, never repair" would quietly
        // uninstall every codec and runtime the game needed.
        if !fresh.appliedRecipes.isEmpty {
            progress("re-applying \(fresh.appliedRecipes.count) recipe(s): \(fresh.appliedRecipes.joined(separator: ", "))")
            _ = try? recipes.run(verbs: fresh.appliedRecipes, prefix: fresh.prefixPath,
                                 runtime: rt, progress: progress)
        }
        // Registry keys cannot be symlinked, so the fresh prefix has none.
        // Re-apply the newest snapshot that carries a registry export, or
        // Unity games silently lose their PlayerPrefs on every rebuild.
        if let snap = saves.snapshots(for: game).first(where: { $0.hasRegistry }) {
            let reg = snap.url.appending(path: "registry.reg")
            if FileManager.default.fileExists(atPath: reg.path) {
                progress("re-applying registry keys from \(snap.name)")
                _ = try? SaveImporter().mergeRegistry(reg, into: fresh.prefixPath, runtime: rt)
            }
        }
        return fresh
    }

    /// Removes prefixes no game points at, plus any on-disk prefix directory
    // MARK: Stray Wine processes

    public lazy var reaper = WineReaper(paths: paths)

    /// Wine sessions still alive. Anything hours old is almost certainly a
    /// leak rather than a game, since Decanter's own launches end with the
    /// game window closing.
    public func strayWineProcesses() -> [WineReaper.Stray] { reaper.strays() }

    @discardableResult
    public func reapWine(progress: (String) -> Void = { _ in }) -> WineReaper.Outcome {
        reaper.reap(progress: progress)
    }

    /// Ends one game without touching anything else that is running.
    ///
    /// A hung game cannot be quit from its own window, and Force Quit does not
    /// list it — Wine processes are not applications. Killing that prefix's
    /// wineserver takes its clients with it and leaves other games alone.
    @discardableResult
    public func stop(_ game: Game) throws -> Int {
        guard let b = store.bottle(game.bottleID) else { return 0 }
        let target = b.prefixPath.pathKey
        let o = reaper.reap { stray in
            guard let p = stray.prefix else { return false }
            return p.pathKey == target
        }
        return o.killed.count
    }

    // MARK: Fonts

    public struct FontOutcome: Sendable {
        public var scope = ""
        public var plan = FontProvisioner.Plan()
        public var error: String?
    }

    /// Brings every template and bottle up to date with the font mapping.
    ///
    /// Templates matter most — new bottles clone from them — but existing
    /// bottles are not re-derived just for this, so they get the same edit
    /// applied in place. The mapping is pure registry data, so re-running is
    /// harmless and idempotent.
    @discardableResult
    public func provisionFonts(progress: (String) -> Void = { _ in }) -> [FontOutcome] {
        let fonts = FontProvisioner()
        var out: [FontOutcome] = []
        var targets: [(String, URL)] = []
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(atPath: paths.templateRoot.path)) ?? [] {
            let u = paths.templateRoot.appending(path: dir)
            if fm.fileExists(atPath: u.appending(path: "system.reg").path) {
                targets.append(("template \(dir)", u))
            }
        }
        for b in store.state.bottles {
            let name = store.state.games.first { $0.bottleID == b.id }?.name ?? b.id.uuidString
            targets.append(("bottle \(name)", b.prefixPath))
        }
        for (scope, prefix) in targets {
            var o = FontOutcome(); o.scope = scope
            do { o.plan = try fonts.apply(to: prefix) }
            catch { o.error = String(describing: error) }
            progress("\(scope): \(o.error ?? "\(o.plan.mapped.count) names mapped")")
            out.append(o)
        }
        return out
    }

    /// with no record at all. Orphaned bottles are how Whisky accumulated
    /// four abandoned duplicates.
    @discardableResult
    public func gc(progress: (String) -> Void = { _ in }) throws -> (bottles: Int, bytes: Int) {
        let live = Set(store.state.games.map(\.bottleID))
        var removed = 0, bytes = 0
        for b in store.state.bottles where !live.contains(b.id) {
            bytes += Self.directorySize(b.prefixPath)
            progress("removing orphan bottle \(b.id.uuidString)")
            try? FileManager.default.removeItem(at: b.prefixPath)
            removed += 1
        }
        try store.mutate { s in s.bottles.removeAll { !live.contains($0.id) } }

        // Untracked directories on disk (e.g. from an interrupted derive).
        let known = Set(store.state.bottles.map(\.prefixPath.lastPathComponent))
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: paths.bottles.path)) ?? []
        for d in onDisk where !known.contains(d) && !d.hasPrefix(".") {
            let u = paths.bottles.appending(path: d)
            bytes += Self.directorySize(u)
            progress("removing untracked prefix \(d)")
            try? FileManager.default.removeItem(at: u)
            removed += 1
        }
        return (removed, bytes)
    }

    static func directorySize(_ url: URL) -> Int {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in en {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Moves a game to a different pinned runtime. The prefix is kept (so
    /// saves survive); the backend is clamped to whatever the new runtime can
    /// actually provide. Going from a newer Wine to an older one can make the
    /// prefix complain — `preflight` will say so, and `rederive` fixes it at
    /// the cost of the prefix contents.
    @discardableResult
    public func setRuntime(_ game: Game, to runtimeID: String,
                           progress: (String) -> Void = { _ in }) throws -> GraphicsBackend {
        guard let rt = store.runtime(runtimeID) else { throw DecanterError.noRuntime(runtimeID) }
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        if game.detection.bitness == .x86 && !rt.supports32Bit {
            throw DecanterError.runtimeLacks32Bit(rt.id)
        }
        _ = try? saves.snapshot(game: game, prefix: bottle.prefixPath, template: template(for: game),
                                note: "taken automatically before switching engine")
        let backend = rt.backends.contains(bottle.backend) ? bottle.backend : (rt.backends.first ?? .wined3d)

        // A prefix built by one Wine generation is not safe under another —
        // this function said so and then did not act on it. It checked the
        // template existed, rewrote the runtime id, and left the old prefix in
        // place, so the new Wine met a stranger's registry and a graphics stack
        // installed for a different engine. That surfaced as a Wine Mono
        // Installer prompt and then "InitializeEngineGraphics failed", neither
        // of which names the actual cause.
        guard FileManager.default.fileExists(atPath: paths.template(for: rt.id).path) else {
            throw DecanterError.noTemplate(rt.id)
        }
        progress("re-deriving the Windows environment for \(rt.id)")
        var fresh = try prefixes.derive(bottleID: bottle.id, runtime: rt, backend: backend)
        fresh.generation = bottle.generation + 1
        fresh.appliedRecipes = bottle.appliedRecipes
        fresh.dxvkVersion = bottle.dxvkVersion
        if backend == .dxvk, let v = bottle.dxvkVersion {
            let dx = DXVKInstaller(paths: paths)
            if dx.installedVersion(in: fresh.prefixPath) != v {
                _ = try? dx.install(into: fresh.prefixPath, runtime: rt, version: v, progress: progress)
            }
        }
        try prefixes.applyScopes(prefix: fresh.prefixPath, scopes: game.scopes)
        _ = try? saves.relink(game: game, prefix: fresh.prefixPath)
        try store.mutate { s in
            s.bottles.removeAll { $0.id == bottle.id }
            s.bottles.append(fresh)
            if let i = s.games.firstIndex(where: { $0.id == game.id }) { s.games[i].runtimeLocked = true }
        }
        note(fresh.id, "runtime -> \(rt.id), backend -> \(backend.label), environment rebuilt")
        return backend
    }

    /// Switches a game to a specific staged DXVK version.
    @discardableResult
    public func setDXVK(_ game: Game, version: String,
                        progress: (String) -> Void = { _ in }) throws -> String {
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }
        let dx = DXVKInstaller(paths: paths)
        _ = try dx.install(into: bottle.prefixPath, runtime: rt, version: version, progress: progress)
        try store.mutate { s in
            if let i = s.bottles.firstIndex(where: { $0.id == bottle.id }) {
                s.bottles[i].dxvkVersion = version
                s.bottles[i].backend = .dxvk
            }
        }
        note(bottle.id, "backend -> DXVK \(version) (explicit request)")
        return version
    }

    /// Appends a dated line to a bottle's change log.
    func note(_ bottleID: UUID, _ text: String) {
        try? store.mutate { s in
            guard let i = s.bottles.firstIndex(where: { $0.id == bottleID }) else { return }
            var log = s.bottles[i].changeLog ?? []
            let stamp = ISO8601DateFormatter().string(from: Date())
            log.append("\(stamp)  \(text)")
            s.bottles[i].changeLog = Array(log.suffix(40))
        }
    }

    // MARK: - Recipes

    public lazy var recipes = RecipeRunner(paths: paths)

    /// Installs dependencies into a game's bottle and records them, so a
    /// re-derived prefix can be restored to the same state.
    @discardableResult
    public func install(_ game: Game, verbs: [String],
                        progress: (String) -> Void = { _ in }) throws -> RecipeRunner.Result {
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }
        let r = try recipes.run(verbs: verbs, prefix: bottle.prefixPath, runtime: rt, progress: progress)
        if !r.succeeded.isEmpty {
            try store.mutate { s in
                if let i = s.bottles.firstIndex(where: { $0.id == bottle.id }) {
                    var applied = s.bottles[i].appliedRecipes
                    for v in r.succeeded where !applied.contains(v) { applied.append(v) }
                    s.bottles[i].appliedRecipes = applied
                }
            }
        }
        return r
    }

    /// Re-runs detection with the current rules.
    ///
    /// Stored detection is a snapshot from when the game was added, so games
    /// added before a rule changed keep showing outdated evidence — and miss
    /// traits that did not exist yet, such as whether the game plays video.
    @discardableResult
    public func redetect(_ game: Game, progress: (String) -> Void = { _ in }) throws -> DetectionResult {
        progress("re-inspecting \(game.exePath.lastPathComponent)")
        var fresh = detector.detect(exe: game.exePath)
        // Video packed inside engine archives cannot be seen statically; if the
        // game has run, its own log settles the question.
        if !fresh.usesVideo, let log = engineLog(for: game),
           let text = try? String(contentsOf: log, encoding: .utf8),
           Detector.playerLogShowsVideo(text) {
            fresh.usesVideo = true
            fresh.signals.append(.init("the game's own log shows video playback", weight: 0.05))
        }
        try store.mutate { s in
            if let i = s.games.firstIndex(where: { $0.id == game.id }) {
                s.games[i].detection = fresh
            }
        }
        return fresh
    }

    @discardableResult
    public func setLaunchArguments(_ game: Game, _ args: [String]) throws -> [String] {
        try store.mutate { s in
            if let i = s.games.firstIndex(where: { $0.id == game.id }) {
                s.games[i].launchArguments = args.isEmpty ? nil : args
            }
        }
        note(game.bottleID, "launch arguments -> \(args.isEmpty ? "(none)" : args.joined(separator: " "))")
        return args
    }

    @discardableResult
    public func setEnvironment(_ game: Game, _ vars: [String: String], clear: Bool = false) throws -> [String: String] {
        var result: [String: String] = [:]
        try store.mutate { s in
            guard let i = s.games.firstIndex(where: { $0.id == game.id }) else { return }
            if clear { s.games[i].envOverrides = [:] }
            for (k, v) in vars { s.games[i].envOverrides[k] = v }
            result = s.games[i].envOverrides
        }
        note(game.bottleID, "environment -> \(result.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
        return result
    }

    /// Locale presets. Japanese and Chinese games frequently crash outright
    /// under a Western locale, because their text handling assumes the system
    /// codepage — a near-null dereference shortly after startup is typical.
    public static let localePresets: [String: (vars: [String: String], blurb: String)] = [
        "japanese": (["LANG": "ja_JP.UTF-8", "LC_ALL": "ja_JP.UTF-8"],
                     "Japanese locale. Try this first for a JP game that crashes just after the splash."),
        "chinese":  (["LANG": "zh_CN.UTF-8", "LC_ALL": "zh_CN.UTF-8"],
                     "Simplified Chinese locale."),
        "korean":   (["LANG": "ko_KR.UTF-8", "LC_ALL": "ko_KR.UTF-8"], "Korean locale."),
        "default":  (["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"], "Back to English."),
    ]

    public func executables(for game: Game) -> [Detector.ExecutableChoice] {
        detector.listExecutables(in: game.exePath.deletingLastPathComponent())
    }

    /// Points the game at a different executable, re-detecting and re-scoping.
    @discardableResult
    public func setExecutable(_ game: Game, to exe: URL,
                              progress: (String) -> Void = { _ in }) throws -> Game {
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw DecanterError.notFound(exe.path)
        }
        guard exe.pathExtension.lowercased() == "exe" else { throw DecanterError.notAnExecutable(exe) }
        progress("re-inspecting \(exe.lastPathComponent)")
        let det = detector.detect(exe: exe)
        var updated = game
        try store.mutate { s in
            guard let i = s.games.firstIndex(where: { $0.id == game.id }) else { return }
            s.games[i].exePath = exe
            s.games[i].detection = det
            // Widen the scope if the new executable sits outside the old grant.
            let scopes = s.games[i].scopes
            let covered = scopes.contains { exe.path.hasPrefix($0.hostPath.path + "/") }
            if !covered {
                s.games[i].scopes = self.launcher.defaultScopes(for: exe)
            }
            updated = s.games[i]
        }
        note(game.bottleID, "executable -> \(exe.lastPathComponent)")
        return updated
    }

    /// Runs any executable inside this game's prefix — a config tool, or the
    /// prerequisite installer games ship in Extras/Redist. Does not change
    /// which executable the game normally launches.
    @discardableResult
    public func runOther(_ game: Game, exe: URL) throws -> Launcher.Plan {
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }
        var temp = game
        temp.exePath = exe
        if !(game.scopes.contains { exe.path.hasPrefix($0.hostPath.path + "/") }) {
            temp.scopes = launcher.defaultScopes(for: exe)
        }
        let plan = try launcher.plan(game: temp, bottle: bottle, runtime: rt)
        try launcher.launch(plan)
        return plan
    }

    // MARK: - Recommendation (no launching)

    public struct Recommendation: Sendable {
        public var runtimeKind: RuntimeKind
        public var backend: GraphicsBackend
        public var reasons: [String] = []
        public var caveats: [String] = []
        public var confidence: String = "high"
    }

    /// Picks a configuration from what the files say, with no trial and error.
    ///
    /// The rules come from documented behaviour plus what has been observed on
    /// this machine:
    ///  - D3DMetal provides feature level 11_1 and is by far the fastest, but
    ///    it does not implement ID3D11Multithread / ID3D11Fence, which Unity's
    ///    video player requires. Apple's own forums describe this as a known
    ///    gap with no launch-argument workaround.
    ///  - DXVK on MoltenVK tops out below 11_1, so modern Unity and Unreal
    ///    refuse to create a device at all.
    ///  - WineD3D is a complete D3D11 implementation (multithread included) on
    ///    OpenGL: slower, but it is the only one that plays Unity video here.
    public func recommend(for game: Game) -> Recommendation {
        let d = game.detection

        // Say plainly when nothing will work. Knowing a game cannot run is far
        // more useful than being invited to try five configurations that fail.
        if let blocker = d.knownUnsupported {
            var r = Recommendation(runtimeKind: .gptk, backend: .d3dmetal)
            r.confidence = "known limitation"
            r.reasons.append("This game will not run on any available setup.")
            r.reasons.append(blocker.replacingOccurrences(of: "\n", with: " "))
            r.caveats.append("Nothing to try here — it needs a newer D3DMetal, or a translation layer such as DXMT that implements the missing interfaces.")
            return r
        }

        // What has actually worked before beats any static rule.
        let sig = Knowledge.Signature(d)
        if let known = knowledge.lookup(sig), known.confirmations > 0 {
            var r = Recommendation(runtimeKind: known.runtimeKind, backend: known.backend)
            let others = known.confirmedGames.subtracting([game.id]).count
            r.reasons.append("this worked for \(known.confirmations) game(s) with the same profile (\(sig.label))")
            if others > 0 {
                r.reasons.append("\(others) of them other than this one")
            }
            if let n = known.note { r.reasons.append(n) }
            r.confidence = known.confirmations >= 2 ? "high" : "medium"
            return r
        }

        var r = Recommendation(runtimeKind: .gptk, backend: .d3dmetal)

        // 2D engines never need a fast 3D path, and WineD3D avoids a whole
        // class of translation bugs.
        if d.engine == .renpy || d.engine == .rpgMakerNW {
            r = Recommendation(runtimeKind: .wine, backend: .wined3d)
            r.reasons.append("\(d.engine.label) is 2D — WineD3D is sufficient and the most predictable")
            if d.bitness == .x86 { r.reasons.append("32-bit, so modern Wine's WoW64 is the safer host") }
            return r
        }

        if d.bitness == .x86 {
            r = Recommendation(runtimeKind: .wine, backend: .wined3d)
            r.reasons.append("32-bit: Wine 11's WoW64 handles these more reliably than GPTK's 2022 base")
            r.caveats.append("If it is a DirectX 9 game, DXVK is usually faster — worth trying second")
            return r
        }

        if d.usesVideo {
            r = Recommendation(runtimeKind: .gptk, backend: .wined3d)
            r.reasons.append("this game plays video, and D3DMetal has no ID3D11Multithread — video fails on it")
            r.reasons.append("WineD3D is a complete D3D11 implementation, so the video player works")
            r.caveats.append("WineD3D runs on OpenGL and is noticeably slower; if you never watch the cutscenes, D3DMetal will be faster")
            return r
        }

        r.reasons.append("\(d.engine.label), 64-bit: D3DMetal gives feature level 11_1 and native Metal speed")
        if d.graphicsAPIs.contains("d3d12.dll") {
            r.reasons.append("D3D12 is referenced, which only D3DMetal can translate here")
        }
        r.caveats.append("If the game turns out to play video, switch to WineD3D — D3DMetal cannot drive Unity's video player")
        if d.confidence < 0.6 { r.confidence = "low"; r.caveats.append("Detection confidence is low; treat this as a starting point") }
        return r
    }

    /// Applies the recommendation without launching anything.
    @discardableResult
    public func applyRecommendation(_ game: Game, progress: (String) -> Void = { _ in }) throws -> Recommendation {
        let rec = recommend(for: game)
        guard let rt = store.state.runtimes.first(where: { $0.kind == rec.runtimeKind })
                ?? store.state.runtimes.first else { throw DecanterError.noRuntime("none pinned") }
        try apply(Candidate(runtimeID: rt.id, backend: rec.backend, dxvkVersion: nil),
                  to: game, progress: progress)
        return rec
    }

    /// Remembers that a configuration worked, both for this game and for every
    /// future game with the same profile. This is what stops a new title from
    /// starting the guessing over again.
    public func rememberWorking(_ game: Game) throws {
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else { return }
        knowledge.recordSuccess(signature: Knowledge.Signature(game.detection),
                                gameID: game.id, runtimeKind: rt.kind, backend: b.backend)
        try knowledge.save(to: paths.knowledgePath)
        note(b.id, "confirmed working: \(rt.id) + \(b.backend.label)")
    }

    public func rememberFailed(_ game: Game) throws {
        knowledge.recordFailure(signature: Knowledge.Signature(game.detection), gameID: game.id)
        try knowledge.save(to: paths.knowledgePath)
    }

    // MARK: - Auto-configuration

    public struct Candidate: Sendable, Equatable {
        public var runtimeID: String
        public var backend: GraphicsBackend
        public var dxvkVersion: String?
        public var label: String {
            "\(runtimeID) + \(backend.label)" + (dxvkVersion.map { " \($0)" } ?? "")
        }
    }

    public struct AttemptResult: Sendable {
        public var candidate: Candidate
        public var outcome: LaunchMonitor.Outcome
        public var videoBroken: Bool
        public var score: Int
        public var notes: [String]
    }

    /// Configurations to try, best-first, using what has actually been observed
    /// on Apple Silicon:
    ///  - DXVK on MoltenVK cannot provide D3D feature level 11_1, which modern
    ///    Unity and Unreal both ask for, so it goes last.
    ///  - D3DMetal provides 11_1 and is fastest, but has no ID3D11Multithread,
    ///    which Unity's video player requires — so a game with video needs
    ///    WineD3D even though it is slower.
    public func candidates(for game: Game) -> [Candidate] {
        let haveGPTK = store.state.runtimes.contains { $0.kind == .gptk }
        let wine = store.state.runtimes.first { $0.kind == .wine }?.id
        let gptk = store.state.runtimes.first { $0.kind == .gptk }?.id
        let dxvkOldest = DXVKInstaller(paths: paths).stagedVersions().last
        var out: [Candidate] = []

        if haveGPTK, let g = gptk {
            out.append(Candidate(runtimeID: g, backend: .d3dmetal, dxvkVersion: nil))
            out.append(Candidate(runtimeID: g, backend: .wined3d, dxvkVersion: nil))
        }
        if let w = wine {
            out.append(Candidate(runtimeID: w, backend: .wined3d, dxvkVersion: nil))
            out.append(Candidate(runtimeID: w, backend: .dxvk, dxvkVersion: dxvkOldest))
        }
        // A 32-bit game cannot use a runtime without 32-bit support.
        if game.detection.bitness == .x86 {
            out = out.filter { store.runtime($0.runtimeID)?.supports32Bit ?? false }
        }
        return out.filter { c in
            guard let rt = store.runtime(c.runtimeID) else { return false }
            guard rt.backends.contains(c.backend) else { return false }
            return FileManager.default.fileExists(atPath: paths.template(for: rt.id).path)
        }
    }

    public func apply(_ c: Candidate, to game: Game, progress: (String) -> Void = { _ in }) throws {
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        let needsRederive = bottle.runtimeID != c.runtimeID
        if needsRederive {
            try store.mutate { s in
                if let i = s.bottles.firstIndex(where: { $0.id == bottle.id }) {
                    s.bottles[i].runtimeID = c.runtimeID
                }
            }
            progress("rebuilding prefix for \(c.runtimeID)")
            _ = try rederive(game, progress: { _ in })
        }
        try store.mutate { s in
            if let i = s.bottles.firstIndex(where: { $0.id == game.bottleID }) {
                s.bottles[i].backend = c.backend
            }
        }
        if c.backend == .dxvk, let v = c.dxvkVersion {
            _ = try? setDXVK(game, version: v)
        }
        note(game.bottleID, "autoconfig tried \(c.label)")
    }

    /// Tries configurations until one renders with working video, reporting
    /// each attempt. This replaces guessing by hand.
    public func autoconfigure(_ game: Game, stopAtFirstGood: Bool = true,
                              progress: (String) -> Void = { _ in }) throws -> (best: Candidate?, attempts: [AttemptResult]) {
        let monitor = LaunchMonitor(paths: paths)
        var attempts: [AttemptResult] = []
        var best: (Candidate, Int)? = nil

        for c in candidates(for: game) {
            progress("trying \(c.label)")
            try apply(c, to: game, progress: progress)
            guard let g = store.state.games.first(where: { $0.id == game.id }) else { break }

            var notes: [String] = []
            do { _ = try run(g) }
            catch {
                notes.append(error.localizedDescription)
                attempts.append(AttemptResult(candidate: c, outcome: .neverStarted,
                                              videoBroken: false, score: 0, notes: notes))
                continue
            }
            let r = monitor.observe(game: g, engineLog: engineLog(for: g), progress: progress)
            if let b = store.bottle(g.bottleID), let rt = store.runtime(b.runtimeID) {
                monitor.stop(game: g, runtime: rt, prefix: b.prefixPath)
            }
            notes.append(contentsOf: r.findings.map(\.summary))
            attempts.append(AttemptResult(candidate: c, outcome: r.outcome,
                                          videoBroken: r.videoBroken, score: r.score, notes: notes))
            progress("  \(c.label): \(r.outcome.summary)\(r.videoBroken ? ", video broken" : "")")

            if best == nil || r.score > best!.1 { best = (c, r.score) }
            // 4 = renders, video fine, nothing in the engine log.
            if stopAtFirstGood, r.score >= 4 { break }
        }
        if let b = best?.0 {
            progress("settling on \(b.label)")
            try apply(b, to: game)
            if let g = store.state.games.first(where: { $0.id == game.id }),
               (best?.1 ?? 0) >= 3 {
                try? rememberWorking(g)
                progress("remembered for future games of this kind")
            }
        }
        return (best?.0, attempts)
    }

    // MARK: - Removal

    public struct RemovalReport: Sendable {
        public var game: String = ""
        public var bottleBytes: Int = 0
        public var snapshotTaken: String?
        public var savedFiles: Int = 0
        public var gameFolderUntouched: String = ""
    }

    /// Removes a game and its bottle. The game's own files on the Mac are
    /// never touched — they live outside the prefix and are not ours to delete.
    @discardableResult
    public func remove(_ game: Game, keepSaves: Bool = true,
                       progress: (String) -> Void = { _ in }) throws -> RemovalReport {
        var rep = RemovalReport()
        rep.game = game.name
        rep.gameFolderUntouched = game.exePath.deletingLastPathComponent().path

        if let bottle = store.bottle(game.bottleID) {
            if keepSaves {
                progress("snapshotting saves before removal")
                if let snap = try? saves.snapshot(game: game, prefix: bottle.prefixPath, template: template(for: game),
                                                  note: "taken automatically before removal") {
                    rep.snapshotTaken = snap.name
                    rep.savedFiles = snap.fileCount
                }
            }
            rep.bottleBytes = Self.directorySize(bottle.prefixPath)
            progress("deleting prefix")
            try? FileManager.default.removeItem(at: bottle.prefixPath)
        }
        if !keepSaves {
            progress("deleting stored saves")
            try? saves.deleteAll(for: game)
        }
        try store.mutate { s in
            s.bottles.removeAll { $0.id == game.bottleID }
            s.games.removeAll { $0.id == game.id }
        }
        return rep
    }

    // MARK: - Saves

    @discardableResult
    public func externaliseSaves(_ game: Game, progress: (String) -> Void = { _ in }) throws -> SaveStore.Externalisation {
        guard let b = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        return try saves.externalise(game: game, prefix: b.prefixPath, template: template(for: game), progress: progress)
    }

    /// The template this game's prefix was actually built from.
    public func template(for game: Game) -> URL? {
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else { return nil }
        return prefixes.templateURL(for: rt)
    }

    public func discoverSaves(_ game: Game) -> SaveStore.Discovery {
        guard let b = store.bottle(game.bottleID) else { return SaveStore.Discovery() }
        return saves.discoverEffective(game: game, prefix: b.prefixPath, template: template(for: game))
    }

    @discardableResult
    public func snapshotSaves(_ game: Game, note: String? = nil,
                              progress: (String) -> Void = { _ in }) throws -> SaveStore.Snapshot {
        guard let b = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        let snap = try saves.snapshot(game: game, prefix: b.prefixPath, template: template(for: game), note: note, progress: progress)
        _ = try? saves.prune(game: game, keep: snapshotRetention)
        return snap
    }

    public var snapshotRetention: Int { 8 }

    @discardableResult
    public func restoreSaves(_ game: Game, snapshot named: String? = nil,
                             progress: (String) -> Void = { _ in }) throws -> Int {
        guard let b = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        let all = saves.snapshots(for: game)
        guard let snap = named.flatMap({ n in all.first { $0.name == n } }) ?? all.first else {
            throw DecanterError.notFound("no snapshot for \(game.name)")
        }
        let rt = store.runtime(b.runtimeID)
        return try saves.restore(snap, game: game, into: b.prefixPath, runtime: rt, progress: progress)
    }

    /// Every game's saves at a glance — what the Saves surface renders.
    public struct SaveOverview: Sendable {
        public var game: String
        public var slug: String
        public var files: Int
        public var bytes: Int
        public var lastModified: Date?
        public var snapshots: Int
        public var registryKeys: Int
        public init(game: String, slug: String, files: Int, bytes: Int,
                    lastModified: Date?, snapshots: Int, registryKeys: Int) {
            self.game = game; self.slug = slug; self.files = files; self.bytes = bytes
            self.lastModified = lastModified; self.snapshots = snapshots
            self.registryKeys = registryKeys
        }
    }

    public func savesOverview() -> [SaveOverview] {
        store.state.games.map { g in
            let d = discoverSaves(g)
            return SaveOverview(game: g.name, slug: saves.slug(for: g),
                                files: d.files.count, bytes: d.totalBytes,
                                lastModified: d.files.map(\.modified).max(),
                                snapshots: saves.snapshots(for: g).count,
                                registryKeys: d.registryKeys.count)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Cross-game search over every discovered save file.
    public struct SaveHit: Sendable {
        public var game: String
        public var relPath: String
        public var bytes: Int
        public var modified: Date
    }

    public func searchSaves(_ query: String) -> [SaveHit] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var out: [SaveHit] = []
        for g in store.state.games {
            for f in discoverSaves(g).files where f.relPath.lowercased().contains(q) {
                out.append(SaveHit(game: g.name, relPath: f.relPath,
                                   bytes: f.bytes, modified: f.modified))
            }
        }
        return out.sorted { $0.modified > $1.modified }
    }

        /// Assembles a pasteable problem report: system, configuration, detection,
    /// diagnosis, graphics log lines, and optionally a screenshot of the
    /// running game window.
    /// Locates the game engine's own log (Unity's Player.log), wherever the
    /// saves actually live — inside the prefix, or out in the store.
    public func engineLog(for game: Game) -> URL? {
        var roots: [URL] = []
        if let b = store.bottle(game.bottleID) { roots.append(b.prefixPath) }
        roots.append(saves.liveRoot(game))
        var found: [(URL, Date)] = []
        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let f as URL in en where f.lastPathComponent == "Player.log" {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append((f, d))
            }
        }
        // Newest wins, and a live log beats an archived crash report — reading
        // an old Crashes/ copy made a fixed problem look like it persisted.
        return found
            .sorted { a, b in
                let aCrash = a.0.path.contains("/Crashes/"), bCrash = b.0.path.contains("/Crashes/")
                if aCrash != bCrash { return !aCrash }
                return a.1 > b.1
            }
            .first?.0
    }

    /// Diagnosis combining Wine's log with the game engine's own.
    public func diagnose(_ game: Game, since: Date? = nil) -> Diagnostics.Report {
        let d = Diagnostics()
        let log = paths.logs.appending(path: "\(game.name.replacingOccurrences(of: "/", with: "_")).log")
        var rep = d.analyse(logAt: log)
        // Only trust the engine log if it belongs to this run. A stale log from
        // an earlier configuration made a fixed problem look like it persisted.
        if let pl = engineLog(for: game),
           let mod = try? pl.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           since == nil || mod >= since!.addingTimeInterval(-5),
           let text = try? String(contentsOf: pl, encoding: .utf8) {
            let extra = d.analysePlayerLog(text)
            var seen = Set(rep.findings.map(\.summary))
            for f in extra where seen.insert(f.summary).inserted { rep.findings.append(f) }
        }
        return rep
    }

    /// Screenshots are deliberately not captured: Decanter never asks for
    /// Screen Recording permission. A visual fault is the user's to screenshot.
    public func report(_ game: Game,
                       progress: (String) -> Void = { _ in }) throws -> URL {
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }
        let pre = try? preflight(game)
        return try Reporter(paths: paths).buildReport(
            game: game, bottle: bottle, runtime: rt, preflight: pre, progress: progress)
    }

    public func importSaves(into game: Game, from source: URL,
                            progress: (String) -> Void = { _ in }) throws -> SaveImporter.Report {
        guard let bottle = store.bottle(game.bottleID) else {
            throw DecanterError.notFound("bottle for \(game.name)")
        }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }
        return try SaveImporter().importSaves(from: source, into: bottle, runtime: rt, progress: progress)
    }
}
