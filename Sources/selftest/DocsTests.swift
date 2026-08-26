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
