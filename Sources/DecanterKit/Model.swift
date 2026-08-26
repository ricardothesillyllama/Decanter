import Foundation

// MARK: - Runtimes

public enum RuntimeKind: String, Codable, Sendable {
    case wine, gptk
}

public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    case dxvk        // D3D9/10/11 -> Vulkan -> MoltenVK -> Metal
    case d3dmetal    // Apple D3DMetal, D3D11/12 -> Metal directly (GPTK only)
    case wined3d     // Wine's own D3D -> OpenGL. Slow, but the safety net.

    public var label: String {
        switch self {
        case .dxvk: "DXVK"
        case .d3dmetal: "D3DMetal"
        case .wined3d: "WineD3D"
        }
    }
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
    public var confidence: Double = 0
    public var signals: [DetectionSignal] = []
    public var recommendedRuntimeKind: RuntimeKind = .wine
    public var recommendedBackend: GraphicsBackend = .dxvk
    public var recipes: [String] = []
    public init() {}

    // Hand-written for the same reason DecanterState is: Swift's synthesised
    // Decodable requires every non-optional key even when the property has a
    // default, so adding one field makes every previously-saved game
    // undecodable. That has now caused a silent library wipe twice.
    enum CodingKeys: String, CodingKey {
        case engine, bitness, graphicsAPIs, modded, hasWarmDXVKCache, usesVideo
        case confidence, signals, recommendedRuntimeKind, recommendedBackend, recipes
        case engineVersion, knownUnsupported
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

    public init(id: UUID = UUID(), name: String, exePath: URL, bottleID: UUID,
                detection: DetectionResult, scopes: [ScopeGrant] = [],
                envOverrides: [String: String] = [:], dllOverrides: [String: String] = [:],
                runtimeLocked: Bool = false, launchArguments: [String]? = nil,
                lastPlayed: Date? = nil, addedAt: Date = Date()) {
        self.id = id; self.name = name; self.exePath = exePath; self.bottleID = bottleID
        self.detection = detection; self.scopes = scopes
        self.envOverrides = envOverrides; self.dllOverrides = dllOverrides
        self.runtimeLocked = runtimeLocked; self.launchArguments = launchArguments
        self.lastPlayed = lastPlayed; self.addedAt = addedAt
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
        }
    }
}


/// Build identity, so a problem report from a source build can be traced to a
/// commit. Stamped by install.sh; "dev" when built some other way.
public enum Build {
    public static let version = "0.3.1"
    public static let commit = "749e9c3"
    public static var summary: String { "Decanter \(version) (\(commit))" }
}
