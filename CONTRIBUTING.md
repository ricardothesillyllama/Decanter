# Contributing

Thanks for looking. Decanter is a small project with a narrow purpose: run
Windows games on Apple Silicon macOS, reliably, without depending on anything
that can disappear.

## Reporting a game that does not work

This is the most useful contribution, and it needs no code.

1. Run `decanter recommend <game> --apply` first. It applies the configuration
   most likely to work without launching anything, and it resolves a good share
   of reports on its own.
2. If it still fails, run `decanter report <game>`. The report lands on your
   clipboard.
3. Open an issue using the **A game does not work** template and paste it.

**You may rename or redact the game.** The report is still useful without the
title — what matters is the engine, architecture, runtime, backend and log
lines. Decanter itself never records game names anywhere but your own library.

## Before opening a pull request

Run the suite. It is fast, and every one of these exists because something
broke:

    swift run -c release selftest          # everything
    swift run selftest unit                # detection, PE parsing, registry, path mapping
    swift run selftest abuse               # hostile input, corrupt state, sandbox escapes
    swift run selftest stress              # concurrency and large binaries
    swift run selftest saves               # discovery, externalising, snapshots
    swift run selftest schema              # state migration
    swift run selftest fonts               # font name mapping and registry writes
    swift run selftest dxvk                # identifying an unmarked DXVK build
    swift run selftest mods                # picking real failures out of a loader log
    swift run selftest reap                # stray Wine process parsing
    swift run selftest stop                # per-game stop must not kill other games
    swift run selftest noise               # logs must not be mistaken for saves
    swift run selftest explain             # mod failures in plain language
    swift run selftest verbs               # winetricks verb validation
    swift run selftest exes                # telling a game from a crash handler
    swift run selftest metal               # can a Wine build host DXMT
    swift run selftest fwd                 # state survives an older binary
    swift run selftest docs                # documentation matches the code, report redaction
    swift run selftest setup               # what a dropped file is, and what setup says is missing
    swift run selftest launch              # real Windows executables, 32- and 64-bit

XCTest ships with Xcode, not the Command Line Tools, and SwiftPM cannot see the
CLT copy of Testing.framework — so the harness is hand-rolled, in keeping with
the no-dependency rule. **420 checks.**

The launch suite also proves the font mapping end to end: it writes the
mapping into a real prefix, asks Wine to read it back through its own registry
parser, and confirms all of it survives a wineserver shutdown — which rewrites
the registry, and is where a malformed edit would quietly disappear. Testing
that Decanter can read what Decanter wrote proves nothing.

The launch suite is the interesting one: it clones the golden template into an
isolated root and launches Wine's own real PE binaries (`winemine.exe`, 32-bit
and 64-bit) through the full pipeline, then confirms via CoreGraphics that a
window with real dimensions actually appeared. A rendered window is the proof
the whole chain worked.

### Releasing

    ./install.sh              # build, sign, install locally
    ./scripts/make-dmg.sh     # dist/Decanter-<version>.dmg for a release
    ./scripts/make-demo.sh    # throwaway library of invented games, for screenshots

### Bugs these tests found

- **Adding one field silently wiped the library.** Swift's synthesised
  `Decodable` requires every non-optional key even when the property has a
  default, so a new field made every previously-saved record undecodable and the
  store fell back to empty. It happened twice before the decoding was
  hand-written and the failure made loud.
- **Lost update between concurrent writers.** The GUI and CLI are routinely open
  together; whichever wrote last silently discarded the other's changes. State
  mutation now takes an exclusive `flock` and re-reads from disk first.
- **A 220MB executable took 33 seconds to inspect.** The DLL-name scan
  lowercased a copy of the whole file, then made ten naive passes over it.
  Unity's `GameAssembly.dll` is routinely that size, so adding a big game looked
  like a hang. Now a single bounded pass with a flat 256-entry first-byte table:
  **0.13s**.
- **The test suite leaked Wine processes.** Each test shut its own bottle down,
  but a test that threw part-way skipped that — and Wine's services survive their
  parent, so the leak was permanent and invisible. Found only when a process that
  had been spinning at 100% CPU for six days turned up in a battery menu.
- **A recipe verb reached `sh -c` unquoted.** Verbs were interpolated into a
  shell string, so `decanter install X "vcrun; …"` ran whatever followed the
  semicolon. winetricks is now invoked with an argv array, and verbs are
  validated besides.
- **`[ErrorHandler]` is a plugin name, not an error.** Matching mod-loader logs
  on the word "error" flagged plugin names and config keys, and a log full of
  false positives gets ignored.
- **Two URLs for the same folder compared unequal.** `appending(path:)` on an
  existing directory flags it as one, so it renders as `…/mine/`, while
  `URL(filePath:)` on the identical string does not. Per-game stop therefore
  matched nothing, and the reaper's "spare these prefixes" guard protected
  nothing — it would have killed a running game it was told to leave alone.
  Path comparison now goes through one helper that normalises both this and
  `/var` versus `/private/var`.

## The rules this codebase actually holds to

These are not style preferences. Each one exists because breaking it caused a
real failure:

- **No external dependencies.** Every dependency is a future 404 — that is
  precisely how Whisky died. The test harness is hand-rolled for this reason.
- **Decode defensively.** Swift's synthesised `Decodable` requires every
  non-optional key even when the property has a default, so adding one field
  makes every previously-saved record undecodable. That silently wiped the
  library twice. Persisted types have hand-written `init(from:)` using
  `decodeIfPresent`. Keep it that way.
- **Never compare file URLs with `==`.** Use `url.pathKey`. Two URLs for the
  same folder compare unequal when one is directory-flagged, and `/var` and
  `/private/var` name the same file. This has bitten four times.
- **Prefixes are re-derived, never repaired.** Repair heuristics rot. If
  something is broken, throw the prefix away and clone a fresh one.
- **Do not widen a game's filesystem access.** No `z: -> /`, and no mapping
  Wine's user folders at the real home directory. `sandboxUserFolders` closes
  seventeen escape routes and preflight verifies them.
- **Nothing is downloaded at runtime**, and `check-rules.sh` fails the build if
  any networking API appears in the sources. One stated exception: the Windows
  Components feature runs winetricks, which fetches redistributables from their
  publishers — that is winetricks reaching out, not Decanter, and it is opt-in
  per component. Users supply Wine, GPTK and DXVK themselves; Decanter takes its
  own copy and manages it.

  This rule is about *servers*, not about typing. A file the user already has is
  not a dependency, so Setup accepts drops, opens download pages in the user's
  browser, and mounts a disk image they hand over. Making people use Terminal
  was never what kept the guarantee.
- **Never build a command as a string.** `Shell.run` takes an argv array for a
  reason — a verb interpolated into `sh -c` was a command-injection bug.

## Adding a test

The harness is in `Sources/selftest`. Each suite is a plain function taking a
`Harness`; register it in `main.swift`. Prefer a test that would have caught the
bug you just fixed, and say in the test's comment what the failure looked like —
several existing tests read as small incident reports, deliberately.

## Commit messages

Say what changed and why it was wrong before. "Fix bug" tells the next person
nothing; the interesting part is always the failure mode.
