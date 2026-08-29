import Foundation
import DecanterKit

/// The bench decides what a Wine build is allowed to be asked to do, so a
/// wrong answer here becomes a game that is offered a graphics option nothing
/// can provide — the exact failure 0.5.5 was written for. Every rule below was
/// wrong at some point during the writing of it.
func runBenchTests(_ t: Harness) {
    let fm = FileManager.default
    let tmp = URL(filePath: NSTemporaryDirectory())
        .appending(path: "decanter-bench-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    let root = tmp.appending(path: "runtime")
    let unix = root.appending(path: "lib/wine/x86_64-unix")
    try? fm.createDirectory(at: unix, withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appending(path: "lib/external"), withIntermediateDirectories: true)
    func touch(_ rel: String) {
        let u = root.appending(path: rel)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: u.path, contents: Data("x".utf8))
    }

    t.suite("the Mach-O reader reads real binaries")
    // A real system binary rather than a fixture: a hand-built Mach-O would
    // only prove the reader agrees with the writer.
    if let img = MachO.read(at: URL(filePath: "/bin/ls")) {
        t.expect(img.dependencies.contains { $0.path.contains("libSystem") },
                 "/bin/ls is seen to link libSystem")
        t.expect(img.dependencies.allSatisfy { !$0.path.isEmpty },
                 "no dependency comes back as an empty string")
    } else {
        t.expect(false, "/bin/ls parses as Mach-O")
    }
    let notMachO = tmp.appending(path: "plain.txt")
    try? "not a binary".write(to: notMachO, atomically: true, encoding: .utf8)
    t.equal(MachO.read(at: notMachO) == nil, true, "a text file is not mistaken for a binary")
    t.equal(MachO.read(at: tmp.appending(path: "does-not-exist")) == nil, true,
            "a missing file returns nothing rather than throwing")

    t.suite("dyld's search is modelled, not guessed at")
    // The system libraries have no files behind them since Big Sur — they live
    // only in the dyld shared cache. Checking the filesystem for them would
    // report every binary in every build as broken.
    t.equal(RuntimeAudit.resolves("/usr/lib/libSystem.B.dylib", loaderDir: unix,
                                  rpaths: [], root: root), true,
            "a system library is present even though no file exists")
    t.equal(RuntimeAudit.resolves("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                                  loaderDir: unix, rpaths: [], root: root), true,
            "so is a system framework")
    t.equal(RuntimeAudit.resolves("/opt/local/lib/libSDL2.dylib", loaderDir: unix,
                                  rpaths: [], root: root), false,
            "an absolute path outside the system is checked for real")

    touch("lib/wine/x86_64-unix/ntdll.so")
    t.equal(RuntimeAudit.resolves("@loader_path/ntdll.so", loaderDir: unix, rpaths: [], root: root), true,
            "@loader_path finds a sibling")
    t.equal(RuntimeAudit.resolves("@loader_path/absent.so", loaderDir: unix, rpaths: [], root: root), false,
            "@loader_path reports a sibling that is not there")

    // The Game Porting Toolkit reaches its bundled GStreamer this way, and
    // failing to walk the traversal reported six libraries missing that were
    // sitting on disk.
    touch("lib/Bundled.framework/Libraries/libgstreamer-1.0.0.dylib")
    t.equal(RuntimeAudit.resolves("@rpath/libgstreamer-1.0.0.dylib", loaderDir: unix,
                                  rpaths: ["@loader_path/../../Bundled.framework/Libraries"], root: root), true,
            "an rpath with ../.. traversal resolves")
    t.equal(RuntimeAudit.resolves("@rpath/libabsent.dylib", loaderDir: unix,
                                  rpaths: ["@loader_path/../../Bundled.framework/Libraries"], root: root), false,
            "and still reports what that directory does not hold")

    // dyld does not give up when every LC_RPATH misses — it searches
    // DYLD_FALLBACK_LIBRARY_PATH by leaf name, which Decanter sets itself.
    touch("lib/libfallback.1.dylib")
    t.equal(RuntimeAudit.resolves("@rpath/libfallback.1.dylib", loaderDir: unix,
                                  rpaths: ["@loader_path/nowhere"], root: root), true,
            "an @rpath miss falls back to the runtime's own lib directory")
    t.equal(RuntimeAudit.resolves("libfallback.1.dylib", loaderDir: unix, rpaths: [], root: root), true,
            "so does a bare library name")
    t.expect(RuntimeAudit.fallbackDirectories(root: root).contains(root.appending(path: "lib").path),
             "the fallback directories are the ones the launcher actually sets")

    t.suite("a gap is attributed to the right side of the build")
    t.equal(RuntimeAudit.isThirtyTwoBitPath("lib/wine/x86_32on64-unix/winegstreamer.so"), true,
            "the Game Porting Toolkit's 32-on-64 directory is the 32-bit side")
    t.equal(RuntimeAudit.isThirtyTwoBitPath("lib/wine/i386-windows/d3d11.dll"), true,
            "so is i386-windows")
    t.equal(RuntimeAudit.isThirtyTwoBitPath("lib/wine/x86_64-unix/winegstreamer.so"), false,
            "and the 64-bit directory is not")
    t.equal(RuntimeAudit.isThirtyTwoBitPath("lib/libintl.8.dylib"), false,
            "a shared library belongs to neither side")

    t.suite("a consequence is read from who needs the library, never its name")
    // The bug this replaces: the same library means different things depending
    // on who wanted it. libbz2 absent from the video decoder announced that
    // text would not draw, because the font library also happens to use bz2.
    var video = RuntimeAudit.Report()
    video.scannedFiles = 10
    video.gaps = [.init(library: "@rpath/libbz2.1.dylib",
                        neededBy: ["lib/libavformat.61.dylib"], isWeak: false)]
    t.expect(video.consequences.contains { $0.contains("Video") },
             "libbz2 missing from the video decoder is a video problem")
    t.expect(!video.consequences.contains { $0.contains("Text") },
             "and is not reported as a font problem")

    var fonts = RuntimeAudit.Report()
    fonts.scannedFiles = 10
    fonts.gaps = [.init(library: "@loader_path/libbz2.1.0.dylib",
                        neededBy: ["lib/libfreetype.6.dylib"], isWeak: false)]
    t.expect(fonts.consequences.contains { $0.contains("Text") },
             "the same library missing from the font library is a font problem")

    var narrow = RuntimeAudit.Report()
    narrow.scannedFiles = 10
    narrow.gaps = [.init(library: "@rpath/libgstreamer-1.0.0.dylib",
                         neededBy: ["lib/wine/x86_32on64-unix/winegstreamer.so"],
                         isWeak: false, thirtyTwoBitOnly: true)]
    t.expect(narrow.consequences.contains { $0.contains("32-bit games only") },
             "a gap only the 32-bit side has says so rather than condemning the build")

    var weakOnly = RuntimeAudit.Report()
    weakOnly.scannedFiles = 10
    weakOnly.gaps = [.init(library: "@rpath/libopt.dylib", neededBy: ["lib/x.dylib"], isWeak: true)]
    t.expect(weakOnly.isSound, "a build is not called broken for an optional library it was built to live without")
    t.equal(weakOnly.consequences.isEmpty, true, "and no consequence is claimed for one")

    t.suite("the bench measures a build rather than trusting its record")
    let paths = Paths(root: tmp.appending(path: "store"))
    let bench = Bench(paths: paths)
    touch("bin/wine")
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "bin/wine").path)
    let spec = RuntimeSpec(id: "test-1.0", kind: .wine, version: "1.0", root: root,
                           winePath: root.appending(path: "bin/wine"),
                           wineserverPath: nil, supports32Bit: false, backends: [])
    var row = bench.measure(spec, auditing: false)
    t.expect(row.finding(.wined3d)?.provided == true,
             "WineD3D is provided wherever Wine itself runs")
    t.expect(row.finding(.dxvk)?.provided == false,
             "DXVK is refused when the build carries no MoltenVK")
    t.expect(row.finding(.dxvk)?.detail.contains("winevulkan") == true,
             "and the reasoning, when asked for, says why winevulkan being present is not evidence")
    t.expect(row.finding(.d3dmetal)?.provided == false,
             "D3DMetal is refused outside the Game Porting Toolkit")
    t.expect(row.finding(.d3dmetal)?.reason.contains("cannot be copied") == true,
             "and says plainly that it cannot simply be copied in")
    t.expect(row.finding(.d3dmetal)?.detail.contains("licence") == true,
             "with the licence as the reason underneath")
    t.expect(row.finding(.dxmt)?.provided == false,
             "DXMT is refused without a driver that can host it")
    t.expect(row.findings.allSatisfy { $0.provided || !$0.reason.isEmpty },
             "every refusal carries a reason")

    touch("lib/libMoltenVK.dylib")
    row = bench.measure(spec, auditing: false)
    t.expect(row.finding(.dxvk)?.provided == true,
             "adding MoltenVK to the build changes the answer — the point of measuring again")
    t.expect(row.finding(.dxvk)?.evidence.first?.contains("libMoltenVK") == true,
             "and the evidence names the file that decided it")
    t.equal(row.backends, row.backends.inPreferenceOrder,
            "the backends a build offers come out in one order")

    t.suite("the plain answer stays plain")
    // The rule this enforces came from the person who wrote the project not
    // being able to read his own tool's output. Every finding has two
    // registers: an answer anyone can act on, and the reasoning behind it.
    // Nothing from the second register may leak into the first — a check
    // rather than an intention, because good intentions do not survive a
    // paragraph written at the moment the reasoning was fresh.
    let banned = ["mach-o", "dylib", "@rpath", "@loader_path", "dlopen", "lc_load",
                  "macdrv", "symbol", ".so", "moltenvk", "winevulkan", "vk_khr",
                  "mh_bundle", "libfreetype", "libgst", "stderr", "null"]
    func plainStrings(of r: Bench.RuntimeRow) -> [(String, String)] {
        r.findings.map { ("\($0.backend.label) answer", $0.reason) }
    }
    // Measured across builds that answer differently, so every branch of every
    // reason is covered rather than whichever one this machine happens to hit.
    var checked = 0
    var offenders: [String] = []
    for probe in [root, root.appending(path: "nonexistent")] {
        let s = RuntimeSpec(id: "probe", kind: .wine, version: "1.0", root: probe,
                            winePath: probe.appending(path: "bin/wine"),
                            wineserverPath: nil, supports32Bit: false, backends: [])
        var strings = plainStrings(of: bench.measure(s, auditing: false))
        strings.append(("headline", RuntimeAudit.Report().headline))
        for (label, text) in strings {
            checked += 1
            let low = text.lowercased()
            if let hit = banned.first(where: { low.contains($0) }) {
                offenders.append("\(label) contains \u{201c}\(hit)\u{201d}")
            }
        }
    }
    t.expect(checked >= 8, "every backend's plain answer was examined on more than one build")
    t.expect(offenders.isEmpty,
             "no plain answer leaks a file format, a symbol name or a library name"
             + (offenders.isEmpty ? "" : " \u{2014} " + offenders.joined(separator: "; ")))

    // The same rule for the one sentence that explains a Metal refusal, which
    // is where the worst of it was: three sentences of Mach-O terminology.
    for probe in [root, root.appending(path: "nonexistent")] {
        let summary = (RuntimeManager.metalHosting(root: probe).unavailableSummary ?? "").lowercased()
        t.expect(!banned.contains { summary.contains($0) },
                 "the Metal refusal for \(probe.lastPathComponent) is readable without a glossary")
        t.expect(summary.isEmpty || summary.count < 200,
                 "and is short enough to be read")
    }
    // The detail must still be there, and must be a different, fuller text —
    // the point of two registers is that neither replaces the other.
    let hosting = RuntimeManager.metalHosting(root: root)
    t.expect(hosting.unavailableReason != nil && hosting.unavailableSummary != nil,
             "a build that cannot host Metal has both an answer and a reason")
    t.expect((hosting.unavailableReason?.count ?? 0) > (hosting.unavailableSummary?.count ?? 0),
             "and the reasoning underneath is the fuller of the two")

    t.suite("one vocabulary, wherever it is read")
    t.equal(GraphicsBackend.dxmt.plainName, "Metal", "DXMT is Metal graphics")
    t.equal(GraphicsBackend.dxvk.plainName, "Vulkan", "DXVK is Vulkan graphics")
    t.equal(GraphicsBackend.d3dmetal.plainName, "Apple", "D3DMetal is Apple graphics")
    t.equal(GraphicsBackend.wined3d.plainName, "Wine", "WineD3D is Wine graphics")
    t.expect(GraphicsBackend.allCases.allSatisfy { !$0.plainName.isEmpty && $0.plainName != $0.label },
             "every backend has a plain name that is not just its real one")

    t.suite("a measurement knows when it has gone stale")
    let before = row.fingerprint
    t.expect(!before.isEmpty, "a measured row carries a fingerprint of the build")
    t.equal(bench.isStale(row, runtime: spec), false, "a fresh measurement is not stale")
    // Changing the Wine binary is what happens when a build is repaired or
    // replaced under a runtime Decanter has already measured.
    try? Data("changed and longer".utf8).write(to: root.appending(path: "bin/wine"))
    t.expect(bench.isStale(row, runtime: spec),
             "replacing the Wine binary makes the old measurement stale")
    var old = row
    old.measuredBy = "0.0.1"
    t.expect(bench.isStale(old, runtime: spec),
             "so does a row taken by a Decanter that asked a weaker question")

    t.suite("the bench writes back what it learns")
    try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    if let store = try? Store(paths: paths) {
        try? store.mutate { $0.runtimes = [spec] }
        var table = Bench.Table()
        table.rows = [bench.measure(spec, auditing: false)]
        let changes = (try? bench.reconcile(store: store, table: table)) ?? []
        t.expect(changes.contains { $0.contains("gained") },
                 "a runtime recorded with no backends is corrected, and the change is reported")
        t.expect(store.state.runtimes.first?.backends.contains(.dxvk) == true,
                 "and the record now says what was measured")
        let again = (try? bench.reconcile(store: store, table: table)) ?? ["something"]
        t.equal(again.isEmpty, true, "running it twice reports no second change")
    } else {
        t.skip("reconcile writes back", "no store")
    }
}
