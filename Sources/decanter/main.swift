import Foundation
import DecanterKit

// Minimal hand-rolled CLI. No argument-parser dependency on purpose: an
// external package is one more thing that can disappear.

let argv = Array(CommandLine.arguments.dropFirst())
let verbose = argv.contains("--verbose") || argv.contains("-v")
/// Opt in to the reasoning. Everything Decanter reports has a plain answer and,
/// underneath it, the technical detail that produced the answer. The detail is
/// never shown unless it is asked for: a person deciding what to do next is not
/// helped by Mach-O file types, and being handed them anyway is how a report
/// teaches people to stop reading it.
let detailed = argv.contains("--detail") || argv.contains("--why")
let args = argv.filter { !["--verbose", "-v", "--detail", "--why"].contains($0) }

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
    exit((e as? DecanterError)?.exitCode ?? 1)
}


/// One bench row, in the order someone reads it: what it is, what it can do,
/// then what is wrong with it. Plain by default; `--detail` adds the reasoning
/// and the files it rests on.
func printBenchRow(_ row: Bench.RuntimeRow, stale: Bool) {
    out("\(row.runtimeID)  (Wine \(row.version)\(row.kind == .gptk ? ", Apple's Game Porting Toolkit" : ""), 32-bit games: \(row.supports32Bit ? "yes" : "no"))")
    if stale { warn("this build has changed since it was measured \u{2014} run `decanter bench`") }
    for f in row.findings.sorted(by: { $0.backend.rank < $1.backend.rank }) {
        out("  \(f.provided ? "\u{2713}" : "\u{2717}") \(f.backend.plainName) graphics  (\(f.backend.label))")
        out("      \(f.reason)")
        if detailed {
            if !f.detail.isEmpty { out("      why: \(f.detail)") }
            for e in f.evidence { out("      decided by: \(e)") }
        }
    }
    if row.soundness.scannedFiles > 0 {
        if row.soundness.isSound {
            out("  \u{2713} \(row.soundness.headline)")
        } else {
            out("  \u{2717} \(row.soundness.headline)")
            for c in row.soundness.consequences { out("      \u{2192} \(c)") }
            out("      `decanter audit \(row.runtimeID)` says more about this")
        }
        if detailed { out("      \(row.soundness.scannedFiles) files were examined") }
    }
    out("")
}

/// Every top-level command, so a typo can be answered with the nearest one
/// rather than with the whole manual. Kept immediately beside `usage()` so a
/// new command is added to both or to neither.
let commandNames = [
    "add", "args", "audit", "autoconfig", "backend", "bench", "bottles", "check",
    "diagnose", "dll", "doctor", "dxmt", "dxvk", "endorse", "env", "exe", "fonts", "gc",
    "help", "import", "info", "install", "knowledge", "list", "mods", "pin",
    "recipes", "recommend", "redetect", "rederive", "remove", "reap", "repair",
    "pack", "report", "restore", "run", "runtime", "saves", "setup", "template", "use",
    "verdict", "version", "worked",
]

/// The help, and where it goes.
///
/// The stream and the exit code are the caller's to choose, and they used to be
/// inferred here from whether any argument had been given — which meant an
/// unrecognised command took the `args.isEmpty == false` branch and exited 0.
/// Decanter reported success for a command it had never heard of, on stdout, so
/// a script wrapping it read a typo as a completed action.
func usage(to stderr: Bool = false, exitCode: Int32 = 0) -> Never {
    let text = """
    decanter — run Windows games on macOS

    SETUP
      decanter setup                  what Decanter has, what it needs, where to get it
      decanter use <file>             hand over a Wine build, a GPTK disk image, DXVK, or a pack
      decanter use --look <folder>    say what Decanter can see in a folder, and install nothing
      decanter doctor                 check the stack (Rosetta, runtimes, template)
      decanter pin                    take Decanter's own copy of every Wine build found
      decanter runtime list           show pinned runtimes
      decanter bench                  measure what each Wine build can actually provide
      decanter audit [runtime]        what a build is missing, and what stops working
      decanter repair <runtime>       offer to fill the gaps from builds already here
      decanter pack check <path>      is this runtime pack whole, and is it ours
      decanter pack build             assemble a pack from upstream archives (maintainer)
      decanter verdict                answer the one thing Decanter could not see for itself
      decanter restore <game>         put a game back on the last setup that worked
      decanter endorse <game>         vouch for a setup you have actually run
      decanter endorse list           what is endorsed, and whether it still checks out
      decanter endorse revoke <game>  take an endorsement back (--note "" just clears the note)
      decanter endorse keygen         make an endorsement key pair on this Mac
        --detail on bench, audit, repair, recommend and mods
                                      the reasoning behind the answer, not just the answer
      decanter runtime set <game> <id>  move a game to another runtime
      decanter template build [rt]    build the golden template for a runtime
      decanter template list          which runtimes have a template
      decanter dxvk list              staged versions and what each game uses
      decanter dxvk use <game> <ver>  switch a game to a specific DXVK version
      decanter dxvk prefer <ver>      which version new templates bake in
      decanter dxmt list              staged DXMT, and which runtimes can host it
      decanter dxmt stage <archive>   stage a DXMT build you supply
      decanter dxmt use <game>        move a game to Metal graphics (Unity 6)

    GAMES
      decanter add <path> [--name N] [--exe NAME]   add a game; --exe picks which one
      decanter exe <game>             list executables; pick one, or run one once
      decanter list                   list games
      decanter info <game>            show detection evidence and settings
      decanter run <game>             launch it
      decanter check <game>           dry-run: verify it WOULD launch, without starting it
      decanter redetect [game]        re-inspect with the current rules (all games if omitted)
      decanter args <game> [flags]    engine switches like -force-d3d12 (no args = show suggestions)
      decanter env <game> [japanese]  environment/locale overrides for CJK games
      decanter dll <game> [name=n,b]  tell Wine which copy of a DLL to load
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
      decanter bottles                list prefixes, runtime, backend, health
      decanter gc                     delete prefixes no game points at
      decanter backend <game> <dxvk|d3dmetal|wined3d>

    Add --verbose for detail.
    """
    if stderr {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else {
        out(text)
    }
    exit(exitCode)
}

/// How many single-character edits separate two commands. Only used to decide
/// whether a typo is close enough to a real command to be worth naming.
func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count)
    var cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            cur[j] = x[i - 1] == y[j - 1]
                ? prev[j - 1]
                : 1 + min(prev[j - 1], min(prev[j], cur[j - 1]))
        }
        swap(&prev, &cur)
    }
    return prev[y.count]
}

