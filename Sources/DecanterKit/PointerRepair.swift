import Foundation
import CryptoKit

/// Mouse input for Unity 6 games, on one Wine build that loses part of it.
///
/// Unity 6 asks Windows to deliver the mouse as a *pointer* — `WM_POINTERDOWN`,
/// `WM_POINTERUPDATE`, `WM_POINTERUP` — and reads nothing else for looking
/// around, dragging or holding a button. Sikarugir's Wine 10.0 (revision 6),
/// the build Decanter uses to host DXMT and so the only one Unity 6 runs on,
/// translates mouse messages into pointer messages but drops one flag, and one
/// kind of message, that Windows always sends:
///
///  * `POINTER_MESSAGE_FLAG_PRIMARY` is missing on a move with a button held,
///    on a second button pressed during a hold, and on every release. A mouse
///    is always the primary pointer on Windows. Without the flag Unity treats
///    the drag as some other pointer's and ignores it: menus work, because a
///    lone click carries the flag, and holding the right button to look
///    around does nothing at all. Measured on a real Unity 6 game: patching
///    the move case alone made mouse-look work.
///  * A double-click becomes no pointer message at all, so a game reading
///    pointers never sees the second click.
///
/// The fix is four changes to `win32u.so`, none of which changes its size:
/// the move case sets the flag, the press and release cases jump through that
/// same instruction, and the four double-click entries of the message table
/// point at the press case.
///
/// It is offered for exactly one file — identified by its SHA-256, not by a
/// version string — because a byte patch applied to a build it was not worked
/// out on is a guess. Nothing is changed unasked; the original is kept beside
/// it and put back by undo.
public struct PointerRepair {

    /// One build this repair was worked out for, and the changes it needs.
    public struct Build: Sendable {
        public var name: String
        /// SHA-256 of the unmodified `win32u.so`.
        public var original: String
        public var patches: [Patch]
        public init(name: String, original: String, patches: [Patch]) {
            self.name = name; self.original = original; self.patches = patches
        }
    }

