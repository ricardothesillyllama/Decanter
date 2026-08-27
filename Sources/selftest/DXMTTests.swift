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

    // MH_DYLIB = 6, MH_BUNDLE = 8. The three cases are the three real builds:
    // one that links but hides the metal-view calls (mainline Wine), one that
    // exports plenty but cannot be linked against (the Game Porting Toolkit),
    // and the one DXMT actually asks for.
    // `macdrv_functions` is what distinguishes real builds; the view calls are
    // the other name DXMT looks up. Either has to be enough on its own.
    let metalAPI = "_macdrv_functions"
    let dylib = fixtureRoot("winemac.so", machO(filetype: 6))
    let capable = fixtureRoot("winemac.so", machO(filetype: 6, trailing: metalAPI))
    let bundle = fixtureRoot("winemac.drv.so", machO(filetype: 8,
                             trailing: "_macdrv_get_client_cocoa_view WineMetalView " + metalAPI))
    let noDriver = fixtureRoot(nil, Data())
    defer { for u in [dylib, capable, bundle, noDriver] { try? fm.removeItem(at: u) } }

    let capableAltName = fixtureRoot("winemac.so", machO(filetype: 6,
                                     trailing: "_macdrv_view_create_metal_view"))
    defer { try? fm.removeItem(at: capableAltName) }
    t.expect(RuntimeManager.metalHosting(root: capable).looksCapable,
             "a dylib that exports macdrv_functions can host DXMT")
    t.expect(RuntimeManager.metalHosting(root: capableAltName).looksCapable,
             "…and so can one that exports the view calls under their own names")
    // The case that a real game disproved: it links, it reaches a Direct3D 11
    // device, and only then finds there is nothing to draw into.
    t.expect(!RuntimeManager.metalHosting(root: dylib).looksCapable,
             "a dylib that hides them cannot, even though it loads perfectly well")
    t.expect(RuntimeManager.metalHosting(root: dylib).driverIsLinkable,
             "…and it is still recorded as linkable, because it is")
    t.expect(!RuntimeManager.metalHosting(root: bundle).looksCapable,
             "a driver built as a bundle cannot, however many symbols it exports")
    t.expect(RuntimeManager.metalHosting(root: bundle).hasCocoaViewAccess,
             "…and the symbols are still recorded, they just do not decide it")
    t.expect(RuntimeManager.metalHosting(root: noDriver).driverPath == nil,
             "a build with no Unix-side Mac driver reports no driver")

    // Every "no" must be able to say why, and the two noes must not say the
    // same thing: one needs a different build, the other needs the same build
    // compiled differently.
    for (name, root) in [("bundle", bundle), ("no driver", noDriver), ("hidden symbols", dylib)] {
        let why = RuntimeManager.metalHosting(root: root).unavailableReason
        t.expect(why != nil && why!.count > 40, "\(name): the refusal explains itself")
    }
    t.expect(RuntimeManager.metalHosting(root: dylib).unavailableReason
             != RuntimeManager.metalHosting(root: bundle).unavailableReason,
             "a hidden-symbol build and a bundle are told apart, not given one answer")
    t.expect(RuntimeManager.metalHosting(root: capable).unavailableReason == nil,
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
        let nmAPI = m.exportedSymbols.contains { $0.contains("macdrv_functions")
                                              || $0.contains("macdrv_view_create_metal_view") }
        t.equal(m.hasCocoaViewAccess, nmCocoa, "\(r.id): cocoa view verdict matches nm")
        // The field that decides is the one that has to agree. `hasMetalView`
        // is deliberately not checked against nm: it looks for the string
        // "WineMetalView", and mainline Wine 11 contains that string as an
        // Objective-C class name while exporting no such symbol. A byte scan
        // cannot tell a class name from an export, which is exactly why the
        // verdict keys on `macdrv_functions` — a symbol that appears in the
        // table when it is exported and not otherwise.
        t.equal(m.hasMetalViewAPI, nmAPI, "\(r.id): Metal view API verdict matches nm")
    }
    if compared == 0 { t.skip("byte scan vs nm", "no pinned runtime with a readable driver") }

    // MARK: What a runtime is allowed to offer
    t.suite("a runtime only offers backends it can deliver")
    t.expect(!RuntimeManager.backends(for: .wine, root: bundle).contains(.dxmt),
             "a Wine that cannot host DXMT does not offer it")
    // Vulkan is the same rule as Metal: a backend is offered only if the
    // runtime can actually deliver it. Sikarugir Wine 10 ships winevulkan.so
    // and no MoltenVK, and DXVK on it fails with "Required Vulkan extension
    // VK_KHR_surface not supported" — so shipping DXVK in its backend list was
    // the same bug as offering DXMT on a Wine that cannot present.
    let noVulkan = fixtureRoot("winemac.so", machO(filetype: 6, trailing: metalAPI))
    let withVulkan = fixtureRoot("winemac.so", machO(filetype: 6, trailing: metalAPI))
    try? fm.createDirectory(at: withVulkan.appending(path: "lib"), withIntermediateDirectories: true)
    fm.createFile(atPath: withVulkan.appending(path: "lib/libMoltenVK.dylib").path, contents: Data())
    defer { for u in [noVulkan, withVulkan] { try? fm.removeItem(at: u) } }
    t.expect(!RuntimeManager.hasVulkan(root: noVulkan),
             "a build with no MoltenVK cannot reach Vulkan")
    t.expect(RuntimeManager.hasVulkan(root: withVulkan),
             "…and one that ships it can")
    t.expect(!RuntimeManager.backends(for: .wine, root: noVulkan).contains(.dxvk),
             "so DXVK is not offered on a runtime that ships no MoltenVK")
    t.expect(RuntimeManager.backends(for: .wine, root: withVulkan).contains(.dxvk),
             "and is offered on one that does")
    // WineD3D asks nothing of the runtime, so it must always survive gating —
    // it is the fallback that makes the other refusals safe to make.
    for root in [noVulkan, withVulkan, bundle, dylib] {
        t.expect(RuntimeManager.backends(for: .wine, root: root).contains(.wined3d),
                 "WineD3D is always offered — it is the floor")
    }

    t.expect(!RuntimeManager.backends(for: .wine, root: dylib).contains(.dxmt),
             "…nor does one that would load and then fail at the first frame")
    t.expect(RuntimeManager.backends(for: .wine, root: capable).contains(.dxmt),
             "a Wine that can host DXMT does offer it")
    t.expect(!RuntimeManager.backends(for: .wine, root: bundle).contains(.d3dmetal),
             "D3DMetal is still never offered on plain Wine")
    t.expect(RuntimeManager.backends(for: .gptk, root: bundle).contains(.d3dmetal),
             "…and is always offered on the Game Porting Toolkit")

    // MARK: One order, everywhere
    //
    // Lists used to come out in whatever order the building code appended in,
    // so the same options read "D3DMetal, DXVK, WineD3D" on one row and
    // "WineD3D, DXMT" on the next — best option below worst. A menu whose order
    // moves between rows is a menu people misread.
    t.suite("backends are listed in one order wherever they appear")
    let everything = fixtureRoot("winemac.so", machO(filetype: 6, trailing: metalAPI))
    try? fm.createDirectory(at: everything.appending(path: "lib"), withIntermediateDirectories: true)
    fm.createFile(atPath: everything.appending(path: "lib/libMoltenVK.dylib").path, contents: Data())
    defer { try? fm.removeItem(at: everything) }
    t.equal(RuntimeManager.backends(for: .gptk, root: everything),
            [.d3dmetal, .dxmt, .dxvk, .wined3d],
            "every backend at once comes out best-first")
    t.equal(RuntimeManager.backends(for: .wine, root: everything),
            [.dxmt, .dxvk, .wined3d],
            "…and dropping one does not reshuffle the rest")
    for (kind, root) in [(RuntimeKind.gptk, everything), (.wine, everything),
                         (.wine, withVulkan), (.wine, noVulkan), (.gptk, bundle)] {
        let got = RuntimeManager.backends(for: kind, root: root)
        t.equal(got, got.inPreferenceOrder, "\(kind.rawValue) list is already in preference order")
        t.equal(got.last, .wined3d, "…and ends on the fallback, never above it")
    }
    // Ranks must be distinct, or "sorted" is not an order.
    t.equal(Set(GraphicsBackend.allCases.map(\.rank)).count, GraphicsBackend.allCases.count,
            "no two backends share a rank")

    // MARK: Unity 6's verdict says what was measured
    //
    // DXMT is the only backend that runs Unity 6, and it was watched doing it:
    // Direct3D 11.0 at feature level 11_1, renderer "Apple M2", gameplay on
    // screen. So the warning must survive every other backend and be lifted by
    // exactly one — an earlier version of this suite asserted the opposite,
    // and was right until the Wine that DXMT needs turned up.
    t.suite("the Unity 6 verdict names DXMT as the way through")
    let det6 = Detector()
    let u6 = det6.detect(exe: Fixture.unity(unityVersion: "6000.2.0b7").appending(path: "TestGame.exe"))
    t.equal(u6.engineVersion, "6000.2.0b7", "the Unity 6 version is read")
    guard let verdict = u6.knownUnsupported else {
        t.expect(false, "Unity 6 is flagged as unsupported"); return
    }
    t.expect(verdict.contains("ID3D11Fence"),
             "the verdict names the interface Apple graphics is missing")
    t.expect(verdict.contains("11_1"),
             "…and the feature level DXMT reaches")
    t.expect(verdict.contains("Metal view"),
             "…and the driver requirement, without which DXMT loads and cannot draw")
    t.equal(u6.unsupportedUnless, .dxmt, "DXMT is named as the way through")
    t.expect(u6.blocker(onBackend: .dxmt) == nil, "so being on DXMT lifts the warning")
    for b in GraphicsBackend.allCases where b != .dxmt {
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
