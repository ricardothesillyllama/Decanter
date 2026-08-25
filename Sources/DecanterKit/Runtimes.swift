import Foundation

/// Finds Wine builds on the system and *pins* them: takes Decanter's own
/// APFS-cloned copy so that a Homebrew upgrade, a cask conflict, or a deleted
/// upstream repo can't pull the runtime out from under an installed game.
/// This is the specific failure that killed Whisky.
public struct RuntimeManager {
    let paths: Paths
    let fm = FileManager.default
    public init(paths: Paths) { self.paths = paths }

    public struct Candidate: Sendable {
        public var kind: RuntimeKind
        public var wineRoot: URL       // .../Contents/Resources/wine
        public var winePath: URL
        public var version: String
        public var supports32Bit: Bool
    }

    /// Known install locations, in preference order.
    public func discover() -> [Candidate] {
        var found: [Candidate] = []
        let wineApps = [
            ("/Applications/Wine Stable.app/Contents/Resources/wine", RuntimeKind.wine),
            ("/Applications/Wine Devel.app/Contents/Resources/wine", .wine),
            ("/Applications/Wine Staging.app/Contents/Resources/wine", .wine),
            ("/Applications/Game Porting Toolkit.app/Contents/Resources/wine", .gptk),
        ]
        for (path, kind) in wineApps {
            let root = URL(filePath: path)
            guard fm.fileExists(atPath: root.path) else { continue }
            let bin = root.appending(path: "bin/wine")
            let bin64 = root.appending(path: "bin/wine64")
            let exe = fm.isExecutableFile(atPath: bin.path) ? bin
                    : (fm.isExecutableFile(atPath: bin64.path) ? bin64 : nil)
            guard let exe else { continue }
            let ver = (try? Shell.run(exe, ["--version"], timeout: 20).out
                        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
            // 32-bit support means a 32-bit PE module dir exists in the build.
            let has32 = fm.fileExists(atPath: root.appending(path: "lib/wine/i386-windows").path)
                     || fm.fileExists(atPath: root.appending(path: "lib/wine/i386-unix").path)
                     || fm.fileExists(atPath: root.appending(path: "lib/wine/x86_32on64-unix").path)
            found.append(.init(kind: kind, wineRoot: root, winePath: exe,
                               version: ver.replacingOccurrences(of: "wine-", with: ""),
                               supports32Bit: has32))
        }
        return found
    }

    /// Builds a Candidate from an arbitrary Wine root (e.g. an extracted
    /// Game Porting Toolkit.app/Contents/Resources/wine), so a runtime can be
    /// pinned without installing it into /Applications first.
    public func inspect(wineRoot: URL, kindHint: RuntimeKind? = nil) throws -> Candidate {
        let bin = wineRoot.appending(path: "bin/wine")
        let bin64 = wineRoot.appending(path: "bin/wine64")
        let exe = fm.isExecutableFile(atPath: bin.path) ? bin
                : (fm.isExecutableFile(atPath: bin64.path) ? bin64 : nil)
        guard let exe else { throw DecanterError.notFound("no wine binary under \(wineRoot.path)") }
        let isGPTK = fm.fileExists(atPath: wineRoot.appending(path: "lib/external/D3DMetal.framework").path)
        let ver = (try? Shell.run(exe, ["--version"], timeout: 30).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        let has32 = fm.fileExists(atPath: wineRoot.appending(path: "lib/wine/i386-windows").path)
                 || fm.fileExists(atPath: wineRoot.appending(path: "lib/wine/x86_32on64-unix").path)
        return .init(kind: kindHint ?? (isGPTK ? .gptk : .wine),
                     wineRoot: wineRoot, winePath: exe,
                     version: ver.replacingOccurrences(of: "wine-", with: ""),
                     supports32Bit: has32)
    }

    /// Copies a discovered build into Decanter's runtimes dir via APFS clone,
    /// then records it. Cheap on APFS; independent of the source afterwards.
    /// `wine --version` can return "wine-7.7 (Game Porting Toolkit 1.1)".
    /// Only the leading version token is safe to put in a directory name.
    static func sanitize(version: String) -> String {
        let token = version.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? version
        return token.filter { $0.isNumber || $0 == "." || $0.isLetter || $0 == "-" }
    }

    @discardableResult
    public func pin(_ c: Candidate, store: Store) throws -> RuntimeSpec {
        let id = "\(c.kind.rawValue)-\(Self.sanitize(version: c.version))"
        let dest = paths.runtimes.appending(path: id)
        if !fm.fileExists(atPath: dest.path) {
            try fm.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
            let r = try Shell.run(URL(filePath: "/bin/cp"),
                                  ["-Rc", c.wineRoot.path, dest.path], timeout: 600)
            if r.code != 0 {
                // -c (clonefile) fails across filesystems; fall back to a real copy.
                let r2 = try Shell.run(URL(filePath: "/bin/cp"),
                                       ["-R", c.wineRoot.path, dest.path], timeout: 900)
                guard r2.code == 0 else { throw DecanterError.cloneFailed(r2.err) }
            }
        }
        let rel = c.winePath.path.replacingOccurrences(of: c.wineRoot.path + "/", with: "")
        let spec = RuntimeSpec(id: id, kind: c.kind, version: Self.sanitize(version: c.version), root: dest,
                               winePath: dest.appending(path: rel),
                               wineserverPath: dest.appending(path: "bin/wineserver"),
                               supports32Bit: c.supports32Bit,
                               backends: c.kind == .gptk ? [.d3dmetal, .dxvk, .wined3d]
                                                         : [.dxvk, .wined3d])
        try store.mutate { s in
            s.runtimes.removeAll { $0.id == id }
            s.runtimes.append(spec)
        }
        return spec
    }

    /// Picks the best pinned runtime for a detection result, honouring the
    /// 32-bit constraint above all else — a game that can't start is worse
    /// than a game that renders a little slower.
    public func choose(for d: DetectionResult, store: Store) -> RuntimeSpec? {
        let all = store.state.runtimes
        guard !all.isEmpty else { return nil }
        let needs32 = d.bitness == .x86
        let preferred = all.filter { $0.kind == d.recommendedRuntimeKind }
        let pool = (needs32 ? preferred.filter(\.supports32Bit) : preferred)
        if let r = pool.sorted(by: { $0.version > $1.version }).first { return r }
        let fallback = needs32 ? all.filter(\.supports32Bit) : all
        return fallback.sorted(by: { $0.version > $1.version }).first
    }
}
