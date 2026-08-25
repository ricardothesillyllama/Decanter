import Foundation

/// What has actually worked, remembered across games.
///
/// A recommendation from static rules is a guess. Once a configuration is
/// observed working for a game, that fact should be kept and reused for every
/// future game that looks the same — otherwise each new title starts from
/// zero and the user is back to trying five combinations by hand.
public struct Knowledge: Codable, Sendable {

    /// What makes two games alike for configuration purposes. Deliberately
    /// coarse: engine, width, and the two traits that actually change the
    /// answer on Apple Silicon.
    public struct Signature: Codable, Hashable, Sendable {
        public var engine: GameEngineKind
        public var bitness: Bitness
        public var usesVideo: Bool
        public var usesD3D12: Bool

        public init(_ d: DetectionResult) {
            engine = d.engine
            bitness = d.bitness
            usesVideo = d.usesVideo
            usesD3D12 = d.graphicsAPIs.contains("d3d12.dll")
        }

        public var label: String {
            var s = "\(engine.label), \(bitness.label)"
            if usesVideo { s += ", video" }
            if usesD3D12 { s += ", D3D12" }
            return s
        }
    }

    public struct Entry: Codable, Sendable {
        public var runtimeKind: RuntimeKind
        public var backend: GraphicsBackend
        /// Distinct games observed working with this, held as the local library
        /// id rather than the title. Counting is the only thing the
        /// recommendation needs, and a UUID cannot identify a game to anyone
        /// but this machine — titles are deliberately never recorded anywhere.
        /// Ids (not a bare count) because the same game confirming twice must
        /// not read as two games agreeing.
        public var confirmedGames: Set<UUID> = []
        public var failedGames: Set<UUID> = []
        public var seeded: Bool = false
        public var note: String?

        public var confirmations: Int { confirmedGames.count }
        public var failures: Int { failedGames.count }

        public init(runtimeKind: RuntimeKind, backend: GraphicsBackend,
                    confirmedGames: Set<UUID> = [], failedGames: Set<UUID> = [],
                    seeded: Bool = false, note: String? = nil) {
            self.runtimeKind = runtimeKind; self.backend = backend
            self.confirmedGames = confirmedGames; self.failedGames = failedGames
            self.seeded = seeded; self.note = note
        }

        // Hand-written for the reason every other type here is: Swift's
        // synthesised Decodable demands each non-optional key even when the
        // property has a default, so adding one field makes every previously
        // saved entry undecodable. That silently reset the whole store twice.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runtimeKind = try c.decode(RuntimeKind.self, forKey: .runtimeKind)
            backend = try c.decode(GraphicsBackend.self, forKey: .backend)
            confirmedGames = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .confirmedGames)) as? Set<UUID> ?? []
            failedGames = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .failedGames)) as? Set<UUID> ?? []
            seeded = (try? c.decodeIfPresent(Bool.self, forKey: .seeded)) as? Bool ?? false
            note = try? c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    public var entries: [String: Entry] = [:]

    /// Human-readable profile for a stored key, so a listing is legible.
    public static func label(forKey key: String) -> String {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return key }
        let engine = GameEngineKind(rawValue: parts[0])?.label ?? parts[0]
        let bits = Bitness(rawValue: parts[1])?.label ?? parts[1]
        var s = "\(engine), \(bits)"
        if parts[2] == "true" { s += ", video" }
        if parts[3] == "true" { s += ", D3D12" }
        return s
    }

    static func key(_ s: Signature) -> String {
        "\(s.engine.rawValue)|\(s.bitness.rawValue)|\(s.usesVideo)|\(s.usesD3D12)"
    }

    // MARK: Seed

    /// Starting knowledge, from behaviour confirmed on Apple Silicon:
    ///  - D3DMetal is the only backend here that provides D3D feature level
    ///    11_1, which modern Unity and Unreal require.
    ///  - D3DMetal has no ID3D11Multithread, so Unity's video player fails on
    ///    it; WineD3D is complete and plays video, at the cost of speed.
    ///  - DXVK on MoltenVK cannot reach 11_1 at all.
    public static func seeded() -> Knowledge {
        var k = Knowledge()
        func add(_ engine: GameEngineKind, _ bits: Bitness, video: Bool, d3d12: Bool,
                 _ kind: RuntimeKind, _ backend: GraphicsBackend, _ note: String) {
            var sig = Signature(DetectionResult())
            sig.engine = engine; sig.bitness = bits; sig.usesVideo = video; sig.usesD3D12 = d3d12
            k.entries[key(sig)] = Entry(runtimeKind: kind, backend: backend,
                                        confirmedGames: [], failedGames: [], seeded: true, note: note)
        }
        for engine in [GameEngineKind.unityIL2CPP, .unityMono, .unreal, .godot] {
            for d3d12 in [true, false] {
                add(engine, .x64, video: false, d3d12: d3d12, .gptk, .d3dmetal,
                    "D3DMetal is the only backend here that reaches feature level 11_1")
                add(engine, .x64, video: true, d3d12: d3d12, .gptk, .wined3d,
                    "video needs ID3D11Multithread, which D3DMetal does not implement")
            }
        }
        for engine in [GameEngineKind.renpy, .rpgMakerNW] {
            for bits in [Bitness.x86, .x64] {
                add(engine, bits, video: false, d3d12: false, .wine, .wined3d,
                    "2D engine — WineD3D is sufficient and the most predictable")
                add(engine, bits, video: true, d3d12: false, .wine, .wined3d,
                    "2D engine with video — Wine's own D3D plays it")
            }
        }
        add(.generic, .x86, video: false, d3d12: false, .wine, .wined3d,
            "32-bit: Wine 11's WoW64 is more reliable than GPTK's 2022 base")
        return k
    }

    // MARK: Use

    public func lookup(_ sig: Signature) -> Entry? { entries[Self.key(sig)] }

    public mutating func recordSuccess(signature: Signature, gameID: UUID,
                                       runtimeKind: RuntimeKind, backend: GraphicsBackend) {
        let k = Self.key(signature)
        var e = entries[k] ?? Entry(runtimeKind: runtimeKind, backend: backend)
        // An observed success outranks a seeded guess, and re-points the entry.
        if e.seeded || (e.runtimeKind == runtimeKind && e.backend == backend) {
            e.runtimeKind = runtimeKind; e.backend = backend
            if e.seeded { e.seeded = false; e.note = nil }
        } else if e.confirmedGames.isEmpty {
            e.runtimeKind = runtimeKind; e.backend = backend
        }
        e.confirmedGames.insert(gameID)
        e.failedGames.remove(gameID)
        entries[k] = e
    }

    public mutating func recordFailure(signature: Signature, gameID: UUID) {
        let k = Self.key(signature)
        guard var e = entries[k] else { return }
        e.failedGames.insert(gameID)
        entries[k] = e
    }

    // MARK: Persistence

    public static func load(at url: URL) -> Knowledge {
        guard let d = try? Data(contentsOf: url),
              var k = try? JSONDecoder().decode(Knowledge.self, from: d) else { return seeded() }
        // Fill in any seeds added since this file was written.
        let s = seeded()
        for (key, entry) in s.entries where k.entries[key] == nil { k.entries[key] = entry }
        return k
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
