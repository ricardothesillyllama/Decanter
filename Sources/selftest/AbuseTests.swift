import Foundation
import DecanterKit

/// Deliberately hostile inputs. Every one of these is a thing that either
/// happens by accident (deleted folders, weird filenames, interrupted writes)
/// or is how a malicious game folder would try to escape its sandbox.
func runAbuseTests(_ t: Harness) {
    let fm = FileManager.default

    // A private, disposable Decanter root so nothing here touches real state.
    func freshEngine(_ tag: String) -> Engine {
        let root = Fixture.dir("root-\(tag)")
        return try! Engine(paths: Paths(root: root))
    }

    // A knowledge export is the one file Decanter is asked to read from a
    // stranger. It has to refuse the bad shapes by name, because the cost of
    // accepting one is a recommendation handed to somebody else's game.
    t.suite("An export from elsewhere is treated as data, not as truth")
    do {
        let e = freshEngine("kb-import")
        let dir = Fixture.dir("kb-files")
        func file(_ name: String, _ body: String) -> URL {
            let u = dir.appending(path: name)
            try? body.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        t.throwsError("a file that is not JSON at all is refused") {
            _ = try e.importKnowledge(from: file("junk.json", "not json"))
        }
        t.throwsError("a JSON file that is not an export is refused") {
            _ = try e.importKnowledge(from: file("other.json", "{\"hello\":1}"))
        }
        t.throwsError("a format from a newer Decanter is refused rather than guessed at") {
            _ = try e.importKnowledge(from: file("future.json",
                "{\"formatVersion\":9,\"observations\":[]}"))
        }
        t.throwsError("a path that is not there is refused") {
            _ = try e.importKnowledge(from: dir.appending(path: "absent.json"))
        }
        // A well-formed one still has to work, or the tests above pass for the
        // wrong reason.
        let good = file("good.json", """
        {"formatVersion":1,"observations":[
          {"signature":{"engine":"unreal","engineMajor":5,"bitness":"x64",
                        "usesVideo":false,"usesD3D12":true,"chip":"m3","macOSMajor":26},
           "setup":{"runtimeKind":"gptk","backend":"d3dmetal"},
           "worked":true,"note":"a title that must not survive"}]}
        """)
        t.survives("a well-formed export is taken") {
            let r = try e.importKnowledge(from: good)
            guard r.added == 1 else {
                throw DecanterError.badFile("expected 1 observation, took \(r.added)")
            }
        }
        let stored = (try? String(contentsOf: e.paths.knowledgePath, encoding: .utf8)) ?? ""
        t.expect(!stored.contains("must not survive"),
                 "and the stranger's note is not written to disk")
    }

    // Exit codes are interface: docs/CLI.md tells people to branch on them.
    t.suite("A failure exits with the code for its kind")
    do {
        t.equal(DecanterError.usage("x").exitCode, 2, "a misused command exits 2")
        t.equal(DecanterError.notFound("x").exitCode, 3, "something not found exits 3")
        t.equal(DecanterError.badFile("x").exitCode, 3, "…as does a file that cannot be used")
        t.equal(DecanterError.notAnExecutable(URL(filePath: "/x")).exitCode, 3,
                "…and something that is not a Windows program")
        t.equal(DecanterError.templateMissing.exitCode, 4, "an unbuilt template exits 4")
        t.equal(DecanterError.noRuntime("x").exitCode, 4, "…as does having no runtime")
        t.equal(DecanterError.runtimeLacks32Bit("x").exitCode, 4,
                "…and a runtime that cannot run the game")
        t.equal(DecanterError.outOfSpace("x").exitCode, 5, "a full disk exits 5")
        t.equal(DecanterError.pathEscapesScope(URL(filePath: "/x")).exitCode, 6,
                "a path outside a game's scope exits 6, and never 0")
        t.equal(DecanterError.launchFailed("x").exitCode, 1, "anything else exits 1")

        // Nothing may exit 0, or a script reads a failure as success.
        let every: [DecanterError] = [
            .noRuntime("x"), .templateMissing, .noTemplate("x"), .notAnExecutable(URL(filePath: "/x")),
            .pathEscapesScope(URL(filePath: "/x")), .runtimeLacks32Bit("x"), .cloneFailed("x"),
            .launchFailed("x"), .notFound("x"), .badFile("x"), .usage("x"), .outOfSpace("x")]
        t.expect(every.allSatisfy { $0.exitCode != 0 }, "no failure exits 0")
        t.expect(every.allSatisfy { ($0.errorDescription ?? "").isEmpty == false },
                 "and every one of them says something")
    }

    t.suite("Room is measured before a runtime is unpacked, not during")
    do {
        let dir = Fixture.dir("space")
        t.survives("a requirement that fits is not refused") {
            try DiskSpace.require(1, at: dir, toDo: "A tiny thing")
        }
        // The destination usually does not exist yet — that is the point of
        // asking — so capacity is read from the nearest ancestor that does.
        let unborn = dir.appending(path: "not/created/yet/runtime")
        // Compared with slack, not for equality: the two readings are taken a
        // moment apart and the disk is in use, so exact equality is a test that
        // fails on a busy machine and passes on an idle one.
        let onVolume = DiskSpace.available(at: unborn) ?? -1
        let atParent = DiskSpace.available(at: dir) ?? -2
        t.expect(onVolume > 0 && abs(onVolume - atParent) < 1_000_000_000,
                 "a path that does not exist yet is measured on the volume that will hold it")
        t.expect(DiskSpace.available(at: URL(filePath: "/nonexistent-volume-xyz")) != nil,
                 "…walking up as far as the root rather than giving up")
        t.throwsError("more space than the disk has is refused up front") {
            try DiskSpace.require(Int64.max / 2, at: dir, toDo: "Unpacking a Wine build")
        }
        do {
            try DiskSpace.require(Int64.max / 2, at: dir, toDo: "Unpacking a Wine build")
            t.expect(false, "the refusal says what it was trying to do")
        } catch {
            let m = (error as? DecanterError)?.errorDescription ?? ""
            t.expect(m.contains("Unpacking a Wine build"), "the refusal says what it was trying to do")
            t.expect(m.contains("free") && m.contains("has"),
                     "…and both how much was needed and how much there is")
            t.equal((error as? DecanterError)?.exitCode, 5, "…and it is the out-of-space code")
        }
        // The estimate has to exceed the archive, or it measures nothing.
        t.expect(DiskSpace.unpackEstimate(forArchiveOf: 100) > 100,
                 "an unpack is budgeted for more than the archive it comes from")
        t.equal(DiskSpace.label(2_000_000_000), "2 GB", "sizes read in whole units")
        t.equal(DiskSpace.label(300_000_000), "300 MB", "…down to megabytes")
        t.expect((DiskSpace.available(at: dir) ?? 0) > 0, "a real directory reports real capacity")
    }

    t.suite("Corrupt and hostile state")
    do {
        let root = Fixture.dir("corrupt")
        let paths = Paths(root: root)
        try? paths.ensure()
        try? Data("{ this is not json at all ][".utf8).write(to: paths.statePath)
        t.survives("a corrupt state.json does not prevent startup") {
            let e = try Engine(paths: paths)
            t.equal(e.store.state.games.count, 0, "...and it starts from an empty library")
        }

        // Truncated / half-written JSON, as an interrupted write would leave.
        let root2 = Fixture.dir("truncated")
        let p2 = Paths(root: root2); try? p2.ensure()
        try? Data(#"{"games":[{"id":"#.utf8).write(to: p2.statePath)
        t.survives("a truncated state.json does not prevent startup") { _ = try Engine(paths: p2) }

        // A state file that is a directory, not a file.
        let root3 = Fixture.dir("dirstate")
        let p3 = Paths(root: root3); try? p3.ensure()
        try? fm.removeItem(at: p3.statePath)
        try? fm.createDirectory(at: p3.statePath, withIntermediateDirectories: true)
        t.survives("a state path that is a directory does not crash startup") { _ = try Engine(paths: p3) }
    }

    t.suite("Hostile game paths")
    do {
        let e = freshEngine("paths")
        t.throwsError("adding a path that does not exist") {
            _ = try e.add(path: URL(filePath: "/nope/does/not/exist"))
        }
        t.throwsError("adding a folder containing no executable") {
            _ = try e.add(path: Fixture.dir("empty-add"))
        }
        let d = Fixture.dir("nonpe")
        Fixture.write(d, "fake.exe", Data("I am not a PE file".utf8))
        t.survives("adding a non-PE file named .exe is handled") {
            _ = try? e.add(path: d.appending(path: "fake.exe"))
        }
        t.throwsError("adding a file that is not an .exe at all") {
            _ = try e.add(path: Fixture.write(Fixture.dir("txt"), "readme.txt", Data("hi".utf8)))
        }

        // Names that would be dangerous if interpolated into paths or shell.
        for hostile in ["../../../etc/passwd", "a/b/c", "name with \"quotes\"",
                        "$(rm -rf ~)", "; rm -rf /", "\u{202E}gnp.exe",
                        String(repeating: "L", count: 400), "測試 🎮"] {
            let g = Fixture.unity(name: "X")
            t.survives("game name is handled safely: \(hostile.prefix(28))") {
                _ = try? e.add(path: g.appending(path: "X.exe"), name: hostile)
            }
        }
        // Nothing should have escaped the sandbox root.
        t.expect(!fm.fileExists(atPath: "/etc/passwd.decanter-test"),
                 "no write escaped to an absolute path")
        let bottleDirs = (try? fm.contentsOfDirectory(atPath: e.paths.bottles.path)) ?? []
        t.expect(bottleDirs.allSatisfy { !$0.contains("..") && !$0.contains("/") },
                 "every bottle directory name is a plain UUID")
    }

    t.suite("Save import cannot escape the prefix")
    do {
        _ = freshEngine("import")
        // Build a bottle by hand so no runtime is needed.
        let prefix = Fixture.dir("prefix")
        try? fm.createDirectory(at: prefix.appending(path: "drive_c/users/testuser"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefix.appending(path: "drive_c/windows/temp"), withIntermediateDirectories: true)
        let bottle = Bottle(prefixPath: prefix, runtimeID: "fake", backend: .dxvk)
        let rt = RuntimeSpec(id: "fake", kind: .wine, version: "0",
                             root: Fixture.dir("rt"), winePath: URL(filePath: "/usr/bin/true"),
                             supports32Bit: true, backends: [.dxvk])

        // A source tree containing a symlink that points outside the prefix.
        let src = Fixture.dir("saves")
        let escapeTarget = Fixture.dir("outside")
        Fixture.write(escapeTarget, "secret.txt", Data("do not touch".utf8))
        try? fm.createDirectory(at: src.appending(path: "drive_c/users/crossover/AppData"),
                                withIntermediateDirectories: true)
        Fixture.write(src, "drive_c/users/crossover/AppData/save.json", Data(#"{"level":1}"#.utf8))
        try? fm.createSymbolicLink(atPath: src.appending(path: "drive_c/users/crossover/link").path,
                                   withDestinationPath: escapeTarget.path)

        var report: SaveImporter.Report? = nil
        t.survives("importing a tree containing a symlink is handled") {
            report = try SaveImporter().importSaves(from: src, into: bottle, runtime: rt)
        }
        t.expect((report?.filesCopied ?? 0) >= 1, "the real save file was copied")
        t.expect(report?.remappedUsers.contains("crossover") ?? false,
                 "the foreign Windows user was remapped")
        t.expect(fm.fileExists(atPath: prefix.appending(path: "drive_c/users/testuser/AppData/save.json").path),
                 "the save landed under this prefix's user, not the foreign one")
        // The escape target must be untouched and not reachable from the prefix.
        let leaked = prefix.appending(path: "drive_c/users/testuser/link")
        let leakedIsSymlink = (try? fm.destinationOfSymbolicLink(atPath: leaked.path)) != nil
        t.expect(!leakedIsSymlink, "a symlink in the source is not reproduced inside the prefix")
        t.expect(fm.fileExists(atPath: escapeTarget.appending(path: "secret.txt").path),
                 "the symlink target outside the prefix is untouched")

        // A .reg file that is malformed, empty, or enormous.
        for (name, data) in [("empty.reg", Data()),
                             ("garbage.reg", Data((0..<4096).map { _ in UInt8.random(in: 0...255) })),
                             ("huge.reg", Data(String(repeating: "[Software\\\\A] 1\n", count: 20_000).utf8))] {
            let s2 = Fixture.dir("reg")
            Fixture.write(s2, name, data)
            t.survives("a \(name) is handled without crashing") {
                _ = try SaveImporter().importSaves(from: s2, into: bottle, runtime: rt)
            }
        }
        t.survives("importing from a directory that does not exist is handled") {
            _ = try SaveImporter().importSaves(from: URL(filePath: "/nope/nothing"), into: bottle, runtime: rt)
        }
    }

    t.suite("Missing pieces on disk")
    do {
        let e = freshEngine("missing")
        t.throwsError("deriving with no golden template") {
            let rt = RuntimeSpec(id: "x", kind: .wine, version: "1", root: Fixture.dir("r"),
                                 winePath: URL(filePath: "/usr/bin/true"),
                                 supports32Bit: true, backends: [.dxvk])
            _ = try e.prefixes.derive(bottleID: UUID(), runtime: rt, backend: .dxvk)
        }
        t.throwsError("running a game whose bottle record is gone") {
            let g = Game(name: "ghost", exePath: URL(filePath: "/tmp/x.exe"),
                         bottleID: UUID(), detection: DetectionResult())
            _ = try e.run(g)
        }
        t.survives("gc with no bottles directory") { _ = try e.gc() }
        t.survives("doctor on a completely empty root") { _ = e.doctor() }
        t.survives("diagnosing a game that has never been launched") {
            _ = Diagnostics().analyse(logAt: e.paths.logs.appending(path: "nope.log"))
        }
    }

    t.suite("Descoping is thorough")
    do {
        let pb = PrefixBuilder(paths: Paths(root: Fixture.dir("descope")))
        let prefix = Fixture.dir("pfx")
        let dd = prefix.appending(path: "dosdevices")
        try? fm.createDirectory(at: dd, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: dd.appending(path: "z:").path, withDestinationPath: "/")
        try? fm.createSymbolicLink(atPath: dd.appending(path: "z::").path, withDestinationPath: "/dev/rdisk1")
        try? fm.createSymbolicLink(atPath: dd.appending(path: "c:").path, withDestinationPath: "../drive_c")
        // wineboot maps a letter at every mounted volume, and a raw device
        // node beside it. Stripping only z: left every one of these behind —
        // measured on a real install, not hypothetical.
        try? fm.createSymbolicLink(atPath: dd.appending(path: "d:").path, withDestinationPath: "/Volumes/Backup")
        try? fm.createSymbolicLink(atPath: dd.appending(path: "d::").path, withDestinationPath: "/dev/rdisk8s1")
        try? fm.createSymbolicLink(atPath: dd.appending(path: "e:").path, withDestinationPath: "/Volumes/Photos")
        t.survives("descope removes the whole-filesystem mapping") { try pb.descope(prefix: prefix) }
        t.expect((try? fm.destinationOfSymbolicLink(atPath: dd.appending(path: "z:").path)) == nil,
                 "z: is gone")
        t.expect((try? fm.destinationOfSymbolicLink(atPath: dd.appending(path: "z::").path)) == nil,
                 "the z:: device node is gone too")
        t.expect((try? fm.destinationOfSymbolicLink(atPath: dd.appending(path: "c:").path)) != nil,
                 "c: is left intact")
        for gone in ["d:", "d::", "e:"] {
            t.expect((try? fm.destinationOfSymbolicLink(atPath: dd.appending(path: gone).path)) == nil,
                     "\(gone) — a mounted volume Decanter never granted — is gone")
        }

        // Re-applying scopes must not resurrect z:.
        t.survives("applying scopes re-descopes first") {
            try pb.applyScopes(prefix: prefix, scopes: [ScopeGrant(letter: "h", hostPath: Fixture.dir("g"))])
        }
        t.expect((try? fm.destinationOfSymbolicLink(atPath: dd.appending(path: "z:").path)) == nil,
                 "z: stays gone after applying scopes")
        t.expect((try? fm.destinationOfSymbolicLink(atPath: dd.appending(path: "h:").path)) != nil,
                 "a granted scope survives the descope that runs before it")

        // A stray drive is not merely removed, it is reported — the promise is
        // only worth leading with if the user can be told when it was kept.
        try? fm.createSymbolicLink(atPath: dd.appending(path: "f:").path, withDestinationPath: "/Volumes/Late")
        let closed = (try? pb.descope(prefix: prefix)) ?? []
        t.expect(closed.contains { $0.hasPrefix("f:") },
                 "descope reports what it closed rather than doing it silently")
        t.expect(((try? pb.descope(prefix: prefix)) ?? ["x"]).isEmpty,
                 "a prefix with nothing stray to close reports nothing")
    }

    t.suite("A guess does not wear a measurement's badge")
    do {
        // The field defaulted to "high", so a recommendation with nothing
        // observed behind it claimed as much certainty as one confirmed twice
        // on this very Mac. Only the knowledge-base path may raise it.
        let fresh = Engine.Recommendation(runtimeKind: .wine, backend: .wined3d)
        t.expect(fresh.confidence != "high",
                 "a recommendation with no evidence behind it does not claim high confidence")
        t.expect(!fresh.overriddenByUser,
                 "and it does not claim the user chose it")
    }

    t.suite("A font warning is not an architecture refusal")
    do {
        let d = Diagnostics()
        let freetype = """
        Wine cannot find the FreeType font library.  To enable Wine to
        use TrueType fonts please install a version of FreeType greater than
        or equal to 2.0.5.
        """
        let f = d.analyse(text: freetype).findings
        t.expect(f.contains(.fontLibraryMissing), "a missing font library is named as one")
        t.expect(!f.contains(.bitnessRefused),
                 "a 64-bit game is no longer sent looking for 32-bit support over a font")
        t.expect(d.analyse(text: "Bad EXE format for foo.exe").findings.contains(.bitnessRefused),
                 "a real architecture refusal is still caught")
    }

    t.suite("Diagnostics under load")
    do {
        let d = Diagnostics()
        let huge = Array(repeating: "fixme:d3d:wined3d_something noisy line here", count: 200_000).joined(separator: "\n")
        let started = Date()
        let rep = d.analyse(text: huge)
        t.expect(Date().timeIntervalSince(started) < 20, "a 200k-line log is analysed in reasonable time")
        t.expect(rep.tail.count <= 25, "only the tail is retained")
        t.survives("analysing binary garbage") {
            _ = d.analyse(text: String(decoding: (0..<8192).map { _ in UInt8.random(in: 1...255) }, as: UTF8.self))
        }
    }
}

/// Targeted at weaknesses suspected from reading the code, rather than
/// generic fuzzing. These are the ones expected to actually fail.
func runStressTests(_ t: Harness) {
    let fm = FileManager.default

    t.suite("Name resolution ambiguity")
    do {
        let root = Fixture.dir("names")
        let e = try! Engine(paths: Paths(root: root))
        try! e.store.mutate { s in
            s.games = [
                Game(name: "A",         exePath: URL(filePath: "/tmp/a.exe"), bottleID: UUID(), detection: DetectionResult()),
                Game(name: "Anthology", exePath: URL(filePath: "/tmp/b.exe"), bottleID: UUID(), detection: DetectionResult()),
                Game(name: "alpha",     exePath: URL(filePath: "/tmp/c.exe"), bottleID: UUID(), detection: DetectionResult()),
                Game(name: "Alpha",     exePath: URL(filePath: "/tmp/d.exe"), bottleID: UUID(), detection: DetectionResult()),
            ]
        }
        t.equal(e.store.game(named: "A")?.name, "A", "an exact name wins over a substring match")
        t.equal(e.store.game(named: "Anthology")?.name, "Anthology", "a full name resolves")
        // Two games differing only by case: the lookup is case-insensitive but
        // the de-duplication on add is case-sensitive, so both can exist.
        let alphaCount = e.store.state.games.filter { $0.name.lowercased() == "alpha" }.count
        t.equal(alphaCount, 2, "two games differing only in case can coexist (documented hazard)")
        t.expect(e.store.game(named: "alpha") != nil, "...and the lookup silently picks one of them")
        // An empty query must not match an arbitrary game.
        t.expect(e.store.game(named: "") == nil, "an empty name does not match a random game")
    }

    t.suite("Concurrent writers")
    do {
        // The GUI polls and writes while the CLI is used: a classic lost update.
        let root = Fixture.dir("concurrent")
        let a = try! Engine(paths: Paths(root: root))
        let b = try! Engine(paths: Paths(root: root))
        try! a.store.mutate { s in
            s.games.append(Game(name: "FromA", exePath: URL(filePath: "/tmp/a.exe"),
                                bottleID: UUID(), detection: DetectionResult()))
        }
        try! b.store.mutate { s in
            s.games.append(Game(name: "FromB", exePath: URL(filePath: "/tmp/b.exe"),
                                bottleID: UUID(), detection: DetectionResult()))
        }
        let fresh = try! Engine(paths: Paths(root: root))
        let names = Set(fresh.store.state.games.map(\.name))
        t.expect(names.contains("FromA") && names.contains("FromB"),
                 "two writers both survive (no lost update)")
    }

    t.suite("Large binaries")
    do {
        // Unity's GameAssembly.dll is routinely hundreds of megabytes.
        let d = Fixture.dir("big")
        let exe = d.appending(path: "Big.exe")
        var header = Fixture.pe(machine: 0x8664, strings: ["d3d11.dll"], padTo: 4096)
        header.append(Data(count: 220_000_000))          // ~220 MB
        try? header.write(to: exe)
        Fixture.write(d, "Big_Data/app.info")

        let started = Date()
        let r = Detector().detect(exe: exe)
        let elapsed = Date().timeIntervalSince(started)
        t.equal(r.bitness, .x64, "a 220MB executable still parses")
        t.expect(elapsed < 5.0, "detecting a 220MB executable takes under 5s (took \(String(format: "%.2f", elapsed))s)")
        try? fm.removeItem(at: d)
    }
}

/// Covers everything added for removal, saves and per-runtime templates.
func runSavesTests(_ t: Harness) {
    let fm = FileManager.default

    t.suite("State decoding never loses the library")
    do {
        // The bug: adding a non-optional field with a default made Swift's
        // synthesised Decodable reject every existing state.json, and the
        // silent fallback to an empty state would be written back over the
        // user's whole library on the next save.
        let root = Fixture.dir("schema")
        let paths = Paths(root: root); try? paths.ensure()
        let older = """
        {"games":[],"bottles":[],"runtimes":[{"id":"wine-1","kind":"wine","version":"1",
        "root":"file:///tmp/r","winePath":"file:///tmp/r/bin/wine","supports32Bit":true,
        "backends":["dxvk"],"pinnedAt":768000000}]}
        """
        try? Data(older.utf8).write(to: paths.statePath)
        let e = try! Engine(paths: paths)
        t.equal(e.store.state.runtimes.count, 1,
                "a state.json written before new fields existed still decodes")
        t.expect(e.store.loadError == nil, "and it is not reported as unreadable")

        // A genuinely unreadable file must be preserved, not silently replaced.
        let root2 = Fixture.dir("unreadable")
        let p2 = Paths(root: root2); try? p2.ensure()
        try? Data("{ not json".utf8).write(to: p2.statePath)
        let e2 = try! Engine(paths: p2)
        t.expect(e2.store.loadError != nil, "an unreadable state file is reported, not swallowed")
        let backups = ((try? fm.contentsOfDirectory(atPath: root2.path)) ?? [])
            .filter { $0.hasPrefix("state.unreadable-") }
        t.expect(!backups.isEmpty, "…and a copy of it is kept")
    }

    t.suite("Removal")
    do {
        let root = Fixture.dir("removal")
        let e = try! Engine(paths: Paths(root: root))
        let gameDir = Fixture.unity(name: "Doomed")
        let bottleDir = Fixture.dir("doomed-prefix")
        Fixture.write(bottleDir, "drive_c/marker.txt", Data("x".utf8))
        let b = Bottle(prefixPath: bottleDir, runtimeID: "r", backend: .dxvk)
        let g = Game(name: "Doomed", exePath: gameDir.appending(path: "Doomed.exe"),
                     bottleID: b.id, detection: DetectionResult())
        try! e.store.mutate { s in s.bottles = [b]; s.games = [g] }

        let rep = try! e.remove(g, keepSaves: false)
        t.equal(rep.game, "Doomed", "reports what it removed")
        t.expect(!fm.fileExists(atPath: bottleDir.path), "the prefix is deleted")
        t.expect(e.store.state.games.isEmpty, "the game record is forgotten")
        t.expect(e.store.state.bottles.isEmpty, "the bottle record is forgotten")
        t.expect(fm.fileExists(atPath: gameDir.appending(path: "Doomed.exe").path),
                 "the user's actual game files are NOT touched")
    }

    t.suite("Save discovery by template diff")
    do {
        let root = Fixture.dir("discovery")
        let paths = Paths(root: root); try? paths.ensure()
        // A template with Wine-ish content, and a prefix that adds game files.
        let tpl = paths.template
        try? fm.createDirectory(at: tpl, withIntermediateDirectories: true)
        Fixture.write(tpl, "drive_c/users/testuser/AppData/LocalLow/.keep")
        Fixture.write(tpl, "drive_c/users/testuser/AppData/Local/Temp/wine.tmp", Data("junk".utf8))
        try? "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n".write(
            to: tpl.appending(path: "user.reg"), atomically: true, encoding: .utf8)

        let prefix = Fixture.dir("disc-prefix")
        Fixture.write(prefix, "drive_c/users/testuser/AppData/LocalLow/.keep")
        Fixture.write(prefix, "drive_c/users/testuser/AppData/Local/Temp/wine.tmp", Data("junk".utf8))
        Fixture.write(prefix, "drive_c/users/testuser/AppData/LocalLow/Acme/Game/save1.json", Data("{}".utf8))
        Fixture.write(prefix, "drive_c/users/testuser/AppData/LocalLow/Acme/Game/Cache/huge.bin", Data(count: 5000))
        Fixture.write(prefix, "drive_c/ProgramData/Acme/profile.dat", Data("p".utf8))
        try? "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n\n[Software\\\\Acme\\\\Game] 2\n".write(
            to: prefix.appending(path: "user.reg"), atomically: true, encoding: .utf8)

        let store = SaveStore(paths: paths)
        let d = store.discover(in: prefix)
        let names = d.files.map { ($0.relPath as NSString).lastPathComponent }
        t.expect(names.contains("save1.json"), "finds a file the game created")
        t.expect(names.contains("profile.dat"), "finds ProgramData content too")
        t.expect(!names.contains("wine.tmp"), "ignores files that came from the template")
        t.expect(!names.contains("huge.bin"), "ignores cache directories")
        t.equal(d.registryKeys.count, 1, "finds exactly the game's registry key")
        t.expect(d.registryKeys.first?.contains("Acme") ?? false, "…and it is the right one")

        let roots = store.saveRoots(in: prefix)
        t.expect(roots.contains { $0.hasSuffix("LocalLow/Acme") },
                 "externalisation targets the game-created directory, not AppData itself")
        t.expect(!roots.contains { $0.hasSuffix("AppData") || $0.hasSuffix("LocalLow") },
                 "…and never a directory the template also has")
    }

    t.suite("Externalise, rebuild, survive")
    do {
        let root = Fixture.dir("ext")
        let paths = Paths(root: root); try? paths.ensure()
        let tpl = paths.template
        try? fm.createDirectory(at: tpl, withIntermediateDirectories: true)
        Fixture.write(tpl, "drive_c/users/testuser/AppData/LocalLow/.keep")

        let prefix = Fixture.dir("ext-prefix")
        Fixture.write(prefix, "drive_c/users/testuser/AppData/LocalLow/.keep")
        Fixture.write(prefix, "drive_c/users/testuser/AppData/LocalLow/Acme/save.json", Data("progress".utf8))

        let store = SaveStore(paths: paths)
        let g = Game(name: "Ext", exePath: URL(filePath: "/tmp/e.exe"),
                     bottleID: UUID(), detection: DetectionResult())
        let r = try! store.externalise(game: g, prefix: prefix)
        t.expect(r.moved.contains { $0.hasSuffix("LocalLow/Acme") }, "the save directory was moved out")
        let link = prefix.appending(path: "drive_c/users/testuser/AppData/LocalLow/Acme")
        t.expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
                 "a symlink now stands in its place")
        // The store is deliberately Windows-user agnostic: Wine names the user
        // after the host, GPTK calls it "crossover", and a game must find its
        // saves under whichever name the current runtime uses.
        t.expect(fm.fileExists(atPath: store.liveRoot(g)
                    .appending(path: "drive_c/users/\(SaveStore.userPlaceholder)/AppData/LocalLow/Acme/save.json").path),
                 "the real file lives in the store under a user-agnostic path")

        // Simulate a re-derive: throw the prefix away, clone the template, relink.
        try? fm.removeItem(at: prefix)
        _ = try? Shell.run(URL(filePath: "/bin/cp"), ["-R", tpl.path, prefix.path], timeout: 60)
        let n = try! store.relink(game: g, prefix: prefix)
        t.expect(n >= 1, "relink re-attaches after a rebuild")
        let after = prefix.appending(path: "drive_c/users/testuser/AppData/LocalLow/Acme/save.json")
        t.expect(fm.fileExists(atPath: after.path),
                 "progress survives a prefix rebuild with no restore step")
        t.equal(try? String(contentsOf: after, encoding: .utf8), "progress",
                "…and the contents are intact")
    }

    t.suite("Snapshots")
    do {
        let root = Fixture.dir("snap")
        let paths = Paths(root: root); try? paths.ensure()
        try? fm.createDirectory(at: paths.template, withIntermediateDirectories: true)
        let prefix = Fixture.dir("snap-prefix")
        Fixture.write(prefix, "drive_c/users/r/AppData/LocalLow/Acme/save.json", Data("v1".utf8))
        let store = SaveStore(paths: paths)
        let g = Game(name: "Snap", exePath: URL(filePath: "/tmp/s.exe"),
                     bottleID: UUID(), detection: DetectionResult())

        let s1 = try! store.snapshot(game: g, prefix: prefix, note: "first")
        t.expect(s1.fileCount >= 1, "a snapshot captures the save file")
        // Change the save, then restore.
        Fixture.write(prefix, "drive_c/users/r/AppData/LocalLow/Acme/save.json", Data("v2-broken".utf8))
        _ = try! store.restore(s1, game: g, into: prefix, runtime: nil)
        let back = try? String(contentsOf: prefix.appending(path: "drive_c/users/r/AppData/LocalLow/Acme/save.json"),
                               encoding: .utf8)
        t.equal(back, "v1", "restoring a snapshot brings the old contents back")

        for _ in 0..<4 { _ = try? store.snapshot(game: g, prefix: prefix) }
        let pruned = try! store.prune(game: g, keep: 2)
        t.expect(pruned >= 1, "old snapshots are pruned")
        t.equal(store.snapshots(for: g).count, 2, "retention is honoured")
    }

    t.suite("Recipe presets")
    do {
        t.expect(RecipeRunner.expand(["fmv"]).contains("quartz"),
                 "the fmv preset expands to DirectShow")
        t.expect(RecipeRunner.expand(["fmv"]).contains("lavfilters702"),
                 "…and the LAV codec pack")
        t.equal(RecipeRunner.expand(["vcrun", "vcrun2019"]).count, 1,
                "duplicate verbs collapse")
        t.expect(RecipeRunner.expand(["corefonts"]) == ["corefonts"],
                 "a raw winetricks verb passes through untouched")
    }

    t.suite("HUD is off unless asked for")
    do {
        let root = Fixture.dir("hud")
        let paths = Paths(root: root); try? paths.ensure()
        let l = Launcher(paths: paths)
        let rt = RuntimeSpec(id: "r", kind: .wine, version: "1", root: Fixture.dir("rr"),
                             winePath: URL(filePath: "/usr/bin/true"),
                             supports32Bit: true, backends: [.dxvk])
        let prefix = Fixture.dir("hud-prefix")
        try? fm.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
        let b = Bottle(prefixPath: prefix, runtimeID: "r", backend: .dxvk)
        let dir = Fixture.unity(name: "H")
        var g = Game(name: "H", exePath: dir.appending(path: "H.exe"), bottleID: b.id,
                     detection: DetectionResult())
        g.scopes = [ScopeGrant(letter: "h", hostPath: dir)]

        let quiet = try! l.plan(game: g, bottle: b, runtime: rt, verbose: true, showHUD: false)
        t.equal(quiet.env["DXVK_HUD"], "0", "troubleshoot logging does not draw an overlay")
        t.equal(quiet.env["MTL_HUD_ENABLED"], "0", "…nor the Metal overlay")
        t.expect(quiet.env["WINEDEBUG"]?.contains("+d3d") ?? false, "…but verbose logging is still on")
        let loud = try! l.plan(game: g, bottle: b, runtime: rt, verbose: false, showHUD: true)
        t.expect(loud.env["DXVK_HUD"] != "0", "the overlay appears only when explicitly requested")
    }

    t.suite("BepInEx override")
    do {
        let root = Fixture.dir("bep")
        let paths = Paths(root: root); try? paths.ensure()
        let l = Launcher(paths: paths)
        let rt = RuntimeSpec(id: "r", kind: .wine, version: "1", root: Fixture.dir("rr2"),
                             winePath: URL(filePath: "/usr/bin/true"),
                             supports32Bit: true, backends: [.dxvk])
        let prefix = Fixture.dir("bep-prefix")
        try? fm.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
        let b = Bottle(prefixPath: prefix, runtimeID: "r", backend: .dxvk)
        let dir = Fixture.unity(name: "M", modded: true)
        var det = Detector().detect(exe: dir.appending(path: "M.exe"))
        t.expect(det.modded, "a Doorstop config marks the game as modded")
        det.recommendedBackend = .dxvk
        var g = Game(name: "M", exePath: dir.appending(path: "M.exe"), bottleID: b.id, detection: det)
        g.scopes = [ScopeGrant(letter: "h", hostPath: dir)]
        let plan = try! l.plan(game: g, bottle: b, runtime: rt)
        t.expect(plan.env["WINEDLLOVERRIDES"]?.contains("winhttp=n,b") ?? false,
                 "a modded game gets the winhttp override BepInEx needs")
    }
}

/// Schema evolution. This bug class has caused a silent library wipe twice:
/// a new non-optional field makes Swift's synthesised Decodable reject every
/// previously-saved record, and any fallback-to-empty then overwrites the
/// user's library on the next save.
func runSchemaTests(_ t: Harness) {
    t.suite("Old state files keep decoding")
    do {
        let root = Fixture.dir("schema-evolution")
        let paths = Paths(root: root); try? paths.ensure()
        // A game saved before usesVideo / dxvkVersion / changeLog existed.
        let old = """
        {"games":[{"id":"11111111-1111-1111-1111-111111111111","name":"Legacy",
        "exePath":"file:///tmp/legacy.exe","bottleID":"22222222-2222-2222-2222-222222222222",
        "detection":{"engine":"unityIL2CPP","bitness":"x64","graphicsAPIs":["d3d11.dll"],
        "modded":false,"hasWarmDXVKCache":false,"confidence":0.9,"signals":[],
        "recommendedRuntimeKind":"wine","recommendedBackend":"dxvk","recipes":[]},
        "scopes":[],"envOverrides":{},"dllOverrides":{},"runtimeLocked":false,
        "addedAt":768000000}],
        "bottles":[{"id":"22222222-2222-2222-2222-222222222222",
        "prefixPath":"file:///tmp/pfx","runtimeID":"wine-11.0","backend":"dxvk",
        "appliedRecipes":[],"generation":1,"health":{"healthy":{}},"createdAt":768000000}],
        "runtimes":[]}
        """
        try? Data(old.utf8).write(to: paths.statePath)
        let e = try! Engine(paths: paths)
        t.equal(e.store.state.games.count, 1, "a game saved before new fields existed still loads")
        t.equal(e.store.state.games.first?.name, "Legacy", "…with its name intact")
        t.equal(e.store.state.bottles.count, 1, "and its bottle")
        t.expect(e.store.loadError == nil, "and it is not reported as corrupt")
        t.equal(e.store.state.games.first?.detection.usesVideo, false,
                "a field that did not exist yet defaults sanely")

        // Round-trip: saving must not lose the record.
        try? e.store.mutate { _ in }
        let reread = try! Engine(paths: paths)
        t.equal(reread.store.state.games.count, 1, "saving after loading does not wipe the library")
    }

    t.suite("Undecodable state is never silently emptied")
    do {
        let root = Fixture.dir("schema-broken")
        let paths = Paths(root: root); try? paths.ensure()
        // Structurally valid JSON, but a game record that cannot decode.
        try? Data(#"{"games":[{"nonsense":true}],"bottles":[],"runtimes":[]}"#.utf8)
            .write(to: paths.statePath)
        let e = try! Engine(paths: paths)
        t.expect(e.store.loadError != nil,
                 "a library that fails to decode is reported, not quietly replaced with nothing")
    }
}
