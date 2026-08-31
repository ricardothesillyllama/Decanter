import Foundation
import DecanterKit

/// Two ways back from a launch that went wrong: say what happened, or go back
/// to what worked. Both are places where Decanter could easily record something
/// untrue, so the properties worth holding are about what it refuses to
/// conclude.
func runVerdictTests(_ t: Harness) {
    let fm = FileManager.default
    let tmp = URL(filePath: NSTemporaryDirectory())
        .appending(path: "decanter-verdict-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    let paths = Paths(root: tmp)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let v = Verdict(paths: paths)

    func pending(onRecommendation: Bool = true, at when: Date = Date()) -> Verdict.Pending {
        .init(gameID: UUID(), gameName: "A Game", runtimeID: "wine-11.0", backend: .dxvk,
              launchedAt: when, observed: "it exited after 3 seconds",
              onRecommendation: onRecommendation,
              suggested: onRecommendation ? nil : "Metal graphics")
    }

    t.suite("Decanter asks only about what it could not see")
    t.equal(v.pending() == nil, true, "with nothing parked, there is no question")
    try? v.park(pending())
    t.expect(v.pending() != nil, "a launch it could not judge leaves a question")
    let q = v.pending()?.question ?? ""
    t.expect(q.contains("A Game") && q.contains("exited after 3 seconds"),
             "and the question names the game and says what was actually seen")
    t.expect(q.hasSuffix("?"), "and is phrased as a question")
    let plain = q.lowercased()
    t.expect(!["dxvk", "backend", "prefix", "dylib"].contains { plain.contains($0) },
             "in words that need nothing explained first")

    t.suite("a question nobody answers in time is dropped, not asked")
    // Being asked on Friday how Tuesday's launch went produces an answer that
    // should not be recorded as an observation.
    try? v.park(pending(at: Date().addingTimeInterval(-60 * 60 * 24 * 5)))
    t.equal(v.pending() == nil, true, "a launch from days ago is no longer asked about")
    t.equal(fm.fileExists(atPath: v.path.path), false,
            "and the stale question is cleared rather than left to resurface")

    t.suite("a setup nobody suggested says nothing about the suggestion")
    try? v.park(pending(onRecommendation: false))
    let second = v.pending()?.switchQuestion
    t.expect(second != nil, "when the person chose the setup themselves, there is a second question")
    t.expect(second?.contains("Metal graphics") == true,
             "and it names what was suggested instead")
    try? v.park(pending(onRecommendation: true))
    t.equal(v.pending()?.switchQuestion == nil, true,
            "and there is no second question when they were on the suggestion already")

    t.suite("the reasons for moving off a suggestion are a closed list")
    // Free text is the one place a game title could reach knowledge that
    // travels, so there is none — and "no reason given" is a real answer rather
    // than an invitation to write one.
    t.expect(Verdict.SwitchReason.allCases.count >= 4, "there are real options")
    t.expect(Verdict.SwitchReason.allCases.contains(.unstated),
             "including declining to say")
    t.expect(Verdict.SwitchReason.allCases.allSatisfy { !$0.label.isEmpty },
             "each of which is written out in plain words")
    t.expect(Verdict.SwitchReason.allCases.allSatisfy { $0.label.lowercased() == $0.label || $0.label.contains("Decanter") },
             "and reads as something a person would say")

    t.suite("skipping records nothing")
    try? v.park(pending())
    v.clear()
    t.equal(v.pending() == nil, true, "a skipped question does not come back")

    t.suite("going back to what worked")
    let good = Game.KnownGood(runtimeID: "wine-10.0-dxmt", backend: .dxmt, layerVersion: "0.80")
    t.expect(good.label.contains("Metal"),
             "the last working setup is described in the same words as everywhere else")
    t.expect(good.label.contains("0.80"),
             "including the layer's version — going back to \"Metal\" is not going back if it is a different Metal")
    let noVersion = Game.KnownGood(runtimeID: "wine-11.0", backend: .wined3d)
    t.expect(!noVersion.label.contains("nil") && !noVersion.label.isEmpty,
             "and a setup with no version to name reads cleanly anyway")

    t.suite("a game that was never confirmed has nothing to go back to")
    var g = Game(name: "Fresh", exePath: URL(filePath: "/tmp/x.exe"), bottleID: UUID(),
                 detection: DetectionResult())
    t.equal(g.knownGood == nil, true, "a new game has no known-good setup")
    g.knownGood = good
    t.equal(g.knownGood?.runtimeID, "wine-10.0-dxmt", "and one can be recorded on it")
    // Encoded and decoded, because this is state that has to survive a version
    // that has never heard of it.
    if let data = try? JSONEncoder().encode(g),
       let back = try? JSONDecoder().decode(Game.self, from: data) {
        t.equal(back.knownGood?.backend, .dxmt, "it survives being written and read back")
    } else {
        t.expect(false, "a game with a known-good setup encodes and decodes")
    }
    // A game saved before this field existed must still load.
    let older = """
    {"id":"\(UUID().uuidString)","name":"Old","exePath":"file:///tmp/o.exe",
     "bottleID":"\(UUID().uuidString)","detection":{},"scopes":[],
     "envOverrides":{},"dllOverrides":{},"runtimeLocked":false,
     "addedAt":0}
    """
    if let old = try? JSONDecoder().decode(Game.self, from: Data(older.utf8)) {
        t.equal(old.knownGood == nil, true, "a game saved before this existed still loads, with nothing to go back to")
    } else {
        t.expect(false, "a game saved by an older Decanter still loads")
    }
}

/// Five things can be wrong with one game at once. Until 0.7.2 all five drew a
/// card and they stacked, all about the same game, free to disagree in front of
/// the reader. These check the order that replaced the stack — an order that is
/// a claim about urgency, will be argued with, and would otherwise quietly stop
/// being true.
func runConcernOrderTests(_ t: Harness) {
    t.suite("Concerns — one card, and which one")

    t.equal(Concern.mostUrgent(of: []), nil,
            "a game with nothing wrong shows no card at all")

    for c in Concern.allCases {
        t.equal(Concern.mostUrgent(of: [c]), c, "\(c) alone is the one shown")
    }

    // The pair that matters most. Every recommendation is formed without
    // knowing what happened last time, so asking after advising means the
    // advice was given blind.
    t.equal(Concern.mostUrgent(of: [.setupAdvice, .unansweredVerdict]), .unansweredVerdict,
            "the unanswered question comes before the advice that depends on it")
    t.equal(Concern.mostUrgent(of: [.setupAdvice, .unsoundEnvironment]), .unsoundEnvironment,
            "a graphics recommendation waits for an environment that can load what it has")
    t.equal(Concern.mostUrgent(of: [.diagnosis, .unsoundEnvironment]), .diagnosis,
            "what already went wrong comes before what might")
    t.equal(Concern.mostUrgent(of: Set(Concern.allCases)), .cannotStart,
            "with everything wrong at once, a game that cannot start says so first")
    // The certainty outranks the question, and this is the pair that says why:
    // "how did last night's launch go?" is the wrong thing to put to somebody
    // whose game is no longer on the disk.
    t.equal(Concern.mostUrgent(of: [.unansweredVerdict, .cannotStart]), .cannotStart,
            "a game that cannot start is not asked how it went")
    t.equal(Concern.mostUrgent(of: [.diagnosis, .cannotStart]), .cannotStart,
            "and it comes before a diagnosis of the launch that failed because of it")
    // Everything below it still ranks as it did — inserting a case at the top
    // must not reorder the four that were already there.
    t.equal(Concern.mostUrgent(of: Set(Concern.allCases).subtracting([.cannotStart])),
            .unansweredVerdict,
            "with that one absent, the unanswered question is first as before")

    // Stray Wine processes are a nuisance and never a cause, so they must not
    // outrank anything — and must not be silently dropped either.
    for c in Concern.allCases where c != .strayProcesses {
        t.equal(Concern.mostUrgent(of: [.strayProcesses, c]), c,
                "stray processes never outrank \(c)")
    }
    t.equal(Concern.mostUrgent(of: [.strayProcesses]), .strayProcesses,
            "stray processes are still shown when they are all there is")

    t.suite("Concerns — which ones open the repair tools")

    // The repair section opens itself when there is something to repair. Stray
    // processes have their own card with its own button; opening five repair
    // controls for them points somebody at the wrong five.
    t.expect(!Concern.strayProcesses.callsForRepairTools,
             "stray processes do not open a section of repairs")
    for c in Concern.allCases where c != .strayProcesses {
        t.expect(c.callsForRepairTools, "\(c) opens the repair tools")
    }

    // The order is total. Two concerns that compare equal would make which card
    // appears depend on Set iteration order, which is not stable between runs.
    let ranks = Concern.allCases.map(\.rawValue)
    t.equal(Set(ranks).count, Concern.allCases.count, "every concern has a distinct rank")
}
