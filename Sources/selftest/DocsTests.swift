import Foundation
import DecanterKit

/// Documentation drift, caught by the suite rather than by a reader.
///
/// The check count reached 337 in the README while CONTRIBUTING still said 328,
/// and a suite could be added without ever appearing in the list contributors
/// are told to run. Both are the same failure: a fact stated in two places and
/// maintained in one.
func runDocsTests(_ t: Harness) {
    t.suite("docs match the code")

    // #filePath is Sources/selftest/DocsTests.swift, so the root is three up.
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ name: String) -> String {
        (try? String(contentsOf: root.appending(path: name), encoding: .utf8)) ?? ""
    }
    let readme = read("README.md")
    let contributing = read("CONTRIBUTING.md")
    let main = read("Sources/selftest/main.swift")

    guard !readme.isEmpty, !contributing.isEmpty, !main.isEmpty else {
        t.skip("docs checks", "run from outside the source tree"); return
    }

    func claimedCount(_ s: String) -> Int? {
        guard let r = s.range(of: #"\*\*[0-9]+ checks"#, options: .regularExpression) else { return nil }
        return Int(s[r].filter(\.isNumber))
    }
    let a = claimedCount(readme), b = claimedCount(contributing)
    t.expect(a != nil, "the README states a check count")
    t.expect(b != nil, "CONTRIBUTING states a check count")
    t.equal(a, b, "both documents state the same number — ./scripts/sync-docs.sh keeps them in step")

    // The CI badge carries the same figure in its label. It was the one place
    // the number was not generated, and it was the one place it was wrong.
    if let r = readme.range(of: #"label=[0-9]+%20checks"#, options: .regularExpression) {
        // Only the digits before the '%'. Filtering every digit out of the
        // match swallows the 20 in "%20" and turns 466 into 46620 — which the
        // test then reported as a mismatch for the wrong reason.
        let digits = readme[r].dropFirst("label=".count).prefix { $0.isNumber }
        t.equal(Int(digits), a, "the CI badge states the same count as the prose")
    } else {
        t.expect(false, "the CI badge states a check count")
    }

    // Every suite the harness accepts must be listed for contributors to run.
    var registered: Set<String> = []
    for line in main.split(separator: "\n") where line.contains("args.contains(") {
        if let r = line.range(of: #"args\.contains\("[a-z]+"\)"#, options: .regularExpression) {
            registered.insert(String(line[r]).filter { $0.isLetter })
                .self
        }
    }
    registered = Set(registered.map { $0.replacingOccurrences(of: "argscontains", with: "") })

    var documented: Set<String> = []
    for line in contributing.split(separator: "\n") where line.contains("swift run selftest ") {
        let after = line.components(separatedBy: "swift run selftest ")[1]
        if let word = after.split(separator: " ").first { documented.insert(String(word)) }
    }

    let undocumented = registered.subtracting(documented).subtracting(["all"])
    t.expect(undocumented.isEmpty,
             "every suite is listed in CONTRIBUTING (missing: \(undocumented.sorted().joined(separator: ", ")))")

    let phantom = documented.subtracting(registered)
    t.expect(phantom.isEmpty,
             "CONTRIBUTING lists no suite that does not exist (extra: \(phantom.sorted().joined(separator: ", ")))")

    // Screenshots go stale silently: the UI moves on and an unreferenced image
    // sits in the repo showing labels that no longer exist. Three of them did.
    let shots = (try? FileManager.default.contentsOfDirectory(
        atPath: root.appending(path: "Resources/screenshots").path)) ?? []
    let prose = readme + contributing
        + read("docs/CLI.md") + read("docs/RUNTIMES.md")
        + read("docs/TROUBLESHOOTING.md") + read("docs/DESIGN.md")
    let orphans = shots.filter { $0.hasSuffix(".png") && !prose.contains($0) }.sorted()
    t.expect(orphans.isEmpty,
             "every screenshot is referenced by a document (unused: \(orphans.joined(separator: ", ")))")

    // Moving sections between documents duplicates paragraphs, and the copies
    // drift rather than staying identical — so exact matching misses them. Two
    // near-identical paragraphs about Setup survived a move into
    // docs/RUNTIMES.md, one directly under the other.
    //
    // One check per document, naming the worst pair: a check per paragraph
    // *pair* is hundreds of assertions that say nothing.
    func worstOverlap(_ doc: String) -> (Double, String) {
        let paras = doc.components(separatedBy: "\n\n")
            .map { Set($0.split(whereSeparator: \.isWhitespace).map(String.init)) }
            .filter { $0.count > 18 }
        var worst = (0.0, "")
        for i in paras.indices {
            for j in paras.indices where j > i {
                let ratio = Double(paras[i].intersection(paras[j]).count)
                    / Double(max(paras[i].count, paras[j].count))
                if ratio > worst.0 {
                    worst = (ratio, paras[i].sorted().prefix(6).joined(separator: " "))
                }
            }
        }
        return worst
    }
    for (name, doc) in [("README.md", readme), ("docs/RUNTIMES.md", read("docs/RUNTIMES.md")),
                        ("docs/CLI.md", read("docs/CLI.md")), ("CONTRIBUTING.md", contributing)] {
        let (ratio, sample) = worstOverlap(doc)
        t.expect(ratio < 0.8,
                 "\(name) has no paragraph said twice (worst overlap \(Int(ratio * 100))%: \(sample))")
    }
}

