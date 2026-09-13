import Foundation
import AppKit
import DecanterKit

/// This binary, running as the launcher inside an exported bundle.
///
/// Opened from Finder there is no terminal, so anything that has to be said is
/// said in a dialog, and a missing Game Porting Toolkit is asked for with an
/// open panel. Run from a terminal it prints instead, and takes the toolkit as
/// `--gptk <path>` — which is also how `--prepare-only` checks a bundle without
/// putting a game or a dialog on anyone's screen.
@MainActor
func runPortable(_ runner: BundleRunner, arguments: [String]) -> Never {
    let prepareOnly = arguments.contains("--prepare-only")
    let interactive = isatty(STDOUT_FILENO) != 0 || prepareOnly
    let say: (String) -> Void = { if interactive { print("  \u{2022} \($0)") } }

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

    func askForGPTK(_ title: String, _ message: String) -> URL? {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Choose…")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Game Porting Toolkit — its disk image, or the app"
        return panel.runModal() == .OK ? panel.url : nil
    }

    if let i = arguments.firstIndex(of: "--gptk"), i + 1 < arguments.count {
        do {
            let said = try runner.acceptGPTK(from: URL(filePath: (arguments[i + 1] as NSString).expandingTildeInPath),
                                             progress: say)
            if interactive { print("  \u{2713} \(said)") }
        } catch {
            tell("That is not the Game Porting Toolkit", error.localizedDescription)
            exit(4)
        }
    }

    while true {
        do {
            switch try runner.prepare(progress: say) {
            case .needsGPTK(let why):
                let title = "\(runner.manifest.gameName) needs the Game Porting Toolkit"
                if interactive {
                    tell(title, why + "\n\nFrom a terminal:\n  \"\(runner.app.path)/Contents/MacOS/\(Export.launcherName)\" --gptk <disk image or app>")
                    exit(4)
                }
                guard let chosen = askForGPTK(title, why) else { exit(4) }
                do { _ = try runner.acceptGPTK(from: chosen, progress: say) }
                catch { tell("That is not the Game Porting Toolkit", error.localizedDescription) }
                continue

            case .ready(let e, let g):
                if prepareOnly {
                    print("  \u{2713} \(g.name) is ready to run from \(runner.home.path)")
                    if let b = e.store.bottle(g.bottleID) {
                        print("    Wine:     \(b.runtimeID)")
                        print("    graphics: \(b.backend.plainName) (\(b.backend.label))")
                        print("    Windows environment: \(b.prefixPath.path)")
                    }
                    print("    game:     \(g.exePath.path)")
                    exit(0)
                }
                let plan = try e.run(g)
                // Stay open while the game runs, so the bundle reads as the
                // running app — and so a game that never starts gets a sentence
                // rather than silence.
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
}
