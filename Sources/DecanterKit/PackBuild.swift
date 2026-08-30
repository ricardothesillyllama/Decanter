import Foundation

/// Assembling a pack, which is a maintainer's job and happens once per release.
///
/// The design decision that shapes all of this: **a pack carries upstream
/// archives, byte for byte, and never a tree Decanter re-packed.**
///
/// The alternative was to tar up the pinned runtimes from this Mac, which is
/// what the first sketch did, and it is wrong for three reasons that only
/// became clear when the licences file was written. A re-packed tree cannot be
/// checked against anything — its hash matches nothing upstream publishes, so
/// "is this the real DXVK 2.7" has no answer. A re-packed tree may quietly
/// contain repairs: `RuntimeRepair` borrows missing libraries from any pinned
/// build, and on this machine the one runtime that can host DXMT is complete
/// only because seven files were copied out of Apple's Game Porting Toolkit —
/// legitimate here, not ours to redistribute, and invisible once copied. And a
/// licences file that says "unmodified binaries from the projects below" is
/// then a false statement, which is the one thing a licences file may not be.
///
/// Carrying the upstream archives makes all three go away by construction
/// rather than by care. What the pack adds is what upstream cannot: one file
/// instead of three, a manifest saying what is inside, checksums so a
/// half-finished download is caught before it is unpacked, a licences file
/// assembled from the components rather than maintained beside them, and a
/// signature so the copy that arrived can be shown to be the copy that was
/// published.
public extension Pack {

    /// One archive going in, with the facts about it that only the person
    /// assembling the pack knows.
    struct Ingredient: Sendable {
        public var piece: Piece
        public var archive: URL
        /// Left empty to take it from the archive's name, which is where every
        /// one of these projects puts it.
        public var version: String
        public var licence: String
        public var origin: String

        public init(piece: Piece, archive: URL, version: String = "",
                    licence: String, origin: String) {
            self.piece = piece; self.archive = archive; self.version = version
            self.licence = licence; self.origin = origin
        }
    }

    struct Assembly: Sendable {
        public var root: URL
        public var manifest: Manifest
        public var signed: Bool
        /// Things worth saying out loud that did not stop the build.
        public var warnings: [String] = []

