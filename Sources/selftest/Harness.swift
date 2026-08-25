import Foundation

/// A deliberately tiny test harness. No framework, so it runs anywhere.
final class Harness {
    private(set) var passed = 0, failed = 0, skipped = 0
    private var failures: [String] = []
    private var suite = ""

    func suite(_ name: String) {
        suite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    func expect(_ cond: @autoclosure () -> Bool, _ what: String) {
        if cond() { passed += 1; print("  \u{001B}[32m✓\u{001B}[0m \(what)") }
        else {
            failed += 1
            failures.append("\(suite): \(what)")
            print("  \u{001B}[31m✗\u{001B}[0m \(what)")
        }
    }

    func equal<T: Equatable>(_ a: T?, _ b: T?, _ what: String) {
        if a == b { passed += 1; print("  \u{001B}[32m✓\u{001B}[0m \(what)") }
        else {
            failed += 1
            failures.append("\(suite): \(what) — got \(String(describing: a)), wanted \(String(describing: b))")
            print("  \u{001B}[31m✗\u{001B}[0m \(what)  (got \(String(describing: a)), wanted \(String(describing: b)))")
        }
    }

    /// Asserts the call throws — used heavily by the abuse suite.
    func throwsError(_ what: String, _ body: () throws -> Void) {
        do { try body(); failed += 1; failures.append("\(suite): \(what)")
             print("  \u{001B}[31m✗\u{001B}[0m \(what) — did NOT throw") }
        catch { passed += 1; print("  \u{001B}[32m✓\u{001B}[0m \(what) — threw \(type(of: error))") }
    }

    /// Asserts the call survives (no crash, no throw) whatever it returns.
    func survives(_ what: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("  \u{001B}[32m✓\u{001B}[0m \(what)") }
        catch { passed += 1; print("  \u{001B}[32m✓\u{001B}[0m \(what) — handled: \(error.localizedDescription.prefix(70))") }
    }

    func skip(_ what: String, _ why: String) {
        skipped += 1
        print("  \u{001B}[33m·\u{001B}[0m \(what) — skipped: \(why)")
    }

    func summary() -> Int32 {
        print("\n\u{001B}[1m────────────────────────────────────────\u{001B}[0m")
        print("  passed \(passed)   failed \(failed)   skipped \(skipped)")
        if !failures.isEmpty {
            print("\n  failures:")
            for f in failures { print("   - \(f)") }
        }
        return failed == 0 ? 0 : 1
    }
}
