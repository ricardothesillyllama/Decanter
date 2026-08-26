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