/// Small guarantees that are cheap to state and were not being kept.
func runHygieneTests(_ t: Harness) {
    t.suite("report and build hygiene")

    // The README invites people to redact the game name. It should not then
    // leak who they are through /Users/<name> in every path.
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let sample = """
    | Executable | `\(home)/Games/Thing/Thing.exe` |
    prefix: /private\(home)/Library/Application Support/Decanter/bottles/abc
    log line: could not open \(home)/Games/Thing/x.log
    """
    let red = Reporter.redactHome(sample)
    t.expect(!red.contains(home), "the home directory is gone from a report")
    t.expect(!red.contains("/private" + home), "…including its /private twin")
    t.equal(red.components(separatedBy: "~").count - 1, 3, "each occurrence became a tilde")
    t.expect(red.contains("Games/Thing/Thing.exe"), "the rest of the path is untouched")

    // A report from a source build has to be traceable to a commit.
    t.expect(!Build.commit.isEmpty, "the build records a commit")
    t.expect(Build.summary.contains(Build.version), "the summary names the version")
    t.expect(Build.summary.contains(Build.commit), "…and the commit")

    // Redaction must be safe on text that contains no paths at all.
    t.equal(Reporter.redactHome("nothing to redact"), "nothing to redact",
            "text without paths is unchanged")
    t.equal(Reporter.redactHome(""), "", "empty input is fine")
}

