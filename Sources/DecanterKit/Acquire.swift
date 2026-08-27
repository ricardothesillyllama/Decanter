import Foundation

/// Turns "the user handed us a file" into a pinned runtime or a staged
/// graphics layer.
///
/// Decanter never fetches anything: the whole project exists because Whisky's
/// installed copies broke when an upstream repository was deleted. But that
/// rule is about not depending on a *server*, not about making people type.
/// A file the user already has on disk is not a dependency, so accepting a
/// drop costs none of the guarantee and removes every remaining reason to
/// open Terminal during setup.
public struct Acquisition {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    /// What a dropped path turns out to be. Classification is by content —
    /// a Wine tree is a directory with a `bin/wine` in it, whatever it is
    /// called — because the names differ between every source people get
    /// these from.
    public enum Piece: Sendable, Equatable {
        case wineRoot(URL)
        case diskImage(URL)
        /// An archive that is named like a Wine build. Whether it really is
        /// one can only be settled by unpacking it, which is `accept`'s job:
        /// classification happens while the user is still dragging.
        case wineArchive(URL)
        case dxvkArchive(URL)
        case dxmtArchive(URL)
        case unrecognised(String)

        public var summary: String {
            switch self {
            case .wineRoot(let u): "a Wine build at \(u.lastPathComponent)"
            case .diskImage(let u): "the disk image \(u.lastPathComponent)"
            case .wineArchive(let u): "the Wine archive \(u.lastPathComponent)"
            case .dxvkArchive(let u): "the DXVK archive \(u.lastPathComponent)"
            case .dxmtArchive(let u): "the DXMT archive \(u.lastPathComponent)"
            case .unrecognised(let why): why
            }
        }
    }

    /// Every path this type hands back goes through here first.
    ///
    /// `contentsOfDirectory` returns directory URLs with a trailing slash and
    /// the temporary directory resolves `/var` to `/private/var`, so the same
    /// folder reached two ways produced two unequal URLs. That is the same
    /// mismatch that once broke per-game stop and the reaper's keep-list, and
    /// it is cheaper to have one canonical form than to remember to compare
    /// carefully at every site.
    func canonical(_ u: URL) -> URL { URL(filePath: u.pathKey) }

    /// A directory is a Wine root if the binary is where Wine puts it.
    /// Checked before anything else, so a folder someone renamed still works.
    public func isWineRoot(_ u: URL) -> Bool {
        fm.isExecutableFile(atPath: u.appending(path: "bin/wine").path)
            || fm.isExecutableFile(atPath: u.appending(path: "bin/wine64").path)
    }

