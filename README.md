# Decanter

**Run Windows games on your Apple Silicon Mac.**

Decanter manages Wine for you: it works out what a game needs, builds it an
isolated Windows environment, and picks the graphics translation most likely to
work — instead of leaving you to guess between five combinations and try each
one by hand.

It is a maintained alternative to [Whisky](https://github.com/Whisky-App/Whisky),
which was archived in 2025. When Whisky's bundled Wine repository was deleted,
installed copies could no longer finish setting themselves up. Decanter is built
so that cannot happen to it: it downloads nothing, and keeps its own copy of
every runtime it uses.

<!-- TODO: screenshot of the game detail view goes here -->

## What you get

- **A native Mac app and a full CLI**, sharing one engine. Either is enough on
  its own.
- **A recommendation, not a guessing game.** Decanter reads the game's engine,
  architecture and graphics API, combines that with what has already worked on
  your machine, and tells you which runtime and backend to use — and why.
- **Every game isolated.** Each one gets its own Windows environment, cloned
  instantly with APFS copy-on-write. No game can break another.
- **Your saves kept safe.** Saves are stored outside the Windows environment and
  linked back in, so rebuilding a broken game never destroys your progress.
  Snapshots on demand.
- **Games cannot read your files.** Unlike Whisky, no game gets a view of your
  whole Mac — just its own folder.
- **Real answers when something breaks.** One command produces a problem report
  with the runtime actually in use, the graphics layer actually loaded, an
  automatic diagnosis, and the relevant log lines.
- **Mod support.** BepInEx is detected and wired up automatically, with plugin
  status and loader errors surfaced in the app.

## Quick start

```sh
git clone https://github.com/ricardothesillyllama/Decanter.git
cd Decanter && ./install.sh
decanter pin && decanter template build     # one-time setup
decanter add ~/Games/SomeGame
decanter run SomeGame
```

Or open **Decanter.app** from `/Applications` and drag a game folder in.

You will need a Wine build and, ideally, Apple's Game Porting Toolkit — see
[Getting the pieces](#getting-the-pieces). Decanter does not download them for
you, on purpose.

## Requirements

- Apple Silicon Mac, macOS 14 or later
- **Xcode Command Line Tools** — `xcode-select --install`. Full Xcode is not needed.
- **Rosetta 2** — `softwareupdate --install-rosetta`. Wine's 32-bit support needs it.
- At least one Wine build, and ideally two (see below)

Decanter downloads nothing and bundles nothing. It never contacts the network at
all. You supply the runtimes; Decanter takes its own copy of each and manages
them. That is deliberate — Whisky died because the runtime it fetched at setup
time was deleted upstream, and installed copies could no longer finish setting
themselves up.

## Getting the pieces

**Game Porting Toolkit (GPTK)** gives you D3DMetal, Apple's Direct3D-to-Metal
translation, which is the fastest option for modern 3D games. Apple distributes
it from the [developer downloads](https://developer.apple.com/download/all/)
page (search "Game Porting Toolkit"; a free Apple ID is enough). It ships as a
disk image containing a Wine tree — point Decanter at it:

    decanter runtime add /path/to/Game\ Porting\ Toolkit/wine

**A mainline Wine build** covers everything GPTK cannot. GPTK is based on
Wine 7.7 from 2022, so newer titles often need something current. Any Apple
Silicon Wine build works — for example the casks published by
[Gcenx](https://github.com/Gcenx/homebrew-wine). Once installed anywhere on the
system:

    decanter pin        # finds every Wine build present and copies each into Decanter's store

**DXVK** translates Direct3D to Vulkan and is what most games want. Download a
release tarball from [doitsujin/dxvk](https://github.com/doitsujin/dxvk/releases)
and stage it:

    decanter dxvk stage ~/Downloads/dxvk-1.10.3.tar.gz

> **Get 1.10.3, not the newest.** DXVK 2.x and 3.x require Vulkan 1.3 features
> MoltenVK does not fully implement, so they fail on macOS in ways that look
> like game bugs. 1.10.3 targets Vulkan 1.1 and is the one that works here. You
> can stage several versions and switch per game with `decanter dxvk use`.

Neither runtime is redistributed by this project, and none of them are its work:
Wine is LGPL, DXVK is zlib-licensed, and GPTK is Apple's, under Apple's terms.

## Install

    ./install.sh

That builds in release mode, assembles `Decanter.app`, copies it to
`/Applications`, and puts the `decanter` CLI on your `PATH`. The app bundle is
assembled from `Resources/` at build time rather than kept in the repo, so a
fresh clone always produces a matching binary.

## Setup

    decanter pin                       # take our own copy of every Wine build found
    decanter runtime add <wine-root>   # pin a GPTK build from anywhere
    decanter dxvk stage dxvk-1.10.3.tar.gz
    decanter template build            # golden template, with DXVK baked in

## Use

    decanter add ~/Games/SomeGame      # folder or .exe; auto-detects
    decanter recommend SomeGame        # what should this game run on, and why
    decanter check SomeGame            # dry-run: would it launch?
    decanter run SomeGame
    decanter exes SomeGame             # list every .exe; pick a different one
    decanter diagnose SomeGame         # classify the last failure
    decanter import SomeGame ./saves   # restore saves + merge registry
    decanter rederive SomeGame

Run `decanter help` for the full list.

## Choosing a backend

Five runtime/backend combinations exist and guessing between them is miserable,
so Decanter decides from evidence and remembers the answer:

    decanter recommend <game> --apply   # apply without launching anything

Recommendations come from the game's own profile — engine, bitness, whether it
plays video, whether it references D3D12 — and from what has already worked on
this machine for games with the same profile. Confirmations are counted, never
named. Two rules were measured rather than guessed:

- **A game that plays video cannot use D3DMetal.** D3DMetal does not implement
  `ID3D11Multithread`, so video playback fails with `E_NOINTERFACE` while the
  rest of the game renders fine. Those games are routed to WineD3D.
- **32-bit games belong on mainline Wine.** GPTK's 2022 base has a less reliable
  WoW64 layer than Wine 11's.

## When a game runs but looks wrong

This is the hard case: nothing crashes, so the log is nearly empty and there is
nothing to hand to anyone.

    decanter run <game> --debug    # verbose D3D/DXGI/Vulkan/DXVK/MoltenVK logging
    decanter report <game>         # full problem report, copied to the clipboard

`report` collects the machine, the runtime and backend actually in use (not
merely the one configured), the DXVK build actually installed in the prefix,
whether Windows font names are mapped, detection evidence, an automatic
diagnosis, every graphics-related log line, and the log tail.

For a visual fault, take a screenshot yourself with Command-Shift-4, then Space,
then click the window. Decanter deliberately does not capture the screen, so it
never asks for Screen Recording permission.

The same flow is in the app under "Something looks wrong?", and on the
right-click menu of any game in the sidebar.

## Blank text, empty buttons

Wine on macOS registers your Mac's fonts but invents no aliases, so a game that
asks for a Windows-only face — MS PGothic, Segoe UI, SimSun — gets nothing back
and draws no text at all, while its layout still reserves the space. It looks
like a rendering bug, not a font one.

    decanter fonts --check    # what maps to what
    decanter fonts            # apply to every template and bottle

Japanese games are the usual casualty even when their text is English: a
translation patch replaces the strings, not the UI font. New bottles inherit the
mapping automatically.

## Leftover Wine processes

Wine's services outlive whatever started them and re-parent to `launchd`, so a
crashed or timed-out launch can leave a process spinning at full CPU
indefinitely. They are not applications, so they never appear in Force Quit, and
macOS bills their energy to Decanter even when Decanter is not running.

    decanter reap --list    # what is still alive, and for how long
    decanter reap           # end them

`decanter doctor` flags anything pinned at high CPU or running over an hour.

## Notes on save import

Two traps this handles, both of which fail silently otherwise:

1. Saves extracted from another prefix carry that prefix's Windows user
   (e.g. `users/crossover/`); paths are remapped to the destination's user.
2. Unity keeps PlayerPrefs in the **registry**, not in files. Wine's internal
   `user.reg` syntax is *not* importable `.reg` syntax — `regedit` exits 0 and
   imports nothing. Decanter converts it, and writes the staged file as
   UTF-16LE with a BOM so non-ASCII key names survive.

Saves are externalised out of the prefix and symlinked back in, so
`decanter rederive` can throw a prefix away without touching them.

## Signing, and why permissions reset

Ad-hoc signing makes an app's *designated requirement* the binary's own cdhash:

    designated => cdhash H"272e5501..."

Every rebuild changes that hash, so macOS treats the result as a different
application and forgets anything you granted it. Fix it once with a self-signed
identity, after which the requirement is based on the certificate rather than
the contents:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name it `Decanter Dev`, Identity Type *Self Signed Root*, Certificate Type
   *Code Signing*
3. Find it under "My Certificates", open it, expand **Trust**, and set
   *Code Signing* to **Always Trust**

`install.sh` uses that identity automatically when it exists and falls back to
ad-hoc otherwise.

> Releases here are **not** notarised, because that requires a paid Apple
> Developer account. A downloaded `.app` will be blocked by Gatekeeper on first
> open — allow it under System Settings → Privacy & Security. Building from
> source avoids this entirely, which is why that is the recommended path.

## Tests

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
    swift run selftest launch              # real Windows executables, 32- and 64-bit

XCTest ships with Xcode, not the Command Line Tools, and SwiftPM cannot see the
CLT copy of Testing.framework — so the harness is hand-rolled, in keeping with
the no-dependency rule. **244 checks.**

The launch suite is the interesting one: it clones the golden template into an
isolated root and launches Wine's own real PE binaries (`winemine.exe`, 32-bit
and 64-bit) through the full pipeline, then confirms via CoreGraphics that a
window with real dimensions actually appeared. A rendered window is the proof
the whole chain worked.

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

## Why it is built this way

**Runtimes are pinned, not borrowed.** Decanter copies each Wine build into its own
store (`~/Library/Application Support/Decanter/runtimes/`) via APFS clone. A Homebrew
upgrade, a cask conflict, or a deleted upstream release cannot break an installed game.
This is the exact failure that killed Whisky.

**Every game gets its own prefix.** Prefixes are cloned from one "golden" template with
APFS copy-on-write — measured at 335 MB in 0.46 s, costing no meaningful disk. Because
isolation is free, no game can break another through a conflicting dependency.

**Broken prefixes are re-derived, never repaired.** `decanter rederive <game>` throws the
prefix away and rebuilds it. Repair heuristics are the thing that rots.

**No `z: -> /`.** Whisky mapped the entire Mac filesystem into every bottle, so any
Windows binary could read `~/Documents`, `~/.ssh` and iCloud. Decanter grants a game its
own folder plus a shared games dir, and nothing else.

**Detection decides the runtime.** The binary's PE header gives bitness; sibling files
(`UnityPlayer.dll`, `GameAssembly.dll`, `package.nw`, `renpy/`, `.pck`, Unreal layout,
`BepInEx/`) give the engine; and a `.dxvk-cache` is treated as proof DXVK already worked.
Note that Unity and Unreal link `d3d12.dll` while rendering D3D11 — Decanter does not
fall for that.

**Backends are clamped to what the runtime can provide.** D3DMetal only exists inside
GPTK; storing it against a Wine runtime would silently mean no acceleration at all.

## Known limitations

- **Unity 6 (6000.x) does not work** on any runtime or backend currently
  available. Decanter detects it and says so rather than letting you guess.
- **DXMT** (Direct3D 11 straight to Metal) needs a Wine that exposes hidden
  `winemac.drv` symbols. No FOSS build currently does.
- Nothing is notarised; see above.

## Status

Verified working on an M2 MacBook Air, macOS 26.5.1, with Wine 11.0 and
GPTK 3.0-3 pinned side by side.

## License

GPL-3.0. See [LICENSE](LICENSE).

Decanter bundles no third-party code. Wine, DXVK and the Game Porting Toolkit
are separate works under their own licenses and are neither included nor
redistributed here.
