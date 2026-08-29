import Foundation
import DecanterKit

/// A repair writes into a Wine build, so the things worth proving are the ones
/// that stop it doing harm: it does not act until it is told to, it does not
/// copy a file that cannot load, it does not leave the build broken in a new
/// way, and everything it did can be taken back.
func runRepairTests(_ t: Harness) {
    let fm = FileManager.default
    let clang = "/usr/bin/clang"
    guard fm.isExecutableFile(atPath: clang) else {
        t.suite("repairing a build from what is already here")
        t.skip("the repair suite", "no compiler, so no real binaries to reason about")
        return
    }

    let tmp = URL(filePath: NSTemporaryDirectory())
        .appending(path: "decanter-repair-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }

    /// Builds a real dylib, because the whole point is reading real load
    /// commands. A hand-written fixture would only prove the reader agrees
    /// with the writer.
    @discardableResult
    func dylib(_ path: URL, installName: String, links: [String] = [],
               arch: String = "x86_64") -> Bool {
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let src = tmp.appending(path: "src-\(UUID().uuidString).c")
        try? "int decanter_probe(void) { return 1; }\n".write(to: src, atomically: true, encoding: .utf8)
        var args = ["-arch", arch, "-dynamiclib", "-o", path.path, src.path,
                    "-install_name", installName, "-Wl,-rpath,@loader_path"]
        args.append(contentsOf: links)
        let r = try? Shell.run(URL(filePath: clang), args, timeout: 120)
        try? fm.removeItem(at: src)
        return r?.code == 0
    }
    func executable(_ path: URL, arch: String = "x86_64") -> Bool {
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let src = tmp.appending(path: "m-\(UUID().uuidString).c")
        try? "int main(void){return 0;}\n".write(to: src, atomically: true, encoding: .utf8)
        let r = try? Shell.run(URL(filePath: clang), ["-arch", arch, "-o", path.path, src.path], timeout: 120)
        try? fm.removeItem(at: src)
        return r?.code == 0
    }
    func spec(_ id: String, _ root: URL) -> RuntimeSpec {
        RuntimeSpec(id: id, kind: .wine, version: "1.0", root: root,
                    winePath: root.appending(path: "bin/wine"),
                    wineserverPath: nil, supports32Bit: false, backends: [])
    }

    // A build that is missing something, and a build that has it.
    let target = tmp.appending(path: "target")
    let donor = tmp.appending(path: "donor")
    let unix = target.appending(path: "lib/wine/x86_64-unix")
    guard executable(target.appending(path: "bin/wine")),
          executable(donor.appending(path: "bin/wine")),
          dylib(donor.appending(path: "lib/libleaf.dylib"), installName: "@rpath/libleaf.dylib"),
          dylib(donor.appending(path: "lib/libmid.dylib"), installName: "@rpath/libmid.dylib",
                links: [donor.appending(path: "lib/libleaf.dylib").path]),
          dylib(unix.appending(path: "asker.so"), installName: "asker.so",
                links: [donor.appending(path: "lib/libmid.dylib").path])
    else {
        t.suite("repairing a build from what is already here")
        t.skip("the repair suite", "the compiler would not produce the fixtures")
        return
    }
    let targetSpec = spec("target-1.0", target)
    let donorSpec = spec("donor-1.0", donor)
    let repair = RuntimeRepair()

    t.suite("what a build is missing, and where it can come from")
    let before = RuntimeAudit().audit(root: target)
    t.expect(!before.isSound, "the target is seen to be missing something")
    t.expect(before.hardGaps.contains { $0.library.contains("libmid") },
             "and it is named as the library the build actually asks for")

    let offer = repair.plan(for: targetSpec, donors: [targetSpec, donorSpec], audit: before)
    t.expect(!offer.isEmpty, "a plan is produced from a build that has the missing piece")

    t.suite("a plan closes, or it is not a repair")
    // The bug this replaces: copying a library out of its own directory orphans
    // it from its siblings. Six gaps were closed and three new ones opened, and
    // the build was left broken in a different way.
    t.expect(offer.borrows.contains { $0.library == "libmid.dylib" },
             "the missing library is in the plan")
    t.expect(offer.borrows.contains { $0.library == "libleaf.dylib" },
             "and so is the library that one will itself need once it is moved")
    t.equal(offer.borrows.count, 2, "with nothing else swept in")

    t.suite("describing is not doing")
    t.expect(!fm.fileExists(atPath: target.appending(path: "lib/libmid.dylib").path),
             "planning a repair copies nothing")
    t.expect(!offer.summary.isEmpty && !offer.undo.isEmpty,
             "and the plan says what it would do and how to take it back")
    t.expect(offer.summary.contains("Nothing is downloaded"),
             "and says outright that nothing is fetched from anywhere")
    let plainOffer = offer.summary.lowercased()
    t.expect(!["dylib", "@rpath", "mach-o", "symbol"].contains { plainOffer.contains($0) },
             "the offer is readable without knowing what any of this means")

    t.suite("only what was agreed to, and only once")
    let done = (try? repair.apply(offer, to: targetSpec)) ?? []
    t.equal(done.count, 2, "applying copies exactly what the plan named")
    let after = RuntimeAudit().audit(root: target)
    t.expect(after.isSound, "and the build is whole afterwards — no gap traded for another")

    // Applying the same plan again must not double up or overwrite.
    let stamp = try? fm.attributesOfItem(atPath: target.appending(path: "lib/libmid.dylib").path)[.modificationDate] as? Date
    let again = (try? repair.apply(offer, to: targetSpec)) ?? ["something"]
    t.equal(again.isEmpty, true, "applying it a second time changes nothing")
    let stamp2 = try? fm.attributesOfItem(atPath: target.appending(path: "lib/libmid.dylib").path)[.modificationDate] as? Date
    t.equal(stamp, stamp2, "and does not rewrite a file that is already there")

    t.suite("a repair can be taken back exactly")
    let bystander = target.appending(path: "lib/not-ours.dylib")
    fm.createFile(atPath: bystander.path, contents: Data("keep me".utf8))
    let removed = (try? repair.undo(targetSpec)) ?? []
    t.equal(removed.count, 2, "undo removes what was copied")
    t.expect(fm.fileExists(atPath: bystander.path),
             "and nothing that was already there")
    t.expect(!RuntimeAudit().audit(root: target).isSound,
             "the build is back in the state it was found in")
    t.equal((try? repair.undo(targetSpec))?.isEmpty, true,
            "undoing twice is not an error")

    t.suite("a library that cannot load is not offered")
    // Wine here is x86_64 under Rosetta. An arm64 library is the wrong kind of
    // file and fails silently — which is exactly why it has to be checked
    // rather than assumed from the name matching.
    let wrongArch = tmp.appending(path: "wrong")
    _ = executable(wrongArch.appending(path: "bin/wine"))
    _ = dylib(wrongArch.appending(path: "lib/libmid.dylib"),
              installName: "@rpath/libmid.dylib", arch: "arm64")
    let wrongSpec = spec("wrong-1.0", wrongArch)
    let refused = repair.plan(for: targetSpec, donors: [wrongSpec])
    t.expect(refused.borrows.isEmpty,
             "a donor built for the other architecture is not used")
    t.expect(refused.unfillable.contains { $0.library.contains("libmid") },
             "and the gap is reported as one nothing here can fill, not quietly dropped")
    t.expect(refused.summary.contains("Nothing on this Mac"),
             "which is said plainly rather than shown as an empty list")

    t.suite("Apple's own components are never taken")
    // Everything else the Game Porting Toolkit bundles is ordinary open source.
    // Apple's parts live in one directory, and Decanter simply never reaches
    // into it rather than judging licences file by file.
    let apple = tmp.appending(path: "apple")
    _ = executable(apple.appending(path: "bin/wine"))
    _ = dylib(apple.appending(path: "lib/external/libmid.dylib"), installName: "@rpath/libmid.dylib")
    let appleSpec = spec("gptk-7.7", apple)
    let fromApple = repair.plan(for: targetSpec, donors: [appleSpec])
    t.expect(fromApple.borrows.isEmpty,
             "a library sitting in lib/external is not borrowed, whatever it is")
    t.expect(fromApple.unfillable.contains { $0.library.contains("libmid") },
             "and the gap stays open rather than being filled from there")

    // The guard is a path comparison, and directory enumeration hands back
    // paths with symlinks already followed. A build reached through a linked
    // path compared a real path against a linked one and the guard stopped
    // guarding without saying so.
    let linked = tmp.appending(path: "apple-link")
    try? fm.createSymbolicLink(at: linked, withDestinationURL: apple)
    let linkedSpec = spec("gptk-7.7", linked)
    let viaLink = repair.plan(for: targetSpec, donors: [linkedSpec])
    t.expect(viaLink.borrows.isEmpty,
             "and it still holds when the build is reached through a symlink")
}
