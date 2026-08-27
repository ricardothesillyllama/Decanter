import Foundation

/// What has actually worked — and what has actually failed — remembered across
/// games.
///
/// The unit of knowledge here is a *situation*, not a game. "Unity 6 on an M2
/// under Wine 11 with DXMT 0.80 fails to create an ID3D11Fence" is complete and
/// actionable; the title of the game it was seen on adds nothing anyone can act
/// on. So no title is ever recorded, and every field of a situation is drawn
/// from a closed vocabulary — a field rich enough to distinguish one game *is*
/// a name, and one anybody holding a copy could recompute.
///
/// Adding the machine axes makes buckets fragment: exact matches get rare fast.
/// That is handled by storing every observation at full specificity and
/// *querying* from most specific to least, reporting which level answered,
/// rather than by keeping the key coarse.
public struct Knowledge: Codable, Sendable {

    // MARK: - Situation

    /// The circumstances, with no room for a name.
    ///
    /// Every field is an enum, a bool, or a small bounded integer. That is a
    /// rule, not a coincidence: a free-form string is how identifying detail
    /// arrives without anyone deciding to let it in, and `check-rules.sh`
    /// fails the build if a stored one appears here.
    public struct Signature: Codable, Hashable, Sendable {
        // --- the game ---
        public var engine: GameEngineKind
        /// 6000 for Unity 6, 2022 for Unity 2022, nil when unknown. A version
        /// generation, never a build string.
        public var engineMajor: Int?
        public var bitness: Bitness
        public var usesVideo: Bool
        public var usesD3D12: Bool
        // --- the Mac ---
        public var chip: MachineClass.Chip
        public var macOSMajor: Int?

        public init(_ d: DetectionResult, on machine: MachineClass = .current()) {
            engine = d.engine
            engineMajor = Self.major(of: d.engineVersion)
            bitness = d.bitness
            usesVideo = d.usesVideo
            // The Agility SDK shipping beside the game is the evidence that
            // D3D12 is really in the renderer list; the import alone only dates
            // the engine.
            usesD3D12 = d.shipsD3D12Runtime || d.graphicsAPIs.contains("d3d12.dll")
            chip = machine.chip
            macOSMajor = machine.macOSMajor
        }

        public init(engine: GameEngineKind = .generic, engineMajor: Int? = nil,
                    bitness: Bitness = .unknown, usesVideo: Bool = false, usesD3D12: Bool = false,
                    chip: MachineClass.Chip = .unknown, macOSMajor: Int? = nil) {
            self.engine = engine; self.engineMajor = engineMajor; self.bitness = bitness
            self.usesVideo = usesVideo; self.usesD3D12 = usesD3D12
            self.chip = chip; self.macOSMajor = macOSMajor
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            engine = (try? c.decode(GameEngineKind.self, forKey: .engine)) ?? .generic
            engineMajor = try? c.decodeIfPresent(Int.self, forKey: .engineMajor)
            bitness = (try? c.decode(Bitness.self, forKey: .bitness)) ?? .unknown
            usesVideo = (try? c.decode(Bool.self, forKey: .usesVideo)) ?? false
            usesD3D12 = (try? c.decode(Bool.self, forKey: .usesD3D12)) ?? false
            chip = (try? c.decode(MachineClass.Chip.self, forKey: .chip)) ?? .unknown
            macOSMajor = try? c.decodeIfPresent(Int.self, forKey: .macOSMajor)
        }

        /// "6000.2.0b7" -> 6000. Only the generation, which is the part that
        /// changes the answer.
        static func major(of version: String?) -> Int? {
            guard let v = version, let first = v.split(separator: ".").first else { return nil }
            return Int(first)
        }

        public var engineLabel: String {
            engineMajor.map { "\(engine.label) \($0)" } ?? engine.label
        }

        public var label: String {
            var s = "\(engineLabel), \(bitness.label)"
            if usesVideo { s += ", video" }
            if usesD3D12 { s += ", D3D12" }
            if chip != .unknown { s += " · \(chip.label)" }
            if let os = macOSMajor { s += " · macOS \(os)" }
            return s
        }
    }

    // MARK: - The ladder

