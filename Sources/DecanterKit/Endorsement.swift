import Foundation
import CryptoKit

/// Marking a piece of knowledge as one the maintainer ran themselves.
///
/// The mechanism matters more than it looks. An earlier plan had the app verify
/// its *own* code signature and unlock a maintainer mode on that. It would have
/// been theatre: Decanter is ad-hoc signed by design, an ad-hoc signature
/// carries no identity, and anyone rebuilding from source gets a binary that
/// passes exactly the same check. Open source and a self-check cannot combine
/// into a privilege.
///
/// What works is signing the *knowledge* rather than the program. The
/// maintainer holds a private key; Decanter ships only the public half. An
/// endorsed row carries a signature over its own contents, so any build can
/// check one and only the key holder can make one. A fork can ship its own
/// public key — and should — but it cannot forge an endorsement inside this
/// distribution, which is the only thing that needed to be true.
///
/// It also keeps the rule that everything shipped is anonymous. A signature
/// proves a *tier*, not a person: nothing in a row says who signed it, and
/// nothing needs to.
public enum Endorsement {

    /// Where a row came from, and how much that is worth.
    public enum Tier: String, Codable, Sendable, CaseIterable, Comparable {
        /// Signed by the maintainer's key: someone ran this and watched it work.
        case verified
        /// Arrived in someone's export, or was shipped as a starting assumption.
        case community
        /// Seen on this Mac. The strongest kind for the person sitting here,
        /// and the reason `verified` never overrules a specific local
        /// observation.
        case local

        /// Weakest first. A switch rather than an array lookup, because the
        /// array version force-unwrapped its own index: correct for exactly the
        /// three cases that existed, and a crash the moment a fourth was added.
        /// The compiler checks this one.
        var rank: Int {
            switch self {
            case .community: 0
            case .verified:  1
            case .local:     2
            }
        }

        public static func < (a: Tier, b: Tier) -> Bool { a.rank < b.rank }

        public var label: String {
            switch self {
            case .verified:  "verified"
            case .community: "shared"
            case .local:     "seen here"
            }
        }
    }

    /// The maintainer's public key, base64, or empty when this build has none.
    ///
    /// Empty is the honest default and the right one for a fork: with no key,
    /// nothing verifies, every row is community or local, and the interface
    /// says so. A fork that wants its own endorsements replaces this with its
    /// own public key — which is the correct thing for it to do, and cannot be
    /// mistaken for this one.
    public static let maintainerPublicKey = "TzkcOiTxTi5v/FvLRjtsZZnpDGoo3jFR8TbS6D+aYzE="

