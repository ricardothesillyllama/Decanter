import Foundation
import DecanterKit

/// A prefix cloned from a template built before version markers existed carries
/// no `.decanter-dxvk` file, and used to report a bare "DXVK ?" in every
/// problem report — the one line you most want exact when rendering is broken.
func runDXVKTests(_ t: Harness) {
    t.suite("DXVK version identification")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "decanter-dxvk-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let paths = Paths(root: root)
    try? paths.ensure()

    // Two staged builds with genuinely different bytes, plus one that differs
    // only in length — size alone must not be treated as identification.
    func stage(_ version: String, _ body: Data) {
        let d = paths.runtimes.appending(path: "dxvk/\(version)/x64")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        try? body.write(to: d.appending(path: "d3d11.dll"))
    }
    let a = Data(repeating: 0xA1, count: 4096)
    let b = Data(repeating: 0xB2, count: 4096)      // same size, different bytes
    let c = Data(repeating: 0xA1, count: 8192)      // same byte, different size
    stage("1.10.3", a); stage("2.4", b); stage("3.0.2", c)

    let inst = DXVKInstaller(paths: paths)
    t.equal(Set(inst.stagedVersions()), ["1.10.3", "2.4", "3.0.2"], "all staged builds are found")

    func prefix(with dll: Data?, marker: String? = nil) -> URL {
        let p = root.appending(path: "pfx-\(UUID().uuidString)")
        let sys = p.appending(path: "drive_c/windows/system32")
        try? fm.createDirectory(at: sys, withIntermediateDirectories: true)
        if let dll { try? dll.write(to: sys.appending(path: "d3d11.dll")) }
        if let marker { try? marker.write(to: p.appending(path: ".decanter-dxvk"),
                                          atomically: true, encoding: .utf8) }
        return p
    }

    t.equal(inst.installedVersion(in: prefix(with: a)), "1.10.3",
            "an unmarked prefix is identified by the bytes of its d3d11.dll")
    t.equal(inst.installedVersion(in: prefix(with: b)), "2.4",
            "a same-sized but different build is told apart")
    t.equal(inst.installedVersion(in: prefix(with: c)), "3.0.2",
            "a same-byte but different-sized build is told apart")

    // The marker still wins: it records what Decanter actually installed, which
    // survives the staged copy being deleted or replaced.
    t.equal(inst.installedVersion(in: prefix(with: a, marker: "9.9.9")), "9.9.9",
            "an explicit marker outranks content matching")

    t.equal(inst.installedVersion(in: prefix(with: Data(repeating: 0xFF, count: 4096))), nil,
            "a build that matches nothing staged reports nil, not a wrong version")
    t.equal(inst.installedVersion(in: prefix(with: nil)), nil,
            "a prefix with no DXVK at all reports nil")
    t.equal(inst.installedVersion(in: root.appending(path: "does-not-exist")), nil,
            "a missing prefix is nil rather than a crash")
}

/// A mod loader fails in a way nothing else can see: BepInEx prints a healthy
/// banner, then a plugin throws and the game dies. Picking the real failures out
/// of that log is the whole value, so the matching has to be precise.
func runModLogTests(_ t: Harness) {
    t.suite("mod loader failures")

    let log = [
        "[Message:   BepInEx] BepInEx 5.4.22.0 - SampleGame",
        "[Info   :   BepInEx] Loading [ErrorHandler 1.2.0]",          // name contains "Error"
        "[Info   :ConfigMgr] error_reporting = false",                // config key
        "[Error  :   BepInEx] Could not load [BrokenPlugin 1.0.0]",
        "FATAL UNHANDLED EXCEPTION: System.NullReferenceException",
        "  at SplashScreenPatcher+<>c.<CommunicationThread>b__4_1 () in <filename unknown>:0",
        "[Error  :   BepInEx] Could not load [BrokenPlugin 1.0.0]",   // duplicate
    ]
    let f = ModInspector.failures(in: log)

    t.expect(!f.contains { $0.contains("ErrorHandler 1.2.0") },
             "a plugin whose NAME contains 'Error' is not a failure")
    t.expect(!f.contains { $0.contains("error_reporting") },
             "a config key containing 'error' is not a failure")
    t.expect(f.contains { $0.contains("BrokenPlugin") }, "an [Error] line is a failure")
    t.expect(f.contains { $0.contains("FATAL UNHANDLED EXCEPTION") }, "a fatal exception is a failure")
    t.expect(f.contains { $0.contains("at SplashScreenPatcher") },
             "the stack frame is kept — it names the plugin actually at fault")
    t.equal(f.filter { $0.contains("BrokenPlugin") }.count, 1,
            "a repeated failure is reported once, not once per occurrence")
    t.equal(ModInspector.failures(in: []).count, 0, "an empty log yields nothing")
    t.expect(ModInspector.failures(in: ["all fine here"]).isEmpty, "a clean log yields nothing")
}

