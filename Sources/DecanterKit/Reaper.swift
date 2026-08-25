import Foundation

/// Finds and kills Wine processes that outlived the app that started them.
///
/// Wine is not a normal child process. `wine foo.exe` forks a wineserver and a
/// set of service processes (services.exe, plugplay.exe, explorer.exe) that
/// re-parent to launchd, so sending SIGTERM to the process we spawned leaves
/// the whole session running. When Decanter quits, or a wineboot blows its
/// timeout, those survivors keep burning CPU under the app's name — macOS still
/// attributes their energy to Decanter even though Decanter is long gone, which
/// makes it look like the app is running when it is not.
///
/// The reliable way to end a Wine session is to kill its wineserver: every
/// client dies with it. SIGKILL is only the fallback for processes whose prefix
/// no longer exists.
public struct WineReaper {
    let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public struct Stray: Sendable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var cpu: Double
        /// As `ps` reports it: `[[dd-]hh:]mm:ss`.
        public var elapsed: String
        public var command: String
        public var prefix: URL?
        /// Wine's own background services, as opposed to a real program.
        public var isService: Bool

        public init(pid: Int32, cpu: Double, elapsed: String, command: String,
                    prefix: URL?, isService: Bool) {
            self.pid = pid; self.cpu = cpu; self.elapsed = elapsed
            self.command = command; self.prefix = prefix; self.isService = isService
        }
        public var age: TimeInterval { Self.seconds(elapsed) }

        /// What to call this in a list. `ps` shows a Wine process either as a
        /// Windows path or as the Mac binary that loaded it, and for a loader
        /// the interesting part is the .exe argument rather than argv[0] —
        /// naming that row "wine64-preloader" would hide which one is stuck.
        public var displayName: String {
            let tokens = command.split(separator: " ").map(String.init)
            // Splitting on spaces cannot find the Mac binary, because our own
            // runtime path contains "Application Support". So when there is no
            // .exe token, take everything up to the first argument instead.
            var exe = tokens.first { $0.lowercased().hasSuffix(".exe") } ?? command
            if !exe.lowercased().hasSuffix(".exe") {
                let argStart = [" -", " C:\\", " Z:\\"]
                    .compactMap { command.range(of: $0)?.lowerBound }.min()
                exe = String(command[command.startIndex..<(argStart ?? command.endIndex)])
            }
            let leaf = exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? exe
            // rundll32 is a shell; say what it is actually installing.
            if leaf.lowercased() == "rundll32.exe",
               let inf = tokens.last(where: { $0.lowercased().hasSuffix(".inf") }) {
                let f = inf.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? inf
                return "rundll32.exe (installing \(f))"
            }
            return leaf
        }

