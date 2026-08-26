import Foundation
import CoreGraphics

/// Builds a single pasteable diagnostic bundle. The motivating case: a game
/// launches but renders wrongly. Nothing crashes, so the log alone proves
/// nothing — the bundle pairs configuration and log with a screenshot of the
/// actual window.
public struct Reporter {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    // MARK: System facts

    public static func systemSummary() -> [String: String] {
        var d: [String: String] = [:]
        func sh(_ cmd: String, _ args: [String]) -> String {
            (try? Shell.run(URL(filePath: cmd), args, timeout: 30).out
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "?"
        }
        d["macOS"] = sh("/usr/bin/sw_vers", ["-productVersion"]) + " (" + sh("/usr/bin/sw_vers", ["-buildVersion"]) + ")"
        d["chip"] = sh("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        d["arch"] = sh("/usr/bin/uname", ["-m"])
        if let mem = try? Shell.run(URL(filePath: "/usr/sbin/sysctl"), ["-n", "hw.memsize"], timeout: 15).out
            .trimmingCharacters(in: .whitespacesAndNewlines), let b = Double(mem) {
            d["memory"] = String(format: "%.0f GB", b / 1_073_741_824)
        }
        d["rosetta"] = FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta") ? "installed" : "MISSING"
        let gpu = sh("/usr/sbin/system_profiler", ["SPDisplaysDataType"])
        for line in gpu.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Chipset Model:") { d["gpu"] = t.replacingOccurrences(of: "Chipset Model:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("Metal Support:") { d["metal"] = t.replacingOccurrences(of: "Metal Support:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("Resolution:") && d["resolution"] == nil {
                d["resolution"] = t.replacingOccurrences(of: "Resolution:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return d
    }

    // MARK: Window capture

    public struct WindowRef: Sendable {
        public var id: CGWindowID
        public var owner: String
        public var title: String
        public var width: Int
        public var height: Int
        public var pid: pid_t
    }

    /// PIDs running a given executable. Every Wine window is owned by a
    /// process called "wine", so with two games open the only way to tell them
    /// apart — for a screenshot, or for a test — is the executable name, which
    /// does appear in the command line (as "H:\\Game.exe").
    /// The prefix path does not: it lives in the environment, and macOS blocks
    /// reading another process's environment.
    public static func pids(forExecutable exe: URL) -> Set<pid_t> {
        let r = try? Shell.run(URL(filePath: "/usr/bin/pgrep"),
                               ["-f", exe.lastPathComponent], timeout: 20)
        let out = r?.out ?? ""
        return Set(out.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Finds on-screen windows belonging to Wine. Wine windows are owned by
    /// processes named `wine`/`wine64`/`wine-preloader` or by the game exe.
    public static func wineWindows() -> [WindowRef] {
        // Wine's real game window is often NOT in the on-screen list: it can be
        // on another space, or not yet mapped. Returning on-screen results
        // *only when non-empty* was wrong — with one game already visible, a
        // second game's window would never be found, because the fallback
        // never fired. Always consider both, on-screen first.
        let onScreen = collectWineWindows([.optionOnScreenOnly, .excludeDesktopElements])
        let everything = collectWineWindows([.excludeDesktopElements])
        var seen = Set(onScreen.map(\.id))
        return onScreen + everything.filter { seen.insert($0.id).inserted }
    }

    private static func collectWineWindows(_ opts: CGWindowListOption) -> [WindowRef] {
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowRef] = []
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (w[kCGWindowName as String] as? String) ?? ""
            let lower = owner.lowercased()
            let looksWine = lower == "wine" || lower.hasPrefix("wine")
                || lower.hasSuffix(".exe") || lower.contains("preloader")
            guard looksWine else { continue }
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
            else { continue }
            // Only exclude things too small to be any game window at all.
            guard width >= 64, height >= 64 else { continue }
            let pid = (w[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } ?? 0
            out.append(WindowRef(id: id, owner: owner, title: title,
                                 width: Int(width), height: Int(height), pid: pid))
        }
        // Largest first: the game window, not a tool palette.
        return out.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// Decanter deliberately does NOT take screenshots. Doing so needs Screen
    /// Recording permission, which macOS re-prompts for on every rebuild of an
    /// unsigned app — a permanent nuisance for a feature the user can perform
    /// better themselves with Command-Shift-4.
    public static let manualCaptureAdvice = """
    Attach a screenshot if the problem is visual:
      press Command-Shift-4, then Space, then click the game window.
    """

    // MARK: The bundle

    /// Replaces the user's home directory with `~` throughout.
    ///
    /// Both the real path and its /private-prefixed twin, since Wine and `ps`
    /// disagree about which one they report.
    public static func redactHome(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        var out = text.replacingOccurrences(of: "/private" + home, with: "~")
        out = out.replacingOccurrences(of: home, with: "~")
        return out
    }

    /// Blank-but-correctly-sized text is a font failure that looks like a
    /// rendering failure, so the report has to say whether the Windows font
    /// names are mapped. Without this line the only symptom is a screenshot.
    func fontSummary(_ prefix: URL) -> String {
        let fp = FontProvisioner()
        let installed = fp.installed(in: prefix)
        let missing = fp.plan(for: prefix).pending.count
        if installed.isEmpty {
            return missing > 0
                ? "**none — \(missing) Windows font name(s) resolve to nothing**"
                : "not needed"
        }
        return "\(installed.count) mapped" + (missing > 0 ? ", \(missing) still unmapped" : "")
    }

    public func buildReport(game: Game, bottle: Bottle, runtime: RuntimeSpec,
                            preflight: Engine.PreflightReport?,
                            progress: (String) -> Void = { _ in }) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safe = game.name.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let dir = paths.root.appending(path: "reports")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let reportURL = dir.appending(path: "decanter-\(safe)-\(stamp).md")


        let sys = Self.systemSummary()
        let logURL = paths.logs.appending(path: "\(game.name.replacingOccurrences(of: "/", with: "_")).log")
        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
        let logLines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diag = Diagnostics().analyse(text: logText, logPath: logURL)

        var md = """
        # Decanter problem report

        **Game:** \(game.name)
        **When:** \(Date().formatted(date: .abbreviated, time: .standard))
        **Screenshot:** none — take one with Command-Shift-4, Space, click the window, and attach it.
        
        ## System

        | | |
        |---|---|
        | macOS | \(sys["macOS"] ?? "?") |
        | Chip | \(sys["chip"] ?? "?") (\(sys["arch"] ?? "?")) |
        | GPU | \(sys["gpu"] ?? "?") — \(sys["metal"] ?? "?") |
        | Memory | \(sys["memory"] ?? "?") |
        | Display | \(sys["resolution"] ?? "?") |
        | Rosetta 2 | \(sys["rosetta"] ?? "?") |

        ## Configuration

        | | |
        |---|---|
        | Runtime | \(runtime.id) (\(runtime.kind.rawValue) \(runtime.version)) |
        | 32-bit capable | \(runtime.supports32Bit ? "yes" : "no") |
        | Graphics backend | \(bottle.backend.label) |
        | Effective D3D | \(preflight?.effectiveD3D ?? "unknown") |
        | DXVK in prefix | \(DXVKInstaller(paths: paths).isInstalled(in: bottle.prefixPath) ? (DXVKInstaller(paths: paths).stagedVersion ?? "yes") : "no") |
        | Prefix generation | \(bottle.generation) |
        | Font name mapping | \(fontSummary(bottle.prefixPath)) |
        | Executable | `\(game.exePath.path)` |
        | DOS path | `\(preflight?.winPath ?? "?")` |
        | Drives | \(preflight?.scopesApplied.joined(separator: " ") ?? "?") |

        ## Detection

        - Engine: \(game.detection.engine.label)
        - Architecture: \(game.detection.bitness.label)
        - Graphics APIs referenced: \(game.detection.graphicsAPIs.isEmpty ? "none" : game.detection.graphicsAPIs.joined(separator: ", "))
        - Modded: \(game.detection.modded ? "yes" : "no")
        - Confidence: \(String(format: "%.2f", game.detection.confidence))

        Evidence:
        \(game.detection.signals.map { "- [\(String(format: "%.2f", $0.weight))] \($0.rule)" }.joined(separator: "\n"))

        ## Automatic diagnosis

        \(diag.findings.isEmpty ? "No recognised failure signature in the log. If the game renders incorrectly but does not crash, this is expected — see the screenshot and the graphics log below."
          : diag.findings.map { "- **\($0.summary)** — \($0.suggestion)" }.joined(separator: "\n"))

        ## Graphics-relevant log lines

        ```
        \(Self.graphicsLines(logLines).joined(separator: "\n"))
        ```

        ## Last 120 log lines

        ```
        \(logLines.suffix(120).joined(separator: "\n"))
        ```
        """
        if md.count > 400_000 { md = String(md.prefix(400_000)) + "\n\n(truncated)" }
        // Every path in here contained the account name. The README tells
        // people they may redact the game; it should not then leak who they
        // are through /Users/<name> in a dozen places.
        let redacted = Self.redactHome(md)
        try redacted.write(to: reportURL, atomically: true, encoding: .utf8)
        return reportURL
    }

    /// Pulls out the lines that matter for a rendering problem specifically.
    static func graphicsLines(_ lines: [String]) -> [String] {
        let keys = ["vulkan", "moltenvk", "mvk-", "dxvk", "d3dmetal", "metal", "d3d11", "d3d12",
                    "dxgi", "opengl", "shader", "swapchain", "adapter", "device", "gpu",
                    "resolution", "fullscreen", "display"]
        var out: [String] = []
        for l in lines {
            let low = l.lowercased()
            if keys.contains(where: { low.contains($0) }) { out.append(l) }
            if out.count >= 150 { break }
        }
        return out.isEmpty ? ["(no graphics-related lines found)"] : out
    }
}
