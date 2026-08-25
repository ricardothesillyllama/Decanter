# Changelog

## v0.1.1 — 2026-08-25

Feedback and recovery. Actions used to be fire-and-forget: the pane went
quietly disabled while something ran, with no sign of which one was in
flight, no result, and any error gone the moment the next thing happened.

- Every action shows its own progress, says what it is for, and reports what
  it did.
- **Activity panel** keeping the last 50 actions with durations and full
  error text, so "what have I already tried?" is answerable.
- **Stop** a running game. A hung Windows game cannot be quit from its own
  window and Force Quit does not list it — Wine processes are not
  applications — so the only recovery was killing every Wine session at once.
- The **executable picker no longer disappears**. Switching the chosen .exe
  cleared its cache and nothing re-scanned it, so the control vanished until
  you navigated away and back. It now shows what it is doing instead.
- **A second game in the same folder** can be added as its own library entry,
  with its own prefix. On request only: Decanter cannot tell a game from a
  config tool or a crash handler, and guessing would fill the library with
  junk. Adding the same executable twice is refused.
- **Unmarked DXVK builds are identified** by matching the installed
  `d3d11.dll` against staged versions, instead of reporting `DXVK ?` in every
  problem report.
- **Mod loader failures are surfaced** from BepInEx's own log, which is the
  only place a broken plugin explains itself.

### Fixed

- Two URLs naming the same folder compared unequal when one was
  directory-flagged. Per-game stop matched nothing, and the reaper's "spare
  these prefixes" guard protected nothing — it would have killed a running
  game it was told to leave alone.
- Release binaries embedded the builder's home directory, and so their
  username, in debug info. `strings` does not surface it.
- `install.sh` signed the installed copy after copying, leaving the bundle it
  built unsigned and carrying the wrong identifier.

244 checks.

## v0.1.0 — 2026-08-25

First tagged build. Runs Windows games on Apple Silicon macOS via Wine, with a
CLI and a native SwiftUI app over one shared engine.

### Core

- **Pinned runtimes.** Every Wine build is copied into Decanter's own store
  rather than referenced in place, so a Homebrew upgrade or a deleted upstream
  release cannot break an installed game.
- **Per-game prefixes** cloned from a golden template with APFS copy-on-write —
  335 MB in 0.46 s — so isolation costs nothing and no game can break another.
- **Re-derive, never repair.** `decanter rederive` throws a broken prefix away
  and rebuilds it. Saves are externalised and symlinked back in, so a rebuild
  keeps them.
- **No `z: → /`.** A game gets its own folder and a shared games directory.
  Seventeen further escape routes through Wine's mapped user folders are closed
  and verified on every launch.
- **Detection-first.** The PE header gives bitness; sibling files give the
  engine; the executable picker knows Unity's `<Name>_Data` convention and
  Unreal's packaged layout, so it does not pick a config tool or an inner
  binary that cannot find its own `.uproject`.

### Choosing a configuration

- `decanter recommend --apply` picks a runtime and backend from the game's
  profile plus what has already worked on this machine, and applies it without
  launching anything. Confirmations are counted, never named.
- Two rules established by measurement: a game that plays video cannot use
  D3DMetal (no `ID3D11Multithread`, video fails with `E_NOINTERFACE`), and
  32-bit games belong on mainline Wine rather than GPTK's 2022 base.

### Diagnosis

- `decanter report` bundles the machine, the runtime and backend actually in
  use, the DXVK build actually present, font mapping status, detection
  evidence, an automatic diagnosis, and every graphics-related log line.
- `decanter fonts` maps Windows-only font names (MS PGothic, Segoe UI, SimSun)
  onto faces macOS has. Without it, games asking for them draw no text at all
  while their layout still reserves the space.
- `decanter reap` finds and ends Wine processes left running by an earlier
  session. They re-parent to `launchd`, never appear in Force Quit, and macOS
  bills their energy to Decanter even when it is not running.
- BepInEx status, plugin list, and — most usefully — the failures pulled out of
  the mod loader's own log, which is the only place a broken plugin explains
  itself.

### Known limitations

- Unity 6 (6000.x) does not work on any available runtime or backend. Decanter
  detects it and says so rather than letting you guess.
- DXMT needs a Wine exposing hidden `winemac.drv` symbols; no FOSS build does.
- Releases are not notarised — no paid Apple Developer account. Build from
  source, or allow the app under System Settings → Privacy & Security.

### Tests

238 checks in a hand-rolled harness (XCTest ships with Xcode, not the Command
Line Tools). The launch suite runs Wine's own 32- and 64-bit PE binaries through
the full pipeline and confirms via CoreGraphics that a real window appeared.
