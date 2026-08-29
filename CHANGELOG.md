# Changelog

## v0.5.5 — 2026-08-29

A game that had been unplayable for days turned out to be misconfigured rather
than unsupported, and every layer that should have caught it stayed quiet.

- **A game whose graphics option its runtime cannot provide is now refused, not
  launched.** Preflight already detected this and listed it among its problems —
  and then the launch went ahead regardless. Wine's own graphics loaded instead
  of the recorded ones, the game initialised, and it died with nothing in the
  log to find. Checking and then proceeding anyway is the same as not checking.
  Launch now stops, names what is wrong in plain words, and says what to change.
- **Blocking problems are distinguished from untidy ones.** A Windows user
  folder pointing outside the prefix is repaired in passing; a graphics option
  the environment cannot supply means the game cannot work. Only the second
  kind stops a launch.
- **A runtime that cannot host DXMT is no longer cloned into a DXMT host.**
  Switching a game to Metal graphics copied its runtime — 800 MB — installed
  DXMT into the copy, and only then reported that the copy could not host DXMT.
  DXMT resolves the Mac driver's entry points at the first frame, so a build
  whose driver is a bundle, or exports nothing, can carry every DXMT DLL and
  still never draw. The check now happens before the copy.

## v0.5.4 — 2026-08-29

- **Closing a stray drive is now recorded wherever it happens.** 0.5.3 removed
  every drive Decanter did not create, but only wrote down what it had closed on
  the launch path — and three paths build a launch plan, so a volume found by
  `check` was closed in silence. Doing the right thing and being able to say it
  was done are two halves of the same promise; both now hold.

## v0.5.3 — 2026-08-29

Eight defects, all found while writing down the rules the project actually runs
on rather than by using the app. Each was confirmed against the source or a real
log before it was fixed.

- **A missing font library was diagnosed as an architecture refusal.** The
  matcher keyed on the substring `wine cannot find`, which also begins Wine's
  message "Wine cannot find the FreeType font library." A 64-bit Unity game was
  therefore told its runtime had refused its architecture and to go and find
  32-bit support. The two messages mean entirely different things and are now
  matched separately, with a finding of their own for the real problem.
- **A prefix could see every mounted volume.** Removing `z: -> /` was never
  sufficient: `wineboot` maps a drive letter at every mounted volume and a raw
  `/dev/rdisk` node beside it, and nothing removed them. Measured on a real
  install, three prefixes each had doors onto two mounted images. Before every
  launch Decanter now removes every letter that is not `c:` and not a folder you
  granted, and records what it closed. The documented promise — a game sees its
  own folder and nothing else — is now true rather than nearly true.
- **Wine could not find libraries a runtime shipped.** Only the Game Porting
  Toolkit had its library directory on the fallback search path, so a Wine build
  carrying its own FreeType, GStreamer or FFmpeg could not load any of them —
  the library sat in `lib/` and Wine announced it could not be found. Every
  runtime's own `lib/` is now searchable.
- **A guess wore a measurement's badge.** The confidence field defaulted to
  `high`, so a recommendation derived purely from a static rule — nothing
  observed, nothing measured — claimed as much certainty as one confirmed twice
  on the same Mac. Only evidence raises it now.
- **A game you configured by hand kept being argued with.** `runtimeLocked` was
  written in two places and read in none, so the recommendation banner pushed
  back on a decision already made, forever. Choosing is not knowing, so an
  override still teaches the knowledge base nothing — but it does stop the app
  disagreeing with you about a game you have already solved.
- **A running game could be reported as having exited early.** Success required
  a window of at least 640x480, owned by a process matched on the executable's
  basename, within 45 seconds. A first launch compiling shaders, a game
  fullscreen on another Space, or one started through a proxy loader all failed
  that test while playing perfectly. The window can now also be matched by
  owner, and the wait is 120 seconds.
- **Applying a recommendation changed the label, not the environment.** It wrote
  the backend field directly instead of going through the one code path that
  installs DXVK or DXMT and writes the DXMT marker — the same
  says-one-thing-runs-another fault fixed for `runtime set` in 0.5.2.
- **An applied DXVK recommendation recorded no version.** It passed no version
  at all, while the knowledge base distinguishes DXVK 1.10.3 from 2.x precisely
  because they are not the same answer.

