import Foundation

/// Restores extracted save data into a freshly derived prefix.
///
/// Two things make this more than a file copy:
///  1. Saves come from a prefix whose Windows user was someone else
///     ("crossover"), so `users/<old>/...` must be remapped to this prefix's user.
///  2. Unity games keep PlayerPrefs in the *registry*, not in files, so
///     .reg fragments have to be merged or the game loses its settings and,
///     for some titles, its progress.
public struct SaveImporter {
    let fm = FileManager.default
    public init() {}

    public struct Report: Sendable {
        public var filesCopied: Int = 0
        public var bytesCopied: Int = 0
        public var regFilesMerged: [String] = []
        public var remappedUsers: Set<String> = []
        public var skipped: [String] = []
        /// True when the source had no drive_c and a location was inferred.
        public var inferredLayout = false
    }

    /// Placeholder swapped for the destination prefix's Windows user.
    let targetPlaceholder = "__target_user__"

    func relativeComponents(of url: URL, under base: URL) -> [String]? {
        let b = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let u = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else { return nil }
        return Array(u.dropFirst(b.count))
    }

    /// The Windows user name inside a prefix (Wine names it after the host user).
    public func prefixUser(_ prefix: URL) -> String {
        let users = prefix.appending(path: "drive_c/users")
        let names = (try? fm.contentsOfDirectory(atPath: users.path)) ?? []
        return names.first { $0 != "Public" && !$0.hasPrefix(".") }
            ?? NSUserName()
    }

    @discardableResult
    public func importSaves(from source: URL, into bottle: Bottle,
                            runtime: RuntimeSpec,
                            progress: (String) -> Void = { _ in }) throws -> Report {
        var report = Report()
        let target = prefixUser(bottle.prefixPath)

        guard let en = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw DecanterError.notFound(source.path)
        }
        var regFiles: [URL] = []
        for case let f as URL in en {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if f.pathExtension.lowercased() == "reg" { regFiles.append(f); continue }
            if f.lastPathComponent.hasPrefix("_") || f.lastPathComponent.hasPrefix(".") { continue }

            // Locate the drive_c-relative portion of this path.
            let comps = f.pathComponents
            var rel: [String]
            if let idx = comps.lastIndex(of: "drive_c") {
                rel = Array(comps[(idx + 1)...])
            } else {
                // A bare Vendor/Product tree (how people usually hand save data
                // around) has no drive_c. Unity keeps that layout under
                // AppData/LocalLow, which is where it must land to be found.
                guard let r = relativeComponents(of: f, under: source) else {
                    report.skipped.append(f.lastPathComponent); continue
                }
                // Include the source folder's own name: people hand over the
                // vendor directory, and Unity's layout is
                // LocalLow/<Vendor>/<Product>. Dropping it puts the product
                // one level too high and the game finds nothing.
                rel = ["users", targetPlaceholder, "AppData", "LocalLow",
                       source.lastPathComponent] + r
                report.inferredLayout = true
            }
            // users/<whoever>/... -> users/<this prefix's user>/...
            if rel.count > 2, rel[0].lowercased() == "users", rel[1] != target {
                if rel[1] != targetPlaceholder { report.remappedUsers.insert(rel[1]) }
                rel[1] = target
            }
            let dest = bottle.prefixPath.appending(path: "drive_c")
                .appending(path: rel.joined(separator: "/"))
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: f, to: dest)
            report.filesCopied += 1
            report.bytesCopied += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }

        // Merge registry fragments last, so files are in place first.
        for reg in regFiles {
            progress("merging registry \(reg.lastPathComponent)")
            do {
                let keys = try mergeRegistry(reg, into: bottle.prefixPath, runtime: runtime)
                report.regFilesMerged.append(keys >= 0 ? "\(reg.lastPathComponent) (\(keys) keys)"
                                                       : reg.lastPathComponent)
            } catch {
                report.skipped.append("\(reg.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }
}

extension SaveImporter {
    /// Merges a .reg fragment into a prefix. Two traps handled here, both of
    /// which fail silently: Wine's internal user.reg syntax is NOT importable
    /// .reg syntax (regedit exits 0 and imports nothing), and the file must be
    /// UTF-16LE with a BOM or non-ASCII key names arrive mangled.
    /// Returns the number of keys converted, or -1 if it was already .reg format.
    @discardableResult
    public func mergeRegistry(_ reg: URL, into prefix: URL, runtime: RuntimeSpec) throws -> Int {
        let fm = FileManager.default
        guard var text = try? String(contentsOf: reg, encoding: .utf8) else {
            throw DecanterError.notFound("unreadable registry file")
        }
        var keyCount = -1
        if WineRegConverter.isWineInternal(text) {
            let hive = reg.lastPathComponent.lowercased().contains("system")
                ? "HKEY_LOCAL_MACHINE" : "HKEY_CURRENT_USER"
            let c = WineRegConverter().convert(text, hive: hive)
            text = c.text; keyCount = c.keyCount
        }
        // There is no z: drive, so Wine cannot see host paths — stage inside.
        let tempDir = prefix.appending(path: "drive_c/windows/temp")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let staged = tempDir.appending(path: "decanter-import.reg")
        var blob = Data([0xFF, 0xFE])
        for u in Array(text.utf16) {
            blob.append(UInt8(u & 0xff)); blob.append(UInt8((u >> 8) & 0xff))
        }
        try blob.write(to: staged, options: .atomic)
        defer { try? fm.removeItem(at: staged) }

        let env = PrefixBuilder(paths: Paths()).baseEnv(prefix: prefix, runtime: runtime)
        let r = try Shell.run(runtime.winePath,
                              ["regedit", #"C:\\windows\\temp\\decanter-import.reg"#],
                              env: env, timeout: 180)
        guard r.code == 0 else {
            throw DecanterError.launchFailed("regedit exit \(r.code): \(r.err.suffix(120))")
        }
        return keyCount
    }
}