/// Stopping one game must not touch another. The reaper's filter is the only
/// thing standing between "quit this hung game" and "kill everything the user
/// has open", so the prefix match is worth pinning down.
func runStopScopeTests(_ t: Harness) {
    t.suite("per-game stop scoping")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "decanter-stop-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    let mine = root.appending(path: "bottles/mine")
    let other = root.appending(path: "bottles/other")
    for d in [mine, other] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }

    func stray(_ prefix: URL?) -> WineReaper.Stray {
        WineReaper.Stray(pid: 1, cpu: 0, elapsed: "00:10",
                         command: #"C:\windows\system32\explorer.exe"#,
                         prefix: prefix, isService: true)
    }
    // Exactly the comparison Engine.stop uses.
    let target = mine.pathKey
    func matches(_ s: WineReaper.Stray) -> Bool {
        guard let p = s.prefix else { return false }
        return p.pathKey == target
    }

    t.expect(matches(stray(mine)), "a process in this game's prefix is selected")
    t.expect(!matches(stray(other)), "a process in another game's prefix is spared")
    t.expect(!matches(stray(nil)),
             "a process whose prefix cannot be read is spared, not killed on a guess")
    // /var vs /private/var has broken path comparison in this codebase three
    // times; stopping a game must not become "kill everything" because of it.
    // The two shapes that broke this: a plain path URL (what ps gives us) and
    // the /var form of a /private/var path.
    t.expect(matches(stray(URL(filePath: mine.path))),
             "a plain path URL matches a directory-flagged one for the same folder")
    t.expect(matches(stray(URL(filePath: mine.path.replacingOccurrences(of: "/private/var", with: "/var")))),
             "the same prefix reached through /var still matches")
    t.expect(matches(stray(URL(filePath: mine.path + "/"))),
             "a trailing slash does not change the identity")
}

/// A save browser that lists log files is worse than none: it offers junk for
/// backup and, more damagingly, warns that "saves are still inside the prefix"
/// when the only things in there are logs — so rebuilding looks dangerous when
/// it is not.
func runSaveNoiseTests(_ t: Harness) {
    t.suite("save discovery noise")

    func noise(_ path: String) -> Bool { SaveStore.isNoise(URL(filePath: "/x/" + path)) }

    // Unity names its player log with a .txt extension, which is exactly how it
    // slipped past an extension-only filter and showed up as a 400 KB "save".
    t.expect(noise("output_log.txt"), "Unity's output_log.txt is not a save")
    t.expect(noise("Player.log"), "Unity's Player.log is not a save")
    t.expect(noise("prev_output_log.txt"), "the rolled copy is not a save either")
    t.expect(noise("index.dat"), "Internet Explorer's index.dat is not a save")
    t.expect(noise("LogOutput.log"), "BepInEx's loader log is not a save")
    t.expect(noise("something.tmp"), "temp files are still skipped")

    // The point of the filter is to keep real saves, so over-matching is the
    // failure that actually loses data.
    t.expect(!noise("savedata.txt"), "a plainly named .txt save is kept")
    t.expect(!noise("player.dat"), "a .dat save is kept")
    t.expect(!noise("prefs"), "an extensionless prefs file is kept")
    t.expect(!noise("catalog.json"), "a .json save is kept")
    t.expect(!noise("slot1.sav"), "a .sav file is kept")

    // Windows' own cache directories should never be walked into.
    t.expect(SaveStore.isCachePath(["AppData", "Local", "Microsoft", "Windows", "INetCache"]),
             "INetCache is treated as a cache directory")
    t.expect(SaveStore.isCachePath(["INetCache", "Content.IE5"]),
             "Content.IE5 is treated as a cache directory")
    t.expect(!SaveStore.isCachePath(["AppData", "LocalLow", "SomeStudio", "SomeGame"]),
             "an ordinary Unity save folder is not mistaken for a cache")
}