    /// How specific a match is, from "this exact setup on this exact Mac" down
    /// to "games on this engine".
    ///
    /// Ordered so the first axis dropped is the one least likely to change the
    /// answer. macOS and chip go before the engine generation because Unity 6
    /// versus Unity 2022 is the entire story and the chip rarely is.
    public enum Level: Int, Codable, Sendable, CaseIterable, Comparable {
        case thisMac = 0, thisChip, anyMac, sameShape, sameGeneration, sameEngine

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .thisMac:        "this setup, on this Mac"
            case .thisChip:       "this setup, on this chip"
            case .anyMac:         "this kind of game, any Mac"
            case .sameShape:      "games that look like this"
            case .sameGeneration: "this engine generation"
            case .sameEngine:     "this engine"
            }
        }

        /// Whether a query `a` is answered by a stored observation `b` at this
        /// level. Asymmetric on purpose: how specific the *observation* is
        /// limits how widely it applies, whatever the level.
        public func matches(_ a: Signature, _ b: Signature) -> Bool {
            guard a.engine == b.engine, a.bitness == b.bitness else { return false }
            // Engine generation is a qualifier on the claim, not merely an axis
            // to relax. An observation recorded about Unity 6 is *about Unity 6*
            // — letting the broadest level drop it made Unity 6's measured
            // failures veto everything for Unity 2022, which they say nothing
            // about. An observation with no generation is a general claim and
            // still answers for any of them.
            if let stored = b.engineMajor, stored != a.engineMajor { return false }
            if self <= .sameGeneration, a.engineMajor != b.engineMajor { return false }
            if self <= .sameShape, a.usesVideo != b.usesVideo { return false }
            if self <= .anyMac, a.usesD3D12 != b.usesD3D12 { return false }
            if self <= .thisChip {
                guard a.chip != .unknown, a.chip == b.chip else { return false }
            }
            if self <= .thisMac {
                guard let x = a.macOSMajor, let y = b.macOSMajor, x == y else { return false }
            }
            return true
        }
    }

    // MARK: - Observations

    /// One setup, as it was actually configured.
    public struct Setup: Codable, Hashable, Sendable {
        public var runtimeKind: RuntimeKind
        public var backend: GraphicsBackend
        /// The graphics layer's version, when it has one. DXVK 1.10.3 and
        /// DXVK 2.x are not the same answer, and neither are DXMT releases —
        /// recording them as one is how a knowledge base learns something
        /// untrue and then keeps repeating it.
        public var layerVersion: String?

        public init(runtimeKind: RuntimeKind, backend: GraphicsBackend, layerVersion: String? = nil) {
            self.runtimeKind = runtimeKind; self.backend = backend; self.layerVersion = layerVersion
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeKind = (try? c.decode(RuntimeKind.self, forKey: .runtimeKind)) ?? .wine
            backend = (try? c.decode(GraphicsBackend.self, forKey: .backend)) ?? .dxvk
            layerVersion = try? c.decodeIfPresent(String.self, forKey: .layerVersion)
        }

        public var label: String {
            let rt = runtimeKind == .gptk ? "GPTK" : "Wine"
            return layerVersion.map { "\(rt) + \(backend.label) \($0)" } ?? "\(rt) + \(backend.label)"
        }
    }

    /// Why something failed, in a closed vocabulary. Free text would be the one
    /// place a game could be named, so there is no free text.
    public enum Failure: String, Codable, Sendable, CaseIterable {
        case noDevice            // the graphics layer could not create a device
        case missingInterface    // a device, but an interface the engine needs is absent
        case noWindow            // ran, drew nothing
        case crashedEarly        // died before a window
        case unspecified

        public var label: String {
            switch self {
            case .noDevice:         "no graphics device"
            case .missingInterface: "a required graphics interface is missing"
            case .noWindow:         "ran but drew nothing"
            case .crashedEarly:     "crashed before opening a window"
            case .unspecified:      "did not work"
            }
        }
    }

    public struct Observation: Codable, Sendable, Hashable {
        public var signature: Signature
        public var setup: Setup
        public var worked: Bool
        public var failure: Failure?
        /// Which game this came from, as a local id — never a title, and
        /// meaningless on any other machine. It exists so one game confirming
        /// twice does not read as two games agreeing, and it is dropped on
        /// export.
        public var gameID: UUID?
        /// True for knowledge Decanter shipped with rather than saw here.
        public var seeded: Bool = false
        public var note: String?

        public init(signature: Signature, setup: Setup, worked: Bool,
                    failure: Failure? = nil, gameID: UUID? = nil,
                    seeded: Bool = false, note: String? = nil) {
            self.signature = signature; self.setup = setup; self.worked = worked
            self.failure = failure; self.gameID = gameID; self.seeded = seeded; self.note = note
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            signature = try c.decode(Signature.self, forKey: .signature)
            setup = try c.decode(Setup.self, forKey: .setup)
            worked = (try? c.decode(Bool.self, forKey: .worked)) ?? false
            failure = try? c.decodeIfPresent(Failure.self, forKey: .failure)
            gameID = try? c.decodeIfPresent(UUID.self, forKey: .gameID)
            seeded = (try? c.decode(Bool.self, forKey: .seeded)) ?? false
            note = try? c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    public var observations: [Observation] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observations = (try? c.decode([Observation].self, forKey: .observations)) ?? []
        // A store written before observations existed kept a dictionary of
        // entries with no machine axes. Those are still true, just less
        // specific, so they are carried across with the machine left unknown
        // rather than invented — they match from `anyMac` down.
        if observations.isEmpty, let legacy = try? c.decode([String: LegacyEntry].self, forKey: .entries) {
            for (key, e) in legacy {
                guard let sig = LegacyEntry.signature(fromKey: key) else { continue }
                let setup = Setup(runtimeKind: e.runtimeKind, backend: e.backend)
                if e.confirmedGames.isEmpty {
                    observations.append(.init(signature: sig, setup: setup, worked: true,
                                              seeded: e.seeded, note: e.note))
                }
                for id in e.confirmedGames {
                    observations.append(.init(signature: sig, setup: setup, worked: true,
                                              gameID: id, seeded: e.seeded, note: e.note))
                }
                for id in e.failedGames {
                    observations.append(.init(signature: sig, setup: setup, worked: false,
                                              failure: .unspecified, gameID: id))
                }
            }
        }
    }

    /// The shape of the pre-0.4 store, read once so nothing learned is lost.
    struct LegacyEntry: Codable {
        var runtimeKind: RuntimeKind
        var backend: GraphicsBackend
        var confirmedGames: Set<UUID> = []
        var failedGames: Set<UUID> = []
        var seeded: Bool = false
        var note: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeKind = try c.decode(RuntimeKind.self, forKey: .runtimeKind)
            backend = try c.decode(GraphicsBackend.self, forKey: .backend)
            confirmedGames = (try? c.decode(Set<UUID>.self, forKey: .confirmedGames)) ?? []
            failedGames = (try? c.decode(Set<UUID>.self, forKey: .failedGames)) ?? []
            seeded = (try? c.decode(Bool.self, forKey: .seeded)) ?? false
            note = try? c.decodeIfPresent(String.self, forKey: .note)
        }

        static func signature(fromKey key: String) -> Signature? {
            let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 4, let engine = GameEngineKind(rawValue: p[0]),
                  let bits = Bitness(rawValue: p[1]) else { return nil }
            return Signature(engine: engine, bitness: bits,
                             usesVideo: p[2] == "true", usesD3D12: p[3] == "true")
        }
    }

    /// Only `observations` is written. `entries` exists solely so a pre-0.4
    /// file can be read once and converted; writing it back would keep the old
    /// shape alive forever.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observations, forKey: .observations)
    }

    enum CodingKeys: String, CodingKey { case observations, entries }
}