    /// Where the private half lives when this Mac has one. Never in the
    /// repository, and never anywhere Decanter's own export could reach it.
    public static var privateKeyPath: URL {
        if let override = ProcessInfo.processInfo.environment["DECANTER_ENDORSE_KEY"],
           !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".decanter-endorse.key")
    }

    /// Whether this Mac can produce endorsements at all. Not a password and not
    /// a mode: the capability is simply having the key, which is the one thing
    /// that cannot be copied out of an open repository.
    public static var canEndorse: Bool {
        FileManager.default.fileExists(atPath: privateKeyPath.path)
    }

    // MARK: - What gets signed

    /// The exact bytes an endorsement covers.
    ///
    /// Built by hand rather than by encoding the struct: JSON key order,
    /// number formatting and optional handling are all free to change between
    /// releases, and a signature over bytes that can drift is a signature that
    /// stops verifying for no reason anyone can see. Every field is named, in a
    /// fixed order, with absence written out.
    ///
    /// The whole situation is covered, chip and macOS included. An endorsement
    /// is a specific claim — "this worked, here, on this" — and a signature
    /// over a claim with the specifics removed would be a broader promise than
    /// the one that was actually kept.
    public static func canonical(signature s: Knowledge.Signature,
                                 setup u: Knowledge.Setup,
                                 worked: Bool,
                                 failure: Knowledge.Failure?,
                                 note: String?) -> Data {
        let fields: [(String, String)] = [
            ("v", "1"),
            ("engine", s.engine.rawValue),
            ("engineMajor", s.engineMajor.map(String.init) ?? "-"),
            ("bitness", s.bitness.rawValue),
            ("usesVideo", s.usesVideo ? "1" : "0"),
            ("usesD3D12", s.usesD3D12 ? "1" : "0"),
            ("chip", s.chip.rawValue),
            ("macOSMajor", s.macOSMajor.map(String.init) ?? "-"),
            ("runtimeKind", u.runtimeKind.rawValue),
            ("backend", u.backend.rawValue),
            ("layerVersion", u.layerVersion ?? "-"),
            ("worked", worked ? "1" : "0"),
            ("failure", failure?.rawValue ?? "-"),
            ("note", note ?? "-"),
        ]
        return Data(fields.map { "\($0.0)=\($0.1)" }.joined(separator: "\n").utf8)
    }

    public static func canonical(_ o: Knowledge.Observation) -> Data {
        canonical(signature: o.signature, setup: o.setup, worked: o.worked,
                  failure: o.failure, note: o.note)
    }

    // MARK: - Making and checking one

    public enum KeyError: LocalizedError {
        case noPrivateKey, noPublicKey, badKey(String)
        public var errorDescription: String? {
            switch self {
            case .noPrivateKey:
                "This Mac has no endorsement key, so it cannot mark anything as verified. `decanter endorse keygen` makes one."
            case .noPublicKey:
                "This build ships no endorsement key, so it cannot check whether anything is verified."
            case .badKey(let s): "The endorsement key could not be read: \(s)"
            }
        }
    }

    public static func generateKeyPair() throws -> (privateKeyBase64: String, publicKeyBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(),
                key.publicKey.rawRepresentation.base64EncodedString())
    }

    static func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        guard let text = try? String(contentsOf: privateKeyPath, encoding: .utf8) else {
            throw KeyError.noPrivateKey
        }
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw KeyError.badKey(privateKeyPath.lastPathComponent)
        }
        return key
    }

    /// Where the public half is kept while a build has none baked in.
    ///
    /// A release carries its key in the source, and then this file is ignored
    /// entirely — a released Decanter must not be talked into trusting a key
    /// somebody dropped next to it. Before a key has been baked in there is no
    /// key to undermine, and being able to check your own endorsements on your
    /// own machine is the whole of what this is for.
    public static var localPublicKeyPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".decanter-endorse.pub")
    }

    static func publicKeyText() -> String? {
        if !maintainerPublicKey.isEmpty { return maintainerPublicKey }
        guard let t = try? String(contentsOf: localPublicKeyPath, encoding: .utf8) else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The build's key, parsed once.
    ///
    /// Verification is asked for far more often than it looks: the knowledge
    /// base checks it for every observation at every level of the matching
    /// ladder, for every game, on every refresh. Parsing base64 and building a
    /// key object each time made a cheap question expensive for no reason.
    /// Immutable for the life of the process, because the key it caches is
    /// compiled in.
    private static let cachedPublicKey: Curve25519.Signing.PublicKey? = {
        guard let text = publicKeyText(), let raw = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }()

    static func loadPublicKey() throws -> Curve25519.Signing.PublicKey {
        guard publicKeyText() != nil else { throw KeyError.noPublicKey }
        guard let key = cachedPublicKey else {
            throw KeyError.badKey("the endorsement key this copy of Decanter is using")
        }
        return key
    }

    /// Whether this build can check endorsements at all.
    public static var canVerify: Bool { publicKeyText() != nil }

    /// True when the key in use came with the build rather than from a file
    /// beside it. Shown wherever a tier is explained, because "verified" means
    /// something different in a release than it does on a developer's Mac.
    public static var keyIsBuiltIn: Bool { !maintainerPublicKey.isEmpty }

    /// Signs an observation, returning the signature to store beside it.
    public static func sign(_ o: Knowledge.Observation) throws -> String {
        try sign(o, with: loadPrivateKey())
    }

    /// Signs against a named key rather than this Mac's.
    ///
    /// Exists so the suite can prove the whole mechanism — sign, verify, detect
    /// tampering, apply the tier — with a key pair it generates itself. A test
    /// that needed a real secret to exist would either not run or would push
    /// someone toward committing one.
    public static func sign(_ o: Knowledge.Observation, privateKeyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKeyBase64),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw KeyError.badKey("the key given")
        }
        return try sign(o, with: key)
    }

    static func sign(_ o: Knowledge.Observation, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: canonical(o)).base64EncodedString()
    }

    /// Whether a row's signature is genuinely this build's maintainer's.
    ///
    /// Returns false rather than throwing for every ordinary failure — no key
    /// shipped, no signature present, signature does not match. A row that
    /// cannot be verified is simply not verified; it is not an error, and
    /// treating it as one would make an unsigned knowledge base look broken.
    public static func isVerified(_ o: Knowledge.Observation) -> Bool {
        // The cheap question first. Almost every row has no endorsement at all,
        // and this used to load and parse a key before discovering that.
        guard o.endorsement?.isEmpty == false else { return false }
        guard let key = try? loadPublicKey() else { return false }
        return isVerified(o, against: key)
    }

    /// Checks against a named key rather than this build's. The counterpart to
    /// `sign(_:privateKeyBase64:)`, and used for the same reason.
    public static func isVerified(_ o: Knowledge.Observation, publicKeyBase64: String) -> Bool {
        guard o.endorsement?.isEmpty == false else { return false }
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return isVerified(o, against: key)
    }

    static func isVerified(_ o: Knowledge.Observation, against key: Curve25519.Signing.PublicKey) -> Bool {
        guard let stored = o.endorsement, !stored.isEmpty,
              let sig = Data(base64Encoded: stored) else { return false }
        return key.isValidSignature(sig, for: canonical(o))
    }

    /// The tier a row sits in, which is the only thing endorsement grants.
    /// There is no name attached and no way to attach one.
    public static func tier(of o: Knowledge.Observation, seenLocally: Bool) -> Tier {
        if seenLocally { return .local }
        return isVerified(o) ? .verified : .community
    }

    /// Writes a new private key, refusing to overwrite one that already exists.
    ///
    /// Overwriting would silently invalidate every endorsement already made
    /// with the old key, and the only sign of it would be rows quietly ceasing
    /// to be verified.
    public static func writePrivateKey(_ base64: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: privateKeyPath.path) else {
            throw KeyError.badKey("there is already a key at \(privateKeyPath.path) — move it aside first if you really mean to replace it")
        }
        try base64.write(to: privateKeyPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyPath.path)
    }
}
