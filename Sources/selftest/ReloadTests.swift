import Foundation
import DecanterKit

/// The app and the CLI are routinely open at the same time, and until 0.6.1 the
/// app's answer to every question was the one it formed at launch: `Store` had
/// a `refresh()` written for exactly this and no callers, and `knowledge` was a
/// `lazy var` read once. These check that an Engine adopts what another process
/// wrote, because nothing else in the suite would have noticed it did not.
func runReloadTests(_ t: Harness) {
    t.suite("Reload — adopting another process's writes")

    let root = Fixture.dir("reload-root")
    let paths = Paths(root: root)

    guard let a = try? Engine(paths: paths), let b = try? Engine(paths: paths) else {
        t.expect(false, "two engines can share a root")
        return
    }

    // `a` stands in for the app, holding its Engine open; `b` for the CLI.
    t.equal(a.store.state.games.count, 0, "the app starts with an empty library")

    let game = Game(name: "Fixture", exePath: root.appending(path: "x.exe"),
                    bottleID: UUID(), detection: DetectionResult())
    try? b.store.mutate { $0.games.append(game) }

    t.equal(a.store.state.games.count, 0, "the app does not see it without being told to look")
    a.reload()
    t.equal(a.store.state.games.count, 1, "after reload the app sees what the CLI added")

    // The knowledge base is the half that stayed frozen even when the state did
    // not, because `lazy var` initialises once and never again.
    let sig = Knowledge.Signature(engine: .unityMono, engineMajor: 6000, bitness: .x64)
    let setup = Knowledge.Setup(runtimeKind: .wine, backend: .dxmt)
    t.expect(a.knowledge.observations.first { $0.signature == sig && !$0.seeded } == nil,
             "the app has no local observation for this situation yet")

    b.knowledge.record(.init(signature: sig, setup: setup, worked: true,
                             gameID: UUID(), seeded: false))
    try? b.knowledge.save(to: paths.knowledgePath)

    t.expect(a.knowledge.observations.first { $0.signature == sig && !$0.seeded } == nil,
             "a lazily-loaded knowledge base does not notice on its own")
    a.reload()
    t.expect(a.knowledge.observations.first { $0.signature == sig && !$0.seeded } != nil,
             "after reload the app sees what was endorsed or confirmed at the prompt")

    t.suite("Provenance — three origins, not two")

    let shipped = Knowledge.Observation(signature: sig, setup: setup, worked: true, seeded: true)
    let imported = Knowledge.Observation(signature: sig, setup: setup, worked: true,
                                         gameID: nil, seeded: false, imported: true)
    let local = Knowledge.Observation(signature: sig, setup: setup, worked: true,
                                      gameID: UUID(), seeded: false)

    t.equal(shipped.origin, .shipped, "a seeded row is shipped")
    t.equal(local.origin, .local, "a row from this Mac is local")
    // The one that was wrong: imported is not seeded, so a two-way test put it
    // in the same bucket as an observation made here.
    t.equal(imported.origin, .imported, "an imported row is not described as observed here")
    t.expect(imported.origin.label != local.origin.label,
             "someone else's machine never claims to be this one")
}


