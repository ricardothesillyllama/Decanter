import Foundation

/// Taking a game — or only how it is set up — somewhere else.
///
/// Two artefacts, one for each question somebody actually has.
///
/// **A setup file** answers "how did you get this running?". It is a few
/// kilobytes: which Wine, which graphics layer and version, which switches and
/// overrides. It names no game and holds no path, so it can be posted anywhere,
/// and it is the default — most of the time the setup is what somebody wants.
///
/// **A bundle** answers "can I just have it?". It is a Mac app holding the game
/// itself, a Wine to run it and the Windows environment it was set up in. It
/// holds the game, so giving it to someone is distributing that game, and
/// Decanter says so before it builds one.
///
/// Three things were measured before any of this was written, and each one is
/// the reason for a piece of it:
///
/// - **Writing inside a signed app breaks its seal.** A bundle is never where
///   Wine runs: its launcher clones the contents somewhere writable on first
///   open, and the bundle stays exactly as it was signed. See `BundleRunner`.
/// - **A Windows environment is not self-contained.** A real one held six
///   symlinks pointing out of itself — the game's drive, the shared games
///   folder, and protected save folders in Decanter's store. They are cut on
///   the way in and rebuilt where the bundle lands.
/// - **Some things here are not ours to give away.** The Game Porting Toolkit
///   is Apple's, and Wine copies its builtin DLLs into every environment it
///   builds, so neither GPTK nor an environment it built ever goes in a bundle.
///   A Wine build that an earlier repair topped up from GPTK carries those
///   libraries too, and the person building the bundle is asked about them.
public enum Export {
    public static let setupExtension = "decantersetup"
    public static let manifestName = "bundle.json"
    public static let launcherName = "Launch"
    public static let formatVersion = 1

    /// Shown before a bundle is built, never after.
    public static let disclaimer = """
    A bundle contains the whole game. Giving it to someone is distributing that game, so only \
    share one you have the right to share — something free, freely redistributable, or your own \
    work. A game you bought is usually not yours to give away. Decanter checks none of this, and \
    nothing it adds makes sharing allowed.
    """

    /// Wine builds here are x86_64 and run under Rosetta. Stamped into every
    /// bundle because it carries a deadline: Apple has said Rosetta's general
    /// availability ends with macOS 28, and a bundle should say what it needs.
    public static let architecture = "x86_64 (runs under Rosetta)"

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// APFS clone where the volume allows it, a real copy where it does not.
    static func clone(_ src: URL, to dst: URL, timeout: TimeInterval = 3600) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try Shell.run(URL(filePath: "/bin/cp"), ["-Rc", src.path, dst.path], timeout: timeout)
        if r.code != 0 {
            try? fm.removeItem(at: dst)
            let r2 = try Shell.run(URL(filePath: "/bin/cp"), ["-R", src.path, dst.path], timeout: timeout)
            guard r2.code == 0 else { throw DecanterError.cloneFailed(r2.err) }
        }
    }

    /// Removes every symlink in a copied tree that points outside it, and
    /// returns their paths relative to the tree.
    ///
    /// Both sides are compared with symlinks in the *directories* resolved and
    /// the link itself left alone — resolving the link would follow it to
    /// wherever it points, which is the thing being judged, and not resolving
    /// the directories puts /var and /private/var on opposite sides of the test.
    static func cutOutsideLinks(in root: URL) -> [String] {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var cut: [String] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return cut }
        for case let u as URL in en {
            guard (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let dest = try? fm.destinationOfSymbolicLink(atPath: u.path) else { continue }
            let parent = u.deletingLastPathComponent().resolvingSymlinksInPath()
            let target = dest.hasPrefix("/")
                ? URL(filePath: dest).standardizedFileURL.path
                : parent.appending(path: dest).standardizedFileURL.path
            if target == base || target.hasPrefix(base + "/") { continue }
            let here = parent.appending(path: u.lastPathComponent).standardizedFileURL.path
            let rel = here.hasPrefix(base + "/") ? String(here.dropFirst(base.count + 1)) : u.lastPathComponent
            if (try? fm.removeItem(at: u)) != nil { cut.append(rel) }
        }
        return cut.sorted()
    }
}