/// What to say about a command that does not exist.
///
/// Not the full listing. Seventy lines of help scroll the actual error off the
/// screen, and printing them on stdout makes `decanter typo | head` look like
/// help was asked for. The error goes to stderr, names the nearest command when
/// there is an obvious one, and says where the rest is.
func unknownCommand(_ cmd: String) -> Never {
    var msg = "error: there is no `decanter \(cmd)` command.\n"
    let near = commandNames
        .map { ($0, editDistance(cmd.lowercased(), $0)) }
        // A third of the length, so short commands need a near-exact typo and
        // long ones can survive a slip or two. A suggestion that is not close
        // is worse than none: it sends someone off to read about the wrong
        // thing.
        .filter { $0.1 <= max(1, $0.0.count / 3) }
        .sorted { $0.1 < $1.1 }
    if let best = near.first {
        msg += "       did you mean `decanter \(best.0)`?\n"
    }
    msg += "       `decanter help` lists everything.\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(2)
}

guard let cmd = args.first else { usage(exitCode: 1) }
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

case "version", "--version", "-v":
    out(Build.summary)

case "doctor":
    let e = engine()
    let h = e.doctor()
    out("Decanter doctor")
    out("  root: \(e.paths.root.path)")
    print(h.rosetta ? "  \u{2713} Rosetta 2 present" : "  \u{2717} Rosetta 2 MISSING — Wine cannot run")
    switch h.rosettaHorizon {
    case .fine:                 out("  \u{00b7} \(h.rosettaHorizon.note)")
    case .lastSupportedRelease: warn(h.rosettaHorizon.note)
    case .removed:              warn(h.rosettaHorizon.note)
    }
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
    // DXMT is the only route to Direct3D 11 straight to Metal, and whether a
    // build can host it is a property of the binary rather than a guess. It is
    // printed here, under the runtime it describes. It used to appear eight
    // lines further down, past the game and bottle counts, so the same object
    // was described twice in two places with unrelated text in between.
    let bench = Bench(paths: e.paths)
    let benchTable = bench.load()
    for r in h.pinnedRuntimes {
        out("  pinned: \(r.id)  backends: \(r.backends.map(\.label).joined(separator: ", "))")
        let m = e.runtimes.metalHosting(of: r)
        guard m.driverPath != nil else { continue }
        // A measurement outranks an inspection. `bench` starts this build and
        // asks it directly, so calling a measured build "untested" is the tool
        // contradicting itself inside one session.
        if let row = benchTable.row(r.id), !bench.isStale(row, runtime: r),
           let f = row.finding(.dxmt) {
            out("      \(f.provided ? "\u{2713}" : "\u{2717}") DXMT: \(f.reason)")
            continue
        }
        // Two different noes, and they are not interchangeable: one build
        // cannot be linked against at all, the other links and then cannot
        // produce a frame.
        let verdict = m.looksCapable ? "could host DXMT — `decanter bench` would settle it"
            : !m.driverIsLinkable ? "cannot host DXMT — its Mac driver is a bundle, not a dylib"
            : "cannot host DXMT — its Mac driver hides the metal-view calls"
        out("      \(verdict)")
    }
    if h.templateBuilt {
        let age = h.templateAge.map { " (\(Int($0 / 86400))d old)" } ?? ""
        ok("golden template built\(age)")
    } else { warn("golden template not built — run `decanter template build`") }
    out(h.gamesDirExists ? "  \u{2713} ~/Games exists" : "  · ~/Games does not exist yet")
    out("  games: \(e.store.state.games.count)   bottles: \(e.store.state.bottles.count)")
    // A leaked Wine session keeps burning CPU under Decanter's name long after
    // the app quits, so the only place the user can see it is here.
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

case "setup":
    // The GUI's Setup page in text form, from the same Readiness the app uses,
    // so the two can never disagree about whether this Mac is ready.
    let e = engine()
    let r = e.readiness()
    out("Decanter setup — \(r.headline)")
    out("")
    for piece in r.pieces {
        let mark = switch piece.state {
        case .present: "\u{2713}"
        case .foundNotPinned: "\u{2192}"
        case .missing: piece.required ? "\u{2717}" : "\u{00b7}"
        }
        out("  \(mark) \(piece.title)\(piece.required ? "" : "  (optional)")")
        out("      \(piece.why)")
        // The technical line, always — this surface's audience already knows
        // the words, and it carries the exact version constraints.
        if let spec = piece.spec { out("      \(spec)") }
        // `detail` is the GUI's next action ("drag the file onto this window"),
        // which is nonsense in a terminal. Only shown once a piece is present,
        // where it reports what is installed rather than what to do.
        if piece.state == .present, let d = piece.detail { out("      \(d)") }
        if piece.state != .present, let src = piece.source {
            out("      get it: \(src.absoluteString)")
            out("      then:   decanter use <the file you downloaded>")
        }
    }
    if !r.ready {
        out("")
        out("  Nothing is downloaded for you, on purpose: an installed Decanter")
        out("  cannot be broken by something disappearing from the internet.")
    }