/// The raw loader line is accurate and useless: "Could not load [UIScale 0.9.0]
/// : missing dependency" does not tell most people that a mod is broken, which
/// one, or whether the game will still start.
func runModExplainTests(_ t: Harness) {
    t.suite("mod failures in plain language")

    func e(_ s: String) -> String { ModInspector.explain(s) }

    let dep = e("[Error  :   BepInEx] Could not load [UIScale 0.9.0] : missing dependency")
    t.expect(dep.contains("UIScale 0.9.0"), "names the mod that failed")
    t.expect(dep.lowercased().contains("not installed"), "says a required mod is missing")
    t.expect(!dep.contains("[Error"), "drops the severity tag")

    t.expect(e("[Error  :   BepInEx] Could not load [OldMod 1.0]").contains("failed to load"),
             "a plain load failure is described as one")
    t.expect(e("FATAL UNHANDLED EXCEPTION: System.NullReferenceException")
                .lowercased().contains("loader itself crashed"),
             "a fatal loader crash is distinguished from one broken mod")
    t.expect(e("[Error :BepInEx] [CameraTools] threw NullReferenceException")
                .contains("CameraTools"),
             "a crash still names the mod")
    t.expect(!e("[Error  :   BepInEx] something odd happened").isEmpty,
             "an unrecognised failure still produces a sentence")
}

/// A big install can hold thirty executables and exactly one is the game.
/// Getting this wrong is what made the picker unusable: the interesting entry
/// buried under crash handlers and redistributables.
func runExecutableClassifyTests(_ t: Harness) {
    t.suite("executable classification")
    func k(_ n: String, path: String = "") -> Detector.ExecutableChoice.Kind {
        Detector.classify(name: n, path: path.isEmpty ? "/g/" + n : path).0
    }

    // Things that are never the game.
    for n in ["UnityCrashHandler64.exe", "CrashReportClient.exe", "unins000.exe",
              "Uninstall.exe", "GameUpdater.exe"] {
        t.equal(k(n), .noise, "\(n) is noise")
    }
    for n in ["vcredist_x64.exe", "DXSETUP.exe", "dxwebsetup.exe",
              "dotnetfx45.exe", "oalinst.exe", "UEPrereqSetup_x64.exe"] {
        t.equal(k(n), .installer, "\(n) is a prerequisite installer")
    }
    for n in ["Config.exe", "SettingTool.exe", "GameLauncher.exe", "LevelEditor.exe"] {
        t.equal(k(n), .tool, "\(n) is a tool")
    }
    // …and the ones that must survive as candidates.
    for n in ["SampleGame.exe", "Start Sample Game.exe", "Adventure.exe", "hl2.exe"] {
        t.equal(k(n), .game, "\(n) stays a game candidate")
    }
    t.equal(k("Shipping.exe", path: "/g/SampleGame/Binaries/Win64/Shipping.exe"), .tool,
            "an Unreal inner binary is a tool, not the thing to launch")

    // Ordering is what the menu depends on.
    let fixture = Fixture.noisy()
    let list = Detector().listExecutables(in: fixture)
    t.expect(!list.isEmpty, "the noisy fixture produces choices")
    if let first = list.first {
        t.expect(first.isLikelyGame || first.kind == .game,
                 "the first entry is a game candidate, not a crash handler")
    }
    let kinds = list.map(\.kind)
    t.equal(kinds, kinds.sorted(), "entries are grouped by purpose, games first")
}

/// "Not scanned yet" and "scanned, found one" are different facts. Collapsing
/// them into an empty array made the picker announce "only executable in this
/// folder" before it had looked, then correct itself — which read as the
/// control being unreliable rather than slow.
func runExecutableStateTests(_ t: Harness) {
    t.suite("executable picker state")

    // Mirrors AppModel.executableState, which cannot be reached from here
    // because it lives in the app target.
    enum State: Equatable { case unknown, scanning, loaded(Int) }
    func state(cache: [Int]?, scanning: Bool) -> State {
        if scanning { return .scanning }
        guard let c = cache else { return .unknown }
        return .loaded(c.count)
    }

    t.equal(state(cache: nil, scanning: false), .unknown,
            "no cache entry means we have not looked, not that there is nothing")
    t.equal(state(cache: nil, scanning: true), .scanning, "an in-flight scan is scanning")
    t.equal(state(cache: [1], scanning: false), .loaded(1), "one executable is a real answer")
    t.equal(state(cache: [], scanning: false), .loaded(0), "zero is also a real answer")

    // The property that actually mattered: only .loaded may claim there is
    // just one executable.
    for s in [State.unknown, .scanning] {
        t.expect(s != .loaded(1), "\(s) must never be reported as 'only executable'")
    }
}