/// Two failure modes that reach the user as the same string, and one dated
/// assumption this codebase owns rather than inherits.
func runClassificationTests(_ t: Harness) {
    t.suite("failure classification")

    func findings(_ log: String) -> [Diagnostics.Finding] {
        let d = FileManager.default.temporaryDirectory
            .appending(path: "diag-\(UUID().uuidString).log")
        try? log.write(to: d, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: d) }
        return Diagnostics().analyse(logAt: d).findings
    }

    // The loader failure: a Windows API set Wine does not implement. Nothing
    // about graphics changes it.
    let loader = findings("""
    err:module:import_dll Library api-ms-win-core-winrt-robuffer-l1-1-0.dll not found
    Failed to load il2cpp
    """)
    t.expect(loader.contains(where: { if case .missingAPISet = $0 { true } else { false } }),
             "an api-ms-win-* import is classified as a missing API set")
    t.expect(!loader.contains(where: { if case .missingDLL = $0 { true } else { false } }),
             "…and not as an ordinary missing DLL, which sends people to install the wrong thing")

    // The renderer failure, from the same engine, reported the same way.
    let renderer = findings("""
    d3d11: CreateFence failed, ID3D11Fence not available
    Failed to load il2cpp
    """)
    t.expect(renderer.contains(where: { $0 == .d3d11FenceUnsupported }),
             "a failed fence creation is classified as a renderer gap")
    t.expect(!renderer.contains(where: { if case .missingAPISet = $0 { true } else { false } }),
             "…and is not confused with the loader failure")

    // An ordinary missing DLL must still be one.
    let plain = findings("err:module:import_dll Library MSVCP140.dll not found")
    t.expect(plain.contains(where: { if case .missingDLL = $0 { true } else { false } }),
             "a real missing DLL is still reported as one")

    // The remedies must differ, since that is the whole point of splitting them.
    let a = Diagnostics.Finding.missingAPISet("api-ms-win-core-winrt-robuffer-l1-1-0.dll")
    t.expect(a.suggestion.lowercased().contains("newer wine"), "the API-set remedy points at Wine")
    t.expect(!a.suggestion.lowercased().contains("dxmt"), "…not at a graphics layer")
    t.expect(Diagnostics.Finding.d3d11FenceUnsupported.suggestion.contains("DXMT"),
             "the fence remedy names the shape of the answer")

    // Rosetta: an assumption this codebase owns.
    t.equal(Engine.rosettaHorizon(majorVersion: 26), .fine(untilMajor: 27),
            "today's macOS is fine, with the horizon named")
    t.equal(Engine.rosettaHorizon(majorVersion: 27), .lastSupportedRelease,
            "macOS 27 is the last release with full Rosetta 2")
    t.equal(Engine.rosettaHorizon(majorVersion: 28), .removed,
            "macOS 28 removes it, and Wine is an x86_64 program")
}

/// Detection knowing something the interface never says is the same as not
/// knowing it. A Unity 6 game read as 6000.x, stored a blocker, and still
/// showed "Ready to play" with no warning anywhere in the app.
func runSurfacingTests(_ t: Harness) {
    t.suite("what detection knows reaches the user")

    let det = Detector()
    // A Unity 6 build, including a beta — 6000.2.0b7 is what turned up in the
    // wild, and a pattern expecting only `f` releases would miss it.
    for version in ["6000.0.58f2", "6000.2.0b7", "6000.3.1a4"] {
        let dir = Fixture.unity(name: "Sample", unityVersion: version)
        let r = det.detect(exe: dir.appending(path: "Sample.exe"))
        t.equal(r.engineVersion, version, "reads \(version) from the engine data")
        t.expect(r.knownUnsupported != nil, "\(version) is flagged as not known to run")
    }
    // …and an older Unity must not be flagged.
    let old = Fixture.unity(name: "Older", unityVersion: "2019.4.0f1")
    let r = det.detect(exe: old.appending(path: "Older.exe"))
    t.equal(r.engineVersion, "2019.4.0f1", "reads an older version too")
    t.expect(r.knownUnsupported == nil, "Unity 2019 is not flagged")

    // The status line lives in the app target and cannot be reached from here;
    // its behaviour is asserted by the same condition it reads, above.
    t.expect(r.knownUnsupported == nil, "an unflagged game leaves the status line alone")

}