case "use":
    // One command for every piece a person can be handed: a Wine folder, a
    // Wine .app, a Game Porting Toolkit .dmg, or a DXVK tarball. Decanter
    // works out which it is by looking inside, because the names differ
    // between every source these come from.
    let look = rest.contains("--look")
    guard let p = rest.first(where: { !$0.hasPrefix("--") }) else {
        die(DecanterError.usage("usage: decanter use [--look] <wine folder | .app | .dmg | dxvk-*.tar.gz | pack>"))
    }
    let e = engine()
    let target = URL(filePath: (p as NSString).expandingTildeInPath)
    // `--look` reports and stops. It is here for the folder case — pointing
    // `use` at ~/Downloads takes in everything it recognises, and that is a
    // reasonable thing to want and an unreasonable thing to discover.
    if look {
        let found = e.look(in: target)
        if found.isEmpty {
            warn("nothing in \(target.lastPathComponent) is something Decanter can use")
            exit(1)
        }
        for f in found { out("  \(f.summary)") }
        out("")
        out("  Nothing has been installed. Run the same command without --look to take these in.")
        exit(0)
    }
    do {
        let summary = try e.accept(droppedPath: target, progress: step)
        ok(summary)
    } catch { die(error) }

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
    if let blocker = g.detection.blocker(onBackend: e.store.bottle(g.bottleID)?.backend) {
        out("")
        warn(blocker.replacingOccurrences(of: "\n", with: " "))
    }

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
                    e.askAbout(g, observed: "it is running, but its log reports problems")
                } else {
                    try? e.rememberWorking(g)
                    out("    remembered this setup for games like it")
                }
            case .runningWithoutWindow:
                warn("running, but no window appeared after 45s")
                e.askAbout(g, observed: "it is running, but no window appeared")
            case .exited(let t):
                warn("exited after \(Int(t))s — it did not stay running")
                e.askAbout(g, observed: "it exited after \(Int(t)) seconds")
            case .neverStarted:
                warn("it never started")
                e.askAbout(g, observed: "it never started")
            }
            for f in r.findings { out("    \u{2717} \(f.summary)"); out("      -> \(f.suggestion)") }
            if !r.outcome.isGood { out("    try: decanter autoconfig \(g.name)") }
            // Only where Decanter declined to record. A clean launch asks
            // nothing — being asked to confirm the obvious is how a prompt
            // becomes something people dismiss without reading.
            if Verdict(paths: e.paths).pending() != nil {
                out("")
                out("    Decanter could not tell whether that worked.")
                out("    Say so with `decanter verdict worked` or `decanter verdict failed`.")
            }
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
    guard rest.count >= 2 else { die(DecanterError.usage("usage: decanter import <game> <dir>")) }
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
        die(DecanterError.usage("usage: decanter backend <game> <"
                                   + GraphicsBackend.allCases.map(\.rawValue).joined(separator: "|") + ">"))
    }
    let (e, g) = requireGame(rest[0])
    do {
        try e.setBackend(g, nb, progress: step)
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
        die(DecanterError.usage("usage: decanter dxvk stage <tar.gz> | list | use <game> <version>"))
    }

case "dxmt":
    let e = engine()
    let inst = DXMTInstaller(paths: e.paths)
    if rest.first == "stage", rest.count > 1 {
        do {
            let v = try inst.stage(archive: URL(filePath: (rest[1] as NSString).expandingTildeInPath), progress: step)
            ok("DXMT \(v) staged")
        } catch { die(error) }
    } else if rest.first == "status" || rest.first == "list" || rest.isEmpty {
        let versions = inst.stagedVersions()
        out(versions.isEmpty ? "  ! no DXMT staged" : "  staged versions: \(versions.joined(separator: ", "))")
        out("")
        // Staged is only half the answer. Which runtimes can host it is the
        // half people actually get stuck on, so it is stated without asking.
        out("  which pinned runtimes can host it:")
        if e.store.state.runtimes.isEmpty { out("    (no runtimes pinned yet)") }
        for rt in e.store.state.runtimes {
            let h = RuntimeManager.metalHosting(root: rt.root)
            out("    \(rt.id): \(h.looksCapable ? "yes" : "no")"
                + (h.looksCapable ? "" : " — \(h.unavailableReason?.replacingOccurrences(of: "\n", with: " ") ?? "")"))
        }
        out("")
        for b in e.store.state.bottles where inst.isInstalled(in: b.prefixPath) {
            let owner = e.store.state.games.first { $0.bottleID == b.id }?.name ?? "(orphan)"
            out("  \(owner): DXMT \(inst.installedVersion(in: b.prefixPath) ?? "?")")
        }
        out("")
        out("  DXMT translates Direct3D 11 straight to Metal. It is the only layer here")
        out("  that implements the interfaces Unity 6 asks for. Decanter has not confirmed")
        out("  a Unity 6 game running on it — if you get one working, say so on the issue tracker.")
    } else if rest.first == "use", rest.count > 1 {
        let g = requireGame(rest[1]).1
        do {
            _ = try e.setBackend(g, .dxmt, progress: step)
            ok("\(g.name) now uses DXMT")
            out("    run `decanter check \(g.name)` to confirm")
        } catch { die(error) }
    } else {
        die(DecanterError.usage("usage: decanter dxmt stage <archive> | list | use <game>"))
    }

