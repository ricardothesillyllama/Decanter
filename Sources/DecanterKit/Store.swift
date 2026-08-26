import Foundation

/// Everything Decanter owns lives under one root, so the whole system can be
/// backed up, inspected, or thrown away as a unit.
public struct Paths: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        // DECANTER_ROOT runs the app and CLI against an isolated store. Used
        // for the documentation screenshots and for trying things out without
        // touching a real library.
        if let root { self.root = root }
        else if let env = ProcessInfo.processInfo.environment["DECANTER_ROOT"], !env.isEmpty {
            self.root = URL(filePath: (env as NSString).expandingTildeInPath)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Decanter")
        }
    }
    public var runtimes: URL   { root.appending(path: "runtimes") }
    /// One golden template per runtime. A prefix built by Wine 11 is not safe
    /// to hand to GPTK's Wine 7.7 — the older Wine sees an unfamiliar prefix
    /// and starts bootstrapping wine-mono into it.
    public func template(for runtimeID: String) -> URL {
        root.appending(path: "template/golden-\(runtimeID)")
    }
    /// Legacy single-template location, still read so existing installs work.
    public var template: URL   { root.appending(path: "template/golden") }
    /// Holds every per-runtime template plus the legacy one.
    public var templateRoot: URL { root.appending(path: "template") }
    public var bottles: URL    { root.appending(path: "bottles") }
    public var profiles: URL   { root.appending(path: "profiles") }
    public var logs: URL       { root.appending(path: "logs") }
    public var saves: URL      { root.appending(path: "saves") }
    public var statePath: URL  { root.appending(path: "state.json") }
    public var knowledgePath: URL { root.appending(path: "knowledge.json") }
    public var gamesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Games")
    }

    public func ensure() throws {
        for d in [root, runtimes, bottles, profiles, logs, saves,
                  template.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

public struct DecanterState: Codable, Sendable {
    public var games: [Game] = []
    public var bottles: [Bottle] = []
    public var runtimes: [RuntimeSpec] = []
    public var templateBuiltAt: Date?
    public var templateRuntimeID: String?
    /// runtimeID -> when its template was built
    public var templates: [String: Date] = [:]

    /// Keys written by a newer version than the one that loaded this file.
    /// Carried through untouched so an older binary cannot delete them by
    /// rewriting the store — see JSONValue.swift.
    public var unknownKeys: [String: JSONValue] = [:]

    public init() {}

    // Decoding is written by hand on purpose. Swift's synthesised Decodable
    // REQUIRES every non-optional key even when the property has a default, so
    // simply adding a field makes every existing state.json fail to decode —
    // and a silent fallback to an empty state would then be written back over
    // the user's whole library on the next save.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case games, bottles, runtimes, templateBuiltAt, templateRuntimeID, templates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // These deliberately do NOT swallow errors. Falling back to an empty
        // array on a decode failure looks like "no games" and then overwrites
        // the real library on the next save — a silent wipe. Better to throw,
        // so Store keeps a backup and reports it.
        games = try c.decodeIfPresent([Game].self, forKey: .games) ?? []
        bottles = try c.decodeIfPresent([Bottle].self, forKey: .bottles) ?? []
        runtimes = try c.decodeIfPresent([RuntimeSpec].self, forKey: .runtimes) ?? []
        templateBuiltAt = try? c.decodeIfPresent(Date.self, forKey: .templateBuiltAt)
        templateRuntimeID = try? c.decodeIfPresent(String.self, forKey: .templateRuntimeID)
        templates = (try? c.decodeIfPresent([String: Date].self, forKey: .templates)) as? [String: Date] ?? [:]
        unknownKeys = UnknownKeys.capture(from: decoder,
                                          known: CodingKeys.allCases.map(\.rawValue))
    }
}

public final class Store: @unchecked Sendable {
    public let paths: Paths
    public private(set) var state: DecanterState
    /// Set when the on-disk state could not be decoded; surfaced by `doctor`.
    public private(set) var loadError: String?

    public init(paths: Paths = Paths()) throws {
        self.paths = paths
        try paths.ensure()
        if let d = try? Data(contentsOf: paths.statePath) {
            do {
                self.state = try JSONDecoder().decode(DecanterState.self, from: d)
            } catch {
                // Never quietly start empty on top of a state file we could not
                // read: the next save would overwrite the user's library.
                let backup = paths.root.appending(path: "state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? d.write(to: backup)
                self.state = DecanterState()
                self.loadError = "state.json could not be read (\(error)). A copy was kept at \(backup.lastPathComponent)."
            }
        } else {
            self.state = DecanterState()
        }
    }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // .atomic is a temp file plus rename, so a crash mid-write cannot
        // truncate the library. The merge puts back any field a newer version
        // wrote that this binary does not know about.
        let encoded = try enc.encode(state)
        let merged = UnknownKeys.merge(state.unknownKeys, into: encoded)
        try merged.write(to: paths.statePath, options: .atomic)
    }

    private var lockPath: URL { paths.root.appending(path: "state.lock") }

    /// Read-modify-write under an exclusive file lock, re-reading from disk
    /// first. The GUI and the CLI are routinely open at the same time; without
    /// this, whichever writes last silently discards the other's changes.
    public func mutate(_ body: (inout DecanterState) throws -> Void) throws {
        if !FileManager.default.fileExists(atPath: lockPath.path) {
            FileManager.default.createFile(atPath: lockPath.path, contents: nil)
        }
        let fd = open(lockPath.path, O_RDWR | O_CREAT, 0o644)
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        if fd >= 0 { _ = flock(fd, LOCK_EX) }

        // Adopt whatever another process committed while we were idle.
        if let d = try? Data(contentsOf: paths.statePath),
           let disk = try? JSONDecoder().decode(DecanterState.self, from: d) {
            state = disk
        }
        try body(&state)
        try save()
    }

    /// Pull in changes made by another process without mutating anything.
    public func refresh() {
        if let d = try? Data(contentsOf: paths.statePath),
           let disk = try? JSONDecoder().decode(DecanterState.self, from: d) {
            state = disk
        }
    }

    /// Exact match wins, then case-insensitive exact, then a substring match
    /// but only when it is unambiguous. An empty query never matches.
    public func game(named n: String) -> Game? {
        let q = n.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if let exact = state.games.first(where: { $0.name == q }) { return exact }
        let ci = state.games.filter { $0.name.lowercased() == q.lowercased() }
        if ci.count == 1 { return ci[0] }
        if ci.count > 1 { return ci[0] }        // caller should have disambiguated
        let partial = state.games.filter { $0.name.lowercased().contains(q.lowercased()) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// All plausible matches, so callers can report ambiguity instead of
    /// silently acting on the wrong game.
    public func gamesMatching(_ n: String) -> [Game] {
        let q = n.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        if let exact = state.games.first(where: { $0.name == n }) { return [exact] }
        let ci = state.games.filter { $0.name.lowercased() == q }
        if !ci.isEmpty { return ci }
        return state.games.filter { $0.name.lowercased().contains(q) }
    }
    public func bottle(_ id: UUID) -> Bottle? { state.bottles.first { $0.id == id } }
    public func runtime(_ id: String) -> RuntimeSpec? { state.runtimes.first { $0.id == id } }
}
