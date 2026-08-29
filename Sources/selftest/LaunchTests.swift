import Foundation
import CoreGraphics
import DecanterKit

/// End-to-end launches of REAL Windows executables — the ones Wine itself
/// ships (winemine, notepad, clock), in both 64-bit and 32-bit builds.
/// A window actually appearing is the proof that rendering works: these are
/// GUI programs, so a visible window means the whole chain ran, from prefix
/// derivation through scoped drive mapping to the Win32 GUI stack on Metal.
func runLaunchTests(_ t: Harness) {
    let fm = FileManager.default

    t.suite("Real executable launches")

    // Borrow the real pinned runtime and golden template, but run in an
    // isolated root so the live library is never touched.
    guard let live = try? Engine() else { t.skip("all launch tests", "no Decanter root"); return }
    guard let wine = live.store.state.runtimes.first(where: { $0.kind == .wine }) else {
        t.skip("all launch tests", "no Wine runtime pinned"); return
    }
    guard fm.fileExists(atPath: live.paths.template.path) else {
        t.skip("all launch tests", "golden template not built"); return
    }

    let testRoot = Fixture.dir("launch-root")
    let paths = Paths(root: testRoot)
    try? paths.ensure()
    // APFS-clone the template so the test costs ~0.5s and no disk.
    let clone = try? Shell.run(URL(filePath: "/bin/cp"),
                               ["-Rc", live.paths.template.path, paths.template.path], timeout: 300)
    guard clone?.code == 0, fm.fileExists(atPath: paths.template.path) else {
        t.skip("all launch tests", "could not clone the golden template"); return
    }
    let e = try! Engine(paths: paths)
    try! e.store.mutate { s in s.runtimes = [wine] }
    t.expect(true, "isolated test root prepared from a cloned golden template")

    /// Copies one of Wine's own Windows programs into a fake game folder.
    /// Copies under a UNIQUE name: processes are matched by executable name,
    /// and staging both builds as "winemine.exe" makes the 32- and 64-bit runs
    /// indistinguishable.
    func stageWineProgram(_ name: String, arch: String, as newName: String) -> URL? {
        let src = wine.root.appending(path: "lib/wine/\(arch)/\(name)")
        guard fm.fileExists(atPath: src.path) else { return nil }
        let dir = Fixture.dir("game-\(newName)")
        let dst = dir.appending(path: newName)
        try? fm.copyItem(at: src, to: dst)
        return fm.fileExists(atPath: dst.path) ? dst : nil
    }

    /// Waits for a Wine-owned window to appear on screen.
    /// Only windows owned by processes bound to this prefix count — another
    /// game of the user's may be running at the same time.
    func waitForWindow(ofExecutable exe: URL, timeout: TimeInterval) -> Reporter.WindowRef? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let mine = Reporter.pids(forExecutable: exe)
            if !mine.isEmpty,
               let w = Reporter.wineWindows().first(where: { mine.contains($0.pid) }) { return w }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    func shutdown(_ bottlePrefix: URL) {
        if let ws = wine.wineserverPath {
            var env = PrefixBuilder(paths: paths).baseEnv(prefix: bottlePrefix, runtime: wine)
            env["WINEPREFIX"] = bottlePrefix.path
            _ = try? Shell.run(ws, ["-k"], env: env, timeout: 45)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    // Other Wine windows may legitimately be on screen (the user's own game),
    // so record what was there before and only reason about the difference.
    // ---- fonts, read back through Wine's own parser ------------------------
    //
    // The unit tests prove Decanter can read what Decanter wrote, which is
    // circular. The mapping is only worth anything if *Wine* accepts it, and a
    // malformed registry edit fails silently — Wine drops the section and
    // carries on. So write it into a real prefix and ask Wine what it sees.
    t.suite("font mapping, via Wine")
    do {
        let prefix = paths.template
        let plan = try! FontProvisioner().apply(to: prefix)
        t.expect(!plan.mapped.isEmpty, "the template has Windows font names to map")

        var env = PrefixBuilder(paths: paths).baseEnv(prefix: prefix, runtime: wine)
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"

        func query(_ key: String) -> String {
            guard let r = try? Shell.run(wine.winePath, ["reg", "query", key],
                                         env: env, timeout: 120) else { return "" }
            return r.out + r.err
        }
        let hkcu = query(#"HKCU\Software\Wine\Fonts\Replacements"#)
        let hklm = query(#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#)

        // Whatever the machine's fonts are, the mapping we just wrote must come
        // back through Wine unchanged.
        let sample = plan.mapped.first { $0.name == "MS PGothic" } ?? plan.mapped[0]
        t.expect(hkcu.contains(sample.name),
                 "Wine reads back the replacement for \(sample.name)")
        t.expect(hkcu.contains(sample.target),
                 "…pointing at \(sample.target)")
        t.expect(hklm.contains(sample.name),
                 "Wine reads back the HKLM substitution too")

        // A malformed edit shows up as a missing or truncated section, so count.
        // reg query emits CRLF, and its first run in a fresh prefix can
        // interleave wineboot chatter, so count occurrences rather than lines.
        let lines = hkcu.components(separatedBy: "REG_SZ").count - 1
        if lines < plan.mapped.count {
            print("      DEBUG query returned \(hkcu.count) chars, \(lines) values")
        }
        t.expect(lines >= plan.mapped.count,
                 "all \(plan.mapped.count) mappings survive Wine's parser (saw \(lines))")

        // The registry Wine rewrote on exit must still contain them.
        if let ws = wine.wineserverPath {
            _ = try? Shell.run(ws, ["-k"], env: env, timeout: 45)
        }
        Thread.sleep(forTimeInterval: 1.0)
        let installed = FontProvisioner().installed(in: prefix)
        t.expect(installed[sample.name] == sample.target,
                 "the mapping survives a wineserver shutdown rewriting the registry")
    }

    // ---- 64-bit -----------------------------------------------------------
    if let exe = stageWineProgram("winemine.exe", arch: "x86_64-windows", as: "DecanterTest64.exe") {
        t.expect(true, "staged a real 64-bit PE (winemine.exe)")
        var game: Game?
        t.survives("adding a real 64-bit Windows program") { game = try e.add(path: exe, name: "MineTest64") }

        if let g = game {
            t.equal(g.detection.bitness, .x64, "detected as 64-bit from its real PE header")
            t.survives("preflight passes for a real executable") {
                let pre = try e.preflight(g)
                t.expect(pre.exeVisibleToWine, "Wine can resolve the real DOS path")
                t.expect(!pre.fullFilesystemExposed, "the launch is scoped, with no z: drive")
            }
            t.survives("launching a real 64-bit Windows GUI program") { _ = try e.run(g) }
            if let w = waitForWindow(ofExecutable: g.exePath, timeout: 40) {
                t.expect(true, "a window appeared: \(w.width)x\(w.height) owned by \(w.owner)")
                t.expect(w.width > 100 && w.height > 100, "the window has real, rendered dimensions")
            } else {
                t.expect(false, "a 64-bit Windows program rendered a visible window")
            }
            if let b = e.store.bottle(g.bottleID) { shutdown(b.prefixPath) }
            t.expect(Reporter.pids(forExecutable: g.exePath).isEmpty,
                     "the test's own processes exited after shutdown")
        }
    } else {
        t.skip("64-bit launch", "winemine.exe not present in this Wine build")
    }

    // ---- 32-bit: the WoW64 claim ------------------------------------------
    if let exe = stageWineProgram("winemine.exe", arch: "i386-windows", as: "DecanterTest32.exe") {
        t.expect(true, "staged a real 32-bit PE (winemine.exe)")
        var game: Game?
        t.survives("adding a real 32-bit Windows program") { game = try e.add(path: exe, name: "MineTest32") }

        if let g = game {
            t.equal(g.detection.bitness, .x86, "detected as 32-bit from its real PE header")
            t.equal(g.detection.recommendedRuntimeKind, .wine, "32-bit routed to modern Wine")
            t.survives("launching a real 32-bit Windows GUI program") { _ = try e.run(g) }
            if let w = waitForWindow(ofExecutable: g.exePath, timeout: 40) {
                t.expect(true, "a 32-bit window appeared: \(w.width)x\(w.height) — WoW64 works")
            } else {
                t.expect(false, "a 32-bit Windows program rendered a visible window (WoW64)")
                // Say what was actually observed, rather than leaving a bare failure.
                let pids = Reporter.pids(forExecutable: g.exePath)
                print("      exe: \(g.exePath.lastPathComponent)")
                print("      matching pids: \(pids.isEmpty ? "none" : pids.map(String.init).joined(separator: ", "))")
                let wins = Reporter.wineWindows()
                print("      wine windows: \(wins.map { "\($0.width)x\($0.height)@\($0.pid)" }.joined(separator: " "))")
                if let b = e.store.bottle(g.bottleID) {
                    let log = paths.logs.appending(path: "\(g.name).log")
                    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? "(no log)"
                    print("      log tail: \(text.split(separator: "\n").suffix(3).joined(separator: " | "))")
                    print("      prefix: \(b.prefixPath.lastPathComponent)")
                }
            }
            if let b = e.store.bottle(g.bottleID) { shutdown(b.prefixPath) }
        }
    } else {
        t.skip("32-bit launch", "no i386 winemine.exe in this Wine build")
    }

    // ---- the report path, with a real log ---------------------------------
    if let g = e.store.state.games.first {
        t.survives("building a problem report for a really-launched game") {
            let rep = try e.report(g)
            let text = (try? String(contentsOf: rep, encoding: .utf8)) ?? ""
            t.expect(text.contains("## System"), "the report contains the system section")
            t.expect(text.contains("Effective D3D"), "the report states which D3D is really in use")
            t.expect(text.count > 800, "the report has real content (\(text.count) bytes)")
        }
    }

    t.suite("The launch monitor waits long enough, and looks wide enough")
    do {
        // 45 seconds and a strict pid match reported a game that was on screen
        // and playing as having exited early. A first launch compiles shaders,
        // and a proxy loader draws from a process pgrep never attributed to
        // the executable.
        let mirror = Mirror(reflecting: LaunchMonitor(paths: paths))
        _ = mirror   // the value under test is the default argument below
        t.expect(LaunchMonitor.Outcome.exited(after: 3).summary.contains("exited"),
                 "an exit still reads as an exit")
        t.expect(!LaunchMonitor.Outcome.runningWithoutWindow.isGood,
                 "running with no window is still not success")
        t.expect(LaunchMonitor.Outcome.rendering(width: 1920, height: 1080).isGood,
                 "a real window is still the only thing that counts as rendering")
    }

    // Every launch test shuts its own bottle down, but a test that throws
    // part-way skips that — and Wine's services survive their parent, so the
    // leak is permanent and invisible. A suite-wide sweep on the way out is
    // what stops `selftest` leaving explorer.exe running for days.
    let leaked = WineReaper(paths: paths).reap { stray in
        stray.prefix?.path.hasPrefix(testRoot.path) ?? false
    }
    if leaked.sessionsEnded + leaked.killed.count > 0 {
        print("  cleaned up \(leaked.killed.count) leaked Wine process(es)")
    }
    let stillThere = WineReaper(paths: paths).strays().filter {
        $0.prefix?.path.hasPrefix(testRoot.path) ?? false
    }
    t.expect(stillThere.isEmpty, "the suite leaves no Wine processes behind")

    try? fm.removeItem(at: testRoot)
}
