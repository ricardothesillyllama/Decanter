import Foundation

/// Watches a launch and says what actually happened.
///
/// Launching used to be fire-and-forget: the CLI printed "launched" and the GUI
/// showed nothing, so a game that died two seconds later looked identical to one
/// that worked. This turns a launch into an observable outcome.
public struct LaunchMonitor {
    let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public enum Outcome: Sendable, Equatable {
        case rendering(width: Int, height: Int)
        case runningWithoutWindow
        case exited(after: TimeInterval)
        case neverStarted

        public var isGood: Bool { if case .rendering = self { return true }; return false }

        public var summary: String {
            switch self {
            case .rendering(let w, let h): "rendering at \(w)x\(h)"
            case .runningWithoutWindow:    "running, but no window appeared"
            case .exited(let t):           "exited after \(String(format: "%.0f", t))s"
            case .neverStarted:            "never started"
            }
        }
    }

    public struct Result: Sendable {
        public var outcome: Outcome = .neverStarted
        public var findings: [Diagnostics.Finding] = []
        /// Video is a separate question from rendering: a game can draw its UI
        /// perfectly and still fail to play a single frame of video.
        public var videoBroken = false
        /// Whether the game was still alive when observation ended. A game can
        /// draw a window and die seconds later; treating that as success taught
        /// the knowledge base a configuration that does not actually work.
        public var survived = false
        public var score: Int {
            var s = 0
            if outcome.isGood { s += 2 }
            if !videoBroken { s += 1 }
            if findings.isEmpty { s += 1 }
            return s
        }
    }

    /// Polls until the game renders, dies, or the deadline passes.
    /// 45 seconds was too short and the window match was too narrow, so a game
    /// that was on screen and playing could be reported as having exited early.
    /// A first launch compiles shaders, a large game loads slowly, and a game
    /// launched through a proxy loader draws its window from a process whose
    /// name is not the executable's.
    public func observe(game: Game, prefix: URL, engineLog: URL?, timeout: TimeInterval = 120,
                        progress: (String) -> Void = { _ in }) -> Result {
        var r = Result()
        let reaper = WineReaper(paths: paths)
        let started = Date()
        var sawProcess = false

        while Date().timeIntervalSince(started) < timeout {
            let pids = reaper.programPIDs(in: prefix)
            if !pids.isEmpty {
                sawProcess = true
                // A launcher or mod loader drawing from another process is
                // still covered, because any program in this Windows
                // environment counts. Matching on the file name is what made
                // one game's window answer for another's.
                if let w = reaper.gameWindow(in: prefix) {
                    r.outcome = .rendering(width: w.width, height: w.height)
                    progress("window appeared: \(w.width)x\(w.height)")
                    // Watch a while longer: games that fail on video or a
                    // missing interface typically render, then die within
                    // ~10-15s. Judging at first paint calls those a success.
                    let settle = Date()
                    while Date().timeIntervalSince(settle) < 18 {
                        Thread.sleep(forTimeInterval: 1.5)
                        if reaper.programPIDs(in: prefix).isEmpty {
                            r.outcome = .exited(after: Date().timeIntervalSince(started))
                            progress("it rendered, then exited — not a working setup")
                            break
                        }
                    }
                    r.survived = !reaper.programPIDs(in: prefix).isEmpty
                    break
                }
            } else if sawProcess {
                r.outcome = .exited(after: Date().timeIntervalSince(started))
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        if case .neverStarted = r.outcome, sawProcess { r.outcome = .runningWithoutWindow }

        // Fold in whatever the game engine recorded about itself — but only if
        // the log was actually written by this run.
        if let log = engineLog,
           let mod = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           mod >= started.addingTimeInterval(-5),
           let text = try? String(contentsOf: log, encoding: .utf8) {
            let d = Diagnostics()
            r.findings = d.analysePlayerLog(text)
            r.videoBroken = r.findings.contains(.videoNeedsMultithreadDevice)
                || text.lowercased().contains("windowsvideomedia error")
        }
        return r
    }
}
