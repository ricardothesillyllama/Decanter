import Foundation

// MARK: - Soundness

/// Whether a Wine build holds together on its own terms: does every library it
/// references actually exist where it will be looked for?
///
/// This exists because of a specific failure. A runtime was assembled by hand,
/// `libfreetype.6.dylib` was copied into it, and every font call still failed —
/// FreeType links against four more libraries that were not copied, so the
/// `dlopen` failed and Wine fell back to no fonts at all. Decanter could not
/// explain it, because every check it had asked whether a file was present
/// rather than whether it could load.
///
/// A missing library is silent by design: `dlopen` returns null, the caller
/// takes its fallback path, and the game renders blank boxes or plays no video.
/// Nothing writes an error anyone sees. Finding these needs a scan, so this
/// does the scan.
public struct RuntimeAudit: Sendable {
    public init() {}

    public struct Gap: Sendable, Codable, Hashable {
        /// As written in the binary — `@rpath/liborc-0.4.0.dylib`, not a
        /// resolved path, because it does not resolve. That is the point.
        public var library: String
        /// Which files ask for it, as paths inside the build rather than bare
        /// names. The distinction is not pedantry: the Game Porting Toolkit
        /// carries two files called `winegstreamer.so`, one for 64-bit and one
        /// for its 32-on-64 support, with different search paths — one finds
        /// GStreamer and the other does not. Reported by name alone, they are
        /// the same file and the report is wrong about which games are
        /// affected.
        public var neededBy: [String]
        /// Weak dependencies are allowed to be absent — dyld nulls the symbols
        /// and the caller is written to cope. Kept apart so a build is not
        /// called broken for an optional codec it was built to live without.
        public var isWeak: Bool
        /// True when every file that needs this lives on the 32-bit side. A
        /// 32-bit-only gap is real but narrow, and saying "video will not
        /// play" about a build where 64-bit video plays fine is the kind of
        /// overstatement that teaches people to ignore the report.
        public var thirtyTwoBitOnly: Bool

        public init(library: String, neededBy: [String], isWeak: Bool,
                    thirtyTwoBitOnly: Bool = false) {
            self.library = library; self.neededBy = neededBy
            self.isWeak = isWeak; self.thirtyTwoBitOnly = thirtyTwoBitOnly
        }
    }

    public struct Report: Sendable, Codable {
        public var scannedFiles = 0
        public var gaps: [Gap] = []
        public init() {}

        /// Only a hard gap makes a build unsound.
        public var hardGaps: [Gap] { gaps.filter { !$0.isWeak } }
        public var weakGaps: [Gap] { gaps.filter(\.isWeak) }
        public var isSound: Bool { hardGaps.isEmpty }

        /// The count, without naming anything. A library name is meaningless to
        /// almost everyone who will read this — the useful facts are that
        /// something is missing, how much, and what stops working because of
        /// it. The names are still there, under `gaps`, for anyone who asks.
        public var headline: String {
            if isSound { return "Nothing this build expects to find is missing." }
            let n = hardGaps.count
            return "This build is missing \(n) of the supporting piece\(n == 1 ? "" : "s") it expects to find."
        }