/// Signature-and-setup, so "have I already got this one" is a single lookup.
struct Pair: Hashable {
    let s: Knowledge.Signature
    let u: Knowledge.Setup
    init(_ s: Knowledge.Signature, _ u: Knowledge.Setup) { self.s = s; self.u = u }
}

// MARK: - Asking

public extension Knowledge {

    /// What the knowledge base has to say, and how closely it actually matched.
    struct Answer: Sendable {
        public var setup: Setup
        public var level: Level
        /// Distinct games seen working with this setup at that level.
        public var confirmations: Int
        public var failures: Int
        public var note: String?
        public var seeded: Bool

        /// Said plainly, including how loose the match was — an answer drawn
        /// from "this engine, any Mac" should not sound like one drawn from an
        /// identical machine.
        public var provenance: String {
            if seeded && confirmations == 0 { return "a starting assumption, not yet confirmed here" }
            let games = confirmations == 1 ? "1 game" : "\(confirmations) games"
            return "\(games) at the level of \(level.label)"
        }
    }

    func observations(matching sig: Signature, at level: Level) -> [Observation] {
        observations.filter { level.matches(sig, $0.signature) }
    }

    /// The best answer available, searched from most specific to least.
    ///
    /// A setup that has failed at least as often as it has worked is never
    /// returned: a bucket where something is known to break should fall through
    /// to a broader question rather than recommend the broken thing.
    func best(for sig: Signature, excluding gameID: UUID? = nil) -> Answer? {
        // A specific failure outranks a general success. Without this, Unity 6
        // fell through to "Unity games work on D3DMetal" — true of Unity in
        // general, and measured to be false for Unity 6, which is exactly the
        // case the generation axis exists to capture.
        var vetoed = Set<Setup>()

        for level in Level.allCases {
            let here = observations(matching: sig, at: level)
            guard !here.isEmpty else { continue }

            struct Tally { var worked = Set<UUID>(); var failed = Set<UUID>()
                           var seeded = false; var note: String?
                           var bareWorked = 0; var bareFailed = 0 }
            var tally: [Setup: Tally] = [:]
            for o in here {
                var t = tally[o.setup] ?? Tally()
                if let id = o.gameID {
                    // The game being asked about does not get to vouch for
                    // itself: "this worked for 1 game" meaning *this* game is
                    // not knowledge, it is an echo.
                    // Not a ternary: Set.insert returns a tuple, and discarding
                    // it is a warning — which CI builds with -warnings-as-errors.
                    if id != gameID {
                        if o.worked { t.worked.insert(id) } else { t.failed.insert(id) }
                    }
                } else if o.worked { t.bareWorked += 1 } else { t.bareFailed += 1 }
                if o.seeded { t.seeded = true }
                if t.note == nil { t.note = o.note }
                tally[o.setup] = t
            }

            let ranked = tally
                .filter { !vetoed.contains($0.key) }
                .filter { $0.value.failed.count == 0 && $0.value.bareFailed == 0 }
                .filter { $0.value.worked.count > 0 || $0.value.bareWorked > 0 }
                .sorted {
                    if $0.value.worked.count != $1.value.worked.count {
                        return $0.value.worked.count > $1.value.worked.count
                    }
                    // Something observed beats something shipped.
                    return !$0.value.seeded && $1.value.seeded
                }
            guard let winner = ranked.first else {
                // Nothing survived here. Carry this level's failures down so a
                // broader, vaguer success cannot contradict a specific
                // measurement — but only downward: a failure found at the same
                // level as a success is already handled by the filters above.
                for o in here where !o.worked { vetoed.insert(o.setup) }
                continue
            }
            return Answer(setup: winner.key, level: level,
                          confirmations: winner.value.worked.count,
                          failures: winner.value.failed.count,
                          note: winner.value.note, seeded: winner.value.seeded)
        }
        return nil
    }

