import Foundation
import DecanterKit

/// One game's unanswered question no longer throws away another's.
func runPerGameVerdictTests(_ t: Harness) {
    t.suite("One question per game, and answering one leaves the others")
    let fm = FileManager.default
    let root = Fixture.dir("verdicts")
    let paths = Paths(root: root); try? paths.ensure()
    let v = Verdict(paths: paths)
    func p(_ id: UUID, _ name: String, ago: TimeInterval = 0) -> Verdict.Pending {
        .init(gameID: id, gameName: name, runtimeID: "wine-11.0", backend: .dxvk,
              launchedAt: Date().addingTimeInterval(-ago), observed: "it exited after 3 seconds",
              onRecommendation: true)
    }
    let a = UUID(), b = UUID()
    try? v.park(p(a, "First", ago: 60))
    try? v.park(p(b, "Second"))
    t.equal(v.pending(for: a)?.gameName, "First", "a second game's question does not replace the first's")
    t.equal(v.pending(for: b)?.gameName, "Second", "and both are waiting")
    t.equal(v.pending()?.gameName, "Second", "the most recent is the one the command line asks about")
    v.clear(gameID: b)
    t.equal(v.pending(for: b) == nil, true, "answering one clears only that one")
    t.equal(v.pending(for: a)?.gameName, "First", "and leaves the other waiting")

    // The file an older Decanter wrote holds one question, and upgrading must
    // not lose it.
    v.clearAll()
    let legacy = root.appending(path: "pending-verdict.json")
    try? JSONEncoder().encode(p(a, "Parked by an older version")).write(to: legacy)
    t.equal(v.pending(for: a)?.gameName, "Parked by an older version",
            "a question an older version parked is still asked")
    t.expect(!fm.fileExists(atPath: legacy.path), "and carried into the new file rather than read twice")
    v.clearAll()
    t.expect(!fm.fileExists(atPath: v.path.path), "with nothing waiting, no file is left behind")
}