        public static func seconds(_ etime: String) -> TimeInterval {
            var days = 0.0, rest = etime
            if let dash = rest.firstIndex(of: "-") {
                days = Double(rest[rest.startIndex..<dash]) ?? 0
                rest = String(rest[rest.index(after: dash)...])
            }
            let parts = rest.split(separator: ":").compactMap { Double($0) }
            let hms = parts.reduce(0.0) { $0 * 60 + $1 }
            return days * 86400 + hms
        }
    }

    static let services = ["services.exe", "winedevice.exe", "plugplay.exe",
                           "explorer.exe", "svchost.exe", "rpcss.exe",
                           "rundll32.exe", "wineboot.exe", "start.exe", "conhost.exe"]

    /// Everything Wine-ish still alive that this install is responsible for.
    ///
    /// Matches two shapes: processes running out of our runtimes directory, and
    /// processes whose argv is a Windows path — that is how Wine relabels its
    /// own children, so `ps` shows `C:\windows\system32\services.exe` with no
    /// trace of which Mac installed it.
    public func strays() -> [Stray] {
        guard let r = try? Shell.run(URL(filePath: "/bin/ps"),
                                     ["-Ao", "pid=,pcpu=,etime=,command="], timeout: 20)
        else { return [] }
        var out: [Stray] = []
        let runtimeRoot = paths.runtimes.path
        for line in r.out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let cols = t.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4, let pid = Int32(cols[0]) else { continue }
            let command = String(cols[3])
            let fromUs = command.contains(runtimeRoot)
            let windowsy = command.hasPrefix("C:\\") || command.hasPrefix("Z:\\")
            guard fromUs || windowsy else { continue }
            // Never target ourselves or the process doing the scanning.
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let exe = command.split(separator: "\\").last.map(String.init)?
                .split(separator: " ").first.map(String.init) ?? ""
            out.append(Stray(pid: pid,
                             cpu: Double(cols[1]) ?? 0,
                             elapsed: String(cols[2]),
                             command: command,
                             prefix: prefix(of: pid),
                             isService: Self.services.contains(exe.lowercased())))
        }
        return out.sorted { $0.cpu > $1.cpu }
    }

    /// Reads WINEPREFIX out of a running process's environment.
    ///
    /// The value routinely contains spaces ("Application Support"), so it is
    /// read up to the next `NAME=` token rather than to the next space — which
    /// is the bug that made an earlier version report a truncated path.
    func prefix(of pid: Int32) -> URL? {
        guard let r = try? Shell.run(URL(filePath: "/bin/ps"),
                                     ["eww", "-o", "command=", "-p", String(pid)], timeout: 15)
        else { return nil }
        guard let start = r.out.range(of: "WINEPREFIX=") else { return nil }
        let tail = r.out[start.upperBound...]
        let pattern = try? NSRegularExpression(pattern: #"\s+[A-Za-z_][A-Za-z0-9_]*="#)
        let s = String(tail)
        let end = pattern?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            .flatMap { Range($0.range, in: s)?.lowerBound } ?? s.endIndex
        let path = String(s[s.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(filePath: path)
    }

    /// Every wineserver binary this install has staged.
    func wineservers() -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: paths.runtimes.path) else { return [] }
        return dirs.map { paths.runtimes.appending(path: "\($0)/bin/wineserver") }
            .filter { fm.isExecutableFile(atPath: $0.path) }
    }

    public struct Outcome: Sendable {
        public var sessionsEnded = 0
        public var killed: [Int32] = []
        public var survived: [Int32] = []
    }

    /// Ends every stray Wine session. `keeping` spares prefixes that belong to
    /// something the caller knows is legitimately running.
    @discardableResult
    public func reap(keeping live: Set<URL> = [], progress: (String) -> Void = { _ in }) -> Outcome {
        let liveResolved = Set(live.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        return reap(progress: progress) { s in
            guard let p = s.prefix else { return true }
            return !liveResolved.contains(p.resolvingSymlinksInPath().standardizedFileURL)
        }
    }

    /// Ends only the sessions `matching` selects. Used by the test suite, which
    /// must clean up after itself without touching a game the user is playing.
    @discardableResult
    public func reap(progress: (String) -> Void = { _ in },
                     matching: (Stray) -> Bool) -> Outcome {
        var o = Outcome()
        let doomed = strays().filter(matching)
        guard !doomed.isEmpty else { return o }

        // Preferred route: ask each session's wineserver to shut down, which
        // takes its clients with it and lets Wine flush the registry cleanly.
        var prefixes = Set<String>()
        for s in doomed { if let p = s.prefix { prefixes.insert(p.path) } }
        for path in prefixes.sorted() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            // Scanned off disk rather than taken from the pinned list: a
            // stray can outlive the runtime record that started it.
            for ws in wineservers() {
                progress("shutting down wineserver for \(URL(filePath: path).lastPathComponent)")
                _ = try? Shell.run(ws, ["-k"], env: ["WINEPREFIX": path], timeout: 30)
            }
            o.sessionsEnded += 1
        }

        // Anything still standing had no reachable prefix (a deleted temp dir)
        // or ignored the request. SIGKILL, because SIGTERM is what failed.
        usleep(500_000)
        let remaining = Set(strays().map(\.pid))
        for s in doomed where remaining.contains(s.pid) {
            if kill(s.pid, SIGKILL) == 0 { o.killed.append(s.pid) }
            else { o.survived.append(s.pid) }
        }
        return o
    }
}
