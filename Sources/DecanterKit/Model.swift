import Foundation

// MARK: - Runtimes

public enum RuntimeKind: String, Codable, Sendable {
    case wine, gptk
}

public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    case dxvk        // D3D9/10/11 -> Vulkan -> MoltenVK -> Metal
    case d3dmetal    // Apple D3DMetal, D3D11/12 -> Metal directly (GPTK only)
    case wined3d     // Wine's own D3D -> OpenGL. Slow, but the safety net.
    case dxmt        // DXMT, D3D11 -> Metal directly. Needs a host Wine that
                     // can hand out a Cocoa view; see RuntimeManager.metalHosting.

    public var label: String {
        switch self {
        case .dxvk: "DXVK"
        case .d3dmetal: "D3DMetal"
        case .wined3d: "WineD3D"
        case .dxmt: "DXMT"
        }
    }

    /// What to call this where someone is reading rather than configuring.
    ///
    /// Lived in the app for a while, which meant the app said "Metal graphics"
    /// and the command line said "DXMT" about the same setting. Two vocabularies
    /// for one thing is worse than either alone: someone who learns one cannot
    /// search the other. It belongs here, where everything that reports to a
    /// person can reach it.
    ///
    /// The real name is never hidden, only demoted — someone following a forum
    /// thread needs to recognise "DXVK", and concealing it would make this
    /// harder to get help with, not easier. Say "Vulkan graphics (DXVK)".
    public var plainName: String {
        switch self {
        case .d3dmetal: "Apple"
        case .dxvk:     "Vulkan"
        case .wined3d:  "Wine"
        case .dxmt:     "Metal"
        }
    }

    /// One order for every list of backends, anywhere.
    ///
    /// Lists used to come out in whatever order the code that built them
    /// happened to append in, so the same three options read "D3DMetal, DXVK,
    /// WineD3D" beside one runtime and "DXVK, WineD3D" beside another, with
    /// DXMT tacked on after WineD3D — the best option listed below the worst.
    /// A menu whose order changes between rows is a menu people misread.
    ///
    /// Best first, and the ranking is the recommendation: the two that reach
    /// Metal directly, then Vulkan through MoltenVK, then Wine's own
    /// translation to OpenGL, which is slow and always available.
    public var rank: Int {
        switch self {
        case .d3dmetal: 0
        case .dxmt:     1
        case .dxvk:     2
        case .wined3d:  3
        }
    }
}

public extension Array where Element == GraphicsBackend {
    /// Same order wherever backends are shown or stored.
    var inPreferenceOrder: [GraphicsBackend] { sorted { $0.rank < $1.rank } }
}

/// A pinned, archived Wine build. Decanter keeps its own copy under
/// `runtimes/` rather than trusting a Homebrew cask to still exist.
public struct RuntimeSpec: Codable, Hashable, Identifiable, Sendable {
    public var id: String              // "wine-11.0", "gptk-3.0-3"
    public var kind: RuntimeKind
    public var version: String
    public var root: URL               // .../runtimes/wine-11.0
    public var winePath: URL           // binary to exec
    public var wineserverPath: URL?
    public var supports32Bit: Bool
    public var backends: [GraphicsBackend]
    public var pinnedAt: Date

    public init(id: String, kind: RuntimeKind, version: String, root: URL,
                winePath: URL, wineserverPath: URL? = nil,
                supports32Bit: Bool, backends: [GraphicsBackend],
                pinnedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.version = version
        self.root = root; self.winePath = winePath; self.wineserverPath = wineserverPath
        self.supports32Bit = supports32Bit; self.backends = backends; self.pinnedAt = pinnedAt
    }