// MARK: - Setup files

/// How a game is set up, as it leaves the machine. No game name, no path, no
/// identifier — the same rule the knowledge base keeps, for the same reason.
public struct SetupFile: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var decanterVersion: String
    public var engine: GameEngineKind
    public var bitness: Bitness
    public var runtimeKind: RuntimeKind
    public var runtimeVersion: String
    public var backend: GraphicsBackend
    public var layerVersion: String?
    public var launchArguments: [String]
    public var environment: [String: String]
    public var dllOverrides: [String: String]
    public var builtOn: MachineClass

    public init(engine: GameEngineKind, bitness: Bitness, runtimeKind: RuntimeKind,
                runtimeVersion: String, backend: GraphicsBackend, layerVersion: String? = nil,
                launchArguments: [String] = [], environment: [String: String] = [:],
                dllOverrides: [String: String] = [:], builtOn: MachineClass = .current()) {
        self.formatVersion = Export.formatVersion
        self.decanterVersion = Build.version
        self.engine = engine; self.bitness = bitness
        self.runtimeKind = runtimeKind; self.runtimeVersion = runtimeVersion
        self.backend = backend; self.layerVersion = layerVersion
        self.launchArguments = launchArguments; self.environment = environment
        self.dllOverrides = dllOverrides; self.builtOn = builtOn
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, decanterVersion, engine, bitness, runtimeKind, runtimeVersion
        case backend, layerVersion, launchArguments, environment, dllOverrides, builtOn
    }

    /// Hand-written, like every persisted type here: a file written by a newer
    /// Decanter must still open in an older one, as far as it can.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 1
        decanterVersion = (try? c.decode(String.self, forKey: .decanterVersion)) ?? "unknown"
        engine = (try? c.decode(GameEngineKind.self, forKey: .engine)) ?? .generic
        bitness = (try? c.decode(Bitness.self, forKey: .bitness)) ?? .unknown
        runtimeKind = try c.decode(RuntimeKind.self, forKey: .runtimeKind)
        runtimeVersion = (try? c.decode(String.self, forKey: .runtimeVersion)) ?? "unknown"
        backend = try c.decode(GraphicsBackend.self, forKey: .backend)
        layerVersion = try? c.decodeIfPresent(String.self, forKey: .layerVersion)
        launchArguments = (try? c.decode([String].self, forKey: .launchArguments)) ?? []
        environment = (try? c.decode([String: String].self, forKey: .environment)) ?? [:]
        dllOverrides = (try? c.decode([String: String].self, forKey: .dllOverrides)) ?? [:]
        builtOn = (try? c.decode(MachineClass.self, forKey: .builtOn)) ?? MachineClass()
    }

    /// Named after the setup, never the game.
    public var title: String {
        let rt = runtimeKind == .gptk ? "GPTK \(runtimeVersion)" : "Wine \(runtimeVersion)"
        let layer = layerVersion.map { " \($0)" } ?? ""
        return "\(engine.label) on \(rt) with \(backend.plainName) graphics\(layer)"
    }

    public var fileName: String {
        String(title.map { "/:\\".contains($0) ? "-" : $0 }) + "." + Export.setupExtension
    }
}

public extension Engine {

    func setupFile(for game: Game) throws -> SetupFile {
        guard let b = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle for \(game.name)") }
        guard let rt = store.runtime(b.runtimeID) else { throw DecanterError.noRuntime(b.runtimeID) }
        let layer: String? = switch b.backend {
        case .dxvk: b.dxvkVersion
        case .dxmt: DXMTInstaller(paths: paths).defaultVersion
        default: nil
        }
        return SetupFile(engine: game.detection.engine, bitness: game.detection.bitness,
                         runtimeKind: rt.kind, runtimeVersion: rt.version, backend: b.backend,
                         layerVersion: layer, launchArguments: game.launchArguments ?? [],
                         environment: game.envOverrides, dllOverrides: game.dllOverrides)
    }

