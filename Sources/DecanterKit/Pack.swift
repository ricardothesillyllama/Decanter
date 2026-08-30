import Foundation
import CryptoKit

/// A runtime pack: one archive holding everything a first run needs, assembled
/// once by the maintainer and verified byte-for-byte when it lands.
///
/// This exists because the no-network rule had a hole in it that setup fell
/// through. Decanter fetches nothing, which is the whole point — Whisky's
/// installed copies died when the runtime it downloaded was deleted upstream.
/// But "we fetch nothing" was being paid for by the user, who was sent to three
/// strangers' releases pages to collect a Wine build, a DXVK tarball and a DXMT
/// archive, and had to know which of the seventeen files on each page was the
/// right one. That is not a beginner path. It is the same dependency Whisky
/// had, moved onto a person.
///
/// A pack closes it without touching the rule. The bytes are gathered once, on
/// a machine where they were shown to work, hashed, licensed, and published as
/// a single file. Decanter still fetches nothing: the user's browser downloads
/// it, and Decanter reads it off the disk exactly as it reads a dropped Wine
/// build today. What changes is that there is one file instead of three, from
/// one place instead of three, and Decanter can say whether the copy that
/// arrived is the copy that was published.
///
/// Three properties, each of which is the reason for a piece of this file:
///
/// **It says what it contains.** `pack.json` names every component, its
/// version, its size and its SHA-256. A truncated download is caught before it
/// is unpacked rather than three screens later as a missing symbol.
///
/// **It says where it came from.** Every component carries its upstream and its
/// licence, and `LICENCES.txt` is assembled from those. Redistributing LGPL
/// binaries is allowed and requires saying so; the file is not a formality.
///
/// **It can be assembled only from things that may be redistributed.** This is
/// the one that has teeth. Decanter's repair can borrow a missing library from
/// any pinned build, including Apple's Game Porting Toolkit, and on this
/// machine it did: the Sikarugir Wine 10 build's media stack is complete only
/// because seven libraries were copied out of the toolkit. That is entirely
/// legitimate on the Mac it happened on and entirely not redistributable, and
/// nothing about the resulting directory looks any different. So the assembler
/// reads the repair manifest and refuses, by name, rather than trusting anyone
/// to remember.
public enum Pack {
    public static let manifestName = "pack.json"
    public static let licencesName = "LICENCES.txt"
    /// Bumped only when older Decanters must refuse to read a newer pack.
    public static let formatVersion = 1

    /// What a component is, which decides how it is installed rather than only
    /// how it is described. Closed on purpose: a pack that can carry an
    /// arbitrary "kind" is a pack that can carry an installer.
    public enum Piece: String, Codable, Sendable, CaseIterable {
        case wine, dxvk, dxmt
        /// The libraries a Wine build needs to play a game's audio and video
        /// and does not always carry.
        ///
        /// This kind exists because of a specific, measured gap. The one Wine
        /// build on this platform that can host DXMT ships without seven
        /// libraries its own GStreamer and FFmpeg chain asks for by name, and
        /// `repair` closed that gap here from the only donor available — Apple's
        /// Game Porting Toolkit, which is licensed for use on this Mac and not
        /// for redistribution. That made the one runtime worth publishing the
        /// one runtime that could not be published.
        ///
        /// Six of the seven turn out to be in the GStreamer build Sikarugir
        /// publish themselves, under the LGPL, each an x86_64 Mach-O whose
        /// install name is exactly the `@rpath/<name>.dylib` the Wine binaries
        /// ask for; the seventh ships in Gcenx's Wine 11, also LGPL. So the
        /// pack can be whole with no toolkit content in it at all.
        case media

        public var label: String {
            switch self {
            case .wine: "Windows support"
            case .dxvk: "Vulkan graphics"
            case .dxmt: "Metal graphics"
            case .media: "Audio and video support"
            }
        }
    }

    /// One file inside the pack.
    ///
    /// Every field is decoded by hand. This is the only type in Decanter that
    /// is parsed from a file a stranger produced, so the synthesised decoder —
    /// which throws away the whole document if one key it wants is absent — is
    /// exactly the wrong shape: a pack written by a later Decanter with one
    /// extra field must still be readable, and a pack missing something
    /// essential must fail with a sentence naming what is missing.
    public struct Component: Codable, Sendable, Equatable {
        public var piece: Piece
        public var version: String
        /// Relative to the pack directory, and validated on read: a component
        /// path is a leaf name, never a path. `../` in a manifest is how an
        /// archive writes outside the directory it was unpacked into.
        public var file: String
        public var bytes: Int64
        public var sha256: String
        /// SPDX identifier where one exists, plain words where it does not.
        public var licence: String
        /// The project and release these bytes were taken from, in words a
        /// person can search for. Not a URL: a pack outlives any link in it.
        public var origin: String

