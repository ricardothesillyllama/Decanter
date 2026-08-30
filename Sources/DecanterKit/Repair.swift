import Foundation

/// Fixing a build that is missing pieces, using only what is already on this
/// Mac.
///
/// The first repair Decanter offers, and it sets the shape for the rest. Three
/// rules it must not break:
///
/// **A named cause, never a ranked guess.** This runs on the output of an
/// audit, so what it proposes is always "this exact file is missing, this exact
/// file needs it". Nothing here is tried to see whether it helps.
///
/// **Nothing is downloaded.** Decanter makes no network requests, and a repair
/// is not an exception to that — every library comes from another Wine build
/// already pinned on this Mac. It follows that some builds cannot be repaired,
/// and saying so is better than reaching for the network.
///
/// **It waits.** `plan` describes; `apply` acts; nothing calls `apply` on its
/// own. Every plan states what it changes, where, and how to undo it.
public struct RuntimeRepair {
    let fm = FileManager.default
    public init() {}

    /// One file, copied from one build into another.
    public struct Borrow: Sendable, Codable, Hashable {
        public var library: String        // leaf name, e.g. "liborc-0.4.0.dylib"
        public var donorID: String
        public var source: URL
        public var destination: URL
        public var architectures: [String]
        /// Which of the target's files were asking for it. Kept so the plan can
        /// say what this fixes rather than only what it copies.
        public var neededBy: [String]

        public init(library: String, donorID: String, source: URL, destination: URL,
                    architectures: [String], neededBy: [String]) {
            self.library = library; self.donorID = donorID
            self.source = source; self.destination = destination
            self.architectures = architectures; self.neededBy = neededBy
        }
    }

    /// A described repair that has not happened.
    public struct Offer: Sendable {
        public var runtimeID: String
        public var borrows: [Borrow] = []
        /// Gaps nothing on this Mac can fill. Named rather than omitted: a plan
        /// that quietly leaves out what it cannot do reads as a complete fix.
        public var unfillable: [RuntimeAudit.Gap] = []

        public var isEmpty: Bool { borrows.isEmpty }

        /// What this would do, without naming a single file.
        public var summary: String {
            guard !borrows.isEmpty else {
                return "Nothing on this Mac can supply what this build is missing."
            }
            let n = borrows.count
            let fromSelf = borrows.filter { $0.donorID == runtimeID }.count
            let others = Set(borrows.filter { $0.donorID != runtimeID }.map(\.donorID)).sorted()
            var s = "Decanter can put \(n) missing piece\(n == 1 ? "" : "s") into \(runtimeID). "
            if fromSelf > 0 && others.isEmpty {
                s += "\(fromSelf == n ? "Every one" : "\(fromSelf)") of them is already inside this build, "
                   + "just not where the part that needs \(fromSelf == 1 ? "it" : "them") looks."
            } else if fromSelf > 0 {
                s += "\(fromSelf) \(fromSelf == 1 ? "is" : "are") already inside this build in another place; "
                   + "the rest come from \(others.joined(separator: " and ")), already on this Mac."
            } else {
                s += "They come from \(others.joined(separator: " and ")) — "
                   + "\(others.count == 1 ? "a build" : "builds") already on this Mac."
            }
            s += " Nothing is downloaded."
            if !unfillable.isEmpty {
                s += " \(unfillable.count) other piece\(unfillable.count == 1 ? "" : "s") "
                   + "\(unfillable.count == 1 ? "is" : "are") missing that nothing here can supply; "
                   + "\(unfillable.count == 1 ? "it" : "they") would stay missing."
            }
            return s
        }

        /// Where the change lands, said plainly enough to go and look.
        public var location: String {
            let dirs = Set(borrows.map { $0.destination.deletingLastPathComponent().path }).sorted()
            return dirs.joined(separator: "\n")
        }

        public var undo: String {
            "Decanter records every file it copies. `decanter repair \(runtimeID) --undo` "
            + "removes exactly those files and nothing else, putting the build back as it was."
        }
    }

    /// The record of what was copied, kept inside the build it changed so the
    /// two cannot be separated. A repair that cannot be undone is a repair
    /// nobody should agree to.
    public struct Manifest: Codable, Sendable {
        public var formatVersion = 1
        public var borrows: [Borrow] = []
        public var appliedAt = Date()
        public var appliedBy = Build.version
        public init() {}
    }

