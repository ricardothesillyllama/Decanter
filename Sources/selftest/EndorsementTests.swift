import Foundation
import DecanterKit

/// Endorsement is the one place Decanter grants something that cannot be
/// obtained by reading the source, so the properties worth proving are the ones
/// that keep it honest: it cannot be forged, it cannot be edited after the fact,
/// it carries no name, and it never overrules what the person's own Mac has
/// actually seen.
func runEndorsementTests(_ t: Harness) {
    let fm = FileManager.default
    let tmp = URL(filePath: NSTemporaryDirectory())
        .appending(path: "decanter-endorse-\(UUID().uuidString)")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    func sig(chip: MachineClass.Chip = .m2, engineMajor: Int? = 6,
             engine: GameEngineKind = .unityIL2CPP) -> Knowledge.Signature {
        var s = Knowledge.Signature(engine: engine, engineMajor: engineMajor, bitness: .x64,
                                    usesVideo: false, usesD3D12: false,
                                    chip: chip, macOSMajor: 26)
        s.engineMajor = engineMajor
        return s
    }
    let dxmt = Knowledge.Setup(runtimeKind: .wine, backend: .dxmt, layerVersion: "0.3")
    let dxvk = Knowledge.Setup(runtimeKind: .wine, backend: .dxvk, layerVersion: "1.10.3")

    t.suite("what an endorsement covers")
    let a = Knowledge.Observation(signature: sig(), setup: dxmt, worked: true)
    var b = a
    b.note = "expect a black frame on first launch"
    t.expect(Endorsement.canonical(a) != Endorsement.canonical(b),
             "the note is part of what is signed, so editing it cannot go unnoticed")
    var c = a
    c.worked = false
    t.expect(Endorsement.canonical(a) != Endorsement.canonical(c),
             "so is whether it worked")
    var d = a
    d.signature = sig(chip: .m4)
    t.expect(Endorsement.canonical(a) != Endorsement.canonical(d),
             "and the machine it was run on — an endorsement is a specific claim")
    var e = a
    e.gameID = UUID()
    t.equal(Endorsement.canonical(a), Endorsement.canonical(e),
            "but not which local game it came from, which never leaves this Mac")
    t.equal(Endorsement.canonical(a), Endorsement.canonical(a),
            "and the same row always produces the same bytes")
    let text = String(decoding: Endorsement.canonical(b), as: UTF8.self)
    t.expect(!text.contains("gameID") && !text.lowercased().contains("richard"),
             "nothing in the signed form names a person or a game")

    t.suite("only a key holder can vouch for anything")
    // Run against a key pair made here rather than the maintainer's, so the
    // suite proves the mechanism without needing a secret to exist.
    guard let pair = try? Endorsement.generateKeyPair(),
          let priv = Data(base64Encoded: pair.privateKeyBase64),
          let pub = Data(base64Encoded: pair.publicKeyBase64) else {
        t.expect(false, "a key pair can be generated"); return
    }
    t.expect(priv.count == 32 && pub.count == 32, "a key pair is generated")
    t.expect(pair.privateKeyBase64 != pair.publicKeyBase64,
             "and the half that ships is not the half that signs")
    let other = try? Endorsement.generateKeyPair()
    t.expect(other?.publicKeyBase64 != pair.publicKeyBase64,
             "two key pairs are not the same key pair")

    t.suite("a row that is not vouched for is simply not vouched for")
    t.equal(Endorsement.isVerified(a), false,
            "a row with no signature does not verify")
    var forged = a
    forged.endorsement = Data("not a signature".utf8).base64EncodedString()
    t.equal(Endorsement.isVerified(forged), false,
            "and neither does one with bytes written into the field by hand")
    t.equal(Endorsement.tier(of: forged, seenLocally: false), .community,
            "an unverifiable row sits at the shared tier, not the verified one")
    t.equal(Endorsement.tier(of: a, seenLocally: true), .local,
            "and what this Mac saw itself is its own tier")
    t.expect(Endorsement.Tier.local > Endorsement.Tier.verified,
             "what this Mac saw outranks what someone vouched for")
    t.expect(Endorsement.Tier.verified > Endorsement.Tier.community,
             "which in turn outranks what was merely shared")

    t.suite("what this Mac has seen is never overruled")
    // The rule chosen for 0.6: an endorsement outranks a generalisation, and
    // loses to an observation about this machine.
    var k = Knowledge()
    k.record(.init(signature: sig(), setup: dxvk, worked: true, gameID: UUID()))
    let localSpecific = k.best(for: sig())
    t.equal(localSpecific?.setup, dxvk,
            "with only a local observation, that is the answer")
    t.equal(localSpecific?.level, .thisMac, "matched at this Mac")
    t.equal(localSpecific?.alsoConsidered == nil, true,
            "and nothing is displaced")

    t.suite("an endorsement outranks a generalisation, and shows what it displaced")
    // A local observation that only matches loosely — a different chip, so it
    // cannot answer at "this Mac" or "this chip".
    var loose = Knowledge()
    loose.record(.init(signature: sig(chip: .m1), setup: dxvk, worked: true, gameID: UUID()))
    let beforeEndorsing = loose.best(for: sig())
    t.expect(beforeEndorsing?.setup == dxvk,
             "the loose local answer stands while nothing is endorsed")
    t.expect((beforeEndorsing?.level ?? .thisMac) > .thisChip,
             "and it is honest that the match was a loose one")

    // A signature made with the pair generated above, checked against that
    // pair's public half. The real path uses whatever key the build carries;
    // injecting one here proves the mechanism without a secret having to exist.
    func signedWith(_ o: Knowledge.Observation) -> Knowledge.Observation {
        var row = o
        row.endorsement = try? Endorsement.sign(o, privateKeyBase64: pair.privateKeyBase64)
        return row
    }
    let checkOurs: (Knowledge.Observation) -> Bool = {
        Endorsement.isVerified($0, publicKeyBase64: pair.publicKeyBase64)
    }

    t.suite("an endorsement displaces a generalisation, and shows what it displaced")
    var endorsed = loose
    // Recorded about a different chip, so it cannot answer at "this Mac" on its
    // own merits. Being lifted above a generalisation is exactly the thing the
    // endorsement is doing, so nothing else may be doing it.
    endorsed.record(signedWith(.init(signature: sig(chip: .m1), setup: dxmt, worked: true,
                                     imported: true,
                                     note: "expect a black frame on the first launch")))
    let winner = endorsed.best(for: sig(), verified: checkOurs)
    t.equal(winner?.setup, dxmt, "the endorsed setup is the answer")
    t.equal(winner?.tier, .verified, "and is marked as vouched for rather than seen here")
    t.equal(winner?.alsoConsidered?.setup, dxvk,
            "what this Mac had worked out for itself is offered second, not dropped")
    t.expect(winner?.note != nil, "and the note the endorser attached comes with it")

    t.suite("an endorsement that matches tightly is still an endorsement")
    // It is returned by the ordinary walk and never reaches the endorsement
    // branch, so the label has to be right on that path too.
    var tight = Knowledge()
    tight.record(signedWith(.init(signature: sig(), setup: dxmt, worked: true, imported: true)))
    t.equal(tight.best(for: sig(), verified: checkOurs)?.tier, .verified,
            "and is labelled as vouched for, not as something a stranger shared")
    var mine = Knowledge()
    mine.record(.init(signature: sig(), setup: dxmt, worked: true, gameID: UUID()))
    t.equal(mine.best(for: sig(), verified: checkOurs)?.tier, .local,
            "while something this Mac ran itself outranks both labels")

    t.suite("an endorsement that cannot be checked changes nothing")
    var pretend = loose
    // A different chip, so this row cannot answer at "this Mac" or "this chip"
    // on its own merits — the only thing that could lift it is an endorsement.
    var unsigned = Knowledge.Observation(signature: sig(chip: .m1), setup: dxmt, worked: true)
    unsigned.endorsement = "AAAA"
    pretend.record(unsigned)
    t.equal(pretend.best(for: sig(), verified: checkOurs)?.setup, dxvk,
            "a row claiming endorsement without a valid signature does not displace anything")

    var tampered = loose
    var edited = signedWith(.init(signature: sig(chip: .m1), setup: dxmt, worked: true,
                                  note: "as endorsed"))
    edited.note = "changed after the fact"
    tampered.record(edited)
    t.equal(tampered.best(for: sig(), verified: checkOurs)?.setup, dxvk,
            "and neither does one whose note was edited after it was signed")

    t.suite("a stranger's bad news does not rule anything out")
    // A failure this Mac saw rules a setup out at once. One that arrived in
    // someone's export does not, or a single broken install elsewhere takes an
    // option away from everyone who imports it. Corroboration is not the escape
    // hatch — the export format never accumulates two rows for one situation —
    // so endorsement is the only thing that promotes such a failure.
    var imported = Knowledge()
    imported.record(.init(signature: sig(), setup: dxvk, worked: true, gameID: UUID()))
    imported.record(.init(signature: sig(), setup: dxvk, worked: false,
                          failure: .noDevice, imported: true))
    t.equal(imported.best(for: sig(), verified: checkOurs)?.setup, dxvk,
            "an imported failure does not veto a setup this Mac has seen work")

    var endorsedFail = Knowledge()
    endorsedFail.record(.init(signature: sig(), setup: dxvk, worked: true, gameID: UUID()))
    endorsedFail.record(signedWith(.init(signature: sig(), setup: dxvk, worked: false,
                                         failure: .noDevice, imported: true)))
    t.expect(endorsedFail.best(for: sig(), verified: checkOurs)?.setup != dxvk,
             "but an endorsed one does — which is the whole of what the tier grants")

    var localFail = Knowledge()
    localFail.record(.init(signature: sig(), setup: dxvk, worked: true, gameID: UUID()))
    localFail.record(.init(signature: sig(), setup: dxvk, worked: false,
                           failure: .noDevice, gameID: UUID()))
    t.expect(localFail.best(for: sig())?.setup != dxvk,
             "while a single failure seen on this Mac rules it out immediately")

    t.suite("a measurement outranks something Decanter shipped an opinion about")
    // The fault this replaces: a game confirmed working on this Mac, and
    // endorsed, went on being described as "not known to run here" because the
    // built-in claim about its engine answered before the record of it working
    // was ever consulted.
    var settled = Knowledge()
    let ownGame = UUID()
    settled.record(.init(signature: sig(), setup: dxmt, worked: true, gameID: ownGame))
    let answer = settled.best(for: sig(), verified: checkOurs)
    t.equal(answer?.setup, dxmt, "a confirmed local run answers for this situation")
    t.expect((answer?.confirmations ?? 0) > 0 || answer?.tier == .local,
             "and it counts as something that happened, not something assumed")

    t.suite("a game does not corroborate itself, endorsed or not")
    var solo = Knowledge()
    solo.record(signedWith(.init(signature: sig(), setup: dxmt, worked: true,
                                 gameID: ownGame, imported: true)))
    let selfAnswer = solo.best(for: sig(), excluding: ownGame, verified: checkOurs)
    t.equal(selfAnswer?.tier, .verified, "the endorsement still answers")
    t.equal(selfAnswer?.confirmations, 0,
            "but the game being asked about is not counted as a game that agreed")

    t.suite("an endorsement survives being exported and imported")
    // An endorsement that stopped at the export boundary would arrive as an
    // ordinary shared row, which is the one thing it is not.
    var source = Knowledge()
    source.record(signedWith(.init(signature: sig(), setup: dxmt, worked: true,
                                   gameID: UUID(), note: "expect a black frame first")))
    let shipped = source.exportable()
    t.expect(shipped.observations.first?.endorsement != nil,
             "the signature is carried in the export")
    t.expect(shipped.observations.allSatisfy { $0.signature.chip != .unknown },
             "alongside the situation it describes")
    var destination = Knowledge()
    _ = destination.merge(shipped, verified: checkOurs)
    let arrived = destination.observations.first
    t.expect(arrived?.imported == true, "the row arrives marked as somebody else's")
    t.equal(arrived?.gameID == nil, true, "with no game id, as before")
    t.expect(arrived.map { Endorsement.isVerified($0, publicKeyBase64: pair.publicKeyBase64) } == true,
             "and its signature still checks out on the other side")
    t.equal(arrived?.note, "expect a black frame first",
            "so the note it was signed with is kept rather than dropped")

    t.suite("an unsigned note is still dropped on arrival")
    // The one free-text field in the format, and the obvious place a game title
    // would leak in. Prose is allowed back only when a signature vouches for it.
    var chatty = Knowledge()
    chatty.record(.init(signature: sig(), setup: dxvk, worked: true, gameID: UUID(),
                        note: "played MyGame 2 for six hours"))
    var elsewhere = Knowledge()
    _ = elsewhere.merge(chatty.exportable(), verified: checkOurs)
    t.equal(elsewhere.observations.first?.note, nil,
            "an unsigned note does not survive the crossing")
    t.equal(elsewhere.observations.first?.endorsement, nil,
            "and neither does an endorsement field that proves nothing")

    var forgedNote = source.exportable()
    forgedNote.observations[0].note = "edited in transit"
    var wary = Knowledge()
    _ = wary.merge(forgedNote, verified: checkOurs)
    t.equal(wary.observations.first?.note, nil,
            "a signed note edited in transit is dropped, because the signature covers it")

    t.suite("provenance says where an answer came from, not how it feels")
    t.equal(Engine.Provenance.inferred.label, "worked out from the files",
            "a rule with nothing behind it says so")
    t.expect(Engine.Provenance.allCases.allSatisfy { !$0.label.isEmpty && !$0.detail.isEmpty },
             "every provenance can be read both short and long")
    t.expect(Engine.Provenance.allCases.allSatisfy { $0.detail.count > $0.label.count },
             "and the long form is the fuller of the two")
    let banned = ["dylib", "mach-o", "@rpath", "ed25519", "signature", "curve25519"]
    t.expect(Engine.Provenance.allCases.allSatisfy { p in
                !banned.contains { p.label.lowercased().contains($0) || p.detail.lowercased().contains($0) }
             },
             "and neither form asks the reader to know how any of it works")
}