    @discardableResult
    func writeSetupFile(for game: Game, into folder: URL) throws -> URL {
        let file = try setupFile(for: game)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appending(path: file.fileName)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(file.title.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined()) \(n).\(Export.setupExtension)")
            n += 1
        }
        try Export.encoder().encode(file).write(to: url, options: .atomic)
        return url
    }

    static func readSetupFile(at url: URL) throws -> SetupFile {
        let data = try Data(contentsOf: url)
        guard let file = try? Export.decoder().decode(SetupFile.self, from: data) else {
            throw DecanterError.badFile("\(url.lastPathComponent) is not a setup file Decanter can read.")
        }
        guard file.formatVersion <= Export.formatVersion else {
            throw DecanterError.badFile("\(url.lastPathComponent) was written by a newer Decanter (\(file.decanterVersion)). Update Decanter to read it.")
        }
        return file
    }

    /// Puts a game on the setup a file describes. Nothing is launched.
    ///
    /// Returns what could not be carried across exactly, in words. A setup
    /// made for a different engine is refused unless asked for: a switch that
    /// fixes one engine is a switch that breaks another.
    @discardableResult
    func applySetupFile(_ file: SetupFile, to game: Game, allowDifferentEngine: Bool = false,
                        progress: (String) -> Void = { _ in }) throws -> [String] {
        guard allowDifferentEngine || file.engine == game.detection.engine else {
            throw DecanterError.notReady(
                "This setup was made for a \(file.engine.label) game, and this one is \(game.detection.engine.label). "
                + "Settings rarely carry across engines — apply it anyway only if a guide told you to.")
        }
        let kinds = store.state.runtimes.filter { $0.kind == file.runtimeKind }
        guard let rt = kinds.first(where: { $0.version == file.runtimeVersion }) ?? kinds.first else {
            throw DecanterError.notReady(
                "This setup needs \(file.runtimeKind == .gptk ? "the Game Porting Toolkit" : "a Wine build"), and none is set up on this Mac. Add one from Setup, then apply it again.")
        }
        guard rt.backends.contains(file.backend) || file.backend == .dxmt else {
            throw DecanterError.notReady("\(rt.id) cannot provide \(file.backend.plainName) graphics, which this setup uses.")
        }
        var notes: [String] = []
        if rt.version != file.runtimeVersion {
            notes.append("made with \(file.runtimeVersion); applied on \(rt.version), the closest build here")
        }
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle for \(game.name)") }
        func fresh() -> Game { store.state.games.first { $0.id == game.id } ?? game }
        if bottle.runtimeID != rt.id { _ = try setRuntime(fresh(), to: rt.id, progress: progress) }
        _ = try setBackend(fresh(), file.backend, progress: progress)
        if file.backend == .dxvk, let v = file.layerVersion {
            if DXVKInstaller(paths: paths).stagedVersions().contains(v) {
                _ = try setDXVK(fresh(), version: v, progress: progress)
            } else {
                notes.append("DXVK \(v) is not staged here, so the version already in place was kept")
            }
        }
        _ = try setLaunchArguments(fresh(), file.launchArguments)
        _ = try setEnvironment(fresh(), file.environment, clear: true)
        for (dll, mode) in file.dllOverrides.sorted(by: { $0.key < $1.key }) {
            _ = try setDLLOverride(fresh(), dll: dll, mode: mode)
        }
        note(game.bottleID, "applied a setup file: \(file.title)")
        return notes
    }
}

// MARK: - Bundles

