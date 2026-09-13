import Foundation

/// What a bundle does when somebody opens it.
///
/// A bundle is never where Wine runs. Writing inside a signed app breaks its
/// seal — measured, not assumed: `codesign --verify` and `spctl` both report
/// "a sealed resource is missing or invalid" after one file inside changes, and
/// Wine writes to its environment on every launch. So the first open clones
/// the bundle's contents into a folder of its own under Application Support,
/// rewrites every path to point there, and runs from that copy. The bundle
/// stays exactly as it was signed, which is also what lets it be copied to
/// another Mac again afterwards.
///
/// An existing copy is never replaced. It holds this person's saves; opening a
/// newer bundle of the same game is not a reason to overwrite them.
public struct BundleRunner: Sendable {
    public let app: URL
    public let manifest: BundleManifest
    public let home: URL

    public var resources: URL { app.appending(path: "Contents/Resources") }

    public init(app: URL, manifest: BundleManifest, home: URL) {
        self.app = app; self.manifest = manifest; self.home = home
    }

    /// The bundle this executable is running from, if it is running from one.
    public static func current(executable: URL, home: URL? = nil) -> BundleRunner? {
        let macos = executable.deletingLastPathComponent()
        let contents = macos.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macos.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        let m = contents.appending(path: "Resources/\(Export.manifestName)")
        guard let data = try? Data(contentsOf: m),
              let manifest = try? Export.decoder().decode(BundleManifest.self, from: data) else { return nil }
        return BundleRunner(app: app, manifest: manifest, home: home ?? defaultHome(for: manifest))
    }

