import Foundation
import DecanterKit

/// A pack is the only thing Decanter takes in that arrives as a single unit,
/// claims to be complete, and is installed on the strength of that claim. So
/// the checks here are almost all about the claim being false in some specific
/// way: a truncated download, a swapped file, a manifest that points outside
/// its own directory, a signature made with the wrong key or over the wrong
/// kind of document.
func runPackTests(_ t: Harness) {
    t.suite("Packs — the manifest, and what it is worth")

    let work = Fixture.dir("pack")
    let paths = Paths(root: work.appending(path: "store"))
    try? paths.ensure()

    // Stand-in archives. Nothing unpacks them in these tests: what is under
    // test is the manifest, the hashing and the refusals, and a real Wine build
    // in the suite would make it take minutes and only run on a machine that
    // already had one.
    let src = Fixture.dir("pack-src")
    let dxvkArchive = Fixture.write(src, "dxvk-2.7.tar.gz", Data(repeating: 0xD1, count: 64_000))
    let dxmtArchive = Fixture.write(src, "dxmt-0.80.tar.gz", Data(repeating: 0xD2, count: 32_000))

    let out = work.appending(path: "decanter-pack-1")
    let built = try? Pack.assemble([
        .init(piece: .dxvk, archive: dxvkArchive, licence: "Zlib", origin: "DXVK"),
        .init(piece: .dxmt, archive: dxmtArchive, licence: "LGPL-2.1-or-later", origin: "DXMT"),
    ], named: "decanter-pack-1", into: out, notes: "fixture", paths: paths)

    guard let built else {
        t.expect(false, "a pack assembles from two archives")
        return
    }
    t.equal(built.manifest.components.count, 2, "the manifest lists both components")
    t.equal(built.manifest.components.first { $0.piece == .dxvk }?.version, "2.7",
            "the version is read out of the archive's name")
    t.equal(built.manifest.totalBytes, 96_000, "the manifest's sizes are the files' sizes")
    t.expect(FileManager.default.fileExists(atPath: out.appending(path: Pack.licencesName).path),
             "a licences file is written beside the components")

    // The licences file is generated from the components, so a component that
    // is in the pack cannot be absent from it.
    let licences = (try? String(contentsOf: out.appending(path: Pack.licencesName), encoding: .utf8)) ?? ""
    t.expect(licences.contains("Zlib") && licences.contains("LGPL-2.1-or-later"),
             "every component's licence is named in the licences file")
    t.expect(licences.contains("GPL-3.0-or-later"),
             "the licences file says what Decanter itself is, and that it is not in the pack")
    t.expect(licences.lowercased().contains("source"),
             "the LGPL's source obligation is stated rather than left implied")

    guard let located = try? Pack.read(at: out) else {
        t.expect(false, "the pack that was just written can be read back")
        return
    }
    let clean = Pack.verify(located)
    t.expect(clean.isSound, "a pack straight out of the assembler verifies")
    t.equal(clean.checked.count, 2, "both components are checked, not just the first")
    t.equal(clean.signedByMaintainer, nil, "an unsigned pack is reported as unsigned, not as forged")
    t.expect(clean.summary.contains("carries no signature"),
             "the summary says plainly that nobody has vouched for it")

    t.suite("Packs — a copy that is not the copy that was published")

    // One byte, in the middle. The size still matches, so only the checksum
    // catches it — which is the case a size check alone would wave through.
    let tampered = Fixture.dir("pack-tampered")
    try? FileManager.default.removeItem(at: tampered)
    try? FileManager.default.copyItem(at: out, to: tampered)
    let victim = tampered.appending(path: "dxvk-2.7.tar.gz")
    if var bytes = try? Data(contentsOf: victim) {
        bytes[32_000] = 0x00
        try? bytes.write(to: victim)
    }
    if let l = try? Pack.read(at: tampered) {
        let v = Pack.verify(l)
        t.expect(!v.isSound, "a single changed byte fails the pack")
        t.expect(v.problems.contains { $0.contains("checksum") },
                 "the reason given is the checksum, not a guess")
        t.expect(v.summary.contains("has not been installed"),
                 "the summary says nothing was installed, which is the thing to know")
    } else {
        t.expect(false, "the tampered pack is still structurally readable")
    }

    // Truncation is the common one — a download interrupted at 60%.
    let short = Fixture.dir("pack-short")
    try? FileManager.default.removeItem(at: short)
    try? FileManager.default.copyItem(at: out, to: short)
    if let bytes = try? Data(contentsOf: short.appending(path: "dxmt-0.80.tar.gz")) {
        try? bytes.prefix(19_000).write(to: short.appending(path: "dxmt-0.80.tar.gz"))
    }
    if let l = try? Pack.read(at: short) {
        let v = Pack.verify(l)
        t.expect(!v.isSound, "a truncated component fails the pack")
        t.expect(v.problems.contains { $0.contains("bytes") },
                 "a truncated file is reported as the wrong size, which names the cause")
    }

    // A component that simply is not there.
    let missing = Fixture.dir("pack-missing")
    try? FileManager.default.removeItem(at: missing)
    try? FileManager.default.copyItem(at: out, to: missing)
    try? FileManager.default.removeItem(at: missing.appending(path: "dxmt-0.80.tar.gz"))
    if let l = try? Pack.read(at: missing) {
        t.expect(!Pack.verify(l).isSound, "a component missing from the directory fails the pack")
    }

    t.suite("Packs — a manifest is a stranger's document")

    // The one that matters. `file` is used to build a path inside the pack, so
    // a manifest that puts `../` in it writes — or reads — outside the
    // directory it was unpacked into.
    let hostile = Fixture.dir("pack-hostile")
    let escaping = """
    {"formatVersion":1,"name":"hostile","createdAt":"2026-01-01T00:00:00Z","createdBy":"x",
     "notes":"","components":[{"piece":"dxvk","version":"1","file":"../../../etc/passwd",
     "bytes":1,"sha256":"00","licence":"x","origin":"x"}]}
    """
    Fixture.write(hostile, Pack.manifestName, Data(escaping.utf8))
    t.throwsError("a manifest naming a path outside the pack is refused") {
        _ = try Pack.read(at: hostile)
    }

    let future = Fixture.dir("pack-future")
    Fixture.write(future, Pack.manifestName, Data("""
    {"formatVersion":99,"name":"later","createdAt":"2026-01-01T00:00:00Z","createdBy":"x",
     "notes":"","components":[{"piece":"dxvk","version":"1","file":"a.tar.gz",
     "bytes":1,"sha256":"00","licence":"x","origin":"x"}]}
    """.utf8))
    t.throwsError("a pack from a newer Decanter is refused rather than half-read") {
        _ = try Pack.read(at: future)
    }

    let unknownPiece = Fixture.dir("pack-unknown-piece")
    Fixture.write(unknownPiece, Pack.manifestName, Data("""
    {"formatVersion":1,"name":"odd","createdAt":"2026-01-01T00:00:00Z","createdBy":"x",
     "notes":"","components":[{"piece":"quantum","version":"1","file":"a.tar.gz",
     "bytes":1,"sha256":"00","licence":"x","origin":"x"}]}
    """.utf8))
    t.throwsError("a component of an unknown kind is refused, not skipped") {
        _ = try Pack.read(at: unknownPiece)
    }

    let empty = Fixture.dir("pack-empty")
    Fixture.write(empty, Pack.manifestName, Data("""
    {"formatVersion":1,"name":"empty","createdAt":"2026-01-01T00:00:00Z","createdBy":"x",
     "notes":"","components":[]}
    """.utf8))
    t.throwsError("a pack listing no components is refused") { _ = try Pack.read(at: empty) }

    t.throwsError("a directory with no manifest is not a pack") {
        _ = try Pack.read(at: src)
    }

    t.suite("Packs — signatures, and keeping two kinds of document apart")

    guard let pair = try? Endorsement.generateKeyPair(),
          let other = try? Endorsement.generateKeyPair() else {
        t.skip("pack signing", "no key pair could be generated")
        return
    }
    let manifestBytes = (try? Data(contentsOf: out.appending(path: Pack.manifestName))) ?? Data()
    let signedBytes = Data("decanter-pack-v1\n".utf8) + manifestBytes
    guard let sig = try? Endorsement.sign(bytes: signedBytes,
                                          privateKeyBase64: pair.privateKeyBase64) else {
        t.skip("pack signing", "the generated key could not sign")
        return
    }
    t.expect(Endorsement.isSignatureValid(sig, over: signedBytes, publicKeyBase64: pair.publicKeyBase64),
             "a manifest signed by a key verifies against that key")
    t.expect(!Endorsement.isSignatureValid(sig, over: signedBytes, publicKeyBase64: other.publicKeyBase64),
             "it does not verify against anybody else's key")
    t.expect(!Endorsement.isSignatureValid(sig, over: manifestBytes, publicKeyBase64: pair.publicKeyBase64),
             "a signature over the prefixed form does not verify over the bare manifest")

    // The reason the prefix exists. One key signs observations and manifests;
    // if the two ever produced the same bytes, a signature over one could be
    // presented as a signature over the other.
    let sigOfObservation = Knowledge.Signature(engine: .unityMono, engineMajor: 6000, bitness: .x64)
    let obs = Knowledge.Observation(signature: sigOfObservation,
                                    setup: .init(runtimeKind: .wine, backend: .dxmt),
                                    worked: true, seeded: false)
    let obsBytes = Endorsement.canonical(obs)
    t.expect(!obsBytes.starts(with: Array("decanter-pack-v1\n".utf8)),
             "an observation's signed bytes can never look like a pack's")
    let obsSig = (try? Endorsement.sign(bytes: obsBytes,
                                        privateKeyBase64: pair.privateKeyBase64)) ?? ""
    t.expect(!Endorsement.isSignatureValid(obsSig, over: signedBytes, publicKeyBase64: pair.publicKeyBase64),
             "an endorsement's signature cannot be replayed as a pack's")

    t.suite("Packs — what may not be redistributed")

    // The situation this exists for, reconstructed: a Wine build made whole by
    // copying libraries out of Apple's Game Porting Toolkit. Legitimate on the
    // Mac it happened on; not ours to hand on; and indistinguishable from a
    // native build by looking at the directory.
    let contaminated = Fixture.dir("runtime-repaired")
    var m = RuntimeRepair.Manifest()
    m.borrows = [
        .init(library: "liborc-0.4.0.dylib", donorID: "gptk-7.7",
              source: URL(filePath: "/x"), destination: URL(filePath: "/y"),
              architectures: ["x86_64"], neededBy: ["lib/libgstaudio-1.0.0.dylib"]),
        .init(library: "libffi.7.dylib", donorID: "gptk-7.7",
              source: URL(filePath: "/x"), destination: URL(filePath: "/y"),
              architectures: ["x86_64"], neededBy: ["lib/libgobject-2.0.0.dylib"]),
    ]
    let enc = JSONEncoder()
    if let data = try? enc.encode(m) {
        Fixture.write(contaminated, "lib/.decanter-borrowed.json", data)
    }
    let store = try? Store(paths: paths)
    if let store {
        let blockers = Pack.redistributionBlockers(runtimeID: "wine-10.0-dxmt",
                                                   root: contaminated, store: store)
        t.equal(blockers.count, 1, "a build repaired from the toolkit reports one blocker, not one per file")
        t.expect(blockers.first?.contains("2 files") == true,
                 "the blocker counts the files rather than leaving it vague")
        t.expect(blockers.first?.contains("Game Porting Toolkit") == true,
                 "the blocker names what the donor was, so it can be acted on")

        // The donor being gone must not make the blocker go away: the record
        // outlives the runtime it came from.
        t.expect(store.state.runtimes.first { $0.id == "gptk-7.7" } == nil,
                 "the donor is not in this fixture's library at all")
        t.expect(!Pack.redistributionBlockers(runtimeID: "x", root: contaminated, store: store).isEmpty,
                 "a blocker survives the donor being removed from the library")

        // A build repaired from another Wine build is fine — that is ordinary
        // LGPL redistribution, and flagging it would make the check noise.
        let fine = Fixture.dir("runtime-repaired-ok")
        var m2 = RuntimeRepair.Manifest()
        m2.borrows = [.init(library: "libz.1.dylib", donorID: "wine-11.0",
                            source: URL(filePath: "/x"), destination: URL(filePath: "/y"),
                            architectures: ["x86_64"], neededBy: ["lib/x.dylib"])]
        if let d2 = try? enc.encode(m2) { Fixture.write(fine, "lib/.decanter-borrowed.json", d2) }
        t.expect(Pack.redistributionBlockers(runtimeID: "wine-11.0", root: fine, store: store).isEmpty,
                 "a build repaired from another Wine build is redistributable")

        let untouched = Fixture.dir("runtime-untouched")
        t.expect(Pack.redistributionBlockers(runtimeID: "clean", root: untouched, store: store).isEmpty,
                 "a build that was never repaired has nothing to declare")
    }

    t.suite("Packs — recognised when they land")

    let acq = Acquisition(paths: paths)
    t.equal(acq.classify(out), .pack(URL(filePath: out.pathKey)),
            "a directory holding a manifest is a pack, whatever it is called")
    let packArchive = Fixture.write(src, "decanter-pack-1.tar.gz", Data(repeating: 7, count: 16))
    t.equal(acq.classify(packArchive), .packArchive(URL(filePath: packArchive.pathKey)),
            "an archive named like a pack is offered as one")

    // Order, and why it matters: whether DXMT can be used here is decided by
    // inspecting the Wine build, so asking before one is pinned gets an answer
    // that is wrong and is then shown to the user as a limitation.
    let shuffled: [Pack.Piece] = [.dxmt, .dxvk, .wine]
    let ordered = shuffled.sorted { Pack.installRank($0) < Pack.installRank($1) }
    t.equal(ordered.first, .wine, "the Wine build is installed before the graphics layers")
    t.equal(ordered.last, .dxmt, "DXMT is installed last, once there is something to host it")

    t.suite("Packs — versions read out of names")

    t.equal(Pack.versionFromName("dxvk-2.7.tar.gz"), "2.7", "a plain release name")
    t.equal(Pack.versionFromName("dxmt-0.80.tar.gz"), "0.80", "a two-part version keeps its zero")
    t.equal(Pack.versionFromName("wine-devel-11.16-osx64.tar.xz"), "11.16",
            "a platform tag is not part of the version")
    t.equal(Pack.versionFromName("something.tar.gz"), "unknown",
            "a name with no version in it says so rather than inventing one")
}

