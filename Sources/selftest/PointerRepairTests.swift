import Foundation
import CryptoKit
import DecanterKit

/// Unity 6 reads the mouse as a pointer, and one Wine build drops the primary
/// flag on drags. The repair is a byte patch, so these pin what it may touch.
func runPointerRepairTests(_ t: Harness) {
    t.suite("The mouse repair changes only the file it was worked out for")
    let fm = FileManager.default

    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // A stand-in library: filler, with the "before" bytes at each site.
    var original = Data((0..<0x400).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    let sites: [(Int, [UInt8], [UInt8])] = [(0x40, [0xaa, 0xbb, 0xcc], [0x11, 0x22, 0x33]),
                                            (0x200, [0xde, 0xad], [0xbe, 0xef])]
    for (o, old, _) in sites { original.replaceSubrange(o..<o + old.count, with: old) }
    let build = PointerRepair.Build(name: "Fixture Wine", original: sha(original),
                                    patches: sites.map { .init($0.0, hex($0.1), hex($0.2), "site \($0.0)") })
    var signed = 0
    let repair = PointerRepair(builds: [build], sign: { _ in signed += 1 })

    func runtime(_ tag: String, with bytes: Data) -> (root: URL, lib: URL) {
        let root = Fixture.dir("pointer-\(tag)")
        let dir = root.appending(path: "lib/wine/x86_64-unix")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let lib = dir.appending(path: "win32u.so")
        try? bytes.write(to: lib)
        return (root, lib)
    }
    func succeeds(_ what: String, _ body: () throws -> Void) {
        do { try body(); t.expect(true, what) } catch { t.expect(false, "\(what): \(error.localizedDescription)") }
    }
    func read(_ u: URL) -> Data { (try? Data(contentsOf: u)) ?? Data() }

    // Anything else is not offered.
    var other = original; other[0] ^= 0xff
    let stranger = runtime("stranger", with: other)
    if case .notApplicable = repair.state(of: stranger.root) {
        t.expect(true, "a file with any other hash is not offered anything")
    } else { t.expect(false, "a file with any other hash is not offered anything") }
    t.throwsError("and applying to it refuses") { try repair.apply(to: stranger.root) }
    t.equal(sha(read(stranger.lib)), sha(other), "and leaves it byte for byte as it was")

    // The known build: offered, applied, read back, undone.
    let known = runtime("known", with: original)
    if case .flawed(_, let source) = repair.state(of: known.root) {
        t.equal(source.lastPathComponent, "win32u.so", "the known build is offered, from the library itself")
    } else { t.expect(false, "the known build is offered") }
    succeeds("applying it succeeds") { try repair.apply(to: known.root) }
    let after = read(known.lib)
    t.expect(sites.allSatisfy { Array(after[$0.0..<$0.0 + $0.2.count]) == $0.2 }, "every site carries its new bytes")
    var expected = original
    for (o, _, new) in sites { expected.replaceSubrange(o..<o + new.count, with: new) }
    t.equal(sha(after), sha(expected), "and nothing else in the file changed")
    t.equal(signed, 1, "the changed library is re-signed, once")
    let backup = known.lib.deletingLastPathComponent().appending(path: "win32u.so" + PointerRepair.backupSuffix)
    t.equal(sha(read(backup)), sha(original), "the original is kept beside it")
    if case .repaired = repair.state(of: known.root) { t.expect(true, "and it reads as repaired") }
    else { t.expect(false, "and it reads as repaired") }
    t.throwsError("applying twice refuses") { try repair.apply(to: known.root) }

    succeeds("undo succeeds") { try repair.undo(root: known.root) }
    t.equal(sha(read(known.lib)), sha(original), "undo puts the original back, byte for byte")
    t.expect(!fm.fileExists(atPath: backup.path), "and takes the kept copy with it")
    if case .flawed = repair.state(of: known.root) { t.expect(true, "so the repair is offered again") }
    else { t.expect(false, "so the repair is offered again") }

    // Patched by hand first, with the original kept under another name —
    // how the repair was first tried.
    var partial = original
    partial.replaceSubrange(0x40..<0x43, with: [0x11, 0x22, 0x33])
    let hand = runtime("hand", with: partial)
    let handCopy = hand.lib.deletingLastPathComponent().appending(path: "win32u.so.before-primary-patch")
    try? original.write(to: handCopy)
    if case .flawed(_, let source) = repair.state(of: hand.root) {
        t.equal(source.lastPathComponent, handCopy.lastPathComponent,
                "a hand-patched library is recognised by the original kept beside it")
    } else { t.expect(false, "a hand-patched library is recognised by the original kept beside it") }
    succeeds("and the whole repair is applied from that original") { try repair.apply(to: hand.root) }
    t.equal(sha(read(hand.lib)), sha(expected), "giving exactly the repaired file")
    t.expect(!fm.fileExists(atPath: handCopy.path), "the hand-made copy goes, since the kept backup is the same bytes")

    // A build whose bytes are not where the repair expects: nothing happens.
    let wrong = PointerRepair(builds: [.init(name: "Fixture Wine", original: sha(original),
                                             patches: [.init(0x40, "010203", "111111", "wrong")])],
                              sign: { _ in })
    let misfit = runtime("misfit", with: original)
    t.throwsError("a site that does not hold the expected bytes refuses") { try wrong.apply(to: misfit.root) }
    t.equal(sha(read(misfit.lib)), sha(original), "and the library is untouched")
    t.expect(!fm.fileExists(atPath: misfit.lib.deletingLastPathComponent()
                .appending(path: "win32u.so" + PointerRepair.backupSuffix).path),
             "with no backup left behind")

    // The shipped definition holds together.
    let real = PointerRepair.sikarugir10r6
    t.expect(real.patches.allSatisfy { $0.old.count == $0.new.count && !$0.old.isEmpty },
             "every shipped change keeps the file's size")
    let spans = real.patches.map { $0.offset..<$0.offset + $0.old.count }.sorted { $0.lowerBound < $1.lowerBound }
    t.expect(zip(spans, spans.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound },
             "and no two overlap")

    // Only Unity 6 reads the mouse as a pointer.
    var d = DetectionResult()
    d.engine = .unityMono; d.engineVersion = "6000.3.2f1"
    t.expect(PointerRepair.affects(d), "a Unity 6 game is affected")
    d.engine = .unityIL2CPP
    t.expect(PointerRepair.affects(d), "IL2CPP or Mono alike")
    d.engineVersion = "2022.3.10f1"
    t.expect(!PointerRepair.affects(d), "Unity 2022 reads ordinary mouse messages and is not")
    d.engine = .godot; d.engineVersion = "6000.0"
    t.expect(!PointerRepair.affects(d), "nor is another engine, whatever its version says")

    // The real file, when one is at hand: DECANTER_POINTER_ORIGINAL names an
    // unmodified Sikarugir 10.0 r6 win32u.so. Applied to a copy, signed for
    // real, and read back.
    guard let path = ProcessInfo.processInfo.environment["DECANTER_POINTER_ORIGINAL"] else {
        t.skip("the real build's library", "set DECANTER_POINTER_ORIGINAL to an unmodified one"); return
    }
    let realRT = runtime("real", with: read(URL(filePath: path)))
    succeeds("the shipped repair applies to the real library") { try PointerRepair().apply(to: realRT.root) }
    if case .repaired = PointerRepair().state(of: realRT.root) { t.expect(true, "and it reads as repaired") }
    else { t.expect(false, "and it reads as repaired") }
    let verify = Process()
    verify.executableURL = URL(filePath: "/usr/bin/codesign")
    verify.arguments = ["--verify", realRT.lib.path]
    try? verify.run(); verify.waitUntilExit()
    t.equal(verify.terminationStatus, 0, "and its signature verifies")
}