        public init(piece: Piece, version: String, file: String, bytes: Int64,
                    sha256: String, licence: String, origin: String) {
            self.piece = piece; self.version = version; self.file = file
            self.bytes = bytes; self.sha256 = sha256
            self.licence = licence; self.origin = origin
        }

        enum CodingKeys: String, CodingKey {
            case piece, version, file, bytes, sha256, licence, origin
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let raw = try? c.decode(String.self, forKey: .piece),
                  let p = Piece(rawValue: raw) else {
                throw DecanterError.notFound(
                    "this pack contains a component of a kind this version of Decanter "
                    + "does not know about — a newer Decanter will read it")
            }
            piece = p
            version = (try? c.decode(String.self, forKey: .version)) ?? "unknown"
            file = (try? c.decode(String.self, forKey: .file)) ?? ""
            bytes = (try? c.decode(Int64.self, forKey: .bytes)) ?? 0
            sha256 = (try? c.decode(String.self, forKey: .sha256)) ?? ""
            licence = (try? c.decode(String.self, forKey: .licence)) ?? "unstated"
            origin = (try? c.decode(String.self, forKey: .origin)) ?? "unstated"
        }
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public var formatVersion: Int
        public var name: String
        public var createdAt: Date
        public var createdBy: String
        public var components: [Component]
        /// Free text shown to whoever installs it. Read, never executed.
        public var notes: String

        public init(name: String, components: [Component], notes: String = "") {
            self.formatVersion = Pack.formatVersion
            self.name = name
            self.createdAt = Date()
            self.createdBy = Build.summary
            self.components = components
            self.notes = notes
        }

        enum CodingKeys: String, CodingKey {
            case formatVersion, name, createdAt, createdBy, components, notes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 0
            name = (try? c.decode(String.self, forKey: .name)) ?? "unnamed pack"
            createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
            createdBy = (try? c.decode(String.self, forKey: .createdBy)) ?? "unstated"
            components = (try? c.decode([Component].self, forKey: .components)) ?? []
            notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        }

        public var totalBytes: Int64 { components.reduce(0) { $0 + $1.bytes } }
    }

    /// The order components are installed in. A Wine build first: whether a
    /// graphics layer can be used here is decided by inspecting the runtime,
    /// and asking before one is pinned gets a wrong answer that is then shown
    /// to the user as a limitation.
    public static func installRank(_ p: Piece) -> Int {
        switch p {
        case .wine: 0
        // Straight after the Wine build and before either graphics layer: it
        // is applied *into* that build, so there has to be one, and a build
        // still missing pieces is the wrong thing to then measure for DXMT.
        case .media: 1
        case .dxvk: 2
        case .dxmt: 3
        }
    }

    // MARK: - Hashing

    /// SHA-256 of a file, read in chunks.
    ///
    /// Streamed rather than `Data(contentsOf:)` because the largest component
    /// is most of a gigabyte, and mapping that to hash it is a page fault
    /// storm on a machine that is already unpacking something. 4 MB is large
    /// enough that the syscall cost disappears and small enough to stay out of
    /// the way.
    public static func digest(of url: URL) throws -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else {
            throw DecanterError.notFound("cannot read \(url.lastPathComponent)")
        }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Signing

    /// What the maintainer's signature covers.
    ///
    /// Prefixed, and that prefix is the whole reason this is a function rather
    /// than the manifest bytes on their own. The endorsement key already signs
    /// one kind of thing — the canonical form of an observation — and a key
    /// that signs two kinds of thing with no separation between them can have a
    /// signature over one presented as a signature over the other. The
    /// observation form is left exactly as it is, because changing it would
    /// invalidate every endorsement already published; the new use carries a
    /// domain of its own instead.
    static func signedForm(_ manifest: Data) -> Data {
        Data("decanter-pack-v1\n".utf8) + manifest
    }