case "runtime":
    let e = engine()
    if rest.first == "add", rest.count > 1 {
        // Same path as `decanter use` and as dropping the file on the app, so
        // a disk image works here too rather than failing with "no wine binary".
        do {
            let summary = try e.accept(droppedPath: URL(filePath: (rest[1] as NSString).expandingTildeInPath),
                                       progress: step)
            ok(summary)
        } catch { die(error) }
    } else if rest.first == "set", rest.count > 2 {
        let g = requireGame(rest[1]).1
        do {
            let b = try e.setRuntime(g, to: rest[2])
            ok("\(g.name) now runs on \(rest[2]) with \(b.label)")
            out("    run `decanter check \(g.name)` to confirm the prefix is still happy")
        } catch { die(error) }
    } else if rest.first == "remove", rest.count > 1 {
        do { ok(try e.removeRuntime(rest[1], progress: step)) } catch { die(error) }
    } else if rest.first == "list" || rest.isEmpty {
        for r in e.store.state.runtimes {
            out("  \(r.id)  32-bit:\(r.supports32Bit ? "yes" : "no")  backends: \(r.backends.map(\.label).joined(separator: ", "))")
            out("      \(r.root.path)")
        }
    } else {
        die(DecanterError.usage("usage: decanter runtime add <wine-root> | list | set <game> <id> | remove <id>"))
    }

case "bench":
    // Open to anyone. The measurements are the same whoever runs them; what
    // the maintainer's key adds later is the ability to publish a result, not
    // the ability to take one.
    let e = engine()
    let bench = Bench(paths: e.paths)
    if rest.first == "show" {
        let t = bench.load()
        if t.rows.isEmpty { die(DecanterError.notFound("nothing measured yet \u{2014} run `decanter bench`")) }
        for row in t.rows { printBenchRow(row, stale: e.store.state.runtimes.first { $0.id == row.runtimeID }
                                                        .map { bench.isStale(row, runtime: $0) } ?? false) }
    } else {
        guard !e.store.state.runtimes.isEmpty else {
            die(DecanterError.noRuntime("no runtimes pinned yet \u{2014} run `decanter setup`"))
        }
        do {
            let t = try bench.runAll(store: e.store, progress: step)
            for row in t.rows { printBenchRow(row, stale: false) }
            let changes = try bench.reconcile(store: e.store, table: t)
            if changes.isEmpty {
                ok("the record already matched what these builds can do")
            } else {
                for c in changes { ok("updated \(c)") }
                out("    what Decanter offers for a game follows this, so the choices will have changed")
            }
        } catch { die(error) }
    }

case "audit":
    let e = engine()
    if rest.first == "deps", rest.count > 1 {
        let u = URL(filePath: (rest[1] as NSString).expandingTildeInPath)
        guard let img = MachO.read(at: u) else { die(DecanterError.notFound("not a Mach-O file")) }
        out("rpaths:"); for r in img.rpaths { out("    \(r)") }
        let rootGuess = e.store.state.runtimes.first { u.path.hasPrefix($0.root.path) }?.root
            ?? u.deletingLastPathComponent()
        out("root: \(rootGuess.path)")
        out("loaderDir: \(u.deletingLastPathComponent().path)")
        out("dependencies:"); for d in img.dependencies.sorted(by: { $0.path < $1.path }) {
            out("    " + RuntimeAudit.explain(d.path, loaderDir: u.deletingLastPathComponent(),
                                              rpaths: img.rpaths, root: rootGuess)
                + (d.isWeak ? "  (weak)" : ""))
        }
        exit(0)
    }
    let targets = rest.isEmpty ? e.store.state.runtimes
                              : e.store.state.runtimes.filter { $0.id == rest[0] }
    guard !targets.isEmpty else { die(DecanterError.notFound("runtime \(rest.first ?? "")")) }
    for rt in targets {
        let rep = RuntimeAudit().audit(root: rt.root)
        out(rt.id)
        if rep.isSound {
            ok(rep.headline)
        } else {
            out("  \u{2717} \(rep.headline)")
            for c in rep.consequences { out("      \u{2192} \(c)") }
            if !detailed {
                out("      run `decanter audit \(rt.id) --detail` to see exactly which, and what needs them")
            }
        }
        if detailed {
            out("      \(rep.scannedFiles) files examined")
            for g in rep.hardGaps {
                out("    \(g.library)\(g.thirtyTwoBitOnly ? "   (32-bit side only)" : "")")
                out("        needed by \(g.neededBy.prefix(4).joined(separator: ", "))"
                    + (g.neededBy.count > 4 ? " and \(g.neededBy.count - 4) more" : ""))
            }
            for g in rep.weakGaps.prefix(5) {
                out("    \(g.library)   (optional \u{2014} absent by design is fine)")
            }
        }
        out("")
    }