        /// What is broken, in the terms of the person who would notice it.
        ///
        /// Derived from *which binary needs the missing piece*, never from the
        /// missing piece's own name. That distinction was a bug: keying on the
        /// name meant a `libbz2` absent from the video decoder's dependencies
        /// announced "text may not draw", because the font library also
        /// happens to use bz2. The same library means different things
        /// depending on who wanted it, so the dependent is what is read.
        public var consequences: [String] {
            var out: [String] = []
            func consumers(_ needles: [String]) -> [Gap] {
                hardGaps.filter { g in
                    g.neededBy.contains { f in
                        let n = (f as NSString).lastPathComponent.lowercased()
                        return needles.contains { n.contains($0) }
                    }
                }
            }
            func line(_ text: String, _ gaps: [Gap]) {
                guard !gaps.isEmpty else { return }
                // Narrow the claim when only the 32-bit side is affected.
                out.append(gaps.allSatisfy(\.thirtyTwoBitOnly)
                           ? text + " This affects 32-bit games only."
                           : text)
            }
            line("Text may not draw at all — the font library cannot load.",
                 consumers(["freetype", "dwrite", "wineps", "win32u", "gdi"]))
            line("Video and cut scenes will not play.",
                 consumers(["gstreamer", "winedmo", "libav", "libgst", "qcap", "avicap", "libglib", "libgobject", "libgmodule"]))
            line("Vulkan graphics cannot start, so DXVK will not work here.",
                 consumers(["vulkan", "moltenvk"]))
            line("Sound may not play.", consumers(["coreaudio", "winealsa"]))
            // Anything left over is real but not something this can name a
            // consequence for. Saying so is better than inventing one.
            let named = Set(
                (consumers(["freetype", "dwrite", "wineps", "win32u", "gdi"])
                 + consumers(["gstreamer", "winedmo", "libav", "libgst", "qcap", "avicap", "libglib", "libgobject", "libgmodule"])
                 + consumers(["vulkan", "moltenvk"])
                 + consumers(["coreaudio", "winealsa"])).map(\.library))
            let rest = hardGaps.filter { !named.contains($0.library) }
            if !rest.isEmpty {
                out.append("\(rest.count) other supporting piece\(rest.count == 1 ? " is" : "s are") missing too. Whatever needs \(rest.count == 1 ? "it" : "them") will fail without saying so.")
            }
            return out
        }
    }

    /// Directory names whose contents are Windows binaries, not Mach-O.
    /// Skipped by name rather than by reading and rejecting each file: a Wine
    /// build holds well over a thousand PE files, and opening them all to learn
    /// they are PE turns a one-second scan into a slow one.
    static func isWindowsSide(_ name: String) -> Bool { name.hasSuffix("-windows") }

    /// Every Mach-O image under a Wine root, dependencies resolved.
    public func audit(root: URL) -> Report {
        var rep = Report()
        var missing: [String: (files: Set<String>, weak: Bool)] = [:]

        for file in Self.machOCandidates(root: root) {
            guard let image = MachO.read(at: file) else { continue }
            rep.scannedFiles += 1
            let dir = file.deletingLastPathComponent()
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            for dep in image.dependencies {
                if Self.resolves(dep.path, loaderDir: dir, rpaths: image.rpaths, root: root) { continue }
                var entry = missing[dep.path] ?? (files: [], weak: dep.isWeak)
                entry.files.insert(relative)
                // If any binary needs it non-weakly, the gap is hard.
                entry.weak = entry.weak && dep.isWeak
                missing[dep.path] = entry
            }
        }

        rep.gaps = missing
            .map { lib, v in
                Gap(library: lib, neededBy: v.files.sorted(), isWeak: v.weak,
                    thirtyTwoBitOnly: v.files.allSatisfy(Self.isThirtyTwoBitPath))
            }
            .sorted { ($0.isWeak ? 1 : 0, $0.library) < ($1.isWeak ? 1 : 0, $1.library) }
        return rep
    }

    /// Whether a path inside the build belongs to the 32-bit side.
    ///
    /// Wine keeps the two apart by directory — `i386-*` for plain 32-bit,
    /// `x86_32on64-*` for the Game Porting Toolkit's thunking layer — so the
    /// directory is the answer and no guessing is involved.
    public static func isThirtyTwoBitPath(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { c in
            c.hasPrefix("i386-") || c.hasPrefix("x86_32on64")
        }
    }

    /// The files worth reading: the Unix side of Wine, the libraries it carries,
    /// and the binaries in `bin`.
    static func machOCandidates(root: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for sub in ["lib", "bin"] {
            let base = root.appending(path: sub)
            guard let walk = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in walk {
                if isWindowsSide(u.lastPathComponent) { walk.skipDescendants(); continue }
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                out.append(u)
            }
        }
        return out
    }

