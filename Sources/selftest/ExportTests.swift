import Foundation
import DecanterKit

/// A small library with one Wine build, one game and one environment, laid out
/// the way a real one is — including the links that point outside a prefix.
private struct ExportFixture {
    let e: Engine
    let game: Game
    let runtime: RuntimeSpec
    let gameDir: URL
}

private func makeExportFixture(_ tag: String, kind: RuntimeKind = .wine,
                               backends: [GraphicsBackend] = [.dxvk, .wined3d],
                               engine: GameEngineKind = .unityIL2CPP,
                               name: String = "Secret Fixture Title") -> ExportFixture? {
    let fm = FileManager.default
    let root = Fixture.dir(tag)
    guard let e = try? Engine(paths: Paths(root: root)) else { return nil }
    let rid = kind == .gptk ? "gptk-fixture" : "wine-fixture"
    let rtRoot = e.paths.runtimes.appending(path: rid)
    try? fm.createDirectory(at: rtRoot.appending(path: "bin"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: rtRoot.appending(path: "lib"), withIntermediateDirectories: true)
    try? Data("#!/bin/sh\n".utf8).write(to: rtRoot.appending(path: "bin/wine"))
    try? Data("not really a library".utf8).write(to: rtRoot.appending(path: "lib/libfoo.dylib"))
    let rt = RuntimeSpec(id: rid, kind: kind, version: "11.0", root: rtRoot,
                         winePath: rtRoot.appending(path: "bin/wine"),
                         wineserverPath: rtRoot.appending(path: "bin/wineserver"),
                         supports32Bit: true, backends: backends)

    // The template the environment was cloned from: it has the user folder
    // and none of the game's files.
    let tpl = e.paths.template(for: rid)
    try? fm.createDirectory(at: tpl.appending(path: "drive_c/users/tester/AppData/LocalLow"),
                            withIntermediateDirectories: true)

    let gameDir = Fixture.dir("\(tag)-game").appending(path: "Some Game")
    try? fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
    try? Data("MZ".utf8).write(to: gameDir.appending(path: "Game.exe"))

    let bottleID = UUID()
    let prefix = e.paths.bottles.appending(path: bottleID.uuidString)
    let save = prefix.appending(path: "drive_c/users/tester/AppData/LocalLow/Vendor/Product/save.dat")
    try? fm.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("progress".utf8).write(to: save)
    try? fm.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
    try? fm.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/h:").path, withDestinationPath: gameDir.path)

    var det = DetectionResult()
    det.engine = engine; det.bitness = .x64; det.graphicsAPIs = ["d3d11.dll"]
    let game = Game(name: name, exePath: gameDir.appending(path: "Game.exe"), bottleID: bottleID, detection: det)
    try? e.store.mutate { s in
        s.runtimes = [rt]
        s.games = [game]
        s.bottles = [Bottle(id: bottleID, prefixPath: prefix, runtimeID: rid, backend: backends[0])]
    }
    return ExportFixture(e: e, game: game, runtime: rt, gameDir: gameDir)
}

func runSetupFileTests(_ t: Harness) {
    t.suite("A setup file says how a game is set up, and nothing about which game")
    guard let f = makeExportFixture("setupfile") else { t.expect(false, "a fixture library can be made"); return }
    let e = f.e
    _ = try? e.setLaunchArguments(f.game, ["-screen-fullscreen", "0"])
    _ = try? e.setEnvironment(f.game, ["LANG": "ja_JP.UTF-8"])
    _ = try? e.setDLLOverride(f.game, dll: "winhttp", mode: "n,b")
    let game = e.store.state.games[0]

    guard let file = try? e.setupFile(for: game) else { t.expect(false, "a setup file can be made"); return }
    let json = String(decoding: (try? JSONEncoder().encode(file)) ?? Data(), as: UTF8.self)
    t.expect(!json.contains("Secret Fixture Title"), "the game's name is not in it")
    t.expect(!json.contains("Game.exe") && !json.contains("/"), "nor its executable, nor any path")
    t.expect(!file.title.contains("Secret"), "and it is named after the setup, not the game")
    t.equal(file.launchArguments, ["-screen-fullscreen", "0"], "launch switches go with it")
    t.equal(file.dllOverrides["winhttp"], "n,b", "and DLL overrides")
    t.equal(file.environment["LANG"], "ja_JP.UTF-8", "and environment settings")

    let out = Fixture.dir("setupfile-out")
    let url = try? e.writeSetupFile(for: game, into: out)
    t.equal(url?.pathExtension, Export.setupExtension, "it is written with its own extension")
    t.equal(url.flatMap { try? Engine.readSetupFile(at: $0) }, file, "and reads back exactly as written")

    // Applied to a different game of the same kind.
    let otherID = UUID()
    let other = Game(name: "Another", exePath: f.gameDir.appending(path: "Game.exe"), bottleID: otherID,
                     detection: game.detection)
    try? e.store.mutate { s in
        s.games.append(other)
        s.bottles.append(Bottle(id: otherID, prefixPath: Fixture.dir("setupfile-other-prefix"),
                                runtimeID: f.runtime.id, backend: .wined3d))
    }
    t.survives("a setup applies to another game of the same kind") { _ = try e.applySetupFile(file, to: other) }
    // By bottle: a game's own id is generated separately from its bottle's.
    let applied = e.store.state.games.first { $0.bottleID == otherID }
    t.equal(applied?.launchArguments, ["-screen-fullscreen", "0"], "carrying its switches")
    t.equal(applied.flatMap { e.store.bottle($0.bottleID)?.backend }, file.backend, "and its graphics")

    var godot = DetectionResult(); godot.engine = .godot
    let strangerID = UUID()
    let stranger = Game(name: "Stranger", exePath: f.gameDir.appending(path: "Game.exe"), bottleID: strangerID,
                        detection: godot)
    try? e.store.mutate { s in
        s.games.append(stranger)
        s.bottles.append(Bottle(id: strangerID, prefixPath: Fixture.dir("setupfile-stranger"),
                                runtimeID: f.runtime.id, backend: .wined3d))
    }
    t.throwsError("a setup made for another engine is refused unless asked for") {
        _ = try e.applySetupFile(file, to: stranger)
    }

    var future = file
    future.formatVersion = 99
    let futureURL = out.appending(path: "future.\(Export.setupExtension)")
    try? JSONEncoder().encode(future).write(to: futureURL)
    t.throwsError("a file from a newer Decanter says so rather than half-applying") {
        _ = try Engine.readSetupFile(at: futureURL)
    }
}

func runBundlePlanTests(_ t: Harness) {
    t.suite("Before a bundle is built, Decanter says what cannot travel")
    guard let g = makeExportFixture("plan-gptk", kind: .gptk, backends: [.d3dmetal, .dxvk, .wined3d]) else {
        t.expect(false, "a fixture library can be made"); return
    }
    let plan = try? g.e.planBundle(for: g.game)
    t.equal(plan?.needsGPTK, true, "a game on the Game Porting Toolkit is flagged")
    t.expect(plan?.wineAlternative == nil, "with nothing seen working on Wine, no switch is offered")
    t.equal(plan?.sizes.runtime, 0, "neither GPTK nor its environment is counted as going in")
    t.equal(plan?.sizes.prefix, 0, "…including the environment it built")

    // Another game of the same kind, seen working on Wine with Vulkan graphics.
    let e = g.e
    let wineRoot = e.paths.runtimes.appending(path: "wine-other")
    try? FileManager.default.createDirectory(at: wineRoot, withIntermediateDirectories: true)
    let wine = RuntimeSpec(id: "wine-other", kind: .wine, version: "11.0", root: wineRoot,
                           winePath: wineRoot.appending(path: "bin/wine"), supports32Bit: true,
                           backends: [.dxvk, .wined3d])
    let seenID = UUID()
    let seen = Game(name: "Seen", exePath: g.gameDir.appending(path: "Game.exe"), bottleID: seenID,
                    detection: g.game.detection)
    try? e.store.mutate { s in
        s.runtimes.append(wine)
        s.games.append(seen)
        s.bottles.append(Bottle(id: seenID, prefixPath: Fixture.dir("plan-seen"), runtimeID: wine.id, backend: .dxvk))
    }
    try? e.rememberWorking(seen)
    t.equal((try? e.planBundle(for: g.game))?.wineAlternative?.backend, .dxvk,
            "a Wine setup seen working for this kind of game is offered as the way to make it self-contained")

    guard let w = makeExportFixture("plan-borrowed") else { t.expect(false, "a second fixture"); return }
    var m = RuntimeRepair.Manifest()
    m.borrows = [.init(library: "libfoo.dylib", donorID: "gptk-7.7", source: URL(filePath: "/nowhere/libfoo.dylib"),
                       destination: w.runtime.root.appending(path: "lib/libfoo.dylib"),
                       architectures: ["x86_64"], neededBy: [])]
    try? JSONEncoder().encode(m).write(to: RuntimeRepair.manifestPath(in: w.runtime.root))
    let borrowed = try? w.e.planBundle(for: w.game)
    t.equal(borrowed?.borrowedLibraries, ["libfoo.dylib"],
            "libraries a repair copied in from GPTK are named before anything is built")
    t.equal(borrowed?.needsGPTK, false, "on a build that is otherwise Wine's own")
    t.expect(borrowed?.disclaimer.contains("right to share") == true,
             "and the plan carries the disclaimer, so it is read before a bundle exists")
}

func runBundleBuildTests(_ t: Harness) {
    t.suite("A bundle is built, sealed, and opens into a folder of its own")
    let fm = FileManager.default
    guard let f = makeExportFixture("bundle") else { t.expect(false, "a fixture library can be made"); return }
    var m = RuntimeRepair.Manifest()
    m.borrows = [.init(library: "libfoo.dylib", donorID: "gptk-7.7", source: URL(filePath: "/nowhere/libfoo.dylib"),
                       destination: f.runtime.root.appending(path: "lib/libfoo.dylib"),
                       architectures: ["x86_64"], neededBy: [])]
    try? JSONEncoder().encode(m).write(to: RuntimeRepair.manifestPath(in: f.runtime.root))

    let out = Fixture.dir("bundle-out")
    let launcher = Fixture.dir("bundle-launcher").appending(path: "Launch")
    try? fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: launcher)
    guard let plan = try? f.e.planBundle(for: f.game) else { t.expect(false, "a plan can be made"); return }

    t.throwsError("borrowed libraries are not dropped without a yes") {
        _ = try f.e.buildBundle(plan, options: BundleOptions(), into: out, launcher: launcher)
    }
    t.expect(((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).isEmpty,
             "and a refused build leaves nothing behind")

    guard let app = try? f.e.buildBundle(plan, options: BundleOptions(shipWithoutBorrowedLibraries: true),
                                         into: out, launcher: launcher) else {
        t.expect(false, "a bundle can be built"); return
    }
    let res = app.appending(path: "Contents/Resources")
    t.expect(app.lastPathComponent == "Secret Fixture Title.app", "it is named for the game it holds")
    t.expect(fm.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/\(Export.launcherName)").path),
             "it has a launcher")
    let manifest = (try? Data(contentsOf: res.appending(path: Export.manifestName)))
        .flatMap { try? JSONDecoder.iso.decode(BundleManifest.self, from: $0) }
    t.equal(manifest?.gameName, f.game.name, "its manifest says what it holds")
    t.equal(manifest?.omittedLibraries, ["libfoo.dylib"], "including what was left out")
    t.expect(!fm.fileExists(atPath: res.appending(path: "runtime/lib/libfoo.dylib").path),
             "and the borrowed library really is not in it")
    t.expect(fm.fileExists(atPath: res.appending(path: "game/Some Game/Game.exe").path), "the game is in it")
    let pfx = res.appending(path: "prefix")
    t.expect((try? fm.destinationOfSymbolicLink(atPath: pfx.appending(path: "dosdevices/c:").path)) == "../drive_c",
             "the environment keeps its own drive")
    t.expect((try? fm.destinationOfSymbolicLink(atPath: pfx.appending(path: "dosdevices/h:").path)) == nil,
             "but not a link to a folder on this Mac")
    t.expect(!fm.fileExists(atPath: pfx.appending(path: "drive_c/users/tester/AppData/LocalLow/Vendor/Product/save.dat").path),
             "and saves are left out unless asked for")
    let verify = try? Shell.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path], timeout: 120)
    t.equal(verify?.code, 0, "its signature verifies")

    t.suite("Opening a bundle leaves the bundle as it was signed")
    let home = Fixture.dir("bundle-home")
    guard let runner = BundleRunner.current(executable: app.appending(path: "Contents/MacOS/\(Export.launcherName)"),
                                            home: home) else {
        t.expect(false, "the launcher recognises the bundle it is in"); return
    }
    t.expect(BundleRunner.current(executable: URL(filePath: "/usr/local/bin/decanter")) == nil,
             "and an ordinary install is not mistaken for one")
    guard case .ready(let e2, let g2)? = try? runner.prepare() else {
        t.expect(false, "a bundle carrying its Wine prepares without asking for anything"); return
    }
    t.expect(g2.exePath.pathKey.hasPrefix(home.pathKey), "the game runs from a copy outside the bundle")
    t.expect(e2.store.state.runtimes.first?.root.pathKey.hasPrefix(home.pathKey) == true, "so does its Wine")
    t.expect(e2.store.bottle(g2.bottleID)?.prefixPath.pathKey.hasPrefix(home.pathKey) == true,
             "and its Windows environment")
    t.equal(g2.dllOverrides, f.game.dllOverrides, "with the setup it was bundled on")
    let again = try? Shell.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path], timeout: 120)
    t.equal(again?.code, 0, "and the bundle still verifies, because nothing was written inside it")

    if let pfx2 = e2.store.bottle(g2.bottleID)?.prefixPath {
        let marker = pfx2.appending(path: "drive_c/played.txt")
        try? Data("played".utf8).write(to: marker)
        guard case .ready(_, let g3)? = try? runner.prepare() else { t.expect(false, "it opens a second time"); return }
        t.equal(g3.id, g2.id, "opening it again uses the same copy")
        t.expect(fm.fileExists(atPath: marker.path), "and never overwrites what was played there")
    }

    t.suite("A GPTK bundle is only built on purpose")
    guard let gp = makeExportFixture("bundle-gptk", kind: .gptk, backends: [.d3dmetal, .wined3d]),
          let gplan = try? gp.e.planBundle(for: gp.game) else { t.expect(false, "a GPTK fixture"); return }
    let gout = Fixture.dir("bundle-gptk-out")
    t.throwsError("a GPTK game is not bundled without choosing to") {
        _ = try gp.e.buildBundle(gplan, options: BundleOptions(), into: gout, launcher: launcher)
    }
    guard let gapp = try? gp.e.buildBundle(gplan, options: BundleOptions(bringYourOwnGPTK: true), into: gout,
                                           launcher: launcher) else {
        t.expect(false, "chosen, it builds"); return
    }
    let gres = gapp.appending(path: "Contents/Resources")
    t.expect(!fm.fileExists(atPath: gres.appending(path: "runtime").path), "with no GPTK in it")
    t.expect(!fm.fileExists(atPath: gres.appending(path: "prefix").path), "and no environment GPTK built")
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// A bundle that needs GPTK on a Mac without one asks for it, in words that
/// say how to hand it over.
func runBundleGPTKTests(_ t: Harness) {
    t.suite("A bring-your-own-GPTK bundle asks for the toolkit it cannot carry")
    let fm = FileManager.default
    guard let gp = makeExportFixture("gptk-ask", kind: .gptk, backends: [.d3dmetal, .wined3d]),
          let plan = try? gp.e.planBundle(for: gp.game) else { t.expect(false, "a GPTK fixture"); return }
    let out = Fixture.dir("gptk-ask-out")
    let launcher = Fixture.dir("gptk-ask-launcher").appending(path: "Launch")
    try? fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: launcher)
    guard let app = try? gp.e.buildBundle(plan, options: BundleOptions(bringYourOwnGPTK: true),
                                          into: out, launcher: launcher),
          let runner = BundleRunner.current(executable: app.appending(path: "Contents/MacOS/\(Export.launcherName)"),
                                            home: Fixture.dir("gptk-ask-home")) else {
        t.expect(false, "the bundle builds and its launcher recognises it"); return
    }
    if RuntimeManager(paths: Paths(root: runner.home)).discover().contains(where: { $0.kind == .gptk }) {
        t.skip("asking for GPTK", "this Mac has the Game Porting Toolkit in Applications, so the bundle takes that instead")
        return
    }
    guard case .needsGPTK(let why)? = try? runner.prepare() else {
        t.expect(false, "with no toolkit anywhere, the bundle stops and asks"); return
    }
    t.expect(why.contains("disk image"), "saying the toolkit can be handed over as its disk image")
    t.expect(why.contains("Nothing is downloaded"), "and that nothing is fetched to get it")
    t.throwsError("something that is not the toolkit is refused rather than pinned in its place") {
        _ = try runner.acceptGPTK(from: Fixture.dir("gptk-ask-not-a-toolkit"))
    }
}