    /// Wine trees hide at different depths depending on where the build came
    /// from: loose, inside an `.app`, or one level down in a disk image whose
    /// top level is a licence file and a folder. Three levels covers every
    /// layout seen so far and keeps this from walking a whole home directory
    /// if someone drops the wrong thing.
    public func findWineRoot(under u: URL, depth: Int = 3) -> URL? {
        if isWineRoot(u) { return canonical(u) }
        // The conventional spot inside a .app bundle, checked directly so the
        // common case does not depend on the search below.
        let inBundle = u.appending(path: "Contents/Resources/wine")
        if isWineRoot(inBundle) { return canonical(inBundle) }
        guard depth > 0 else { return nil }
        let kids = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        // Deterministic order: two candidates in one image must always resolve
        // to the same one, or a user's second attempt pins something different.
        for kid in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let found = findWineRoot(under: kid, depth: depth - 1) { return found }
        }
        return nil
    }

    /// DXVK ships as `dxvk-<version>.tar.gz`. Match on the extension and the
    /// name, not on unpacking it — classification runs on the main thread as
    /// the user drags, and must be instant.
    public func looksLikeDXVK(_ u: URL) -> Bool {
        let n = u.lastPathComponent.lowercased()
        return n.contains("dxvk") && (n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz"))
    }

    /// Every archive shape Decanter will open. `.tar.xz` is the one the
    /// official macOS Wine builds actually ship as, and its absence here meant
    /// the file at the end of Decanter's own download link was rejected with
    /// "not something Decanter can use" — the only supported route to a Wine
    /// build was a Homebrew cask, which is a Terminal command this app exists
    /// to avoid. `tar` reads all of these through libarchive.
    static let archiveSuffixes = [".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.zst", ".zip"]

    public func looksLikeDXMT(_ u: URL) -> Bool {
        let n = u.lastPathComponent.lowercased()
        return n.contains("dxmt") && Self.archiveSuffixes.contains { n.hasSuffix($0) }
    }

    /// Matched by name, like the two above, and for the same reason: deciding
    /// properly means unpacking half a gigabyte, and this runs as the user
    /// drags. Every build Gcenx publishes is `wine-devel-…` or `wine-staging-…`,
    /// so the name carries enough. A wrong guess costs one clear sentence from
    /// `withWineRoot(inArchive:)`, not a bad install.
    public func looksLikeWineArchive(_ u: URL) -> Bool {
        let n = u.lastPathComponent.lowercased()
        return n.contains("wine") && Self.archiveSuffixes.contains { n.hasSuffix($0) }
    }

    /// `wineSearchDepth` is lowered when scanning the contents of a dropped
    /// folder: three levels per child is fine for one deliberate drop and is a
    /// visible pause across every item in a Downloads folder.
    public func classify(_ url: URL, wineSearchDepth: Int = 3) -> Piece {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".dmg") { return .diskImage(canonical(url)) }
        if looksLikeDXVK(url) { return .dxvkArchive(canonical(url)) }
        if looksLikeDXMT(url) { return .dxmtArchive(canonical(url)) }
        if looksLikeWineArchive(url) { return .wineArchive(canonical(url)) }
        if Self.archiveSuffixes.contains(where: { n.hasSuffix($0) }) {
            return .unrecognised("\(url.lastPathComponent) is an archive, but not one Decanter recognises — Wine builds are named wine-devel-<version>-osx64.tar.xz, DXVK releases dxvk-<version>.tar.gz, DXMT releases dxmt-<version>.tar.gz")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return .unrecognised("\(url.lastPathComponent) is not something Decanter can use")
        }
        if let root = findWineRoot(under: url, depth: wineSearchDepth) { return .wineRoot(root) }
        return .unrecognised("no Wine build inside \(url.lastPathComponent)")
    }

    /// Everything usable that a dropped path turns out to hold.
    ///
    /// A single file is the common case and behaves exactly as it did. This is
    /// for the other one: a Downloads folder holding a Wine build and two
    /// graphics archives, where three separate drags are three chances to drag
    /// the wrong thing. Only the immediate children are considered — a folder
    /// someone drops is a place they put files, not a tree to go hunting in.
    public func classifyAll(_ url: URL) -> [Piece] {
        let single = classify(url)
        guard case .unrecognised = single else { return [single] }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [single] }
        let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        var out: [Piece] = []
        for kid in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let piece = classify(kid, wineSearchDepth: 2)
            if case .unrecognised = piece { continue }
            out.append(piece)
        }
        return out.isEmpty ? [single] : Self.inDependencyOrder(out)
    }

    /// Runtimes before graphics layers. Staging DXMT reports whether anything
    /// on this Mac can host it, and that answer is wrong if the Wine build
    /// sitting in the same folder has not been pinned yet.
    static func inDependencyOrder(_ pieces: [Piece]) -> [Piece] {
        func rank(_ p: Piece) -> Int {
            switch p {
            case .wineRoot, .diskImage, .wineArchive: 0
            case .dxvkArchive: 1
            case .dxmtArchive: 2
            case .unrecognised: 3
            }
        }
        // Sorting in Swift is not stable, and two archives of the same kind
        // must not swap between runs: the index breaks every tie.
        return pieces.enumerated()
            .sorted { rank($0.element) == rank($1.element) ? $0.offset < $1.offset
                                                          : rank($0.element) < rank($1.element) }
            .map(\.element)
    }

    // MARK: - Disk images

    /// Mounted read-only and without showing in the Finder, then always
    /// detached. `-nobrowse` matters: a stray mounted volume from a failed
    /// setup is confusing, and users then eject it by dragging it to the bin.
    public struct Mount: Sendable, Equatable {
        public let device: String
        public let mountPoint: URL
    }

    func attach(_ dmg: URL) throws -> Mount {
        let r = try Shell.run(URL(filePath: "/usr/bin/hdiutil"),
                              ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"],
                              timeout: 300)
        guard r.code == 0 else {
            throw DecanterError.notFound("could not open \(dmg.lastPathComponent): \(r.err.isEmpty ? r.out : r.err)")
        }
        guard let m = Self.parseAttach(plist: r.out) else {
            throw DecanterError.notFound("\(dmg.lastPathComponent) mounted but exposed no volume")
        }
        return m
    }

    /// hdiutil's plist lists every entity in the image; only one of them has a
    /// mount point. Parsed with PropertyListSerialization rather than by
    /// scraping the human-readable output, which is tab-separated and changes.
    public static func parseAttach(plist: String) -> Mount? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        for e in entities {
            guard let point = e["mount-point"] as? String, !point.isEmpty else { continue }
            let dev = (e["dev-entry"] as? String) ?? point
            return Mount(device: dev, mountPoint: URL(filePath: point))
        }
        return nil
    }

    func detach(_ m: Mount) {
        // Best effort, and forced: Wine's own files may still be settling and
        // a polite eject fails. Leaving the volume mounted is the worse
        // outcome, so this never throws into the caller's path.
        _ = try? Shell.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", m.device, "-force"], timeout: 120)
    }

    /// Copies the Wine tree out of a disk image before the image is ejected.
    /// The pin has to happen while mounted, so this hands the root to a body
    /// and guarantees the eject afterwards.
    /// Unpacks an archive into scratch space and hands the Wine tree inside it
    /// to `body`, removing the copy however the call ends. The mirror of
    /// `withWineRoot(inDiskImage:)`, and it exists for the same reason: the pin
    /// has to happen while the tree is still on disk.
    public func withWineRoot<T>(inArchive archive: URL, _ body: (URL) throws -> T) throws -> T {
        let tmp = paths.root.appending(path: "tmp-wine")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let name = archive.lastPathComponent.lowercased()
        // Generous: these are hundreds of megabytes, and a slow disk unpacking
        // one is not a hang.
        let r: (code: Int32, out: String, err: String)
        if name.hasSuffix(".zip") {
            r = try Shell.run(URL(filePath: "/usr/bin/unzip"), ["-q", archive.path, "-d", tmp.path], timeout: 900)
        } else {
            r = try Shell.run(URL(filePath: "/usr/bin/tar"), ["xf", archive.path, "-C", tmp.path], timeout: 900)
        }
        guard r.code == 0 else { throw DecanterError.cloneFailed("unpack: \(r.err)") }
        guard let root = findWineRoot(under: tmp) else {
            throw DecanterError.notFound(
                "\(archive.lastPathComponent) unpacked, but there is no Wine build inside it — "
                + "the file to fetch is named wine-devel-<version>-osx64.tar.xz")
        }
        return try body(root)
    }

    public func withWineRoot<T>(inDiskImage dmg: URL, _ body: (URL) throws -> T) throws -> T {
        let mount = try attach(dmg)
        defer { detach(mount) }
        guard let root = findWineRoot(under: mount.mountPoint) else {
            throw DecanterError.notFound("\(dmg.lastPathComponent) does not contain a Wine build")
        }
        return try body(root)
    }
}

