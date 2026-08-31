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

    // The regression that started this: the file at the end of Decanter's own
    // Wine download link is a .tar.xz, which was not in the archive list, so it
    // fell all the way through to "not something Decanter can use". The only
    // route that worked was a Homebrew cask — a Terminal command, which is the
    // thing this app exists to remove.
    for name in ["wine-devel-11.16-osx64.tar.xz", "wine-staging-11.16-osx64.tar.xz"] {
        let u = tmp.appending(path: name)
        fm.createFile(atPath: u.path, contents: Data())
        t.equal(acq.classify(u), .wineArchive(canon(u)), "\(name) is recognised as a Wine build")
    }

    let strangeXZ = tmp.appending(path: "linux-6.9.tar.xz")
    fm.createFile(atPath: strangeXZ.path, contents: Data())
    if case .unrecognised(let why) = acq.classify(strangeXZ) {
        t.expect(why.contains("wine-devel-"),
                 "an unrelated .tar.xz is refused, and the refusal names the file that was wanted")
    } else {
        t.expect(false, "an archive with no Wine in its name must not be unpacked looking for one")
    }

    // Dropping a folder: one gesture instead of three, and three chances to
    // drag the wrong file removed.
    let downloads = tmp.appending(path: "Downloads")
    try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
    for name in ["wine-devel-11.16-osx64.tar.xz", "dxvk-1.10.3.tar.gz",
                 "dxmt-v0.80.tar.gz", "receipt.pdf"] {
        fm.createFile(atPath: downloads.appending(path: name).path, contents: Data())
    }
    let found = acq.classifyAll(downloads)
    t.equal(found.count, 3, "a dropped folder yields every piece in it, and nothing else")
    if found.count == 3 {
        // Runtimes first: staging DXMT reports whether anything can host it,
        // and that answer is wrong until the Wine build beside it is pinned.
        t.equal(found[0], .wineArchive(canon(downloads.appending(path: "wine-devel-11.16-osx64.tar.xz"))),
                "the Wine build is taken before the graphics layers that depend on one")
        t.equal(found[1], .dxvkArchive(canon(downloads.appending(path: "dxvk-1.10.3.tar.gz"))),
                "DXVK comes after the runtime")
        t.equal(found[2], .dxmtArchive(canon(downloads.appending(path: "dxmt-v0.80.tar.gz"))),
                "DXMT comes last, because it is the one that reports its host")
    }
    t.equal(acq.classifyAll(downloads), found, "scanning the same folder twice gives the same order")

    // A single file is the common case and must behave exactly as before.
    t.equal(acq.classifyAll(dxvk), [.dxvkArchive(canon(dxvk))],
            "dropping one file still yields exactly that one piece")
    t.equal(acq.classifyAll(loose), [.wineRoot(canon(loose))],
            "a folder that is itself a Wine build is not scanned for loose archives")

    // Recognising the name is half of it. This unpacks a real .tar.xz through
    // the same path a downloaded Wine build takes, because "tar reads xz" was
    // an assumption until it was run.
    let stage = tmp.appending(path: "stage")
    makeWineRoot(at: stage.appending(path: "Wine Devel.app/Contents/Resources/wine"))
    let archive = tmp.appending(path: "wine-devel-11.16-osx64.tar.xz")
    let tarred = try? Shell.run(URL(filePath: "/usr/bin/tar"),
                                ["cJf", archive.path, "-C", stage.path, "."], timeout: 120)
    if tarred?.code == 0 {
        t.survives("a downloaded Wine archive unpacks and the tree inside it is found") {
            let name = try acq.withWineRoot(inArchive: archive) { $0.appending(path: "bin/wine").path }
            guard name.contains("/bin/wine") else {
                throw DecanterError.notFound("found \(name), which is not a Wine tree")
            }
        }
        t.expect(!fm.fileExists(atPath: tmp.appending(path: "tmp-wine").path),
                 "and the unpacked copy is cleaned up afterwards")
        // A .tar.xz of the wrong thing must fail with the sentence that says
        // which file to fetch, not with a tar error.
        let decoy = tmp.appending(path: "wine-notes.tar.xz")
        _ = try? Shell.run(URL(filePath: "/usr/bin/tar"),
                           ["cJf", decoy.path, "-C", tmp.path, "empty"], timeout: 120)
        t.throwsError("an archive with no Wine build inside is refused after unpacking") {
            _ = try acq.withWineRoot(inArchive: decoy) { $0 }
        }
    } else {
        t.skip("a downloaded Wine archive unpacks and the tree inside it is found",
               "tar could not write an xz archive here")
    }

    // An empty folder must still refuse rather than quietly succeed with none.
    let none = acq.classifyAll(empty)
    t.equal(none.count, 1, "a folder with nothing usable yields one answer, not silence")
    if case .unrecognised = none.first { t.expect(true, "and that answer is a refusal") }
    else { t.expect(false, "an empty folder must not report success") }
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
    // know the words, so the words must not appear in the one-line reason.
    // Real product names are allowed in `detail`, where they name a thing the
    // person is about to download — but never in the sentence explaining why
    // they would want it.
    let plain = r.pieces.map { $0.title + " " + $0.why }.joined(separator: " ")
    for jargon in ["prefix", "bottle", "runtime", "backend", "WoW64", "D3D",
                   "Wine", "DXVK", "Vulkan", "translation layer", "x86", "binary",
                   "Apple Silicon", "emulat"] {
        t.expect(!plain.contains(jargon),
                 "the one-line reason avoids \"\(jargon)\"")
    }

    // Every reason has to be a sentence someone can act on, not a fragment.
    for piece in r.pieces {
        t.expect(piece.why.hasSuffix("."), "\(piece.id)'s reason is a full sentence")
        t.expect(piece.why.split(separator: " ").count <= 26,
                 "\(piece.id)'s reason stays short enough to read (\(piece.why.split(separator: " ").count) words)")
    }

    // Two audiences, two lines. The plain sentence must stay jargon-free, and
    // the technical line must actually be specific enough to act on — a version
    // or a project name, not a restatement of the title.
    for piece in r.pieces {
        guard let spec = piece.spec else {
            t.expect(false, "\(piece.id) has a technical line"); continue
        }
        t.expect(spec.contains("·"),
                 "\(piece.id)'s technical line gives more than one fact")
        t.expect(spec.rangeOfCharacter(from: .decimalDigits) != nil,
                 "\(piece.id)'s technical line names a version or a number")
        t.expect(spec.lowercased() != piece.title.lowercased(),
                 "\(piece.id)'s technical line is not just the title again")
    }
    // The version that works is a measured fact, not a preference, so it has to
    // be on screen rather than buried in a document nobody opens.
    t.expect(r.pieces.first { $0.id == "dxvk" }?.spec?.contains("1.10.3") == true,
             "the DXVK row names the version that actually works on macOS")

    t.equal(Engine.ageLabel(3_600 * 5), "5 hours", "template age reads in hours")
    t.equal(Engine.ageLabel(86_400 * 2), "2 days", "template age reads in days")
    t.equal(Engine.ageLabel(60), "less than an hour", "a fresh template does not read as 0 days")
}