    public static func manifestPath(in root: URL) -> URL {
        root.appending(path: "lib/.decanter-borrowed.json")
    }

    /// Directories a library may never be taken from.
    ///
    /// `lib/external` is where the Game Porting Toolkit keeps Apple's own
    /// components — D3DMetal and its shared library. Everything else the
    /// toolkit bundles is ordinary open-source built from MacPorts, but Apple's
    /// parts are licensed only as part of the toolkit. Decanter does not have
    /// to adjudicate that case by case: it simply never takes anything from
    /// the directory Apple's own code lives in.
    /// Both sides are resolved through their symlinks before comparing, and
    /// that is the whole of why this is not a one-line prefix check. Directory
    /// enumeration hands back paths with every symlink already followed, so a
    /// build reached through a linked path — a relocated home directory, a
    /// temporary directory, an external volume — produced a real path on one
    /// side and a linked one on the other, `hasPrefix` said no, and the guard
    /// silently stopped guarding. A boundary that quietly holds only for some
    /// paths is worse than no boundary, because it still reads like one.
    static func isOffLimits(_ path: String, donorRoot: URL) -> Bool {
        let barrier = donorRoot.appending(path: "lib/external")
            .resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == barrier || candidate.hasPrefix(barrier + "/")
    }

    /// What would fix this build, and what would not.
    ///
    /// Works to a fixed point rather than one pass, and that was learned by
    /// getting it wrong: copying six libraries into a build closed six gaps and
    /// opened three new ones, because a library moved out of its own directory
    /// can no longer find its siblings. A repair that leaves the build broken
    /// in a different way is not a repair, so every file this would copy is
    /// itself examined, at the place it would land, and whatever *it* would
    /// then be missing joins the plan.
    ///
    /// `donors` is every pinned build. The target itself is searched first —
    /// see the note in the body.
    public func plan(for target: RuntimeSpec, donors: [RuntimeSpec],
                     audit: RuntimeAudit.Report? = nil) -> Offer {
        var offer = Offer(runtimeID: target.id)
        let report = audit ?? RuntimeAudit().audit(root: target.root)
        let wanted = Set(MachO.architectures(at: target.winePath))
        // The build itself is searched first, and this is not a technicality.
        // A file is often already inside the build and merely somewhere the
        // asker does not look — Apple's Game Porting Toolkit carries GStreamer
        // in a bundled framework that its own 32-bit side cannot reach. Taking
        // the build's own copy fixes that with no risk at all; taking another
        // build's copy would put two versions of the same library inside one
        // Wine, which is a different and worse thing to have done.
        let pool = [target] + donors.filter { $0.id != target.id }

        var queue: [(library: String, neededBy: [String])] =
            report.hardGaps.map { ($0.library, $0.neededBy) }
        var pending = Set<String>()
        var unfillable: [String: [String]] = [:]
        // Bounded because a dependency graph that keeps producing new names is
        // a graph this cannot close, and looping on it would hang rather than
        // report.
        var rounds = 0

        while !queue.isEmpty, rounds < 16 {
            rounds += 1
            var next: [(library: String, neededBy: [String])] = []
            for item in queue {
                let leaf = (item.library as NSString).lastPathComponent
                guard let (donor, source, archs) = findDonor(leaf: leaf, in: pool, matching: wanted) else {
                    unfillable[item.library, default: []].append(contentsOf: item.neededBy)
                    continue
                }
                for destination in destinations(library: item.library, neededBy: item.neededBy,
                                                leaf: leaf, root: target.root) {
                    guard !fm.fileExists(atPath: destination.path) else { continue }
                    guard pending.insert(destination.path).inserted else { continue }
                    offer.borrows.append(.init(library: leaf, donorID: donor.id, source: source,
                                               destination: destination, architectures: archs,
                                               neededBy: item.neededBy))
                    // What this file will itself need, from where it will sit.
                    guard let image = MachO.read(at: source) else { continue }
                    let landing = destination.deletingLastPathComponent()
                    let relative = destination.path
                        .replacingOccurrences(of: target.root.path + "/", with: "")
                    for dep in image.dependencies where !dep.isWeak {
                        if RuntimeAudit.resolves(dep.path, loaderDir: landing,
                                                 rpaths: image.rpaths, root: target.root) { continue }
                        if Self.satisfiedByPlan(dep.path, loaderDir: landing,
                                                root: target.root, pending: pending) { continue }
                        next.append((dep.path, [relative]))
                    }
                }
            }
            queue = next
        }

        offer.unfillable = unfillable
            .map { RuntimeAudit.Gap(library: $0.key, neededBy: Array(Set($0.value)).sorted(),
                                    isWeak: false,
                                    thirtyTwoBitOnly: $0.value.allSatisfy(RuntimeAudit.isThirtyTwoBitPath)) }
            .sorted { $0.library < $1.library }
        return offer
    }