    public static func defaultHome(for m: BundleManifest) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Decanter Bundles/\(m.bundleID)")
    }

    /// Takes a Game Porting Toolkit somebody hands over — a disk image, the
    /// app, or a Wine folder — into this bundle's own folder, exactly the way
    /// Setup takes one. Refuses anything that turns out not to be the toolkit,
    /// rather than pinning an ordinary Wine where GPTK was asked for.
    @discardableResult
    public func acceptGPTK(from url: URL, progress: (String) -> Void = { _ in }) throws -> String {
        let paths = Paths(root: home)
        try paths.ensure()
        let e = try Engine(paths: paths)
        let said = try e.accept(droppedPath: url, progress: progress)
        guard e.store.state.runtimes.contains(where: { $0.kind == .gptk }) else {
            throw DecanterError.badFile("\(url.lastPathComponent) is not the Game Porting Toolkit.")
        }
        return said
    }

    public enum Preparation {
        case ready(Engine, Game)
        /// The bundle runs on GPTK and this Mac has none. The words say what to do.
        case needsGPTK(String)
    }

    public func prepare(progress: @escaping (String) -> Void = { _ in }) throws -> Preparation {
        let fm = FileManager.default
        let paths = Paths(root: home)
        try paths.ensure()
        let e = try Engine(paths: paths)
        if let g = e.store.state.games.first(where: { $0.name == manifest.gameName }),
           e.store.bottle(g.bottleID) != nil {
            return .ready(e, g)
        }

        // Wine: the bundle's own, or the Game Porting Toolkit on this Mac.
        let spec: RuntimeSpec
        if let rid = manifest.runtimeID, let wp = manifest.winePath {
            let dest = paths.runtimes.appending(path: rid)
            if !fm.fileExists(atPath: dest.path) {
                progress("copying \(rid) out of the bundle")
                try Export.clone(resources.appending(path: "runtime"), to: dest)
            }
            let kind = manifest.setup.runtimeKind
            spec = RuntimeSpec(id: rid, kind: kind, version: manifest.setup.runtimeVersion, root: dest,
                               winePath: dest.appending(path: wp),
                               wineserverPath: manifest.wineserverPath.map { dest.appending(path: $0) },
                               supports32Bit: manifest.supports32Bit,
                               backends: RuntimeManager.backends(for: kind, root: dest))
            let s = spec
            try e.store.mutate { st in
                st.runtimes.removeAll { $0.id == s.id }
                st.runtimes.append(s)
            }
        } else if let taken = e.store.state.runtimes.first(where: { $0.kind == .gptk }) {
            // Handed over earlier, and already this bundle's own copy.
            spec = taken
        } else {
            let manager = RuntimeManager(paths: paths)
            guard let gptk = manager.discover().first(where: { $0.kind == .gptk }) else {
                return .needsGPTK(
                    "This bundle runs on Apple's Game Porting Toolkit, which cannot be included in it. "
                    + "Choose the Game Porting Toolkit — its disk image, or the app — and the bundle takes its own copy. "
                    + "Nothing is downloaded.")
            }
            progress("taking a copy of the Game Porting Toolkit on this Mac")
            spec = try manager.pin(gptk, store: e.store)
        }

        // Graphics layers the bundle carried, where Decanter looks for them.
        for name in ["dxvk", "dxmt"] {
            let src = resources.appending(path: "components/\(name)")
            guard let items = try? fm.contentsOfDirectory(atPath: src.path) else { continue }
            for item in items where !item.hasPrefix(".") {
                let dest = paths.runtimes.appending(path: "\(name)/\(item)")
                if !fm.fileExists(atPath: dest.path) {
                    try Export.clone(src.appending(path: item), to: dest)
                }
            }
        }

        let gameDir = home.appending(path: "game/\(manifest.gameFolder)")
        if !fm.fileExists(atPath: gameDir.path) {
            progress("copying the game out of the bundle")
            try Export.clone(resources.appending(path: "game/\(manifest.gameFolder)"), to: gameDir)
        }
        let exe = gameDir.appending(path: manifest.executable)

        let bottleID = UUID()
        let bottle: Bottle
        if manifest.carriesPrefix {
            let dest = paths.bottles.appending(path: bottleID.uuidString)
            progress("copying the Windows environment out of the bundle")
            try Export.clone(resources.appending(path: "prefix"), to: dest)
            let backend = spec.backends.contains(manifest.setup.backend) || manifest.setup.backend == .dxmt
                ? manifest.setup.backend : (spec.backends.first ?? .wined3d)
            bottle = Bottle(id: bottleID, prefixPath: dest, runtimeID: spec.id, backend: backend,
                            dxvkVersion: manifest.dxvkVersion)
        } else {
            progress("building a Windows environment with \(spec.id) — about a minute, and only the first time")
            try e.buildTemplate(runtimeID: spec.id, progress: progress)
            let backend = spec.backends.contains(manifest.setup.backend)
                ? manifest.setup.backend : (spec.backends.first ?? .wined3d)
            bottle = try e.prefixes.derive(bottleID: bottleID, runtime: spec, backend: backend)
        }

        var game = Game(name: manifest.gameName, exePath: exe, bottleID: bottleID,
                        detection: manifest.detection, scopes: e.launcher.defaultScopes(for: exe))
        game.launchArguments = manifest.setup.launchArguments.isEmpty ? nil : manifest.setup.launchArguments
        game.envOverrides = manifest.setup.environment
        game.dllOverrides = manifest.setup.dllOverrides
        let g = game, b = bottle
        try e.store.mutate { st in
            st.bottles.append(b)
            st.games.append(g)
        }

        // Saves the bundle carried go in through the same door as saves kept
        // from a removed game: a kept store, adopted into this game.
        if let snap = manifest.savesSnapshot {
            let kept = "\(e.saves.slug(for: game))--kept-bundle"
            try Export.clone(resources.appending(path: "saves/\(snap)"),
                             to: paths.saves.appending(path: "\(kept)/snapshots/\(snap)"))
            _ = try e.saves.adopt(keptSlug: kept, into: game, prefix: bottle.prefixPath, runtime: spec,
                                  knownSlugs: Set(e.store.state.games.map { e.saves.slug(for: $0) }),
                                  progress: progress)
        }
        return .ready(e, game)
    }
}