case "repair":
    // Describes by default and acts only when told to. The offer names its
    // cause, says where the change lands and how to undo it, and then stops.
    let e = engine()
    guard let target = e.store.state.runtimes.first(where: { $0.id == rest.first }) else {
        die(DecanterError.usage("usage: decanter repair <runtime> [--do | --undo]\n"
            + "       runtimes: " + e.store.state.runtimes.map(\.id).joined(separator: ", ")))
    }
    let repair = RuntimeRepair()
    if rest.contains("--undo") {
        do {
            let removed = try repair.undo(target, progress: step)
            if removed.isEmpty { ok("nothing had been copied into \(target.id)") }
            else { ok("removed \(removed.count) file\(removed.count == 1 ? "" : "s") \u{2014} \(target.id) is back as it was") }
        } catch { die(error) }
    } else {
        let report = RuntimeAudit().audit(root: target.root)
        if report.isSound { ok(report.headline); break }
        let offer = repair.plan(for: target, donors: e.store.state.runtimes, audit: report)
        out(target.id)
        out("  \u{2717} \(report.headline)")
        for c in report.consequences { out("      \u{2192} \(c)") }
        out("")
        out("  \(offer.summary)")
        if !offer.isEmpty {
            out("  It changes:")
            for line in offer.location.split(separator: "\n") { out("      \(line)") }
            out("  \(offer.undo)")
            if detailed {
                out("  In detail:")
                for b in offer.borrows {
                    out("      \(b.library)  (\(b.architectures.joined(separator: ", ")))  from \(b.donorID)")
                    out("          wanted by \(b.neededBy.prefix(3).joined(separator: ", "))")
                }
                for g in offer.unfillable { out("      cannot supply \(g.library)") }
            }
        }
        if rest.contains("--do") {
            guard !offer.isEmpty else { die(DecanterError.notFound("nothing here can supply what is missing")) }
            do {
                let done = try repair.apply(offer, to: target, progress: step)
                ok("copied \(done.count) file\(done.count == 1 ? "" : "s")")
                let after = RuntimeAudit().audit(root: target.root)
                if after.isSound { ok(after.headline) }
                else {
                    // A borrowed library brings its own dependencies. Saying
                    // what is left beats declaring victory.
                    out("  \(after.headline)")
                    for c in after.consequences { out("      \u{2192} \(c)") }
                    out("  run `decanter repair \(target.id)` again \u{2014} some of these may now be fillable")
                }
                let bench = Bench(paths: e.paths)
                var table = bench.load()
                table.rows.removeAll { $0.runtimeID == target.id }
                table.rows.append(bench.measure(target))
                try bench.save(table)
                for c in try bench.reconcile(store: e.store, table: table) { ok("updated \(c)") }
            } catch { die(error) }
        } else if !offer.isEmpty {
            out("")
            out("  Nothing has been changed. Run `decanter repair \(target.id) --do` to go ahead.")
        }
    }

case "pack":
    // A runtime pack is one file holding the Wine build and the graphics
    // layers a first run needs, with checksums and licences beside them.
    // Reading one is for everybody; building one is for whoever publishes it.
    //
    // Installing one is deliberately not here. `decanter use <file>` already
    // takes in every piece a person can be handed and works out what it is by
    // looking, and a pack is a piece. A second verb that installs would be a
    // second place for "what did Decanter just do with my file" to be
    // answered differently.
    switch rest.first ?? "check" {
    case "check":
        guard rest.count > 1 else {
            die(DecanterError.usage("usage: decanter pack check <pack directory>"))
        }
        let root = URL(filePath: (rest[1] as NSString).expandingTildeInPath)
        do {
            let located = try Pack.read(at: root)
            out("\(located.manifest.name)")
            out("  assembled \(located.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))"
                + " by \(located.manifest.createdBy)")
            for c in located.manifest.components.sorted(by: { $0.piece.rawValue < $1.piece.rawValue }) {
                out("  \(c.piece.label) \(c.version) — \(c.file)")
                out("      \(ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file))"
                    + ", \(c.licence), from \(c.origin)")
            }
            if !located.manifest.notes.isEmpty {
                out("")
                out("  \(located.manifest.notes)")
            }
            out("")
            let v = Pack.verify(located, progress: step)
            for line in v.checked { ok(line) }
            for line in v.problems { warn(line) }
            out("")
            out("  \(v.summary)")
            if !v.isSound { exit(1) }
        } catch { die(error) }

    case "build":
        // Every archive is named on the command line rather than discovered.
        // Assembling a pack is the one operation here whose output other people
        // install, and a file picked up because it happened to be in a folder
        // is exactly the mistake that must not be possible.
        var name = "decanter-pack"
        var outDir: URL? = nil
        var notes = ""
        var sign = false
        var allowIncomplete = false
        var archives: [Pack.Piece: URL] = [:]
        var origins: [Pack.Piece: String] = [:]
        var i = 1
        func nextValue(_ flag: String) -> String {
            guard i + 1 < rest.count else { die(DecanterError.usage("\(flag) needs a value")) }
            i += 1
            return rest[i]
        }
        while i < rest.count {
            switch rest[i] {
            case "--name": name = nextValue("--name")
            case "--out": outDir = URL(filePath: (nextValue("--out") as NSString).expandingTildeInPath)
            case "--notes": notes = nextValue("--notes")
            case "--sign": sign = true
            case "--allow-incomplete-wine": allowIncomplete = true
            case "--wine": archives[.wine] = URL(filePath: (nextValue("--wine") as NSString).expandingTildeInPath)
            case "--dxvk": archives[.dxvk] = URL(filePath: (nextValue("--dxvk") as NSString).expandingTildeInPath)
            case "--dxmt": archives[.dxmt] = URL(filePath: (nextValue("--dxmt") as NSString).expandingTildeInPath)
            case "--media": archives[.media] = URL(filePath: (nextValue("--media") as NSString).expandingTildeInPath)
            case "--wine-origin": origins[.wine] = nextValue("--wine-origin")
            case "--dxvk-origin": origins[.dxvk] = nextValue("--dxvk-origin")
            case "--dxmt-origin": origins[.dxmt] = nextValue("--dxmt-origin")
            case "--media-origin": origins[.media] = nextValue("--media-origin")
            default: die(DecanterError.usage("decanter pack build: unknown option \(rest[i])"))
            }
            i += 1
        }
        guard let outDir else {
            die(DecanterError.usage("""
            usage: decanter pack build --out <dir> --wine <archive> [--media <archive>]
                                   [--dxvk <archive>] [--dxmt <archive>]
                                       [--name N] [--notes TEXT] [--sign] [--allow-incomplete-wine]
                                       [--wine-origin TEXT] [--dxvk-origin TEXT] [--dxmt-origin TEXT]
            """))
        }
        guard !archives.isEmpty else { die(DecanterError.usage("a pack needs at least one archive")) }

        // Licences are constants, not options. They are a statement about what
        // the bytes are, checked once against each project's own LICENSE file,
        // and a command-line flag that can set them wrong is a command-line
        // flag that can publish a false claim.
        let licences: [Pack.Piece: String] = [
            .wine: "LGPL-2.1-or-later",   // Wine, and every macOS build of it
            .dxvk: "Zlib",                // github.com/doitsujin/dxvk
            .dxmt: "LGPL-2.1-or-later",   // github.com/3Shain/dxmt
            // GStreamer and the FFmpeg libraries beside it. LGPL is the
            // binding one and is what the licences file has to state; the
            // permissive pieces travelling with them do not weaken it.
            .media: "LGPL-2.1-or-later",  // Sikarugir-App/gstreamer
        ]
        let ingredients = Pack.Piece.allCases.compactMap { piece -> Pack.Ingredient? in
            guard let a = archives[piece] else { return nil }
            return Pack.Ingredient(piece: piece, archive: a,
                                   licence: licences[piece] ?? "unstated",
                                   origin: origins[piece] ?? a.lastPathComponent)
        }
        let e = engine()
        do {
            let built = try Pack.assemble(ingredients, named: name, into: outDir, notes: notes,
                                          paths: e.paths, signWithMaintainerKey: sign,
                                          allowIncompleteWine: allowIncomplete, progress: step)
            for w in built.warnings { warn(w) }
            ok(built.summary)
            out("  \(built.root.path)")
            if !sign {
                out("")
                out("  Unsigned. Whoever installs it can check the files against the manifest,")
                out("  but not that the manifest is yours. Pass --sign on the machine holding")
                out("  the endorsement key.")
            }
        } catch { die(error) }

    default: usage(to: true, exitCode: 2)
    }