    /// dyld's search, reduced to the cases a Wine build actually uses.
    /// Exposed so a resolution can be shown step by step when it is wrong.
    public static func explain(_ raw: String, loaderDir: URL, rpaths: [String], root: URL) -> String {
        "\(resolves(raw, loaderDir: loaderDir, rpaths: rpaths, root: root) ? "found" : "MISSING")  \(raw)"
    }

    /// Whether dyld would find `raw`, given who is asking and where it lives.
    /// Public so the suite can hold the resolution rules to account directly —
    /// every one of them was wrong at least once.
    public static func resolves(_ raw: String, loaderDir: URL, rpaths: [String], root: URL) -> Bool {
        let fm = FileManager.default
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: (p as NSString).standardizingPath) }

        // Absolute system paths are the one case where "the file is not there"
        // means nothing at all. Since Big Sur the system libraries exist only
        // inside the dyld shared cache — /usr/lib/libSystem.B.dylib has no file
        // behind it on any modern Mac — so checking the filesystem for them
        // would report every binary in the build as broken.
        if raw.hasPrefix("/usr/lib/") || raw.hasPrefix("/System/") { return true }

        if raw.hasPrefix("@loader_path/") {
            return exists(loaderDir.appending(path: String(raw.dropFirst(13))).path)
        }
        if raw.hasPrefix("@executable_path/") {
            // These libraries are loaded by `bin/wine`, and `wine` re-execs
            // itself as `wine-preloader` from the same directory, so `bin` is
            // the executable directory in every case that matters here.
            return exists(root.appending(path: "bin/" + String(raw.dropFirst(17))).path)
        }
        if raw.hasPrefix("@rpath/") {
            let tail = String(raw.dropFirst(7))
            // dyld does not give up when every LC_RPATH misses: it falls back
            // to searching DYLD_FALLBACK_LIBRARY_PATH by leaf name. Decanter
            // sets that itself before launching Wine, so the audit has to search
            // the same directories or it reports libraries as missing that will
            // in fact be found. See PrefixBuilder.baseEnv, which this mirrors.
            if Self.fallbackDirectories(root: root).contains(where: { exists($0 + "/" + (tail as NSString).lastPathComponent) }) {
                return true
            }
            for rp in rpaths {
                var base = rp
                if base.hasPrefix("@loader_path/") {
                    base = loaderDir.appending(path: String(base.dropFirst(13))).path
                } else if base == "@loader_path" {
                    base = loaderDir.path
                } else if base.hasPrefix("@executable_path/") {
                    base = root.appending(path: "bin/" + String(base.dropFirst(17))).path
                } else if base == "@executable_path" {
                    base = root.appending(path: "bin").path
                }
                if exists(base + "/" + tail) { return true }
            }
            return false
        }
        if raw.hasPrefix("/") { return exists(raw) }

        // A bare name is resolved by dyld's fallback search. Wine also sets
        // DYLD_FALLBACK_LIBRARY_PATH into the runtime's own lib directory, so
        // that is checked alongside the loader's directory.
        for dir in [loaderDir.path] + Self.fallbackDirectories(root: root) {
            if exists(dir + "/" + raw) { return true }
        }
        return false
    }

    /// Exactly what `PrefixBuilder.baseEnv` puts in DYLD_FALLBACK_LIBRARY_PATH,
    /// plus dyld's own default. Kept next to the resolver so the two cannot
    /// drift into disagreeing about where a library will be looked for.
    public static func fallbackDirectories(root: URL) -> [String] {
        [root.appending(path: "lib/external").path,
         root.appending(path: "lib").path,
         "/usr/local/lib", "/usr/lib"]
    }
}

// MARK: - Capability bench

