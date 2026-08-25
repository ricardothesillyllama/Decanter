import Foundation

/// Maps Windows-only font names onto faces macOS actually has.
///
/// Wine on macOS never populates `drive_c/windows/Fonts`. It registers the
/// host's fonts straight into the prefix registry instead, which is why a fresh
/// bottle has an empty Fonts folder and still renders Latin text correctly:
/// macOS ships genuine Arial, Tahoma, Times New Roman, Verdana and Courier New,
/// so the Microsoft core web fonts resolve without any help from us.
///
/// What nothing supplies are the names macOS has never had — MS Gothic,
/// MS PGothic, Meiryo, Segoe UI, SimSun, Microsoft YaHei. Ask GDI for one of
/// those and it returns no font at all. A Unity game then draws nothing while
/// its layout still reserves the space, which looks like blank widgets in
/// correctly-sized boxes rather than like a font problem.
///
/// Japanese games are the usual casualty *even when their text is English*: a
/// translation patch replaces the strings, not the UI font object, so every
/// label still renders through MS PGothic.
public struct FontProvisioner {
    let fm = FileManager.default
    public init() {}

    /// Windows name -> candidate replacements, best first. Only candidates the
    /// prefix actually registered are used, so a macOS release that drops a
    /// face degrades to the next one instead of writing a rule to nowhere.
    ///
    /// Targets are spelled as Wine registers them (per-face, e.g.
    /// "Hiragino Sans W3"), not as the macOS family name.
    public static let rules: [(name: String, candidates: [String])] = [
        // Japanese. MS Gothic is the monospaced one, so a UD gothic fits it
        // better than the proportional system face.
        ("MS Gothic",          ["BIZ UDGothic", "Osaka-Mono", "Hiragino Sans W3"]),
        ("MS PGothic",         ["Hiragino Sans W3", "BIZ UDGothic", "Osaka"]),
        ("MS UI Gothic",       ["Hiragino Sans W3", "BIZ UDGothic"]),
        ("MS Mincho",          ["BIZ UDMincho", "YuMincho Medium", "Toppan Bunkyu Mincho Regular"]),
        ("MS PMincho",         ["YuMincho Medium", "BIZ UDMincho", "Toppan Bunkyu Mincho Regular"]),
        ("Meiryo",             ["Hiragino Sans W3", "YuGothic Medium"]),
        ("Meiryo UI",          ["Hiragino Sans W3", "YuGothic Medium"]),
        ("Yu Gothic",          ["YuGothic Medium", "Hiragino Sans W3"]),
        ("Yu Gothic UI",       ["YuGothic Medium", "Hiragino Sans W3"]),
        ("Yu Mincho",          ["YuMincho Medium", "BIZ UDMincho"]),

        // Simplified Chinese. SimSun is a song/serif face, SimHei a sans.
        ("SimSun",             ["Songti SC Regular", "PingFang SC Regular"]),
        ("NSimSun",            ["Songti SC Regular", "PingFang SC Regular"]),
        ("SimHei",             ["Heiti SC Medium", "PingFang SC Regular"]),
        ("FangSong",           ["Songti SC Regular", "PingFang SC Regular"]),
        ("KaiTi",              ["Kaiti SC Regular", "Songti SC Regular"]),
        ("Microsoft YaHei",    ["PingFang SC Regular", "Heiti SC Medium"]),
        ("Microsoft YaHei UI", ["PingFang SC Regular", "Heiti SC Medium"]),

        // Traditional Chinese.
        ("MingLiU",            ["Songti TC Regular", "PingFang TC Regular"]),
        ("PMingLiU",           ["Songti TC Regular", "PingFang TC Regular"]),
        ("DFKai-SB",           ["PingFang TC Regular", "Songti TC Regular"]),
        ("Microsoft JhengHei", ["PingFang TC Regular", "Heiti TC Medium"]),

        // Korean.
        ("Malgun Gothic",      ["Apple SD Gothic Neo Regular", "NanumGothic"]),
        ("Gulim",              ["Apple SD Gothic Neo Regular", "NanumGothic"]),
        ("GulimChe",           ["Apple SD Gothic Neo Regular", "NanumGothic"]),
        ("Dotum",              ["Apple SD Gothic Neo Regular", "NanumGothic"]),
        ("DotumChe",           ["Apple SD Gothic Neo Regular", "NanumGothic"]),
        ("Batang",             ["Apple SD Gothic Neo Regular", "NanumGothic"]),

        // Windows-only Latin UI faces. Modern launchers and menus ask for
        // Segoe UI constantly and get nothing.
        ("Segoe UI",           ["Arial", "Tahoma"]),
        ("Segoe UI Semibold",  ["Arial Bold", "Arial"]),
        ("Segoe UI Light",     ["Arial", "Tahoma"]),
        ("Calibri",            ["Arial", "Tahoma"]),
        ("Candara",            ["Arial", "Tahoma"]),
        ("Corbel",             ["Arial", "Tahoma"]),
        ("Cambria",            ["Times New Roman", "Georgia"]),
        ("Constantia",         ["Georgia", "Times New Roman"]),
        ("Consolas",           ["Andale Mono", "Courier New"]),
        ("Lucida Console",     ["Andale Mono", "Courier New"]),
        ("Lucida Sans Unicode", ["Arial Unicode MS", "Arial"]),
        ("Franklin Gothic Medium", ["Arial", "Tahoma"]),
    ]