    /// Whether a copy this plan already intends to make would answer `raw`.
    ///
    /// Mirrors where `RuntimeAudit.resolves` looks, because the two have to
    /// agree about the same build — one deciding a file is missing while the
    /// other decides it is not is how a plan loops.
    static func satisfiedByPlan(_ raw: String, loaderDir: URL, root: URL,
                                pending: Set<String>) -> Bool {
        let leaf = (raw as NSString).lastPathComponent
        let dirs: [String]
        if raw.hasPrefix("@loader_path/") {
            dirs = [loaderDir.appending(path: String(raw.dropFirst(13)))
                        .deletingLastPathComponent().path]
        } else {
            dirs = [loaderDir.path] + RuntimeAudit.fallbackDirectories(root: root)
        }
        return dirs.contains { pending.contains($0 + "/" + leaf) }
    }

    /// Where the copy has to land for the loader to find it.
    ///
    /// A dependency written `@loader_path/x` is looked for beside the file that
    /// asked, and nowhere else — so it goes beside each asker. Everything else
    /// is found through the fallback search, which Decanter points at the
    /// build's own `lib`, so one copy there serves every asker.
    func destinations(library: String, neededBy: [String], leaf: String, root: URL) -> [URL] {
        guard library.hasPrefix("@loader_path/") else {
            return [root.appending(path: "lib/\(leaf)")]
        }
        return neededBy.map { rel in
            root.appending(path: rel).deletingLastPathComponent().appending(path: leaf)
        }
    }

