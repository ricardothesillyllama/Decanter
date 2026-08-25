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
