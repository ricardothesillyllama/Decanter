import Foundation
import DecanterKit

// Minimal hand-rolled CLI. No argument-parser dependency on purpose: an
// external package is one more thing that can disappear.

let argv = Array(CommandLine.arguments.dropFirst())
let verbose = argv.contains("--verbose") || argv.contains("-v")
let args = argv.filter { $0 != "--verbose" && $0 != "-v" }

func out(_ s: String)  { print(s) }
func step(_ s: String) { print("  \u{2022} \(s)") }
func ok(_ s: String)   { print("  \u{2713} \(s)") }
func warn(_ s: String) { FileHandle.standardError.write(Data("  ! \(s)\n".utf8)) }

func die(_ e: Error) -> Never {
    let msg = (e as? LocalizedError)?.errorDescription ?? "\(e)"
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    if verbose { FileHandle.standardError.write(Data("detail: \(e)\n".utf8)) }
    // Leave a breadcrumb so failures are debuggable after the fact.
    if let e2 = try? Engine() {
        let f = e2.paths.logs.appending(path: "decanter-errors.log")
        try? FileManager.default.createDirectory(at: e2.paths.logs, withIntermediateDirectories: true)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(args.joined(separator: " ")): \(msg)\n"
        if let fh = try? FileHandle(forWritingTo: f) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
    exit(1)
}

func usage() -> Never {
    out("""
    decanter — run Windows games on macOS

    SETUP
      decanter doctor                 check the stack (Rosetta, runtimes, template)
      decanter pin                    take Decanter's own copy of every Wine build found\n      decanter runtime add <root>     pin a Wine/GPTK build from any location\n      decanter runtime list           show pinned runtimes\n      decanter runtime set <game> <id>  move a game to another runtime
      decanter template build [rt]    build the golden template for a runtime
      decanter template list          which runtimes have a template\n      decanter dxvk stage <tar.gz>    bake DXVK into future templates\n      decanter dxvk list              staged versions and what each game uses
      decanter dxvk use <game> <ver>  switch a game to a specific DXVK version
      decanter dxvk prefer <ver>      which version new templates bake in

    GAMES
      decanter add <path> [--name N] [--exe NAME]   add a game; --exe picks which one
      decanter exe <game>             list executables; pick one, or run one once
      decanter list                   list games
      decanter info <game>            show detection evidence and settings
      decanter run <game>             launch it\n      decanter check <game>           dry-run: verify it WOULD launch, without starting it
      decanter redetect [game]        re-inspect with the current rules (all games if omitted)
      decanter args <game> [flags]    engine switches like -force-d3d12 (no args = show suggestions)
      decanter env <game> [japanese]  environment/locale overrides for CJK games
      decanter recommend <game>       which setup to use, and why (launches nothing)
      decanter worked <game>          remember the current setup as working
      decanter knowledge              what Decanter has learned so far
      decanter autoconfig <game>      try each setup for real and keep the one that works
      decanter rederive <game>        throw the prefix away and rebuild it
      decanter diagnose <game>        explain the last failure
      decanter run <game> --debug     launch with verbose graphics logging (no overlay)
      decanter run <game> --hud       show the graphics overlay (off by default)
      decanter report <game>          full problem report + screenshot, copied to clipboard
      decanter import <game> <dir>    restore saves (files + registry) into its prefix
      decanter remove <game>          delete the game and its prefix (saves kept by default)
      decanter mods <game>            BepInEx status, plugins, and whether the loader ran
      decanter fonts [--check]        map Windows font names (MS PGothic, Segoe UI) onto macOS faces
      decanter reap [--list]          find and end Wine processes left running by a previous session
      decanter install <game> fmv     install dependencies (presets or raw winetricks verbs)
      decanter recipes                presets, helper status, and what each game has

    SAVES
      decanter saves list             every game's saves at a glance
      decanter saves show <game>      what was found, and where
      decanter saves snapshot <game>  snapshot now (--all for every game)
      decanter saves snapshots <game> list snapshots
      decanter saves restore <game>   restore the newest snapshot (or name one)
      decanter saves search <text>    search across every game's saves
      decanter saves externalise <game>  move saves out of the prefix (--all)
      decanter saves gc               prune old snapshots

    BOTTLES
      decanter bottles                list prefixes, runtime, backend, health\n      decanter gc                     delete prefixes no game points at
      decanter backend <game> <dxvk|d3dmetal|wined3d>

    Add --verbose for detail.
    """)
    exit(args.isEmpty ? 1 : 0)
}

guard let cmd = args.first else { usage() }
let rest = Array(args.dropFirst())

func engine() -> Engine {
    do { return try Engine() } catch { die(error) }
}

func requireGame(_ name: String?) -> (Engine, Game) {
    let e = engine()
    guard let name else { die(DecanterError.notFound("game name required")) }
    let matches = e.store.gamesMatching(name)
    if matches.count > 1 {
        warn("'\(name)' matches \(matches.count) games: \(matches.map(\.name).joined(separator: ", "))")
        die(DecanterError.notFound("be more specific"))
    }
    guard let g = matches.first else {
        let known = e.store.state.games.map(\.name).joined(separator: ", ")
        die(DecanterError.notFound("game '\(name)'. Known: \(known.isEmpty ? "none" : known)"))
    }
    return (e, g)
}

func humanBytes(_ b: Int) -> String {
    if b >= 1_000_000_000 { return String(format: "%.1f GB", Double(b) / 1e9) }
    if b >= 1_000_000 { return String(format: "%.1f MB", Double(b) / 1e6) }
    if b >= 1_000 { return "\(b / 1000) KB" }
    return "\(b) B"
}

switch cmd {

case "doctor":
    let e = engine()
    let h = e.doctor()
    out("Decanter doctor")
    out("  root: \(e.paths.root.path)")
    print(h.rosetta ? "  \u{2713} Rosetta 2 present" : "  \u{2717} Rosetta 2 MISSING — Wine cannot run")
    // This scan looks for Wine installed *elsewhere* on the Mac, to import.
    // Decanter stages its own runtimes, so finding none is only a problem when
    // nothing is pinned yet — warning either way made a healthy install look
    // broken.
    if h.discovered.isEmpty {
        if h.pinnedRuntimes.isEmpty {
            warn("no Wine found to import — install Game Porting Toolkit, then run `decanter pin`")
        } else {
            out("  \u{00b7} no other Wine installs to import (using Decanter's own staged runtimes)")
        }
    }
    for c in h.discovered {
        out("  found: \(c.kind.rawValue) \(c.version)  32-bit:\(c.supports32Bit ? "yes" : "no")  \(c.wineRoot.path)")
    }
    if h.pinnedRuntimes.isEmpty { warn("nothing pinned yet — run `decanter pin`") }
    for r in h.pinnedRuntimes {
        out("  pinned: \(r.id)  backends: \(r.backends.map(\.label).joined(separator: ", "))")
    }
    if h.templateBuilt {
        let age = h.templateAge.map { " (\(Int($0 / 86400))d old)" } ?? ""
        ok("golden template built\(age)")
    } else { warn("golden template not built — run `decanter template build`") }
    out(h.gamesDirExists ? "  \u{2713} ~/Games exists" : "  · ~/Games does not exist yet")
    out("  games: \(e.store.state.games.count)   bottles: \(e.store.state.bottles.count)")
    // A leaked Wine session keeps burning CPU under Decanter's name long after
    // the app quits, so the only place the user can see it is here.
    // DXMT is the only route to Direct3D 11 straight to Metal, and whether a
    // Wine build can host it is a property of the binary, not a guess.
    for r in h.pinnedRuntimes {
        let m = e.runtimes.metalHosting(of: r)
        if m.driverPath == nil { continue }
        let verdict = m.looksCapable ? "could host DXMT (untested)"
            : m.hasCocoaViewAccess ? "partial — no WineMetalView"
            : "cannot host DXMT (macOS driver symbols hidden)"
        out("  \(r.id): \(verdict)")
    }
    let strays = e.strayWineProcesses()
    let old = strays.filter { $0.age > 3600 }
    let hot = strays.filter { $0.cpu >= 50 }
    if !hot.isEmpty {
        warn("\(hot.count) Wine process(es) pinned at high CPU — run `decanter reap`")
        for s in hot { out("      \(s.displayName) — \(Int(s.cpu))% CPU for \(s.elapsed)") }
    } else if !old.isEmpty {
        warn("\(old.count) Wine process(es) running over an hour — run `decanter reap --list`")
    } else if strays.isEmpty {
        ok("no leftover Wine processes")
    }

case "pin":
    let e = engine()
    do {
        let pinned = try e.pinAll(progress: step)
        if pinned.isEmpty { warn("nothing found to pin") }
        for r in pinned { ok("pinned \(r.id) -> \(r.root.path)") }
    } catch { die(error) }

case "template":
    let e = engine()
    if rest.first == "build" {
        let which = rest.count > 1 ? rest[1] : nil
        do {
            try e.buildTemplate(runtimeID: which, progress: step)
            ok("template ready")
        } catch { die(error) }
    } else if rest.first == "list" || rest.isEmpty {
        for rt in e.store.state.runtimes {
            let u = e.paths.template(for: rt.id)
            let built = FileManager.default.fileExists(atPath: u.path)
            out("  \(rt.id): \(built ? "\u{2713} built" : "\u{2717} missing — run `decanter template build \(rt.id)`")")
        }
        let missing = e.runtimesWithoutTemplate()
        if !missing.isEmpty {
            warn("games cannot use \(missing.map(\.id).joined(separator: ", ")) until their template exists")
        }
    } else { usage() }

case "add":
    guard let p = rest.first, !p.hasPrefix("--") else { die(DecanterError.notFound("path required")) }
    var name: String? = nil
    if let i = rest.firstIndex(of: "--name"), i + 1 < rest.count { name = rest[i + 1] }
    var chosenExe: String? = nil
    if let i = rest.firstIndex(of: "--exe"), i + 1 < rest.count { chosenExe = rest[i + 1] }
    let e = engine()
    do {
        var url = URL(filePath: (p as NSString).expandingTildeInPath).standardizedFileURL
        // --exe picks among the executables in that folder rather than guessing.
        if let want = chosenExe {
            let choices = e.detector.listExecutables(in: url)
            if let m = choices.first(where: { $0.relativePath.lowercased().contains(want.lowercased())
                                           || $0.url.lastPathComponent.lowercased() == want.lowercased() }) {
                url = m.url
            } else {
                warn("no executable matching '\(want)' — falling back to automatic detection")
                for c in choices.prefix(8) { out("    \(c.relativePath)") }
            }
        }
        let g = try e.add(path: url, name: name, progress: step)
        ok("added \(g.name)")
        out("    engine:     \(g.detection.engine.label)  \(g.detection.bitness.label)")
        out("    graphics:   \(g.detection.graphicsAPIs.isEmpty ? "none detected" : g.detection.graphicsAPIs.joined(separator: ", "))")
        out("    backend:    \(g.detection.recommendedBackend.label)")
        out("    confidence: \(String(format: "%.2f", g.detection.confidence))")
        if g.detection.modded { out("    modded:     yes (BepInEx/Doorstop)") }
    } catch { die(error) }

case "list":
    let e = engine()
    if e.store.state.games.isEmpty { out("no games yet — decanter add <path>") }
    for g in e.store.state.games.sorted(by: { $0.name < $1.name }) {
        let b = e.store.bottle(g.bottleID)
        let last = g.lastPlayed.map { " last played \(DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short))" } ?? ""
        out("  \(g.name)  [\(g.detection.engine.label), \(g.detection.bitness.label), \(b?.backend.label ?? "?")]\(last)")
    }

case "info":
    let (e, g) = requireGame(rest.first)
    let b = e.store.bottle(g.bottleID)
    out("\(g.name)")
    out("  exe:        \(g.exePath.path)")
    out("  engine:     \(g.detection.engine.label)   \(g.detection.bitness.label)")
    out("  backend:    \(b?.backend.label ?? "?")   runtime: \(b?.runtimeID ?? "?")")
    out("  prefix:     \(b?.prefixPath.path ?? "?")  (generation \(b?.generation ?? 0))")
    out("  health:     \(b?.health.label ?? "?")")
    out("  confidence: \(String(format: "%.2f", g.detection.confidence))")
    out("  scopes:")
    for s in g.scopes { out("    \(s.letter): -> \(s.hostPath.path)\(s.readOnly ? " (ro)" : "")") }
    if let log = b?.changeLog, !log.isEmpty {
        out("  history:")
        for l in log.suffix(8) { out("    \(l)") }
    }
    out("  evidence:")
    for s in g.detection.signals { out("    [\(String(format: "%.2f", s.weight))] \(s.rule)") }

case "run":
    let (e, g) = requireGame(rest.first)
    let debugRun = rest.contains("--debug")
    let hud = rest.contains("--hud")
    do {
        let plan = try e.run(g, verbose: debugRun, showHUD: hud)
        if debugRun { out("  troubleshoot mode: verbose graphics logging is on") }
        out("  starting \(g.name) via \(plan.runtime.id) / \(plan.bottle.backend.label)…")
        if rest.contains("--no-wait") {
            ok("launched (not waiting)")
        } else {
            // Fire-and-forget gave no clue whether it worked; watch and report.
            let r = LaunchMonitor(paths: e.paths).observe(game: g, engineLog: e.engineLog(for: g))
            switch r.outcome {
            case .rendering(let w, let h):
                ok("\(g.name) is running — \(w)x\(h)")
                if r.videoBroken {
                    warn("video is not playing on this backend; try: decanter backend \(g.name) wined3d")
                } else if !r.survived {
                    warn("it rendered but did not stay running — not recording this as working")
                } else if !r.findings.isEmpty {
                    warn("it is running, but the engine log reports problems — not recording this as working")
                } else {
                    try? e.rememberWorking(g)
                    out("    remembered this setup for games like it")
                }
            case .runningWithoutWindow:
                warn("running, but no window appeared after 45s")
            case .exited(let t):
                warn("exited after \(Int(t))s — it did not stay running")
            case .neverStarted:
                warn("it never started")
            }
            for f in r.findings { out("    \u{2717} \(f.summary)"); out("      -> \(f.suggestion)") }
            if !r.outcome.isGood { out("    try: decanter autoconfig \(g.name)") }
        }
        out("    log: \(plan.logFile.path)")
    } catch { die(error) }

case "rederive":
    let (e, g) = requireGame(rest.first)
    do { let b = try e.rederive(g, progress: step); ok("re-derived \(g.name) -> generation \(b.generation)") }
    catch { die(error) }

case "diagnose":
    let (e, g) = requireGame(rest.first)
    let rep = e.diagnose(g)
    out("diagnosis for \(g.name)")
    if let pl = e.engineLog(for: g) { out("  (also read the game's own log: \(pl.lastPathComponent))") }
    if rep.isEmpty {
        ok("nothing obviously wrong in the log")
    } else {
        for f in rep.findings {
            out("  \u{2717} \(f.summary)")
            out("    -> \(f.suggestion)")
        }
    }
    if verbose {
        if let lp = rep.logPath { out("  --- last lines of \(lp.path) ---") }
        for l in rep.tail { out("    \(l)") }
    }

case "import":
    guard rest.count >= 2 else { die(DecanterError.notFound("usage: decanter import <game> <dir>")) }
    let (e, g) = requireGame(rest[0])
    do {
        let src = URL(filePath: (rest[1] as NSString).expandingTildeInPath)
        let r = try e.importSaves(into: g, from: src, progress: step)
        ok("imported \(r.filesCopied) files (\(r.bytesCopied / 1024) KB)")
        if !r.remappedUsers.isEmpty { out("    remapped Windows user(s): \(r.remappedUsers.joined(separator: ", "))") }
        if !r.regFilesMerged.isEmpty { out("    merged registry: \(r.regFilesMerged.joined(separator: ", "))") }
        if !r.skipped.isEmpty { warn("skipped \(r.skipped.count): \(r.skipped.prefix(5).joined(separator: ", "))") }
    } catch { die(error) }

case "bottles":
    let e = engine()
    if e.store.state.bottles.isEmpty { out("no bottles yet") }
    for b in e.store.state.bottles {
        let owner = e.store.state.games.first { $0.bottleID == b.id }?.name ?? "(orphan)"
        out("  \(owner)  gen \(b.generation)  \(b.runtimeID)  \(b.backend.label)  \(b.health.label)")
        out("      \(b.prefixPath.path)")
    }

case "backend":
    guard rest.count >= 2, let nb = GraphicsBackend(rawValue: rest[1].lowercased()) else {
        die(DecanterError.notFound("usage: decanter backend <game> <dxvk|d3dmetal|wined3d>"))
    }
    let (e, g) = requireGame(rest[0])
    do {
        try e.store.mutate { s in
            if let i = s.bottles.firstIndex(where: { $0.id == g.bottleID }) { s.bottles[i].backend = nb }
            if let i = s.games.firstIndex(where: { $0.id == g.id }) { s.games[i].runtimeLocked = true }
        }
        ok("\(g.name) now uses \(nb.label) (choice locked against auto-detection)")
    } catch { die(error) }

case "gc":
    let e = engine()
    do {
        let r = try e.gc(progress: step)
        if r.bottles == 0 { ok("nothing to clean") }
        else { ok("removed \(r.bottles) orphan prefix(es), \(r.bytes / 1_000_000) MB apparent") }
    } catch { die(error) }

case "dxvk":
    let e = engine()
    let inst = DXVKInstaller(paths: e.paths)
    if rest.first == "stage", rest.count > 1 {
        do {
            let v = try inst.stage(tarball: URL(filePath: (rest[1] as NSString).expandingTildeInPath), progress: step)
            ok("DXVK \(v) staged")
        } catch { die(error) }
    } else if rest.first == "status" || rest.first == "list" || rest.isEmpty {
        let versions = inst.stagedVersions()
        out(versions.isEmpty ? "  ! no DXVK staged" : "  staged versions: \(versions.joined(separator: ", "))")
        if let d = inst.defaultVersion { out("  default (used by new templates): \(d)") }
        out("")
        for b in e.store.state.bottles {
            let owner = e.store.state.games.first { $0.bottleID == b.id }?.name ?? "(orphan)"
            let v = inst.installedVersion(in: b.prefixPath)
            out("  \(owner): \(inst.isInstalled(in: b.prefixPath) ? "DXVK \(v ?? "?")" : "builtin D3D")  [backend: \(b.backend.label)]")
        }
        out("")
        out("  Note: DXVK 2.x/3.x need Vulkan 1.3 features MoltenVK does not fully")
        out("  implement. 1.10.3 targets Vulkan 1.1 and is usually the one that works here.")
    } else if rest.first == "prefer", rest.count > 1 {
        do { try inst.setPreferred(rest[1]); ok("new templates will use DXVK \(rest[1])") }
        catch { die(error) }
    } else if rest.first == "use", rest.count > 2 {
        let g = requireGame(rest[1]).1
        do {
            let v = try e.setDXVK(g, version: rest[2], progress: step)
            ok("\(g.name) now uses DXVK \(v)")
            out("    run `decanter check \(g.name)` to confirm")
        } catch { die(error) }
    } else {
        die(DecanterError.notFound("usage: decanter dxvk stage <tar.gz> | list | use <game> <version>"))
    }

case "runtime":
    let e = engine()
    if rest.first == "add", rest.count > 1 {
        do {
            let root = URL(filePath: (rest[1] as NSString).expandingTildeInPath)
            let c = try e.runtimes.inspect(wineRoot: root)
            step("found \(c.kind.rawValue) \(c.version) (32-bit: \(c.supports32Bit ? "yes" : "no"))")
            let spec = try e.runtimes.pin(c, store: e.store)
            ok("pinned \(spec.id) -> \(spec.root.path)")
            out("    backends: \(spec.backends.map(\.label).joined(separator: ", "))")
        } catch { die(error) }
    } else if rest.first == "set", rest.count > 2 {
        let g = requireGame(rest[1]).1
        do {
            let b = try e.setRuntime(g, to: rest[2])
            ok("\(g.name) now runs on \(rest[2]) with \(b.label)")
            out("    run `decanter check \(g.name)` to confirm the prefix is still happy")
        } catch { die(error) }
    } else if rest.first == "list" || rest.isEmpty {
        for r in e.store.state.runtimes {
            out("  \(r.id)  32-bit:\(r.supports32Bit ? "yes" : "no")  backends: \(r.backends.map(\.label).joined(separator: ", "))")
            out("      \(r.root.path)")
        }
    } else {
        die(DecanterError.notFound("usage: decanter runtime add <wine-root> | decanter runtime list"))
    }

case "check":
    let (e, g) = requireGame(rest.first)
    do {
        let r = try e.preflight(g)
        out("preflight: \(g.name)")
        out("  runtime:  \(r.runtimeID)   backend: \(r.backend)")
        out("  dos path: \(r.winPath)")
        out("  drives:   \(r.scopesApplied.joined(separator: " "))")
        print(r.exeVisibleToWine ? "  \u{2713} Wine can see the executable"
                                 : "  \u{2717} Wine CANNOT see the executable")
        print(r.fullFilesystemExposed ? "  \u{2717} z: maps the whole filesystem"
                                      : "  \u{2713} whole-filesystem access is blocked")
        out("  graphics: \(r.effectiveD3D)")
        for p in r.problems { warn(p) }
        if r.ok { ok("ready to run") } else { warn("preflight found problems") }
    } catch { die(error) }

case "report":
    let (e, g) = requireGame(rest.first)
    do {
        let rep = try e.report(g, progress: step)
        ok("report written")
        out("    \(rep.path)")
        // Put it on the clipboard so it can be pasted straight into a chat.
        if let text = try? String(contentsOf: rep, encoding: .utf8) {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/pbcopy")
            let pipe = Pipe(); p.standardInput = pipe
            try? p.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try? pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            ok("copied to clipboard — paste it straight into the chat")
        }
        out("    if the problem is visual, add a screenshot: Command-Shift-4, Space, click the window")
    } catch { die(error) }

case "worked":
    let (e2, g) = requireGame(rest.first)
    do { try e2.rememberWorking(g)
         let b = e2.store.bottle(g.bottleID)
         ok("remembered: \(b?.runtimeID ?? "?") + \(b?.backend.label ?? "?") works for \(g.name)")
         out("    future games with the same profile will start here") }
    catch { die(error) }

case "knowledge":
    let e2 = engine()
    let k = e2.knowledge
    if rest.first == "forget" {
        try? FileManager.default.removeItem(at: e2.paths.knowledgePath)
        ok("forgot everything learned; back to the seeded defaults")
    } else {
        out("what Decanter has learned:")
        let sorted = k.entries.sorted { ($0.value.confirmations, $0.key) > ($1.value.confirmations, $1.key) }
        for (key, e3) in sorted {
            let profile = Knowledge.label(forKey: key)
            let setup = "\(e3.runtimeKind == .gptk ? "GPTK" : "Wine") + \(e3.backend.label)"
            let confirmed = e3.confirmations == 0
                ? "(seeded default)"
                : "\u{2713} confirmed on \(e3.confirmations) of your game(s)"
            out("  \(profile.padding(toLength: 40, withPad: " ", startingAt: 0)) \(setup.padding(toLength: 18, withPad: " ", startingAt: 0)) \(confirmed)")
        }
    }

case "remove", "rm", "uninstall":
    let (e2, g) = requireGame(rest.first)
    let keepSaves = !rest.contains("--no-saves")
    let assumeYes = rest.contains("--yes") || rest.contains("-y")
    let bottle = e2.store.bottle(g.bottleID)
    out("About to remove \(g.name):")
    out("  \u{2717} its prefix        \(bottle?.prefixPath.path ?? "(none)")")
    out(keepSaves ? "  \u{2713} saves            snapshotted first, kept in the saves store"
                  : "  \u{2717} saves            DELETED along with the prefix")
    out("  \u{2713} your game files   \(g.exePath.deletingLastPathComponent().path)  (never touched)")
    if !assumeYes {
        out(""); out("Type the game's name to confirm, or anything else to cancel:")
        guard (readLine(strippingNewline: true) ?? "") == g.name else { out("cancelled."); exit(0) }
    }
    do {
        let r = try e2.remove(g, keepSaves: keepSaves, progress: step)
        ok("removed \(r.game)")
        if let snap = r.snapshotTaken { out("    saves kept: snapshot \(snap) (\(r.savedFiles) files)") }
        out("    reclaimed \(humanBytes(r.bottleBytes))")
    } catch { die(error) }

case "redetect":
    let e2 = engine()
    let targets = rest.first.map { [requireGame($0).1] } ?? e2.store.state.games
    for g in targets {
        do {
            let d = try e2.redetect(g, progress: step)
            ok("\(g.name): \(d.engine.label), \(d.bitness.label)\(d.usesVideo ? ", plays video" : "")\(d.engineVersion.map { " — engine \($0)" } ?? " — engine version not found")")
            if let blocker = d.knownUnsupported {
                warn(blocker.replacingOccurrences(of: "\n", with: " "))
            }
        } catch { warn("\(g.name): \(error.localizedDescription)") }
    }

case "args":
    let (e2, g) = requireGame(rest.first)
    if rest.count == 1 {
        let cur = g.launchArguments ?? []
        out("\(g.name) launch arguments: \(cur.isEmpty ? "(none)" : cur.joined(separator: " "))")
        let sug = LaunchPresets.suggestions(for: g.detection)
        if !sug.isEmpty {
            out(""); out("  worth trying for this engine:")
            for s2 in sug { out("    \(s2.flag.padding(toLength: 22, withPad: " ", startingAt: 0)) \(s2.blurb)") }
            out(""); out("  set with: decanter args \(g.name) -force-d3d12")
            out("  clear with: decanter args \(g.name) --none")
        }
    } else {
        let args = rest.contains("--none") ? [] : Array(rest.dropFirst())
        do { _ = try e2.setLaunchArguments(g, args)
             ok(args.isEmpty ? "cleared launch arguments" : "set: \(args.joined(separator: " "))") }
        catch { die(error) }
    }

case "env", "locale":
    let (e2, g) = requireGame(rest.first)
    if rest.count == 1 {
        let cur = g.envOverrides
        out("\(g.name) environment: \(cur.isEmpty ? "(none)" : cur.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
        out("")
        out("  locale presets (CJK games often crash under a Western locale):")
        for (k, v) in Engine.localePresets.sorted(by: { $0.key < $1.key }) {
            out("    \(k.padding(toLength: 10, withPad: " ", startingAt: 0)) \(v.blurb)")
        }
        out("")
        out("  set with: decanter env \(g.name) japanese")
        out("       or:  decanter env \(g.name) SOME_VAR=value")
        out("  clear:    decanter env \(g.name) --none")
    } else if rest.contains("--none") {
        do { _ = try e2.setEnvironment(g, [:], clear: true); ok("cleared environment overrides") }
        catch { die(error) }
    } else {
        var vars: [String: String] = [:]
        for token in rest.dropFirst() {
            if let preset = Engine.localePresets[token.lowercased()] { vars.merge(preset.vars) { a, _ in a } }
            else if let eq = token.firstIndex(of: "=") {
                vars[String(token[token.startIndex..<eq])] = String(token[token.index(after: eq)...])
            }
        }
        guard !vars.isEmpty else { die(DecanterError.notFound("nothing to set — use a preset name or KEY=VALUE")) }
        do { let all = try e2.setEnvironment(g, vars)
             ok("set: \(all.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))") }
        catch { die(error) }
    }

case "exe", "exes":
    let (e2, g) = requireGame(rest.first)
    let choices = e2.executables(for: g)
    // No argument: list what is available.
    if rest.count == 1 {
        out("\(g.name) — executables found")
        out("  current: \(g.exePath.lastPathComponent)")
        out("")
        for (i, c) in choices.enumerated() {
            let mark = c.url == g.exePath ? "\u{2713}" : (c.isLikelyGame ? "\u{2605}" : " ")
            let size = c.bytes >= 1_000_000 ? String(format: "%.1f MB", Double(c.bytes)/1e6) : "\(c.bytes/1000) KB"
            out("  \(mark) [\(i)] \(c.relativePath)")
            out("        \(size)\(c.note.map { " — \($0)" } ?? "")")
        }
        out("")
        out("  switch with:  decanter exe \(g.name) <number|name>")
        out("  run one once: decanter exe \(g.name) <number|name> --run")
    } else {
        let token = rest[1]
        var picked: URL? = nil
        if let idx = Int(token), idx >= 0, idx < choices.count { picked = choices[idx].url }
        else {
            let needle = token.lowercased()
            picked = choices.first { $0.relativePath.lowercased().contains(needle)
                                  || $0.url.lastPathComponent.lowercased() == needle }?.url
                  ?? URL(filePath: (token as NSString).expandingTildeInPath)
        }
        guard let exe = picked, FileManager.default.fileExists(atPath: exe.path) else {
            die(DecanterError.notFound("no executable matching '\(token)'"))
        }
        if rest.contains("--run") {
            // One-off: run it without changing what the game normally launches.
            do {
                let plan = try e2.runOther(g, exe: exe)
                ok("running \(exe.lastPathComponent) in \(g.name)'s prefix")
                out("    \(plan.winPath) via \(plan.runtime.id)")
                out("    this did not change the game's own executable")
            } catch { die(error) }
        } else {
            do {
                let updated = try e2.setExecutable(g, to: exe, progress: step)
                ok("\(g.name) now launches \(exe.lastPathComponent)")
                out("    engine: \(updated.detection.engine.label), \(updated.detection.bitness.label)\(updated.detection.usesVideo ? ", plays video" : "")")
                if let v = updated.detection.engineVersion { out("    engine version: \(v)") }
                out("    check the recommendation again: decanter recommend \(g.name)")
            } catch { die(error) }
        }
    }

case "recommend":
    let (e2, g) = requireGame(rest.first)
    let rec = e2.recommend(for: g)
    out("\(g.name)")
    out("  engine:   \(g.detection.engine.label), \(g.detection.bitness.label)\(g.detection.usesVideo ? ", plays video" : "")")
    out("")
    out("  recommended: \(rec.runtimeKind == .gptk ? "Game Porting Toolkit" : "Wine 11") + \(rec.backend.label)   [\(rec.confidence) confidence]")
    for r in rec.reasons { out("    \u{00b7} \(r)") }
    if !rec.caveats.isEmpty { out(""); for c in rec.caveats { out("    ! \(c)") } }
    if rest.contains("--apply") {
        do { _ = try e2.applyRecommendation(g, progress: step); ok("applied — nothing was launched") }
        catch { die(error) }
    } else {
        out(""); out("  apply it with: decanter recommend \(g.name) --apply")
    }

case "autoconfig":
    let (e2, g) = requireGame(rest.first)
    let all = rest.contains("--all")
    let cands = e2.candidates(for: g)
    if cands.isEmpty { die(DecanterError.notFound("no usable configurations — check `decanter template list`")) }
    out("Trying \(cands.count) configuration(s) for \(g.name); each launches briefly and closes.")
    do {
        let (best, attempts) = try e2.autoconfigure(g, stopAtFirstGood: !all, progress: step)
        out(""); out("  result")
        for a in attempts {
            let mark = a.outcome.isGood ? (a.videoBroken ? "\u{25B3}" : "\u{2713}") : "\u{2717}"
            out("    \(mark) \(a.candidate.label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(a.outcome.summary)\(a.videoBroken ? ", video broken" : "")")
        }
        out("")
        if let b = best { ok("using \(b.label)") } else { warn("nothing worked — try `decanter report \(g.name)`") }
    } catch { die(error) }

case "reap":
    let e2 = engine()
    let strays = e2.strayWineProcesses()
    if strays.isEmpty { ok("no Wine processes are running"); break }
    out("\(strays.count) Wine process(es) still running:")
    out("")
    for s in strays {
        let hot = s.cpu >= 50 ? "  <-- pinned at \(Int(s.cpu))% CPU" : ""
        let name = s.displayName
        out("  pid \(String(s.pid).padding(toLength: 7, withPad: " ", startingAt: 0))"
            + "\(s.elapsed.padding(toLength: 14, withPad: " ", startingAt: 0))"
            + "\(name.prefix(46))\(hot)")
        if let p = s.prefix { out("          prefix: \(p.lastPathComponent)") }
    }
    out("")
    if rest.contains("--list") || rest.contains("-l") {
        out("run `decanter reap` to end them")
    } else {
        warn("this ends every Wine session, including a game you are playing")
        let o = e2.reapWine(progress: step)
        ok("\(o.sessionsEnded) session(s) shut down, \(o.killed.count) process(es) killed")
        if !o.survived.isEmpty { warn("could not kill: \(o.survived.map(String.init).joined(separator: ", "))") }
    }

case "fonts":
    let e2 = engine()
    let dry = rest.contains("--check") || rest.contains("-n")
    if dry {
        // Show one prefix's view rather than editing anything.
        let fp = FontProvisioner()
        let probe = e2.store.state.bottles.first?.prefixPath
            ?? e2.paths.template(for: e2.store.state.templateRuntimeID ?? "")
        let plan = fp.plan(for: probe)
        out("\(plan.families) host font families visible to Wine")
        out("")
        for m in plan.mapped {
            let mark = plan.already.contains(m.name) ? "\u{2713}" : "+"
            out("  \(mark) \(m.name.padding(toLength: 22, withPad: " ", startingAt: 0)) -> \(m.target)")
        }
        if !plan.unmapped.isEmpty {
            out(""); warn("no macOS face for: \(plan.unmapped.joined(separator: ", "))")
        }
        out("")
        if plan.mapped.isEmpty { ok("nothing to map - every name already resolves") }
        else if plan.pending.isEmpty { ok("all \(plan.mapped.count) already applied to this prefix") }
        else { out("\(plan.pending.count) of \(plan.mapped.count) not yet applied - run: decanter fonts") }
    } else {
        let results = e2.provisionFonts(progress: step)
        let total = results.reduce(0) { $0 + $1.plan.mapped.count }
        let failed = results.filter { $0.error != nil }
        if let first = results.first(where: { !$0.plan.mapped.isEmpty }) {
            out("")
            for m in first.plan.mapped {
                out("  \(m.name.padding(toLength: 22, withPad: " ", startingAt: 0)) -> \(m.target)")
            }
            out("")
        }
        for f in failed { warn("\(f.scope): \(f.error ?? "")") }
        ok("\(total) mapping(s) written across \(results.count) prefix(es)")
        out("  nothing was launched - the mapping takes effect next run")
    }

case "mods":
    let (_, g) = requireGame(rest.first)
    let st = ModInspector().inspect(game: g)
    if !st.installed { out("\(g.name): no BepInEx / Doorstop found next to the executable") }
    else {
        out("\(g.name): BepInEx detected\(st.loaderVersion.map { " \($0)" } ?? "")")
        print(st.loaderRan ? "  \u{2713} the mod loader has run" : "  \u{00b7} no loader log yet")
        out("  \(st.plugins.count) plugin(s)")
        if let d = st.pluginsDir { out("  plugins: \(d.path)") }
        if let n = st.note { warn(n) }
        if !st.errors.isEmpty {
            out("")
            warn("the mod loader reported \(st.errors.count) failure(s):")
            for e in st.errors { out("      \(e.prefix(150))") }
            if let l = st.logPath { out("  full log: \(l.path)") }
        }
    }

case "install":
    guard rest.count >= 2 else {
        out("usage: decanter install <game> <preset|verb>...")
        out(""); out("presets:")
        for (k, v) in RecipeRunner.presets.sorted(by: { $0.key < $1.key }) {
            out("  \(k.padding(toLength: 13, withPad: " ", startingAt: 0)) \(v.blurb)")
        }
        exit(1)
    }
    let (e2, g) = requireGame(rest[0])
    let want = Array(rest.dropFirst()).filter { !$0.hasPrefix("--") }
    let tool = e2.recipes.tooling()
    if !tool.missing.isEmpty { die(DecanterError.notFound("missing helper(s): \(tool.missing.joined(separator: ", "))")) }
    do {
        let r = try e2.install(g, verbs: want, progress: step)
        if !r.succeeded.isEmpty { ok("installed: \(r.succeeded.joined(separator: ", "))") }
        if !r.failed.isEmpty { warn("failed: \(r.failed.joined(separator: ", "))") }
    } catch { die(error) }

case "recipes":
    let e2 = engine()
    let tool = e2.recipes.tooling()
    out("helpers:  winetricks \(tool.winetricks ? "\u{2713}" : "\u{2717}")   cabextract \(tool.cabextract ? "\u{2713}" : "\u{2717}")")
    out(""); out("presets:")
    for (k, v) in RecipeRunner.presets.sorted(by: { $0.key < $1.key }) {
        out("  \(k.padding(toLength: 13, withPad: " ", startingAt: 0)) \(v.blurb)")
    }
    out(""); out("applied per game:")
    for b in e2.store.state.bottles {
        let owner = e2.store.state.games.first { $0.bottleID == b.id }?.name ?? "(orphan)"
        out("  \(owner): \(b.appliedRecipes.isEmpty ? "none" : b.appliedRecipes.joined(separator: ", "))")
    }

case "saves":
    let e2 = engine()
    let sub = rest.first ?? "list"
    switch sub {
    case "list":
        for r in e2.savesOverview() {
            out("  \(r.game)")
            out("      \(r.files) files, \(humanBytes(r.bytes)) · \(r.registryKeys) registry keys · \(r.snapshots) snapshots")
        }
    case "show":
        let (_, g) = requireGame(rest.count > 1 ? rest[1] : nil)
        let d = e2.discoverSaves(g)
        out("\(g.name): \(d.files.count) files, \(humanBytes(d.totalBytes))")
        for f in d.files.sorted(by: { $0.bytes > $1.bytes }).prefix(30) {
            out("  \(humanBytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(f.relPath)")
        }
    case "snapshot":
        if rest.count > 1 && rest[1] == "--all" {
            for g in e2.store.state.games {
                if let s2 = try? e2.snapshotSaves(g, note: "manual") { ok("\(g.name): \(s2.name)") }
            }
        } else {
            let (_, g) = requireGame(rest.count > 1 ? rest[1] : nil)
            do { let s2 = try e2.snapshotSaves(g, note: "manual", progress: step); ok("\(s2.name): \(s2.fileCount) files") }
            catch { die(error) }
        }
    case "snapshots":
        let (_, g) = requireGame(rest.count > 1 ? rest[1] : nil)
        for s2 in e2.saves.snapshots(for: g) {
            out("  \(s2.name)  \(s2.fileCount) files  \(humanBytes(s2.bytes))\(s2.note.map { "  — \($0)" } ?? "")")
        }
    case "restore":
        let (_, g) = requireGame(rest.count > 1 ? rest[1] : nil)
        do { let n = try e2.restoreSaves(g, snapshot: rest.count > 2 ? rest[2] : nil, progress: step)
             ok("restored \(n) files") } catch { die(error) }
    case "search":
        guard rest.count > 1 else { die(DecanterError.notFound("usage: decanter saves search <text>")) }
        for h in e2.searchSaves(rest[1...].joined(separator: " ")).prefix(50) {
            out("  [\(h.game)] \(humanBytes(h.bytes))  \(h.relPath)")
        }
    case "externalise", "externalize":
        let targets = (rest.count > 1 && rest[1] != "--all") ? [requireGame(rest[1]).1] : e2.store.state.games
        for g in targets {
            do { let r = try e2.externaliseSaves(g, progress: step)
                 ok("\(g.name): moved \(r.moved.count), already linked \(r.alreadyLinked.count)") }
            catch { warn("\(g.name): \(error.localizedDescription)") }
        }
    case "gc":
        var removed = 0
        for g in e2.store.state.games { removed += (try? e2.saves.prune(game: g, keep: e2.snapshotRetention)) ?? 0 }
        ok("pruned \(removed) old snapshot(s)")
    default:
        die(DecanterError.notFound("usage: decanter saves list|show|snapshot|snapshots|restore|search|externalise|gc"))
    }

case "help", "--help", "-h": usage()
default:
    warn("unknown command: \(cmd)")
    usage()
}
