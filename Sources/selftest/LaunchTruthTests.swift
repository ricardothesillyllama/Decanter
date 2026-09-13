import Foundation
import DecanterKit

/// Whether a game is running is read from the processes' environment.
///
/// The app asked `pgrep -f <bottle id>`, which searches arguments, and the id
/// is never in a Wine process's arguments. Measured against real processes in
/// real prefixes on both runtimes, it matched nothing — so every launch was
/// reported as never having opened a window, while the game was on screen.
/// These pin the classification; the environment read itself is `prefix(of:)`,
/// which the reaper has relied on since it was written.
func runLivenessTests(_ t: Harness) {
    t.suite("A running game is recognised by its environment, not its arguments")

    let root = "/Users/x/Library/Application Support/Decanter/runtimes"
    // Lines as `ps -Ao pid=,command=` printed them during the measurement.
    let ps = """
      101 \(root)/wine-11.0/lib/wine/x86_64-unix/wine cmd /c
      102 \(root)/gptk-7.7/bin/wine64-preloader /Users/x/Games/Some Game/Game.exe
      103 \(root)/gptk-7.7/bin/wineserver
      104 C:\\windows\\system32\\services.exe
      105 H:\\Some Game\\Game.exe
      106 /usr/bin/python3 /Users/x/notes.py
      107 /Applications/Safari.app/Contents/MacOS/Safari
      108 winedbg --auto 104 200
    """
    let found = WineReaper.wineCandidates(psOutput: ps, runtimeRoot: root)
    let pids = Set(found.map(\.pid))
    t.expect(pids.isSuperset(of: [101, 102, 103, 104, 105, 108]),
             "everything Wine-shaped is a candidate — a runtime binary, a Windows path, a bare helper")
    t.expect(pids.contains(105),
             "including a program Wine labels with a mapped drive rather than C: or Z:")
    t.expect(pids.isDisjoint(with: [106, 107]),
             "and nothing else on the Mac has its environment read")

    t.expect(WineReaper.isProgram(command: "\(root)/wine-11.0/lib/wine/x86_64-unix/wine cmd /c"),
             "the loader running a program is the program")
    t.expect(WineReaper.isProgram(command: "\(root)/gptk-7.7/bin/wine64-preloader /Users/x/Games/Game.exe"),
             "so is GPTK's preloader")
    t.expect(WineReaper.isProgram(command: #"H:\Some Game\Game.exe"#),
             "and a game Wine has relabelled with its Windows path")
    t.expect(!WineReaper.isProgram(command: "\(root)/gptk-7.7/bin/wineserver"),
             "wineserver is not — it outlives the last program by seconds, and would keep a quit game 'running'")
    t.expect(!WineReaper.isProgram(command: #"C:\windows\system32\services.exe"#),
             "nor are Wine's own services")
    t.expect(!WineReaper.isProgram(command: #"C:\windows\system32\explorer.exe /desktop"#),
             "including the desktop explorer.exe every session starts")
    t.expect(!WineReaper.isProgram(command: "winedbg --auto 104 200"),
             "and a crash handler is the opposite of a running game")
}

/// The refusal rule matched too much.
func runRefusalRuleTests(_ t: Harness) {
    t.suite("Only Wine's own refusal means a game will never start")
    let d = Diagnostics()

    // From a real log, during a launch that went on to work.
    let vulkan = "2c70:warn:vulkan:d3dkmt_init_vulkan Failed to open the Vulkan driver"
    let v = d.analyse(text: vulkan).findings
    t.expect(!v.contains { if case .executableWouldNotStart = $0 { return true }; return false },
             "a Vulkan driver warning is not a refused executable")
    t.expect(!v.contains { $0.meansItWillNeverStart },
             "and the launch watcher is not told the game will never start")

    let other = "0024:err:mscoree:LoadLibraryShim error: failed to open config file"
    t.expect(!d.analyse(text: other).findings.contains { $0.meansItWillNeverStart },
             "nor is any other line that merely says 'failed to open'")

    let wide = #"wine: failed to open L"H:\\Game.exe": c0000135"#
    let w = d.analyse(text: wide).findings
    t.expect(w.contains { if case .executableWouldNotStart(_, let st) = $0 { return st == "c0000135" }; return false },
             "Wine's wide-string form of the refusal is still caught, status and all")
    let prefixed = #"0114:wine: failed to open "H:\\Game.exe": c000007b"#
    t.expect(d.analyse(text: prefixed).findings.contains { $0.meansItWillNeverStart },
             "and so is a refusal with a thread id in front of it")
}

/// Kept saves were kept, and then shown nowhere.
func runOrphanedSavesTests(_ t: Harness) {
    t.suite("Saves kept from a removed game can be found, and only those deleted")
    let fm = FileManager.default
    let root = Fixture.dir("kept-saves")
    let paths = Paths(root: root); try? paths.ensure()
    let store = SaveStore(paths: paths)
    let saves = root.appending(path: "saves")

    let live = saves.appending(path: "old-game/live/drive_c/users/me/AppData/LocalLow/V/P")
    try? fm.createDirectory(at: live, withIntermediateDirectories: true)
    try? Data("slot".utf8).write(to: live.appending(path: "slot1.dat"))
    let snap = saves.appending(path: "old-game/snapshots/2026-09-12T23-21-00")
    try? fm.createDirectory(at: snap.appending(path: "files"), withIntermediateDirectories: true)
    try? Data(#"{"game":"Old Game","created":"2026-09-12T23:21:00Z","files":1}"#.utf8)
        .write(to: snap.appending(path: "manifest.json"))

    // What removing a game with no saves leaves behind: a snapshot of nothing.
    let hollow = saves.appending(path: "hollow/snapshots/2026-01-01T00-00-00")
    try? fm.createDirectory(at: hollow.appending(path: "files"), withIntermediateDirectories: true)
    try? Data(#"{"game":"Hollow","files":0}"#.utf8).write(to: hollow.appending(path: "manifest.json"))

    let current = saves.appending(path: "current-game/live")
    try? fm.createDirectory(at: current, withIntermediateDirectories: true)
    try? Data("mine".utf8).write(to: current.appending(path: "a.dat"))

    let kept = store.orphanedStores(knownSlugs: ["current-game"])
    t.equal(kept.map(\.slug), ["old-game"],
            "a removed game's saves are listed, a current game's are not, and an empty store is left out")
    t.equal(kept.first?.recordedName, "Old Game", "it is named the way its snapshot recorded it")
    t.equal(kept.first?.savedFiles, 1, "and says how many save files it holds, counted once")
    t.equal(kept.first?.snapshotCount, 1, "and how many snapshots")

    t.throwsError("a current game's saves cannot be deleted through this door") {
        try store.deleteOrphanedStore(slug: "current-game", knownSlugs: ["current-game"])
    }
    t.throwsError("nor can a path") {
        try store.deleteOrphanedStore(slug: "../state.json", knownSlugs: [])
    }
    t.throwsError("nor a hidden entry") {
        try store.deleteOrphanedStore(slug: ".DS_Store", knownSlugs: [])
    }
    t.expect(fm.fileExists(atPath: current.appending(path: "a.dat").path),
             "and after all three, the current game's save is still there")
    t.survives("the kept store itself can be deleted") {
        try store.deleteOrphanedStore(slug: "old-game", knownSlugs: ["current-game"])
    }
    t.expect(!fm.fileExists(atPath: saves.appending(path: "old-game").path), "and is gone")
}

/// Pressing the picker once silenced the recommendation for good.
func runRecommendationLockTests(_ t: Harness) {
    t.suite("Trying another setup by hand does not silence Decanter forever")
    let fm = FileManager.default
    let root = Fixture.dir("lock-root")
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
        t.skip("lock round trip", "the fixture's recommendation is not a GPTK backend on this build")
        return
    }
    _ = try? e.setBackend(game, other)
    t.equal(e.store.state.games.first?.runtimeLocked, true,
            "moving off the recommendation by hand is remembered as a choice")
    if let g = e.store.state.games.first { _ = try? e.setBackend(g, rec.backend) }
    t.equal(e.store.state.games.first?.runtimeLocked, false,
            "choosing exactly what Decanter recommends is not an override, and clears it")
    t.expect(!(e.store.state.games.first.map { e.recommend(for: $0).overriddenByUser } ?? true),
             "so the recommendation is no longer treated as overridden")
    if let g = e.store.state.games.first { _ = try? e.setBackend(g, other, lockRuntime: false) }
    t.equal(e.store.state.games.first?.runtimeLocked, false,
            "and Decanter changing a setup on its own behalf never sets it")
}
