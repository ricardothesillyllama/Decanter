import Foundation

/// Creates and derives Wine prefixes. Per the design: a broken prefix is never
/// repaired, it is re-derived from the golden template — which is cheap
/// because APFS clones a 335MB prefix in about half a second.
public struct PrefixBuilder {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    public typealias Progress = (String) -> Void

    // MARK: Golden template

    public func buildGoldenTemplate(runtime: RuntimeSpec, store: Store,
                                    progress: Progress = { _ in }) throws {
        let dst = paths.template(for: runtime.id)
        if fm.fileExists(atPath: dst.path) {
            progress("removing previous template")
            try fm.removeItem(at: dst)
        }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Wine's services outlive whatever spawned them, so the shutdown has
        // to happen even when the bootstrap throws. Skipping it on the error
        // path is how a failed template build left a rundll32 running for days.
        defer {
            if let ws = runtime.wineserverPath, fm.isExecutableFile(atPath: ws.path) {
                _ = try? Shell.run(ws, ["-k"],
                                   env: ["WINEPREFIX": dst.path], timeout: 60)
            }
        }
        progress("bootstrapping prefix with \(runtime.id) (this takes a minute)")
        var env = baseEnv(prefix: dst, runtime: runtime)
        // Suppress only the Gecko dialog. Suppressing mscoree here stopped
        // wineboot installing the bundled wine-mono into the prefix, so every
        // prefix silently had no .NET at all.
        env["WINEDLLOVERRIDES"] = "mshtml="
        let r = try Shell.run(runtime.winePath, ["wineboot", "-u"], env: env, timeout: 600)
        guard fm.fileExists(atPath: dst.appending(path: "system.reg").path) else {
            throw DecanterError.cloneFailed("wineboot produced no prefix: \(r.err.suffix(400))")
        }
        progress("setting Windows 10 mode")
        _ = try? Shell.run(runtime.winePath,
                           ["reg", "add", #"HKCU\Software\Wine"#, "/v", "Version",
                            "/d", "win10", "/f"], env: env, timeout: 120)

        // Wine ships wine-mono but only offers to install it when something
        // asks for .NET — as a modal dialog, mid-launch, that blocks the game
        // behind a prompt nobody expects. Both templates had no mono at all.
        // Putting it in the template means no prefix ever meets that dialog.
        let monoSrc = runtime.root.appending(path: "share/wine/mono")
        if let builds = try? fm.contentsOfDirectory(atPath: monoSrc.path),
           let build = builds.first(where: { $0.hasPrefix("wine-mono") }) {
            let dst = dst.appending(path: "drive_c/windows/mono")
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            progress("installing \(build) into the template")
            _ = try? Shell.run(URL(filePath: "/bin/cp"),
                               ["-Rc", monoSrc.appending(path: build).path,
                                dst.appending(path: build).path], timeout: 300)
        } else {
            progress("this runtime ships no wine-mono — .NET games may prompt")
        }

        progress("removing full-filesystem drive mapping")
        try descope(prefix: dst)

        // Wine registers the host's fonts but invents no aliases, so every
        // Windows-only name (MS PGothic, Segoe UI, SimSun) resolves to nothing
        // and games drawing with them render blank. Map them here so every
        // bottle cloned from this template inherits the fix.
        progress("mapping Windows font names onto macOS faces")
        let fonts = try FontProvisioner().apply(to: dst)
        progress("  \(fonts.mapped.count) names mapped from \(fonts.families) host families")
        if !fonts.unmapped.isEmpty {
            progress("  no macOS face for: \(fonts.unmapped.joined(separator: ", "))")
        }

        // Bake DXVK into the template so every cloned prefix inherits it.
        let dxvk = DXVKInstaller(paths: paths)
        if dxvk.isStaged {
            progress("installing DXVK \(dxvk.stagedVersion ?? "") into template")
            _ = try? dxvk.install(into: dst, runtime: runtime, progress: progress)
        } else {
            progress("DXVK not staged - template will use Wine's builtin D3D")
        }

        // Wine launches `winedbg --auto` on every unhandled exception. A game
        // that crashes in a loop therefore spawns one debugger per crashing
        // thread, each of which wants a console, fails to find a font, and
        // crashes in turn. Measured once here: 773 winedbg processes and two
        // conhost.exe at 100% CPU, load average 38, with `decanter doctor`
        // timing out at 120s. Nothing capped it because nothing was watching.
        // An empty Debugger value means the process just dies, which is the
        // correct outcome for a crash nobody is attached to.
        progress("disabling Wine's automatic crash debugger")
        try? PrefixRegistry().setValues(
            ["Debugger": .string(""), "Auto": .string("0")],
            section: "Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug",
            in: dst, file: "system.reg")

        progress("shutting down wineserver")
        if let ws = runtime.wineserverPath, fm.isExecutableFile(atPath: ws.path) {
            _ = try? Shell.run(ws, ["-k"], env: env, timeout: 60)
        }
        try store.mutate { s in
            s.templateBuiltAt = Date()
            s.templateRuntimeID = runtime.id
            s.templates[runtime.id] = Date()
        }
        progress("golden template ready")
    }

