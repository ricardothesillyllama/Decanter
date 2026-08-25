import SwiftUI
import DecanterKit

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var bottles: [Bottle] = []
    @Published var health: Engine.Health?
    @Published var busy: String?              // non-nil while a long task runs
    @Published var lastError: String?
    @Published var running: Set<UUID> = []
    @Published var diagnosis: [UUID: Diagnostics.Report] = [:]
    @Published var strays: [WineReaper.Stray] = []
    @Published var mods: [UUID: ModInspector.Status] = [:]
    /// Only worth interrupting the user for: pinned CPU, or running for hours.
    var leakedWine: [WineReaper.Stray] { strays.filter { $0.cpu >= 50 || $0.age > 3600 } }

    private var engine: Engine?
    private var processes: [UUID: Process] = [:]

    init() { reload() }

    var setupNeeded: Bool {
        guard let h = health else { return true }
        return h.pinnedRuntimes.isEmpty || !h.templateBuilt
    }

    func reload() {
        do {
            let e = try engine ?? Engine()
            engine = e
            games = e.store.state.games.sorted { $0.name < $1.name }
            bottles = e.store.state.bottles
            health = e.doctor()
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
    private func perform(_ label: String, _ work: @escaping @Sendable (Engine) throws -> Void) {
        guard let e = engine else { return }
        busy = label; lastError = nil
        Task.detached(priority: .userInitiated) {
            do { try work(e) }
            catch { await MainActor.run { self.lastError = error.localizedDescription } }
            await MainActor.run { self.busy = nil; self.reload(); self.refreshSaves() }
        }
    }

    func runSetup() {
        perform("Preparing your Mac for Windows games…") { e in
            _ = try e.pinAll()
            try e.buildTemplate()
        }
    }

    func add(path: URL) {
        perform("Inspecting \(path.lastPathComponent)…") { e in _ = try e.add(path: path) }
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
                while true {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let alive = Self.wineAlive(prefix: plan.bottle.prefixPath)
                    if !alive {
                        let rep = Diagnostics().analyse(logAt: plan.logFile)
                        let quick = Date().timeIntervalSince(started) < 12
                        await MainActor.run {
                            self.running.remove(game.id)
                            if quick && !rep.isEmpty { self.diagnosis[game.id] = rep }
                        }
                        return
                    }
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
        perform("Rebuilding \(game.name)'s prefix…") { e in _ = try e.rederive(game) }
    }

    func importSaves(_ game: Game, from url: URL) {
        perform("Importing saves into \(game.name)…") { e in _ = try e.importSaves(into: game, from: url) }
    }

    func setBackend(_ game: Game, _ backend: GraphicsBackend) {
        perform("Switching \(game.name) to \(backend.label)…") { e in
            try e.store.mutate { s in
                if let i = s.bottles.firstIndex(where: { $0.id == game.bottleID }) {
                    s.bottles[i].backend = backend
                }
                if let i = s.games.firstIndex(where: { $0.id == game.id }) {
                    s.games[i].runtimeLocked = true
                }
            }
        }
    }

    func setRuntime(_ game: Game, _ runtimeID: String) {
        perform("Moving \(game.name) to \(runtimeID)…") { e in _ = try e.setRuntime(game, to: runtimeID) }
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
    @Published var lastShot: URL?
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
        perform("Applying the recommended setup for \(game.name)…") { e in
            _ = try e.applyRecommendation(game)
        }
    }

    /// Records the current setup as working, which also teaches future games.
    @Published var executableChoices: [UUID: [Detector.ExecutableChoice]] = [:]

    /// Scanning a game folder touches disk, so do it on demand, off the main
    /// thread, and cache the result.
    func loadExecutables(_ game: Game) {
        guard let e = engine, executableChoices[game.id] == nil else { return }
        Task.detached(priority: .utility) {
            let list = e.executables(for: game)
            await MainActor.run { self.executableChoices[game.id] = list }
        }
    }

    func setExecutable(_ game: Game, _ url: URL) {
        executableChoices[game.id] = nil
        perform("Switching \(game.name) to \(url.lastPathComponent)…") { e in
            _ = try e.setExecutable(game, to: url)
        }
    }

    /// Runs a different executable in the same prefix without changing the game.
    func runOther(_ game: Game, _ url: URL) {
        guard let e = engine else { return }
        lastError = nil
        do {
            _ = try e.runOther(game, exe: url)
            reportNote = "Running \(url.lastPathComponent) in \(game.name)'s prefix."
        } catch { lastError = error.localizedDescription }
    }

    func redetect(_ game: Game) {
        perform("Re-inspecting \(game.name)…") { e in _ = try e.redetect(game) }
    }

    func markWorking(_ game: Game) {
        perform("Remembering this setup…") { e in try e.rememberWorking(game) }
    }

    /// Builds the pasteable bundle and puts it on the clipboard, because the
    /// whole point is having something to hand over.
    func makeReport(_ game: Game, screenshot: Bool) {
        guard let e = engine else { return }
        busy = "Collecting diagnostics…"; lastError = nil; reportNote = nil
        Task.detached(priority: .userInitiated) {
            do {
                let (rep, shot) = try e.report(game, includeScreenshot: false)
                let text = (try? String(contentsOf: rep, encoding: .utf8)) ?? ""
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.lastReport = rep; self.lastShot = shot
                    self.reportNote = "Report copied to the clipboard. If the problem is visual, add a screenshot: Command-Shift-4, Space, click the window."
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
            await MainActor.run { self.busy = nil }
        }
    }

    func revealReport() {
        guard let r = lastReport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastShot, r].compactMap { $0 })
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
        perform("Snapshotting \(game.name)…") { e in _ = try e.snapshotSaves(game, note: "manual") }
    }

    func snapshotAll() {
        perform("Snapshotting every game…") { e in
            for g in e.store.state.games { _ = try? e.snapshotSaves(g, note: "manual (all)") }
        }
    }

    func externaliseSaves(_ game: Game) {
        perform("Protecting \(game.name)'s saves…") { e in _ = try e.externaliseSaves(game) }
    }

    func externaliseAll() {
        perform("Protecting every game's saves…") { e in
            for g in e.store.state.games { _ = try? e.externaliseSaves(g) }
        }
    }

    func restoreSnapshot(_ game: Game, _ name: String) {
        perform("Restoring \(game.name)…") { e in _ = try e.restoreSaves(game, snapshot: name) }
    }

    func remove(_ game: Game, keepSaves: Bool) {
        perform("Removing \(game.name)…") { e in _ = try e.remove(game, keepSaves: keepSaves) }
    }

    func gc() { perform("Cleaning orphaned prefixes…") { e in _ = try e.gc() } }

    func reapWine() {
        perform("Ending leftover Wine processes…") { e in
            let o = e.reapWine()
            let msg = "Ended \(o.sessionsEnded) Wine session(s) and \(o.killed.count) process(es)."
            Task { @MainActor in self.reportNote = msg }
        }
    }

    /// Applies to every template and bottle at once. The mapping is registry
    /// data, so this is idempotent and nothing is launched.
    func fixFonts() {
        perform("Mapping Windows font names…") { e in
            let r = e.provisionFonts()
            let n = r.reduce(0) { $0 + $1.plan.mapped.count }
            let msg = n == 0
                ? "Every Windows font name already resolves — nothing to change."
                : "Mapped \(n) font name(s) across \(r.count) prefix(es). Takes effect next launch."
            Task { @MainActor in self.reportNote = msg }
        }
    }

    func diagnose(_ game: Game) {
        guard let e = engine else { return }
        let log = e.paths.logs.appending(path: "\(game.name.replacingOccurrences(of: "/", with: "_")).log")
        diagnosis[game.id] = Diagnostics().analyse(logAt: log)
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
