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
        /// A Windows API set the Wine build does not implement. Distinct from a
        /// renderer failure and fixed by different things — a newer Wine, or an
        /// override — but both used to surface to the user as the same
        /// "Failed to load il2cpp".
        case missingAPISet(String)
        /// The renderer could not create a D3D11 fence. Unity 6 treats this as
        /// fatal; no launch flag or backend toggle in Decanter changes it.
        case d3d11FenceUnsupported
        /// Wine could not activate a WinRT class. Games reach these through
        /// native plugins, so it surfaces as a DllNotFoundException on the
        /// plugin rather than as anything mentioning WinRT.
        case winrtClassUnavailable(String)
        /// A native plugin the game ships failed to load.
        case nativePluginMissing(String)
        /// DXVK refused to start. 2.x and 3.x require Vulkan 1.3, which
        /// MoltenVK does not fully implement, so they fail outright at
        /// initialisation instead of limping along and rendering badly.
        case dxvkNeedsNewerVulkan
        case needsVisualCppRuntime(String)
        /// The Wine build has no FreeType, so it can render no TrueType font.
        /// Its message begins "Wine cannot find", which used to be matched as
        /// an architecture refusal — sending a 64-bit game after 32-bit
        /// support over a missing library.
        case fontLibraryMissing
        /// Wine could not start the executable at all, with the NT status it
        /// gave for refusing.
        ///
        /// The most common way a launch fails, and nothing here matched it.
        /// A log whose only line was `wine: failed to open "H:\\game.exe":
        /// c0000135` came back as "nothing wrong found in the last run's log",
        /// under a green tick, which is the worst thing this file can do.
        ///
        /// The status is decoded rather than repeated. `c0000135` and
        /// `c000007b` are different problems with different fixes, and neither
        /// hex string is something a person can act on.
        case executableWouldNotStart(exe: String, status: String?)

        public var summary: String {
            switch self {
            case .missingDLL(let d):        "Missing DLL: \(d)"
            case .executableWouldNotStart(let exe, let status):
                if let m = Diagnostics.statusMeaning(status) {
                    "Windows would not start \(exe): \(m.what)"
                } else {
                    "Windows would not start \(exe)"
                }
            case .vulkanUnavailable:        "Vulkan/MoltenVK unavailable — DXVK cannot start"
            case .d3dMetalUnavailable:      "D3DMetal libraries not found for this runtime"
            case .bitnessRefused:           "Runtime refused the executable's architecture"
            case .fontLibraryMissing:       "This Windows environment cannot draw text — it has no font library"
            case .scopeDenied(let p):       "Blocked access outside allowed folders: \(p)"
            case .moduleNotFound(let m):    "Wine could not find module: \(m)"
            case .crashed(let s):           "Process crashed (\(s))"
            case .wineserverGone:           "wineserver exited unexpectedly"
            case .noGraphicsDevice:         "Game could not create a graphics device"
            case .missingAPISet(let dll):
                "The engine needs \(dll), which this Wine build does not implement"
            case .d3d11FenceUnsupported:
                "The graphics layer could not create a Direct3D 11 fence, which this engine requires"
            case .winrtClassUnavailable(let cls):
                "This Wine build cannot provide \(cls), a Windows Runtime component the game asks for"
            case .nativePluginMissing(let dll):
                "The game's own plugin \(dll) could not be loaded"
            case .dxvkNeedsNewerVulkan:
                "This DXVK build needs Vulkan 1.3, which macOS does not fully provide"
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

        /// Whether this finding means the game's process will never exist.
        ///
        /// The launch watcher waits for a process to appear before it will
        /// conclude anything, and waited the whole timeout even when the log
        /// had already said, in its first line and within a second, that Wine
        /// refused the executable. Somebody watched "Running" for the better
        /// part of a minute over a game that never started.
        ///
        /// Only refusals to start. A missing DLL or a graphics complaint can
        /// appear in the log of a launch that goes on to work perfectly, and
        /// treating those as fatal would cut short a healthy start.
        public var meansItWillNeverStart: Bool {
            switch self {
            case .executableWouldNotStart, .bitnessRefused, .unrealWrongExecutable: true
            default: false
            }
        }

        /// What Decanter should try next. This is the bit that makes the
        /// "works on the most games" goal operational rather than aspirational.
        public var suggestion: String {
            switch self {
            case .missingDLL(let d):     "Install the dependency providing \(d), then re-derive the prefix."
            case .executableWouldNotStart(_, let status):
                Diagnostics.statusMeaning(status)?.fix
                    ?? "Check that the game's files are still where Decanter found them, then re-inspect it."
            case .vulkanUnavailable:     "Switch this game's backend to wined3d."
            case .d3dMetalUnavailable:   "Switch to the Wine runtime with the dxvk backend."
            case .bitnessRefused:        "Use a runtime with 32-bit support (Wine 11 has WoW64)."
            case .fontLibraryMissing:
                "This Wine build is missing libfreetype. Menus and dialogs will be blank or boxed. Use a different Windows environment, or replace this one with a complete build."
            case .scopeDenied(let p):    "If intended, grant that folder: decanter scope <game> --add \(p)"
            case .moduleNotFound:        "Re-derive the prefix; if it persists the game needs a dependency."
            case .crashed:               "Try backend wined3d, then the other runtime."
            case .wineserverGone:        "Re-derive the prefix (decanter rederive <game>)."
            case .noGraphicsDevice:      "Try a different graphics backend."
            case .missingAPISet:
                "A newer Wine is the likely fix — this is a gap in the Windows API sets it implements, not a graphics problem. Switching graphics mode will not help."
            case .d3d11FenceUnsupported:
                "No graphics mode available here provides it. A translation layer that implements the D3D11 fence interfaces, such as DXMT, is the shape of the answer."
            case .winrtClassUnavailable:
                "A gap in this Wine build's Windows Runtime support. A newer engine may cover it; changing graphics mode will not, because this is not a graphics problem."
            case .dxvkNeedsNewerVulkan:
                "Use DXVK 1.10.3 — it targets Vulkan 1.1 and is the build that works on macOS. `decanter dxvk use <game> 1.10.3`."
            case .nativePluginMissing:
                "Usually a knock-on effect: the plugin loads, then fails because something it needs is missing. Look for a Windows Runtime or API-set error above it."
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
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.lowercased()
            if l.contains("not-recognized"), l.contains("feature_level") {
                let level = line.contains("11_1") ? "11_1" : "11_0"
                out.append(.featureLevelUnsupported(level))
            }
            if l.contains("failed to create device and context") { out.append(.noGraphicsDevice) }
            // E_NOINTERFACE from the video path: the D3D11 device is missing
            // ID3D11Multithread. This is a backend limitation, not a codec
            // problem, and no amount of installing codecs will fix it.
            // Unity prints this and then says "Will use software video
            // decoding" — it degrades rather than dying. Reporting it as the
            // failure sent people to change backends over a line the engine
            // had already handled, while the real crash sat further down.
            if l.contains("multithread protection failed")
                || (l.contains("windowsvideomedia error") && l.contains("0x80004002")) {
                let recovered = l.contains("software video decoding")
                    || l.contains("will use software")
                if !recovered { out.append(.videoNeedsMultithreadDevice) }
            }
            if l.contains("dllnotfoundexception"),
               let plugin = Self.firstMatch(#"DllNotFoundException:\s*([A-Za-z0-9_.\-]+)"#, in: String(line)) {
                out.append(.nativePluginMissing(plugin))
            }
            if l.contains("initializeenginegraphics failed") { out.append(.noGraphicsDevice) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.summary).inserted }
    }

    public func analyse(text: String, logPath: URL? = nil) -> Report {
        var r = Report(); r.logPath = logPath
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        r.tail = Array(lines.suffix(25))
        var found: [Finding] = []

        for line in lines {
            let l = line.lowercased()
            // Wine could not activate a Windows Runtime class. Wine reports
            // this; Unity never mentions WinRT, it only reports the plugin that
            // failed as a result — so the two halves come from two logs.
            if l.contains("rogetactivationfactory"),
               let cls = Self.firstMatch(#"L\"([A-Za-z0-9_.]+)\""#, in: String(line)) {
                found.append(.winrtClassUnavailable(cls))
            }
            // DXVK announces this itself, and it is decisive: 2.x and 3.x
            // require Vulkan 1.3 that MoltenVK does not fully implement, so
            // they never get an adapter. Without this the log read as
            // "nothing obviously wrong" while the game had no graphics at all.
            if l.contains("failed to initialize dxvk")
                || (l.contains("no adapters found") && l.contains("dxvk"))
                || l.contains("vulkan 1.3 capable setup is required") {
                found.append(.dxvkNeedsNewerVulkan)
            }
            // Checked before the module rules below: when Wine refuses the
            // executable itself, everything after it in the log is a
            // consequence, and the module lines are the noise.
            //
            // "failed to open descriptor file" is Unreal's, matched further
            // down, and means something entirely different.
            if (l.contains("failed to open") && !l.contains("descriptor file"))
                || (l.contains("wine:") && l.contains("cannot find")) {
                let exe = Self.firstMatch(#"[\"“]([^\"”]+)[\"”]"#, in: line)
                    ?? Self.firstMatch(#"([A-Za-z]:\\[^\s\"]+)"#, in: line)
                    ?? "the game"
                let status = Self.firstMatch(#"\b(c0[0-9a-fA-F]{6})\b"#, in: line)?.lowercased()
                found.append(.executableWouldNotStart(exe: exe, status: status))
            }
            if l.contains("err:module:") || l.contains("failed to load") {
                // Checked before the generic DLL case: an api-ms-win-* name is
                // a Windows API set, and calling it a missing DLL sent people
                // off to install Visual C++ runtimes that were never involved.
                if let apiSet = Self.apiSetImport(in: line) {
                    found.append(.missingAPISet(apiSet))
                } else if let dll = Self.firstMatch(#"([A-Za-z0-9_\-\.]+\.dll)"#, in: line) {
                    found.append(.missingDLL(dll))
                } else if let m = Self.firstMatch(#"L\"([^\"]+)\""#, in: line) {
                    found.append(.moduleNotFound(m))
                }
            }
            // Unity 6 treats a failed fence creation as fatal. It is a renderer
            // gap, unrelated to the API-set case above, and both used to reach
            // the user as the same "Failed to load il2cpp".
            if l.contains("id3d11fence") || (l.contains("fence") && l.contains("createfence"))
                || (l.contains("fence") && l.contains("e_notimpl")) {
                found.append(.d3d11FenceUnsupported)
            }
            if l.contains("vulkan") && (l.contains("no device") || l.contains("failed")
                                        || l.contains("not available") || l.contains("cannot")) {
                found.append(.vulkanUnavailable)
            }
            if l.contains("d3dmetal") && (l.contains("not found") || l.contains("dyld")) {
                found.append(.d3dMetalUnavailable)
            }
            // "Wine cannot find the FreeType font library" also begins with
            // "wine cannot find", and matching that as an architecture refusal
            // told a 64-bit game to go looking for 32-bit support. The two
            // messages mean entirely different things, so they are matched
            // separately and neither is inferred from the other.
            if l.contains("freetype") {
                found.append(.fontLibraryMissing)
            } else if l.contains("bad exe format")
                || l.contains("not a valid win32 application")
                || l.contains("wine cannot find the 32-bit")
                || l.contains("unsupported architecture") {
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

    /// What an NT status means in the words somebody can act on, and what to
    /// do about it.
    ///
    /// Only the codes Wine actually emits when it refuses an executable. An
    /// unrecognised code returns nil and the finding stays honest about not
    /// knowing, rather than guessing at a fix.
    static func statusMeaning(_ code: String?) -> (what: String, fix: String)? {
        switch code {
        case "c0000135":
            ("something it needs to run is missing",
             "A library the game loads at startup is not in its Windows environment. If the game shipped with dependencies beside the .exe, check they are still there; otherwise add the matching component under How this game is set up.")
        case "c0000139":
            ("a library it loads is the wrong version",
             "A library is present but does not have the function the game asks of it — usually a Wine builtin standing in for something the game shipped. Try adding the real component under How this game is set up.")
        case "c0000142":
            ("a library failed while starting up",
             "Something loaded and then failed to initialise. Rebuilding this game's Windows environment clears a half-installed component, and takes about half a second.")
        case "c000007b":
            ("it and something beside it are built for different architectures",
             "A 32-bit library next to a 64-bit game, or the reverse. If you copied files in from somewhere, that is where to look.")
        case "c0000034":
            ("the file is not where Decanter last saw it",
             "The game's files have moved, been renamed, or been deleted. Re-inspect the game, or remove and re-add it from its new location.")
        case "c0000022":
            ("Decanter was not allowed to read it",
             "macOS refused access to the game's files. If they are on an external disk or in a protected folder, granting Decanter access there is the fix.")
        default:
            nil
        }
    }

    /// api-ms-win-* names are Windows API sets, not ordinary DLLs. A game
    /// failing on one is a Wine coverage gap; reporting it as a generic
    /// missing DLL sent people to reinstall runtimes that were never involved.
    static func apiSetImport(in log: String) -> String? {
        // The capture group is required: firstMatch returns group 1, and a
        // pattern without one silently matches nothing.
        firstMatch(#"(api-ms-win-[A-Za-z0-9\-]+\.dll)"#, in: log)
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