/// The library that became empty on 27 August.
func runReadOnlyLibraryTests(_ t: Harness) {
    t.suite("A library Decanter cannot read is never written over")
    let root = Fixture.dir("unreadable-library")
    let paths = Paths(root: root); try? paths.ensure()
    let garbage = Data(#"{ "games": 42 }"#.utf8)
    try? garbage.write(to: paths.statePath)
    guard let e = try? Engine(paths: paths) else {
        t.expect(false, "an engine still opens on an unreadable library, so it can say so"); return
    }
    t.expect(e.store.loadError != nil, "the failure is recorded")
    t.expect(e.store.unreadableBackup.map { FileManager.default.fileExists(atPath: $0.path) } == true,
             "and a copy is kept")
    t.throwsError("a change is refused rather than saved over the file") {
        try e.store.mutate { $0.games = [] }
    }
    t.equal(try? Data(contentsOf: paths.statePath), garbage, "the file on disk is exactly as it was")

    // Whatever makes it readable again — a newer Decanter, a hand repair —
    // ends read-only mode the next time the library is looked at.
    try? Data(#"{"games":[],"bottles":[],"runtimes":[]}"#.utf8).write(to: paths.statePath)
    e.store.refresh()
    t.expect(e.store.loadError == nil, "once the file reads, Decanter stops refusing")
    t.survives("and changes go through again") { try e.store.mutate { $0.templates = [:] } }

    // A file that stops decoding while Decanter is already open — a newer
    // version wrote a shape this one does not know — used to be skipped, and
    // the stale copy in memory saved over it.
    try? garbage.write(to: paths.statePath)
    t.throwsError("a file that stops decoding mid-session is not written over either") {
        try e.store.mutate { $0.templates = [:] }
    }
    t.equal(try? Data(contentsOf: paths.statePath), garbage, "and it too is left exactly as it was")

    t.suite("Starting a new library moves the old file aside")
    let root2 = Fixture.dir("unreadable-library-2")
    let p2 = Paths(root: root2); try? p2.ensure()
    try? garbage.write(to: p2.statePath)
    guard let e2 = try? Engine(paths: p2) else { t.expect(false, "an engine opens"); return }
    t.survives("a new library can be started on purpose") { try e2.startNewLibrary() }
    t.expect(e2.store.loadError == nil, "which ends read-only mode")
    let aside = ((try? FileManager.default.contentsOfDirectory(atPath: root2.path)) ?? [])
        .filter { $0.hasPrefix("state.replaced-") }
    t.equal(aside.count, 1, "and the unreadable file is moved aside, not deleted")
}

/// A hand choice gets a small card instead of silence.
func runHandChoiceAdviceTests(_ t: Harness) {
    t.suite("A setup chosen by hand gets one small note, not silence")
    let fm = FileManager.default
    let root = Fixture.dir("hand-choice")
    guard let e = try? Engine(paths: Paths(root: root)) else {
        t.expect(false, "an engine can be made"); return
    }
    var det = DetectionResult()
    det.engine = .unityIL2CPP; det.bitness = .x64; det.graphicsAPIs = ["d3d11.dll"]
    let bottleID = UUID()
    let prefix = root.appending(path: "bottles/\(bottleID.uuidString)")
    try? fm.createDirectory(at: prefix, withIntermediateDirectories: true)
    let rt = RuntimeSpec(id: "gptk-fixture", kind: .gptk, version: "7.7", root: root,
                         winePath: root.appending(path: "wine64"), supports32Bit: true,
                         backends: [.d3dmetal, .dxvk, .wined3d])
    let game = Game(name: "Fixture", exePath: root.appending(path: "g.exe"),
                    bottleID: bottleID, detection: det)
    try? e.store.mutate { s in
        s.games = [game]; s.runtimes = [rt]
        s.bottles = [Bottle(id: bottleID, prefixPath: prefix, runtimeID: rt.id, backend: .d3dmetal)]
    }
    let rec = e.recommend(for: game)
    guard rec.runtimeKind == .gptk, rt.backends.contains(rec.backend),
          let other = rt.backends.first(where: { $0 != rec.backend }) else {
        t.skip("hand choice", "the fixture's recommendation is not a GPTK backend on this build"); return
    }
    _ = try? e.setBackend(game, other)
    let chosen = e.advice(for: e.store.state.games[0])
    t.equal(chosen.kind, .chosenByHand, "moving off the recommendation by hand produces the small card")
    t.expect(chosen.actionLabel?.contains(rec.backend.plainName) == true,
             "which offers Decanter's suggestion by name")
    t.expect(chosen.explanation.contains(other.plainName), "and says what was chosen, without arguing with it")
    _ = try? e.setBackend(e.store.state.games[0], rec.backend)
    t.equal(e.advice(for: e.store.state.games[0]).kind, .settled,
            "and once on the suggestion, there is nothing to say")
}

/// Kept saves under a matching name are found, and only brought back on request.
func runKeptSavesReconnectTests(_ t: Harness) {
    t.suite("Saves kept under a matching name are set aside, found, and brought back")
    let fm = FileManager.default
    let root = Fixture.dir("reconnect")
    let paths = Paths(root: root); try? paths.ensure()
    let store = SaveStore(paths: paths)
    let saves = root.appending(path: "saves")
    let game = Game(name: "Some Game", exePath: root.appending(path: "g.exe"),
                    bottleID: UUID(), detection: DetectionResult())
    let slug = store.slug(for: game)

    // What removing a game with "keep saves" leaves: a snapshot, saved under
    // whatever the old environment called its Windows user.
    let snap = saves.appending(path: "\(slug)/snapshots/2026-09-12T23-21-00")
    let rel = "drive_c/users/crossover/AppData/LocalLow/Vendor/Product/slot1.dat"
    try? fm.createDirectory(at: snap.appending(path: "files/\(rel)").deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    try? Data("progress".utf8).write(to: snap.appending(path: "files/\(rel)"))
    try? Data(#"{"game":"Some Game","files":1}"#.utf8).write(to: snap.appending(path: "manifest.json"))

    let moved = try? store.setAsideKeptStore(for: game)
    t.expect(moved?.hasPrefix("\(slug)--kept-") == true,
             "kept saves in the way of a new game of the same name are set aside")
    t.expect(!fm.fileExists(atPath: saves.appending(path: slug).path),
             "so the new game starts with a store of its own instead of the old one")

    let found = store.keptStores(matching: game, knownSlugs: [slug])
    t.equal(found.map(\.slug), [moved ?? "?"], "and they are offered to the game whose name matches")
    let stranger = Game(name: "Something Else", exePath: root.appending(path: "h.exe"),
                        bottleID: UUID(), detection: DetectionResult())
    t.expect(store.keptStores(matching: stranger, knownSlugs: [slug, store.slug(for: stranger)]).isEmpty,
             "and to no other game")

    let prefix = root.appending(path: "bottles/\(game.bottleID.uuidString)")
    try? fm.createDirectory(at: prefix.appending(path: "drive_c/users/tester"), withIntermediateDirectories: true)
    let n = try? store.adopt(keptSlug: moved ?? "", into: game, prefix: prefix, runtime: nil, knownSlugs: [slug])
    t.equal(n, 1, "bringing them back copies the save")
    t.expect(fm.fileExists(atPath: prefix.appending(path: "drive_c/users/tester/AppData/LocalLow/Vendor/Product/slot1.dat").path),
             "into this environment's own Windows user, not the one it was saved under")
    t.expect(!fm.fileExists(atPath: saves.appending(path: moved ?? "?").path),
             "the kept store is gone once its contents have a home")
    t.equal(store.snapshots(for: game).count, 1, "and its snapshot is now part of this game's own history")
    t.throwsError("a current game's store cannot be adopted as though it were kept") {
        _ = try store.adopt(keptSlug: slug, into: game, prefix: prefix, runtime: nil, knownSlugs: [slug])
    }
}
