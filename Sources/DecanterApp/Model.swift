import SwiftUI
import DecanterKit

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var bottles: [Bottle] = []
    @Published var health: Engine.Health?
    /// What Decanter has and what it is missing, in plain language. Drives the
    /// Setup page and the first-run wizard.
    @Published var readiness: Readiness?

    @Published var busy: String?              // non-nil while a long task runs
    @Published var lastError: String?

    /// What each action did, kept so "what have I already tried?" is answerable.
    /// Error recovery was the weak point: an action would run, fail, and leave
    /// nothing on screen once the next thing happened.
    struct Activity: Identifiable, Sendable {
        enum Outcome: Sendable { case running, succeeded, failed }
        let id = UUID()
        let started = Date()
        var label: String
        var outcome: Outcome = .running
        var detail: String?
        var finished: Date?
        var duration: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }
    }
    @Published var activity: [Activity] = []
    /// Key of the action currently running, so its own button can show a
    /// spinner instead of the whole pane going quietly disabled.
    @Published var activeAction: String?

    func isRunning(_ key: String) -> Bool { activeAction == key }
    /// Most recent finished activity, for the inline result line.
    var lastActivity: Activity? { activity.first { $0.outcome != .running } }
    @Published var running: Set<UUID> = []
    @Published var diagnosis: [UUID: Diagnostics.Report] = [:]
    @Published var strays: [WineReaper.Stray] = []
    @Published var mods: [UUID: ModInspector.Status] = [:]
    /// Only worth interrupting the user for: pinned CPU, or running for hours.
    var leakedWine: [WineReaper.Stray] { strays.filter { $0.cpu >= 50 || $0.age > 3600 } }

    private var engine: Engine?
    private var processes: [UUID: Process] = [:]

    init() { reload() }

    /// Whether the first-run wizard should appear. Deliberately *not* "is
    /// anything missing" — Apple graphics and Vulkan graphics are optional, and
    /// a modal that keeps reappearing because an optional piece is absent is a
    /// nag, not a wizard.
    var setupNeeded: Bool {
        guard let r = readiness else { return true }
        return !r.ready
    }

    func reload() {
        do {
            let e = try engine ?? Engine()
            engine = e
            games = e.store.state.games.sorted { $0.name < $1.name }
            bottles = e.store.state.bottles
            health = e.doctor()
            readiness = e.readiness()
            var recs: [UUID: Engine.Recommendation] = [:]
            for g in games { recs[g.id] = e.recommend(for: g) }
            recommendations = recs
            // Cheap enough to refresh with everything else, and it is the only
            // way a leaked Wine session ever becomes visible: it keeps running
            // after the app quits, so nothing else in the UI would show it.
            strays = e.strayWineProcesses()
            // Just a directory listing per game, so it costs nothing to keep
            // current, and a mod that broke on the last run should be visible
            // before the user launches it again.
            var m: [UUID: ModInspector.Status] = [:]
            for g in games { m[g.id] = ModInspector().inspect(game: g) }
            mods = m
        } catch {
            lastError = error.localizedDescription
        }
    }

    func bottle(for game: Game) -> Bottle? { bottles.first { $0.id == game.bottleID } }

    /// One entry point for every long operation, so the UI can never get out
    /// of sync with the engine and errors always surface in the same place.
    private func perform(_ label: String, key: String? = nil,
                         _ work: @escaping @Sendable (Engine) throws -> String?,
                         then: (@MainActor () -> Void)? = nil) {
        guard let e = engine else { return }
        busy = label; lastError = nil; activeAction = key
        let entry = Activity(label: label)
        activity.insert(entry, at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
        Task.detached(priority: .userInitiated) {
            var summary: String?
            var failure: String?
            do { summary = try work(e) }
            catch { failure = error.localizedDescription }
            await MainActor.run {
                if let i = self.activity.firstIndex(where: { $0.id == entry.id }) {
                    self.activity[i].outcome = failure == nil ? .succeeded : .failed
                    self.activity[i].detail = failure ?? summary
                    self.activity[i].finished = Date()
                }
                self.lastError = failure
                self.busy = nil; self.activeAction = nil
                self.reload(); self.refreshSaves(); then?()
            }
        }
    }

    func runSetup() {
        perform("Preparing your Mac for Windows games…", key: "setup") { e in
            let pinned = try e.pinAll()
            try e.buildTemplate()
            return "Set up \(plural(pinned.count, "engine")) and prepared a clean Windows environment"
        }
    }

    /// Takes Decanter's own copy of everything already installed on this Mac.
    /// Separate from `runSetup` so the Setup page can offer it on its own —
    /// someone who has just installed Wine should not have to rebuild the
    /// template to pick it up.
    func pinDiscovered() {
        perform("Taking a copy of the Wine builds on this Mac…", key: "pin") { e in
            let pinned = try e.pinAll()
            guard !pinned.isEmpty else { return "Nothing new found" }
            return "Added " + pinned.map { Engine.friendly($0) }.joined(separator: ", ")
        }
    }

    func buildTemplate() {
        perform("Building a clean Windows environment…", key: "template") { e in
            try e.buildTemplate()
            return "Ready — new games clone this in under a second"
        }
    }

    /// Everything a user can hand Decanter goes through one path, so a drop
    /// and a file-picker choice cannot behave differently.
    func accept(path: URL) {
        perform("Reading \(path.lastPathComponent)…", key: "accept") { e in
            try e.accept(droppedPath: path)
        }
    }

    func chooseSetupFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Wine build, a Game Porting Toolkit disk image, or a DXVK archive"
        panel.prompt = "Use This"
        if panel.runModal() == .OK, let url = panel.url { accept(path: url) }
    }

    func installRosetta() {
        perform("Installing Rosetta 2…", key: "rosetta") { e in
            try e.installRosetta()
        }
    }

    /// The user goes and gets it; Decanter never fetches anything itself.
    func openSource(_ url: URL) { NSWorkspace.shared.open(url) }

    func add(path: URL) {
        perform("Inspecting \(path.lastPathComponent)…", key: "add") { e in
            let g = try e.add(path: path)
            return "Added \(g.name) — \(g.detection.engine.label), \(g.detection.bitness.label)"
        }
    }

    func play(_ game: Game, verbose: Bool = false) {
        guard let e = engine else { return }
        lastError = nil
        do {
            let plan = try e.run(game, verbose: verbose)
            running.insert(game.id)
            // Watch for exit so the running indicator is truthful, and read the
            // log back automatically if it dies early.
            Task.detached {
                let started = Date()
                // Wine takes a few seconds to get a process on the table. The
                // watcher used to treat "not there yet" as "already exited", so
                // Running flicked back to Play and the Stop button vanished
                // about a second after launch, while the game was still coming
                // up. Wait for it to appear before watching for it to leave.
                var appeared = false
                let appearBy = Date().addingTimeInterval(45)
                while true {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if Self.wineAlive(prefix: plan.bottle.prefixPath) {
                        appeared = true
                        continue
                    }
                    if !appeared {
                        guard Date() > appearBy else { continue }
                        // Never showed up at all: that is a failure to launch,
                        // and the log is the only place that says why.
                        let rep = Diagnostics().analyse(logAt: plan.logFile)
                        await MainActor.run {
                            self.running.remove(game.id)
                            self.diagnosis[game.id] = rep
                            if rep.isEmpty {
                                self.lastError = "\(game.name) did not start, and its log says nothing. Try Troubleshoot Launch under Saves & Maintenance."
                            }
                        }
                        return
                    }
                    let rep = Diagnostics().analyse(logAt: plan.logFile)
                    let quick = Date().timeIntervalSince(started) < 12
                    await MainActor.run {
                        self.running.remove(game.id)
                        if quick && !rep.isEmpty { self.diagnosis[game.id] = rep }
                    }
                    return
                }
            }
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Wine detaches from the process we spawn, so liveness is judged by
    /// whether any process still holds this prefix.
    nonisolated static func wineAlive(prefix: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/pgrep")
        p.arguments = ["-f", prefix.lastPathComponent]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return !String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func rederive(_ game: Game) {
        perform("Rebuilding \(game.name)'s Windows environment…", key: "rebuild") { e in
            let b = try e.rederive(game)
            return "Windows environment rebuilt from the \(b.runtimeID) template; saves kept"
        }
    }

    func importSaves(_ game: Game, from url: URL) {
        perform("Importing saves into \(game.name)…", key: "import") { e in
            let r = try e.importSaves(into: game, from: url)
            return "Imported \(plural(r.filesCopied, "save file"))"
        }
    }

    func setBackend(_ game: Game, _ backend: GraphicsBackend) {
        perform("Switching \(game.name) to \(Help.plainName(backend)) graphics…", key: "backend") { e in
            // Through the engine, not by setting the field: DXVK and DXMT are
            // real DLLs in the prefix and swapping between them needs an
            // install, not a relabel.
            _ = try e.setBackend(game, backend)
            return "Graphics is now \(Help.plainName(backend))"
        }
    }

    func setRuntime(_ game: Game, _ runtimeID: String) {
        perform("Switching \(game.name)'s engine…", key: "runtime") { e in
            _ = try e.setRuntime(game, to: runtimeID)
            return "Engine is now \(runtimeID)"
        }
    }

    var pinnedRuntimes: [RuntimeSpec] { health?.pinnedRuntimes ?? [] }

    /// Recently played first — the list should answer "what do I play now",
    /// with never-played games after, alphabetically.
    var gamesByRecency: [Game] {
        games.sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.name < b.name
            }
        }
    }

    @Published var saveOverview: [UUID: Engine.SaveOverview] = [:]
    @Published var saveFiles: [UUID: [SaveStore.Finding]] = [:]
    @Published var snapshots: [UUID: [SaveStore.Snapshot]] = [:]
    @Published var externalised: Set<UUID> = []
    @Published var searchHits: [Engine.SaveHit] = []
    @Published var lastReport: URL?
    @Published var reportNote: String?

    // Decanter never captures the screen, so it never asks for permission.

    @Published var recommendations: [UUID: Engine.Recommendation] = [:]

    /// The recommended setup for a game, and whether it is already applied.
    func recommendation(for game: Game) -> Engine.Recommendation? { recommendations[game.id] }

    func refreshRecommendations() {
        guard let e = engine else { return }
        var out: [UUID: Engine.Recommendation] = [:]
        for g in games { out[g.id] = e.recommend(for: g) }
        recommendations = out
    }

    func isOnRecommended(_ game: Game) -> Bool {
        guard let rec = recommendations[game.id],
              let b = bottle(for: game),
              let rt = pinnedRuntimes.first(where: { $0.id == b.runtimeID }) else { return false }
        return rt.kind == rec.runtimeKind && b.backend == rec.backend
    }

    func applyRecommendation(_ game: Game) {
        perform("Applying the recommended setup for \(game.name)…", key: "recommend") { e in
            let r = try e.applyRecommendation(game)
            return "Now using \(Help.plainName(r.backend)) graphics"
        }
    }

    /// Records the current setup as working, which also teaches future games.
    @Published var executableChoices: [UUID: [Detector.ExecutableChoice]] = [:]

    /// Games whose folder is being scanned right now, so the picker can say
    /// "looking" instead of silently rendering nothing.
    @Published var scanningExecutables: Set<UUID> = []

    /// Whether we have looked yet, kept separate from what we found.
    ///
    /// The picker read `executableChoices[id] ?? []`, which collapses "not
    /// scanned yet" and "scanned, found one" into the same empty array — so
    /// between the view appearing and the scan starting it confidently
    /// announced "only executable in this folder", and corrected itself a
    /// moment later. Reopening the app appeared to fix it because by then the
    /// cache was warm.
    enum ExecutableState {
        case unknown                       // not looked yet
        case scanning
        case loaded([Detector.ExecutableChoice])
    }

    func executableState(_ game: Game) -> ExecutableState {
        if scanningExecutables.contains(game.id) { return .scanning }
        guard let found = executableChoices[game.id] else { return .unknown }
        return .loaded(found)
    }

    /// Scanning a game folder touches disk, so do it off the main thread and
    /// cache the result. `force` re-scans after the chosen executable changes.
    func loadExecutables(_ game: Game, force: Bool = false) {
        guard let e = engine else { return }
        if !force, executableChoices[game.id] != nil { return }
        guard !scanningExecutables.contains(game.id) else { return }
        scanningExecutables.insert(game.id)
        Task.detached(priority: .utility) {
            let list = e.executables(for: game)
            await MainActor.run {
                self.executableChoices[game.id] = list
                self.scanningExecutables.remove(game.id)
            }
        }
    }

    /// Registers another executable from the same folder as a game in its own
    /// right, with its own prefix and settings.
    ///
    /// Only ever on request. Decanter cannot tell a second game from a config
    /// tool, a crash handler or a prerequisite installer, and guessing would
    /// fill the library with junk — so the choice stays with the person who
    /// knows what the folder contains.
    func addAsSeparateGame(_ url: URL) {
        perform("Adding \(url.lastPathComponent) as its own game…", key: "addSeparate") { e in
            let g = try e.add(path: url)
            return "Added \(g.name) with its own Windows environment — \(g.detection.engine.label)"
        }
    }

    func setExecutable(_ game: Game, _ url: URL) {
        // The old list stays on screen until the new one lands. Clearing it up
        // front made the picker disappear for good: nothing re-scanned, and
        // .task only fires when the view first appears.
        perform("Switching \(game.name) to \(url.lastPathComponent)…", key: "setexe") { e in
            _ = try e.setExecutable(game, to: url)
            return "Launches \(url.lastPathComponent) from now on"
        } then: { [weak self] in
            self?.loadExecutables(game, force: true)
        }
    }

    /// Runs a different executable in the same prefix without changing the game.
    func runOther(_ game: Game, _ url: URL) {
        guard let e = engine else { return }
        lastError = nil
        do {
            _ = try e.runOther(game, exe: url)
            reportNote = "Running \(url.lastPathComponent) inside \(game.name)'s Windows environment."
        } catch { lastError = error.localizedDescription }
    }

    func redetect(_ game: Game) {
        perform("Re-inspecting \(game.name)…", key: "redetect") { e in
            let d = try e.redetect(game)
            return "\(d.engine.label), \(d.bitness.label)\(d.modded ? ", modded" : "")"
        }
    }

    func markWorking(_ game: Game) {
        perform("Remembering this setup…", key: "remember") { e in
            try e.rememberWorking(game)
            return "Recorded as working for games with this profile"
        }
    }

    /// Builds the pasteable bundle and puts it on the clipboard, because the
    /// whole point is having something to hand over.
    func makeReport(_ game: Game) {
        perform("Collecting diagnostics…", key: "report") { e in
            let rep = try e.report(game)
            let text = (try? String(contentsOf: rep, encoding: .utf8)) ?? ""
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.lastReport = rep
            }
            return "Report copied to the clipboard (\(text.count) characters)"
        }
    }

    func revealReport() {
        guard let r = lastReport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r])
    }

    var savesRoot: URL { engine?.paths.saves ?? URL(filePath: NSHomeDirectory()) }

    /// Scanning every prefix is disk work, so it happens off the main thread
    /// and only when the Saves surface is actually looking.
    func refreshSaves() {
        guard let e = engine else { return }
        let games = games
        Task.detached(priority: .utility) {
            var ov: [UUID: Engine.SaveOverview] = [:]
            var files: [UUID: [SaveStore.Finding]] = [:]
            var snaps: [UUID: [SaveStore.Snapshot]] = [:]
            var ext: Set<UUID> = []
            for g in games {
                let d = e.discoverSaves(g)
                files[g.id] = d.files.sorted { $0.bytes > $1.bytes }
                snaps[g.id] = e.saves.snapshots(for: g)
                if e.saves.isExternalised(game: g) { ext.insert(g.id) }
                ov[g.id] = Engine.SaveOverview(game: g.name, slug: e.saves.slug(for: g),
                                               files: d.files.count, bytes: d.totalBytes,
                                               lastModified: d.files.map(\.modified).max(),
                                               snapshots: snaps[g.id]?.count ?? 0,
                                               registryKeys: d.registryKeys.count)
            }
            let o = ov, f = files, sn = snaps, x = ext
            await MainActor.run {
                self.saveOverview = o; self.saveFiles = f
                self.snapshots = sn; self.externalised = x
            }
        }
    }

    func searchSaves(_ q: String) {
        guard let e = engine, !q.isEmpty else { searchHits = []; return }
        Task.detached(priority: .utility) {
            let hits = e.searchSaves(q)
            await MainActor.run { self.searchHits = hits }
        }
    }

    func snapshotSaves(_ game: Game) {
        perform("Snapshotting \(game.name)…", key: "snapshot") { e in
            _ = try e.snapshotSaves(game, note: "manual")
            return "Snapshot taken"
        }
    }

    func snapshotAll() {
        perform("Snapshotting every game…", key: "snapshotAll") { e in
            var n = 0
            for g in e.store.state.games where (try? e.snapshotSaves(g, note: "manual (all)")) != nil { n += 1 }
            return "Snapshotted \(plural(n, "game"))"
        }
    }

    func externaliseSaves(_ game: Game) {
        perform("Protecting \(game.name)'s saves…", key: "externalise") { e in
            let r = try e.externaliseSaves(game)
            return r.moved.isEmpty
                ? "Already protected — \(plural(r.alreadyLinked.count, "folder")) kept outside"
                : "\(plural(r.moved.count, "save folder")) moved somewhere rebuilding cannot erase"
        }
    }

    func externaliseAll() {
        perform("Protecting every game's saves…", key: "externaliseAll") { e in
            var n = 0
            for g in e.store.state.games { n += (try? e.externaliseSaves(g))?.moved.count ?? 0 }
            return "\(plural(n, "save folder")) protected across the library"
        }
    }

    func restoreSnapshot(_ game: Game, _ name: String) {
        perform("Restoring \(game.name)…", key: "restore") { e in
            let n = try e.restoreSaves(game, snapshot: name)
            return "Restored \(plural(n, "file")) from \(name)"
        }
    }

    func remove(_ game: Game, keepSaves: Bool) {
        perform("Removing \(game.name)…", key: "remove") { e in
            _ = try e.remove(game, keepSaves: keepSaves)
            return keepSaves ? "Removed; saves kept" : "Removed, saves deleted"
        }
    }

    func gc() {
        perform("Cleaning up leftovers…", key: "gc") { e in
            let r = try e.gc()
            return r.bottles == 0 ? "Nothing orphaned"
                : "Removed \(plural(r.bottles, "leftover Windows environment")), \(r.bytes / 1_048_576) MB freed"
        }
    }

    func reapWine() {
        perform("Ending leftover Wine processes…", key: "reap") { e in
            let o = e.reapWine()
            return "Ended \(plural(o.killed.count, "leftover process"))"
        }
    }

    /// Applies to every template and bottle at once. The mapping is registry
    /// data, so this is idempotent and nothing is launched.
    func fixFonts() {
        perform("Fixing fonts…", key: "fonts") { e in
            let r = e.provisionFonts()
            let n = r.reduce(0) { $0 + $1.plan.mapped.count }
            return n == 0
                ? "Every Windows font name already resolved — nothing to change"
                : "Mapped \(plural(n, "font name")) across \(plural(r.count, "game")); takes effect next launch"
        }
    }

    /// Installs Windows components a game may ask for by name.
    ///
    /// Unlike everything else here, this reaches the network: winetricks
    /// fetches the redistributables from Microsoft and friends. That is said
    /// plainly in the UI rather than buried, because the whole project
    /// otherwise downloads nothing.
    func installComponents(_ game: Game, _ verbs: [String], label: String) {
        perform("Installing \(label)…", key: "components") { e in
            let tool = e.recipes.tooling()
            guard tool.missing.isEmpty else {
                throw DecanterError.notFound("missing helper(s): \(tool.missing.joined(separator: ", "))")
            }
            let r = try e.install(game, verbs: verbs)
            if !r.failed.isEmpty && r.succeeded.isEmpty {
                throw DecanterError.notFound("\(label) failed to install")
            }
            return r.failed.isEmpty
                ? "\(label) installed"
                : "\(label) partly installed — \(r.failed.joined(separator: ", ")) failed"
        }
    }

    var componentToolingReady: Bool { engine?.recipes.tooling().missing.isEmpty ?? false }

    /// Opens a prefilled issue on the project, after putting the report on the
    /// clipboard. Telling someone to "open an issue" without saying where is
    /// how bug reports do not get written.
    func reportProblem(_ game: Game) {
        perform("Preparing a problem report…", key: "reportIssue") { e in
            let rep = try e.report(game)
            let text = (try? String(contentsOf: rep, encoding: .utf8)) ?? ""
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                if let u = URL(string: "https://github.com/ricardothesillyllama/Decanter/issues/new?template=game-does-not-work.md") {
                    NSWorkspace.shared.open(u)
                }
            }
            return "Report copied. Paste it into the issue that just opened."
        }
    }

    func stop(_ game: Game) {
        perform("Stopping \(game.name)…", key: "stop") { e in
            let n = try e.stop(game)
            return n == 0 ? "Nothing left running" : "Ended \(plural(n, "process", "processes"))"
        } then: { [weak self] in
            self?.running.remove(game.id)
        }
    }

    /// Reads the last run's log and says what it found.
    ///
    /// This used to set `diagnosis` and return. When the log was clean — or
    /// absent, because the game had never been run — nothing appeared, so the
    /// button looked broken. Saying "nothing to report" is a result too.
    func diagnose(_ game: Game) {
        perform("Reading the last run's log…", key: "diagnose") { e in
            let log = e.paths.logs.appending(path: "\(game.name.replacingOccurrences(of: "/", with: "_")).log")
            let exists = FileManager.default.fileExists(atPath: log.path)
            let rep = Diagnostics().analyse(logAt: log)
            Task { @MainActor in self.diagnosis[game.id] = rep }
            if !exists { return "No log yet — this game has not been run from Decanter." }
            if rep.isEmpty { return "Nothing wrong found in the last run's log." }
            return "Found \(plural(rep.findings.count, "thing")) worth looking at."
        }
    }

    func revealPluginsFolder(_ game: Game) {
        guard let d = mods[game.id]?.pluginsDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([d])
    }

    func openLoaderLog(_ game: Game) {
        guard let l = mods[game.id]?.logPath else { return }
        NSWorkspace.shared.open(l)
    }

    func revealPrefix(_ game: Game) {
        guard let b = bottle(for: game) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([b.prefixPath])
    }
}