/// What each pinned Wine build can actually provide, measured rather than
/// declared, with the evidence kept.
///
/// Decanter already worked this out once, at the moment a runtime was pinned,
/// and then wrote the answer into `state.json` and never looked again. That is
/// wrong in both directions. A build assembled or repaired afterwards gains
/// capabilities the record does not know about — this is exactly what happened
/// when a runtime was given its missing font libraries and nothing re-measured.
/// And a build can lose them, if something it depended on is removed.
///
/// So the bench is a thing that is *run*, not a thing that is inferred once. It
/// records what was looked at, so a claim can be checked rather than believed.
public struct Bench: Sendable {
    let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// One backend, on one runtime.
    public struct Finding: Sendable, Codable, Hashable {
        public var backend: GraphicsBackend
        public var provided: Bool
        /// The answer, in words that carry no file formats, no symbol names and
        /// no library names. "No" without a reason sends people to a forum; a
        /// "no" whose reason is three sentences of Mach-O terminology sends
        /// them to the same forum, having first felt stupid.
        ///
        /// The test for whether a sentence belongs here: could someone decide
        /// what to do next after reading only this? "It needs a different Wine
        /// build, and no setting will change that" passes. "Its Mac driver is
        /// a Mach-O bundle" does not — it is the reason for the answer, not the
        /// answer.
        public var reason: String
        /// The same finding for someone who wants the reasoning. Never shown
        /// unless it is asked for. Empty when the plain answer is the whole of
        /// what is known.
        public var detail: String
        /// The files that decided it. A capability claim nobody can check is
        /// an opinion, and this project has been wrong often enough to want
        /// the receipts kept. Detail, not headline.
        public var evidence: [String]

        public init(backend: GraphicsBackend, provided: Bool, reason: String,
                    detail: String = "", evidence: [String] = []) {
            self.backend = backend; self.provided = provided
            self.reason = reason; self.detail = detail; self.evidence = evidence
        }
    }

    public struct RuntimeRow: Sendable, Codable {
        public var runtimeID: String
        public var kind: RuntimeKind
        public var version: String
        public var supports32Bit: Bool
        public var findings: [Finding] = []
        public var soundness = RuntimeAudit.Report()
        public var measuredAt = Date()
        /// Which Decanter measured this. A row taken by an older build may have
        /// asked a weaker question, and that is worth being able to see.
        public var measuredBy = Build.version
        /// Cheap fingerprint of the build, so a row can tell that the thing it
        /// describes has changed underneath it. Not a hash of 2 GB — the size
        /// and modification date of the Wine binary and the Mac driver, which
        /// is what changes when a build is repaired or replaced.
        public var fingerprint: String = ""

        public init(runtimeID: String, kind: RuntimeKind, version: String, supports32Bit: Bool) {
            self.runtimeID = runtimeID; self.kind = kind
            self.version = version; self.supports32Bit = supports32Bit
        }

        public var backends: [GraphicsBackend] {
            findings.filter(\.provided).map(\.backend).inPreferenceOrder
        }
        public func finding(_ b: GraphicsBackend) -> Finding? {
            findings.first { $0.backend == b }
        }

        /// What this build cannot provide, and the reason, weakest claim last.
        ///
        /// The counterpart to `backends`, and the half nothing displayed. A
        /// picker that lists what is available says nothing about what is not,
        /// so "where is Metal graphics?" had no answer anywhere — while this
        /// had already been measured and written down.
        public var unavailable: [(backend: GraphicsBackend, reason: String)] {
            findings.filter { !$0.provided }
                .sorted { $0.backend.rank < $1.backend.rank }
                .map { ($0.backend, $0.reason) }
        }
    }

    public struct Table: Sendable, Codable {
        public var formatVersion = 1
        public var rows: [RuntimeRow] = []
        public init() {}
        public func row(_ id: String) -> RuntimeRow? { rows.first { $0.runtimeID == id } }
    }

    public var tablePath: URL { paths.root.appending(path: "bench.json") }

    /// The table is a cache of measurements, never a source of truth: anything
    /// it holds can be produced again by running the bench. So a file written
    /// by a different version that no longer decodes is discarded rather than
    /// migrated — the cost is one re-measurement, and the alternative is
    /// migration code for a file that is cheap to rebuild.
    public func load() -> Table {
        guard let d = try? Data(contentsOf: tablePath),
              let t = try? JSONDecoder().decode(Table.self, from: d) else { return Table() }
        return t
    }

