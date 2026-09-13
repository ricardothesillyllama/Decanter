import Foundation

/// Finds, stores and restores game save data.
///
/// Discovery works by diffing a prefix against the golden template it was
/// cloned from: whatever exists in the prefix but not the template is, by
/// definition, something this game created. That needs no per-engine knowledge,
/// so it works for Unity, Ren'Py, RPG Maker, Godot, Unreal and whatever comes
/// next. The engine-specific table below is only used to give findings nice
/// names in the UI — never to decide what counts as a save.
public struct SaveStore {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    // MARK: Layout

    public func slug(for game: Game) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let s = game.name.lowercased().map { allowed.contains($0) ? $0 : "-" }
        var out = String(s)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Non-latin names collapse to nothing; fall back to the stable id.
        return trimmed.isEmpty ? game.id.uuidString.prefix(8).lowercased() : trimmed
    }

    public func gameRoot(_ game: Game) -> URL { paths.saves.appending(path: slug(for: game)) }
    public func liveRoot(_ game: Game) -> URL { gameRoot(game).appending(path: "live") }
    public func snapshotsRoot(_ game: Game) -> URL { gameRoot(game).appending(path: "snapshots") }

    // MARK: Discovery

    /// Directory names that never contain saves. Proven against a real 14GB
    /// Whisky library, where they separated 340KB of saves from 843MB of Unity
    /// asset cache and 672MB of crash dumps.
    static let cacheDirs: Set<String> = [
        "temp", "tmp", "cache", "cache2", "caches", "gpucache", "code cache",
        "shadercache", "grshadercache", "dawncache", "dawnwebgpucache", "crashpad",
        "crashdumps", "crashreports", "browsermetrics", "snapshots", "stability",
        "optimizationguidemodelstore", "component_crx_cache", "package cache",
        "cached", "soundscached", "logs", "webrtc event logs", "segmentation platform",
        "extensions_crx_cache", "graphitedawncache", "service worker", "programs",
        "vulkan", "shader_cache", "pipeline_cache", "d3dcache", "nvidia",
        "analytics", "archivedevents", "unityanalytics", "diagnostics",
        // Windows' own caches. INetCache in particular fills up with
        // index.dat and Content.IE5 junk that is never a save.
        "inetcache", "content.ie5", "inetcookies", "webcache", "temporary internet files",
    ]

    /// Files that are never saves however they are named.
    ///
    /// Extension alone is not enough: Unity writes its player log as
    /// `output_log.txt`, so it slips past a `.log` filter and then shows up as
    /// a 400 KB "save" — offered for backup, and counted as progress at risk.
    static let skipFileNames: Set<String> = [
        "output_log.txt", "player.log", "player-prev.log", "prev_output_log.txt",
        "logoutput.log", "error.log", "debug.log", "index.dat", "unityplayer.log",
        "crash.dmp", "thumbs.db", ".ds_store",
    ]
    static let skipExtensions: Set<String> = ["tmp", "log", "pma", "old", "dmp", "exe",
                                              "msi", "dll", "asar", "node", "pak", "cache"]

    /// True for anything that is not worth backing up or warning about.
    public static func isNoise(_ file: URL) -> Bool {
        let name = file.lastPathComponent.lowercased()
        if skipFileNames.contains(name) { return true }
        if skipExtensions.contains(file.pathExtension.lowercased()) { return true }
        // Rolled logs: output_log.1.txt, Player-prev.log, and friends.
        if name.hasSuffix(".txt"), name.contains("_log") || name.hasSuffix("log.txt") { return true }
        return false
    }

    /// A recognised save location, used purely for labelling.
    static func label(for relPath: String) -> String? {
        let p = relPath.lowercased()
        if p.contains("appdata/locallow") { return "Unity" }
        if p.contains("appdata/roaming/renpy") { return "Ren'Py" }
        if p.contains("appdata/roaming/godot") { return "Godot" }
        if p.contains("saved/savegames") { return "Unreal" }
        if p.contains("user data/default/local storage") { return "RPG Maker / nw.js" }
        if p.hasPrefix("programdata") { return "shared app data" }
        if p.contains("/documents/") || p.contains("saved games") { return "Documents" }
        if p.contains("appdata/roaming") { return "Roaming" }
        if p.contains("appdata/local") { return "Local" }
        return nil
    }

    public struct Finding: Sendable {
        public var relPath: String       // relative to drive_c
        public var bytes: Int
        public var modified: Date
        public var label: String?
    }

    public struct Discovery: Sendable {
        public var files: [Finding] = []
        public var registryKeys: [String] = []
        public var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }
        public var isEmpty: Bool { files.isEmpty && registryKeys.isEmpty }
    }

    /// Relative path of `url` under `base`, computed from path components after
    /// resolving symlinks. String surgery on `.path` breaks whenever the two
    /// disagree about symlinks — macOS returns /private/var for /var, which
    /// silently yields an absolute path instead of a relative one.
    static func relativePath(of url: URL, under base: URL) -> String? {
        let b = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let u = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else { return nil }
        return u.dropFirst(b.count).joined(separator: "/")
    }

    public static func isCachePath(_ comps: [String]) -> Bool {
        for c in comps {
            let l = c.lowercased()
            if cacheDirs.contains(l) { return true }
            // Unity's opaque 32-hex asset-cache directories.
            if l.count == 32, l.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { return true }
            if l.hasSuffix("-updater") || l.hasSuffix("-installer") { return true }
        }
        return false
    }

    /// Everything in `prefix` that is not in the template it was cloned from.
    public func discover(in prefix: URL, template: URL? = nil) -> Discovery {
        var d = Discovery()
        let template = template ?? paths.template
        let roots = ["drive_c/users", "drive_c/ProgramData"]

        for root in roots {
            let base = prefix.appending(path: root)
            guard fm.fileExists(atPath: base.path) else { continue }
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys:
                    [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else { continue }

            for case let f as URL in en {
                guard let rel = Self.relativePath(of: f, under: prefix) else { continue }
                let comps = rel.split(separator: "/").map(String.init)
                if Self.isCachePath(comps) { en.skipDescendants(); continue }
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                if Self.isNoise(f) { continue }
                // In the template => shipped by Wine, not written by the game.
                if fm.fileExists(atPath: template.appending(path: rel).path) { continue }
                let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let relFromDriveC = rel.replacingOccurrences(of: "drive_c/", with: "")
                d.files.append(Finding(relPath: rel,
                                       bytes: vals?.fileSize ?? 0,
                                       modified: vals?.contentModificationDate ?? .distantPast,
                                       label: Self.label(for: relFromDriveC)))
            }
        }
        d.registryKeys = discoverRegistryKeys(in: prefix, template: template)
        return d
    }

    /// Discovery for a game, following externalised saves. Once save folders
    /// are symlinked out of the prefix the in-prefix walk finds only symlinks,
    /// so snapshots would silently capture nothing without this.
    public func discoverEffective(game: Game, prefix: URL, template: URL? = nil) -> Discovery {
        var d = discover(in: prefix, template: template)
        let live = liveRoot(game)
        guard fm.fileExists(atPath: live.path) else { return d }
        guard let en = fm.enumerator(at: live, includingPropertiesForKeys:
                [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return d }
        var seen = Set(d.files.map(\.relPath))
        for case let f as URL in en {
            guard let rel = Self.relativePath(of: f, under: live) else { continue }
            let comps = rel.split(separator: "/").map(String.init)
            if Self.isCachePath(comps) { en.skipDescendants(); continue }
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if Self.isNoise(f) { continue }
            guard !seen.contains(rel) else { continue }
            seen.insert(rel)
            let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            d.files.append(Finding(relPath: rel, bytes: vals?.fileSize ?? 0,
                                   modified: vals?.contentModificationDate ?? .distantPast,
                                   label: Self.label(for: rel.replacingOccurrences(of: "drive_c/", with: ""))))
        }
        return d
    }

    /// Resolves where a discovered file actually lives right now — inside the
    /// prefix, or out in the store if this game has been externalised.
    func sourceURL(for rel: String, game: Game, prefix: URL) -> URL {
        let live = liveRoot(game).appending(path: rel)
        if fm.fileExists(atPath: live.path) { return live }
        return prefix.appending(path: rel)
    }

    /// Registry keys the game added, found the same way: by diffing user.reg
    /// against the template's. Unity keeps PlayerPrefs here, so missing this
    /// loses settings and, for some games, progress.
    public func discoverRegistryKeys(in prefix: URL, template: URL? = nil) -> [String] {
        func keys(_ url: URL) -> Set<String> {
            guard let t = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            var out = Set<String>()
            for line in t.split(whereSeparator: \.isNewline) where line.hasPrefix("[") {
                if let close = line.lastIndex(of: "]") {
                    out.insert(String(line[line.index(after: line.startIndex)..<close]))
                }
            }
            return out
        }
        let mine = keys(prefix.appending(path: "user.reg"))
        let base = keys((template ?? paths.template).appending(path: "user.reg"))
        // Ignore Wine's own bookkeeping.
        return mine.subtracting(base)
            .filter { !$0.hasPrefix("Software\\\\Wine") && !$0.hasPrefix("Software\\\\Microsoft") }
            .sorted()
    }

    /// Extracts the game's registry keys as an importable Wine-internal fragment.
    public func exportRegistry(from prefix: URL, keys: [String]) -> String? {
        guard !keys.isEmpty,
              let text = try? String(contentsOf: prefix.appending(path: "user.reg"), encoding: .utf8)
        else { return nil }
        let wanted = Set(keys)
        var out = ["WINE REGISTRY Version 2", ""]
        var keep = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let l = String(line)
            if l.hasPrefix("[") {
                let name = l.lastIndex(of: "]").map { String(l[l.index(after: l.startIndex)..<$0]) } ?? ""
                keep = wanted.contains(name)
            }
            if keep { out.append(l) }
        }
        return out.count > 2 ? out.joined(separator: "\n") + "\n" : nil
    }

    // MARK: Windows user normalisation

    /// Wine names the Windows user after the host user, but GPTK inherits
    /// CrossOver's habit of calling it "crossover". A prefix built by one and
    /// re-derived under the other therefore looks in a different folder — the
    /// game finds nothing and starts a fresh save. The store is kept
    /// user-agnostic so saves follow the game across runtimes.
    public static let userPlaceholder = "__user__"

    public func prefixUser(_ prefix: URL) -> String {
        let users = prefix.appending(path: "drive_c/users")
        let names = (try? fm.contentsOfDirectory(atPath: users.path)) ?? []
        return names.first { $0 != "Public" && !$0.hasPrefix(".") } ?? NSUserName()
    }

    /// drive_c/users/<anyone>/... -> drive_c/users/__user__/...
    static func canonicalise(_ rel: String) -> String {
        var c = rel.split(separator: "/").map(String.init)
        if c.count > 2, c[0] == "drive_c", c[1].lowercased() == "users", c[2] != "Public" {
            c[2] = userPlaceholder
        }
        return c.joined(separator: "/")
    }

    /// drive_c/users/__user__/... -> drive_c/users/<this prefix's user>/...
    func concretise(_ rel: String, prefix: URL) -> String {
        guard rel.contains(Self.userPlaceholder) else { return rel }
        return rel.replacingOccurrences(of: "users/\(Self.userPlaceholder)",
                                        with: "users/\(prefixUser(prefix))")
    }

    // MARK: Externalisation

    /// The top-most directories the game created — i.e. the shallowest paths
    /// that exist in the prefix but not the template. Externalising at this
    /// level is precise: only game-made directories move, never Wine's own.
    public func saveRoots(in prefix: URL, template: URL? = nil) -> [String] {
        let tpl = template ?? paths.template
        let d = discover(in: prefix, template: tpl)
        var roots = Set<String>()
        for f in d.files {
            let comps = f.relPath.split(separator: "/").map(String.init)
            var walk: [String] = []
            for c in comps.dropLast() {
                walk.append(c)
                let rel = walk.joined(separator: "/")
                if !fm.fileExists(atPath: tpl.appending(path: rel).path) {
                    roots.insert(rel); break
                }
            }
        }
        // Drop any root nested inside another.
        return roots.filter { r in !roots.contains { $0 != r && r.hasPrefix($0 + "/") } }.sorted()
    }

    public struct Externalisation: Sendable {
        public var moved: [String] = []
        public var alreadyLinked: [String] = []
        public var bytes: Int = 0
    }

    /// Moves the game's save directories out of the prefix into the store and
    /// symlinks them back. Once done, re-deriving the prefix no longer
    /// destroys saves — the reason this exists.
    @discardableResult
    public func externalise(game: Game, prefix: URL, template: URL? = nil,
                            progress: (String) -> Void = { _ in }) throws -> Externalisation {
        var out = Externalisation()
        let live = liveRoot(game)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)

        for rel in saveRoots(in: prefix, template: template) {
            let inPrefix = prefix.appending(path: rel)
            let inStore = live.appending(path: Self.canonicalise(rel))
            // Already a symlink? Nothing to do.
            if (try? fm.destinationOfSymbolicLink(atPath: inPrefix.path)) != nil {
                out.alreadyLinked.append(rel); continue
            }
            guard fm.fileExists(atPath: inPrefix.path) else { continue }
            try fm.createDirectory(at: inStore.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: inStore.path) {
                // Store already holds a copy: prefer it, discard the prefix one.
                try fm.removeItem(at: inPrefix)
            } else {
                try fm.moveItem(at: inPrefix, to: inStore)
            }
            try fm.createSymbolicLink(atPath: inPrefix.path, withDestinationPath: inStore.path)
            out.moved.append(rel)
            out.bytes += Self.dirSize(inStore)
            progress("externalised \(rel)")
        }
        return out
    }

    /// Re-applies the symlinks after a prefix has been re-derived. This is what
    /// makes "throw the prefix away" safe.
    @discardableResult
    public func relink(game: Game, prefix: URL, template: URL? = nil,
                       progress: (String) -> Void = { _ in }) throws -> Int {
        let live = liveRoot(game)
        guard fm.fileExists(atPath: live.path) else { return 0 }
        let tpl = template ?? paths.template
        var n = 0
        guard let en = fm.enumerator(at: live, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var roots: [String] = []
        for case let u as URL in en {
            guard (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let rel = Self.relativePath(of: u, under: live) else { continue }
            // Only link the shallowest directories that exist in the store.
            if roots.contains(where: { rel.hasPrefix($0 + "/") }) { en.skipDescendants(); continue }
            // A directory the template also has is structural — walk deeper.
            // The user placeholder must be resolved first, or every path below
            // it looks novel and we would symlink the entire Windows profile,
            // dragging caches into the store.
            if fm.fileExists(atPath: tpl.appending(path: concretise(rel, prefix: prefix)).path) { continue }
            roots.append(rel)
            en.skipDescendants()
        }
        for rel in roots {
            let inPrefix = prefix.appending(path: concretise(rel, prefix: prefix))
            let inStore = live.appending(path: rel)
            try? fm.createDirectory(at: inPrefix.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: inPrefix.path) || (try? fm.destinationOfSymbolicLink(atPath: inPrefix.path)) != nil {
                try? fm.removeItem(at: inPrefix)
            }
            try fm.createSymbolicLink(atPath: inPrefix.path, withDestinationPath: inStore.path)
            n += 1
            progress("relinked \(rel)")
        }
        return n
    }

    public func isExternalised(game: Game) -> Bool {
        fm.fileExists(atPath: liveRoot(game).path)
    }

    static func dirSize(_ url: URL) -> Int {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var t = 0
        for case let f as URL in en { t += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return t
    }

    // MARK: Snapshots

    public struct Snapshot: Sendable, Identifiable {
        public var id: String { name }
        public var name: String            // ISO-ish timestamp
        public var url: URL
        public var created: Date
        public var bytes: Int
        public var fileCount: Int
        public var hasRegistry: Bool
        public var note: String?
    }

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = .current
        return f.string(from: d)
    }

    /// Copies the discovered save set into a timestamped snapshot. Uses APFS
    /// cloning, so this is effectively free and instant.
    @discardableResult
    public func snapshot(game: Game, prefix: URL, template: URL? = nil, note: String? = nil,
                         progress: (String) -> Void = { _ in }) throws -> Snapshot {
        let d = discoverEffective(game: game, prefix: prefix, template: template)
        // Timestamps are second-resolution, so two snapshots in the same second
        // would collide and silently overwrite one another.
        var name = Self.stamp()
        var dir = snapshotsRoot(game).appending(path: name)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            name = "\(Self.stamp())-\(n)"
            dir = snapshotsRoot(game).appending(path: name)
            n += 1
        }
        try fm.createDirectory(at: dir.appending(path: "files"), withIntermediateDirectories: true)

        var bytes = 0
        var failed: [String] = []
        for f in d.files {
            let src = sourceURL(for: f.relPath, game: game, prefix: prefix)
            let dst = dir.appending(path: "files").appending(path: f.relPath)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            // clonefile where possible; fall back to a plain copy.
            let r = try? Shell.run(URL(filePath: "/bin/cp"), ["-c", src.path, dst.path], timeout: 120)
            if r?.code != 0 {
                // A clone that failed part-way can leave a stub behind, and a
                // stub makes the fallback copy fail too.
                try? fm.removeItem(at: dst)
                do { try fm.copyItem(at: src, to: dst) } catch { failed.append(f.relPath); continue }
            }
            bytes += f.bytes
        }
        // Both copies used to be `try?`, so a file that could not be read was
        // skipped and the manifest still counted it. Removing a game with
        // "keep saves", rebuilding one and switching its engine all delete the
        // prefix straight after this returns — so a snapshot that quietly
        // missed a file was a save deleted under a message saying it was kept.
        if !failed.isEmpty {
            try? fm.removeItem(at: dir)
            throw DecanterError.badFile(
                "\(failed.count == 1 ? "A save file" : "\(failed.count) save files") could not be copied into a snapshot, so nothing that would delete the originals went ahead. The first was \(failed[0]).")
        }
        if let reg = exportRegistry(from: prefix, keys: d.registryKeys) {
            try reg.write(to: dir.appending(path: "registry.reg"), atomically: true, encoding: .utf8)
        }
        let manifest: [String: Any] = [
            "game": game.name, "created": ISO8601DateFormatter().string(from: Date()),
            "files": d.files.count, "bytes": bytes,
            "registryKeys": d.registryKeys, "note": note ?? "",
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appending(path: "manifest.json"))
        progress("snapshot \(name): \(d.files.count) files, \(bytes / 1024) KB")
        return Snapshot(name: name, url: dir, created: Date(), bytes: bytes,
                        fileCount: d.files.count,
                        hasRegistry: !d.registryKeys.isEmpty, note: note)
    }

    public func snapshots(for game: Game) -> [Snapshot] {
        let root = snapshotsRoot(game)
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { n -> Snapshot? in
            let dir = root.appending(path: n)
            guard let data = try? Data(contentsOf: dir.appending(path: "manifest.json")),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let created = (m["created"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
            let note = (m["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Snapshot(name: n, url: dir, created: created,
                            bytes: m["bytes"] as? Int ?? 0,
                            fileCount: m["files"] as? Int ?? 0,
                            hasRegistry: !((m["registryKeys"] as? [String]) ?? []).isEmpty,
                            note: note)
        }.sorted { $0.created > $1.created }
    }

    /// Restores a snapshot back into a prefix, merging registry keys last.
    @discardableResult
    public func restore(_ snap: Snapshot, game: Game, into prefix: URL, runtime: RuntimeSpec?,
                        progress: (String) -> Void = { _ in }) throws -> Int {
        let filesRoot = snap.url.appending(path: "files")
        var restored = 0
        if let en = fm.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in en {
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard let rel = Self.relativePath(of: f, under: filesRoot) else { continue }
                // Write back to wherever this game's saves live now: into the
                // store if externalised (the symlink would otherwise be
                // replaced by a real file, silently detaching the game).
                let liveTarget = liveRoot(game).appending(path: rel)
                let dst = fm.fileExists(atPath: liveRoot(game).path)
                    ? liveTarget : prefix.appending(path: rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try fm.copyItem(at: f, to: dst)
                restored += 1
            }
        }
        let reg = snap.url.appending(path: "registry.reg")
        if fm.fileExists(atPath: reg.path), let rt = runtime {
            progress("merging registry keys")
            let importer = SaveImporter()
            _ = try? importer.mergeRegistry(reg, into: prefix, runtime: rt)
        }
        progress("restored \(restored) files from \(snap.name)")
        return restored
    }

    public func prune(game: Game, keep: Int) throws -> Int {
        let all = snapshots(for: game)
        guard all.count > keep else { return 0 }
        var removed = 0
        for s in all.dropFirst(keep) { try? fm.removeItem(at: s.url); removed += 1 }
        return removed
    }

    /// Saves kept from a game that is no longer in the library.
    public struct OrphanedStore: Sendable, Identifiable, Hashable {
        public var id: String { slug }
        public var slug: String
        public var url: URL
        public var bytes: Int
        /// Save files held, counted once: the live folder if the game's saves
        /// were protected, otherwise the newest snapshot.
        public var savedFiles: Int
        public var snapshotCount: Int
        public var lastModified: Date?
        /// The game's name as the newest snapshot recorded it. Local only —
        /// read from this Mac's own store and shown on this Mac's own screen.
        public var recordedName: String?
    }

    /// Save stores with no game pointing at them — left behind deliberately by
    /// removing a game with "keep saves".
    ///
    /// This existed and nothing called it, so saves kept on purpose were
    /// invisible everywhere: the Saves page lists only games in the library,
    /// and a removed game is by definition not one. Stores holding no save
    /// files at all are left out; there is nothing in them to find.
    public func orphanedStores(knownSlugs: Set<String>) -> [OrphanedStore] {
        let names = (try? fm.contentsOfDirectory(atPath: paths.saves.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !knownSlugs.contains($0) }
            .compactMap { n -> OrphanedStore? in
                let u = paths.saves.appending(path: n)
                let live = Self.regularFiles(under: u.appending(path: "live"))
                let snapRoot = u.appending(path: "snapshots")
                let snaps = ((try? fm.contentsOfDirectory(atPath: snapRoot.path)) ?? [])
                    .filter { fm.fileExists(atPath: snapRoot.appending(path: "\($0)/manifest.json").path) }
                    .sorted(by: >)
                var name: String?
                var newestFiles = 0
                if let newest = snaps.first {
                    let dir = snapRoot.appending(path: newest)
                    newestFiles = Self.regularFiles(under: dir.appending(path: "files")).count
                    if let data = try? Data(contentsOf: dir.appending(path: "manifest.json")),
                       let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let g = m["game"] as? String, !g.isEmpty { name = g }
                }
                let files = max(live.count, newestFiles)
                guard files > 0 else { return nil }
                let modified = (live + Self.regularFiles(under: snapRoot))
                    .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                    .max()
                return OrphanedStore(slug: n, url: u, bytes: Self.dirSize(u), savedFiles: files,
                                     snapshotCount: snaps.count, lastModified: modified,
                                     recordedName: name)
            }
            .sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
    }

    /// Deletes one kept store, and refuses anything that is not one.
    ///
    /// The slug arrives from a list on screen, but it names a directory, so it
    /// is checked as if it came from anywhere: a current game's store, a path,
    /// or a hidden entry is refused rather than resolved.
    public func deleteOrphanedStore(slug: String, knownSlugs: Set<String>) throws {
        guard !slug.isEmpty, !slug.hasPrefix("."), !slug.contains("/"), !slug.contains("\\") else {
            throw DecanterError.usage("\(slug) is not the name of a kept save store")
        }
        guard !knownSlugs.contains(slug) else {
            throw DecanterError.usage("those saves belong to a game still in the library")
        }
        let u = paths.saves.appending(path: slug)
        guard u.deletingLastPathComponent().pathKey == paths.saves.pathKey,
              fm.fileExists(atPath: u.path) else {
            throw DecanterError.notFound("kept saves called \(slug)")
        }
        try fm.removeItem(at: u)
    }

    /// Moves a kept store out of the way of a new game with the same name.
    ///
    /// Stores are named after games, so a removed game's kept saves and a new
    /// game of that name would otherwise share one folder — and everything
    /// that reads the folder would take the old saves for the new game's own.
    /// Returns the name it was moved to, or nil when there was nothing there.
    @discardableResult
    public func setAsideKeptStore(for game: Game) throws -> String? {
        let root = gameRoot(game)
        guard fm.fileExists(atPath: root.path) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(slug(for: game))--kept-\(f.string(from: Date()))"
        var name = base, n = 2
        while fm.fileExists(atPath: paths.saves.appending(path: name).path) { name = "\(base)-\(n)"; n += 1 }
        try fm.moveItem(at: root, to: paths.saves.appending(path: name))
        return name
    }

    /// Kept stores that match this game by name: set aside from a game of the
    /// same name, or recorded under that name by their last snapshot.
    ///
    /// A matching name is all Decanter has, which is why this finds and the
    /// person decides — two different games can share one.
    public func keptStores(matching game: Game, knownSlugs: Set<String>) -> [OrphanedStore] {
        let mine = slug(for: game)
        return orphanedStores(knownSlugs: knownSlugs).filter { o in
            if o.slug.hasPrefix(mine + "--kept-") { return true }
            if let n = o.recordedName { return n.caseInsensitiveCompare(game.name) == .orderedSame }
            return false
        }
    }

    /// Brings a kept store's saves into a game and folds its snapshots into
    /// the game's own history, then removes the kept store.
    ///
    /// The files come from the live folder when the game had been protected —
    /// that is the newest copy there is — and otherwise from the newest
    /// snapshot that holds any. Paths are carried across Windows users, since
    /// the environment they were saved in may have named its user differently.
    /// The caller snapshots the game's current saves first.
    @discardableResult
    public func adopt(keptSlug: String, into game: Game, prefix: URL, runtime: RuntimeSpec?,
                      knownSlugs: Set<String>, progress: (String) -> Void = { _ in }) throws -> Int {
        guard !keptSlug.isEmpty, !keptSlug.hasPrefix("."), !keptSlug.contains("/"),
              !keptSlug.contains("\\"), !knownSlugs.contains(keptSlug) else {
            throw DecanterError.usage("\(keptSlug) is not a store of kept saves")
        }
        let kept = paths.saves.appending(path: keptSlug)
        guard kept.deletingLastPathComponent().pathKey == paths.saves.pathKey,
              fm.fileExists(atPath: kept.path) else {
            throw DecanterError.notFound("kept saves called \(keptSlug)")
        }
        let live = kept.appending(path: "live")
        let snapRoot = kept.appending(path: "snapshots")
        let snaps = ((try? fm.contentsOfDirectory(atPath: snapRoot.path)) ?? [])
            .filter { fm.fileExists(atPath: snapRoot.appending(path: "\($0)/manifest.json").path) }
            .sorted(by: >)

        var source: URL?
        if !Self.regularFiles(under: live).isEmpty {
            source = live
        } else if let s = snaps.first(where: { !Self.regularFiles(under: snapRoot.appending(path: "\($0)/files")).isEmpty }) {
            source = snapRoot.appending(path: "\(s)/files")
        }

        let externalised = fm.fileExists(atPath: liveRoot(game).path)
        var copied = 0
        if let source {
            for f in Self.regularFiles(under: source) {
                guard let rel = Self.relativePath(of: f, under: source) else { continue }
                let canonical = Self.canonicalise(rel)
                let dst = externalised
                    ? liveRoot(game).appending(path: canonical)
                    : prefix.appending(path: concretise(canonical, prefix: prefix))
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: f, to: dst)
                copied += 1
            }
        }
        if let rt = runtime,
           let s = snaps.first(where: { fm.fileExists(atPath: snapRoot.appending(path: "\($0)/registry.reg").path) }) {
            progress("merging registry keys from the kept saves")
            _ = try? SaveImporter().mergeRegistry(snapRoot.appending(path: "\(s)/registry.reg"),
                                                  into: prefix, runtime: rt)
        }
        let history = snapshotsRoot(game)
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        for s in snaps {
            var name = s, n = 2
            while fm.fileExists(atPath: history.appending(path: name).path) { name = "\(s)-\(n)"; n += 1 }
            try? fm.moveItem(at: snapRoot.appending(path: s), to: history.appending(path: name))
        }
        try fm.removeItem(at: kept)
        progress("brought back \(copied) save file\(copied == 1 ? "" : "s")")
        return copied
    }

    static func regularFiles(under url: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let f as URL in en where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.append(f)
        }
        return out
    }

    public func deleteAll(for game: Game) throws {
        let r = gameRoot(game)
        if fm.fileExists(atPath: r.path) { try fm.removeItem(at: r) }
    }
}