    /// Raw backend names this binary does not recognise, kept so they survive a
    /// round trip through an older version.
    public var unknownBackends: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, kind, version, root, winePath, wineserverPath, supports32Bit, backends, pinnedAt
    }

    /// Hand-written because an unknown *enum case* is as breaking as an unknown
    /// key, and only the second was guarded against.
    ///
    /// Synthesised decoding throws on a raw value it has no case for, so one
    /// `"dxmt"` written by a newer binary made the whole `runtimes` array
    /// undecodable in an older one — which showed up as an app with no runtimes
    /// and no games, next to a CLI that could see everything. Unrecognised
    /// names are set aside and written back out, so passing through an old
    /// binary costs nothing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(RuntimeKind.self, forKey: .kind)) ?? .wine
        version = (try? c.decode(String.self, forKey: .version)) ?? "unknown"
        root = try c.decode(URL.self, forKey: .root)
        winePath = try c.decode(URL.self, forKey: .winePath)
        wineserverPath = try? c.decodeIfPresent(URL.self, forKey: .wineserverPath)
        supports32Bit = (try? c.decode(Bool.self, forKey: .supports32Bit)) ?? false
        pinnedAt = (try? c.decode(Date.self, forKey: .pinnedAt)) ?? Date()
        let raw = (try? c.decode([String].self, forKey: .backends)) ?? []
        backends = raw.compactMap { GraphicsBackend(rawValue: $0) }
        unknownBackends = raw.filter { GraphicsBackend(rawValue: $0) == nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(version, forKey: .version)
        try c.encode(root, forKey: .root)
        try c.encode(winePath, forKey: .winePath)
        try c.encodeIfPresent(wineserverPath, forKey: .wineserverPath)
        try c.encode(supports32Bit, forKey: .supports32Bit)
        try c.encode(pinnedAt, forKey: .pinnedAt)
        try c.encode(backends.map(\.rawValue) + unknownBackends, forKey: .backends)
    }
}

// MARK: - Detection

public enum GameEngineKind: String, Codable, Sendable {
    case renpy, rpgMakerNW, unityIL2CPP, unityMono, godot, unreal, generic

    public var label: String {
        switch self {
        case .renpy: "Ren'Py"
        case .rpgMakerNW: "RPG Maker (nw.js)"
        case .unityIL2CPP: "Unity (IL2CPP)"
        case .unityMono: "Unity (Mono)"
        case .godot: "Godot"
        case .unreal: "Unreal Engine"
        case .generic: "Unknown engine"
        }
    }
}

public enum Bitness: String, Codable, Sendable {
    case x86, x64, unknown
    public var label: String {
        switch self { case .x86: "32-bit"; case .x64: "64-bit"; case .unknown: "unknown" }
    }
}

public struct DetectionSignal: Codable, Sendable, Hashable {
    public var rule: String
    public var path: String?
    public var weight: Double
    public init(_ rule: String, path: String? = nil, weight: Double) {
        self.rule = rule; self.path = path; self.weight = weight
    }
}

public struct DetectionResult: Codable, Sendable {
    public var engine: GameEngineKind = .generic
    public var bitness: Bitness = .unknown
    public var graphicsAPIs: [String] = []
    public var modded: Bool = false
    public var hasWarmDXVKCache: Bool = false
    public var usesVideo: Bool = false
    /// e.g. "6000.0.58f2". Unity 6 needs D3D11 features no translation layer
    /// on this platform provides, so knowing the version prevents a long,
    /// futile hunt through backend combinations.
    public var engineVersion: String?
    public var knownUnsupported: String?
    /// The one backend that lifts `knownUnsupported`, when there is one.
    ///
    /// A flat "does not run here" was accurate on the runtimes Decanter shipped
    /// with and became a lie the moment a layer appeared that handles the case.
    /// Naming the escape hatch keeps the warning true in both worlds.
    public var unsupportedUnless: GraphicsBackend?
    /// True when the build ships the DirectX 12 Agility SDK beside the game —
    /// the only evidence here that D3D12 is in the build's renderer list
    /// rather than merely linked. Every Unity 6 build imports d3d12.dll
    /// whether or not it ever creates a D3D12 device.
    public var shipsD3D12Runtime: Bool = false
    public var confidence: Double = 0
    public var signals: [DetectionSignal] = []
    public var recommendedRuntimeKind: RuntimeKind = .wine
    public var recommendedBackend: GraphicsBackend = .dxvk
    public var recipes: [String] = []
    public init() {}