/// Decanter.app carries the command line in Contents/Helpers, and an app is
/// only ever built around that copy.
func runBundleLauncherTests(_ t: Harness) {
    t.suite("export: the launcher an app is built around")
    let fm = FileManager.default
    let root = Fixture.dir("export-launcher")
    func tool(_ url: URL, mode: Int = 0o755) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: url)
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    let app = root.appending(path: "Decanter.app/Contents/MacOS/Decanter")
    tool(app)
    t.expect(Export.launcher(nextTo: app) == nil,
             "an app without the helper has no launcher — its own binary, which a case-insensitive disk also calls decanter, is never taken for one")

    let helper = root.appending(path: "Decanter.app/Contents/Helpers/decanter")
    tool(helper)
    t.equal(Export.launcher(nextTo: app)?.pathKey, helper.pathKey, "the app's launcher is the helper inside it")

    tool(helper, mode: 0o644)
    t.expect(Export.launcher(nextTo: app) == nil, "a helper that cannot be run is not a launcher")

    let build = root.appending(path: "build/debug")
    tool(build.appending(path: "DecanterApp"))
    tool(build.appending(path: "decanter"))
    t.equal(Export.launcher(nextTo: build.appending(path: "DecanterApp"))?.pathKey,
            build.appending(path: "decanter").pathKey, "outside an app, the decanter beside the running program")
    t.equal(Export.launcher(nextTo: build.appending(path: "decanter"))?.pathKey,
            build.appending(path: "decanter").pathKey, "the command line is its own launcher")
}