case "endorse":
    // Making an endorsement needs a private key, which is the one thing an
    // open repository cannot hand out. Checking one needs only the public half,
    // so anyone can tell whether a row is genuinely vouched for.
    let e = engine()
    // Defaulted rather than matched on Optional: the documentation test
    // reads these case labels to check every command is written down, and a
    // pattern that is not a command confuses it.
    switch rest.first ?? "list" {
    case "keygen":
        do {
            let pair = try Endorsement.generateKeyPair()
            try Endorsement.writePrivateKey(pair.privateKeyBase64)
            try pair.publicKeyBase64.write(to: Endorsement.localPublicKeyPath,
                                           atomically: true, encoding: .utf8)
            ok("private key written to \(Endorsement.privateKeyPath.path)")
            out("    keep it, back it up, and never commit it \u{2014} losing it means every")
            out("    endorsement already made stops verifying, and there is no way back")
            out("")
            out("  public key (this is the half that ships):")
            out("    \(pair.publicKeyBase64)")
            out("")
            out("  paste it into Endorsement.maintainerPublicKey to bake it into releases.")
            out("  until then it is read from \(Endorsement.localPublicKeyPath.lastPathComponent), which a release ignores.")
        } catch { die(error) }

    case "list", "check":
        let rows = e.endorsements()
        if rows.isEmpty {
            out("  nothing here is endorsed")
        } else {
            for (o, valid) in rows {
                out("  \(valid ? "\u{2713}" : "\u{2717}") \(o.signature.label) \u{2014} \(o.setup.label)")
                if let n = o.note { out("      note: \(n)") }
                if !valid {
                    warn("this row's endorsement does not check out \u{2014} it was changed after it was vouched for, or it was signed with a different key")
                }
            }
        }
        out("")
        out(Endorsement.canEndorse
            ? "  this Mac holds an endorsement key, so it can vouch for a setup"
            : "  this Mac has no endorsement key \u{2014} `decanter endorse keygen` makes one")
        if Endorsement.canVerify && !Endorsement.keyIsBuiltIn {
            out("  the key in use came from a file beside Decanter, not from the build")
        }

    case "revoke":
        // Somebody has to be able to take back a claim they signed. A key that
        // can only ever add is a key whose holder cannot correct themselves.
        let (_, g) = requireGame(rest.count > 1 ? rest[1] : nil)
        do {
            if try e.revokeEndorsement(g) {
                ok("withdrawn for \(Knowledge.Signature(g.detection).label)")
                out("    what was seen here is still recorded \u{2014} the vouching and its note are not")
                out("    anyone who already took a copy still has the old one; this cannot reach them")
            } else {
                out("  nothing about this game's situation is endorsed")
            }
        } catch { die(error) }

    case let name:
        let (_, g) = requireGame(name)
        // Distinguished from a missing flag on purpose: `--note ""` asks for
        // the note to be removed, and used to be swallowed by the same test
        // that ignored an absent one.
        var note: String?
        if let i = rest.firstIndex(of: "--note"), i + 1 < rest.count { note = rest[i + 1] }
        do {
            let row = try e.endorse(g, note: note)
            ok("endorsed: \(row.setup.label) for \(row.signature.label)")
            if let n = row.note { out("    note: \(n)") }
            out("    this travels with the knowledge base and carries no name \u{2014} only the tier")
            if !Endorsement.isVerified(row) {
                warn("this build cannot check its own endorsements yet: no public key is baked in and none was found beside it")
            }
        } catch { die(error) }
    }

case "restore":
    // Describes first, like every other change Decanter offers to make.
    let e = engine()
    let (_, g) = requireGame(rest.first)
    guard let good = g.knownGood else {
        die(DecanterError.notFound(
            "nothing has been confirmed working for \(g.name) yet. Once you run it and say it worked, "
            + "Decanter can bring you back here."))
    }
    let when = good.confirmedAt.formatted(date: .abbreviated, time: .shortened)
    if let change = e.restorable(g) {
        out("\(g.name) last worked on \(change.label), confirmed \(when).")
        out("  It is on something else now.")
        if rest.contains("--do") {
            do {
                let done = try e.restoreKnownGood(g, progress: step)
                ok("\(g.name) is back on \(done.label)")
                out("    saves are kept; the Windows environment is rebuilt around them")
            } catch { die(error) }
        } else {
            out("")
            out("  Nothing has been changed. Run `decanter restore \(g.name) --do` to go back to it.")
        }
    } else {
        ok("\(g.name) is already on \(good.label), which is what last worked (\(when))")
    }