    /// The blocker as it applies to a particular backend. `nil` when the game
    /// is on the backend that lifts it.
    public func blocker(onBackend b: GraphicsBackend?) -> String? {
        guard let k = knownUnsupported else { return nil }
        if let escape = unsupportedUnless, b == escape { return nil }
        return k
    }

    // Hand-written for the same reason DecanterState is: Swift's synthesised
    // Decodable requires every non-optional key even when the property has a
    // default, so adding one field makes every previously-saved game
    // undecodable. That has now caused a silent library wipe twice.
    enum CodingKeys: String, CodingKey {
        case engine, bitness, graphicsAPIs, modded, hasWarmDXVKCache, usesVideo
        case confidence, signals, recommendedRuntimeKind, recommendedBackend, recipes
        case engineVersion, knownUnsupported, unsupportedUnless, shipsD3D12Runtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decode(GameEngineKind.self, forKey: .engine)) ?? .generic
        bitness = (try? c.decode(Bitness.self, forKey: .bitness)) ?? .unknown
        graphicsAPIs = (try? c.decode([String].self, forKey: .graphicsAPIs)) ?? []
        modded = (try? c.decode(Bool.self, forKey: .modded)) ?? false
        hasWarmDXVKCache = (try? c.decode(Bool.self, forKey: .hasWarmDXVKCache)) ?? false
        usesVideo = (try? c.decode(Bool.self, forKey: .usesVideo)) ?? false
        engineVersion = try? c.decodeIfPresent(String.self, forKey: .engineVersion)
        knownUnsupported = try? c.decodeIfPresent(String.self, forKey: .knownUnsupported)
        unsupportedUnless = try? c.decodeIfPresent(GraphicsBackend.self, forKey: .unsupportedUnless)
        shipsD3D12Runtime = (try? c.decode(Bool.self, forKey: .shipsD3D12Runtime)) ?? false
        confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0
        signals = (try? c.decode([DetectionSignal].self, forKey: .signals)) ?? []
        recommendedRuntimeKind = (try? c.decode(RuntimeKind.self, forKey: .recommendedRuntimeKind)) ?? .wine
        recommendedBackend = (try? c.decode(GraphicsBackend.self, forKey: .recommendedBackend)) ?? .dxvk
        recipes = (try? c.decode([String].self, forKey: .recipes)) ?? []
    }
}

// MARK: - Scoped filesystem access

/// Which host folders a game can see. There is deliberately no `z: -> /`.
public struct ScopeGrant: Codable, Sendable, Hashable {
    public var letter: String      // "g", "h"
    public var hostPath: URL
    public var readOnly: Bool
    public init(letter: String, hostPath: URL, readOnly: Bool = false) {
        self.letter = letter; self.hostPath = hostPath; self.readOnly = readOnly
    }
}

// MARK: - Bottles

public enum BottleHealth: Codable, Sendable, Equatable {
    case healthy
    case needsSetup(missing: [String])
    case installing(recipe: String)
    case broken(reason: String)

    public var label: String {
        switch self {
        case .healthy: "Healthy"
        case .needsSetup(let m): "Needs setup (\(m.joined(separator: ", ")))"
        case .installing(let r): "Installing \(r)"
        case .broken(let r): "Broken: \(r)"
        }
    }
}

public struct Bottle: Codable, Identifiable, Sendable {
    public var id: UUID
    public var prefixPath: URL
    public var runtimeID: String
    public var backend: GraphicsBackend
    public var appliedRecipes: [String]
    /// Which staged DXVK version this prefix carries. Optional on purpose:
    /// Swift synthesises decodeIfPresent for optionals, so adding it cannot
    /// break decoding of a state file written before it existed.
    public var dxvkVersion: String?
    /// Why this bottle looks the way it does. Backends and runtimes have
    /// changed unexplained more than once; without a log there is no way to
    /// answer "what set this, and when".
    public var changeLog: [String]?
    public var generation: Int
    public var health: BottleHealth
    public var createdAt: Date