        public var summary: String {
            // Formatted rather than divided: a hand-rolled megabyte count
            // printed a 512 KB fixture pack as "0 MB", which reads as a pack
            // that assembled nothing.
            let size = ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file)
            return "\(manifest.name): \(manifest.components.count) components, \(size)"
                 + (signed ? ", signed." : ", unsigned.")
        }
    }

    /// `dxvk-2.7.tar.gz` → `2.7`. Everything before the first digit is the
    /// project's name and everything from the first archive suffix on is
    /// packaging, so what is left is the version. Returns "unknown" rather
    /// than guessing wrongly — a version in a manifest is read by people.
    static func versionFromName(_ name: String) -> String {
        var s = name
        for suffix in Acquisition.archiveSuffixes where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)); break
        }
        // Drop a leading project name and any separator after it.
        guard let firstDigit = s.firstIndex(where: \.isNumber) else { return "unknown" }
        var v = String(s[firstDigit...])
        // Trailing platform tags: wine builds are `…-11.16-osx64`.
        for tag in ["-osx64", "-osx", "-macos", "-x86_64", "-universal"] {
            if v.hasSuffix(tag) { v = String(v.dropLast(tag.count)) }
        }
        return v.isEmpty ? "unknown" : v
    }

    /// Builds a pack directory. Nothing is published here — that is a separate,
    /// deliberate act by a person.
    ///
    /// `allowIncompleteWine` is a flag rather than a default because of what it
    /// waives. The charter's sixth rule says that once Decanter hands someone a
    /// runtime, a missing library inside it is Decanter's defect and not
    /// upstream's, and the only way that rule means anything is if the thing
    /// that assembles the pack checks. So the Wine component is unpacked and
    /// audited before it goes in, and a hard gap stops the build with the count
    /// in the message. Overriding it is allowed — sometimes the incomplete
    /// build is the only one that can do the job — but it has to be typed.
    static func assemble(_ ingredients: [Ingredient], named name: String,
                         into destination: URL, notes: String = "",
                         paths: Paths, signWithMaintainerKey: Bool = false,
                         allowIncompleteWine: Bool = false,
                         progress: (String) -> Void = { _ in }) throws -> Assembly {
        let fm = FileManager.default
        guard !ingredients.isEmpty else {
            throw DecanterError.notFound("a pack needs at least one component")
        }
        // One of each. Two Wine builds in a pack is a decision about which one
        // to use, made by a directory listing.
        for piece in Piece.allCases {
            let n = ingredients.filter { $0.piece == piece }.count
            guard n <= 1 else {
                throw DecanterError.notFound("this pack lists \(n) \(piece.rawValue) components; it may hold one")
            }
        }
        for i in ingredients where !fm.fileExists(atPath: i.archive.path) {
            throw DecanterError.notFound("\(i.archive.lastPathComponent) is not there")
        }

        var warnings: [String] = []
        if let wine = ingredients.first(where: { $0.piece == .wine }) {
            progress("auditing \(wine.archive.lastPathComponent)")
            let acq = Acquisition(paths: paths)
            let report = try acq.withWineRoot(inArchive: wine.archive) { root in
                RuntimeAudit().audit(root: root)
            }
            if !report.isSound {
                let n = report.hardGaps.count
                let named = report.hardGaps.prefix(8).map(\.library).joined(separator: ", ")
                let sentence = "\(wine.archive.lastPathComponent) is missing \(n) "
                    + "librar\(n == 1 ? "y" : "ies") that files inside it require: \(named)"
                    + (n > 8 ? ", and others" : "")
                    + ". A pack that ships this hands everyone who installs it the same gap."
                guard allowIncompleteWine else {
                    throw DecanterError.notFound(sentence
                        + " Fix the build, or pass --allow-incomplete-wine to publish it anyway.")
                }
                warnings.append(sentence + " Published anyway, by request.")
            }
            if !report.weakGaps.isEmpty {
                warnings.append("\(report.weakGaps.count) optional piece"
                    + "\(report.weakGaps.count == 1 ? " is" : "s are") absent; the build is written to cope.")
            }
        }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var components: [Component] = []
        for i in ingredients {
            let leaf = i.archive.lastPathComponent
            let dest = destination.appending(path: leaf)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            progress("copying \(leaf)")
            // Cloned where the filesystem allows it; these are hundreds of
            // megabytes and a real copy of each is minutes of nothing.
            let r = try Shell.run(URL(filePath: "/bin/cp"), ["-c", i.archive.path, dest.path], timeout: 600)
            if r.code != 0 {
                let r2 = try Shell.run(URL(filePath: "/bin/cp"), [i.archive.path, dest.path], timeout: 900)
                guard r2.code == 0 else { throw DecanterError.cloneFailed(r2.err) }
            }
            progress("hashing \(leaf)")
            let sum = try digest(of: dest)
            let size = DiskSpace.sizeOfFile(at: dest) ?? 0
            components.append(Component(
                piece: i.piece,
                version: i.version.isEmpty ? versionFromName(leaf) : i.version,
                file: leaf, bytes: size, sha256: sum,
                licence: i.licence, origin: i.origin))
        }

        let manifest = Manifest(name: name, components: components, notes: notes)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(manifest)
        try data.write(to: destination.appending(path: manifestName), options: .atomic)
        try licencesText(for: manifest).write(to: destination.appending(path: licencesName),
                                              atomically: true, encoding: .utf8)

        var signed = false
        if signWithMaintainerKey {
            // The signature covers the manifest, and the manifest covers every
            // component by hash — so one signature over 200 bytes stands for
            // the whole pack, and re-signing after a component changes is not
            // something anyone can forget to do.
            let sig = try Endorsement.sign(bytes: signedForm(data))
            try sig.write(to: destination.appending(path: signatureName()),
                          atomically: true, encoding: .utf8)
            signed = true
        }
        return Assembly(root: destination, manifest: manifest, signed: signed, warnings: warnings)
    }
}