case "verdict":
    let e = engine()
    let v = Verdict(paths: e.paths)
    guard let p = v.pending() else {
        out("  there is no launch waiting to be judged")
        break
    }
    switch rest.first ?? "ask" {
    case "worked":
        do { ok(try e.settleVerdict(worked: true)) } catch { die(error) }
    case "failed":
        // A closed vocabulary, because free text is the one place a game title
        // could leak into knowledge that travels.
        var failure = Knowledge.Failure.unspecified
        if let i = rest.firstIndex(of: "--why"), i + 1 < rest.count,
           let f = Knowledge.Failure(rawValue: rest[i + 1]) { failure = f }
        var reason: Verdict.SwitchReason?
        if let i = rest.firstIndex(of: "--instead"), i + 1 < rest.count {
            reason = Verdict.SwitchReason(rawValue: rest[i + 1])
        }
        do { ok(try e.settleVerdict(worked: false, failure: failure, switchReason: reason)) }
        catch { die(error) }
    case "skip":
        v.clear()
        ok("left unjudged — nothing was recorded")
    default:
        out("  \(p.question)")
        if let q = p.switchQuestion { out("  \(q)") }
        out("")
        out("    decanter verdict worked")
        out("    decanter verdict failed [--why \(Knowledge.Failure.allCases.map(\.rawValue).joined(separator: "|"))]")
        if p.switchQuestion != nil {
            out("                           [--instead \(Verdict.SwitchReason.allCases.map(\.rawValue).joined(separator: "|"))]")
        }
        out("    decanter verdict skip")
    }