/// The wizard offers one action per missing piece. An action whose only
/// possible outcome is an error message is worse than no action, so the
/// offers have to depend on what is actually possible yet.
func runSetupOrderTests(_ t: Harness) {
    t.suite("setup only offers what can actually be done")

    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "decanter-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let e = try? Engine(paths: Paths(root: tmp)) else {
        t.expect(false, "could not open an engine on an empty root"); return
    }

    let r = e.readiness()
    let template = r.pieces.first { $0.id == "template" }
    // Building the golden template clones a pinned runtime. With none pinned
    // there is nothing to clone, so the button would only ever produce an
    // error — the row says what it is waiting for instead.
    t.expect(template?.accepts == nil,
             "with no Wine build present, the template offers no button")
    t.expect(template?.detail?.contains("Waiting for") == true,
             "and says what it is waiting for")

    // Required pieces come before optional ones, because the page is read top
    // to bottom and the first thing you cannot skip should be the first thing
    // you see. The step numbers then follow that same order — numbering by
    // priority instead produced rows reading 1, 3, 4, 2 down the page.
    let ids = r.pieces.map(\.id)
    t.equal(ids.first, "rosetta", "Rosetta is first — nothing runs without it")
    t.equal(ids.last, "template", "the thing Decanter does for you is last")
    t.expect(ids.firstIndex(of: "wine")! < ids.firstIndex(of: "gptk")!,
             "the required Wine build is listed before the optional Apple graphics")
}