/// Every one of these was a real log Decanter misread while testing a Unity 6
/// game. Three different failures, three different answers, and two of them
/// were being reported as something else entirely.
func runRealLogTests(_ t: Harness) {
    t.suite("logs from a real Unity 6 launch")

    func findings(_ log: String) -> [Diagnostics.Finding] {
        let u = FileManager.default.temporaryDirectory.appending(path: "d-\(UUID().uuidString).log")
        try? log.write(to: u, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: u) }
        return Diagnostics().analyse(logAt: u).findings
    }
    func has(_ fs: [Diagnostics.Finding], _ match: (Diagnostics.Finding) -> Bool) -> Bool {
        fs.contains(where: match)
    }

    // The two halves come from two logs, which is the point: Wine reports the
    // WinRT failure and never mentions the plugin; Unity reports the plugin and
    // never mentions WinRT. A diagnosis that read only one would name a symptom.
    let wine = findings("""
    0024:err:combase:RoGetActivationFactory Failed to find library for L"Windows.UI.ViewManagement.AccessibilitySettings"
    """)
    t.expect(has(wine) { if case .winrtClassUnavailable = $0 { true } else { false } },
             "Wine's log yields the WinRT activation failure")

    let player = Diagnostics().analysePlayerLog("""
    DllNotFoundException: AppUINativePlugin assembly:<unknown assembly>
    """)
    t.expect(has(player) { if case .nativePluginMissing = $0 { true } else { false } },
             "Unity's log yields the plugin that failed because of it")

    // Wine 11 + DXVK 3.0.2: DXVK will not start at all.
    let newDxvk = findings("""
    warn:  DXVK: No adapters found. Please check your device filter settings
    warn:  and Vulkan drivers. A Vulkan 1.3 capable setup is required.
    err:   Failed to initialize DXVK.
    """)
    t.expect(has(newDxvk) { $0 == .dxvkNeedsNewerVulkan },
             "DXVK refusing to initialise is recognised, not read as 'nothing wrong'")
    t.expect(Diagnostics.Finding.dxvkNeedsNewerVulkan.suggestion.contains("1.10.3"),
             "…and the remedy names the build that works")

    // Unity recovering from a degraded video path is not the failure.
    let recovered = Diagnostics().analysePlayerLog("""
    Dedicated video D3D11 device multithread protection failed (error: 0x80004002). Will use software video decoding.
    DllNotFoundException: SomePlugin
    """)
    t.expect(!has(recovered) { $0 == .videoNeedsMultithreadDevice },
             "a condition the engine recovered from is not reported as the failure")
    t.expect(has(recovered) { if case .nativePluginMissing = $0 { true } else { false } },
             "the real failure below it still is")

    // …but an unrecovered one still counts.
    let fatal = Diagnostics().analysePlayerLog("WindowsVideoMedia error 0x80004002 while reading video")
    t.expect(has(fatal) { $0 == .videoNeedsMultithreadDevice },
             "an unrecovered video failure is still reported")
}

