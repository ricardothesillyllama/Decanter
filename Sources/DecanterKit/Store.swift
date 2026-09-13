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
        // Prefixes and runtimes are re-derivable by design, so backing them up
        // is pure waste — tens of gigabytes of Time Machine for something a
        // rebuild reconstructs in half a second. Saves live here too, but they
        // are small and this is a deliberate trade: the store is a cache with
        // a saves directory in it, not a document.
        for d in [runtimes, bottles, template.deletingLastPathComponent()] {
            var u = d
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
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
        templates = (try? c.decode([String: Date].self, forKey: .templates)) ?? [:]
        unknownKeys = UnknownKeys.capture(from: decoder,
                                          known: CodingKeys.allCases.map(\.rawValue))
    }
}

public final class Store: @unchecked Sendable {
    public let paths: Paths

    /// The library in memory, read and written only under `lock`.
    ///
    /// This was a plain stored property on a class the app shares across
    /// threads. Every action runs as a detached task and writes it through
    /// `mutate`; the main thread re-reads it through `refresh` on every
    /// activation and reads it to draw. The file lock serialises one write
    /// against another — including the CLI's — and did nothing for a read in
    /// the same process racing a write. Recursive, because the body passed to
    /// `mutate` routinely reads the store it is mutating.
    private let lock = NSRecursiveLock()
    private var _state: DecanterState
    private var _loadError: String?
    private var _unreadableBackup: URL?

    public var state: DecanterState { lock.lock(); defer { lock.unlock() }; return _state }

    /// Set when the file on disk could not be decoded. While it is set,
    /// nothing is written.
    public var loadError: String? { lock.lock(); defer { lock.unlock() }; return _loadError }

    /// Where the unreadable file was copied, when it was.
    public var unreadableBackup: URL? { lock.lock(); defer { lock.unlock() }; return _unreadableBackup }

    public init(paths: Paths = Paths()) throws {
        self.paths = paths
        try paths.ensure()
        self._state = DecanterState()
        if let d = try? Data(contentsOf: paths.statePath) {
            do {
                self._state = try JSONDecoder().decode(DecanterState.self, from: d)
            } catch {
                setAside(d, because: error)
            }
        }
    }

    /// Keeps a copy of a file that would not decode, and stops writing.
    ///
    /// Keeping the copy was already done. What was not done was stopping: the
    /// store carried on with an empty library, and the next change of any kind
    /// saved that empty library over the file. That is how a library of five
    /// games became an empty one on 27 August — with the copy sitting beside
    /// it and nothing in the app saying so.
    private func setAside(_ data: Data, because error: Error) {
        let backup = paths.root.appending(path: "state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: backup)
        _unreadableBackup = backup
        _loadError = "state.json could not be read (\(error)). A copy was kept at \(backup.lastPathComponent)."
    }

    public func save() throws {
        lock.lock(); defer { lock.unlock() }
        try saveLocked()
    }

    private func saveLocked() throws {
        guard _loadError == nil else {
            throw DecanterError.notReady(
                "Decanter could not read your library, so it is not writing anything over it. "
                + "A copy was kept at \(_unreadableBackup?.lastPathComponent ?? "state.json"). "
                + "Start a new library, or open it with a Decanter that can read it.")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // .atomic is a temp file plus rename, so a crash mid-write cannot
        // truncate the library. The merge puts back any field a newer version
        // wrote that this binary does not know about.
        let encoded = try enc.encode(_state)
        let merged = UnknownKeys.merge(_state.unknownKeys, into: encoded)
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
        // The file lock first, then the memory lock. Waiting for another
        // process to finish writing must not hold up a read on the main thread.
        let fd = open(lockPath.path, O_RDWR | O_CREAT, 0o644)
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        lock.lock(); defer { lock.unlock() }

        // Adopt whatever another process committed while we were idle. A file
        // that no longer decodes — a newer Decanter wrote a shape this one does
        // not know — used to be skipped here, and the stale copy in memory was
        // saved over it. Now it is set aside and nothing is written.
        if let d = try? Data(contentsOf: paths.statePath) {
            do {
                _state = try JSONDecoder().decode(DecanterState.self, from: d)
                _loadError = nil; _unreadableBackup = nil
            } catch {
                if _loadError == nil { setAside(d, because: error) }
            }
        }
        guard _loadError == nil else { try saveLocked(); return }
        try body(&_state)
        try saveLocked()
    }

    /// Pull in changes made by another process without mutating anything.
    /// A file that reads again ends read-only mode.
    public func refresh() {
        lock.lock(); defer { lock.unlock() }
        if let d = try? Data(contentsOf: paths.statePath),
           let disk = try? JSONDecoder().decode(DecanterState.self, from: d) {
            _state = disk
            _loadError = nil; _unreadableBackup = nil
        }
    }

    /// Gives up on a library that cannot be read, on purpose.
    ///
    /// The unreadable file is moved aside rather than deleted — a copy was
    /// already kept when it failed to load, and this keeps the original too.
    /// Nothing on disk that the library pointed at is touched.
    public func abandonUnreadable() throws {
        lock.lock(); defer { lock.unlock() }
        guard _loadError != nil else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.statePath.path) {
            let aside = paths.root.appending(path: "state.replaced-\(Int(Date().timeIntervalSince1970)).json")
            try fm.moveItem(at: paths.statePath, to: aside)
        }
        _state = DecanterState()
        _loadError = nil; _unreadableBackup = nil
        try saveLocked()
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