    public init(id: UUID = UUID(), prefixPath: URL, runtimeID: String,
                backend: GraphicsBackend, appliedRecipes: [String] = [],
                dxvkVersion: String? = nil, changeLog: [String]? = nil,
                generation: Int = 1, health: BottleHealth = .healthy,
                createdAt: Date = Date()) {
        self.id = id; self.prefixPath = prefixPath; self.runtimeID = runtimeID
        self.backend = backend; self.appliedRecipes = appliedRecipes
        self.dxvkVersion = dxvkVersion; self.changeLog = changeLog
        self.generation = generation; self.health = health; self.createdAt = createdAt
    }

    /// The backend name as written, when this binary has no case for it.
    public var unknownBackend: String?

    enum CodingKeys: String, CodingKey {
        case id, prefixPath, runtimeID, backend, appliedRecipes, dxvkVersion
        case changeLog, generation, health, createdAt
    }

    /// Same reasoning as `RuntimeSpec`: a single unrecognised backend name must
    /// not make a bottle undecodable, and must not be silently rewritten to
    /// something else either. The bottle falls back to a backend this binary
    /// can actually run, and the original name is written back out untouched,
    /// so a newer binary still finds the game exactly as it left it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        prefixPath = try c.decode(URL.self, forKey: .prefixPath)
        runtimeID = try c.decode(String.self, forKey: .runtimeID)
        let raw = (try? c.decode(String.self, forKey: .backend)) ?? GraphicsBackend.dxvk.rawValue
        if let known = GraphicsBackend(rawValue: raw) {
            backend = known
        } else {
            backend = .wined3d      // the one every runtime here can always provide
            unknownBackend = raw
        }
        appliedRecipes = (try? c.decode([String].self, forKey: .appliedRecipes)) ?? []
        dxvkVersion = try? c.decodeIfPresent(String.self, forKey: .dxvkVersion)
        changeLog = try? c.decodeIfPresent([String].self, forKey: .changeLog)
        generation = (try? c.decode(Int.self, forKey: .generation)) ?? 1
        health = (try? c.decode(BottleHealth.self, forKey: .health)) ?? .healthy
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(prefixPath, forKey: .prefixPath)
        try c.encode(runtimeID, forKey: .runtimeID)
        try c.encode(unknownBackend ?? backend.rawValue, forKey: .backend)
        try c.encode(appliedRecipes, forKey: .appliedRecipes)
        try c.encodeIfPresent(dxvkVersion, forKey: .dxvkVersion)
        try c.encodeIfPresent(changeLog, forKey: .changeLog)
        try c.encode(generation, forKey: .generation)
        try c.encode(health, forKey: .health)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - Games

public struct Game: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var exePath: URL
    public var bottleID: UUID
    public var detection: DetectionResult
    public var scopes: [ScopeGrant]
    public var envOverrides: [String: String]
    public var dllOverrides: [String: String]
    /// Set once a human corrects the engine's guess; stops re-detection
    /// from silently overriding a known-good manual choice.
    public var runtimeLocked: Bool
    /// Extra arguments passed to the game. Unity's -force-* switches are often
    /// the only way past an engine/backend mismatch. Optional so that adding it
    /// cannot break decoding of previously-saved games.
    public var launchArguments: [String]?
    public var lastPlayed: Date?
    public var addedAt: Date
    /// The last configuration this game was confirmed working on.
    ///
    /// The knowledge base already holds what worked, but it holds it as a claim
    /// about a *situation* — an engine, a bitness, a chip — deliberately, so it
    /// can answer for games it has never seen. That makes it the wrong place to
    /// ask "what was this game running when it last worked", which is a fact
    /// about one game and needs a date attached. Observations carry no date, and
    /// giving them one would put a timestamp into something that gets exported.
    ///
    /// So it lives here: local, per game, never exported, and the one thing
    /// needed to offer somebody their working setup back.
    public var knownGood: KnownGood?

    public struct KnownGood: Codable, Sendable, Hashable {
        public var runtimeID: String
        public var backend: GraphicsBackend
        /// The graphics layer's version, because going back to "DXVK" is not
        /// going back if it is a different DXVK than the one that worked.
        public var layerVersion: String?
        public var confirmedAt: Date

        public init(runtimeID: String, backend: GraphicsBackend,
                    layerVersion: String? = nil, confirmedAt: Date = Date()) {
            self.runtimeID = runtimeID; self.backend = backend
            self.layerVersion = layerVersion; self.confirmedAt = confirmedAt
        }