    /// Setups known to fail for this situation, most-specific match first.
    /// Knowing what not to try saves more time than knowing what to.
    func knownBad(for sig: Signature) -> [(setup: Setup, failure: Failure, level: Level)] {
        for level in Level.allCases {
            var seen = Set<Setup>()
            var bad: [(setup: Setup, failure: Failure, level: Level)] = []
            for o in observations(matching: sig, at: level) where !o.worked {
                guard !seen.contains(o.setup) else { continue }
                seen.insert(o.setup)
                bad.append((o.setup, o.failure ?? .unspecified, level))
            }
            if !bad.isEmpty { return bad }
        }
        return []
    }
}

// MARK: - Recording

public extension Knowledge {

    /// One observation replaces any earlier one for the same situation, setup
    /// and game: a game that failed on DXVK and later worked on it should read
    /// as "works", not as one of each.
    mutating func record(_ o: Observation) {
        observations.removeAll {
            $0.signature == o.signature && $0.setup == o.setup && $0.gameID == o.gameID && !$0.seeded
        }
        observations.append(o)
    }

    mutating func recordSuccess(signature: Signature, gameID: UUID, setup: Setup) {
        record(.init(signature: signature, setup: setup, worked: true, gameID: gameID))
    }

    mutating func recordFailure(signature: Signature, gameID: UUID, setup: Setup,
                                failure: Failure = .unspecified) {
        record(.init(signature: signature, setup: setup, worked: false,
                     failure: failure, gameID: gameID))
    }
}

// MARK: - Seeds

public extension Knowledge {

