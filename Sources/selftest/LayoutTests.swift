import Foundation
import DecanterKit

/// Wine's Unix-side directory name was hardcoded in nine places until 0.8.
/// None of them was wrong — every free macOS Wine is x86_64 — but each one was
/// a name with an expiry date on it, and the bundles in 0.9 are written once
/// and opened years later. These tests exist to prove two things: that nothing
/// changed for the builds people actually have, and that a build with the
/// other name would be read correctly rather than reported empty.
func runWineLayoutTests(_ t: Harness) {
    let fm = FileManager.default
    let tmp = URL(filePath: NSTemporaryDirectory())
        .appending(path: "decanter-layout-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }

    /// A Wine root carrying `dirs` under lib/wine, each holding `files`.
    func build(_ name: String, dirs: [String], files: [String] = []) -> URL {
        let root = tmp.appending(path: name)
        for d in dirs {
            let u = root.appending(path: "lib/wine/\(d)")
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            for f in files { fm.createFile(atPath: u.appending(path: f).path, contents: Data("x".utf8)) }
        }
        return root
    }

    t.suite("the host directory is read off disk, not assumed")
    t.equal(WineLayout.hostDir(under: build("intel", dirs: ["x86_64-unix"])), "x86_64-unix",
            "every Wine shipping today still reads as x86_64-unix")
    t.equal(WineLayout.hostDir(under: build("arm", dirs: ["aarch64-unix"])), "aarch64-unix",
            "a build using Wine's ARM64 name is found")
    t.equal(WineLayout.hostDir(under: build("arm-alt", dirs: ["arm64-unix"])), "arm64-unix",
            "so is one using Apple's spelling of it")

    // Not an arbitrary preference: if a build somehow carried both, the x86_64
    // side is the one with binaries in it on every Mac that exists today.
    t.equal(WineLayout.hostDir(under: build("both", dirs: ["aarch64-unix", "x86_64-unix"])),
            "x86_64-unix", "a build carrying both is read as x86_64 while that is what runs")

    // A root with no Unix directory at all is a broken build, and the caller
    // is about to find nothing whichever name it looks under. It should find
    // nothing at the path a person would think to check by hand.
    t.equal(WineLayout.hostDir(under: tmp.appending(path: "nothing-here")), "x86_64-unix",
            "a build with no Unix side falls back to the familiar name")

    t.suite("the Windows side does not move")
    // The failure this guards against is a plausible one: renaming the guest
    // directories alongside the host one. An ARM64-native Wine still runs the
    // same x86_64 Windows game, so `x86_64-windows` means the game's
    // architecture and has nothing to say about this Mac.
    let guestOnly = build("guest", dirs: ["aarch64-unix", "x86_64-windows", "i386-windows"])
    t.equal(WineLayout.hostDir(under: guestOnly), "aarch64-unix",
            "the Windows directories are not mistaken for the host one")
    t.expect(!WineLayout.hostDirs.contains { $0.hasSuffix("-windows") },
             "no Windows directory is a candidate for the host side")

    t.suite("the readers that used the old constant follow it")
    // These are the payoff. Each one used to look under a literal path, and a
    // machine with the other layout would have been told its Wine has no Mac
    // driver, no Metal bridge and no Vulkan — three capability gates all
    // answering "no" because of a directory name.
    let armDriver = build("arm-driver", dirs: ["aarch64-unix"], files: ["winemac.so"])
    t.expect(RuntimeManager.metalHosting(root: armDriver).driverPath != nil,
             "the Mac driver is found under the ARM64 name")
    t.equal(RuntimeManager.metalHosting(root: armDriver).driverPath?.lastPathComponent,
            "winemac.so", "and it is the driver, not something beside it")

    let armVulkan = build("arm-vulkan", dirs: ["aarch64-unix"], files: ["libMoltenVK.dylib"])
    t.equal(RuntimeManager.hasVulkan(root: armVulkan), true,
            "MoltenVK is found under the ARM64 name")

    let armBridge = build("arm-bridge", dirs: ["aarch64-unix"], files: ["winemetal.so"])
    t.equal(WineLayout.hostPath(under: armBridge, "winemetal.so").lastPathComponent,
            "winemetal.so", "the Metal bridge path is built against the name on disk")
    t.expect(fm.fileExists(atPath: WineLayout.hostPath(under: armBridge, "winemetal.so").path),
             "and it points at a file that is really there")

    // The intel case is the one that must not have changed. Same fixtures,
    // same answers, on the layout every user has.
    let intelDriver = build("intel-driver", dirs: ["x86_64-unix"],
                            files: ["winemac.drv.so", "libMoltenVK.dylib", "winemetal.so"])
    t.expect(RuntimeManager.metalHosting(root: intelDriver).driverPath != nil,
             "nothing changed for an x86_64 build's Mac driver")
    t.equal(RuntimeManager.hasVulkan(root: intelDriver), true,
            "nor for its MoltenVK")
    t.expect(fm.fileExists(atPath: WineLayout.hostPath(under: intelDriver, "winemetal.so").path),
             "nor for its Metal bridge")

    t.suite("nothing crashes on a root that is not a Wine build")
    t.survives("hostDir on a file rather than a directory") {
        let f = tmp.appending(path: "a-file")
        fm.createFile(atPath: f.path, contents: Data())
        _ = WineLayout.hostDir(under: f)
    }
    t.survives("hostPath on a root that does not exist") {
        _ = WineLayout.hostPath(under: tmp.appending(path: "absent"), "winemac.so")
    }
    t.equal(WineLayout.hostRelative(under: build("rel", dirs: ["aarch64-unix"]), "ntdll.so"),
            "lib/wine/aarch64-unix/ntdll.so", "the relative form agrees with the URL form")
}