/// The most ordinary thing a person does to an endorsed setup: play the game
/// again and confirm it still works. Until 0.6.1 that erased the endorsement.
func runEndorsementSurvivalTests(_ t: Harness) {
    t.suite("Endorsement survives being re-recorded")

    let pair = try? Endorsement.generateKeyPair()
    guard let pair else { t.expect(false, "a key pair can be made"); return }

    let sig = Knowledge.Signature(engine: .unityMono, engineMajor: 6000, bitness: .x64,
                                  usesD3D12: true)
    let setup = Knowledge.Setup(runtimeKind: .wine, backend: .dxmt, layerVersion: "0.80")
    let gameID = UUID()

    var k = Knowledge()
    var endorsed = Knowledge.Observation(signature: sig, setup: setup, worked: true,
                                         gameID: gameID, note: "runs well on Metal")
    endorsed.endorsement = try? Endorsement.sign(endorsed, privateKeyBase64: pair.privateKeyBase64)
    k.record(endorsed)
    t.expect(Endorsement.isVerified(k.observations[0], publicKeyBase64: pair.publicKeyBase64),
             "the endorsed row verifies to begin with")

    // What `worked`, the app's post-launch record, and `decanter worked` all do:
    // build a bare observation and record it.
    k.recordSuccess(signature: sig, gameID: gameID, setup: setup)
    t.equal(k.observations.count, 1, "confirming again replaces the row rather than adding one")
    t.expect(k.observations[0].endorsement?.isEmpty == false,
             "confirming a setup that already worked does not throw the endorsement away")
    t.equal(k.observations[0].note, "runs well on Metal",
             "and keeps the note, which is part of what was signed")
    t.expect(Endorsement.isVerified(k.observations[0], publicKeyBase64: pair.publicKeyBase64),
             "the carried-forward endorsement still verifies")

    // A changed outcome is a different claim. Nobody signed for that, so the
    // endorsement has to go — keeping it would leave a signature that fails to
    // verify, which reads as tampering rather than as an honest change.
    k.recordFailure(signature: sig, gameID: gameID, setup: setup, failure: .noDevice)
    t.expect(k.observations[0].endorsement == nil,
             "a setup that has since failed does not keep the endorsement for success")

    // And a different game reaching the same conclusion is its own row, so it
    // cannot displace anything.
    var k2 = Knowledge()
    k2.record(endorsed)
    k2.recordSuccess(signature: sig, gameID: UUID(), setup: setup)
    t.equal(k2.observations.count, 2, "another game agreeing adds a row instead of replacing one")
    t.expect(k2.observations.contains { $0.endorsement?.isEmpty == false },
             "and leaves the endorsed row alone")
}