## v0.5.2 — 2026-08-28

- **Backends are listed in one order everywhere.** Each list was built by
  appending in whatever order the surrounding code happened to use, so the same
  options read "D3DMetal, DXVK, WineD3D" beside one runtime and "WineD3D, DXMT"
  beside the next — the best option printed below the worst. There is now a
  single ranking, best first: the two that reach Metal directly, then Vulkan
  through MoltenVK, then Wine's own translation, which is slow and always there.
  Lists are sorted rather than carefully appended, so adding a backend later
  cannot bring the inconsistency back.
- **Moving a game to another runtime no longer loses DXMT.** DXMT lives in the
  runtime and leaves only a marker in the prefix; `runtime set` rebuilt the
  prefix, kept the recorded backend, and never wrote the marker. The bottle then
  said DXMT while `check` said "Wine builtin D3D (DXMT missing!)" — the same
  says-one-thing-runs-another the DXVK path already guarded against.

## v0.5.1 — 2026-08-28

Everything here was found by using 0.5.0 rather than by reading it.

- **A crash-looping game can no longer wedge the Mac.** Wine launches
  `winedbg --auto` on every unhandled exception, so a game crashing in a loop
  spawns one debugger per crashing thread, each of which wants a console, fails
  to find a font, and crashes in turn. Measured once here: **773 winedbg
  processes**, two `conhost.exe` at 100% CPU, load average 38, and
  `decanter doctor` timing out at 120 seconds. New environments disable Wine's
  automatic debugger, so a crash nobody is attached to just ends.
- **The reaper can see them.** `winedbg` appears in `ps` as a bare name with no
  path and no drive letter, so neither of the tests that identify a Wine process
  matched it — the storm above was invisible to `doctor` and to `decanter stop`
  while it was happening. Bare Wine helpers now count as ours when their
  `WINEPREFIX` is one of ours, which leaves a separate Wine install untouched.
- **DXVK is not offered on a runtime that ships no MoltenVK.** DXVK needs Vulkan,
  and on macOS the only Vulkan is MoltenVK, which Wine builds carry inside
  themselves; `winevulkan.so` is the Wine half and is present either way. The
  Sikarugir build of Wine 10 has no MoltenVK, and DXVK on it fails with
  "Required Vulkan extension VK_KHR_surface not supported" — the same mistake as
  offering DXMT on a Wine that cannot present, which 0.5.0 fixed.
- **`decanter runtime remove <id>`** — there was no way to unpin a runtime.
  Refused while a game still uses it, and it takes the runtime's DXMT clone with
  it, which is what left two Wine 11s in the list with one of them unusable.
- **A state-clobbering race.** `refreshRuntimeCapabilities` built its list from
  the in-memory state *before* `mutate` took the lock and re-read from disk, then
  assigned that snapshot back — silently reverting whatever another process had
  written in between. The app runs it at launch, which is exactly when the CLI is
  most likely to have moved something.
- **Docs.** `README` said Unity 6 does not run, in three places. `docs/RUNTIMES.md`
  had no DXMT section at all, so the one path to Unity 6 was undocumented: it now
  names both conditions a Wine build must satisfy, the build that satisfies them,
  and the fact that it is not self-contained.

## v0.5.0 — 2026-08-27

### Unity 6 runs

A Unity 6 game rendering and playable on Apple Silicon, through DXMT on Metal:
`Direct3D 11.0 [level 11.1]`, `Renderer: Apple M2`. Every previous release said
this was impossible, and said so on measurements that were each individually
correct.

Two conditions have to hold at once, which is why it read as a dead end. Wine's
`winemac.so` must be a Mach-O **dylib** — DXMT's Metal bridge carries a hard
`LC_LOAD_DYLIB` on it and dyld refuses a bundle — **and** that same driver must
export `macdrv_functions`, which DXMT resolves with `dlsym` when it first wants
something to draw into. The Game Porting Toolkit exports it and ships a bundle.
Mainline Wine ships a dylib that exports nothing. Neither is enough alone, and
testing either condition on its own said "should work" about a build that could
not.

- **The Unity 6 verdict names the way through** instead of refusing everything.
  A Unity 6 game on DXMT is no longer warned about; on anything else it still is,
  with the driver requirement stated so the mainline-Wine dead end is not
  repeated.