/// What a bundle holds, written into it and read by its launcher.
///
/// The game's name is here because the game is here: a bundle is its own
/// files, and this never leaves the bundle for anywhere else.
public struct BundleManifest: Codable, Sendable {
    public var formatVersion: Int
    public var decanterVersion: String
    public var bundleID: String
    public var gameName: String
    /// The game's folder, as it is named under Resources/game.
    public var gameFolder: String
    /// The executable, relative to that folder.
    public var executable: String
    public var detection: DetectionResult
    public var setup: SetupFile
    /// Nil when the bundle carries no Wine — the Game Porting Toolkit case.
    public var runtimeID: String?
    public var winePath: String?
    public var wineserverPath: String?
    public var supports32Bit: Bool
    public var carriesPrefix: Bool
    public var dxvkVersion: String?
    /// The snapshot under Resources/saves, when saves were included.
    public var savesSnapshot: String?
    /// Libraries left out of the Wine build because they came from GPTK.
    public var omittedLibraries: [String]
    public var builtOn: MachineClass
    public var builtAt: Date
    public var architecture: String

    public var needsGPTK: Bool { runtimeID == nil && setup.runtimeKind == .gptk }

    public init(bundleID: String, gameName: String, gameFolder: String, executable: String,
                detection: DetectionResult, setup: SetupFile, runtimeID: String?, winePath: String?,
                wineserverPath: String?, supports32Bit: Bool, carriesPrefix: Bool, dxvkVersion: String?,
                savesSnapshot: String?, omittedLibraries: [String]) {
        self.formatVersion = Export.formatVersion
        self.decanterVersion = Build.version
        self.bundleID = bundleID; self.gameName = gameName; self.gameFolder = gameFolder
        self.executable = executable; self.detection = detection; self.setup = setup
        self.runtimeID = runtimeID; self.winePath = winePath; self.wineserverPath = wineserverPath
        self.supports32Bit = supports32Bit; self.carriesPrefix = carriesPrefix
        self.dxvkVersion = dxvkVersion; self.savesSnapshot = savesSnapshot
        self.omittedLibraries = omittedLibraries
        self.builtOn = .current(); self.builtAt = Date(); self.architecture = Export.architecture
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, decanterVersion, bundleID, gameName, gameFolder, executable, detection
        case setup, runtimeID, winePath, wineserverPath, supports32Bit, carriesPrefix, dxvkVersion
        case savesSnapshot, omittedLibraries, builtOn, builtAt, architecture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 1
        decanterVersion = (try? c.decode(String.self, forKey: .decanterVersion)) ?? "unknown"
        bundleID = try c.decode(String.self, forKey: .bundleID)
        gameName = try c.decode(String.self, forKey: .gameName)
        gameFolder = try c.decode(String.self, forKey: .gameFolder)
        executable = try c.decode(String.self, forKey: .executable)
        detection = (try? c.decode(DetectionResult.self, forKey: .detection)) ?? DetectionResult()
        setup = try c.decode(SetupFile.self, forKey: .setup)
        runtimeID = try? c.decodeIfPresent(String.self, forKey: .runtimeID)
        winePath = try? c.decodeIfPresent(String.self, forKey: .winePath)
        wineserverPath = try? c.decodeIfPresent(String.self, forKey: .wineserverPath)
        supports32Bit = (try? c.decode(Bool.self, forKey: .supports32Bit)) ?? false
        carriesPrefix = (try? c.decode(Bool.self, forKey: .carriesPrefix)) ?? false
        dxvkVersion = try? c.decodeIfPresent(String.self, forKey: .dxvkVersion)
        savesSnapshot = try? c.decodeIfPresent(String.self, forKey: .savesSnapshot)
        omittedLibraries = (try? c.decode([String].self, forKey: .omittedLibraries)) ?? []
        builtOn = (try? c.decode(MachineClass.self, forKey: .builtOn)) ?? MachineClass()
        builtAt = (try? c.decode(Date.self, forKey: .builtAt)) ?? Date.distantPast
        architecture = (try? c.decode(String.self, forKey: .architecture)) ?? Export.architecture
    }
}