case "check":
    let (e, g) = requireGame(rest.first)
    do {
        let r = try e.preflight(g)
        // The plain answer first, then the working. Same sentence the app
        // shows, from the same place, so the two cannot drift.
        out("\(g.name): \(r.plainSummary)")
        out("")
        out("  runtime:  \(r.runtimeID)   backend: \(r.backend)")
        out("  dos path: \(r.winPath)")
        out("  drives:   \(r.scopesApplied.joined(separator: " "))")
        print(r.exeVisibleToWine ? "  \u{2713} Wine can see the executable"
                                 : "  \u{2717} Wine CANNOT see the executable")
        print(r.fullFilesystemExposed ? "  \u{2717} z: maps the whole filesystem"
                                      : "  \u{2713} whole-filesystem access is blocked")
        out("  graphics: \(r.effectiveD3D)")
        for p in r.problems { warn(p) }
        if !r.ok { warn("this would not go well \u{2014} see above") }
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
    switch rest.first {
    case "forget":
        try? FileManager.default.removeItem(at: e2.paths.knowledgePath)
        ok("forgot everything learned; back to the seeded defaults")

    case "export":
        // The export carries situations and outcomes and nothing else. There is
        // no flag to include game names because there is no field for one: a
        // name is not withheld here, it was never recorded.
        let dest = URL(filePath: ((rest.count > 1 ? rest[1] : "decanter-knowledge.json") as NSString)
            .expandingTildeInPath)
        do {
            let n = try e2.exportKnowledge(to: dest)
            ok("exported \(n) observation(s) to \(dest.path)")
            out("    no game names, no paths, no machine identifiers — situations and outcomes only")
            out("    open an issue on the tracker and attach it if you would like it merged")
        } catch { die(error) }

    case "import":
        guard rest.count > 1 else { die(DecanterError.usage("usage: decanter knowledge import <file>")) }
        let src = URL(filePath: (rest[1] as NSString).expandingTildeInPath)
        do {
            let r = try e2.importKnowledge(from: src)
            ok("took \(r.added) observation(s) from \(src.lastPathComponent)")
            if r.skipped > 0 {
                out("    skipped \(r.skipped) — this Mac already has an answer for those situations")
            }
            out("    notes are not imported: unsigned prose cannot be attributed to anyone")
        } catch { die(error) }

    case "explain":
        let (_, g) = requireGame(rest.count > 1 ? rest[1] : nil)
        let sig = Knowledge.Signature(g.detection)
        out("situation: \(sig.engineLabel), \(sig.bitness.label)"
            + (sig.usesVideo ? ", video" : "") + (sig.usesD3D12 ? ", D3D12" : "")
            + " on \(MachineClass.current().label)")
        out("")
        for level in Knowledge.Level.allCases {
            let here = k.observations(matching: sig, at: level)
            guard !here.isEmpty else { continue }
            let good = here.filter(\.worked).count, bad = here.count - good
            out("  \(level.label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(good) worked, \(bad) did not")
        }
        out("")
        if let a = k.best(for: sig, excluding: g.id) {
            ok("best answer: \(a.setup.label) — \(a.provenance)")
        } else {
            warn("nothing here answers for this situation yet")
        }
        for bad in k.knownBad(for: sig).prefix(4) {
            out("  ✗ \(bad.setup.label): \(bad.failure.label)")
        }

    default:
        out("what Decanter has learned (\(k.observations.count) observations):")
        out("")
        // Grouped by situation so the listing reads as knowledge rather than
        // as a log of everything that ever happened.
        var bySituation: [Knowledge.Signature: [Knowledge.Observation]] = [:]
        for o in k.observations { bySituation[o.signature, default: []].append(o) }
        let rows = bySituation.sorted {
            ($0.value.filter(\.worked).count, $0.key.engine.rawValue)
                > ($1.value.filter(\.worked).count, $1.key.engine.rawValue)
        }
        for (sig, obs) in rows {
            var profile = "\(sig.engineLabel), \(sig.bitness.label)"
            if sig.usesVideo { profile += ", video" }
            if sig.usesD3D12 { profile += ", D3D12" }
            if sig.chip != .unknown { profile += " · \(sig.chip.label)" }
            if let os = sig.macOSMajor { profile += " · macOS \(os)" }
            out("  \(profile)")
            for o in obs.sorted(by: { $0.worked && !$1.worked }) {
                let mark = o.worked ? "✓" : "✗"
                // Three provenances, and this printed two of them. An imported
                // row is not seeded, so it fell into the else and announced
                // itself as "observed here" — someone else's machine claiming
                // to be this one, in the one listing whose whole job is saying
                // where an answer came from.
                let how = "(\(o.origin.label))"
                // An endorsement is the strongest thing a row can carry and was
                // invisible here, so `endorse list` and `knowledge` described
                // the same row differently.
                let vouched = Endorsement.isVerified(o) ? "  ✦ verified" : ""
                let why = o.worked ? "" : " — \(( o.failure ?? .unspecified).label)"
                out("      \(mark) \(o.setup.label.padding(toLength: 24, withPad: " ", startingAt: 0)) \(how)\(vouched)\(why)")
            }
        }
        out("")
        out("  decanter knowledge explain <game>   what this says about one game")
        out("  decanter knowledge export [file]    hand the observations over, names-free")
        out("  decanter knowledge import <file>    fold someone else's export into this Mac's")
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
            if let blocker = d.blocker(onBackend: e2.store.bottle(g.bottleID)?.backend) {
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

case "dll":
    // Wine's own vocabulary, deliberately untranslated: anybody who needs this
    // is following a forum post that says n,b.
    let (e2, g) = requireGame(rest.first)
    let proxies = e2.modLoaderProxies(g)
    if rest.count == 1 {
        let cur = g.dllOverrides
        out("\(g.name) DLL overrides: \(cur.isEmpty ? "(none set by hand)" : cur.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
        if !proxies.isEmpty {
            out("")
            out("  mod loader proxy found: \(proxies.joined(separator: ", "))")
            out("  these are overridden automatically at launch \u{2014} nothing to set")
        }
        out("")
        out("  n    load the game's own copy")
        out("  b    load Wine's built-in")
        out("  n,b  the game's copy, then Wine's")
        out("  =    with nothing after it, disable the DLL entirely")
        out("")
        out("  set with:   decanter dll \(g.name) winhttp=n,b")
        out("  remove:     decanter dll \(g.name) winhttp --none")
    } else if rest.contains("--none") {
        let name = rest[1].split(separator: "=").first.map(String.init) ?? rest[1]
        do { let all = try e2.setDLLOverride(g, dll: name, mode: nil)
             ok(all.isEmpty ? "no overrides set by hand any more"
                            : "left: \(all.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))") }
        catch { die(error) }
    } else {
        let token = rest[1]
        guard let eq = token.firstIndex(of: "=") else {
            die(DecanterError.usage("usage: decanter dll <game> <name>=<n|b|n,b> (or <name> --none)"))
        }
        let name = String(token[token.startIndex..<eq])
        let mode = String(token[token.index(after: eq)...])
        do { let all = try e2.setDLLOverride(g, dll: name, mode: mode)
             ok("set: \(all.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
             out("    takes effect the next time this game starts") }
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
    out("  recommended: \(rec.runtimeKind == .gptk ? "Game Porting Toolkit" : "Wine 11") + \(rec.backend.plainName) graphics (\(rec.backend.label))")
    out("    \u{2014} \(rec.provenance.label)\(detailed ? ": " + rec.provenance.detail : "")")
    if let n = rec.note { out("    note: \(n)") }
    for r in rec.reasons { out("    \u{00b7} \(r)") }
    if let alt = rec.alternative {
        out("")
        out("  second option: \(alt.runtimeKind == .gptk ? "Game Porting Toolkit" : "Wine") + \(alt.backend.plainName) graphics (\(alt.backend.label))")
        out("    \u{00b7} \(alt.why)")
    }
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
            out("  \u{2717} \(st.errors.count) thing\(st.errors.count == 1 ? "" : "s") went wrong:")
            // The explanation leads and the line follows, the same way
            // everywhere else. The raw line is what gets pasted into a forum
            // thread, and it is useless as a headline.
            for e in st.errors {
                out("      \(ModInspector.explain(e))")
                if detailed { out("        \(e.prefix(200))") }
            }
        }
        if !st.notices.isEmpty {
            out("")
            for n in st.notices {
                out("  \u{00b7} \(n.summary)")
                if detailed { out("        \(n.evidence.prefix(200))") }
            }
        }
        if !st.benign.isEmpty {
            out("")
            // Said, but not counted. A loader that writes one harmless error on
            // every start otherwise makes every game look broken.
            out("  \(st.benign.count) error\(st.benign.count == 1 ? "" : "s") in the log that no mod is responsible for:")
            for b in st.benign {
                out("      \(ModInspector.whyBenign(b))")
                if detailed { out("        \(b.prefix(200))") }
            }
        }
        if !st.errors.isEmpty || !st.benign.isEmpty || !st.notices.isEmpty {
            if let l = st.logPath { out("  full log: \(l.path)") }
            if !detailed { out("  add --detail for the exact lines") }
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
        guard rest.count > 1 else { die(DecanterError.usage("usage: decanter saves search <text>")) }
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
        die(DecanterError.usage("usage: decanter saves list|show|snapshot|snapshots|restore|search|externalise|gc"))
    }

case "help", "--help", "-h": usage()
default:
    unknownCommand(cmd)
}
