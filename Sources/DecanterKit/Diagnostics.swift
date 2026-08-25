import Foundation

/// Turns Wine's very noisy failure output into something actionable.
/// Every launch writes a log; when a game misbehaves this is what reads it back.
public struct Diagnostics {
    public init() {}

    public enum Finding: Sendable, Equatable {
        case missingDLL(String)
        case vulkanUnavailable
        case d3dMetalUnavailable
        case bitnessRefused
        case scopeDenied(String)
        case moduleNotFound(String)
        case crashed(signal: String)
        case wineserverGone
        case noGraphicsDevice
        case unknown(String)
        case featureLevelUnsupported(String)
        case exitedWithoutWindow
        case videoNeedsMultithreadDevice
        case unrealWrongExecutable(String)
        case needsVisualCppRuntime(String)

        public var summary: String {
            switch self {
            case .missingDLL(let d):        "Missing DLL: \(d)"
            case .vulkanUnavailable:        "Vulkan/MoltenVK unavailable — DXVK cannot start"
            case .d3dMetalUnavailable:      "D3DMetal libraries not found for this runtime"
            case .bitnessRefused:           "Runtime refused the executable's architecture"
            case .scopeDenied(let p):       "Blocked access outside allowed folders: \(p)"
            case .moduleNotFound(let m):    "Wine could not find module: \(m)"
            case .crashed(let s):           "Process crashed (\(s))"
            case .wineserverGone:           "wineserver exited unexpectedly"
            case .noGraphicsDevice:         "Game could not create a graphics device"
            case .unknown(let s):           "Unrecognised failure: \(s)"
            case .featureLevelUnsupported(let l):
                "The game requires Direct3D feature level \(l), which this backend cannot provide"
            case .exitedWithoutWindow:      "The game started and exited without opening a window"
            case .videoNeedsMultithreadDevice:
                "Video playback failed: this backend's D3D11 device has no ID3D11Multithread interface"
            case .unrealWrongExecutable(let f):
                "This is Unreal's inner binary, not the game launcher (it wants \(f))"
            case .needsVisualCppRuntime(let d):
                "The game wants the Microsoft Visual C++ runtime (\(d))"
            }
        }

        /// What Decanter should try next. This is the bit that makes the
        /// "works on the most games" goal operational rather than aspirational.
        public var suggestion: String {
            switch self {
            case .missingDLL(let d):     "Install the dependency providing \(d), then re-derive the prefix."
            case .vulkanUnavailable:     "Switch this game's backend to wined3d."
            case .d3dMetalUnavailable:   "Switch to the Wine runtime with the dxvk backend."
            case .bitnessRefused:        "Use a runtime with 32-bit support (Wine 11 has WoW64)."
            case .scopeDenied(let p):    "If intended, grant that folder: decanter scope <game> --add \(p)"
            case .moduleNotFound:        "Re-derive the prefix; if it persists the game needs a dependency."
            case .crashed:               "Try backend wined3d, then the other runtime."
            case .wineserverGone:        "Re-derive the prefix (decanter rederive <game>)."
            case .noGraphicsDevice:      "Try a different graphics backend."
            case .unknown:               "Run with --verbose and inspect the full log."
            case .featureLevelUnsupported:
                "Switch this game to the Game Porting Toolkit runtime with the D3DMetal backend — DXVK on MoltenVK cannot offer 11_1."
            case .exitedWithoutWindow:
                "Check the engine's own log (Unity writes Player.log next to its saves); the failure is usually recorded there."
            case .needsVisualCppRuntime:
                "Install it: decanter install <game> vcrun. Wine ships vcruntime140/msvcp140 as builtins, so this usually means the game wants the real redistributable — often because its launcher checks the registry rather than the files."
            case .unrealWrongExecutable:
                "Re-add the game pointing at the .exe next to the Engine folder — that is the launcher. The binary under Binaries/Win64 cannot be run directly."
            case .videoNeedsMultithreadDevice:
                "Switch this game's backend to WineD3D. D3DMetal does not implement ID3D11Multithread, which Unity's video player requires — graphics will be slower, but the video will play."
            }
        }
    }

