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
        /// The game this was done to, when it was done to one.
        ///
        /// Without it the list was global, so a report collected for one game
        /// sat on top of another game's page claiming to be about it. What was
        /// done to this Mac — pinning a runtime, cleaning up, ending stray
        /// processes — has no game and belongs everywhere.
        var scope: UUID?
        var duration: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }
    }
    @Published var activity: [Activity] = []

    /// What has been done to one game, and to the Mac. A game's page shows
    /// both, because "the runtime was repaired" is part of the story of why a
    /// game started working; another game's page shows neither.
    func activity(for gameID: UUID) -> [Activity] {
        activity.filter { $0.scope == nil || $0.scope == gameID }
    }

    /// What was done to this Mac rather than to any one game.
    var globalActivity: [Activity] { activity.filter { $0.scope == nil } }

    /// What happened the last time a keyed control was pressed.
    ///
    /// The activity list answers "what has been done", which is a different
    /// question from "did the thing I just clicked work" — and it was answering
    /// the second one badly, because it lives at the bottom of the page and
    /// stays there. A reaction belongs on the control that was pressed.
    struct Reaction: Sendable {
        var succeeded: Bool
        var detail: String?
    }
    @Published var reactions: [String: Reaction] = [:]

    func reaction(_ key: String) -> Reaction? { reactions[key] }

    /// How long a success stays on its button. Long enough to read, short
    /// enough that it is plainly about the press that just happened and not a
    /// permanent change of state. A failure is not cleared on a timer: it is
    /// the thing the user still has to deal with, and it goes when they press
    /// something again.
    private static let reactionLinger: Duration = .seconds(4)
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
            // Read the files again before drawing anything from them. The CLI
            // and the app are routinely open together, and until this line
            // existed the app's answer to every question was the one it formed
            // at launch.
            e.reload()
            games = e.store.state.games.sorted { $0.name < $1.name }
            bottles = e.store.state.bottles
            health = e.doctor()
            readiness = e.readiness()
            var recs: [UUID: Engine.Recommendation] = [:]
            var advice: [UUID: Engine.SetupAdvice] = [:]
            var endorsed: Set<UUID> = [], canSign: Set<UUID> = []
            for g in games {
                recs[g.id] = e.recommend(for: g)
                advice[g.id] = e.advice(for: g)
                if e.endorsement(for: g) != nil { endorsed.insert(g.id) }
                if e.canEndorse(g) { canSign.insert(g.id) }
            }
            recommendations = recs
            adviceByGame = advice
            endorsedSetups = endorsed
            endorsable = canSign
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
            // A question about a launch nobody judged, and whether the builds
            // underneath still hold together. Both are cheap to ask for and
            // both are things somebody would want to see without going looking.
            pendingVerdict = Verdict(paths: e.paths).pending()
            checkForReplacedBundle()
            // Reading a small JSON file. Nothing is measured here — `bench` is
            // the command that measures, and it starts every Wine build to do
            // it.
            benchRows = Dictionary(uniqueKeysWithValues:
                Bench(paths: e.paths).load().rows.map { ($0.runtimeID, $0) })
            if runtimeSoundness.isEmpty { refreshSoundness() }
            refreshFonts()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func bottle(for game: Game) -> Bottle? { bottles.first { $0.id == game.bottleID } }

    /// The version sitting in the app bundle on disk, when it is not the one
    /// running.
    ///
    /// A Decanter installed while the old one is still open keeps running the
    /// old one, indefinitely, and nothing on screen says so. That is not a
    /// hypothetical: this app was open across four releases without being
    /// quit once, and every screenshot taken from it was read as a bug in the
    /// build that had just shipped. Twice it sent the maintainer looking for a
    /// fault that had already been fixed.
    ///
    /// The compiled-in version is what this process is; the bundle's plist is
    /// what would run if it were started now. When they differ the process is
    /// the stale one, and only quitting fixes it — closing the window does not
    /// end the process, which is exactly why this keeps happening.
    @Published var newerVersionInstalled: String?

    func checkForReplacedBundle() {
        let plist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist")
        guard let d = try? Data(contentsOf: plist),
              let any = try? PropertyListSerialization.propertyList(from: d, format: nil),
              let dict = any as? [String: Any],
              let onDisk = dict["CFBundleShortVersionString"] as? String,
              !onDisk.isEmpty
        else { newerVersionInstalled = nil; return }
        newerVersionInstalled = onDisk == Build.version ? nil : onDisk
    }

    /// One entry point for every long operation, so the UI can never get out
    /// of sync with the engine and errors always surface in the same place.
    private func perform(_ label: String, key: String? = nil, scope: UUID? = nil,
                         _ work: @escaping @Sendable (Engine) throws -> String?,
                         then: (@MainActor () -> Void)? = nil) {
        guard let e = engine else { return }
        busy = label; lastError = nil; activeAction = key
        // Pressing something clears what the last press said. Two results on
        // screen at once, one of them stale, is how a user ends up acting on
        // the wrong one.
        if let key { reactions[key] = nil }
        let entry = Activity(label: label, scope: scope)
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
                if let key {
                    self.reactions[key] = Reaction(succeeded: failure == nil,
                                                   detail: failure ?? summary)
                    if failure == nil {
                        // Only the success fades. Cleared by identity so a
                        // second press during the wait does not have its own
                        // result wiped by the first one's timer.
                        let stamp = self.reactions[key]
                        Task { @MainActor in
                            try? await Task.sleep(for: Self.reactionLinger)
                            if self.reactions[key]?.detail == stamp?.detail,
                               self.reactions[key]?.succeeded == true {
                                self.reactions[key] = nil
                            }
                        }
                    }
                }
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

    /// What Decanter can see in the Downloads folder, and what the user chose
    /// to take from it.
    ///
    /// Kept separate from `accept(path:)` on purpose. Dropping a folder means
    /// "use what is in here"; Downloads is not a folder anyone assembled, and
    /// a button that pinned whatever Wine build happens to be sitting in it
    /// would be doing something nobody asked for. So this looks, shows what it
    /// found, and waits.
    ///
    /// It also decides when the system's folder-access prompt appears. macOS
    /// asks the first time Decanter reads Downloads; asking because the app
    /// went looking on its own reads as overreach, and asking one beat after
    /// someone pressed "Look in Downloads" reads as the thing they asked for.
    @Published var downloadFindings: [Engine.Finding] = []
    @Published var chosenDownloads: Set<String> = []
    /// Distinguishes "not looked yet" from "looked and found nothing", which
    /// are different sentences.
    @Published var lookedInDownloads = false

    var downloadsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    /// Deliberately not routed through `perform`.
    ///
    /// `perform` exists for work that takes seconds: it sets `busy`, opens an
    /// activity entry, and writes the reaction when the detached task finishes.
    /// Looking in Downloads classifies each immediate child by name and by one
    /// `stat` — measured at 0.2 seconds on a real Downloads folder, opening no
    /// archive — so all of that machinery buys nothing, and the first version
    /// of this had it both ways: it called `perform` for the spinner and then
    /// set the reaction itself, so `perform`'s own completion overwrote the
    /// sentence saying what had been found.
    func lookInDownloads() {
        guard let e = engine else { return }
        let found = e.look(in: downloadsFolder)
        downloadFindings = found
        chosenDownloads = Set(found.map(\.id))
        lookedInDownloads = true
        var entry = Activity(label: "Looked in Downloads")
        entry.outcome = .succeeded
        entry.finished = Date()
        entry.detail = found.isEmpty
            ? "Nothing there is something Decanter can use."
            : "Found \(found.count) thing\(found.count == 1 ? "" : "s"). Nothing has been installed."
        activity.insert(entry, at: 0)
        reactions["look"] = Reaction(succeeded: true, detail: entry.detail)
    }

    func acceptChosenDownloads() {
        let chosen = downloadFindings.filter { chosenDownloads.contains($0.id) }
        guard !chosen.isEmpty else { return }
        perform("Taking in \(chosen.count) item\(chosen.count == 1 ? "" : "s")…", key: "acceptChosen") { e in
            try e.accept(chosen)
        } then: { [weak self] in
            self?.downloadFindings = []
            self?.chosenDownloads = []
            self?.lookedInDownloads = false
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

    /// Knowledge someone hands you, and knowledge you hand over.
    ///
    /// Deliberately a file and a button, never a fetch. Automatic would mean
    /// reaching out to somewhere, and "Decanter makes no network requests" is a
    /// rule that is checkable precisely because there is no exception hiding
    /// behind a convenience. So this is framed as what it is: a file a person
    /// gives you, by whatever means they like.
    func importKnowledge() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a knowledge file someone shared with you"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("Reading \(url.lastPathComponent)…", key: "kbImport") { e in
            let r = try e.importKnowledge(from: url)
            if r.added == 0 {
                return "Nothing new — this Mac already has an answer for all \(r.skipped) of those situations."
            }
            let skipped = r.skipped > 0 ? " \(r.skipped) skipped: already answered here." : ""
            return "Took \(r.added) observation(s).\(skipped) Notes are kept only where the signature checks out."
        }
    }

    func exportKnowledge() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "decanter-knowledge.json"
        panel.message = "Situations and outcomes only — no game names, no paths, no machine identifiers"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("Writing \(url.lastPathComponent)…", key: "kbExport") { e in
            let n = try e.exportKnowledge(to: url)
            return "Wrote \(n) observation(s). No game names, no paths, no machine identifiers."
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
                        // Decanter could not tell whether this worked, so it
                        // asks. Only here and below, where it declines to
                        // conclude anything itself.
                        //
                        // Asked on the main actor rather than from this task:
                        // it reaches the engine's knowledge base, which is
                        // created on first use, and first use from two threads
                        // at once is a race nobody would find twice.
                        await MainActor.run {
                            e.askAbout(game, observed: "it never opened a window")
                            self.running.remove(game.id)
                            self.diagnosis[game.id] = rep
                            if rep.isEmpty {
                                self.lastError = "\(game.name) did not start, and its log says nothing. Try Troubleshoot Launch under Saves & Maintenance."
                            }
                            self.refreshVerdict()
                        }
                        return
                    }
                    let rep = Diagnostics().analyse(logAt: plan.logFile)
                    let ran = Date().timeIntervalSince(started)
                    let quick = ran < 12
                    // A game that quit almost immediately, or one that left
                    // complaints in its log, is the ambiguous case: it may have
                    // been played and closed, or it may have died. Decanter
                    // does not know, so it asks rather than recording a guess.
                    await MainActor.run {
                        if quick {
                            e.askAbout(game, observed: "it closed again after \(Int(ran)) seconds")
                        } else if !rep.isEmpty {
                            e.askAbout(game, observed: "it ran, but its log reports problems")
                        }
                        self.running.remove(game.id)
                        if quick && !rep.isEmpty { self.diagnosis[game.id] = rep }
                        self.refreshVerdict()
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
        perform("Rebuilding \(game.name)'s Windows environment…", key: "rebuild", scope: game.id) { e in
            let b = try e.rederive(game)
            return "Windows environment rebuilt from the \(b.runtimeID) template; saves kept"
        }
    }

    func importSaves(_ game: Game, from url: URL) {
        perform("Importing saves into \(game.name)…", key: "import", scope: game.id) { e in
            let r = try e.importSaves(into: game, from: url)
            return "Imported \(plural(r.filesCopied, "save file"))"
        }
    }

    func setBackend(_ game: Game, _ backend: GraphicsBackend) {
        perform("Switching \(game.name) to \(Help.plainName(backend)) graphics…", key: "backend", scope: game.id) { e in
            // Through the engine, not by setting the field: DXVK and DXMT are
            // real DLLs in the prefix and swapping between them needs an
            // install, not a relabel.
            _ = try e.setBackend(game, backend)
            return "Graphics is now \(Help.plainName(backend))"
        }
    }

    func setRuntime(_ game: Game, _ runtimeID: String) {
        perform("Switching \(game.name)'s engine…", key: "runtime", scope: game.id) { e in
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

    /// Whether the recommendation banner should stay quiet.
    ///
    /// True when the setup already matches — and also when the person has set
    /// this game's runtime or backend by hand. Choosing is not knowing, so an
    /// override teaches the knowledge base nothing; but it does stop Decanter
    /// pushing back on a decision already made.
    /// The "this will not run" warning, as it actually applies to this game.
    ///
    /// `DetectionResult.blocker` is a static rule about an engine, and on its
    /// own it will keep saying a game cannot run here long after this Mac has
    /// watched it run. The knowledge base is what settles that, so it is asked
    /// first — the same order `Engine.recommend` uses, and for the same reason.
    /// A warning that survives its own disproof is the fastest way to teach
    /// someone to ignore warnings.
    func blocker(for game: Game) -> String? {
        guard let text = game.detection.blocker(onBackend: bottle(for: game)?.backend) else {
            return nil
        }
        // Evidence outranks the rule. Anything weaker — a shipped assumption,
        // an inference from the files — does not, and the warning stands.
        switch recommendations[game.id]?.provenance {
        case .seenHere, .verified: return nil
        default: return text
        }
    }

    func isOnRecommended(_ game: Game) -> Bool {
        guard let rec = recommendations[game.id],
              let b = bottle(for: game),
              let rt = pinnedRuntimes.first(where: { $0.id == b.runtimeID }) else { return false }
        if rec.overriddenByUser { return true }
        return rt.kind == rec.runtimeKind && b.backend == rec.backend
    }

    // MARK: - Going back, and being asked

    /// The launch Decanter could not judge for itself, if there is one.
    @Published var pendingVerdict: Verdict.Pending?
    /// Whether each runtime holds together, and what could be done if not.
    @Published var runtimeSoundness: [String: RuntimeAudit.Report] = [:]

    func refreshVerdict() {
        guard let e = engine else { return }
        pendingVerdict = Verdict(paths: e.paths).pending()
    }

    /// Measured off the main thread: an audit reads every binary in a Wine
    /// build, which is fast but not instant, and the window must not stop while
    /// it happens.
    func refreshSoundness() {
        guard let e = engine else { return }
        let roots = e.store.state.runtimes.map { ($0.id, $0.root) }
        Task.detached(priority: .utility) {
            var out: [String: RuntimeAudit.Report] = [:]
            for (id, root) in roots { out[id] = RuntimeAudit().audit(root: root) }
            await MainActor.run { self.runtimeSoundness = out }
        }
    }

    /// Whether this game's Windows environment still needs font names mapped.
    ///
    /// "Fix Fonts" was an action with no diagnosis beside it: a button you press
    /// on a hunch, that may do nothing, and tells you so only afterwards.
    /// `decanter fonts --check` has answered this all along. Two registry
    /// files per prefix, so it costs nothing to keep current.
    @Published var fontStatus: [UUID: String] = [:]
    /// Games where pressing it would change nothing.
    @Published var fontsSettled: Set<UUID> = []

    func refreshFonts() {
        guard engine != nil else { return }
        let prefixes = games.compactMap { g -> (UUID, URL)? in
            bottle(for: g).map { (g.id, $0.prefixPath) }
        }
        Task.detached(priority: .utility) {
            let fp = FontProvisioner()
            var lines: [UUID: String] = [:], settled: Set<UUID> = []
            for (id, prefix) in prefixes {
                let plan = fp.plan(for: prefix)
                if plan.mapped.isEmpty {
                    lines[id] = "Every Windows font name already resolves here."
                    settled.insert(id)
                } else if plan.pending.isEmpty {
                    lines[id] = "All \(plan.mapped.count) names are already mapped."
                    settled.insert(id)
                } else {
                    lines[id] = "\(plan.pending.count) of \(plan.mapped.count) Windows font names are not mapped yet."
                }
            }
            await MainActor.run { self.fontStatus = lines; self.fontsSettled = settled }
        }
    }

    /// Throws away snapshots past the retention count, for every game.
    ///
    /// `decanter saves gc` did this and the app did not, so snapshots
    /// accumulated with nothing on any screen offering to stop them.
    func pruneSnapshots() {
        perform("Pruning old snapshots…", key: "savesGC") { e in
            var removed = 0
            for g in e.store.state.games {
                removed += (try? e.saves.prune(game: g, keep: e.snapshotRetention)) ?? 0
            }
            return removed == 0
                ? "Nothing to prune — every game is within \(e.snapshotRetention) snapshots."
                : "Pruned \(plural(removed, "old snapshot"))."
        }
    }

    // MARK: - Advanced

    /// Engine switches, locale, and the graphics layer's exact version.
    ///
    /// All three existed only at the prompt. They are here now because the
    /// people who need them cannot be told to open a terminal by an app whose
    /// whole argument is that you should not have to — and they are behind a
    /// door because someone who does not know what `-force-d3d12` is has no use
    /// for it and every chance of being harmed by it.
    func setLaunchArguments(_ game: Game, _ args: [String]) {
        perform(args.isEmpty ? "Clearing launch switches…" : "Setting launch switches…",
                key: "args", scope: game.id) { e in
            let set = try e.setLaunchArguments(game, args)
            return set.isEmpty ? "No switches. The game starts as it ships."
                               : "Starts with \(set.joined(separator: " "))."
        }
    }

    func setLocalePreset(_ game: Game, _ name: String) {
        perform("Setting the language environment…", key: "locale", scope: game.id) { e in
            guard let preset = Engine.localePresets[name] else {
                throw DecanterError.notFound("no locale preset called \(name)")
            }
            _ = try e.setEnvironment(game, preset.vars)
            return preset.blurb
        }
    }

    func clearLocale(_ game: Game) {
        perform("Clearing the language environment…", key: "locale", scope: game.id) { e in
            _ = try e.setEnvironment(game, [:], clear: true)
            return "Cleared. The game runs in whatever your Mac's language is."
        }
    }

    func setDXVKVersion(_ game: Game, _ version: String) {
        perform("Switching to DXVK \(version)…", key: "dxvkVersion", scope: game.id) { e in
            let v = try e.setDXVK(game, version: version)
            return "Now on DXVK \(v)."
        }
    }

    /// Engine switches worth trying for this game, from its detection.
    func argumentSuggestions(for game: Game) -> [(flag: String, blurb: String)] {
        LaunchPresets.suggestions(for: game.detection)
    }

    func setDLLOverride(_ game: Game, dll: String, mode: String?) {
        perform(mode == nil ? "Removing the override…" : "Setting the DLL override…",
                key: "dll", scope: game.id) { e in
            let all = try e.setDLLOverride(game, dll: dll, mode: mode)
            return all.isEmpty ? "No overrides set by hand. Takes effect next launch."
                               : "\(all.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  ")) — next launch."
        }
    }

    /// Which proxy DLL the mod loader beside this game loads through. Named so
    /// the interface can say what it found rather than assuming winhttp.
    func modLoaderProxies(_ game: Game) -> [String] { engine?.modLoaderProxies(game) ?? [] }

    var stagedDXVKVersions: [String] {
        guard let e = engine else { return [] }
        return DXVKInstaller(paths: e.paths).stagedVersions()
    }

    func answerVerdict(worked: Bool, failure: Knowledge.Failure = .unspecified,
                       reason: Verdict.SwitchReason? = nil) {
        perform(worked ? "Recording that it worked…" : "Recording what happened…", key: "verdict") { e in
            try e.settleVerdict(worked: worked, failure: failure, switchReason: reason)
        } then: { self.refreshVerdict() }
    }

    func skipVerdict() {
        guard let e = engine else { return }
        Verdict(paths: e.paths).clear()
        pendingVerdict = nil
    }

    /// The setup this game last worked on, when it is on something else now.
    func restorable(_ game: Game) -> Game.KnownGood? { engine?.restorable(game) }

    /// The single answer about this game's setup. See `Engine.SetupAdvice`:
    /// the card is a rendering of this and decides nothing itself.
    func advice(for game: Game) -> Engine.SetupAdvice? { adviceByGame[game.id] }
    @Published private var adviceByGame: [UUID: Engine.SetupAdvice] = [:]

    /// The endorsement on the setup this game is running, if it verifies.
    @Published var endorsedSetups: Set<UUID> = []
    /// Games whose current setup this Mac is in a position to vouch for.
    @Published var endorsable: Set<UUID> = []
    var holdsEndorsementKey: Bool { Endorsement.canEndorse }

    func isEndorsed(_ game: Game) -> Bool { endorsedSetups.contains(game.id) }
    func canEndorse(_ game: Game) -> Bool { endorsable.contains(game.id) }
    func endorsementNote(_ game: Game) -> String? { engine?.endorsement(for: game)?.note }

    /// Vouching for a setup, from the screen where the setup is chosen.
    ///
    /// Only ever offered where `canEndorse` is true, which means this Mac holds
    /// a key *and* has seen this setup work. Nobody else gets a control they
    /// cannot use, and nothing can be vouched for that was not run.
    func endorse(_ game: Game, note: String?) {
        perform("Vouching for this setup…", key: "endorse", scope: game.id) { e in
            let row = try e.endorse(game, note: note)
            return "Endorsed \(row.setup.label). It travels with the knowledge base and carries no name — only the tier."
        }
    }

    func revokeEndorsement(_ game: Game) {
        perform("Withdrawing the endorsement…", key: "endorse", scope: game.id) { e in
            let did = try e.revokeEndorsement(game)
            return did ? "Withdrawn. What was seen here is still recorded; the vouching is not."
                       : "There was nothing here to withdraw."
        }
    }

    /// Whether the game would start, without starting it.
    ///
    /// One verb where there were two, because the two names described each
    /// other's behaviour.
    ///
    /// "Test Launch" did not launch — it ran the preflight and predicted.
    /// "Troubleshoot Launch" did launch, with verbose logging. Two controls
    /// four words apart, one of which starts a game and one of which does not,
    /// is a coin toss dressed as a choice; and the split was wrong on its own
    /// terms, because the prediction is only ever a prediction. A check that
    /// says "it should start" followed by a Play that fails leaves someone
    /// exactly where they began, having pressed two different buttons.
    ///
    /// Chained, they are one coherent action: find out what is wrong. The
    /// check runs first and **stops** if it names a blocker — nothing is
    /// launched, because a blocker is an answer and starting the game would
    /// only produce a second copy of it. If the check passes, the game starts
    /// with full logging, which is the only way to learn anything more.
    ///
    /// That a press can put a game window on screen is said on the control
    /// itself rather than discovered. It is the same rule the rest of Decanter
    /// keeps: nothing appears on screen that was not asked for.
    ///
    /// Written out rather than routed through `perform`, because what happens
    /// next depends on the *report* and `perform` hands its caller only the
    /// sentence it produced. The first version of this decided whether to
    /// launch by looking for a phrase in that sentence — behaviour keyed on
    /// prose, which holds right up until somebody improves the wording and it
    /// starts a game that should not have been started.
    func troubleshoot(_ game: Game) {
        guard let e = engine else { return }
        let label = "Checking whether \(game.name) would start…"
        busy = label; lastError = nil; activeAction = "check"
        reactions["check"] = nil
        let entry = Activity(label: label, scope: game.id)
        activity.insert(entry, at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }

        Task.detached(priority: .userInitiated) {
            var report: Engine.PreflightReport?
            var failure: String?
            do { report = try e.preflight(game) }
            catch { failure = error.localizedDescription }
            await MainActor.run {
                let blocked = !(report?.blockers.isEmpty ?? true)
                let detail = failure ?? (report?.plainSummary ?? "")
                    + (blocked ? "  Nothing was started — this has to be fixed first." : "")
                if let i = self.activity.firstIndex(where: { $0.id == entry.id }) {
                    self.activity[i].outcome = failure == nil ? .succeeded : .failed
                    self.activity[i].detail = detail
                    self.activity[i].finished = Date()
                }
                self.lastError = failure
                self.busy = nil; self.activeAction = nil
                // A blocker is not a failure of the check: the check worked and
                // the news is bad. Marking it failed puts a red mark on the one
                // thing that did its job.
                self.reactions["check"] = Reaction(succeeded: failure == nil, detail: detail)
                self.reload()
                guard failure == nil, !blocked else { return }
                // Nothing named a reason it would not start, so the remaining
                // question is what the game itself does — and only running it
                // answers that.
                self.play(game, verbose: true)
            }
        }
    }

    /// What this game's runtime cannot provide, and why, measured rather than
    /// assumed.
    ///
    /// The picker lists what is available and says nothing about what is not,
    /// so "where is Metal graphics?" had no answer anywhere in the app —
    /// `decanter bench` held one the whole time. Read from the stored table
    /// only: measuring starts each Wine build in turn, which is not something
    /// to do because a section was opened.
    func unavailableBackends(for game: Game) -> [(backend: GraphicsBackend, reason: String)] {
        guard let b = bottle(for: game), let row = benchRows[b.runtimeID] else { return [] }
        return row.unavailable
    }

    @Published var benchRows: [String: Bench.RuntimeRow] = [:]

    func restoreKnownGood(_ game: Game) {
        perform("Putting \(game.name) back on what worked…", key: "restore", scope: game.id) { e in
            let good = try e.restoreKnownGood(game)
            return "Back on \(good.label)"
        }
    }

    /// Fills a build's gaps from builds already on this Mac. Never automatic.
    func repairRuntime(_ runtimeID: String, from game: Game? = nil) {
        perform("Repairing \(runtimeID)…", key: "repair", scope: game?.id) { e in
            guard let rt = e.store.state.runtimes.first(where: { $0.id == runtimeID }) else {
                throw DecanterError.notFound(runtimeID)
            }
            let repair = RuntimeRepair()
            let offer = repair.plan(for: rt, donors: e.store.state.runtimes)
            guard !offer.isEmpty else {
                throw DecanterError.notFound("nothing on this Mac can supply what \(runtimeID) is missing")
            }
            let done = try repair.apply(offer, to: rt)
            let bench = Bench(paths: e.paths)
            var table = bench.load()
            table.rows.removeAll { $0.runtimeID == rt.id }
            table.rows.append(bench.measure(rt))
            try? bench.save(table)
            _ = try? bench.reconcile(store: e.store, table: table)
            return "Put \(done.count) missing piece\(done.count == 1 ? "" : "s") into \(runtimeID)"
        } then: { self.refreshSoundness() }
    }

    func applyRecommendation(_ game: Game) {
        perform("Applying the recommended setup for \(game.name)…", key: "recommend", scope: game.id) { e in
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
        perform("Switching \(game.name) to \(url.lastPathComponent)…", key: "setexe", scope: game.id) { e in
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
        perform("Re-inspecting \(game.name)…", key: "redetect", scope: game.id) { e in
            let d = try e.redetect(game)
            return "\(d.engine.label), \(d.bitness.label)\(d.modded ? ", modded" : "")"
        }
    }

    func markWorking(_ game: Game) {
        perform("Remembering this setup…", key: "remember", scope: game.id) { e in
            try e.rememberWorking(game)
            return "Recorded as working for games with this profile"
        }
    }

    /// Builds the pasteable bundle and puts it on the clipboard, because the
    /// whole point is having something to hand over.
    func makeReport(_ game: Game) {
        perform("Collecting diagnostics…", key: "report", scope: game.id) { e in
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
        perform("Snapshotting \(game.name)…", key: "snapshot", scope: game.id) { e in
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
        perform("Protecting \(game.name)'s saves…", key: "externalise", scope: game.id) { e in
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
        perform("Restoring \(game.name)…", key: "restore", scope: game.id) { e in
            let n = try e.restoreSaves(game, snapshot: name)
            return "Restored \(plural(n, "file")) from \(name)"
        }
    }

    func remove(_ game: Game, keepSaves: Bool) {
        perform("Removing \(game.name)…", key: "remove", scope: game.id) { e in
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
    /// Applies to every template and bottle, and is almost always pressed from
    /// one game's page. The effect is global; the *report* belongs where the
    /// button was, which is why the caller says who asked. Without that, a
    /// result about one game turned up on Setup, which is nobody's page.
    func fixFonts(from game: Game? = nil) {
        perform("Fixing fonts…", key: "fonts", scope: game?.id) { e in
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
        perform("Installing \(label)…", key: "components", scope: game.id) { e in
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
        perform("Preparing a problem report…", key: "reportIssue", scope: game.id) { e in
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
        perform("Stopping \(game.name)…", key: "stop", scope: game.id) { e in
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
        perform("Reading the last run's log…", key: "diagnose", scope: game.id) { e in
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