public extension Engine {
    /// One entry point for every piece a user can hand Decanter, so the app,
    /// the wizard and the CLI cannot disagree about what a dropped file means.
    /// Returns a sentence to show the user, because "it worked" without saying
    /// what worked is how people end up running setup twice.
    @discardableResult
    func accept(droppedPath url: URL, progress: (String) -> Void = { _ in }) throws -> String {
        let acq = Acquisition(paths: paths)
        let pieces = acq.classifyAll(url)
        guard pieces.count > 1 else { return try apply(pieces[0], acq: acq, progress: progress) }

        // A folder can hold several usable things, and one of them failing must
        // not throw away the ones that worked — otherwise someone who dropped a
        // folder is left guessing which parts landed.
        var done: [String] = []
        var failed: [String] = []
        for piece in pieces {
            do { done.append(try apply(piece, acq: acq, progress: progress)) }
            catch { failed.append(error.localizedDescription) }
        }
        guard !done.isEmpty else { throw DecanterError.notFound(failed.joined(separator: "; ")) }
        return done.joined(separator: "\n")
             + (failed.isEmpty ? "" : "\n\nNot taken: " + failed.joined(separator: "; "))
    }

    /// One piece, taken in. Split out of `accept` so a folder holding three of
    /// them runs the same code three times rather than a second implementation.
    private func apply(_ piece: Acquisition.Piece, acq: Acquisition,
                       progress: (String) -> Void) throws -> String {
        switch piece {
        case .wineRoot(let root):
            let c = try runtimes.inspect(wineRoot: root)
            progress("found \(c.kind.rawValue) \(c.version)")
            let spec = try runtimes.pin(c, store: store)
            return "Added \(Self.friendly(spec)) — Decanter now has its own copy"

        case .wineArchive(let archive):
            progress("unpacking \(archive.lastPathComponent)")
            return try acq.withWineRoot(inArchive: archive) { root in
                let c = try runtimes.inspect(wineRoot: root)
                progress("found \(c.kind.rawValue) \(c.version) inside the archive")
                let spec = try runtimes.pin(c, store: store)
                return "Added \(Self.friendly(spec)) — Decanter now has its own copy"
            }

        case .diskImage(let dmg):
            progress("opening \(dmg.lastPathComponent)")
            return try acq.withWineRoot(inDiskImage: dmg) { root in
                let c = try runtimes.inspect(wineRoot: root)
                progress("found \(c.kind.rawValue) \(c.version) inside the disk image")
                let spec = try runtimes.pin(c, store: store)
                return "Added \(Self.friendly(spec)) — Decanter now has its own copy"
            }

        case .dxvkArchive(let tarball):
            let v = try DXVKInstaller(paths: paths).stage(tarball: tarball, progress: progress)
            return "Added Vulkan graphics (DXVK \(v))"

        case .dxmtArchive(let archive):
            let v = try DXMTInstaller(paths: paths).stage(archive: archive, progress: progress)
            // Staging is not the same as being able to use it, and saying so
            // here saves someone switching a game over and hitting a wall.
            let hosts = store.state.runtimes.filter {
                RuntimeManager.metalHosting(root: $0.root).looksCapable
            }
            if hosts.isEmpty {
                return "Added Metal graphics (DXMT \(v)) — but no runtime here can host it yet. "
                     + "It needs a Wine whose Mac driver exposes a Cocoa view; the Game Porting Toolkit's Wine does."
            }
            return "Added Metal graphics (DXMT \(v)) — usable on "
                 + hosts.map(\.id).joined(separator: ", ")

        case .unrecognised(let why):
            throw DecanterError.notFound(why)
        }
    }

    /// Plain name first, real name in brackets. Used anywhere a runtime is
    /// named to a person rather than to a log.
    static func friendly(_ spec: RuntimeSpec) -> String {
        switch spec.kind {
        case .gptk: "Apple graphics support (Game Porting Toolkit, Wine \(spec.version))"
        case .wine: "Windows support (Wine \(spec.version))"
        }
    }

    /// macOS offers Rosetta automatically the first time an Intel binary runs,
    /// which for most people happens on their first game. This is for everyone
    /// else. The command is a constant with nothing interpolated into it; the
    /// password prompt is the system's own.
    func installRosetta() throws -> String {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        let r = try Shell.run(URL(filePath: "/usr/bin/osascript"), ["-e", script], timeout: 900)
        guard r.code == 0 else {
            throw DecanterError.notFound("Rosetta 2 was not installed: \(r.err.isEmpty ? r.out : r.err)")
        }
        return "Rosetta 2 installed"
    }
}
