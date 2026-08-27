import Foundation
import DecanterKit

/// The DXMT capability gate, the Unity 6 verdict, and the one place where two
/// graphics layers can be mistaken for each other.
func runDXMTTests(_ t: Harness) {
    let fm = FileManager.default

    // MARK: The gate itself, on fixtures rather than on whatever is pinned
    //
    // The verdict comes from a byte scan now, not from `nm` — the developer
    // tools are not on every Mac. Fixtures make that testable on any machine.
    t.suite("DXMT capability is read from the driver's bytes")

    /// A minimal Mach-O: magic, then `filetype` at offset 12, which is all the
    /// gate reads. Real headers rather than text, because the thing under test
    /// is a header field.
    func machO(filetype: UInt32, trailing: String = "") -> Data {
        var d = Data()
        for v: UInt32 in [0xFEED_FACF, 0x0100_0007, 0x0000_0003, filetype, 0, 0, 0, 0] {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(Data(trailing.utf8))
        return d
    }

    func fixtureRoot(_ name: String?, _ body: Data) -> URL {
        let root = fm.temporaryDirectory.appending(path: "dxmt-fix-\(UUID().uuidString)")
        if let name {
            let dir = root.appending(path: "lib/wine/x86_64-unix")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? body.write(to: dir.appending(path: name))
        }
        return root
    }

    // MH_DYLIB = 6, MH_BUNDLE = 8.
    let dylib = fixtureRoot("winemac.so", machO(filetype: 6))
    let bundle = fixtureRoot("winemac.drv.so", machO(filetype: 8, trailing: "_macdrv_get_client_cocoa_view WineMetalView"))
    let noDriver = fixtureRoot(nil, Data())
    defer { for u in [dylib, bundle, noDriver] { try? fm.removeItem(at: u) } }

    t.expect(RuntimeManager.metalHosting(root: dylib).looksCapable,
             "a driver built as a dylib can host DXMT")
    t.expect(!RuntimeManager.metalHosting(root: bundle).looksCapable,
             "a driver built as a bundle cannot, however many symbols it exports")
    t.expect(RuntimeManager.metalHosting(root: bundle).hasCocoaViewAccess,
             "…and the symbols are still recorded, they just do not decide it")
    t.expect(RuntimeManager.metalHosting(root: noDriver).driverPath == nil,
             "a build with no Unix-side Mac driver reports no driver")

    // Every "no" must be able to say why. A gate that refuses without a reason
    // is the thing people file issues about.
    for (name, root) in [("bundle", bundle), ("no driver", noDriver)] {
        let why = RuntimeManager.metalHosting(root: root).unavailableReason
        t.expect(why != nil && why!.count > 40, "\(name): the refusal explains itself")
    }
    t.expect(RuntimeManager.metalHosting(root: dylib).unavailableReason == nil,
             "a capable build gives no reason, because there is nothing to explain")

    // MARK: Byte scan and nm must not drift apart
    //
    // `nm` is still consulted for detail. If the two ever disagreed, the
    // detail shown in `doctor` would contradict the verdict beside it.
    t.suite("the byte scan agrees with nm")
    var compared = 0
    for r in (try? Store(paths: Paths()))?.state.runtimes ?? [] {
        let m = RuntimeManager.metalHosting(root: r.root)
        guard m.driverPath != nil, !m.exportedSymbols.isEmpty else { continue }
        compared += 1
        let nmCocoa = m.exportedSymbols.contains { $0.contains("macdrv_get_cocoa_view")
                                                || $0.contains("macdrv_get_client_cocoa_view") }
        let nmMetal = m.exportedSymbols.contains { $0.contains("WineMetalView") }
        t.equal(m.hasCocoaViewAccess, nmCocoa, "\(r.id): cocoa view verdict matches nm")
        t.equal(m.hasMetalView, nmMetal, "\(r.id): Metal view verdict matches nm")
    }
    if compared == 0 { t.skip("byte scan vs nm", "no pinned runtime with a readable driver") }

    // MARK: What a runtime is allowed to offer
    t.suite("a runtime only offers backends it can deliver")
    t.expect(!RuntimeManager.backends(for: .wine, root: bundle).contains(.dxmt),
             "a Wine that cannot host DXMT does not offer it")
    t.expect(RuntimeManager.backends(for: .wine, root: dylib).contains(.dxmt),
             "a Wine that can host DXMT does offer it")
    t.expect(!RuntimeManager.backends(for: .wine, root: bundle).contains(.d3dmetal),
             "D3DMetal is still never offered on plain Wine")
    t.expect(RuntimeManager.backends(for: .gptk, root: bundle).contains(.d3dmetal),
             "…and is always offered on the Game Porting Toolkit")

    // MARK: Unity 6's verdict says what was measured
    //
    // DXMT is the only backend here that gets Unity 6 a device, and it still
    // does not run it. The warning has to survive being on DXMT, or it would
    // promise something that was tried and did not work.
    t.suite("the Unity 6 verdict is not lifted by any backend here")
    let det6 = Detector()
    let u6 = det6.detect(exe: Fixture.unity(unityVersion: "6000.2.0b7").appending(path: "TestGame.exe"))
    t.equal(u6.engineVersion, "6000.2.0b7", "the Unity 6 version is read")
    guard let verdict = u6.knownUnsupported else {
        t.expect(false, "Unity 6 is flagged as unsupported"); return
    }
    t.expect(verdict.contains("ID3D11Fence"),
             "the verdict names the interface that actually fails")
    t.expect(verdict.contains("11_1"),
             "…and credits DXMT with the feature level it does reach")
    t.expect(u6.unsupportedUnless == nil,
             "no backend is named as an escape hatch, because none was seen to work")
    for b in GraphicsBackend.allCases {
        t.expect(u6.blocker(onBackend: b) != nil, "still blocked on \(b.label)")
    }

    // The mechanism is kept, because a future DXMT release implementing the
    // fence is exactly the case it exists for.
    var hypothetical = DetectionResult()
    hypothetical.knownUnsupported = "needs an interface only X provides"
    hypothetical.unsupportedUnless = .dxmt
    t.expect(hypothetical.blocker(onBackend: .dxvk) != nil, "an escape hatch does not lift other backends")
    t.expect(hypothetical.blocker(onBackend: .dxmt) == nil, "…and does lift the one it names")

    var plain = DetectionResult()
    plain.knownUnsupported = "nothing will run this"
    t.expect(plain.blocker(onBackend: .dxmt) != nil,
             "a blocker with no escape hatch is not lifted by any backend")

    // MARK: Archive classification
    t.suite("DXMT archives are told apart from DXVK ones")
    let acq = Acquisition(paths: Paths())
    for name in ["dxmt-v0.72.tar.gz", "dxmt-0.72.zip", "DXMT-1.0.tar.zst"] {
        let u = URL(filePath: "/tmp/\(name)")
        t.expect(acq.looksLikeDXMT(u), "\(name) is recognised as DXMT")
        t.expect(!acq.looksLikeDXVK(u), "\(name) is not mistaken for DXVK")
    }
    for name in ["dxvk-1.10.3.tar.gz", "dxvk-2.3.tar.gz"] {
        let u = URL(filePath: "/tmp/\(name)")
        t.expect(acq.looksLikeDXVK(u), "\(name) is still recognised as DXVK")
        t.expect(!acq.looksLikeDXMT(u), "\(name) is not mistaken for DXMT")
    }
    if case .unrecognised(let why) = acq.classify(URL(filePath: "/tmp/something-else.tar.gz")) {
        t.expect(why.contains("dxmt") || why.contains("DXMT"),
                 "an unknown archive's complaint mentions both layers it could have been")
    } else {
        t.expect(false, "an unknown archive is not classified as anything")
    }

    t.suite("a DXMT version is read out of the archive name")
    let payload = fm.temporaryDirectory
    t.equal(DXMTInstaller.version(fromArchive: "dxmt-v0.72.tar.gz", payload: payload), "0.72",
            "a leading v is dropped")
    t.equal(DXMTInstaller.version(fromArchive: "dxmt-1.2.3.zip", payload: payload), "1.2.3",
            "a three-part version survives")

    // MARK: The collision
    //
    // DXVK and DXMT replace the same DLLs and leave the same backup behind, so
    // the backup alone cannot say which one is installed.
    t.suite("a DXMT prefix is not reported as DXVK")
    let prefix = fm.temporaryDirectory.appending(path: "dxmt-prefix-\(UUID().uuidString)")
    let sys = prefix.appending(path: "drive_c/windows/system32")
    try? fm.createDirectory(at: sys, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: prefix) }
    try? Data("x".utf8).write(to: sys.appending(path: "d3d11.dll.wine-builtin"))

    let dxvk = DXVKInstaller(paths: Paths())
    let dxmt = DXMTInstaller(paths: Paths())
    t.expect(dxvk.isInstalled(in: prefix), "a backup with no DXMT marker still reads as DXVK")
    try? Data("0.72".utf8).write(to: prefix.appending(path: ".decanter-dxmt"))
    t.expect(dxmt.isInstalled(in: prefix), "the marker identifies DXMT")
    t.expect(!dxvk.isInstalled(in: prefix), "…and DXVK stops claiming the same prefix")
    dxmt.clearMarker(in: prefix)
    t.expect(dxvk.isInstalled(in: prefix), "clearing the marker hands the prefix back")
}