- **The knowledge base seeds Unity 6 + DXMT as a success**, because it was
  watched working rather than inferred.
- **`GpuFence::Create(): Failed to create ID3D11Fence` was never the blocker.**
  It still fails, and Unity carries on regardless. A whole release was planned
  around reporting it upstream.

### Fixed

- **DXMT is no longer offered on a runtime that cannot draw.** The capability
  gate tested only whether Wine's Mac driver could be linked against, because a
  real `dlopen` succeeded — which proves loading, not presenting. Mainline Wine
  would load DXMT, reach a Direct3D 11 device at feature level 11_1, and then
  fail at the first frame with "your Wine has no exported symbols needed by
  DXMT". `doctor` now distinguishes the two refusals: a driver that is the wrong
  Mach-O type needs a different build, one that hides the symbols needs the same
  build compiled differently.

### Added

- **`decanter knowledge import <file>`** closes the loop that `export` opened.
  A situation this Mac already has an answer for is skipped rather than merged —
  counts are not exported, so a second row would be a duplicate, not weight, and
  a stranger cannot outvote what was seen here. Notes are dropped: an unsigned
  one cannot be attributed to anybody, and prose is the one field a game title
  could ride in on.
- **Disk space is measured before unpacking or copying**, not discovered part-way
  through. Running out mid-copy left a half-written runtime and an error from
  `tar` that named no cause.
- **Exit codes 0–6, documented in `docs/CLI.md`** and fixed as interface, so a
  script can branch on the kind of failure instead of matching message text.

## v0.4.3 — 2026-08-27

### First run stops being an errand

- **The Wine build Decanter links to can now actually be dropped into
  Decanter.** Those builds ship as `.tar.xz`, which was not in the list of
  archives `Acquisition` recognised, so the file at the end of Decanter's own
  download link fell through every branch and came back as "not something
  Decanter can use". The only route that worked was a Homebrew cask — a
  Terminal command, in the app that exists to remove Terminal commands. Wine
  archives are now unpacked and searched the same way a disk image already was.
- **The download link points at the downloads.** It pointed at the Homebrew
  tap, whose front page is a README of shell commands and no file; it now
  points at the releases page, and the row names the file to click.
- **Only the required pieces are numbered.** Rosetta, Wine and the template are
  the whole path to a running game; the three graphics layers are a choice a
  game asks for later. Numbering all six turned a first run into a six-item
  errand across four websites. They now sit under "Graphics — optional".
- **A folder can be dropped instead of a file.** Decanter takes everything it
  recognises inside it, runtimes before graphics layers, and one piece failing
  no longer discards the ones that worked. The CLI gets this too.
- **A working setup no longer wears a warning.** The sidebar painted its footer
  amber whenever any *optional* piece was missing, so the only way to clear it
  was to fetch three graphics layers you might have no use for.

### Fixed

- `scripts/bump.sh` ran arithmetic on `CFBundleVersion`, which stopped working
  once that key held a dotted version rather than a build number. It exited
  half-done — one key rewritten, no changelog entry — so every release since
  has been bumped by hand.
- A tag's source now carries the version it is tagged as. `install.sh` stamps
  the version constant *after* a release is cut, so v0.4.2's `Model.swift` said
  `0.4.1` and a build from that tag misreported itself.

## v0.4.2 — 2026-08-27

- **The build is green again.** CI compiles with `-warnings-as-errors` and a
  plain `swift build` does not, so a discarded `Set.insert` return value was
  invisible locally and red the moment it was pushed — which is how both 0.4.0
  and 0.4.1 shipped with a failing pipeline.
- `STRICT=1 ./scripts/check-rules.sh` now builds the way CI builds, so that gap
  can be closed before a push rather than discovered after one.

## v0.4.1 — 2026-08-27

- **An older binary no longer opens on an empty library.** Shipping DXMT wrote
  `"dxmt"` into `state.json`, and a 0.3.1 app — which has no such case — threw
  while decoding `runtimes`, so it showed no runtimes and no games beside a CLI
  that could see everything. The store already preserved unknown *keys*; an
  unknown *enum case* is just as breaking and was not guarded against.
  `RuntimeSpec` and `Bottle` now set an unrecognised backend name aside and
  write it back out untouched, so passing through a binary that cannot use it
  costs nothing. A bottle falls back to WineD3D — which every runtime can
  provide — while still recording what it really was.
