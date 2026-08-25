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

Run the suite. It is fast and it has caught real bugs:

```sh
swift run -c release selftest
```

The launch tests need a pinned runtime and a built template; they skip cleanly
without one, so a first run on a fresh machine will show fewer checks.

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
- **Nothing is downloaded at runtime.** Users supply Wine, GPTK and DXVK.
  Decanter takes its own copy and manages it.

## Adding a test

The harness is in `Sources/selftest`. Each suite is a plain function taking a
`Harness`; register it in `main.swift`. Prefer a test that would have caught the
bug you just fixed, and say in the test's comment what the failure looked like —
several existing tests read as small incident reports, deliberately.

## Commit messages

Say what changed and why it was wrong before. "Fix bug" tells the next person
nothing; the interesting part is always the failure mode.