/// What the CLI tells a shell.
///
/// These run the built binary rather than reasoning about it, because the thing
/// that was wrong could not be seen in the source without following the exit
/// code back to where it was chosen. `usage()` derived its status from whether
/// any argument had been given, so a command Decanter had never heard of took
/// the "an argument was given" branch and reported success — on stdout, with
/// the whole manual attached.
///
/// Neither command reaches an Engine, so nothing here touches a real library.
func runCLIExitTests(_ t: Harness) {
    t.suite("CLI — what a shell is told")

    let binary = URL(filePath: CommandLine.arguments[0])
        .deletingLastPathComponent().appending(path: "decanter")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        t.skip("CLI exit codes", "the decanter binary is not built beside selftest")
        return
    }

    func run(_ argv: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = argv
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        guard (try? p.run()) != nil else { return (-1, "", "") }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: od, as: UTF8.self),
                String(decoding: ed, as: UTF8.self))
    }

    let bogus = run(["frobnicate"])
    t.expect(bogus.status != 0, "an unknown command fails rather than reporting success")
    t.expect(bogus.err.contains("frobnicate"), "the error names the command that does not exist")
    t.expect(bogus.out.isEmpty, "nothing goes to stdout, so a pipe does not read it as help")
    // The old behaviour: seventy lines of help, which scrolls the error itself
    // off a normal terminal.
    t.expect(bogus.err.split(separator: "\n").count < 6,
             "the error is short enough to still be on screen")

    let typo = run(["knowlege"])
    t.expect(typo.err.contains("knowledge"), "a near miss is answered with the command meant")
    let nonsense = run(["zzzzzzzzzz"])
    t.expect(!nonsense.err.contains("did you mean"),
             "nothing close enough means no suggestion, rather than a wrong one")

    let help = run(["help"])
    t.equal(help.status, 0, "asking for help succeeds")
    t.expect(help.out.contains("decanter setup"), "help goes to stdout, where it was asked for")
}

/// What the app now answers without launching anything, and what it says about
/// options a build does not offer. Both were `decanter`-only, and both are
/// phrased in the shared library so the two surfaces cannot drift apart.
func runSurfaceParityTests(_ t: Harness) {
    t.suite("Would it start — said in one sentence")

    var clean = Engine.PreflightReport()
    clean.exeVisibleToWine = true
    clean.fullFilesystemExposed = false
    t.expect(clean.ok, "a clean report is ok")
    t.expect(clean.plainSummary.contains("should start"), "and says so plainly")
    t.expect(!clean.plainSummary.contains("preflight"),
             "without using a word from aviation")

    // The quiet failure this exists for: the graphics option cannot be
    // provided, Wine's own D3D loads instead, and the game dies with nothing in
    // the log. It must be said ahead of anything untidy-but-survivable.
    var blocked = clean
    blocked.blockers = ["This game is set to Metal graphics, which this Wine build cannot provide."]
    blocked.problems = ["z: maps the whole filesystem", blocked.blockers[0]]
    t.expect(!blocked.ok, "a blocker makes the report not ok")
    t.equal(blocked.plainSummary, blocked.blockers[0],
            "the blocker is what gets said, not the untidy drive mapping")

    var untidyOnly = clean
    untidyOnly.problems = ["z: maps the whole filesystem"]
    t.equal(untidyOnly.plainSummary, "z: maps the whole filesystem",
            "with no blocker, the survivable problem is still worth saying")

    // Nothing named, and the executable is invisible: the one case where the
    // report knows less than the reader needs, so it says what to do instead.
    var invisible = Engine.PreflightReport()
    invisible.fullFilesystemExposed = false
    t.expect(invisible.plainSummary.contains("cannot see"),
             "an invisible executable is named as the thing to fix")

    t.suite("What a build does not offer, and why")

    var row = Bench.RuntimeRow(runtimeID: "wine-x", kind: .wine, version: "11.0",
                               supports32Bit: true)
    row.findings = [
        .init(backend: .wined3d, provided: true, reason: "Available."),
        .init(backend: .dxmt, provided: false,
              reason: "This Wine build's display driver does not offer the Metal layer a way in."),
        .init(backend: .d3dmetal, provided: false,
              reason: "Apple's graphics translation comes only inside Apple's Game Porting Toolkit."),
    ]
    let absent = row.unavailable
    t.equal(absent.count, 2, "only the ones that are missing")
    t.expect(!absent.contains { $0.backend == .wined3d }, "and never one that is there")
    t.expect(absent.allSatisfy { !$0.reason.isEmpty },
             "each carries the reason it is missing, not just its absence")
    // The two-register rule: a reason shown without --detail may not reach for
    // a symbol or a file format. This is the plain half.
    t.expect(absent.allSatisfy { r in
        !["Mach-O", "dylib", "symbol", ".so", "export"].contains { r.reason.contains($0) }
    }, "and says it without naming a file format or a symbol")
    t.equal(row.backends.count, 1, "the available list still holds only what is provided")
}