    public static func signatureName(for manifest: String = manifestName) -> String {
        manifest + ".sig"
    }

    // MARK: - Reading

    /// Where a pack's parts live once it is a directory on disk.
    public struct Located: Sendable {
        public var root: URL
        public var manifest: Manifest
        /// Detached signature, base64, if the pack carries one.
        public var signature: String?
    }

    /// Reads and structurally checks a pack directory. Does not hash anything —
    /// that is `verify`, which is slow and is reported with progress.
    public static func read(at root: URL) throws -> Located {
        let mURL = root.appending(path: manifestName)
        guard let data = try? Data(contentsOf: mURL) else {
            throw DecanterError.notFound("no \(manifestName) in \(root.lastPathComponent)")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let manifest: Manifest
        do { manifest = try dec.decode(Manifest.self, from: data) }
        catch let e as DecanterError { throw e }
        catch { throw DecanterError.notFound("\(manifestName) is not readable: \(error.localizedDescription)") }

        guard manifest.formatVersion <= formatVersion else {
            throw DecanterError.notFound(
                "this pack was made for a newer Decanter (pack format \(manifest.formatVersion), "
                + "this build reads \(formatVersion)) — update Decanter and try again")
        }
        guard !manifest.components.isEmpty else {
            throw DecanterError.notFound("\(manifest.name) lists no components")
        }
        // A component's file is a leaf name. Checked here, once, so nothing
        // downstream has to remember that a manifest is a stranger's document.
        for c in manifest.components {
            guard !c.file.isEmpty else {
                throw DecanterError.notFound("a \(c.piece.rawValue) component in \(manifest.name) names no file")
            }
            guard c.file == URL(filePath: c.file).lastPathComponent, !c.file.hasPrefix(".") else {
                throw DecanterError.notFound(
                    "\(manifest.name) points a component outside itself (\(c.file)) — it will not be used")
            }
        }
        let sig = try? String(contentsOf: root.appending(path: signatureName()), encoding: .utf8)
        return Located(root: root, manifest: manifest,
                       signature: sig?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Verifying

    /// The result of checking a pack, in the order a person reads it: did it
    /// arrive whole, and is it the one that was published.
    public struct Verification: Sendable {
        public var name: String
        public var checked: [String] = []
        public var problems: [String] = []
        /// nil when the pack carries no signature at all, which is the ordinary
        /// case for a pack somebody assembled themselves.
        public var signedByMaintainer: Bool?

        public var isSound: Bool { problems.isEmpty }

        /// One sentence, leading with the answer.
        public var summary: String {
            if !problems.isEmpty {
                return "\(name) did not arrive intact — \(problems.count) "
                     + "problem\(problems.count == 1 ? "" : "s"). It has not been installed."
            }
            // `.some(true)` rather than `true`. Swift 6.3 accepts the bare
            // literals as exhaustive over `Bool?`; the compiler on macOS 15,
            // which is what CI builds with, does not — and this shipped red
            // because `STRICT=1` runs the same flags as CI against a different
            // toolchain, so "the release build has warnings" was checked and
            // "the release build compiles there" was not.
            switch signedByMaintainer {
            case .some(true):
                return "\(name) is complete, and is the pack Decanter published."
            case .some(false):
                return "\(name) is complete, but its signature is not one Decanter recognises. "
                     + "The files are intact; who assembled them is unestablished."
            case .none:
                return "\(name) is complete. It carries no signature, so it is a pack "
                     + "somebody assembled — the files match what its own manifest says they should be."
            }
        }
    }

    /// Hashes every component and compares. Slow by construction — it reads the
    /// whole pack — so it takes a progress callback and is never called from a
    /// place that cannot show one.
    public static func verify(_ located: Located, progress: (String) -> Void = { _ in }) -> Verification {
        var v = Verification(name: located.manifest.name)
        let fm = FileManager.default
        for c in located.manifest.components {
            let u = located.root.appending(path: c.file)
            guard fm.fileExists(atPath: u.path) else {
                v.problems.append("\(c.file) is missing from the pack")
                continue
            }
            progress("checking \(c.file)")
            if let actual = DiskSpace.sizeOfFile(at: u), c.bytes > 0, actual != c.bytes {
                // Reported and then still hashed: a size mismatch is almost
                // always a truncated download, and saying which is which costs
                // one line rather than a second run.
                v.problems.append("\(c.file) is \(actual) bytes, and the pack says \(c.bytes)")
            }
            guard !c.sha256.isEmpty else {
                v.problems.append("\(c.file) has no checksum in the manifest, so it cannot be checked")
                continue
            }
            do {
                let d = try digest(of: u)
                if d == c.sha256.lowercased() {
                    v.checked.append("\(c.piece.label) \(c.version)")
                } else {
                    v.problems.append("\(c.file) does not match its checksum — the copy that arrived "
                                    + "is not the copy that was published")
                }
            } catch {
                v.problems.append("\(c.file) could not be read: \(error.localizedDescription)")
            }
        }
        if let sig = located.signature, !sig.isEmpty,
           let data = try? Data(contentsOf: located.root.appending(path: manifestName)) {
            v.signedByMaintainer = Endorsement.isSignatureValid(sig, over: signedForm(data))
        }
        return v
    }

    // MARK: - Redistribution

    /// Why a pinned build may not be put into a pack.
    ///
    /// Reads the record `RuntimeRepair` leaves inside a build it changed. A
    /// build repaired from Apple's Game Porting Toolkit contains Apple's
    /// distribution: fine to run here, not ours to hand on. The check is by
    /// donor rather than by file because the file names are ordinary open
    /// source names — `liborc-0.4.0.dylib` says nothing about where the copy
    /// came from, and by the time it is inside another build it looks native.
    ///
    /// Measured on this machine: `wine-10.0-dxmt` carries seven borrows, all
    /// from `gptk-7.7`, all feeding the GStreamer and FFmpeg chain that plays
    /// a game's video. So the one runtime that can host DXMT is also the one
    /// that cannot currently be published, and that is a fact about the build,
    /// not a bug in this function.
    public static func redistributionBlockers(runtimeID: String, root: URL,
                                              store: Store) -> [String] {
        let mURL = RuntimeRepair.manifestPath(in: root)
        guard let data = try? Data(contentsOf: mURL),
              let m = try? JSONDecoder().decode(RuntimeRepair.Manifest.self, from: data),
              !m.borrows.isEmpty else { return [] }

        var blockers: [String] = []
        var counted: [String: Int] = [:]
        for b in m.borrows {
            let donorKind = store.state.runtimes.first { $0.id == b.donorID }?.kind
            // The prefix is the fallback for a donor that has since been
            // removed from the library: the record outlives the runtime, and a
            // blocker that disappears when the donor is deleted is not one.
            let isToolkit = donorKind == .gptk || b.donorID.hasPrefix("gptk")
            if isToolkit { counted[b.donorID, default: 0] += 1 }
        }
        for (donor, n) in counted.sorted(by: { $0.key < $1.key }) {
            blockers.append(
                "\(runtimeID) contains \(n) file\(n == 1 ? "" : "s") copied from \(donor), "
                + "Apple's Game Porting Toolkit. Those are licensed for use on this Mac and "
                + "may not be redistributed, so this build cannot go into a pack.")
        }
        return blockers
    }

    // MARK: - Licences

    /// The licences file, built from the components rather than kept alongside
    /// them. A hand-maintained one drifts the first time a component version
    /// changes, and the drift is invisible.
    public static func licencesText(for manifest: Manifest) -> String {
        var s = """
        \(manifest.name)
        Assembled \(ISO8601DateFormatter().string(from: manifest.createdAt)) by \(manifest.createdBy).

        This pack redistributes unmodified binaries from the projects below. Decanter
        claims no copyright over them. Each is covered by its own licence, named here;
        the full text of each licence ships inside its component's archive, where its
        authors put it.

        Decanter itself is GPL-3.0-or-later and is not part of this pack.

        SOURCE. Several of these components are covered by the GNU Lesser General
        Public License, which requires that whoever distributes a binary also makes
        the corresponding source available. The source for every component here is
        published by its own project, at the release named below, unmodified — that
        is the same source, and it is where it has always been. Anyone who would
        rather have it from whoever handed them this pack may ask for it; the
        obligation is real and is not delegated away by this paragraph.


        """
        for c in manifest.components.sorted(by: { $0.piece.rawValue < $1.piece.rawValue }) {
            s += """
            \(c.piece.label) — \(c.origin)
              version   \(c.version)
              file      \(c.file)
              licence   \(c.licence)
              sha256    \(c.sha256)


            """
        }
        return s
    }
}