- `decanter run --debug` now turns DXMT's own logging on alongside DXVK's and
  MoltenVK's. DXMT names the exact failure ("Failed to create mach port for
  shared fence" and four siblings) and says nothing at all when left at `none`,
  which made troubleshooting a DXMT game guesswork.

## v0.4.0 — 2026-08-27

### DXMT, and a much more honest answer about Unity 6

- **Decanter can now use DXMT**, a fourth graphics layer that translates
  Direct3D 11 straight to Metal. Hand it a DXMT build the way you hand it
  DXVK — `decanter dxmt stage <archive>`, or drop it on the window.
- **Which Wine builds can host it is measured, not assumed.** DXMT's Metal
  bridge hard-links `@rpath/winemac.so` as a dylib. Mainline Wine 11 ships one;
  the Game Porting Toolkit ships a Mach-O *bundle*, which macOS refuses to link
  against at all. Decanter reads the file's type and only offers DXMT where it
  can actually load — with the reason attached when it cannot.
- **DXMT gets its own copy of the runtime.** It has to be installed as a Wine
  builtin, which is global to a runtime, and `=b` is what WineD3D games use too
  — so baking it into a shared runtime would silently switch them onto it. The
  copy is an APFS clone: near-zero bytes, about a second.
- **Unity 6 now says what actually happens.** Measured on an M2 against a real
  6000.2 build: DXVK on MoltenVK fails device creation at *every* feature level
  down to 10_0; WineD3D cannot create a device; D3DMetal has no ID3D11Fence,
  no ID3D11Multithread and no D3D11On12. DXMT gets a real device at feature
  level 11_1 — the only layer here that does — and Unity then fails
  `GpuFence::Create` because DXMT has no ID3D11Fence either. **Unity 6 still
  does not run.** It is closer, and Decanter can now tell you exactly how far
  it gets and where it stops.
- **D3D12 is inferred from what shipped, not from what linked.** Every Unity 6
  build imports `d3d12.dll` whether or not it ever creates a D3D12 device, so
  the import dates the engine rather than describing the renderer. Unity only
  ships the DirectX 12 Agility SDK beside the game when D3D12 is really in the
  renderer list, and that is what Decanter reads now.

### The knowledge base keys on a situation, not a game

- **What gets remembered is circumstances and outcomes**: engine and generation,
  bitness, video, D3D12, chip family, macOS major — plus what was tried and what
  happened. "Unity 6 on an M2 under Wine 11 with DXMT 0.80 fails to create an
  ID3D11Fence" is complete and useful; the title of the game adds nothing you
  can act on, so no title is recorded anywhere.
- **That guarantee is now mechanical.** Every field of a situation is an enum, a
  bool or a bounded integer, and `check-rules.sh` fails the build if a
  free-form one appears — a field rich enough to distinguish a game *is* a name,
  and one anybody with a copy could recompute.
- **Answers say how closely they matched.** Adding machine detail makes exact
  matches rare, so observations are stored at full specificity and *queried*
  from most specific to least: this Mac, this chip, any Mac, games of this
  shape, this engine generation, this engine. The level that answered is
  reported, because a suggestion drawn from "this engine, any Mac" is a weaker
  claim than one from an identical machine.
- **Failures are knowledge too.** Decanter now records what did not work and why,
  and a specific failure outranks a general success — which is what stops Unity 6
  falling through to "Unity games work on D3DMetal", true in general and measured
  to be false for Unity 6.
- **`decanter knowledge export`** writes the observations out to hand over.
  There is no option to include a game name, because there is no field for one.
- **`decanter knowledge explain <game>`** shows the ladder for one game: what
  matched at each level, what is recommended, and what is known to fail.
- Knowledge written by earlier versions is carried across rather than discarded,
  with the machine left unknown rather than invented.

### Fixes

- A runtime pinned before a backend existed kept claiming it could not do
  something it could; capability is now re-read from the files on disk.
- DXVK and DXMT both replace `d3d11.dll`, so a prefix could report the wrong
  one. They are now told apart.
- The CLI documentation check only looked for top-level verbs, so every
  subcommand had to be excused by hand and two were passing by coincidence. It
  now verifies words inside documented commands; the exclusion list went from
  eighteen entries to five.