/// Readiness on a Mac that has never had a template, which until 0.7.7 nothing
/// tested — every fixture and every developer machine had been through the old
/// single-template layout, so `template/golden` existed and the answer came out
/// right by accident.
///
/// The fault it hid was a first-run blocker: `doctor()` asked about
/// `template/golden` while `template build` writes `template/golden-<runtimeID>`,
/// so a new user built the template, watched `template list` say built, and
/// watched the setup page say "not ready yet" for ever. Found by installing a
/// pack into an empty root.
func runFirstRunReadinessTests(_ t: Harness) {
    t.suite("Readiness — a Mac that has never had a template")

    let root = Fixture.dir("first-run")
    let paths = Paths(root: root)
    try? paths.ensure()
    guard let e = try? Engine(paths: paths) else {
        t.expect(false, "an engine opens on an empty root")
        return
    }

    // A runtime, pinned, with no template anywhere.
    let rt = RuntimeSpec(id: "wine-11.0", kind: .wine, version: "11.0",
                         root: root.appending(path: "runtimes/wine-11.0"),
                         winePath: root.appending(path: "runtimes/wine-11.0/bin/wine"),
                         supports32Bit: true, backends: [.dxvk, .wined3d])
    try? e.store.mutate { $0.runtimes = [rt] }
    e.reload()
    t.expect(!e.doctor().templateBuilt, "with no template anywhere, none is reported")
    t.expect(!e.readiness().ready, "and setup is not ready")

    // Built where `template build` actually writes it — per runtime.
    let perRuntime = paths.template(for: rt.id)
    try? FileManager.default.createDirectory(at: perRuntime.appending(path: "drive_c"),
                                             withIntermediateDirectories: true)
    t.expect(FileManager.default.fileExists(atPath: perRuntime.path),
             "the per-runtime template is where template build puts it")
    t.expect(!FileManager.default.fileExists(atPath: paths.template.path),
             "and the legacy single-template path does not exist on a fresh Mac")

    e.reload()
    t.expect(e.doctor().templateBuilt,
             "a per-runtime template counts — this is the bug, and it blocked every first run")
    t.expect(e.readiness().ready,
             "so a Mac with Rosetta, a runtime and a template is ready")

    // The legacy path still counts, because installs that predate the split
    // have one and nothing has migrated them.
    let legacyRoot = Fixture.dir("legacy-template")
    let legacyPaths = Paths(root: legacyRoot)
    try? legacyPaths.ensure()
    if let e2 = try? Engine(paths: legacyPaths) {
        try? e2.store.mutate { $0.runtimes = [rt] }
        try? FileManager.default.createDirectory(at: legacyPaths.template,
                                                 withIntermediateDirectories: true)
        e2.reload()
        t.expect(e2.doctor().templateBuilt, "the legacy location still counts, so old installs do not regress")
    }
}

/// The pack, as the setup page offers it. These are about the link and the
/// promise around it rather than about layout — a link that resolves to the
/// wrong thing is the one failure here that a person cannot recover from on
/// their own, because they have no way to know what they should have got.
func runPackSourceTests(_ t: Harness) {
    t.suite("Setup — the pack link")

    let u = Readiness.packSource.absoluteString
    t.expect(u.hasSuffix(".tar.gz"),
             "the link is to the file, not to a page listing seventeen assets")
    t.expect(u.contains("/releases/download/"),
             "and is a release asset, so it resolves without anybody choosing anything")

    // Pinned, not floating. `latest` moves with every patch release of the app
    // while the pack does not, so a link to `latest` eventually resolves to a
    // release with no pack in it at all.
    t.expect(!u.contains("/latest/"),
             "pinned to a pack release rather than following the newest app release")
    t.expect(Acquisition(paths: Paths(root: Fixture.dir("packlink")))
                .looksLikePackArchive(Readiness.packSource),
             "and the file it points at is one Decanter recognises as a pack")

    // The notes are a separate link on purpose: 200 MB is worth reading about
    // first, and the download button must not be the only way to find out what
    // is in it.
    t.expect(Readiness.packNotes.absoluteString.contains("/releases/tag/"),
             "there is a page describing the pack, separate from the download")
    t.expect(Readiness.packNotes.absoluteString != u,
             "reading about it and fetching it are different actions")

    // Every source the setup page offers must be somewhere a browser can go.
    // A file:// or a malformed URL here would open nothing and say nothing.
    for (name, url) in [("pack", Readiness.packSource), ("pack notes", Readiness.packNotes),
                        ("wine", Readiness.wineSource), ("gptk", Readiness.gptkSource),
                        ("dxvk", Readiness.dxvkSource), ("dxmt", Readiness.dxmtSource)] {
        t.equal(url.scheme, "https", "the \(name) link is https")
        t.expect(url.host != nil, "the \(name) link names a host")
    }
}