        public var label: String {
            let base = "\(runtimeID) with \(backend.plainName) graphics"
            return layerVersion.map { "\(base) \($0)" } ?? base
        }
    }

    public init(id: UUID = UUID(), name: String, exePath: URL, bottleID: UUID,
                detection: DetectionResult, scopes: [ScopeGrant] = [],
                envOverrides: [String: String] = [:], dllOverrides: [String: String] = [:],
                runtimeLocked: Bool = false, launchArguments: [String]? = nil,
                lastPlayed: Date? = nil, addedAt: Date = Date(),
                knownGood: KnownGood? = nil) {
        self.id = id; self.name = name; self.exePath = exePath; self.bottleID = bottleID
        self.detection = detection; self.scopes = scopes
        self.envOverrides = envOverrides; self.dllOverrides = dllOverrides
        self.runtimeLocked = runtimeLocked; self.launchArguments = launchArguments
        self.lastPlayed = lastPlayed; self.addedAt = addedAt
        self.knownGood = knownGood
    }
}

// MARK: - Errors

public enum DecanterError: LocalizedError {
    case noRuntime(String)
    case templateMissing
    case noTemplate(String)
    case notAnExecutable(URL)
    case pathEscapesScope(URL)
    case runtimeLacks32Bit(String)
    case cloneFailed(String)
    case launchFailed(String)
    case notFound(String)
    /// A message that is already a complete sentence. Every other case names a
    /// category first, which reads well for "Not found: wine-11.0" and badly
    /// for a sentence that already explains itself.
    case badFile(String)
    case usage(String)
    case outOfSpace(String)
    /// The setup is inconsistent in a way that makes the game fail silently
    /// rather than loudly. Its own sentence, because it always names the fix.
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .noRuntime(let s): "No runtime available: \(s)"
        case .templateMissing: "Golden template not built yet. Run `decanter template build`."
        case .noTemplate(let r): "No golden template for runtime \(r). Run `decanter template build \(r)`."
        case .notAnExecutable(let u): "Not a Windows executable: \(u.path)"
        case .pathEscapesScope(let u): "Path is outside this game's allowed folders: \(u.path)"
        case .runtimeLacks32Bit(let s): "Runtime \(s) cannot run 32-bit Windows programs."
        case .cloneFailed(let s): "Could not clone prefix: \(s)"
        case .launchFailed(let s): "Launch failed: \(s)"
        case .notFound(let s): "Not found: \(s)"
        case .badFile(let s): s
        case .usage(let s): s
        case .notReady(let s): s
        case .outOfSpace(let s): "Not enough disk space: \(s)"
        }
    }

    /// The process exit status this failure produces, so a script can branch on
    /// the kind of failure instead of matching on the message.
    ///
    /// These numbers are interface: they are listed in `docs/CLI.md`, and a
    /// released one must not be reassigned to a different meaning.
    public var exitCode: Int32 {
        switch self {
        case .usage:                                                   2
        case .notFound, .badFile, .notAnExecutable:                    3
        case .noRuntime, .templateMissing, .noTemplate,
             .runtimeLacks32Bit, .notReady:                            4
        case .outOfSpace:                                              5
        case .pathEscapesScope:                                        6
        case .cloneFailed, .launchFailed:                              1
        }
    }
}


/// Build identity, so a problem report from a source build can be traced to a
/// commit. Stamped by install.sh: empty for a build made from a clean tree,
/// where the version is the whole of the attribution; the short hash when the
/// tree was modified, which is the case a hash was ever for; "dev" outside a
/// repository.
public enum Build {
    public static let version = "0.6.5"
    public static let commit = ""
    /// A released build says its version and stops. The version is the whole
    /// of the attribution when the source it was built from is public and
    /// unmodified, and a hash there was worse than nothing: it named the commit
    /// before the tag, every time, because it had to be written before that
    /// commit existed.
    public static var summary: String {
        commit.isEmpty ? "Decanter \(version)" : "Decanter \(version) (\(commit))"
    }
}
