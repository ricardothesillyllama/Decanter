import Foundation
import DecanterKit

func runUnitTests(_ t: Harness) {
    let det = Detector()

    t.suite("PE parsing")
    do {
        let d = Fixture.dir("pe")
        t.equal(PEReader.read(Fixture.write(d, "a.exe", Fixture.pe(machine: 0x8664)))?.bitness, .x64,
                "reads a 64-bit machine field")
        t.equal(PEReader.read(Fixture.write(d, "b.exe", Fixture.pe(machine: 0x014c)))?.bitness, .x86,
                "reads a 32-bit machine field")
        t.expect(PEReader.read(Fixture.write(d, "c.exe", Data("plainly not a PE".utf8))) == nil,
                 "a text file renamed .exe does not parse as PE")
        var trunc = Data(count: 0x40); trunc[0] = 0x4D; trunc[1] = 0x5A
        withUnsafeBytes(of: UInt32(0x4000).littleEndian) { for (i, b) in $0.enumerated() { trunc[0x3c + i] = b } }
        t.expect(PEReader.read(Fixture.write(d, "t.exe", trunc)) == nil,
                 "a truncated PE is rejected rather than crashing")
        t.expect(PEReader.read(Fixture.write(d, "e.exe", Data()))  == nil, "an empty file is rejected")
        let imports = PEReader.read(Fixture.write(d, "g.exe",
                        Fixture.pe(machine: 0x8664, strings: ["d3d11.dll", "dxgi.dll"])))?.importedDLLs ?? []
        t.expect(imports.contains("d3d11.dll") && imports.contains("dxgi.dll"),
                 "finds referenced graphics DLLs")
    }

    t.suite("Engine detection")
    do {
        let unity = det.detect(exe: Fixture.unity().appending(path: "TestGame.exe"))
        t.equal(unity.engine, .unityIL2CPP, "identifies Unity IL2CPP")
        t.equal(unity.bitness, .x64, "identifies 64-bit")
        t.expect(unity.confidence > 0.6, "confidence above 0.6 for a clear match")

        // Updated after measuring on Apple Silicon: DXVK on MoltenVK cannot
        // reach D3D feature level 11_1, which modern Unity demands, so the
        // earlier "prefer DXVK" expectation was simply wrong here.
        t.expect(unity.graphicsAPIs.contains("d3d12.dll"), "precondition: d3d12 is referenced")
        t.equal(unity.recommendedBackend, .d3dmetal, "modern 64-bit Unity defaults to D3DMetal")
        t.equal(unity.recommendedRuntimeKind, .gptk, "...which means the GPTK runtime")

        let ue = det.detect(exe: Fixture.unreal().appending(path: "Shipping.exe"))
        t.equal(ue.engine, .unreal, "identifies Unreal")
        t.equal(ue.recommendedRuntimeKind, .gptk, "a non-Unity d3d12 engine does prefer GPTK")
        t.equal(ue.recommendedBackend, .d3dmetal, "...with D3DMetal")

        let ue32 = det.detect(exe: Fixture.unreal(machine: 0x014c).appending(path: "Shipping.exe"))
        t.equal(ue32.bitness, .x86, "32-bit Unreal detected as 32-bit")
        t.equal(ue32.recommendedRuntimeKind, .wine, "32-bit overrides the GPTK preference")

        let warm = det.detect(exe: Fixture.unity(warmCache: true).appending(path: "TestGame.exe"))
        t.expect(warm.hasWarmDXVKCache, "spots a warm .dxvk-cache")
        // A warm cache is noted but no longer decisive: it usually comes from
        // an older CrossOver-based bottle, and cannot override the fact that
        // DXVK has no feature level 11_1 here.
        t.equal(warm.recommendedBackend, .d3dmetal, "a warm DXVK cache no longer overrides feature-level reality")

        t.expect(det.detect(exe: Fixture.unity(modded: true).appending(path: "TestGame.exe")).modded,
                 "spots a Doorstop/BepInEx mod loader")

        let renpy = det.detect(exe: Fixture.renpy().appending(path: "VN.exe"))
        t.equal(renpy.engine, .renpy, "identifies Ren'Py")
        t.equal(renpy.recommendedBackend, .wined3d, "2D engines prefer WineD3D")

        let rpgm = det.detect(exe: Fixture.rpgMaker().appending(path: "Game.exe"))
        t.equal(rpgm.engine, .rpgMakerNW, "identifies RPG Maker / nw.js")
        t.equal(det.detect(exe: Fixture.godot().appending(path: "Game.exe")).engine, .godot,
                "identifies Godot")
    }

    t.suite("Executable picking")
    do {
        t.equal(det.findExecutable(in: Fixture.noisy())?.lastPathComponent, "RealGame.exe",
                "prefers the game over a larger crash handler, uninstaller and redist")
        t.expect(det.findExecutable(in: Fixture.dir("empty")) == nil,
                 "an empty folder yields no executable")
    }

    t.suite("Video decides the backend")
    do {
        // A game that plays video must not be put on D3DMetal, which has no
        // ID3D11Multithread and therefore cannot drive Unity's video player.
        let d = Fixture.unity(name: "Movie")
        Fixture.write(d, "Movie_Data/StreamingAssets/intro.mp4", Data("fake".utf8))
        let r = det.detect(exe: d.appending(path: "Movie.exe"))
        t.expect(r.usesVideo, "detects that the game ships video")
        t.equal(r.recommendedBackend, .wined3d, "a video game is routed to WineD3D, not D3DMetal")
    }

    t.suite("Unreal packaged layout")
    do {
        let root = Fixture.unrealPackaged()
        // Pointed at the packaged root.
        t.equal(det.findExecutable(in: root)?.lastPathComponent, "Start Sample Game.exe",
                "picks the launcher next to Engine/, not the far larger inner binary")
        // Pointed at the inner game folder, which is what people actually do.
        let inner = root.appending(path: "SampleGame")
        t.equal(det.findExecutable(in: inner)?.lastPathComponent, "Start Sample Game.exe",
                "walks up from the inner folder to find the launcher")
        // And pointed straight at Binaries/Win64.
        let win64 = root.appending(path: "SampleGame/Binaries/Win64")
        t.equal(det.findExecutable(in: win64)?.lastPathComponent, "Start Sample Game.exe",
                "even from Binaries/Win64 it resolves to the launcher")

        let r = det.detect(exe: root.appending(path: "Start Sample Game.exe"))
        t.equal(r.engine, .unreal, "identified as Unreal")
        t.expect(r.graphicsAPIs.contains("d3d11.dll"),
                 "graphics APIs read from the inner binary, not the stub launcher")
        t.equal(r.recommendedBackend, .d3dmetal, "Unreal with d3d12 prefers D3DMetal")
    }

    t.suite("Registry conversion")
    do {
        let conv = WineRegConverter()
        let wineFormat = """
        WINE REGISTRY Version 2

        [Software\\\\ExampleVendor\\\\SampleGame] 1771908086
        #time=1dca547d627de08
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000003

        [Software\\\\ExampleVendor\\\\Sample\\x6e2c\\x8a66] 1771906704
        "unity.player_session_count_h922449978"=hex:31,30,34,00
        """
        t.expect(WineRegConverter.isWineInternal(wineFormat), "recognises Wine's internal format")
        let r = conv.convert(wineFormat)
        t.equal(r.keyCount, 2, "converts both keys")
        t.expect(r.text.hasPrefix("Windows Registry Editor Version 5.00"),
                 "emits the header regedit actually requires")
        t.expect(r.text.contains(#"[HKEY_CURRENT_USER\Software\ExampleVendor\SampleGame]"#),
                 "prefixes the hive and unescapes double backslashes")
        t.expect(r.text.contains("Sample測試"),
                 "decodes \\x escapes into real characters (Sample測試)")
        t.expect(!r.text.contains("#time="), "drops Wine's metadata lines")
        t.expect(r.text.contains("dword:00000003"), "preserves dword values")
        t.expect(conv.convert("[Software\\\\X] 1\n", hive: "HKEY_LOCAL_MACHINE")
                    .text.contains("[HKEY_LOCAL_MACHINE\\Software\\X]"),
                 "honours the requested hive for system.reg fragments")
        t.expect(WineRegConverter.decodeHexEscapes("Sample\\x6e2c\\x8a66") == "Sample測試",
                 "hex escape decoder round-trips")
    }

    t.suite("Scoped path mapping")
    do {
        let paths = Paths(root: Fixture.dir("paths"))
        let l = Launcher(paths: paths)
        let gameDir = URL(filePath: "/Users/x/Games/Cool Game")
        let scopes = [ScopeGrant(letter: "h", hostPath: gameDir),
                      ScopeGrant(letter: "g", hostPath: URL(filePath: "/Users/x/Games"), readOnly: true)]

        t.equal(try? l.windowsPath(for: gameDir.appending(path: "game.exe"), scopes: scopes),
                #"H:\game.exe"#, "maps an exe to its DOS path")
        t.equal(try? l.windowsPath(for: gameDir.appending(path: "bin/sub/game.exe"), scopes: scopes),
                #"H:\bin\sub\game.exe"#, "converts separators for nested paths")
        // The longest matching grant must win, else a broad grant shadows a narrow one.
        t.equal(try? l.windowsPath(for: gameDir.appending(path: "game.exe"), scopes: scopes.reversed()),
                #"H:\game.exe"#, "the most specific grant wins regardless of order")
        t.throwsError("a path outside every grant is refused") {
            _ = try l.windowsPath(for: URL(filePath: "/Users/x/Documents/secret.exe"), scopes: scopes)
        }
        t.throwsError("a sibling path that merely shares a prefix is refused") {
            _ = try l.windowsPath(for: URL(filePath: "/Users/x/Games/Cool Game Evil/x.exe"),
                                  scopes: [ScopeGrant(letter: "h", hostPath: gameDir)])
        }
    }

    t.suite("Failure diagnosis")
    do {
        let d = Diagnostics()
        t.expect(d.analyse(text: "err:module:import_dll Library d3dcompiler_47.dll not found")
                    .findings.contains { if case .missingDLL = $0 { return true }; return false },
                 "classifies a missing DLL")
        t.expect(d.analyse(text: "MoltenVK: vulkan no device available")
                    .findings.contains(.vulkanUnavailable), "classifies Vulkan being unavailable")
        t.expect(d.analyse(text: "wine: Bad EXE format for Z:\\game.exe")
                    .findings.contains(.bitnessRefused), "classifies an architecture refusal")
        t.expect(d.analyse(text: "open /Users/x/Documents/a: Operation not permitted")
                    .findings.contains { if case .scopeDenied = $0 { return true }; return false },
                 "classifies a blocked folder access")
        t.expect(d.analyse(text: "hello world, nothing wrong here").isEmpty,
                 "a clean log produces no findings")
        let dupes = d.analyse(text: Array(repeating: "MoltenVK: vulkan failed", count: 50).joined(separator: "\n"))
        t.equal(dupes.findings.count, 1, "repeated identical errors are de-duplicated")
        t.expect(!Diagnostics().analyse(text: "d3d11 swapchain created")
                    .findings.isEmpty == false, "graphics chatter alone is not a failure")

        // The failure that reported "nothing wrong found" under a green tick.
        // Wine's most ordinary refusal, and there was no rule for it.
        func started(_ log: String) -> (exe: String, status: String?)? {
            for f in d.analyse(text: log).findings {
                if case .executableWouldNotStart(let e, let st) = f { return (e, st) }
            }
            return nil
        }
        let dllMissing = #"wine: failed to open "H:\a.exe": c0000135"#
        t.expect(started(dllMissing) != nil, "a log Wine could not open the game from is a finding")
        t.equal(started(dllMissing)?.status, "c0000135", "the NT status is captured")
        t.equal(started(dllMissing)?.exe, #"H:\a.exe"#, "so is the executable it refused")
        t.expect(d.analyse(text: dllMissing).findings.first?.summary
                    .contains("something it needs to run is missing") == true,
                 "c0000135 is decoded into words rather than repeated as hex")
        t.expect(started(#"wine: failed to open "H:\g.exe": c000007b"#) != nil,
                 "an architecture mismatch on startup is caught")
        t.expect(d.analyse(text: #"wine: failed to open "H:\g.exe": c000007b"#).findings.first?
                    .summary.contains("different architectures") == true,
                 "and decoded to the architecture wording, not the DLL one")
        t.expect(started(#"wine: cannot find L"H:\gone.exe""#) != nil,
                 "Wine not finding the executable at all is caught")
        t.equal(started(#"wine: failed to open "H:\a.exe": c0ffee11"#)?.status, "c0ffee11",
                "an unrecognised status is kept")
        t.equal(d.analyse(text: #"wine: failed to open "H:\\a.exe": c0ffee11"#).findings.first?.summary,
                #"Windows would not start H:\\a.exe"#,
                "and produces no invented explanation for it")
        t.expect(d.analyse(text: #"wine: failed to open "H:\\a.exe": c0ffee11"#).findings.first?
                    .suggestion.contains("still where Decanter found them") == true,
                 "falling back to the one suggestion true regardless of the code")
        // Unreal's descriptor-file line means something else entirely and is
        // matched further down; it must not be swallowed by this rule.
        t.expect(d.analyse(text: "LogInit: Failed to open descriptor file '../../Game.uproject'")
                    .findings.contains { if case .unrealWrongExecutable = $0 { return true }; return false },
                 "Unreal's descriptor-file failure is still its own finding")
        t.expect(started("LogInit: Failed to open descriptor file '../../Game.uproject'") == nil,
                 "and is not also reported as a refused executable")
    }
}

/// Guards the video heuristic, which was briefly wrong in a way that would have
/// mislabelled every Unity game and pushed them all onto the slower backend.
func runVideoDetectionTests(_ t: Harness) {
    let det = Detector()

    t.suite("Video detection uses real evidence")
    do {
        // A stock Unity game with no video assets. UnityPlayer.dll always
        // contains "WindowsVideoMedia" — that must NOT count as video.
        let plain = Fixture.unity(name: "Plain")
        Fixture.write(plain, "UnityPlayer.dll",
                      Fixture.pe(machine: 0x8664, strings: ["d3d11.dll", "WindowsVideoMedia"]))
        let r1 = det.detect(exe: plain.appending(path: "Plain.exe"))
        t.expect(!r1.usesVideo, "a Unity game with no video assets is not marked as video")
        t.equal(r1.recommendedBackend, .d3dmetal, "…so it keeps the fast backend")

        // A game that actually ships a video file.
        let movie = Fixture.unity(name: "Movie")
        Fixture.write(movie, "Movie_Data/StreamingAssets/intro.mp4", Data("x".utf8))
        let r2 = det.detect(exe: movie.appending(path: "Movie.exe"))
        t.expect(r2.usesVideo, "a real video asset is detected")
        t.equal(r2.recommendedBackend, .wined3d, "…and routes to the backend that can play it")

        // Video packed inside archives is only provable from the engine's log.
        t.expect(Detector.playerLogShowsVideo("[PlayVideo] Title - BG"),
                 "the engine log settles it when assets are packed")
        t.expect(!Detector.playerLogShowsVideo("Initialize engine version: 2022.3.37f1"),
                 "an ordinary log line is not treated as video")
    }
}

/// The executable picker: a game folder holds more than one .exe, and the
/// automatic choice has to be overridable and correctly labelled.
func runExecutablePickerTests(_ t: Harness) {
    let det = Detector()

    t.suite("Listing executables for the user to choose")
    do {
        let d = Fixture.unity(name: "RealGame")
        Fixture.write(d, "unins000.exe", Fixture.pe(machine: 0x8664, padTo: 2_000_000))
        Fixture.write(d, "Config.exe", Fixture.pe(machine: 0x8664, padTo: 300_000))
        Fixture.write(d, "Extras/Redist/vcredist_x64.exe", Fixture.pe(machine: 0x8664, padTo: 5_000_000))

        let list = det.listExecutables(in: d)
        t.expect(list.count >= 4, "finds every executable, not just the likely one")
        t.equal(list.first?.url.lastPathComponent, "RealGame.exe",
                "the likely game is offered first")
        t.expect(list.first?.isLikelyGame == true, "…and is marked as the automatic pick")

        func note(_ name: String) -> String? {
            list.first { $0.url.lastPathComponent == name }?.note
        }
        t.expect(note("unins000.exe")?.contains("uninstall") == true, "the uninstaller is labelled")
        t.expect(note("Config.exe")?.contains("configuration") == true, "the config tool is labelled")
        t.expect(note("vcredist_x64.exe")?.contains("prerequisite") == true,
                 "a prerequisite installer is labelled and suggested")
        t.expect(list.allSatisfy { !$0.relativePath.hasPrefix("/") },
                 "paths are shown relative to the game folder")
    }

    t.suite("Unreal packages list from the package root")
    do {
        let root = Fixture.unrealPackaged()
        // Listing from the inner folder should still show the whole package.
        let list = det.listExecutables(in: root.appending(path: "SampleGame/Binaries/Win64"))
        t.expect(list.contains { $0.url.lastPathComponent == "Start Sample Game.exe" },
                 "the launcher is offered even when pointed at Binaries/Win64")
        t.expect(list.first { $0.url.path.contains("/Binaries/Win") }?.note?.contains("inner binary") == true,
                 "the inner binary is labelled as the wrong thing to launch")
    }
}
