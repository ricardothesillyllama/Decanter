import Foundation
import DecanterKit

/// Classification decides what happens to a file someone drags onto the
/// window, and a wrong answer there is the first thing a new user ever sees.
/// Every layout here is one these builds actually ship in.
func runAcquisitionTests(_ t: Harness) {
    t.suite("what a dropped file turns out to be")

    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "decanter-acq-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let acq = Acquisition(paths: Paths(root: tmp))
    let fm = FileManager.default
    /// Paths come back canonicalised — see Acquisition.canonical — so the
    /// expectations are written in the same form.
    func canon(_ u: URL) -> URL { URL(filePath: u.pathKey) }

    /// A Wine tree is "a directory with an executable bin/wine in it" — the
    /// only thing every build shares. Names differ by source.
    func makeWineRoot(at u: URL) {
        try? fm.createDirectory(at: u.appending(path: "bin"), withIntermediateDirectories: true)
        let bin = u.appending(path: "bin/wine")
        fm.createFile(atPath: bin.path, contents: Data("#!/bin/sh\n".utf8),
                      attributes: [.posixPermissions: 0o755])
    }

    let loose = tmp.appending(path: "wine")
    makeWineRoot(at: loose)
    t.equal(acq.classify(loose), .wineRoot(canon(loose)), "a bare Wine tree is recognised")

    // The .app layout: what a Homebrew cask or Apple's toolkit installs.
    let app = tmp.appending(path: "Wine Devel.app")
    let inside = app.appending(path: "Contents/Resources/wine")
    makeWineRoot(at: inside)
    t.equal(acq.classify(app), .wineRoot(canon(inside)), "a Wine tree inside a .app bundle is found")

    // A disk image's top level is usually a licence and a folder, so the tree
    // is one or two levels down. Not finding it there is what forced people
    // into Terminal to work out the right path by hand.
    let image = tmp.appending(path: "mounted")
    let nested = image.appending(path: "Game Porting Toolkit/wine")
    makeWineRoot(at: nested)
    t.equal(acq.classify(image), .wineRoot(canon(nested)), "a Wine tree nested two levels down is found")

    // Two candidates must resolve the same way every time: a user's second
    // attempt pinning something different is a bug they cannot even describe.
    let twoUp = tmp.appending(path: "two")
    makeWineRoot(at: twoUp.appending(path: "beta/wine"))
    makeWineRoot(at: twoUp.appending(path: "alpha/wine"))
    let first = acq.classify(twoUp), second = acq.classify(twoUp)
    t.equal(first, second, "classification of the same directory is stable")
    t.equal(first, .wineRoot(canon(twoUp.appending(path: "alpha/wine"))),
            "when a tree appears twice, the first by name wins")

    // Depth is bounded so dropping a home directory does not walk it.
    let deep = tmp.appending(path: "deep")
    makeWineRoot(at: deep.appending(path: "a/b/c/d/wine"))
    if case .unrecognised = acq.classify(deep) { t.expect(true, "the search depth is bounded") }
    else { t.expect(false, "a Wine tree five levels down should not be found — the search is bounded") }

    let dxvk = tmp.appending(path: "dxvk-1.10.3.tar.gz")
    fm.createFile(atPath: dxvk.path, contents: Data())
    t.equal(acq.classify(dxvk), .dxvkArchive(canon(dxvk)), "a DXVK release tarball is recognised by name")

    let other = tmp.appending(path: "something-else.tar.gz")
    fm.createFile(atPath: other.path, contents: Data())
    if case .unrecognised(let why) = acq.classify(other) {
        t.expect(why.contains("dxvk-"), "an unrelated archive is refused, and says what the name should look like")
    } else {
        t.expect(false, "a non-DXVK archive must not be staged as DXVK")
    }

    let dmg = tmp.appending(path: "Game Porting Toolkit_1.1.dmg")
    fm.createFile(atPath: dmg.path, contents: Data())
    t.equal(acq.classify(dmg), .diskImage(canon(dmg)), "a disk image is recognised before anything is mounted")

    let empty = tmp.appending(path: "empty")
    try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
    if case .unrecognised(let why) = acq.classify(empty) {
        t.expect(why.contains("empty"), "an unusable folder is named in the refusal")
    } else {
        t.expect(false, "an empty folder is not a Wine build")
    }
}

