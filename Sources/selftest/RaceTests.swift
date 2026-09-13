import Foundation
import DecanterKit

/// The shape of concurrency the app actually has, compressed.
///
/// The app runs every action as a detached task that writes the library
/// through `Store.mutate`, while its main thread re-reads the library through
/// `Store.refresh` on every activation and reads `store.state` to draw. The
/// file lock serialises one write against another; nothing serialises a write
/// against a read inside the same process. The engine's `knowledge` is also a
/// `lazy var`, and first use from two threads at once is not safe.
///
/// Not part of `all`: without the thread sanitizer it proves nothing when it
/// passes, and a real race can crash the run. Build with
/// `swift build --sanitize=thread --product selftest`, then `selftest race`.
func runRaceTests(_ t: Harness) {
    t.suite("The library is read while it is written, the way the app does it")
    let root = Fixture.dir("race-root")
    guard let e = try? Engine(paths: Paths(root: root)) else {
        t.expect(false, "an engine can be made"); return
    }
    let group = DispatchGroup()
    let q = DispatchQueue(label: "decanter.race", attributes: .concurrent)
    for i in 0..<120 {
        q.async(group: group) {
            try? e.store.mutate { s in
                s.games.append(Game(name: "g\(i)", exePath: root.appending(path: "g\(i).exe"),
                                    bottleID: UUID(), detection: DetectionResult()))
            }
        }
        q.async(group: group) { e.store.refresh(); _ = e.store.state.games.count }
        q.async(group: group) { _ = e.knowledge.observations.count }
    }
    group.wait()
    t.expect(true, "the run finished — the sanitizer's report, not this line, is the result")
}
