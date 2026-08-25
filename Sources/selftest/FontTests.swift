import Foundation
import DecanterKit

/// Fonts are the one subsystem that edits system.reg, which is 76,000 lines of
/// data wineboot generated. A writer bug there does not fail loudly — it
/// corrupts a prefix — so these tests care mostly about "changed nothing else".
func runFontTests(_ t: Harness) {
    t.suite("fonts")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appending(path: "decanter-fonts-\(UUID().uuidString)")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    // A prefix that has the Latin core fonts and macOS' CJK faces, but none of
    // the Windows-only names — exactly what wineboot leaves behind.
    let systemReg = """
    WINE REGISTRY Version 2

    [Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts] 1787369801
    #time=1dd31e77230accc
    "@Arial Unicode MS (TrueType)"="\\\\??\\\\unix\\\\ignored.ttf"
    "Arial (TrueType)"="\\\\??\\\\unix\\\\Arial.ttf"
    "Arial Bold (TrueType)"="\\\\??\\\\unix\\\\Arial Bold.ttf"
    "Arial Unicode MS (TrueType)"="\\\\??\\\\unix\\\\Arial Unicode.ttf"
    "Andale Mono (TrueType)"="\\\\??\\\\unix\\\\Andale Mono.ttf"
    "Georgia (TrueType)"="\\\\??\\\\unix\\\\Georgia.ttf"
    "Hiragino Sans W3 (TrueType)"="\\\\??\\\\unix\\\\Hiragino.ttc"
    "PingFang SC Regular (TrueType)"="\\\\??\\\\unix\\\\PingFang.ttc"
    "Songti SC Regular (TrueType)"="\\\\??\\\\unix\\\\Songti.ttc"
    "Tahoma (TrueType)"="\\\\??\\\\unix\\\\Tahoma.ttf"
    "Times New Roman (TrueType)"="\\\\??\\\\unix\\\\Times New Roman.ttf"

    [Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes] 1787368699
    #time=1dd31e4e13f549a
    "Helv"="MS Sans Serif"
    "MS Shell Dlg"="Tahoma"

    [Software\\\\Microsoft\\\\Keep Me] 1787368699
    #time=1dd31e4e13f549a
    "untouched"="yes"

    """
    let prefix = tmp
    try? systemReg.write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)
    try? "WINE REGISTRY Version 2\n\n".write(to: prefix.appending(path: "user.reg"),
                                             atomically: true, encoding: .utf8)

    let fp = FontProvisioner()
    let have = fp.availableFamilies(in: prefix)

    t.expect(have.contains("Arial"), "parses a family name out of the Fonts cache")
    t.expect(have.contains("Hiragino Sans W3"), "parses a name containing spaces and digits")
    t.expect(!have.contains("@Arial Unicode MS"),
             "skips the @-prefixed vertical-writing duplicates")
    t.expect(!have.contains("MS Shell Dlg"),
             "reads only the Fonts section, not FontSubstitutes below it")

    let plan = fp.plan(for: prefix)
    let map = Dictionary(uniqueKeysWithValues: plan.mapped.map { ($0.name, $0.target) })

    t.equal(map["MS PGothic"], "Hiragino Sans W3", "MS PGothic falls to the JP system face")
    t.equal(map["SimSun"], "Songti SC Regular", "SimSun falls to a song face, not a sans")
    t.equal(map["Segoe UI"], "Arial", "Segoe UI falls to Arial")
    t.equal(map["Consolas"], "Andale Mono", "Consolas falls to a monospaced face")
    // BIZ UDGothic is absent from this fixture, so MS Gothic must skip to the
    // next candidate rather than writing a rule pointing at nothing.
    t.equal(map["MS Gothic"], "Hiragino Sans W3", "an absent first choice falls through")
    t.expect(plan.unmapped.contains("MS Mincho"),
             "a name with no candidate present is reported, not silently dropped")
    t.expect(!map.keys.contains("Arial"), "a font the prefix really has is left alone")

    // The write must be surgical.
    let before = (try? String(contentsOf: prefix.appending(path: "system.reg"), encoding: .utf8)) ?? ""
    _ = try? fp.apply(to: prefix)
    let after = (try? String(contentsOf: prefix.appending(path: "system.reg"), encoding: .utf8)) ?? ""

    t.expect(after.contains(#""untouched"="yes""#), "an unrelated section survives the write")
    t.expect(after.contains(#""MS Shell Dlg"="Tahoma""#),
             "pre-existing substitutions survive the write")
    t.expect(after.contains(#""MS PGothic"="Hiragino Sans W3""#),
             "the substitution lands in system.reg (HKLM)")
    t.expect(after.contains("[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts]"),
             "the 76k-line Fonts cache is not clobbered")
    t.expect(after.count > before.count, "the write only added")

    let user = (try? String(contentsOf: prefix.appending(path: "user.reg"), encoding: .utf8)) ?? ""
    t.expect(user.contains(#"[Software\\Wine\\Fonts\\Replacements]"#),
             "the replacement lands in user.reg (HKCU)")
    t.expect(user.contains(#""Segoe UI"="Arial""#), "user.reg carries the same mapping")

    // Re-running is how this gets applied to existing bottles, so it has to be
    // safe to do repeatedly.
    _ = try? fp.apply(to: prefix)
    let twice = (try? String(contentsOf: prefix.appending(path: "system.reg"), encoding: .utf8)) ?? ""
    t.equal(twice.count, after.count, "applying twice changes nothing the second time")
    t.equal(twice.components(separatedBy: #""MS PGothic"="#).count - 1, 1,
            "re-applying does not duplicate a key")

    t.equal(fp.installed(in: prefix)["MS PGothic"], "Hiragino Sans W3",
            "the mapping reads back for problem reports")
    let settled = fp.plan(for: prefix)
    t.expect(settled.pending.isEmpty, "an applied prefix reports nothing outstanding")
    t.expect(!settled.mapped.isEmpty, "but still reports what it mapped")

    // A prefix with no registry at all must not throw or invent files.
    let empty = tmp.appending(path: "empty")
    try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
    t.survives("a prefix with no system.reg is a no-op, not a crash") {
        let p = try FontProvisioner().apply(to: empty)
        t.expect(p.isEmpty, "nothing is mapped when no fonts are known")
    }
}