    public func save(_ t: Table) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(t).write(to: tablePath, options: .atomic)
    }

    /// A row is stale when the build it describes has changed since, or when a
    /// newer Decanter would ask a different question.
    public func isStale(_ row: RuntimeRow, runtime: RuntimeSpec) -> Bool {
        row.fingerprint != Self.fingerprint(of: runtime) || row.measuredBy != Build.version
    }

    static func fingerprint(of runtime: RuntimeSpec) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        for rel in ["bin/wine", "lib/wine/x86_64-unix/winemac.so",
                    "lib/wine/x86_64-unix/winemac.drv.so",
                    "lib/wine/x86_64-unix/winemetal.so"] {
            let p = runtime.root.appending(path: rel).path
            guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
            let size = (a[.size] as? NSNumber)?.intValue ?? 0
            let mod = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(rel):\(size):\(Int(mod))")
        }
        return parts.joined(separator: "|")
    }

    /// Measures one build, end to end.
    public func measure(_ runtime: RuntimeSpec, auditing: Bool = true) -> RuntimeRow {
        var row = RuntimeRow(runtimeID: runtime.id, kind: runtime.kind,
                             version: runtime.version, supports32Bit: runtime.supports32Bit)
        row.fingerprint = Self.fingerprint(of: runtime)
        let fm = FileManager.default
        let root = runtime.root
        func rel(_ u: URL) -> String {
            u.path.replacingOccurrences(of: root.path + "/", with: "")
        }

        // WineD3D — Wine's own Direct3D on OpenGL. Always available where Wine
        // itself is, which is exactly why it is the fallback everything else
        // degrades to.
        let wine = fm.isExecutableFile(atPath: runtime.winePath.path)
        row.findings.append(.init(
            backend: .wined3d, provided: wine,
            reason: wine
                ? "Available. The safe choice: slower than the others, and the one that fails least often."
                : "There is no working copy of Wine in this build, so it cannot run anything.",
            detail: wine
                ? "Wine's own Direct3D implementation, translated to OpenGL. Complete, including the interfaces the faster paths omit."
                : "",
            evidence: [rel(runtime.winePath)]))

        // DXVK — Direct3D through Vulkan. On macOS the only Vulkan is MoltenVK,
        // and Wine builds carry their own. `winevulkan.so` is not evidence:
        // it is the Wine side of the bridge and ships either way. Measured —
        // Sikarugir's Wine 10 has winevulkan.so and no MoltenVK, and DXVK on it
        // fails at "VK_KHR_surface not supported".
        let vulkan = Self.moltenVK(in: root)
        row.findings.append(.init(
            backend: .dxvk, provided: vulkan != nil,
            reason: vulkan != nil
                ? "Available. This build carries the graphics support DXVK needs."
                : "Not available. This build does not carry the graphics support DXVK needs, and no setting can add it — it would have to be a different Wine build.",
            detail: vulkan != nil
                ? "DXVK translates Direct3D to Vulkan, and the only Vulkan on macOS is MoltenVK, which Wine builds ship inside themselves."
                : "Wine's own winevulkan is present, but that is only the Wine half of the bridge and ships either way. Without MoltenVK there is no Vulkan driver underneath it, and DXVK fails at \"VK_KHR_surface not supported\".",
            evidence: vulkan.map { [rel($0)] } ?? []))

        // D3DMetal — Apple's own translation, shipped only inside the Game
        // Porting Toolkit and not redistributable, so its presence is a fact
        // about the build on this Mac rather than something Decanter can add.
        let d3dm = root.appending(path: "lib/external/D3DMetal.framework")
        let hasD3DM = fm.fileExists(atPath: d3dm.path)
        row.findings.append(.init(
            backend: .d3dmetal, provided: hasD3DM,
            reason: hasD3DM
                ? "Available. Apple's own graphics translation is part of this build."
                : "Not available. Apple's graphics translation comes only inside Apple's Game Porting Toolkit, and cannot be copied into another build.",
            detail: hasD3DM
                ? "D3DMetal converts Direct3D 11 and 12 straight to Metal. The fastest option here, but it leaves out some interfaces — notably the ones Unity's video player needs."
                : "Apple's licence for the Game Porting Toolkit does not permit redistributing D3DMetal, so a build that did not come with it cannot be given it.",
            evidence: hasD3DM ? [rel(d3dm)] : []))

        // DXMT — Direct3D 11 straight to Metal. Two independent conditions,
        // both learned the hard way; see RuntimeManager.MetalHosting.
        let hosting = RuntimeManager.metalHosting(root: root)
        let bridge = root.appending(path: "lib/wine/x86_64-unix/winemetal.so")
        let hasBridge = fm.fileExists(atPath: bridge.path)
        var dxmtEvidence: [String] = []
        if let d = hosting.driverPath { dxmtEvidence.append(rel(d)) }
        if hasBridge { dxmtEvidence.append(rel(bridge)) }
        row.findings.append(.init(
            backend: .dxmt, provided: hosting.looksCapable,
            reason: hosting.looksCapable
                ? (hasBridge
                    ? "Available. This build can draw through Metal, and the Metal support is installed."
                    : "This build can draw through Metal, but the Metal support has not been installed into it yet. Decanter can do that.")
                : (hosting.unavailableSummary ?? "This build cannot draw through Metal."),
            detail: hosting.looksCapable
                ? "The build's Mac driver is a linkable library and exports the calls DXMT looks up at the first frame — the two conditions that decide it."
                : (hosting.unavailableReason?.replacingOccurrences(of: "\n", with: " ") ?? ""),
            evidence: dxmtEvidence))

        if auditing { row.soundness = RuntimeAudit().audit(root: root) }
        return row
    }

    /// Where MoltenVK is, if it is anywhere. Builds put it in `lib`, beside the
    /// Unix libraries, or tucked inside a bundled framework — the Game Porting
    /// Toolkit keeps its copy inside GStreamer.framework, which a check of
    /// `lib/libMoltenVK.dylib` alone would miss.
    public static func moltenVK(in root: URL) -> URL? {
        let fm = FileManager.default
        for p in ["lib/libMoltenVK.dylib", "lib/wine/x86_64-unix/libMoltenVK.dylib"] {
            let u = root.appending(path: p)
            if fm.fileExists(atPath: u.path) { return u }
        }
        guard let walk = fm.enumerator(at: root.appending(path: "lib"),
                                       includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in walk where u.lastPathComponent.hasPrefix("libMoltenVK") { return u }
        return nil
    }

    /// Measures every pinned runtime and writes the table.
    @discardableResult
    public func runAll(store: Store, progress: (String) -> Void = { _ in }) throws -> Table {
        var t = Table()
        for rt in store.state.runtimes {
            progress("measuring \(rt.id)")
            t.rows.append(measure(rt))
        }
        try save(t)
        return t
    }

    /// Folds the measured capabilities back into the recorded runtimes, so the
    /// rest of Decanter reads one answer rather than two.
    ///
    /// This is the half that was missing. `backends` was decided once at pin
    /// time and never revisited, so a build that gained a capability kept being
    /// offered the old list — and a person who repaired their runtime had no
    /// way to tell Decanter about it short of unpinning and pinning again.
    @discardableResult
    public func reconcile(store: Store, table: Table) throws -> [String] {
        var changes: [String] = []
        try store.mutate { s in
            for i in s.runtimes.indices {
                guard let row = table.row(s.runtimes[i].id) else { continue }
                let old = s.runtimes[i].backends.inPreferenceOrder
                let new = row.backends
                guard old != new else { continue }
                let gained = new.filter { !old.contains($0) }.map(\.label)
                let lost = old.filter { !new.contains($0) }.map(\.label)
                var parts: [String] = []
                if !gained.isEmpty { parts.append("gained \(gained.joined(separator: ", "))") }
                if !lost.isEmpty { parts.append("lost \(lost.joined(separator: ", "))") }
                changes.append("\(s.runtimes[i].id): \(parts.joined(separator: ", "))")
                s.runtimes[i].backends = new
            }
        }
        return changes
    }
}