/// Everything worth knowing before a bundle is built, worked out without
/// writing anything.
public struct BundlePlan: Sendable {
    public struct Sizes: Sendable {
        public var runtime = 0, components = 0, prefix = 0, game = 0, saves = 0
        public var total: Int { runtime + components + prefix + game + saves }
    }

    public var game: Game
    public var bottle: Bottle
    public var runtime: RuntimeSpec
    public var suggestedName: String
    public var sizes: Sizes
    /// On the Game Porting Toolkit, which cannot travel — nor can an
    /// environment it built.
    public var needsGPTK: Bool
    /// A Wine setup this kind of game has been seen working on, offered as the
    /// way to make a GPTK game's bundle self-contained.
    public var wineAlternative: Knowledge.Setup?
    /// Libraries in this Wine build that came from GPTK.
    public var borrowedLibraries: [String]
    /// Registry keys the game wrote, which live inside its environment and go
    /// with it even when save files do not.
    public var registryKeysInEnvironment: Int

    public var disclaimer: String { Export.disclaimer }
}

public struct BundleOptions: Sendable {
    /// Off by default: save files carry player names.
    public var includeSaves: Bool
    public var bringYourOwnGPTK: Bool
    public var shipWithoutBorrowedLibraries: Bool

    public init(includeSaves: Bool = false, bringYourOwnGPTK: Bool = false,
                shipWithoutBorrowedLibraries: Bool = false) {
        self.includeSaves = includeSaves
        self.bringYourOwnGPTK = bringYourOwnGPTK
        self.shipWithoutBorrowedLibraries = shipWithoutBorrowedLibraries
    }
}

public extension Engine {

    func planBundle(for game: Game) throws -> BundlePlan {
        guard let bottle = store.bottle(game.bottleID) else { throw DecanterError.notFound("bottle for \(game.name)") }
        guard let rt = store.runtime(bottle.runtimeID) else { throw DecanterError.noRuntime(bottle.runtimeID) }
        let needsGPTK = rt.kind == .gptk

        var alternative: Knowledge.Setup?
        if needsGPTK {
            let sig = Knowledge.Signature(game.detection)
            let failed = Set(knowledge.observations.filter { $0.signature == sig && !$0.worked }.map(\.setup))
            let wine = store.state.runtimes.filter { $0.kind == .wine }
            alternative = knowledge.observations.first { o in
                o.signature == sig && o.worked && o.setup.runtimeKind == .wine
                    && !failed.contains(o.setup)
                    && wine.contains { $0.backends.contains(o.setup.backend) }
            }?.setup
        }

        var borrowed: [String] = []
        if !needsGPTK {
            let gptkIDs = Set(store.state.runtimes.filter { $0.kind == .gptk }.map(\.id))
            borrowed = Array(Set(RuntimeRepair().loadManifest(in: rt.root).borrows
                .filter { gptkIDs.contains($0.donorID) || $0.donorID.hasPrefix("gptk") }
                .map(\.library))).sorted()
        }

        var sizes = BundlePlan.Sizes()
        sizes.game = Self.directorySize(game.exePath.deletingLastPathComponent())
        sizes.saves = saves.discoverEffective(game: game, prefix: bottle.prefixPath,
                                              template: template(for: game)).totalBytes
        if !needsGPTK {
            sizes.runtime = Self.directorySize(rt.root)
            sizes.prefix = Self.directorySize(bottle.prefixPath)
        }
        if bottle.backend == .dxvk, let v = bottle.dxvkVersion ?? DXVKInstaller(paths: paths).defaultVersion {
            sizes.components = Self.directorySize(DXVKInstaller(paths: paths).stagedRoot.appending(path: v))
        } else if bottle.backend == .dxmt {
            sizes.components = Self.directorySize(DXMTInstaller(paths: paths).stagedRoot)
        }

        let keys = needsGPTK ? 0
            : saves.discoverRegistryKeys(in: bottle.prefixPath, template: template(for: game)).count

        return BundlePlan(game: game, bottle: bottle, runtime: rt,
                          suggestedName: String(game.name.map { "/:\\".contains($0) ? "-" : $0 }),
                          sizes: sizes, needsGPTK: needsGPTK, wineAlternative: alternative,
                          borrowedLibraries: borrowed, registryKeysInEnvironment: keys)
    }

