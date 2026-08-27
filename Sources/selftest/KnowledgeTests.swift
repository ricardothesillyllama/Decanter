import Foundation
import DecanterKit

/// The knowledge base keys on a situation, never on a game. These check the
/// two things that makes true: the fallback ladder that keeps a specific key
/// useful, and the export that carries no identity.
func runKnowledgeTests(_ t: Harness) {

    func sig(_ engine: GameEngineKind = .unityMono, major: Int? = 6000,
             _ bits: Bitness = .x64, video: Bool = false, d3d12: Bool = false,
             chip: MachineClass.Chip = .m2, os: Int? = 26) -> Knowledge.Signature {
        .init(engine: engine, engineMajor: major, bitness: bits,
              usesVideo: video, usesD3D12: d3d12, chip: chip, macOSMajor: os)
    }
    let dxvk = Knowledge.Setup(runtimeKind: .wine, backend: .dxvk, layerVersion: "1.10.3")
    let dxmt = Knowledge.Setup(runtimeKind: .wine, backend: .dxmt, layerVersion: "0.80")

    // MARK: The ladder
    t.suite("a situation matches more loosely as the ladder is descended")
    let here = sig()
    let otherMac = sig(chip: .m4, os: 27)
    let otherShape = sig(video: true)
    let otherGeneration = sig(major: 2022)
    let otherEngine = sig(.unreal)

    t.expect(Knowledge.Level.thisMac.matches(here, here), "an identical situation matches at the top")
    t.expect(!Knowledge.Level.thisMac.matches(here, otherMac), "a different Mac does not match at the top")
    t.expect(!Knowledge.Level.thisChip.matches(here, otherMac), "nor at chip level")
    t.expect(Knowledge.Level.anyMac.matches(here, otherMac), "but does once the machine is dropped")
    t.expect(!Knowledge.Level.anyMac.matches(here, otherShape), "video still separates them there")
    t.expect(!Knowledge.Level.sameShape.matches(here, otherShape), "…and at shape level")
    t.expect(Knowledge.Level.sameGeneration.matches(here, otherShape), "…but not once shape is dropped")
    t.expect(!Knowledge.Level.sameGeneration.matches(here, otherGeneration),
             "Unity 6 and Unity 2022 are never the same generation")
    t.expect(!Knowledge.Level.sameEngine.matches(here, otherGeneration),
             "…and not even at the broadest level: a claim about Unity 2022 is about Unity 2022")

    // Matching is asymmetric, and that is the point: how specific an
    // observation is limits how widely it applies. A general claim about Unity
    // answers a question about Unity 6; a claim about Unity 6 does not answer a
    // question about Unity generally.
    let general = sig(.unityMono, major: nil, .x64, chip: .unknown, os: nil)
    t.expect(Knowledge.Level.sameEngine.matches(here, general),
             "a claim with no generation answers a question about one")
    t.expect(!Knowledge.Level.sameEngine.matches(general, sig(major: 6000, chip: .unknown, os: nil)),
             "…but a claim about one generation does not answer a question about all of them")
    for level in Knowledge.Level.allCases {
        t.expect(!level.matches(here, otherEngine), "\(level.label): a different engine never matches")
    }
    // An unknown chip must not silently match every chip.
    t.expect(!Knowledge.Level.thisChip.matches(sig(chip: .unknown), sig(chip: .unknown)),
             "an unknown chip does not match itself — that would be a fact nobody established")

    // MARK: Answering
    t.suite("an answer says how closely it matched")
    var k = Knowledge()
    let a = UUID(), b = UUID(), asking = UUID()
    k.recordSuccess(signature: here, gameID: a, setup: dxvk)
    guard let exact = k.best(for: here) else { t.expect(false, "an exact match answers"); return }
    t.equal(exact.level, .thisMac, "an identical situation answers at the top of the ladder")
    t.equal(exact.setup, dxvk, "…with the setup that worked")
    t.equal(exact.confirmations, 1, "…and one confirmation")

    // The same knowledge, asked from a different Mac, must still answer — just
    // more loosely, and it must say so.
    guard let loose = k.best(for: otherMac) else { t.expect(false, "a different Mac still gets an answer"); return }
    t.equal(loose.level, .anyMac, "…answered from a broader level")
    t.expect(loose.provenance.contains("any Mac"), "and the provenance names that level")
    t.expect(exact.provenance != loose.provenance, "the two do not read the same")

    t.suite("a game does not get to vouch for itself")
    var solo = Knowledge()
    solo.recordSuccess(signature: here, gameID: asking, setup: dxvk)
    t.expect(solo.best(for: here, excluding: asking) == nil,
             "the only confirmation being this game is not knowledge, it is an echo")
    solo.recordSuccess(signature: here, gameID: b, setup: dxvk)
    t.equal(solo.best(for: here, excluding: asking)?.confirmations, 1,
            "another game confirming does count")

    t.suite("something known to fail is never recommended")
    var mixed = Knowledge()
    mixed.recordFailure(signature: here, gameID: a, setup: dxvk, failure: .noDevice)
    mixed.recordSuccess(signature: here, gameID: b, setup: dxmt)
    t.equal(mixed.best(for: here)?.setup, dxmt, "the setup that worked is chosen")
    let bad = mixed.knownBad(for: here)
    t.equal(bad.first?.setup, dxvk, "the failing one is reported as known-bad")
    t.equal(bad.first?.failure, .noDevice, "…with the reason it failed")

    t.suite("a later success replaces an earlier failure for the same game")
    var revised = Knowledge()
    revised.recordFailure(signature: here, gameID: a, setup: dxvk, failure: .noWindow)
    revised.recordSuccess(signature: here, gameID: a, setup: dxvk)
    t.equal(revised.observations.filter { $0.gameID == a && $0.setup == dxvk }.count, 1,
            "one game and one setup leave one observation, not one of each")
    t.expect(revised.observations.first?.worked == true, "…and it is the later one")

    // MARK: Unity 6's baseline
    t.suite("Unity 6 ships as measured failures, not as silence")
    let seeded = Knowledge.seeded()
    let u6 = sig(.unityMono, major: 6000, .x64, chip: .unknown, os: nil)
    let u6bad = seeded.knownBad(for: u6)
    t.expect(u6bad.count >= 4, "every backend tried on Unity 6 is recorded as failing (got \(u6bad.count))")
    t.expect(u6bad.contains { $0.setup.backend == .dxmt && $0.failure == .missingInterface },
             "DXMT is recorded as reaching a device and then missing an interface")
    t.expect(u6bad.contains { $0.setup.backend == .dxvk && $0.failure == .noDevice },
             "DXVK is recorded as never getting a device at all")
    t.expect(seeded.best(for: u6) == nil,
             "and nothing is recommended for Unity 6, because nothing worked")

    // Unity 2022 is a different generation and must be unaffected by all that.
    let u2022 = sig(.unityMono, major: 2022, .x64, chip: .unknown, os: nil)
    t.expect(seeded.best(for: u2022) != nil, "Unity 2022 still gets an answer")

    // MARK: Export
    t.suite("the export carries situations, never identity")
    var lib = Knowledge.seeded()
    lib.recordSuccess(signature: here, gameID: a, setup: dxvk)
    lib.recordSuccess(signature: here, gameID: b, setup: dxvk)
    let out = lib.exportable()
    t.expect(!out.observations.isEmpty, "there is something to export")
    t.equal(out.observations.count, 1,
            "two local games agreeing collapse to one row — the count is about this library, not the world")
    let encoded = try? JSONEncoder().encode(out)
    let text = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    t.expect(!text.isEmpty, "the export encodes")
    t.expect(!text.contains(a.uuidString) && !text.contains(b.uuidString),
             "no local game id survives the export")
    t.expect(!text.lowercased().contains("gameid"), "…and there is no field for one")
    t.expect(!text.contains("\"seeded\""), "seeds are not exported — the recipient already has them")

    // MARK: Migration
    t.suite("a pre-0.4 knowledge file is carried across, not discarded")
    let legacyGame = UUID()
    let legacy = """
    {"entries":{"unityMono|x64|false|false":{"runtimeKind":"wine","backend":"dxvk",
     "confirmedGames":["\(legacyGame.uuidString)"],"failedGames":[],"seeded":false}}}
    """
    guard let migrated = try? JSONDecoder().decode(Knowledge.self, from: Data(legacy.utf8)) else {
        t.expect(false, "a pre-0.4 file decodes"); return
    }
    t.equal(migrated.observations.count, 1, "the old entry became an observation")
    t.equal(migrated.observations.first?.setup.backend, .dxvk, "…keeping what worked")
    t.equal(migrated.observations.first?.signature.chip, .unknown,
            "…with the machine left unknown rather than invented")
    let old = sig(.unityMono, major: nil, .x64, chip: .unknown, os: nil)
    t.expect(migrated.best(for: old) != nil, "and it still answers")

    t.suite("knowledge survives a round trip")
    let round = try? JSONDecoder().decode(Knowledge.self, from: JSONEncoder().encode(lib))
    t.equal(round?.observations.count, lib.observations.count, "every observation comes back")
}