/// hdiutil's plist is parsed rather than its human output, which is
/// tab-aligned and has changed shape between macOS releases.
func runDiskImageParseTests(_ t: Harness) {
    t.suite("reading hdiutil's output")

    // Trimmed from a real `hdiutil attach -plist`: the partition entries come
    // first and have no mount point at all, which a naive "first entity" read
    // would take as the volume.
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>system-entities</key>
      <array>
        <dict>
          <key>content-hint</key><string>GUID_partition_scheme</string>
          <key>dev-entry</key><string>/dev/disk4</string>
        </dict>
        <dict>
          <key>content-hint</key><string>Apple_APFS</string>
          <key>dev-entry</key><string>/dev/disk4s1</string>
        </dict>
        <dict>
          <key>dev-entry</key><string>/dev/disk5s1</string>
          <key>mount-point</key><string>/Volumes/Game Porting Toolkit</string>
          <key>volume-kind</key><string>apfs</string>
        </dict>
      </array>
    </dict>
    </plist>
    """
    let m = Acquisition.parseAttach(plist: plist)
    t.equal(m?.mountPoint.path, "/Volumes/Game Porting Toolkit",
            "the entity with a mount point is the volume, not the first one listed")
    t.equal(m?.device, "/dev/disk5s1", "the device is kept, because that is what detaches cleanly")

    t.expect(Acquisition.parseAttach(plist: "not a plist") == nil,
             "unparseable output yields nothing rather than a wrong mount")
    t.expect(Acquisition.parseAttach(plist: "<plist version=\"1.0\"><dict/></plist>") == nil,
             "a plist with no entities yields nothing")
}

/// The Setup page and `decanter setup` both render this, so its wording is
/// part of the product. These check the properties the UI relies on.
func runReadinessTests(_ t: Harness) {
    t.suite("what Decanter says it needs")

    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "decanter-ready-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let e = try? Engine(paths: Paths(root: tmp)) else {
        t.expect(false, "could not open an engine on an empty root"); return
    }

    let r = e.readiness()
    t.expect(!r.ready, "a Mac with nothing set up is not ready")
    t.expect(r.pieces.count >= 4, "every piece a user must supply is listed")

    // The distinction the sidebar badge depends on: a missing optional piece
    // must never make the app say it cannot run anything.
    let optional = r.pieces.filter { !$0.required }.map(\.id)
    t.expect(optional.contains("gptk"), "Apple graphics is optional — games still run without it")
    t.expect(optional.contains("dxvk"), "Vulkan graphics is optional")
    t.expect(r.pieces.first { $0.id == "wine" }?.required == true,
             "Windows support is required — nothing runs without it")

    // Every piece a person has to go and fetch must say where from, or the
    // page is just a list of things they cannot act on.
    for piece in r.pieces where piece.state != .present {
        if piece.id == "rosetta" || piece.id == "template" { continue }
        t.expect(piece.source != nil, "\(piece.id) says where to get it")
        t.expect(piece.accepts != nil, "\(piece.id) says what to hand over")
    }

    // The copy is the feature here: this page exists for people who do not
    // know the words, so the words must not appear on it.
    let plain = r.pieces.map { $0.title + " " + $0.why }.joined(separator: " ")
    for jargon in ["prefix", "bottle", "runtime", "backend", "WoW64", "D3D"] {
        t.expect(!plain.contains(jargon),
                 "the plain-language summary avoids \"\(jargon)\"")
    }

    t.equal(Engine.ageLabel(3_600 * 5), "5 hours", "template age reads in hours")
    t.equal(Engine.ageLabel(86_400 * 2), "2 days", "template age reads in days")
    t.equal(Engine.ageLabel(60), "less than an hour", "a fresh template does not read as 0 days")
}
