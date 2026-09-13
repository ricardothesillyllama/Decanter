import Foundation
import AppKit
import DecanterKit

/// This binary, running as the launcher inside an exported bundle.
///
/// Opened from Finder there is no terminal, so anything that has to be said is
/// said in a dialog. Run from a terminal, it prints instead, which is also how
/// `--prepare-only` checks a bundle without putting a game on screen.
@MainActor
func runPortable(_ runner: BundleRunner, prepareOnly: Bool) -> Never {
    // `--prepare-only` is a check run from scripts and tests, so it always
    // answers in text — a dialog there would appear on someone's screen.
    let interactive = isatty(STDOUT_FILENO) != 0 || prepareOnly
    func tell(_ title: String, _ message: String) {
        if interactive {
            FileHandle.standardError.write(Data("\(title)\n\(message)\n".utf8))
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    do {
        switch try runner.prepare(progress: { if interactive { print("  \u{2022} \($0)") } }) {
        case .needsGPTK(let why):
            tell("\(runner.manifest.gameName) needs the Game Porting Toolkit", why)
            exit(4)
        case .ready(let e, let g):
            if prepareOnly {
                print("  \u{2713} \(g.name) is ready to run from \(runner.home.path)")
                if let b = e.store.bottle(g.bottleID) {
                    print("    Wine:    \(b.runtimeID)")
                    print("    graphics: \(b.backend.plainName) (\(b.backend.label))")
                    print("    Windows environment: \(b.prefixPath.path)")
                }
                print("    game:    \(g.exePath.path)")
                exit(0)
            }
            let plan = try e.run(g)
            // Stay open while the game runs, so the bundle reads as the running
            // app — and so a game that never starts gets a sentence rather
            // than silence.
            let reaper = WineReaper(paths: e.paths)
            var appeared = false
            let deadline = Date().addingTimeInterval(45)
            while true {
                Thread.sleep(forTimeInterval: 1.5)
                if reaper.sessionIsLive(in: plan.bottle.prefixPath) { appeared = true; continue }
                if appeared { exit(0) }
                if Date() > deadline {
                    let rep = Diagnostics().analyse(logAt: plan.logFile)
                    tell("\(g.name) did not start",
                         rep.findings.first.map { "\($0.summary)\n\n\($0.suggestion)" }
                            ?? "Nothing in its log says why. The log is at \(plan.logFile.path).")
                    exit(1)
                }
            }
        }
    } catch {
        tell("\(runner.manifest.gameName) could not start", error.localizedDescription)
        exit(1)
    }
}