/// Which evidence is allowed to decide that a game really renders with D3D12.
///
/// Measured across the Unity builds available while this was written: every
/// 6000.x build imports `d3d12.dll` and no 2018/2019 build does, so the import
/// dates the engine rather than describing the renderer. The Agility SDK
/// folder is shipped only when D3D12 is in the build's graphics API list.
func runD3D12EvidenceTests(_ t: Harness) {
    t.suite("D3D12 is inferred from what shipped, not from what linked")
    let det = Detector()

    let plain = det.detect(exe: Fixture.unity(d3d12: true).appending(path: "TestGame.exe"))
    t.expect(plain.graphicsAPIs.contains("d3d12.dll"), "precondition: the import is there")
    t.expect(!plain.shipsD3D12Runtime, "a Unity build with no Agility SDK is not treated as a D3D12 game")

    let shipped = det.detect(exe: Fixture.unity(d3d12: true, agilitySDK: true).appending(path: "TestGame.exe"))
    t.expect(shipped.shipsD3D12Runtime, "the Agility SDK beside the game is the evidence that counts")
    t.equal(shipped.recommendedBackend, .d3dmetal, "…and it is what moves the recommendation to Apple graphics")
    t.expect(shipped.signals.contains { $0.rule.contains("Agility") },
             "the reason is stated in the evidence list, not just applied")

    let none = det.detect(exe: Fixture.unity(d3d12: false).appending(path: "TestGame.exe"))
    t.expect(!none.shipsD3D12Runtime, "no import and no SDK means no D3D12")
}