    public struct Report: Sendable {
        public var findings: [Finding] = []
        public var logPath: URL?
        public var tail: [String] = []
        public var isEmpty: Bool { findings.isEmpty }
    }

    public func analyse(logAt url: URL) -> Report {
        var r = Report(); r.logPath = url
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            r.findings = [.unknown("no log at \(url.path)")]
            return r
        }
        return analyse(text: text, logPath: url)
    }

    /// Unity records the real reason a launch failed in its own Player.log,
    /// not in Wine's output. Reading only Wine's log made a fatal graphics
    /// failure look like "nothing obviously wrong".
    public func analysePlayerLog(_ text: String) -> [Finding] {
        var out: [Finding] = []
        for line in text.split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("not-recognized"), l.contains("feature_level") {
                let level = line.contains("11_1") ? "11_1" : "11_0"
                out.append(.featureLevelUnsupported(level))
            }
            if l.contains("failed to create device and context") { out.append(.noGraphicsDevice) }
            // E_NOINTERFACE from the video path: the D3D11 device is missing
            // ID3D11Multithread. This is a backend limitation, not a codec
            // problem, and no amount of installing codecs will fix it.
            if l.contains("multithread protection failed")
                || (l.contains("windowsvideomedia error") && l.contains("0x80004002")) {
                out.append(.videoNeedsMultithreadDevice)
            }
            if l.contains("initializeenginegraphics failed") { out.append(.noGraphicsDevice) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.summary).inserted }
    }

    public func analyse(text: String, logPath: URL? = nil) -> Report {
        var r = Report(); r.logPath = logPath
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        r.tail = Array(lines.suffix(25))
        var found: [Finding] = []

        for line in lines {
            let l = line.lowercased()
            if l.contains("err:module:") || l.contains("failed to load") {
                if let dll = Self.firstMatch(#"([A-Za-z0-9_\-\.]+\.dll)"#, in: line) {
                    found.append(.missingDLL(dll))
                } else if let m = Self.firstMatch(#"L\"([^\"]+)\""#, in: line) {
                    found.append(.moduleNotFound(m))
                }
            }
            if l.contains("vulkan") && (l.contains("no device") || l.contains("failed")
                                        || l.contains("not available") || l.contains("cannot")) {
                found.append(.vulkanUnavailable)
            }
            if l.contains("d3dmetal") && (l.contains("not found") || l.contains("dyld")) {
                found.append(.d3dMetalUnavailable)
            }
            if l.contains("wine cannot find") || l.contains("bad exe format")
                || l.contains("not a valid win32 application") {
                found.append(.bitnessRefused)
            }
            if l.contains("operation not permitted") || l.contains("permission denied") {
                let p = Self.firstMatch(#"((?:/|[A-Za-z]:\\)[^\s\"']+)"#, in: line) ?? "unknown path"
                found.append(.scopeDenied(p))
            }
            if l.contains("wineserver: exiting") || l.contains("wineserver crash") {
                found.append(.wineserverGone)
            }
            if l.contains("createdevice") && l.contains("fail") { found.append(.noGraphicsDevice) }
            // The genuine Visual C++ case: a named runtime DLL, a side-by-side
            // failure, or the game's own "requires the C++ runtime" dialog.
            if l.contains("vcruntime") || l.contains("msvcp140")
                || l.contains("side-by-side") || l.contains("sxs")
                || (l.contains("c++") && (l.contains("runtime") || l.contains("redistributable"))) {
                let which = Self.firstMatch(#"([A-Za-z0-9_]+140[A-Za-z0-9_]*\.dll)"#, in: line)
                    ?? "Visual C++ redistributable"
                found.append(.needsVisualCppRuntime(which))
            }
            if l.contains("failed to open descriptor file") {
                let f = Self.firstMatch(#"'([^']+)'"#, in: line) ?? "a .uproject file"
                found.append(.unrealWrongExecutable(f))
            }
            if l.contains("unhandled exception") || l.contains("sigsegv") || l.contains("sigabrt") {
                found.append(.crashed(signal: l.contains("sigsegv") ? "SIGSEGV" : "unhandled exception"))
            }
        }
        // De-duplicate while preserving order.
        var seen = Set<String>()
        r.findings = found.filter { seen.insert($0.summary).inserted }
        return r
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