    /// Builds the bundle. The plan's choices have to have been made: nothing
    /// here decides on anybody's behalf whether GPTK is left out or borrowed
    /// libraries are dropped.
    @discardableResult
    func buildBundle(_ plan: BundlePlan, options: BundleOptions, into folder: URL, launcher: URL,
                     progress: (String) -> Void = { _ in }) throws -> URL {
        if plan.needsGPTK && !options.bringYourOwnGPTK {
            throw DecanterError.notReady(
                "\(plan.game.name) runs on the Game Porting Toolkit, which cannot go in a bundle. "
                + (plan.wineAlternative.map { "Switch it to \($0.label), which has worked for games like it, or " } ?? "")
                + "build it so whoever opens it supplies their own.")
        }
        if !plan.borrowedLibraries.isEmpty && !options.shipWithoutBorrowedLibraries {
            throw DecanterError.notReady(
                "\(plan.runtime.id) holds \(plan.borrowedLibraries.count) libraries copied in from the Game Porting Toolkit, "
                + "which cannot be shared: \(plan.borrowedLibraries.joined(separator: ", ")). "
                + "Build without them — the game may lose video or audio — or leave this game unbundled.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appending(path: "\(plan.suggestedName).app")
        guard !fm.fileExists(atPath: app.path) else {
            throw DecanterError.usage("\(app.lastPathComponent) already exists in \(folder.path)")
        }
        let stage = folder.appending(path: ".\(plan.suggestedName).app.building-\(UUID().uuidString.prefix(8))")
        var finished = false
        defer { if !finished { try? fm.removeItem(at: stage) } }

        let contents = stage.appending(path: "Contents")
        let res = contents.appending(path: "Resources")
        let macos = contents.appending(path: "MacOS")
        try fm.createDirectory(at: res, withIntermediateDirectories: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)

        // The launcher is this very program. One implementation of launching,
        // so a bundle cannot drift from the app that built it.
        let launch = macos.appending(path: Export.launcherName)
        try Export.clone(launcher, to: launch)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launch.path)

        let bundleID = "local.decanter.bundle.\(UUID().uuidString.lowercased())"
        let info: [String: Any] = [
            "CFBundleExecutable": Export.launcherName,
            "CFBundleIdentifier": bundleID,
            "CFBundleName": plan.suggestedName,
            "CFBundleDisplayName": plan.suggestedName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": Build.version,
            "CFBundleVersion": Build.version,
            "LSMinimumSystemVersion": "14.0",
            "LSApplicationCategoryType": "public.app-category.games",
            "NSHighResolutionCapable": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))

        var omitted: [String] = []
        var winePath: String?, wineserverPath: String?
        if !plan.needsGPTK {
            progress("copying \(plan.runtime.id)")
            let rtCopy = res.appending(path: "runtime")
            try Export.clone(plan.runtime.root, to: rtCopy)
            let rootKey = plan.runtime.root.pathKey
            if options.shipWithoutBorrowedLibraries {
                let gptkIDs = Set(store.state.runtimes.filter { $0.kind == .gptk }.map(\.id))
                for b in RuntimeRepair().loadManifest(in: plan.runtime.root).borrows
                    where gptkIDs.contains(b.donorID) || b.donorID.hasPrefix("gptk") {
                    let dest = b.destination.pathKey
                    guard dest.hasPrefix(rootKey + "/") else { continue }
                    try? fm.removeItem(at: rtCopy.appending(path: String(dest.dropFirst(rootKey.count + 1))))
                    omitted.append(b.library)
                }
                try? fm.removeItem(at: RuntimeRepair.manifestPath(in: rtCopy))
            }
            let wk = plan.runtime.winePath.pathKey
            if wk.hasPrefix(rootKey + "/") { winePath = String(wk.dropFirst(rootKey.count + 1)) }
            if let ws = plan.runtime.wineserverPath?.pathKey, ws.hasPrefix(rootKey + "/") {
                wineserverPath = String(ws.dropFirst(rootKey.count + 1))
            }

            progress("copying the Windows environment")
            let pfx = res.appending(path: "prefix")
            try Export.clone(plan.bottle.prefixPath, to: pfx)
            let cut = Export.cutOutsideLinks(in: pfx)
            if !cut.isEmpty { progress("left out \(cut.count) link(s) pointing outside it: \(cut.joined(separator: ", "))") }
            if !options.includeSaves {
                let found = saves.discover(in: pfx, template: template(for: plan.game)).files
                for f in found { try? fm.removeItem(at: pfx.appending(path: f.relPath)) }
                if !found.isEmpty { progress("left out \(found.count) save file(s)") }
            }
        }

        if plan.bottle.backend == .dxvk, let v = plan.bottle.dxvkVersion ?? DXVKInstaller(paths: paths).defaultVersion {
            let src = DXVKInstaller(paths: paths).stagedRoot.appending(path: v)
            if fm.fileExists(atPath: src.path) { try Export.clone(src, to: res.appending(path: "components/dxvk/\(v)")) }
        } else if plan.bottle.backend == .dxmt {
            let src = DXMTInstaller(paths: paths).stagedRoot
            if fm.fileExists(atPath: src.path) { try Export.clone(src, to: res.appending(path: "components/dxmt")) }
        }

        progress("copying the game")
        let gameDir = plan.game.exePath.deletingLastPathComponent()
        try Export.clone(gameDir, to: res.appending(path: "game/\(gameDir.lastPathComponent)"))

        var snapshotName: String?
        if options.includeSaves {
            progress("taking a snapshot of the saves")
            let snap = try saves.snapshot(game: plan.game, prefix: plan.bottle.prefixPath,
                                          template: template(for: plan.game), note: "taken for a bundle")
            try Export.clone(snap.url, to: res.appending(path: "saves/\(snap.name)"))
            snapshotName = snap.name
        }

        let setup = try setupFile(for: plan.game)
        let manifest = BundleManifest(
            bundleID: bundleID, gameName: plan.game.name, gameFolder: gameDir.lastPathComponent,
            executable: plan.game.exePath.lastPathComponent, detection: plan.game.detection, setup: setup,
            runtimeID: plan.needsGPTK ? nil : plan.runtime.id, winePath: winePath, wineserverPath: wineserverPath,
            supports32Bit: plan.runtime.supports32Bit, carriesPrefix: !plan.needsGPTK,
            dxvkVersion: plan.bottle.dxvkVersion, savesSnapshot: snapshotName,
            omittedLibraries: omitted.sorted())
        try Export.encoder().encode(manifest).write(to: res.appending(path: Export.manifestName))

        // Extended attributes — quarantine flags, Finder info — make codesign
        // refuse a bundle outright, so they go first.
        progress("signing")
        _ = try? Shell.run(URL(filePath: "/usr/bin/xattr"), ["-cr", stage.path], timeout: 600)
        let sign = try Shell.run(URL(filePath: "/usr/bin/codesign"),
                                 ["--force", "--deep", "--sign", "-", stage.path], timeout: 3600)
        guard sign.code == 0 else {
            throw DecanterError.badFile("The bundle could not be signed: \(sign.err.suffix(300))")
        }
        let verify = try Shell.run(URL(filePath: "/usr/bin/codesign"),
                                   ["--verify", "--deep", "--strict", stage.path], timeout: 3600)
        guard verify.code == 0 else {
            throw DecanterError.badFile("The bundle was signed but does not verify: \(verify.err.suffix(300))")
        }
        try fm.moveItem(at: stage, to: app)
        finished = true
        return app
    }
}