## v0.3.1 — 2026-08-26

- **A released version can no longer be quietly overwritten.** Rulesets on the
  repository refuse to move or delete `main` or any `v*` tag, so a published
  release is fixed. `check-rules.sh` now fails if anything under `Sources/`
  differs from the tag for the version in `Info.plist` — otherwise the DMG
  people download stops matching the tree they are reading.
- **`./scripts/bump.sh`** moves the version on and opens a changelog entry.
  `Info.plist` stays the single source of truth; `install.sh` rewrites the
  constant in `Model.swift` from it.
- Plugins with no bytes rendered as "Zero KB", which reads as a bug rather than
  as a fact about the file.
- **Decanter no longer claims a Game Porting Toolkit version Apple never
  shipped.** `wine --version` reports `wine-7.7 (Game Porting Toolkit 1.1)`, and
  only the leading token is safe in a directory name — so the number Decanter
  records is the *Wine* version inside the toolkit. It now reads "Game Porting
  Toolkit (Wine 7.7)" rather than "Game Porting Toolkit 7.7".
- **Documentation fixes found by reading it rather than writing it.** Moving
  sections into `docs/` left two near-identical paragraphs about Setup one under
  the other, a second copy of the "downloads nothing" paragraph, a "(see below)"
  pointing at material now above it, and a Rosetta note splitting a bullet list
  in half. `docs/RUNTIMES.md` is rewritten as one document. A test now fails on
  any two paragraphs in a document that overlap by more than 80%, which catches
  reworded copies that exact matching misses.

## v0.3.0 — 2026-08-26

Setup used to take six Terminal commands. It now takes none — without Decanter
downloading anything, which is the guarantee the whole project rests on.

The rule was never "the user must type". It is "nothing here depends on a
server still existing", because Whisky's installed copies broke when the
runtime it fetched was deleted upstream. A file you already have on disk is not
a dependency, so Decanter now accepts one however you hand it over.

### Setup without Terminal

- **A Setup page**, permanent in the sidebar rather than a modal you see once.
  It lists every piece Decanter needs, whether it is present, what it is for in
  one plain sentence, and where the missing ones come from.
- **Drop anything on the window.** A Wine folder, a Wine `.app`, Apple's Game
  Porting Toolkit as a `.dmg`, or a DXVK `.tar.gz`. Decanter identifies it by
  looking inside — a Wine build is "a directory with a `bin/wine` in it",
  whatever it has been named — mounts a disk image if it is one, takes what it
  needs, and ejects it.
- **A first-run wizard** with the same rows, and the sentence explaining why any
  of this is being asked of you. Dismissable, and it does not come back.
- **`decanter setup` and `decanter use <file>`** do the same from the CLI, from
  the same code, so the two surfaces cannot disagree about whether this Mac is
  ready. `decanter runtime add` now accepts a disk image too.
- **Downloading nothing is now a rule the build enforces.** `check-rules.sh`
  fails if any networking API appears in the sources. Links on the Setup page
  open in your browser; Decanter itself makes no request.

### Saying what things are, not how good they are

- **Graphics options are Apple, Vulkan and Wine**, with `D3DMetal`, `DXVK` and
  `WineD3D` beside them. They were Apple, Standard and Compatibility, and the
  last two were quiet promises: "Compatibility" reads as the safe choice a
  stuck person should move to, when WineD3D is the slow fallback and a modern
  game may well do better on Apple's. Compatibility is not a slider with one
  backend at the top — it is per-game, which is the entire reason Decanter
  recommends instead of ranking.
- **The recommendation is a badge beside the name**, never baked into it, so
  Decanter can point at a different option per game without any name implying
  it was second-best.
- **Each option says when you would reach for it** — "Try if the game will not
  start, or draws nothing" — rather than claiming a rank.
- **"Engine" now means Unity and Unreal only.** It was also the label on the
  Wine runtime picker, in the same window. That control is "Runs on", and names
  the builds directly rather than inventing a category word. It was nearly
  "Windows version", which is simply false: both provide the same Windows APIs.
- **Advanced carries the same weight as every other section header.** It was set
  in small secondary text, which reads as a footnote rather than a place to go —
  hiding the one control someone who *does* know Wine came for.

