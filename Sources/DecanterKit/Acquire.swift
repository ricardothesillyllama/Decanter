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
        case dxvkArchive(URL)
        case dxmtArchive(URL)
        case unrecognised(String)

        public var summary: String {
            switch self {
            case .wineRoot(let u): "a Wine build at \(u.lastPathComponent)"
            case .diskImage(let u): "the disk image \(u.lastPathComponent)"
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

    /// DXMT ships its releases under more suffixes than DXVK does, so the set
    /// is named once rather than repeated at each test.
    static let archiveSuffixes = [".tar.gz", ".tgz", ".tar.zst", ".zip"]

    public func looksLikeDXMT(_ u: URL) -> Bool {
        let n = u.lastPathComponent.lowercased()
        return n.contains("dxmt") && Self.archiveSuffixes.contains { n.hasSuffix($0) }
    }

    public func classify(_ url: URL) -> Piece {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".dmg") { return .diskImage(canonical(url)) }
        if looksLikeDXVK(url) { return .dxvkArchive(canonical(url)) }
        if looksLikeDXMT(url) { return .dxmtArchive(canonical(url)) }
        if Self.archiveSuffixes.contains(where: { n.hasSuffix($0) }) {
            return .unrecognised("\(url.lastPathComponent) is an archive, but not one Decanter recognises — DXVK releases are named dxvk-<version>.tar.gz, DXMT releases dxmt-<version>.tar.gz")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return .unrecognised("\(url.lastPathComponent) is not something Decanter can use")
        }
        if let root = findWineRoot(under: url) { return .wineRoot(root) }
        return .unrecognised("no Wine build inside \(url.lastPathComponent)")
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
        switch acq.classify(url) {
        case .wineRoot(let root):
            let c = try runtimes.inspect(wineRoot: root)
            progress("found \(c.kind.rawValue) \(c.version)")
            let spec = try runtimes.pin(c, store: store)
            return "Added \(Self.friendly(spec)) — Decanter now has its own copy"

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