    // MARK: Reading what the prefix has

    static let fontsSection = #"[Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]"#

    /// Family names Wine registered for this prefix, taken from the cache
    /// wineboot writes. Entries look like `"Arial (TrueType)"="\??\unix\..."`.
    /// `@`-prefixed names are the vertical-writing duplicates and are skipped.
    public func availableFamilies(in prefix: URL) -> Set<String> {
        guard let text = try? String(contentsOf: prefix.appending(path: "system.reg"),
                                     encoding: .utf8) else { return [] }
        var out: Set<String> = []
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") {
                inSection = line.hasPrefix(Self.fontsSection)
                continue
            }
            guard inSection, line.hasPrefix("\""), !line.hasPrefix("\"@") else { continue }
            guard let close = line.dropFirst().firstIndex(of: "\"") else { continue }
            var name = String(line[line.index(after: line.startIndex)..<close])
            for suffix in [" (TrueType)", " (OpenType)", " (All res)", " (VGA res)"] {
                if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
            }
            if !name.isEmpty { out.insert(name) }
        }
        return out
    }

    public struct Plan: Sendable {
        /// Windows name -> the macOS face it will resolve to.
        public var mapped: [(name: String, target: String)] = []
        /// Names with no candidate present on this machine.
        public var unmapped: [String] = []
        /// Names already written into this prefix, so a second look does not
        /// report settled work as outstanding.
        public var already: Set<String> = []
        public var families = 0
        public var isEmpty: Bool { mapped.isEmpty }
        /// What a re-run would actually change.
        public var pending: [(name: String, target: String)] {
            mapped.filter { !already.contains($0.name) }
        }
    }

    /// Decides what to write without touching anything.
    public func plan(for prefix: URL) -> Plan {
        let have = availableFamilies(in: prefix)
        var p = Plan()
        p.families = have.count
        let existing = installed(in: prefix)
        for rule in Self.rules {
            // A prefix that genuinely has the real font keeps it.
            if have.contains(rule.name) { continue }
            if let target = rule.candidates.first(where: { have.contains($0) }) {
                p.mapped.append((rule.name, target))
                if existing[rule.name] == target { p.already.insert(rule.name) }
            } else {
                p.unmapped.append(rule.name)
            }
        }
        return p
    }

    // MARK: Writing

    /// Installs the mapping two ways, because Wine consults two different keys
    /// at two different moments:
    ///
    /// - `Software\Wine\Fonts\Replacements` (HKCU) registers the replacement
    ///   under the requested name, so the alias also shows up in font
    ///   *enumeration*. Unity resolves dynamic fonts by walking the installed
    ///   list, so without this a substitution alone can still come back empty.
    /// - `...\CurrentVersion\FontSubstitutes` (HKLM) is what GDI applies when a
    ///   font is *selected* by name, which covers everything using CreateFont
    ///   directly.
    ///
    /// Deliberately not written: `FontLink\SystemLink`, which would add
    /// per-glyph fallback so a Latin face could borrow CJK glyphs. It needs
    /// REG_MULTI_SZ file/face pairs whose parsing on macOS I have not verified,
    /// and getting it wrong corrupts the registry rather than failing loudly.
    @discardableResult
    public func apply(to prefix: URL, registry: PrefixRegistry = PrefixRegistry()) throws -> Plan {
        let p = plan(for: prefix)
        guard !p.isEmpty else { return p }
        let values = Dictionary(uniqueKeysWithValues:
            p.mapped.map { ($0.name, PrefixRegistry.Value.string($0.target)) })
        try registry.setValues(values,
                               section: #"Software\\Wine\\Fonts\\Replacements"#,
                               in: prefix, file: "user.reg")
        try registry.setValues(values,
                               section: #"Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"#,
                               in: prefix, file: "system.reg")
        return p
    }

    /// What is currently mapped, for `info` and problem reports.
    public func installed(in prefix: URL, registry: PrefixRegistry = PrefixRegistry()) -> [String: String] {
        registry.values(section: #"[Software\\Wine\\Fonts\\Replacements]"#,
                        in: prefix, file: "user.reg")
    }
}
