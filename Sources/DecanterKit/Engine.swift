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
        refreshRuntimeCapabilities()
    }

    /// Adopt whatever another process has written since this Engine was built.
    ///
    /// `Store.refresh()` was written for exactly this and had no callers. The
    /// app held one Engine for its whole lifetime, `knowledge` was a `lazy var`
    /// read once, and so anything the CLI changed stayed invisible until the
    /// app was quit and reopened — a game moved to another backend went on
    /// being drawn on the old one, and an endorsement made at the prompt
    /// changed nothing on screen. The Refresh menu item recomputed the
    /// interface over the same frozen snapshot, which is worse than having no
    /// Refresh at all: it answers the question without looking.
    ///
    /// Runtime capabilities are re-derived too, because a build that was
    /// repaired between launches can do things the recorded list says it
    /// cannot.
    public func reload() {
        store.refresh()
        knowledge = Knowledge.load(at: paths.knowledgePath)
        refreshRuntimeCapabilities()
    }

    /// Re-derives what each pinned runtime can offer, from the files on disk.
    ///
    /// `backends` is recorded at pin time, so a runtime pinned before a backend
    /// existed keeps claiming it cannot do something it can. That is not a
    /// hypothetical: every runtime pinned before DXMT support was added said
    /// "DXMT is not provided by this runtime" while sitting on a Wine that
    /// hosts it perfectly well. Capability is a property of the bytes, so it is
    /// re-read rather than trusted.
    func refreshRuntimeCapabilities() {
        // Only capabilities are re-derived here. Dropping specs whose files are
        // missing was tried and is wrong: a runtime on an unmounted external
        // drive is absent, not gone, and deleting the user's registration for
        // it because a volume was not plugged in is unrecoverable. Callers that
        // need a runtime to actually exist check for themselves.
        // Re-derived *inside* the lock, from the copy `mutate` just read off
        // disk. Computing the list first and assigning it afterwards looks
        // equivalent and is not: `mutate` replaces `state` with the disk copy
        // before running this body, so a list built beforehand is a snapshot
        // from before another process's writes, and assigning it puts those
        // writes back the way they were. The app runs this at launch, which is
        // exactly when the CLI is most likely to have moved something.
        let capable = store.state.runtimes.contains { rt in
            RuntimeManager.backends(for: rt.kind, root: rt.root) != rt.backends
        }
        guard capable else { return }
        try? store.mutate { s in
            s.runtimes = s.runtimes.map { rt in
                var r = rt
                r.backends = RuntimeManager.backends(for: rt.kind, root: rt.root)
                return r
            }
        }
    }

    /// Forgets a pinned runtime and deletes Decanter's copy of it.
    ///
    /// Refused while a bottle still points at it: unpinning underneath a game
    /// leaves that game unlaunchable with no way back, and "it stopped working
    /// and I don't know why" is the failure this project exists to avoid. A
    /// DXMT host clone is deleted with its base, because it is a copy of that
    /// base and useless without it.
    @discardableResult
    public func removeRuntime(_ id: String, progress: (String) -> Void = { _ in }) throws -> String {
        guard let spec = store.runtime(id) else {
            throw DecanterError.notFound("no pinned runtime called \(id)")
        }
        let users = store.state.bottles.filter { $0.runtimeID == id }
        guard users.isEmpty else {
            let names = users.compactMap { b in store.state.games.first { $0.bottleID == b.id }?.name }
            throw DecanterError.usage(
                "\(id) is still in use by \(names.isEmpty ? "\(users.count) environment(s)" : names.joined(separator: ", "))"
                + " — move them with `decanter runtime set <game> <other>` first.")
        }
        // The clone made for DXMT goes too. It exists only to host DXMT for
        // this base, and leaving it behind is what put two Wine 11s in the
        // runtime list with one of them unusable.
        let clone = id + DXMTInstaller.hostSuffix
        var removed = [id]
        if store.runtime(clone) != nil,
           store.state.bottles.allSatisfy({ $0.runtimeID != clone }) { removed.append(clone) }

        for r in removed {
            if let spec = store.runtime(r) { try? FileManager.default.removeItem(at: spec.root) }
            try? FileManager.default.removeItem(at: paths.template(for: r))
            progress("removed \(r)")
        }
        try store.mutate { st in
            st.runtimes.removeAll { removed.contains($0.id) }
            for r in removed { st.templates[r] = nil }
            if let t = st.templateRuntimeID, removed.contains(t) { st.templateRuntimeID = nil }
        }
        _ = spec
        return removed.count == 1 ? "removed \(id)"
                                  : "removed \(removed.joined(separator: " and "))"
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
        // Templates have been per-runtime — `template/golden-<id>` — since a
        // prefix built by Wine 11 was found not to be safe under GPTK's Wine
        // 7.7. This kept checking `template/golden`, the single location that
        // preceded that, so it answered from a directory nothing writes any
        // more.
        //
        // On a machine that has been through the old layout the legacy folder
        // is still there and the answer came out right by accident, which is
        // why it survived: the only machine that shows the fault is one that
        // has never had a template before. On that machine — every new user —
        // `template list` said built, Setup said missing, and the setup page
        // stayed at "not ready yet" no matter how many times the template was
        // rebuilt. Found by installing the pack into an empty root, which is
        // the first time this project has run a first run.
        h.templateBuilt = FileManager.default.fileExists(atPath: paths.template.path)
            || store.state.runtimes.contains {
                FileManager.default.fileExists(atPath: paths.template(for: $0.id).path)
            }
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
        // Preflight already knew. It listed four problems for a game that then
        // launched anyway, ran on graphics it was not configured for, and died
        // without writing an error — and stayed that way for days because
        // nothing ever refused. Checking and then proceeding regardless is the
        // same as not checking.
        let pre = try preflight(game)
        if let first = pre.blockers.first {
            let rest = pre.blockers.dropFirst()
            let more = rest.isEmpty ? "" : "\n" + rest.map { "Also: \($0)." }.joined(separator: "\n")
            // Plain sentences, no command syntax: the same words have to read
            // correctly in a window and in a terminal, and the interface that
            // shows them is the one that knows how its own buttons are named.
            throw DecanterError.notReady(
                "\(game.name) is not ready to run — \(first).\(more) "
                + "Choose a graphics option this Windows environment provides, "
                + "or let Decanter pick one for this game.")
        }

        // Say it rather than only doing it. A drive that appeared since the
        // last launch is exactly the case the promise exists for, so it is
        // recorded where "what set this, and when" can be answered.
        let plan = try launcher.plan(game: game, bottle: bottle, runtime: rt,
                                     verbose: verbose, showHUD: showHUD)
        recordClosures(plan, bottle: bottle)
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
        /// The subset of `problems` that means the game cannot work, as opposed
        /// to the ones that are untidy but survivable. A game whose recorded
        /// graphics option its runtime cannot provide does not fail loudly:
        /// Wine's own D3D loads instead, the game initialises, and it dies with
        /// nothing in the log to find. Measured once, on a game that had been
        /// quietly unplayable for days.
        public var blockers: [String] = []
        public var ok: Bool {
            problems.isEmpty && exeVisibleToWine && !fullFilesystemExposed
                && escapingUserFolders.isEmpty
        }

        /// The report as one sentence anyone can act on.
        ///
        /// Lives here rather than in the app so the answer to "would this
        /// start?" is the same wherever it is asked, and so it can be tested
        /// without a Wine build. Blockers are said in preference to problems:
        /// a game whose graphics option its runtime cannot provide does not
        /// fail loudly — Wine's own D3D loads instead and the game dies with
        /// nothing in the log — so naming an untidy drive mapping ahead of that
        /// would answer a question nobody asked.
        public var plainSummary: String {
            if ok { return "Everything it needs is in place — it should start." }
            let said = blockers.isEmpty ? problems : blockers
            if !said.isEmpty { return said.joined(separator: "  ") }
            return exeVisibleToWine
                ? "Something is not right, but Decanter could not name it. Press Play, then Diagnose."
                : "Wine cannot see the game's program file. Rebuild the environment, or re-inspect the folder."
        }

        public init() {}
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

        // First, because it is the only one here that no change can lift. The
        // others say "this setup is wrong"; this one says "no setup works", and
        // burying it under a graphics complaint sends somebody off to try
        // backend combinations for an evening.
        if let ac = game.detection.antiCheat {
            rep.problems.append("\(ac) is present and needs a Windows kernel driver")
            rep.blockers.append("this game uses \(ac), which runs as a Windows kernel driver. There is no Windows kernel here to load it into, so no Wine build, graphics layer or setting will start it")
        }
        if game.detection.bitness == .x86 && !rt.supports32Bit {
            rep.problems.append("game is 32-bit but \(rt.id) has no 32-bit support")
            rep.blockers.append("this game is 32-bit, and \(rt.id) cannot run 32-bit programs")
        }
        if !rt.backends.contains(bottle.backend) {
            rep.problems.append("\(bottle.backend.label) is not provided by \(rt.id)")
            rep.blockers.append("this game is set to \(bottle.backend.label) graphics, which \(rt.id) cannot provide. Wine’s own graphics load instead and the game fails with nothing in the log")
        }
        if bottle.backend == .dxvk && !DXVKInstaller(paths: paths).isInstalled(in: bottle.prefixPath) {
            rep.problems.append("backend is DXVK but this prefix has Wine's builtin D3D")
            rep.blockers.append("this game is set to Vulkan graphics, but its Windows environment has Wine’s built-in graphics instead")
        }
        if bottle.backend == .dxmt {
            if !DXMTInstaller(paths: paths).isInstalled(in: bottle.prefixPath) {
                rep.problems.append("backend is DXMT but this prefix is not marked for it")
            rep.blockers.append("this game is set to Metal graphics, but its Windows environment is not set up for it")
            }
            if !FileManager.default.fileExists(
                atPath: WineLayout.hostPath(under: rt.root, "winemetal.so").path) {
                rep.problems.append("\(rt.id) does not carry DXMT's Metal bridge")
            rep.blockers.append("\(rt.id) does not carry the Metal bridge this game’s graphics option needs")
            }
        }
        rep.dxvkPresent = DXVKInstaller(paths: paths).isInstalled(in: bottle.prefixPath)
        rep.effectiveD3D = switch bottle.backend {
            case .dxvk:
                rep.dxvkPresent
                    ? "DXVK \(DXVKInstaller(paths: paths).installedVersion(in: bottle.prefixPath) ?? "(build not among those staged)") (native DLLs in prefix)"
                    : "Wine builtin D3D (DXVK missing!)"
            case .d3dmetal: "Apple D3DMetal (builtin, via \(rt.id))"
            case .wined3d:  "Wine builtin D3D on OpenGL"
            case .dxmt:
                DXMTInstaller(paths: paths).isInstalled(in: bottle.prefixPath)
                    ? "DXMT \(DXMTInstaller(paths: paths).installedVersion(in: bottle.prefixPath) ?? "(version unknown)") (builtin, via \(rt.id))"
                    : "Wine builtin D3D (DXMT missing!)"
        }

        let plan = try launcher.plan(game: game, bottle: bottle, runtime: rt)
        recordClosures(plan, bottle: bottle)
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
        // DXMT lives in the runtime, so a rebuilt prefix carries only a marker
        // saying which layer it is running. Without this the bottle recorded
        // DXMT while the prefix had none, and `check` reported "Wine builtin
        // D3D (DXMT missing!)" for a game the library insisted was on DXMT —
        // the same "says one thing, runs another" the DXVK branch above exists
        // to prevent.
        let dxmt = DXMTInstaller(paths: paths)
        if backend == .dxmt, let v = dxmt.defaultVersion {
            dxmt.mark(v, in: fresh.prefixPath)
        } else {
            dxmt.clearMarker(in: fresh.prefixPath)
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

    /// Moves a game to a backend, doing whatever the prefix needs for it.
    ///
    /// Setting the field alone is not enough for the two backends that are
    /// real DLLs in the prefix: DXVK and DXMT overwrite the same files, so
    /// switching between them has to reinstall rather than just relabel. The
    /// UI and the CLI both go through here so they cannot drift.
    @discardableResult
    public func setBackend(_ game: Game, _ backend: GraphicsBackend,
                           lockRuntime: Bool = true,
                           progress: (String) -> Void = { _ in }) throws -> GraphicsBackend {
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle") }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }

        let dxmt = DXMTInstaller(paths: paths)
        switch backend {
        case .dxmt:
            guard let v = dxmt.defaultVersion else {
                throw DecanterError.notFound("DXMT is not staged — hand Decanter a DXMT build first")
            }
            // DXMT lives in a runtime, not in a prefix, so switching to it can
            // mean moving the game to the runtime that carries it.
            let host = try dxmt.hostRuntime(basedOn: rt, version: v, store: store, progress: progress)
            if host.id != rt.id {
                _ = try setRuntime(game, to: host.id, progress: progress)
            }
            if let b = store.bottle(game.bottleID) { dxmt.mark(v, in: b.prefixPath) }
        default:
            // A prefix that still claims DXMT while running something else is
            // how a report ends up describing the wrong graphics layer.
            dxmt.clearMarker(in: bottle.prefixPath)
        }
        try store.mutate { s in
            if let i = s.bottles.firstIndex(where: { $0.id == game.bottleID }) { s.bottles[i].backend = backend }
            if lockRuntime, let i = s.games.firstIndex(where: { $0.id == game.id }) { s.games[i].runtimeLocked = true }
        }
        note(game.bottleID, "backend -> \(backend.label)")
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
    /// Writes down every drive the descope closed on the way to a plan.
    ///
    /// Building a plan is what descopes, and three separate paths build one —
    /// launching, `check`, and the autoconfigure attempts. Recording it at only
    /// the launch site meant a stray volume found by `check` was closed in
    /// silence, which is the half of the promise that is not merely doing the
    /// right thing but being able to say it was done.
    func recordClosures(_ plan: Launcher.Plan, bottle: Bottle) {
        for d in plan.closedDrives {
            note(bottle.id, "closed a drive this game should not have had: \(d)")
        }
    }

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
    /// Tell Wine to prefer a particular DLL, or stop preferring it.
    ///
    /// `Game.dllOverrides` has been honoured by the launcher since it existed
    /// and set by nothing: no command, no screen, no default beyond the empty
    /// dictionary in the initialiser. A capability that only the launcher can
    /// see is not a capability. This is the same fault as `runtimeLocked` —
    /// written in two places and read in none — with the halves swapped.
    ///
    /// Mode is Wine's own vocabulary: `n` native first, `b` builtin first,
    /// `n,b` native then builtin, and the empty string disables the DLL
    /// entirely. Kept as Wine writes it rather than translated, because anyone
    /// who needs this is reading a forum post that uses those letters.
    @discardableResult
    public func setDLLOverride(_ game: Game, dll: String, mode: String?) throws -> [String: String] {
        let name = dll.lowercased()
            .replacingOccurrences(of: ".dll", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw DecanterError.usage("'\(dll)' is not a DLL name. Use something like winhttp or version.")
        }
        if let mode, !["n", "b", "n,b", "b,n", ""].contains(mode) {
            throw DecanterError.usage(
                "'\(mode)' is not a Wine override mode. Use n (native), b (builtin), n,b, or an empty value to disable the DLL.")
        }
        var result: [String: String] = [:]
        try store.mutate { s in
            guard let i = s.games.firstIndex(where: { $0.id == game.id }) else { return }
            if let mode { s.games[i].dllOverrides[name] = mode }
            else { s.games[i].dllOverrides.removeValue(forKey: name) }
            result = s.games[i].dllOverrides
        }
        note(game.bottleID, "dll override \(name) -> \(mode ?? "(removed)")")
        return result
    }

    /// The proxy DLLs a mod loader beside this game will try to load through.
    /// Named so the interface can say which one it found rather than assuming
    /// winhttp, which is only the most common choice.
    public func modLoaderProxies(_ game: Game) -> [String] {
        Launcher.doorstopProxies(besideExecutable: game.exePath)
    }

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
        recordClosures(plan, bottle: bottle)
        try launcher.launch(plan)
        return plan
    }

    // MARK: - Recommendation (no launching)

    public struct Recommendation: Sendable {
        public var runtimeKind: RuntimeKind
        public var backend: GraphicsBackend
        public var reasons: [String] = []
        public var caveats: [String] = []
        /// Set when the person has already chosen this game's setup by hand.
        /// `runtimeLocked` was written in two places and read in none, so a
        /// deliberate choice was re-argued on every screen. An override is a
        /// preference: it sticks, and it stops the app pushing back.
        public var overriddenByUser = false
        /// Where this came from, which is a fact, rather than how strongly it
        /// is felt, which was not one.
        ///
        /// This replaced a confidence badge reading "high" / "medium" / "low".
        /// The trouble with that scale was not its calibration but its type:
        /// two things can both be "medium" for entirely different reasons, and
        /// the word gave no way to tell a rule nobody has ever tested from an
        /// observation on an identical machine. Provenance cannot be wrong in
        /// the same way — it says what happened, and the reader decides what
        /// that is worth.
        public var provenance: Provenance = .inferred

        /// The second option, when there is a real one.
        ///
        /// An endorsement outranks a generalisation drawn from this Mac's own
        /// history, but it does not get to erase it. When one displaces the
        /// other, both are offered — endorsed first, the machine's own answer
        /// second — rather than the loser vanishing.
        public var alternative: Alternative?

        /// A note attached to an endorsed row: someone ran this and said what
        /// to expect. The single place free text exists anywhere in the
        /// knowledge base, and it can only be written by a key holder, which is
        /// what keeps "no game is ever named" true.
        public var note: String?

        public init(runtimeKind: RuntimeKind, backend: GraphicsBackend,
                    reasons: [String] = [], caveats: [String] = [],
                    overriddenByUser: Bool = false, provenance: Provenance = .inferred) {
            self.runtimeKind = runtimeKind; self.backend = backend
            self.reasons = reasons; self.caveats = caveats
            self.overriddenByUser = overriddenByUser; self.provenance = provenance
        }
    }

    /// The second choice, kept beside the first.
    public struct Alternative: Sendable {
        public var runtimeKind: RuntimeKind
        public var backend: GraphicsBackend
        public var why: String
        public init(runtimeKind: RuntimeKind, backend: GraphicsBackend, why: String) {
            self.runtimeKind = runtimeKind; self.backend = backend; self.why = why
        }
    }

    /// Where a recommendation came from.
    public enum Provenance: String, Codable, Sendable, CaseIterable {
        /// This Mac has run it.
        case seenHere
        /// Someone ran it and signed for it. See `Endorsement`.
        case verified
        /// Arrived in someone else's export.
        case sharedByOthers
        /// A starting assumption Decanter shipped with, not yet confirmed here.
        case shipped
        /// Worked out from what the files say. Nothing has been observed.
        case inferred
        /// Nothing is known to work; this is the only thing that could.
        case onlyOption
        /// Nothing will work.
        case knownLimitation

        /// Short enough for a chip beside the recommendation.
        public var label: String {
            switch self {
            case .seenHere:        "seen working here"
            case .verified:        "verified"
            case .sharedByOthers:  "shared by others"
            case .shipped:         "a starting point"
            case .inferred:        "worked out from the files"
            case .onlyOption:      "the only thing that can work"
            case .knownLimitation: "known not to work"
            }
        }

        /// The same thing at length, for anyone who wants to know what the
        /// short version is standing for.
        public var detail: String {
            switch self {
            case .seenHere:
                "This Mac has run this combination and it worked."
            case .verified:
                "Someone ran this themselves and vouched for it. It is not a guess, and it is not a measurement from this Mac either."
            case .sharedByOthers:
                "This came from someone else's shared knowledge. Nobody here has confirmed it."
            case .shipped:
                "Decanter came with this as a sensible place to start. Nothing here has confirmed it yet."
            case .inferred:
                "Worked out from what the game's own files say. Nothing has been tried."
            case .onlyOption:
                "Everything else is known to fail for this kind of game. This is the only remaining possibility, not a tested answer."
            case .knownLimitation:
                "This game needs something nothing available here provides."
            }
        }
    }

    /// Picks a configuration from what the files say, with no trial and error.
    ///
    /// A game whose runtime was set by hand still gets a recommendation — it
    /// is worth being able to ask — but it is marked as overridden, and the
    /// interface does not argue with a choice already made.
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
    /// A pinned runtime that can actually run `backend`, with the component
    /// it needs staged. `nil` when either half is missing.
    func hostFor(_ backend: GraphicsBackend) -> RuntimeSpec? {
        switch backend {
        case .dxmt:
            guard DXMTInstaller(paths: paths).isStaged else { return nil }
            return store.state.runtimes.first { RuntimeManager.metalHosting(root: $0.root).looksCapable }
        default:
            return store.state.runtimes.first { $0.backends.contains(backend) }
        }
    }

    /// Which half is missing, said plainly enough to act on.
    func missingPieceFor(_ backend: GraphicsBackend) -> String {
        guard backend == .dxmt else {
            return "\(backend.label) is not available on any runtime Decanter has pinned."
        }
        let staged = DXMTInstaller(paths: paths).isStaged
        let host = store.state.runtimes.contains { RuntimeManager.metalHosting(root: $0.root).looksCapable }
        switch (staged, host) {
        case (false, false):
            return "This needs DXMT, and a Wine that can host it — the Game Porting Toolkit's Wine can, mainline Wine cannot. Neither is set up yet."
        case (false, true):
            return "This needs a DXMT build. Hand one to Decanter and it will stage it; a pinned runtime here can already host it."
        case (true, false):
            return "DXMT is staged, but no pinned runtime can host it: its Mac driver has to hand out a Cocoa view, which the Game Porting Toolkit's Wine does and mainline Wine does not."
        case (true, true):
            return "DXMT is staged and hostable — this should have been recommended, which is a bug worth reporting."
        }
    }

    /// Turns a knowledge-base answer into a recommendation.
    ///
    /// Extracted so the same conversion serves both the path that runs before
    /// the shipped "this cannot work" claim and the one that runs after it.
    /// Two copies of this drifted apart once already.
    func recommendation(from known: Knowledge.Answer, for game: Game,
                        sig: Knowledge.Signature) -> Recommendation {
        var r = Recommendation(runtimeKind: known.setup.runtimeKind, backend: known.setup.backend)
        // An endorsement's provenance is already a sentence; a match count is a
        // noun phrase that needs the lead-in. Running them through the same
        // prefix produced "this worked for someone ran this and confirmed it".
        r.reasons.append(known.tier == .verified
                         ? known.provenance.prefix(1).uppercased() + known.provenance.dropFirst() + "."
                         : "this worked for \(known.provenance)")
        r.provenance = switch (known.tier, known.seeded, known.confirmations) {
            case (.verified, _, _):  .verified
            case (.local, _, _):     .seenHere
            case (.community, true, 0): .shipped
            case (.community, _, _): .sharedByOthers
        }
        // A note on an endorsed row is the maintainer speaking, so it is
        // kept apart and shown as such rather than folded in with the
        // reasoning, which is Decanter's own voice.
        if let n = known.note {
            if r.provenance == .verified { r.note = n } else { r.reasons.append(n) }
        }
        // Offered only when it is actually a different choice, which means a
        // different runtime or a different graphics layer. Comparing whole
        // setups instead compared the layer's *version* too, so "DXMT 0.80" and
        // "DXMT, version unrecorded" came out as two options that read as the
        // same words twice. The version is Decanter's business, not a choice
        // anybody is being offered.
        if let second = known.alsoConsidered,
           second.setup.runtimeKind != known.setup.runtimeKind
            || second.setup.backend != known.setup.backend {
            r.alternative = Alternative(runtimeKind: second.setup.runtimeKind,
                                        backend: second.setup.backend,
                                        why: second.why)
        }
        for bad in knowledge.knownBad(for: sig).prefix(3) where bad.setup != known.setup {
            r.caveats.append("\(bad.setup.label): \(bad.failure.label)")
        }
        r.overriddenByUser = game.runtimeLocked
        return r
    }

    public func recommend(for game: Game) -> Recommendation {
        let d = game.detection
        let sig = Knowledge.Signature(d)
        let known = knowledge.best(for: sig, excluding: game.id)

        // Something that has actually run outranks something Decanter shipped
        // an opinion about, and this check has to come first for that to be
        // true. It did not, and the consequence was precise: a game confirmed
        // working on this Mac — and endorsed — went on being described as "not
        // known to run here", because the built-in claim that its engine needs
        // a particular graphics layer answered before the record of it working
        // was ever consulted. The rule was already written in a comment three
        // lines further down; it just ran second.
        //
        // Only a confirmed or vouched-for answer gets this. A shipped starting
        // assumption is not evidence and must not overrule another one.
        if let known, known.confirmations > 0 || known.tier == .verified {
            return recommendation(from: known, for: game, sig: sig)
        }

        // Say plainly when nothing will work. Knowing a game cannot run is far
        // more useful than being invited to try five configurations that fail.
        if let blocker = d.knownUnsupported {
            // There is one honest exception to "nothing will work": a backend
            // that implements the missing interfaces, staged, on a runtime that
            // can host it. All three have to be true, so all three are checked
            // rather than assumed from the backend existing in the enum.
            if let escape = d.unsupportedUnless, let host = hostFor(escape) {
                var r = Recommendation(runtimeKind: host.kind, backend: escape)
                r.provenance = .onlyOption
                r.reasons.append("Only \(escape.label) implements the interfaces this game needs.")
                r.reasons.append(blocker.replacingOccurrences(of: "\n", with: " "))
                r.caveats.append("Decanter has not seen this combination succeed. It is the only one that can work, not one that is known to.")
                return r
            }
            var r = Recommendation(runtimeKind: .gptk, backend: .d3dmetal)
            r.provenance = .knownLimitation
            r.reasons.append("This game will not run on any setup Decanter currently has.")
            r.reasons.append(blocker.replacingOccurrences(of: "\n", with: " "))
            if let escape = d.unsupportedUnless {
                r.caveats.append(missingPieceFor(escape))
            } else {
                r.caveats.append("Nothing to try here — it needs a translation layer that implements the missing interfaces.")
            }
            return r
        }

        // What has actually worked before beats any static rule — but how
        // closely it matched is part of the answer, not a detail. A setup drawn
        // from "this engine, any Mac" is a weaker claim than one drawn from an
        // identical machine, and saying so is the difference between a
        // recommendation and a guess wearing one's clothes.
        // Anything the knowledge base has left — a shipped starting assumption,
        // or a row from somebody else's export. Weaker than the check at the
        // top, and it runs after the shipped claim rather than before it.
        if let known {
            let r = recommendation(from: known, for: game, sig: sig)
            if known.confirmations > 0 || !known.seeded { return r }
        }

        var r = Recommendation(runtimeKind: .gptk, backend: .d3dmetal)

        // 2D engines never need a fast 3D path, and WineD3D avoids a whole
        // class of translation bugs.
        if d.engine == .renpy || d.engine == .rpgMakerNW {
            r = Recommendation(runtimeKind: .wine, backend: .wined3d)
            r.reasons.append("\(d.engine.label) is 2D — WineD3D is sufficient and the most predictable")
            if d.bitness == .x86 { r.reasons.append("32-bit, so modern Wine's WoW64 is the safer host") }
            r.overriddenByUser = game.runtimeLocked
            return r
        }

        if d.bitness == .x86 {
            r = Recommendation(runtimeKind: .wine, backend: .wined3d)
            r.reasons.append("32-bit: Wine 11's WoW64 handles these more reliably than GPTK's 2022 base")
            r.caveats.append("If it is a DirectX 9 game, DXVK is usually faster — worth trying second")
            r.overriddenByUser = game.runtimeLocked
            return r
        }

        if d.usesVideo {
            r = Recommendation(runtimeKind: .gptk, backend: .wined3d)
            r.reasons.append("this game plays video, and D3DMetal has no ID3D11Multithread — video fails on it")
            r.reasons.append("WineD3D is a complete D3D11 implementation, so the video player works")
            r.caveats.append("WineD3D runs on OpenGL and is noticeably slower; if you never watch the cutscenes, D3DMetal will be faster")
            r.overriddenByUser = game.runtimeLocked
            return r
        }

        r.reasons.append("\(d.engine.label), 64-bit: D3DMetal gives feature level 11_1 and native Metal speed")
        if d.graphicsAPIs.contains("d3d12.dll") {
            r.reasons.append("D3D12 is referenced, which only D3DMetal can translate here")
        }
        r.caveats.append("If the game turns out to play video, switch to WineD3D — D3DMetal cannot drive Unity's video player")
        if d.confidence < 0.6 { r.caveats.append("Decanter is not very sure what kind of game this is, so treat this as a starting point") }
        r.overriddenByUser = game.runtimeLocked
        return r
    }

    /// Applies the recommendation without launching anything.
    @discardableResult
    public func applyRecommendation(_ game: Game, progress: (String) -> Void = { _ in }) throws -> Recommendation {
        let rec = recommend(for: game)
        guard let rt = store.state.runtimes.first(where: { $0.kind == rec.runtimeKind })
                ?? store.state.runtimes.first else { throw DecanterError.noRuntime("none pinned") }
        // Passing nil recorded a setup with no layer version, while
        // Setup.layerVersion exists precisely because DXVK 1.10.3 and 2.x are
        // not the same answer. Name the version that will actually be staged.
        let version = rec.backend == .dxvk ? DXVKInstaller(paths: paths).defaultVersion : nil
        try apply(Candidate(runtimeID: rt.id, backend: rec.backend, dxvkVersion: version),
                  to: game, progress: progress)
        return rec
    }

    /// Remembers that a configuration worked, both for this game and for every
    /// future game with the same profile. This is what stops a new title from
    /// starting the guessing over again.
    public func rememberWorking(_ game: Game) throws {
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else { return }
        let s = setup(for: b, runtime: rt)
        try mutateKnowledge { k in
            k.recordSuccess(signature: Knowledge.Signature(game.detection),
                            gameID: game.id, setup: s)
        }
        // Kept per game as well as in the knowledge base. The two answer
        // different questions: the knowledge base knows what works for this
        // *kind* of game, and this knows what this one was running the last
        // time somebody said it was fine.
        try store.mutate { st in
            if let i = st.games.firstIndex(where: { $0.id == game.id }) {
                st.games[i].knownGood = .init(runtimeID: rt.id, backend: b.backend,
                                              layerVersion: s.layerVersion)
            }
        }
        note(b.id, "confirmed working: \(rt.id) + \(b.backend.label)")
    }

    /// Parks the question Decanter could not answer for itself.
    ///
    /// Called only where a launch was *not* recorded — a clean launch is
    /// recorded and asks nothing, because confirming the obvious is how a
    /// prompt trains people to dismiss it unread.
    public func askAbout(_ game: Game, observed: String) {
        guard let b = store.bottle(game.bottleID) else { return }
        let rec = recommend(for: game)
        let onRec = rec.runtimeKind == store.runtime(b.runtimeID)?.kind && rec.backend == b.backend
        try? Verdict(paths: paths).park(.init(
            gameID: game.id, gameName: game.name, runtimeID: b.runtimeID,
            backend: b.backend, observed: observed, onRecommendation: onRec,
            suggested: onRec ? nil : "\(rec.backend.plainName) graphics"))
    }

    /// Records what the person said, and stops asking.
    ///
    /// A failure on a setup nobody suggested is recorded as a failure of *that*
    /// setup and nothing else. The suggestion stays unjudged, because it was
    /// never run — which is a different thing from having been tried and found
    /// wanting, and the two must not become the same row.
    @discardableResult
    public func settleVerdict(worked: Bool, failure: Knowledge.Failure = .unspecified,
                              switchReason: Verdict.SwitchReason? = nil) throws -> String {
        let v = Verdict(paths: paths)
        guard let p = v.pending() else {
            throw DecanterError.notFound("there is no launch waiting to be judged")
        }
        guard let game = store.state.games.first(where: { $0.id == p.gameID }) else {
            v.clear()
            throw DecanterError.notFound("that game is no longer in the library")
        }
        defer { v.clear() }
        if worked {
            try rememberWorking(game)
            return "recorded: \(p.backend.plainName) graphics works for \(game.name), and for games like it"
        }
        try rememberFailed(game, failure: failure)
        var out = "recorded: \(p.backend.plainName) graphics did not work here"
        if !p.onRecommendation, let suggested = p.suggested {
            out += ". Decanter suggested \(suggested), which has not been tried — this says nothing about it"
        }
        if let switchReason, switchReason != .unstated {
            note(game.bottleID, "moved off the suggestion: \(switchReason.label)")
        }
        return out
    }

    /// What going back to the last working setup would involve, or nil when
    /// there is nothing to go back to or it is already there.
    public func restorable(_ game: Game) -> Game.KnownGood? {
        guard let good = game.knownGood else { return nil }
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else { return good }
        let now = setup(for: b, runtime: rt)
        let unchanged = b.runtimeID == good.runtimeID
                     && b.backend == good.backend
                     && now.layerVersion == good.layerVersion
        return unchanged ? nil : good
    }

    /// Puts a game back on the last configuration it was confirmed working on.
    ///
    /// Not automatic, and not offered as a guess: it is offered when something
    /// has stopped working and there is a specific, dated configuration to
    /// return to. "It worked on Tuesday" is a named cause.
    @discardableResult
    public func restoreKnownGood(_ game: Game, progress: (String) -> Void = { _ in }) throws -> Game.KnownGood {
        guard let good = game.knownGood else {
            throw DecanterError.notFound(
                "nothing has been confirmed working for \(game.name) yet, so there is nothing to go back to")
        }
        guard store.state.runtimes.contains(where: { $0.id == good.runtimeID }) else {
            throw DecanterError.noRuntime(
                "\(good.runtimeID) is no longer here, so \(game.name) cannot be put back on it")
        }
        try apply(Candidate(runtimeID: good.runtimeID, backend: good.backend,
                            dxvkVersion: good.backend == .dxvk ? good.layerVersion : nil),
                  to: game, progress: progress)
        return good
    }

    public func rememberFailed(_ game: Game, failure: Knowledge.Failure = .unspecified) throws {
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else { return }
        try mutateKnowledge { k in
            k.recordFailure(signature: Knowledge.Signature(game.detection),
                            gameID: game.id, setup: setup(for: b, runtime: rt),
                            failure: failure)
        }
    }

    /// Marks what this Mac has already seen work as vouched for.
    ///
    /// Only a setup that has actually been recorded as working can be endorsed,
    /// and that is the point rather than a limitation. "Verified" is meant to
    /// carry exactly one claim — someone ran this and watched it work — so
    /// endorsing something nobody has run would make the tier into the guess it
    /// exists to be distinguishable from.
    ///
    /// The note is signed along with everything else. Editing it later breaks
    /// the endorsement outright, which is the safe failure: the alternative is
    /// quietly changing what was vouched for.
    @discardableResult
    public func endorse(_ game: Game, note: String? = nil) throws -> Knowledge.Observation {
        guard Endorsement.canEndorse else { throw Endorsement.KeyError.noPrivateKey }
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else {
            throw DecanterError.notFound("this game has no environment to describe")
        }
        let sig = Knowledge.Signature(game.detection)
        let s = setup(for: b, runtime: rt)
        guard var row = knowledge.observations.first(where: {
            $0.signature == sig && $0.setup == s && $0.worked && !$0.seeded
        }) else {
            throw DecanterError.notFound(
                "nothing here records this setup as working yet. Run the game, say it worked, "
                + "and then it can be endorsed \u{2014} verified has to mean somebody ran it")
        }
        // An empty note is a request to remove one, not an absence of one.
        // `--note ""` used to be filtered out by the same test that ignored a
        // missing flag, so a note could be written and never taken back — and
        // re-endorsing without a note silently re-signed the old text, which
        // reads exactly like Decanter inventing prose of its own.
        if let note { row.note = note.isEmpty ? nil : note }
        row.endorsement = try Endorsement.sign(row)
        try mutateKnowledge { $0.record(row) }
        return row
    }

    // MARK: - Writing what has been learned

    private var knowledgeLockPath: URL { paths.root.appending(path: "knowledge.lock") }

    /// Change the knowledge base and write it, without discarding what another
    /// process wrote in the meantime.
    ///
    /// `Store.mutate` has done this for the library since the beginning, with
    /// the reason in a comment: "The GUI and the CLI are routinely open at the
    /// same time; without this, whichever writes last silently discards the
    /// other's changes." Every word of that was true of the knowledge base too,
    /// and it had none of the protection — `knowledge.save` wrote whatever was
    /// in memory over whatever was on disk.
    ///
    /// The consequence was not theoretical and not subtle. An app left open
    /// holds the knowledge it read at launch. An endorsement made at the prompt
    /// afterwards lands on disk, and then the next thing done in that window —
    /// confirming a launch, anything at all — writes the launch-time copy back
    /// over it. The endorsement disappears with nothing said, and it is the one
    /// thing here that cannot be reconstructed without the private key. It
    /// happened twice on the maintainer's own Mac while this was being written.
    ///
    /// So: take the lock, adopt the disk copy, apply the change to *that*, and
    /// write. The change is expressed as a function of the current state rather
    /// than as a finished value, because a finished value computed before the
    /// lock is exactly the stale write this exists to prevent.
    public func mutateKnowledge(_ body: (inout Knowledge) throws -> Void) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: knowledgeLockPath.path) {
            fm.createFile(atPath: knowledgeLockPath.path, contents: nil)
        }
        let fd = open(knowledgeLockPath.path, O_RDWR | O_CREAT, 0o644)
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        if fd >= 0 { _ = flock(fd, LOCK_EX) }

        var disk = Knowledge.load(at: paths.knowledgePath)
        try body(&disk)
        try disk.save(to: paths.knowledgePath)
        knowledge = disk
    }

    // MARK: - One decision, in one place

    /// What to do about this game's setup, as a single answer.
    ///
    /// The app used to draw up to three cards about this at once: a warning
    /// that the game was not known to run, an offer to go back to what last
    /// worked, and a recommendation to try something else — each rendered by a
    /// different view from a different source, stacked, all of them about the
    /// same decision and sometimes disagreeing about it. Three ways to say one
    /// thing is not three times the help; it is a reader deciding which card to
    /// believe.
    ///
    /// So the decision is made once, here, where it can be tested without a
    /// window. The card is a rendering of this, and has no opinions of its own.
    public struct SetupAdvice: Sendable {
        public enum Kind: Sendable {
            /// Nothing to say — the game is on the best thing available.
            case settled
            /// It worked on something else before. Going back is the offer.
            case goBack
            /// Something else is expected to work better than what it is on.
            case tryThis
            /// Nothing here is known to run it, and there is nothing to press.
            case stuck
        }
        public var kind: Kind = .settled
        public var headline = ""
        /// The plain reason, in one or two sentences.
        public var explanation = ""
        /// Why Decanter believes it — the provenance, the date, the note.
        public var evidence: [String] = []
        /// What the button says. `nil` when there is nothing to do.
        public var actionLabel: String?
        /// The thing that has to stay true even while acting on this.
        public var caution: String?
        public var provenance: Provenance = .inferred
        public var backend: GraphicsBackend?
        public var isRestore = false
    }

    public func advice(for game: Game) -> SetupAdvice {
        var a = SetupAdvice()
        let rec = recommend(for: game)
        a.provenance = rec.provenance
        a.backend = rec.backend

        let bottle = store.bottle(game.bottleID)
        let runtime = bottle.flatMap { store.runtime($0.runtimeID) }
        let onRecommended = rec.overriddenByUser
            || (runtime?.kind == rec.runtimeKind && bottle?.backend == rec.backend)

        // Going back outranks trying something. A setup this game was actually
        // seen working on is a stronger claim than any recommendation, and
        // offering both at once asks the reader to choose between Decanter's
        // memory and Decanter's advice.
        if let good = restorable(game) {
            a.kind = .goBack
            a.isRestore = true
            a.headline = "Go back to what worked"
            a.explanation = "\(game.name) last ran on \(good.label). It is on something else now."
            a.evidence.append("Confirmed \(good.confirmedAt.formatted(date: .abbreviated, time: .shortened)).")
            a.caution = "Your saves are kept. The Windows environment is rebuilt around them."
            a.actionLabel = "Go Back"
            a.backend = good.backend
            return a
        }

        // Nothing will run it, and nothing can be pressed. Say so and stop —
        // an offer here would be an invitation to try things that are already
        // known to fail.
        if rec.provenance == .knownLimitation {
            a.kind = .stuck
            a.headline = "Not known to run here"
            a.explanation = rec.reasons.dropFirst().first ?? rec.reasons.first ?? ""
            if let missing = rec.caveats.first { a.evidence.append(missing) }
            return a
        }

        guard !onRecommended else { return a }

        a.kind = .tryThis
        a.headline = rec.provenance == .onlyOption
            ? "Only \(rec.backend.plainName) graphics can run this"
            : "Try \(rec.backend.plainName) graphics"
        a.explanation = rec.provenance == .onlyOption
            ? (rec.reasons.dropFirst().first ?? rec.reasons.first ?? "")
            : (rec.reasons.first ?? "")
        if let note = rec.note { a.evidence.append(note) }
        a.evidence.append(rec.provenance.detail)
        a.caution = rec.caveats.first
        a.actionLabel = "Use This"
        return a
    }

    // MARK: - Endorsement, per game

    /// The endorsement covering the setup this game is on right now, if there
    /// is one and it still verifies.
    ///
    /// The app had no way to see this at all: `endorse list` existed only at
    /// the prompt, so the strongest thing Decanter can say about a setup was
    /// invisible on the screen where that setup is chosen.
    public func endorsement(for game: Game) -> Knowledge.Observation? {
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else { return nil }
        let sig = Knowledge.Signature(game.detection)
        let now = setup(for: b, runtime: rt)
        return knowledge.observations.first {
            $0.signature == sig && $0.setup == now && $0.worked
                && Endorsement.isVerified($0)
        }
    }

    /// Whether this Mac could endorse this game's current setup.
    ///
    /// Two things have to hold, and they are different questions: the Mac has
    /// to hold a key, and the setup has to be one that was actually seen
    /// working here. Verified means somebody ran it — an endorsement of
    /// something nobody has run would be the one thing the tier must never be.
    public func canEndorse(_ game: Game) -> Bool {
        guard Endorsement.canEndorse else { return false }
        guard let b = store.bottle(game.bottleID), let rt = store.runtime(b.runtimeID) else { return false }
        let sig = Knowledge.Signature(game.detection)
        let now = setup(for: b, runtime: rt)
        return knowledge.observations.contains {
            $0.signature == sig && $0.setup == now && $0.worked && !$0.seeded
        }
    }

    /// Withdraws an endorsement, leaving the observation itself alone.
    ///
    /// Somebody has to be able to take back a claim they signed — a key that
    /// can only ever add is a key whose holder cannot correct themselves. The
    /// observation stays, because it is still true that this ran here; what
    /// goes is the vouching, and the note, which was part of what was signed.
    @discardableResult
    public func revokeEndorsement(_ game: Game) throws -> Bool {
        let sig = Knowledge.Signature(game.detection)
        var found = false
        try mutateKnowledge { k in
            for i in k.observations.indices
            where k.observations[i].signature == sig
                && k.observations[i].endorsement?.isEmpty == false {
                k.observations[i].endorsement = nil
                k.observations[i].note = nil
                found = true
            }
        }
        return found
    }

    /// Every endorsed row, with whether its signature still checks out.
    ///
    /// A signature that no longer verifies is worth surfacing rather than
    /// hiding: it means the row was edited after it was vouched for, or that
    /// this build carries a different key than the one that signed it.
    public func endorsements() -> [(observation: Knowledge.Observation, valid: Bool)] {
        knowledge.observations
            .filter { $0.endorsement?.isEmpty == false }
            .map { ($0, Endorsement.isVerified($0)) }
    }

    /// The setup a bottle is actually running, including the graphics layer's
    /// version — DXVK 1.10.3 and DXVK 2.x are different answers, and recording
    /// them as one is how a knowledge base learns something untrue.
    func setup(for bottle: Bottle, runtime: RuntimeSpec) -> Knowledge.Setup {
        let version: String? = switch bottle.backend {
            case .dxvk: DXVKInstaller(paths: paths).installedVersion(in: bottle.prefixPath)
            case .dxmt: DXMTInstaller(paths: paths).installedVersion(in: bottle.prefixPath)
            default:    nil
        }
        return .init(runtimeKind: runtime.kind, backend: bottle.backend, layerVersion: version)
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
        // Writing the field directly changed what Decanter *said* the game was
        // using without changing what the prefix actually had — no DXVK or DXMT
        // install, no DXMT marker. That is the same "records one thing, runs
        // another" fault already fixed in setRuntime. Go through setBackend, so
        // there is one implementation of switching and it cannot drift.
        // lockRuntime is false: Decanter applying its own recommendation is not
        // the user making a choice, and must not read as one.
        // Re-read the game: a rederive above replaced the bottle, and passing
        // the caller's stale copy is how a switch lands on the old prefix.
        let fresh = store.state.games.first { $0.id == game.id } ?? game
        _ = try setBackend(fresh, c.backend, lockRuntime: false, progress: progress)
        if c.backend == .dxvk, let v = c.dxvkVersion {
            _ = try? setDXVK(fresh, version: v)
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
