import Foundation
import DecanterKit

/// A prefix cloned from a template built before version markers existed carries
/// no `.decanter-dxvk` file, and used to report a bare "DXVK ?" in every
/// problem report — the one line you most want exact when rendering is broken.
func runDXVKTests(_ t: Harness) {
    t.suite("DXVK version identification")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "decanter-dxvk-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let paths = Paths(root: root)
    try? paths.ensure()

    // Two staged builds with genuinely different bytes, plus one that differs
    // only in length — size alone must not be treated as identification.
    func stage(_ version: String, _ body: Data) {
        let d = paths.runtimes.appending(path: "dxvk/\(version)/x64")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        try? body.write(to: d.appending(path: "d3d11.dll"))
    }
    let a = Data(repeating: 0xA1, count: 4096)
    let b = Data(repeating: 0xB2, count: 4096)      // same size, different bytes
    let c = Data(repeating: 0xA1, count: 8192)      // same byte, different size
    stage("1.10.3", a); stage("2.4", b); stage("3.0.2", c)

    let inst = DXVKInstaller(paths: paths)
    t.equal(Set(inst.stagedVersions()), ["1.10.3", "2.4", "3.0.2"], "all staged builds are found")

    func prefix(with dll: Data?, marker: String? = nil) -> URL {
        let p = root.appending(path: "pfx-\(UUID().uuidString)")
        let sys = p.appending(path: "drive_c/windows/system32")
        try? fm.createDirectory(at: sys, withIntermediateDirectories: true)
        if let dll { try? dll.write(to: sys.appending(path: "d3d11.dll")) }
        if let marker { try? marker.write(to: p.appending(path: ".decanter-dxvk"),
                                          atomically: true, encoding: .utf8) }
        return p
    }

    t.equal(inst.installedVersion(in: prefix(with: a)), "1.10.3",
            "an unmarked prefix is identified by the bytes of its d3d11.dll")
    t.equal(inst.installedVersion(in: prefix(with: b)), "2.4",
            "a same-sized but different build is told apart")
    t.equal(inst.installedVersion(in: prefix(with: c)), "3.0.2",
            "a same-byte but different-sized build is told apart")

    // The marker still wins: it records what Decanter actually installed, which
    // survives the staged copy being deleted or replaced.
    t.equal(inst.installedVersion(in: prefix(with: a, marker: "9.9.9")), "9.9.9",
            "an explicit marker outranks content matching")

    t.equal(inst.installedVersion(in: prefix(with: Data(repeating: 0xFF, count: 4096))), nil,
            "a build that matches nothing staged reports nil, not a wrong version")
    t.equal(inst.installedVersion(in: prefix(with: nil)), nil,
            "a prefix with no DXVK at all reports nil")
    t.equal(inst.installedVersion(in: root.appending(path: "does-not-exist")), nil,
            "a missing prefix is nil rather than a crash")
}

/// A mod loader fails in a way nothing else can see: BepInEx prints a healthy
/// banner, then a plugin throws and the game dies. Picking the real failures out
/// of that log is the whole value, so the matching has to be precise.
func runModLogTests(_ t: Harness) {
    t.suite("mod loader failures")

    let log = [
        "[Message:   BepInEx] BepInEx 5.4.22.0 - SampleGame",
        "[Info   :   BepInEx] Loading [ErrorHandler 1.2.0]",          // name contains "Error"
        "[Info   :ConfigMgr] error_reporting = false",                // config key
        "[Error  :   BepInEx] Could not load [BrokenPlugin 1.0.0]",
        "FATAL UNHANDLED EXCEPTION: System.NullReferenceException",
        "  at SplashScreenPatcher+<>c.<CommunicationThread>b__4_1 () in <filename unknown>:0",
        "[Error  :   BepInEx] Could not load [BrokenPlugin 1.0.0]",   // duplicate
    ]
    let f = ModInspector.failures(in: log)

    t.expect(!f.contains { $0.contains("ErrorHandler 1.2.0") },
             "a plugin whose NAME contains 'Error' is not a failure")
    t.expect(!f.contains { $0.contains("error_reporting") },
             "a config key containing 'error' is not a failure")
    t.expect(f.contains { $0.contains("BrokenPlugin") }, "an [Error] line is a failure")
    t.expect(f.contains { $0.contains("FATAL UNHANDLED EXCEPTION") }, "a fatal exception is a failure")
    t.expect(f.contains { $0.contains("at SplashScreenPatcher") },
             "the stack frame is kept — it names the plugin actually at fault")
    t.equal(f.filter { $0.contains("BrokenPlugin") }.count, 1,
            "a repeated failure is reported once, not once per occurrence")
    t.equal(ModInspector.failures(in: []).count, 0, "an empty log yields nothing")
    t.expect(ModInspector.failures(in: ["all fine here"]).isEmpty, "a clean log yields nothing")
}