    /// Bytes at an offset, before and after. Same length, always.
    public struct Patch: Sendable {
        public var offset: Int
        public var old: [UInt8]
        public var new: [UInt8]
        public var what: String
        public init(_ offset: Int, _ old: String, _ new: String, _ what: String) {
            self.offset = offset
            self.old = Self.bytes(old)
            self.new = Self.bytes(new)
            self.what = what
        }
        static func bytes(_ hex: String) -> [UInt8] {
            var out: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
                if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }
                i = j
            }
            return out
        }
    }

    /// Sikarugir Wine 10.0, revision 6, x86_64 `win32u.so`.
    public static let sikarugir10r6 = Build(
        name: "Sikarugir Wine 10.0 (revision 6)",
        original: "dc40c864f9442c9299df2b75d40e78a9550cb7fbdab64dc0ff06941efcec64b9",
        patches: [
            // WM_MOUSEMOVE → WM_POINTERUPDATE. Was: flags = held ? held|INCONTACT|INRANGE
            // : INRANGE|PRIMARY. Now PRIMARY either way, set by `orb $0x20,%ah` at
            // 0xa34b4 — the instruction the other two cases jump through.
            Patch(0xa34a5, "6685d2b8022000000f44f8be4502000089f8",
                           "85d2b8022000000f45c7be4502000080cc20",
                  "a move with a button held carries the primary flag"),
            // Button down: jump to 0xa34b4 rather than 0xa34b7, so a second button
            // pressed during a hold gets the flag too.
            Patch(0xa31bf, "e9f3020000", "e9f0020000",
                  "a second button pressed during a hold carries it"),
            // Button up: the same, for every release.
            Patch(0xa348d, "eb28", "eb25",
                  "every release carries it"),
            // The message table, WM_LBUTTONDBLCLK, WM_RBUTTONDBLCLK,
            // WM_MBUTTONDBLCLK, WM_XBUTTONDBLCLK: from "no pointer message" to
            // the button-down case, which is what Windows sends for them.
            Patch(0xa3d9c, "58f7ffff", "0ff4ffff", "a left double-click is a pointer press"),
            Patch(0xa3da8, "58f7ffff", "0ff4ffff", "a right double-click is a pointer press"),
            Patch(0xa3db4, "58f7ffff", "0ff4ffff", "a middle double-click is a pointer press"),
            Patch(0xa3dc4, "58f7ffff", "0ff4ffff", "a side-button double-click is a pointer press"),
        ])

    public static let backupSuffix = ".before-pointer-repair"

    public enum State: Sendable {
        /// Not a build this repair knows. Nothing is offered.
        case notApplicable
        /// The known build, unrepaired. `source` is where the original bytes
        /// are — the library itself, or a copy of it kept beside it by hand.
        case flawed(build: String, source: URL)
        /// Repaired, with the original kept at `backup`.
        case repaired(build: String, backup: URL)
    }

    public let builds: [Build]
    /// Re-signs a changed library. A byte patch breaks the ad-hoc signature,
    /// and a library whose signature does not verify is one macOS may refuse
    /// to load. Replaceable so the checks can run on files that are not code.
    let sign: (URL) throws -> Void

    public init(builds: [Build] = [Self.sikarugir10r6], sign: ((URL) throws -> Void)? = nil) {
        self.builds = builds
        self.sign = sign ?? { url in
            let r = try Shell.run(URL(filePath: "/usr/bin/codesign"), ["--force", "--sign", "-", url.path], timeout: 120)
            guard r.code == 0 else { throw DecanterError.badFile("could not re-sign \(url.lastPathComponent): \(r.err.suffix(200))") }
        }
    }

    /// The library this repair changes, inside a runtime.
    public static func library(in root: URL) -> URL {
        WineLayout.hostPath(under: root, "win32u.so")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL) -> String? {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).map(sha256)
    }

    public func state(of root: URL) -> State {
        let lib = Self.library(in: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: lib.path), let hash = Self.sha256(of: lib) else { return .notApplicable }
        if let b = builds.first(where: { $0.original == hash }) { return .flawed(build: b.name, source: lib) }

        // Not the original. Either Decanter repaired it, or somebody patched it
        // by hand and kept the original beside it — which is how this repair
        // was first tested. Both are recognised by a kept original whose hash
        // is known; anything else is left alone.
        let dir = lib.deletingLastPathComponent()
        let siblings = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("win32u.so.before-") }.sorted()
        for name in siblings {
            let kept = dir.appending(path: name)
            guard let h = Self.sha256(of: kept), let b = builds.first(where: { $0.original == h }) else { continue }
            if name == "win32u.so" + Self.backupSuffix, isRepaired(lib, as: b) {
                return .repaired(build: b.name, backup: kept)
            }
            return .flawed(build: b.name, source: kept)
        }
        return .notApplicable
    }

    func isRepaired(_ lib: URL, as b: Build) -> Bool {
        guard let d = try? Data(contentsOf: lib, options: .mappedIfSafe) else { return false }
        return b.patches.allSatisfy { p in
            p.offset + p.new.count <= d.count && Array(d[p.offset..<p.offset + p.new.count]) == p.new
        }
    }

    /// Applies the repair. Returns what it changed, in words.
    @discardableResult
    public func apply(to root: URL, progress: (String) -> Void = { _ in }) throws -> [String] {
        guard case .flawed(let name, let source) = state(of: root),
              let build = builds.first(where: { $0.name == name }) else {
            throw DecanterError.notReady("This Wine build is not one the mouse repair was worked out for, so nothing was changed.")
        }
        let fm = FileManager.default
        let lib = Self.library(in: root)
        var data = try Data(contentsOf: source)
        guard Self.sha256(data) == build.original else {
            throw DecanterError.badFile("\(source.lastPathComponent) changed while it was being read. Nothing was changed.")
        }
        for p in build.patches {
            guard p.old.count == p.new.count, p.offset + p.old.count <= data.count,
                  Array(data[p.offset..<p.offset + p.old.count]) == p.old else {
                throw DecanterError.badFile("\(build.name) is not laid out as expected at \(String(p.offset, radix: 16)). Nothing was changed.")
            }
            data.replaceSubrange(p.offset..<p.offset + p.new.count, with: p.new)
        }

        // The original first, so there is always a way back. Kept from the
        // source, which is the original even when the library is not.
        let backup = lib.deletingLastPathComponent().appending(path: "win32u.so" + Self.backupSuffix)
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: source, to: backup)
        }
        guard Self.sha256(of: backup) == build.original else {
            throw DecanterError.badFile("\(backup.lastPathComponent) is not the original, so the repair would leave no way back. Nothing was changed.")
        }

        progress("writing the repaired \(lib.lastPathComponent)")
        let staged = lib.deletingLastPathComponent().appending(path: ".win32u.so.pointer-repair-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: staged) }
        try data.write(to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        try sign(staged)
        _ = try fm.replaceItemAt(lib, withItemAt: staged)

        guard isRepaired(lib, as: build) else {
            throw DecanterError.badFile("The repaired library does not read back as repaired. Undo puts the original back.")
        }
        // A hand-made copy of the original has done its job: the kept backup is
        // the same bytes, and two of them would each look like the way back.
        if source.lastPathComponent != lib.lastPathComponent, source.pathKey != backup.pathKey {
            try? fm.removeItem(at: source)
        }
        return build.patches.map(\.what)
    }

    /// Puts the original back.
    public func undo(root: URL, progress: (String) -> Void = { _ in }) throws {
        guard case .repaired(_, let backup) = state(of: root) else {
            throw DecanterError.notReady("The mouse repair is not applied to this Wine build.")
        }
        let fm = FileManager.default
        let lib = Self.library(in: root)
        progress("putting the original \(lib.lastPathComponent) back")
        let staged = lib.deletingLastPathComponent().appending(path: ".win32u.so.pointer-undo-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: backup, to: staged)
        _ = try fm.replaceItemAt(lib, withItemAt: staged)
        try fm.removeItem(at: backup)
    }

    public static let headline = "Looking around and dragging do nothing here"
    public static let explanation = "Unity 6 reads the mouse as a Windows pointer. This Wine build leaves out the mark that says the mouse is the main pointer whenever a button is held, and sends nothing for a double-click — so clicks work, and anything done with a button held down does not."
    public static func change(in root: URL) -> String {
        "It changes a few bytes of one file in Decanter's own copy of this Wine build — \(WineLayout.hostRelative(under: root, "win32u.so")) — and keeps the original beside it, so it can be undone. Every game on this build gets the fix, and only mouse input changes. Nothing is downloaded or launched."
    }

    /// Whether a game is one this flaw reaches: Unity 6, which reads the mouse
    /// only as a pointer. Older Unity and every other engine read ordinary
    /// mouse messages, which this build delivers correctly.
    public static func affects(_ d: DetectionResult) -> Bool {
        guard d.engine == .unityMono || d.engine == .unityIL2CPP else { return false }
        return (Knowledge.Signature(d).engineMajor ?? 0) >= 6000
    }
}