/// The command reference is a table a person reads instead of running
/// `--help`, so it rots the moment a command is added. This makes that a test
/// failure rather than a bad first impression.
func runCLIDocsTests(_ t: Harness) {
    t.suite("the command reference matches the CLI")

    let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ name: String) -> String {
        (try? String(contentsOf: root.appending(path: name), encoding: .utf8)) ?? ""
    }
    let main = read("Sources/decanter/main.swift")
    let cli = read("docs/CLI.md")
    guard !main.isEmpty, !cli.isEmpty else {
        t.skip("CLI docs checks", "run from outside the source tree"); return
    }

    // Every `case "x":` in the dispatch switch is a verb a user can type.
    // Aliases and the help verbs are excluded: they exist for convenience and
    // documenting all of them would make the table worse, not better.
    let excluded: Set<String> = ["help", "--help", "-h", "version", "--version", "-v",
                                 "rm", "uninstall", "exes", "externalize", "locale"]
    var verbs: Set<String> = []
    for line in main.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("case \"") , trimmed.hasSuffix(":") else { continue }
        for part in trimmed.dropFirst(5).dropLast().components(separatedBy: ", ") {
            let v = part.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !v.isEmpty { verbs.insert(v) }
        }
    }
    verbs.subtract(excluded)
    t.expect(verbs.count > 20, "the dispatch table was actually parsed (found \(verbs.count))")

    // A verb counts as documented if it appears as a word inside some
    // `decanter ...` command in the table — which covers subcommands like
    // `decanter knowledge export` as well as top-level ones.
    //
    // The earlier check only looked for "decanter <verb>", so every nested verb
    // had to be excluded by hand, and a new one counted as documented the
    // moment somebody remembered to add it to that list. Several were also
    // passing by coincidence, because an unrelated top-level command happened
    // to share the name.
    var documentedWords = Set<String>()
    for span in cli.components(separatedBy: "`decanter ").dropFirst() {
        let command = span.components(separatedBy: "`").first ?? ""
        for word in command.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            documentedWords.insert(String(word))
        }
    }
    let undocumented = verbs.filter { !documentedWords.contains($0) }.sorted()
    t.expect(undocumented.isEmpty,
             "every command appears in docs/CLI.md (missing: \(undocumented.joined(separator: ", ")))")

    // And the other direction, which nothing checked. A document can go on
    // describing a command long after it is gone — SUPPORT.md pointed at a "★
    // option on the game page" for months after that badge stopped existing,
    // and no test had any way to notice. This catches the command half of that
    // class, which is the half that can be checked mechanically.
    let prose = ["README.md", "SUPPORT.md", "docs/TROUBLESHOOTING.md",
                 "docs/RUNTIMES.md", "docs/DESIGN.md", "CONTRIBUTING.md"]
    var invented: [String] = []
    // Words that follow `decanter ` but are options, placeholders or prose
    // rather than commands.
    func looksLikeAVerb(_ w: String) -> Bool {
        !w.isEmpty && !w.hasPrefix("-") && !w.hasPrefix("<")
            && w.allSatisfy { $0.isLetter } && w.lowercased() == w
    }
    for file in prose {
        let text = read(file)
        guard !text.isEmpty else { continue }
        for span in text.components(separatedBy: "decanter ").dropFirst() {
            let word = String(span.prefix { !$0.isWhitespace && $0 != "`" && $0 != "\n" })
            guard looksLikeAVerb(word), !verbs.contains(word) else { continue }
            // Subcommands are real too — they are matched against the same
            // dispatch table the CLI documentation check uses, plus the inner
            // words of any command CLI.md already spells out.
            guard !documentedWords.contains(word) else { continue }
            invented.append("\(file): decanter \(word)")
        }
    }
    t.expect(invented.isEmpty,
             "no document describes a command that does not exist (\(invented.prefix(4).joined(separator: "; ")))")

    // The README must not carry a second, drifting copy of the same table.
    let readme = read("README.md")
    t.expect(readme.contains("docs/CLI.md"),
             "the README points at the command reference rather than repeating it")
}

/// Markdown in stored copy renders only if the view asks for it.
///
/// `Text("**bold**")` parses Markdown because a string *literal* becomes a
/// LocalizedStringKey. `Text(someStoredString)` does not — it printed the
/// asterisks. Every explanation in this app is a stored constant, so any
/// constant containing Markdown has to reach a view that parses it.
func runMarkdownTests(_ t: Harness) {
    t.suite("markdown in stored copy is actually rendered")

    let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func read(_ name: String) -> String {
        (try? String(contentsOf: root.appending(path: name), encoding: .utf8)) ?? ""
    }
    let app = ["Help.swift", "Views.swift", "SetupView.swift", "SavesView.swift"]
        .map { read("Sources/DecanterApp/\($0)") }
    guard app.allSatisfy({ !$0.isEmpty }) else {
        t.skip("markdown checks", "run from outside the source tree"); return
    }
    let all = app.joined(separator: "\n")

    // The parsing view must exist and use the Markdown initialiser.
    t.expect(all.contains("struct Markdown: View"), "there is a view that parses stored Markdown")
    t.expect(all.contains("AttributedString(\n            markdown: text"),
             "and it parses rather than merely wrapping the string")

    // Anything handing a stored string to a popover must go through it.
    // Text(literal) is fine — SwiftUI parses those itself.
    for (name, source) in zip(["Help.swift", "Views.swift", "SetupView.swift", "SavesView.swift"], app) {
        for line in source.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            // A Text() whose argument is an identifier or interpolation, on a
            // line that also carries Markdown emphasis.
            guard l.contains("**") , l.hasPrefix("Text(") else { continue }
            t.expect(l.contains("Text(\""),
                     "\(name): Markdown reaches a parsing view, not Text(String) — \(l.prefix(60))")
        }
    }
}