    // MARK: Derivation

    /// Clones the golden template into a new bottle. Uses APFS clonefile so
    /// this costs no meaningful disk and takes well under a second.
    public func derive(bottleID: UUID, runtime: RuntimeSpec,
                       backend: GraphicsBackend) throws -> Bottle {
        let template = templateURL(for: runtime)
        guard fm.fileExists(atPath: template.path) else {
            throw DecanterError.noTemplate(runtime.id)
        }
        let dst = paths.bottles.appending(path: bottleID.uuidString)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.createDirectory(at: paths.bottles, withIntermediateDirectories: true)
        let r = try Shell.run(URL(filePath: "/bin/cp"),
                              ["-Rc", template.path, dst.path], timeout: 300)
        if r.code != 0 {
            let r2 = try Shell.run(URL(filePath: "/bin/cp"),
                                   ["-R", template.path, dst.path], timeout: 900)
            guard r2.code == 0 else { throw DecanterError.cloneFailed(r2.err) }
        }
        return Bottle(id: bottleID, prefixPath: dst, runtimeID: runtime.id, backend: backend)
    }

    /// Per-runtime template, falling back to the legacy shared one.
    public func templateURL(for runtime: RuntimeSpec) -> URL {
        let perRuntime = paths.template(for: runtime.id)
        if fm.fileExists(atPath: perRuntime.path) { return perRuntime }
        return paths.template
    }

    // MARK: Scoping