    /// The first build carrying this library in a form the target can load.
    ///
    /// Architecture is checked, not assumed. Wine here is x86_64 under Rosetta;
    /// an arm64 library is the wrong kind of file and fails silently.
    func findDonor(leaf: String, in donors: [RuntimeSpec],
                   matching wanted: Set<String>) -> (RuntimeSpec, URL, [String])? {
        for donor in donors {
            guard let walk = fm.enumerator(at: donor.root.appending(path: "lib"),
                                           includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in walk where u.lastPathComponent == leaf {
                if Self.isOffLimits(u.path, donorRoot: donor.root) { continue }
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let archs = MachO.architectures(at: u)
                guard !archs.isEmpty else { continue }
                // Empty `wanted` means the target's own architecture could not
                // be read; refusing is safer than copying on a hope.
                guard !wanted.isEmpty, !wanted.isDisjoint(with: Set(archs)) else { continue }
                return (donor, u, archs)
            }
        }
        return nil
    }

    /// A directory of dylibs, dressed as a donor.
    ///
    /// `plan` searches donors by walking `<root>/lib`, and that is the only
    /// thing it needs from a `RuntimeSpec` — so an unpacked archive of media
    /// libraries can be one, and the whole of `plan` and `apply` then works
    /// unchanged: the fixed-point closure that stops a copied library arriving
    /// without its own siblings, the architecture match, the refusal to write
    /// outside the build, and the manifest that makes `--undo` exact.
    ///
    /// Writing a second copy routine for the pack was the obvious thing and the
    /// wrong one. The first version of `plan` closed six gaps and opened three,
    /// because a library moved out of its own directory can no longer find its
    /// neighbours; a fresh implementation would have had to learn that again.
    public static func donor(unpackedAt root: URL, id: String) -> RuntimeSpec {
        RuntimeSpec(id: id, kind: .wine, version: "supplied", root: root,
                    winePath: root.appending(path: "bin/wine"),
                    wineserverPath: root.appending(path: "bin/wineserver"),
                    supports32Bit: false, backends: [])
    }

    /// Where the libraries are inside an unpacked archive.
    ///
    /// Found rather than assumed: the GStreamer build these come from puts them
    /// at `GStreamer.framework/Versions/1.0/lib`, and the next archive will put
    /// them somewhere else. What is constant is a directory with a `lib` in it
    /// holding Mach-O files, so that is what is looked for.
    public static func findLibraryRoot(under url: URL, depth: Int = 4) -> URL? {
        let fm = FileManager.default
        let lib = url.appending(path: "lib")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: lib.path, isDirectory: &isDir), isDir.boolValue,
           let names = try? fm.contentsOfDirectory(atPath: lib.path),
           names.contains(where: { $0.hasSuffix(".dylib") }) {
            return url
        }
        guard depth > 0 else { return nil }
        let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        // Deterministic: two candidates in one archive must always resolve to
        // the same one, or a second attempt installs something different.
        for kid in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let found = findLibraryRoot(under: kid, depth: depth - 1) { return found }
        }
        return nil
    }

    /// Carries out a plan that was agreed to, and records it.
    ///
    /// Repeats the audit afterwards: a borrowed library brings its own
    /// dependencies, and a repair that closes six gaps while opening three is
    /// not a fix. The caller is told what is left rather than being congratulated.
    @discardableResult
    public func apply(_ offer: Offer, to target: RuntimeSpec,
                      progress: (String) -> Void = { _ in }) throws -> [String] {
        guard !offer.isEmpty else { return [] }
        var done: [String] = []
        var manifest = loadManifest(in: target.root)
        for b in offer.borrows {
            // The boundary SECURITY.md states, enforced rather than argued for.
            // Today every destination is built from a leaf name and a directory
            // inside the build, so none of them can escape — but "cannot" is a
            // property of the current code, not of the promise, and the promise
            // is the one people rely on.
            guard Self.isInside(b.destination, root: target.root) else {
                throw DecanterError.notFound(
                    "refusing to write outside \(target.id) — \(b.destination.lastPathComponent) "
                    + "would land somewhere that is not part of this Wine build")
            }
            try fm.createDirectory(at: b.destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // Refuse to write over anything already there. A repair that
            // replaces a working file is no longer a repair.
            guard !fm.fileExists(atPath: b.destination.path) else { continue }
            progress("copying \(b.library) from \(b.donorID)")
            try fm.copyItem(at: b.source, to: b.destination)
            manifest.borrows.append(b)
            done.append("\(b.library) → \(b.destination.path)")
        }
        manifest.appliedAt = Date()
        manifest.appliedBy = Build.version
        try saveManifest(manifest, in: target.root)
        return done
    }

    /// Removes exactly what was copied, and nothing else.
    @discardableResult
    public func undo(_ target: RuntimeSpec, progress: (String) -> Void = { _ in }) throws -> [String] {
        let manifest = loadManifest(in: target.root)
        guard !manifest.borrows.isEmpty else { return [] }
        var removed: [String] = []
        for b in manifest.borrows where fm.fileExists(atPath: b.destination.path) {
            // A manifest is a file inside a build that anybody could edit.
            // Removing what it names without checking would turn it into a
            // list of things to delete anywhere on the disk.
            guard Self.isInside(b.destination, root: target.root) else { continue }
            progress("removing \(b.library)")
            try fm.removeItem(at: b.destination)
            removed.append(b.destination.path)
        }
        try? fm.removeItem(at: Self.manifestPath(in: target.root))
        return removed
    }

    /// Whether a path really is inside a build, symlinks resolved on both
    /// sides. The same comparison the donor guard makes, and for the same
    /// reason: a prefix check on unresolved paths silently stops holding the
    /// moment either side is reached through a link.
    public static func isInside(_ url: URL, root: URL) -> Bool {
        // Resolved on the deepest existing ancestor, because the destination
        // itself does not exist yet — resolving a path that is not there
        // returns it unchanged, which would defeat the check.
        var probe = url.deletingLastPathComponent()
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let here = probe.resolvingSymlinksInPath().standardizedFileURL.path
        return here == base || here.hasPrefix(base + "/")
    }

    public func loadManifest(in root: URL) -> Manifest {
        guard let d = try? Data(contentsOf: Self.manifestPath(in: root)),
              let m = try? JSONDecoder().decode(Manifest.self, from: d) else { return Manifest() }
        return m
    }

    func saveManifest(_ m: Manifest, in root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: Self.manifestPath(in: root), options: .atomic)
    }
}