/// The media component, which exists because of one measured situation: the
/// only Wine build on this platform that can host DXMT ships without seven
/// libraries its own GStreamer and FFmpeg chain asks for by name, and the only
/// donor on this Mac was Apple's Game Porting Toolkit — legitimate to use here,
/// not ours to redistribute. That made the one runtime worth publishing the one
/// runtime that could not be published.
func runPackMediaTests(_ t: Harness) {
    t.suite("Packs — the media component")

    t.equal(Pack.installRank(.wine), 0, "the Wine build is pinned first")
    t.expect(Pack.installRank(.media) > Pack.installRank(.wine),
             "media goes into a Wine build, so there has to be one")
    t.expect(Pack.installRank(.media) < Pack.installRank(.dxmt),
             "and it goes in before DXMT is measured, or the build is judged while incomplete")
    t.equal(Pack.Piece.media.label, "Audio and video support",
            "named for what it does, not for the project it came from")

    t.suite("Packs — finding libraries inside an archive")

    // Where they sit is found, not assumed: the GStreamer build these come from
    // puts them at GStreamer.framework/Versions/1.0/lib, and the next archive
    // will put them somewhere else.
    let nested = Fixture.dir("media-nested")
    Fixture.write(nested, "GStreamer.framework/Versions/1.0/lib/libffi.7.dylib", Data([0xCF, 0xFA, 0xED, 0xFE]))
    let found = RuntimeRepair.findLibraryRoot(under: nested)
    t.equal(found?.lastPathComponent, "1.0", "the directory holding lib/ is found several levels down")

    let flat = Fixture.dir("media-flat")
    Fixture.write(flat, "lib/liborc-0.4.0.dylib", Data([0xCF, 0xFA, 0xED, 0xFE]))
    t.equal(RuntimeRepair.findLibraryRoot(under: flat)?.pathKey, flat.pathKey,
            "a flat archive works too")

    // A directory with a lib/ that holds no dylibs is not a library root — a
    // Wine build's lib/wine is full of PE files and would match a looser test.
    let decoy = Fixture.dir("media-decoy")
    Fixture.write(decoy, "lib/readme.txt", Data("no".utf8))
    t.equal(RuntimeRepair.findLibraryRoot(under: decoy), nil,
            "a lib/ with no libraries in it is not a library root")

    t.suite("Packs — the donor is only a donor")

    // The archive is offered to the existing repair rather than copied wholesale.
    // Copying everything would put two versions of the same library inside one
    // Wine, which is the failure `repair` was written to avoid, and would make
    // the result impossible to undo cleanly.
    let donor = RuntimeRepair.donor(unpackedAt: flat, id: "pack-media")
    t.equal(donor.id, "pack-media", "the donor is named for what it is")
    t.equal(donor.root.pathKey, flat.pathKey, "and points at the unpacked archive")
    t.expect(donor.backends.isEmpty, "it offers no graphics backends — it is not a runtime")
    t.expect(!donor.supports32Bit, "and claims no capability it cannot demonstrate")
}