    /// Removes every drive Decanter did not create.
    ///
    /// Removing `z: -> /` was never sufficient. Whisky mapped the entire Mac
    /// filesystem into every bottle, so a Windows binary from the open internet
    /// could read ~/Documents, ~/.ssh and iCloud — but `wineboot` also maps a
    /// drive letter at every mounted volume, and a raw `/dev/rdisk` node beside
    /// it. A prefix quietly gained a door onto each external disk, network
    /// share and mounted image the moment one appeared. Measured on a real
    /// install: `d: -> /Volumes/...`, `e: -> /Volumes/...`, `d:: -> /dev/rdisk8s1`.
    ///
    /// The documented promise is that a game sees its own folder and nothing
    /// else, so anything that is not `c:` and not a granted scope goes.
    /// Returns what it closed, so this can be said in plain words rather than
    /// discovered in a log.
    @discardableResult
    public func descope(prefix: URL, keeping scopes: [ScopeGrant] = []) throws -> [String] {
        let dd = prefix.appending(path: "dosdevices")
        // `c:` is the prefix's own drive; a granted letter is one the user
        // asked for. Both spellings of a device node belong to their letter.
        var keep: Set<String> = ["c:", "c::"]
        for s in scopes {
            keep.insert("\(s.letter.lowercased()):")
            keep.insert("\(s.letter.lowercased())::")
        }

        var closed: [String] = []
        let names = (try? fm.contentsOfDirectory(atPath: dd.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            guard !keep.contains(name.lowercased()) else { continue }
            // Only a symlink is a drive mapping. Anything else is not ours to
            // judge, and removing a real directory here would be destructive.
            let link = dd.appending(path: name)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            try? fm.removeItem(at: link)
            closed.append("\(name) -> \(dest)")
        }
        try sandboxUserFolders(prefix: prefix)
        return closed
    }

    /// Removing `z:` is NOT sufficient. Wine also points each Windows user
    /// folder at the corresponding real one in the host home directory —
    /// Documents, Downloads, Desktop, Music, Pictures, Videos — so a game can
    /// still read and write them through C:\users\<user>\Documents.
    /// Replace any symlink that escapes the prefix with a real folder inside it.
    @discardableResult
    public func sandboxUserFolders(prefix: URL) throws -> [String] {
        var fixed: [String] = []
        let users = prefix.appending(path: "drive_c/users")
        guard let names = try? fm.contentsOfDirectory(atPath: users.path) else { return fixed }
        let prefixReal = prefix.resolvingSymlinksInPath().path
        for user in names where !user.hasPrefix(".") {
            let home = users.appending(path: user)
            guard let entries = try? fm.contentsOfDirectory(atPath: home.path) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let item = home.appending(path: entry)
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: item.path) else { continue }
                let target = dest.hasPrefix("/") ? dest
                    : home.appending(path: dest).standardizedFileURL.path
                // A link that stays inside the prefix is ours and is fine.
                if URL(filePath: target).resolvingSymlinksInPath().path.hasPrefix(prefixReal) { continue }
                try? fm.removeItem(at: item)
                try? fm.createDirectory(at: item, withIntermediateDirectories: true)
                fixed.append("\(user)/\(entry) -> was \(target)")
            }
        }
        return fixed
    }

    @discardableResult
    public func applyScopes(prefix: URL, scopes: [ScopeGrant]) throws -> [String] {
        let dd = prefix.appending(path: "dosdevices")
        try fm.createDirectory(at: dd, withIntermediateDirectories: true)
        // Descope before the grants are written, so a letter the user asked
        // for is created fresh rather than trusted from whatever was there —
        // but tell descope which letters those are. Without that it reported
        // the game's own folder as "a drive this game should not have had",
        // moments before recreating it. The doors were right and the account of
        // them was false, which is the worse of the two failures.
        let closed = try descope(prefix: prefix, keeping: scopes)
        for s in scopes {
            let link = dd.appending(path: "\(s.letter):")
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: s.hostPath.path)
        }
        return closed
    }

    /// Names of Windows user folders that currently escape the prefix.
    public func escapingUserFolders(prefix: URL) -> [String] {
        var out: [String] = []
        let users = prefix.appending(path: "drive_c/users")
        guard let names = try? fm.contentsOfDirectory(atPath: users.path) else { return out }
        let prefixReal = prefix.resolvingSymlinksInPath().path
        for user in names where !user.hasPrefix(".") {
            let home = users.appending(path: user)
            for entry in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where !entry.hasPrefix(".") {
                let item = home.appending(path: entry)
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: item.path) else { continue }
                let target = dest.hasPrefix("/") ? dest : home.appending(path: dest).standardizedFileURL.path
                if URL(filePath: target).resolvingSymlinksInPath().path.hasPrefix(prefixReal) { continue }
                out.append("\(entry)")
            }
        }
        return out
    }

    // MARK: Environment

    public func baseEnv(prefix: URL, runtime: RuntimeSpec) -> [String: String] {
        var e: [String: String] = [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all",
            "WINEDLLPATH": runtime.root.appending(path: "lib/wine").path,
        ]
        // Every runtime's own lib directory has to be searchable, not just
        // GPTK's. Wine dlopens libfreetype, GStreamer and friends by soname
        // rather than linking them, so a build that ships its own copies in
        // lib/ still cannot find them unless that directory is on the fallback
        // path — and the symptom is Wine announcing it "cannot find the
        // FreeType font library" while the library sits right there. GPTK
        // keeps lib/external first because that is where D3DMetal lives.
        var libPaths: [String] = []
        if runtime.kind == .gptk { libPaths.append(runtime.root.appending(path: "lib/external").path) }
        libPaths.append(runtime.root.appending(path: "lib").path)
        libPaths.append("/usr/lib")
        e["DYLD_FALLBACK_LIBRARY_PATH"] = libPaths.joined(separator: ":")
        return e
    }

    public func graphicsEnv(_ backend: GraphicsBackend, runtime: RuntimeSpec) -> [String: String] {
        switch backend {
        case .dxvk:
            return ["DXVK_HUD": "0", "DXVK_LOG_LEVEL": "none",
                    "WINEDLLOVERRIDES": "d3d9,d3d10core,d3d11,dxgi=n"]
        case .d3dmetal:
            guard runtime.kind == .gptk else { return [:] }
            // GPTK implements D3DMetal *inside* Wine's builtin D3D modules, so
            // these must resolve builtin. Using "native" here would pick up the
            // DXVK DLLs sitting in the prefix and quietly run DXVK instead.
            return ["D3DM_SUPPORT_DXR": "0", "MTL_HUD_ENABLED": "0",
                    "WINEDLLOVERRIDES": "d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"]
        case .wined3d:
            return ["WINEDLLOVERRIDES": "d3d11,d3d10core,dxgi,d3d9=b"]
        case .dxmt:
            // DXMT ships Wine *builtin* DLLs, so they are selected with `=b`
            // and found on WINEDLLPATH — not copied into the prefix as native
            // ones. `=b` also matters for a second reason, the same one
            // D3DMetal has: a prefix that already contains DXVK's native DLLs
            // would otherwise quietly run DXVK instead.
            //
            // WINEDLLPATH is *replaced* by what is returned here, so the
            // runtime's own directory is carried along rather than dropped.
            // Builtin, not native: DXMT's DLLs *are* this runtime's builtins,
            // and only a builtin gets its unixlib — DXMT's Metal bridge —
            // bound to it. `=b` also stops a prefix that still has DXVK's
            // native DLLs in system32 from quietly running DXVK instead, the
            // same trap D3DMetal has.
            return ["DXMT_LOG_LEVEL": "none",
                    "WINEDLLOVERRIDES": "d3d10core,d3d11,dxgi,winemetal=b"]
        }
    }
}