### Two audiences on one screen

- **Every Setup row has a question mark** with the exact project, the exact
  version, and the constraint that matters — `DXVK 1.10.3 · targets Vulkan 1.1.
  2.x/3.x need Vulkan 1.3, which MoltenVK does not fully implement`. The plain
  sentence stays jargon-free and is tested for it; the technical line is one
  click away and selectable.
- **Outstanding pieces are numbered**, in the order they appear. The first
  attempt numbered required ones first, which read 1, 3, 4, 2 down the page.
- **Two columns when the window has room**, since this page has no inspector.

### Fixes

- **Markdown in stored copy was never rendered.** `Text("**bold**")` parses
  because a string *literal* becomes a `LocalizedStringKey`; `Text(storedString)`
  does not. Every explanation in this app is a stored constant, so every popover
  had been printing its asterisks.
- **Build It was offered for the golden template with no runtime pinned** — an
  action whose only possible outcome was an error.
- **The sidebar showed a green dot beside "Not ready yet"**, because it reported
  Rosetta alone rather than overall readiness.
- **The inspector toggle appeared on pages with nothing to inspect.**
- **Mods was titled twice**, four lines apart.
- **Plugins with no bytes rendered as "Zero KB".**

### Repo

- README rebuilt around the first thirty seconds: hero, badges, three-step
  install, then what you get. The command reference, runtime guide and
  requirements moved into `docs/`.
- **`docs/CLI.md` cannot drift** — a test reads the CLI's dispatch switch and
  fails if a command is missing from the table.
- The CI badge's check count is generated by `sync-docs.sh` like every other
  figure, and a test fails if it disagrees with the prose.
- Issue forms, `SUPPORT.md`, release-note categories, dependabot for the
  workflow's actions, CODEOWNERS, and Discussions.

## v0.2.0 — 2026-08-25

First public release. The app was rebuilt around one idea: the page should read
as a sentence and a button, and everything else should earn its place by being
asked for.

### The app

- **Plain language on the main path.** Graphics modes are Apple, Standard and
  Compatibility; D3DMetal, DXVK and WineD3D are a click away under Advanced,
  because someone following a forum thread still needs to recognise them.
- **Progressive disclosure.** Graphics, Mods, Saves & Maintenance, Windows
  Components and Activity are collapsed until wanted, and open themselves when
  something is wrong.
- **Every action reports what it did**, and an Activity log keeps the last 50
  with durations and full error text, so "what have I already tried?" is
  answerable.
- **Stop a running game.** A hung Windows game cannot be quit from its own
  window and Force Quit does not list it, so there was no recovery short of
  killing every Wine process on the machine.
- **Windows Components** installs a Visual C++ runtime, codecs, a shader
  compiler or .NET when a game names one. Opt-in per component: installing
  everything up front is how a Windows environment goes wrong.
- **Report a Problem** copies a full report and opens a prefilled issue.
- **Mod failures in plain language**, with the exact log line kept underneath.
- **Windows Environments** replaces the per-game Bottles list, which showed the
  same settings twice.

### Distribution

- Ships as a **disk image**. Drag it into Applications.
- Release binaries no longer embed the builder's home directory.

### Fixed

- **A command injection.** Recipe verbs were interpolated into a `sh -c`
  string, so `decanter install X "vcrun; …"` ran what followed the semicolon.
- Two URLs for the same folder compared unequal when one was directory-flagged,
  so per-game stop matched nothing and the reaper's "spare these" guard
  protected nothing.
- The running indicator flicked back to Play a second after launch, because the
  watcher read "Wine has not started yet" as "already exited".
- The executable picker announced "only executable in this folder" before it had
  looked, and got stuck when you switched games.
- Logs were listed as save files, which made a safe rebuild look destructive.
- Unmarked DXVK builds reported `DXVK ?` in every problem report.
- Diagnose did nothing visible when the log was clean or absent.

### Tests

**328 checks.** The launch suite proves the font mapping end to end: it writes
the mapping into a real prefix, has Wine read it back through its own parser,
and confirms all of it survives a wineserver shutdown.

### Known limitations

- Unity 6 (6000.x) does not work on any available runtime or backend.
- Releases are not notarised — no paid Apple Developer account — so the first
  launch needs System Settings ▸ Privacy & Security.

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