    /// What Decanter ships knowing, from behaviour measured on Apple Silicon.
    ///
    /// Seeds carry no machine axes: they are claims about engines and layers,
    /// not about anyone's Mac, so they match from `anyMac` downward and are
    /// outranked by anything actually seen here.
    static func seeded() -> Knowledge {
        var k = Knowledge()
        func add(_ engine: GameEngineKind, major: Int? = nil, _ bits: Bitness,
                 video: Bool = false, d3d12: Bool = false,
                 _ kind: RuntimeKind, _ backend: GraphicsBackend,
                 worked: Bool = true, failure: Failure? = nil, _ note: String) {
            let sig = Signature(engine: engine, engineMajor: major, bitness: bits,
                                usesVideo: video, usesD3D12: d3d12)
            k.observations.append(.init(signature: sig,
                                        setup: Setup(runtimeKind: kind, backend: backend),
                                        worked: worked, failure: failure,
                                        seeded: true, note: note))
        }

        for engine in [GameEngineKind.unityIL2CPP, .unityMono, .unreal, .godot] {
            for d3d12 in [true, false] {
                add(engine, .x64, d3d12: d3d12, .gptk, .d3dmetal,
                    "D3DMetal is the only backend here that reaches feature level 11_1")
                add(engine, .x64, video: true, d3d12: d3d12, .gptk, .wined3d,
                    "video needs ID3D11Multithread, which D3DMetal does not implement")
            }
        }
        for engine in [GameEngineKind.renpy, .rpgMakerNW] {
            for bits in [Bitness.x86, .x64] {
                add(engine, bits, .wine, .wined3d,
                    "2D engine — WineD3D is sufficient and the most predictable")
                add(engine, bits, video: true, .wine, .wined3d,
                    "2D engine with video — Wine's own D3D plays it")
            }
        }
        add(.generic, .x86, .wine, .wined3d,
            "32-bit: Wine 11's WoW64 is more reliable than GPTK's 2022 base")

        // Unity 6, measured on an M2 against a real 6000.2 build rather than
        // assumed. Seeded *failures* are knowledge too: they stop Decanter
        // recommending something already known to break, and they give the
        // first real success something to improve on.
        for engine in [GameEngineKind.unityIL2CPP, .unityMono] {
            add(engine, major: 6000, .x64, .gptk, .d3dmetal, worked: false, failure: .missingInterface,
                "D3DMetal has no ID3D11Fence or ID3D11Multithread, and no D3D11On12")
            // Both runtimes: WineD3D is WineD3D either way, and recording the
            // failure against only one of them let Unity 6 fall through to
            // "GPTK + WineD3D", which is the same layer that just failed.
            for kind in [RuntimeKind.wine, .gptk] {
                add(engine, major: 6000, .x64, kind, .wined3d, worked: false, failure: .noDevice,
                    "WineD3D cannot create a D3D11 device for Unity 6")
                add(engine, major: 6000, .x64, kind, .dxvk, worked: false, failure: .noDevice,
                    "DXVK on MoltenVK fails device creation at every feature level, down to 10_0")
            }
            add(engine, major: 6000, .x64, .wine, .dxmt, worked: false, failure: .missingInterface,
                "DXMT gets a real device at feature level 11_1, then Unity fails GpuFence::Create — no ID3D11Fence")
        }
        return k
    }

    // MARK: Persistence

    static func load(at url: URL) -> Knowledge {
        guard let d = try? Data(contentsOf: url),
              var k = try? JSONDecoder().decode(Knowledge.self, from: d) else { return seeded() }
        // Seeds added since this file was written are folded in. Anything seen
        // here wins, so a seed never overwrites a measurement.
        let mine = Set(k.observations.filter { !$0.seeded }.map { Pair($0.signature, $0.setup) })
        for s in seeded().observations where !mine.contains(Pair(s.signature, s.setup)) {
            if !k.observations.contains(where: { $0.seeded && $0.signature == s.signature && $0.setup == s.setup }) {
                k.observations.append(s)
            }
        }
        return k
    }

    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Export

public extension Knowledge {

    /// The observations as they leave this machine.
    ///
    /// Two things are dropped: seeds, which the recipient already has, and
    /// `gameID`, which means nothing elsewhere but is still an identifier.
    /// What remains is situations and outcomes.
    ///
    /// There is deliberately no option to include a title. An earlier design
    /// stored names locally with a checkbox to include them on export; the
    /// simpler and more honest version is that a name is never recorded at all,
    /// so there is nothing to decide at export time.
    struct Export: Codable, Sendable {
        public var formatVersion = 1
        public var observations: [Row] = []

        public struct Row: Codable, Sendable {
            public var signature: Signature
            public var setup: Setup
            public var worked: Bool
            public var failure: Failure?
            public var note: String?
        }
    }

    func exportable() -> Export {
        var e = Export()
        // One row per situation-and-setup: how many local games agreed is a
        // fact about this library, not about the world.
        var seen = Set<Pair>()
        for o in observations where !o.seeded {
            let key = Pair(o.signature, o.setup)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            e.observations.append(.init(signature: o.signature, setup: o.setup,
                                        worked: o.worked, failure: o.failure, note: o.note))
        }
        return e
    }
}

public extension Engine {
    @discardableResult
    func exportKnowledge(to url: URL) throws -> Int {
        let e = knowledge.exportable()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(e).write(to: url, options: .atomic)
        return e.observations.count
    }
}
