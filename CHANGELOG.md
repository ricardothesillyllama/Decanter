# Changelog

## v0.8.3 — 2026-09-01

An adversarial pass over every surface, and the fixes it turned up. The theme
running through most of them is one fault: **Decanter knew something and did
not say it.**

**Diagnose reported "nothing wrong found in the last run's log" over a log
whose only line was a failure.** Wine's most ordinary refusal —

    wine: failed to open "H:\game.exe": c0000135

— matched no rule at all, so the report came back clean, with a green tick on
it. There is now a rule for it, and the NT status is decoded rather than
repeated: `c0000135` means something the game needs to run is missing,
`c000007b` means it and a library beside it are built for different
architectures, `c0000034` means the file has moved. An unrecognised code is
reported as unrecognised instead of guessed at. Wine's chatter about modules is
checked *after* this now, because when the executable itself is refused every
line below it is a consequence.

**A game whose files had been deleted said "Ready to play".** Green dot, live
Play button, and Re-inspect returned success on it — detection has no rule that
fails on a file that is not there, so every rule simply did not match and the
result came back "Unknown engine" with a tick. The library is now checked
against the disk on every refresh, the sidebar row says *files missing*, the
status line says *Its files are missing*, and re-inspecting a game that is not
there is an error rather than a success.

**A kernel anti-cheat was detected at the moment a game was added and mentioned
nowhere.** Decanter has found Easy Anti-Cheat and BattlEye by name since they
shipped, and `preflight` calls it the one blocker no change can lift — but that
only ran if somebody went looking in Diagnose. Until then the page said the
game was ready. It now says, in front of everything else, that the game uses a
Windows kernel driver, that there is no Windows kernel here to load it into,
and that no Wine build, graphics layer or setting will start it.

These two share a new card and a new rank above every other concern. Asking
somebody how last night's launch went is the wrong question to put to a person
whose game is no longer on the disk.

**A failed launch showed "Running" for forty-five seconds.** The watcher waited
for a process to appear before it would conclude anything, and waited out the
full timeout even when the log had already said, in its first line and within a
second, that the game was refused. It now reads the log while it waits and
stops as soon as it finds a refusal. The button also says **Starting…** until a
process actually exists, because "Running" was a claim Decanter could not
support for the first few seconds and could not support at all for a game that
never started. And a launch that plainly failed is no longer followed by "did
that work?" — that question is for the ambiguous cases, which is the whole
reason it exists.

**The two most destructive controls in the app were the two that asked
nothing.** Clean Up Leftovers and Prune Old Snapshots deleted on one click,
while removing a game, rebuilding one and restoring a snapshot all stopped to
ask. Both confirm now, and the prune says how many snapshots per game it keeps
instead of "the recent" ones.

**The remove-game dialog's two outcomes looked identical.** Two red buttons,
same weight, stacked, differing by three trailing words — and the difference
between them is whether your saves still exist afterwards. Keeping the saves is
the recoverable choice and now reads as the ordinary one; only deleting them is
styled as destructive.

**The one field that gets signed and shared accepted a one-time code from
Messages.** macOS offered to autofill the endorsement note — the field whose
contents are signed, exported, and, as the line underneath it says, cannot be
recalled once shared. It is now declared as taking no content type at all.

**Four component cards shared one identity.** Installing any of them spun all
four and wrote its result into all four blurbs, so three cards claimed work
they had not done. Each has its own now.

**And the one thing in Decanter that uses the network said so in the faintest
type on the page, underneath the buttons it applied to.** The Setup page says
Decanter never downloads anything by itself; the exception is these four
buttons, and an exception you learn about after pressing the button is not one
that was disclosed. It is now stated above them, in the same weight as
everything else a person is expected to read.

**The library sorted by an encoding table.** Never-played games were ordered
with Swift's `<`, an ordinal comparison over Unicode scalars, so every
lowercase-initial title sorted below every uppercase one and every CJK or
Arabic title below all of those. `localizedStandardCompare` also puts "Game 2"
before "Game 10", which is what alphabetical means to a person.

**The detail pane showed the zero-library pitch to people with a full
library.** It is what every launch opens on and what a deletion returns you to
— the most-seen surface in the app — and it told somebody with eight games to
drop a game folder into the window. It now says what is actually true.

**Choosing Add Game on a home folder locked the app.** The search walked
without a depth limit, without a cap, and without skipping bundles: a walk of
`/Applications` descended into Visual Studio Code and came back with an `.exe`
shipped inside it, which Decanter then added as a game. Bundles are opaque now,
the walk is bounded three ways, and directory listings are cached rather than
repeated once per executable found. The same walk over `/Applications` went
from nine seconds and a wrong answer to two and the right one.

**Three different problems reported the same wrong diagnosis.** A path that did
not exist, a folder with no game in it, and a file that was not a Windows
program all came back "Not a Windows executable" — and adding a game twice
produced "Not found: Game.exe is already in the library", an error saying it
could not find the thing it had just found. Four messages now, each about what
actually happened. The exit codes are unchanged.

**Eight help popovers shipped with gaps in the middle of sentences**, left by a
reflow and preserved faithfully by the Markdown renderer. The Library popover
rendered washed out and truncated to a single line, because a popover inherits
the environment of whatever it is anchored to and that one hangs off a sidebar
section header — so it arrived wearing the header's colour, its upper-casing
and its line limit.

**The evidence column was ragged**, each weight sitting wherever its row's
height left it. Baselines and a fixed column now.

**Five places still said "prefix"** to the user, in an app whose sidebar
section is called Windows Environments — including the remove-game confirmation
and the first sentence anybody reads.

### Chrome

**The app had one keyboard shortcut.** ⌘⇧R, Refresh. Add Game — the primary
action — could only be reached by clicking a toolbar icon. There is now a File
menu with ⌘N, a Game menu (Play ⌘R, Stop ⌘., Troubleshoot, Diagnose, Copy
Problem Report ⌘⇧C, Show Windows Files), a Go menu for the four pages (⌘1–⌘4),
and Show Details on ⌘⌥I.

**The Details button disappeared when a game was not selected**, which
shortened the toolbar and moved Add Game sideways every time somebody clicked
Setup. It disables instead.

**The activity list was thrown away on quit.** It exists so "what have I
already tried?" is answerable, and it could not answer that across a launch —
three panels draw it and all three were empty on every cold start. It is
written to disk now. Entries still marked running when the app was last quit
are dropped rather than restored, because nothing can be said about how they
went.

**The out-of-date banner told you to quit and gave you no way to.** It offers
Quit now, disabled while anything is running. It still will not restart itself
— that would discard work in flight on the strength of a version string.

**Three page titles had three different treatments**, one stray hard-coded
orange bypassed the palette, and `BottleDetail` and `BottleRow` — 103 lines
implementing the per-bottle page that 0.6 deliberately removed — were still in
the tree, referenced by nothing.

Fourteen new tests, 1094 in total.

## v0.8.2 — 2026-08-31

**The endorsement popover named the game, and then told you not to.** It opened
with "*Rebirth Pub* is on Metal graphics, and this Mac has seen it work", and
four lines below warned "do not name the game in it". Both halves cannot be
right, and a reader believes the first one: it teaches that you are vouching for
*that game*, when nothing about the game travels. What gets signed is a
situation and a setup, every field of both drawn from a closed vocabulary. The
note is then written for a title nobody receiving it can see.

It now shows the signed subject in the words the row itself carries:

    Situation   Unity (Mono), 64-bit · M2 · macOS 26
    Setup       Wine + Metal graphics 0.80

with a line saying you are vouching for a kind of game on a setup and not for
this one in particular. The warning beside the note box stopped being a patch
over the framing and now says the useful thing instead: write it for whoever
lands on this situation, because they will not know which game you had.

The badge beside the title reads **setup verified** rather than *verified*. The
tier is still called verified — that is the tier's own name and is used
everywhere else — but one word sitting an inch from a game's title reads as a
claim about the game.

Eleven tests on the subject shown to the signer, and a rule that fails the build
if the endorsement surface ever interpolates a game name again.

**The out-of-date banner was drawn on top of the two things it sat next to.**
It overlapped the sidebar's own "Library" header and the Add Game button in the
toolbar, so the message telling you the window is stale was itself the least
readable thing on screen.

It was attached as a top safe-area inset on the `NavigationSplitView`. A split
view manages the safe areas of its columns itself, so an inset applied to the
whole thing draws over them instead of displacing them — and the toolbar lives
in the title bar, above all of it. The banner is now a sibling above the split
view, which pushes both columns down and cannot reach the toolbar at all.

Only visible with the banner actually showing, which needs a newer build
installed while an older one is still running. That is a narrow window, and it
is why this shipped.

## v0.8.1 — 2026-08-31

**Two sections on the game page were both called "Advanced", with the same
icon.** One holds the Wine version and the paths that follow from it; the other
holds launch switches, locale and DLL overrides, behind a door that asks you to
acknowledge it first. Neither name was wrong when it was written — they went in
months apart — and the collision is only visible with both on screen at once,
which is how every accretion problem in this app has arrived.

The first is now **Wine build**, which is what someone goes looking for it by
name to find. The second keeps *Advanced*, because changing how a game starts
is what that word is for.

A new rule fails the build if two headings on the game page ever match again. It
is scoped to that page: "Activity" appears there and on the global page too, and
those are never seen together, so that is not a collision.

## v0.8.0 — 2026-08-31

Decanter looks and reads more like a Mac app and less like a machine wrote it.
No new capability; everything the bundles in 0.9 will be built on top of, done
first so they inherit it instead of being rewritten a release later.

### Surfaces the system draws

- **Twenty-seven hand-drawn cards are gone.** Every grouped surface here was a
  `RoundedRectangle` filled with an opaque `.controlBackgroundColor`. They
  looked right on the Mac they were written on, and that was the whole problem:
  none of them moved when the system did. Not for Liquid Glass, not for Reduce
  Transparency, not for Increase Contrast. They are `GroupBox` now and get all
  of it for nothing. The one that mattered most is the game page's own sections,
  which was the largest surface in the app.
- **Green, orange and red come from the system.** They were mixed by hand, three
  literal RGB triples, which meant they stayed exactly that colour for a
  colour-blind user and for anyone with Increase Contrast turned on. The amber
  accent is deliberately still hand-mixed: it is the one colour on screen that
  says Decanter rather than AppKit, and keeping it was the point of the exercise.
- **A box inside a box is one box too many**, so the pieces list, the graphics
  options and the two log excerpts dropped their own frames when the section
  around them gained one.
- Two new rules. `check-rules.sh` now fails the build if a container surface is
  painted by hand again.

### Wine's host directory is read, not spelled

`lib/wine/x86_64-unix` was written out in nine places. None was wrong — every
free macOS Wine is x86_64 — but it is the one name in Wine's layout that changes
on an ARM64-native build, and each of those nine was a capability gate that
would have answered "no" on such a build. No Mac driver, no Metal bridge, no
Vulkan, all because of a directory name.

`WineLayout.hostPath` reads the name off disk instead. Nothing changes for any
build that exists today, which is the point: the `.app` bundles coming in 0.9
are written once and opened years later, and none of them will carry a name with
an expiry date. The Windows-side names are untouched, because `x86_64-windows`
describes the *game* — an ARM64 Wine still runs the same Windows executable.
Eighteen tests, including the one that proves an x86_64 build reads exactly as
it did before.

### Writing that sounds like a person wrote it

The prompt for this was clocking a competitor as machine-written from its prose
alone, and suspecting Decanter reads the same way. It was measured, and **the
measurement was wrong** — em-dashes per word, which infers voice from
punctuation. Measured for the things that actually make prose read as
machine-written — vocabulary, uniform shape, hedging, self-congratulation — the
UI strings and all 52,000 words of code comments come back clean: zero hits
across twenty-seven markers, six triads in the lot.

- **The README had it, and is rewritten.** Nine feature bullets of near-identical
  length and identical shape; the *this-not-that* antithesis eight times in one
  document, which is a construction a person uses twice. Doing the pass also
  caught three things that were plainly out of date: the install steps still
  described the checklist that 0.7.8 replaced, the badge claimed 936 checks, and
  Apple's Game Porting Toolkit was described as *ideally* wanted when the pack
  deliberately leaves it out.
- **`rather than`, 193 times in the comments.** Every instance earns its keep,
  so the fix is not 193 edits. Two of them within six lines of each other is
  where it stops reading as a sentence and starts reading as a habit; there are
  seventeen such clusters, and the seven in live source and docs are rewritten.
  The ten in this file are left alone: quietly restyling a dated record is worse
  than a repeated connective.
- **No lint rule for it, deliberately.** The case for one was that I cannot audit
  my own voice, which is true and is exactly why it would not work — the rule
  would have been written against the same bad instrument, and it would have
  flagged three clean surfaces while missing the one that was actually bad.

1063 checks, up from 1045.

## v0.7.8 — 2026-08-31

Setup leads with the pack, and 0.7 is finished.

- **One instruction instead of six rows.** The setup page opened as a checklist:
  six pieces, five of them downloads from five different places, each with its
  own link. That page is a procurement list, and the *shape* of it taught
  somebody "this is complicated" before they had read a word — which is the toll
  the no-download rule was quietly charging the user. It now opens with one
  button that fetches one file.
- **The checklist is demoted, not deleted.** It collapses behind "Set these up
  individually" while the Mac is not ready, and becomes the whole page once it
  is. "What am I missing?" is a real question, asked again every time a game
  misbehaves, and the rows are the right answer to it — they were just the wrong
  first impression.
- **The link is to the file, not to a page.** A releases page listing seventeen
  assets is not an instruction. It is pinned to the pack's own release rather
  than to `latest`, because `latest` moves with every patch of the app while the
  pack does not — a floating link eventually resolves to a release with no pack
  in it.
- **Getting it and taking it in are one card.** They were two — the checklist,
  and a separate "already downloaded it?" — and two cards explaining how to set
  up is the duplication the last few releases were spent removing. "Look in
  Downloads" now sits directly under the button that puts a file there.

The pack itself is published, signed, and verified into two empty Decanter
stores — once as the archive, once unpacked. Both reach a working setup in about
twenty seconds. It is attached to this release as well as having its own, so
nobody has to find two pages.

## v0.7.7 — 2026-08-31

**Every first run was blocked, and no machine that had ever run Decanter could
show it.**

Templates have been per-runtime — `template/golden-<runtimeID>` — since a prefix
built by Wine 11 turned out not to be safe under the Game Porting Toolkit's Wine
7.7. `doctor()` kept asking about `template/golden`, the single location that
preceded that split, so it answered from a directory nothing writes any more.

On a Mac that has been through the old layout the legacy folder is still sitting
there and the answer came out right by accident, which is exactly why it
survived this long. On a Mac that has never had a template — every new user —
`decanter template list` said built, the setup page said missing, and setup
stayed at "not ready yet" no matter how many times the template was rebuilt.

Found by assembling the first real pack and installing it into an empty root,
which is the first time this project has actually performed a first run. Both
locations now count, so installs that predate the split do not regress, and
there are tests for a Mac with each and with neither.

## v0.7.6 — 2026-08-31

A pack can now carry the libraries a Wine build needs to play audio and video
and does not always have.

- **A fourth component kind, `media`.** The archive is offered to the existing
  repair as a *donor* rather than copied wholesale, and that is the whole design:
  copying everything would put two versions of the same library inside one Wine —
  the exact failure `repair` was written to avoid — and would make the result
  impossible to undo cleanly. So the build is audited, only what is genuinely
  missing is taken, the fixed point is worked so a copied library arrives with
  its own dependencies, architecture is matched, writes outside the build are
  refused, and every file lands in the manifest that makes `repair --undo` exact.
  On the build this was written for that is six files out of several hundred.
- **Verified against the real failure, not a fixture.** A Sikarugir Wine 10 with
  its seven borrowed libraries removed audits as seven missing and reports that
  video will not play. It installs the pack, and comes back with six filled and
  the seventh named as one the pack could not supply — which is the right
  behaviour for a gap it cannot close, and better than a silent partial fix.
- Media installs after the Wine build and before either graphics layer: it goes
  *into* a build, so there has to be one, and whether that build can host DXMT
  is the wrong thing to measure while it is still incomplete.
- Where the libraries sit inside an archive is found rather than assumed. The
  build these come from puts them at `GStreamer.framework/Versions/1.0/lib`; the
  next one will put them somewhere else. A `lib/` holding no libraries is not a
  library root — a Wine build's `lib/wine` is full of Windows binaries and would
  match a looser test.

**Pack v1 does not need any of it.** Gcenx's Wine 11 audits completely clean as
upstream ships it, so the first pack is Wine 11 + DXVK 1.10.3 + DXMT 0.80 —
complete, redistributable, no Game Porting Toolkit content anywhere in it. That
should have been checked before the component was built; it was one command
away. The component is still what makes a Sikarugir pack possible later, and
repairing from a supplied archive rather than only from another pinned runtime
is a capability worth having on its own.

## v0.7.5 — 2026-08-31

- **The stale-build banner never appeared, and the reason was where it lived.**
  It shipped in 0.6.5 to say "this window is running an old build, quit and
  reopen", and it was checked thirty-five lines into `reload()`'s `do` block —
  behind `doctor()`, `readiness()`, a per-game recommendation, an endorsement
  check and a scan for stray processes. So the one message that explains why
  things look wrong was reachable only if the old build's engine still worked
  end to end. It now runs first and outside that block, where it cannot be
  skipped, and on a five-second timer as well as on reactivation: the app is
  replaced by a script in a terminal, and somebody reading that terminal and
  looking back at a window that never lost focus is never reactivated at all.
- **Kernel anti-cheat is detected and named before a launch.** Easy Anti-Cheat
  and BattlEye install a Windows kernel driver; there is no Windows kernel here
  to install it into, and no Wine build, graphics layer or setting changes that.
  It is the only failure Decanter can be certain of in advance and it had
  nothing to say about it — so somebody met a launcher error and went hunting
  through backend combinations for an evening. It is now a blocker, and it is
  said first, because every other blocker means "this setup is wrong" and this
  one means "no setup works".
  Found by reading Whisky's own game notes rather than by guessing.
- The first version of that detection used `has()`, an exact filename match, so
  it would have found a folder called `EasyAntiCheat` and missed
  `EasyAntiCheat_x64.dll` — which is how it usually ships. Caught before it
  shipped; there are now eight tests holding the shapes it has to recognise, and
  one holding a name it must not mistake for BattlEye.

## v0.7.4 — 2026-08-31

_Unreleased._

## v0.7.4 — 2026-08-31

Subtraction. Counted what is on screen for one game and how much of it is said
more than once, then removed the copies rather than rearranging them.

- **The detail pane went from fourteen rows to four.** Seven of the fourteen
  were already on the page a few inches to the left: the state was the status
  dot, the graphics layer was a section subtitle, "vouched for" was the badge
  beside the title, mods was the Mods section — and the engine appeared three
  times, as a chip, in the sidebar, and here. None of that was a decision. It
  was accretion, each row true and reasonable on its own, which is why counting
  was the whole of the design work. What is left follows one rule: **the page
  answers what and now, the pane answers why.**
- **The three save rows moved to the Saves page**, which already showed files,
  size, snapshots and whether they are protected, and showed them better. The
  Protect button went with them.
- **Two of the three chips under the title are gone.** The engine sits under the
  game's name in the sidebar and "modded" is the Mods section, which only
  appears when there are mods. Architecture survives on one condition: 64-bit is
  every game and changes nothing, while 32-bit constrains which Wine builds can
  run it at all — so it is shown when it is news.
- **A rule counts the pane's rows and fails above six.** A count is the only
  thing that catches accretion, because no single addition ever looks like the
  problem.
- The Protect button on the Saves page carried two `.help` modifiers, so the
  first was dead. One now.

Also in this version, held back from a release of its own:

The disk-image window, made simple instead of made robust.

0.7.3 fixed the collision by anchoring the title, the instruction and the note
outside the band the icons can occupy. It worked, and it was the wrong repair:
it spent care on keeping three things aligned that the window did not need.

- **The title, the instruction and the arrow are gone.** The window's own title
  bar already says Decanter. An app icon beside an Applications alias is the
  most recognised convention on the platform and has needed no caption for
  twenty-five years. The arrow was the actual liability — it was drawn between
  the two icon positions, and Finder scales a background picture to the window
  while the icon positions do not scale, so it pointed at nothing the moment
  anybody opened the image as a tab.
- **What is left is one line at the bottom**: that the app is not signed by
  Apple and the first launch needs System Settings. It is the one fact a
  first-time user cannot get from anywhere else. Checked at every window height
  from 340 to 900 points — the icons stay 217 points from the top and the note
  only moves further away as the window grows, so the two cannot meet.
- The window is shorter to match, and the icons sit in the middle of it.


## v0.7.3 — 2026-08-30

The disk image, which is the first thing anybody sees and was the first thing
that looked broken.

- **Nothing is drawn in the band the icons occupy.** Finder scales a background
  picture to whatever size the window actually is; the icon positions saved in
  `.DS_Store` are absolute points and do not scale with it. The two agree only
  at the one size the image was laid out for — and a disk image opened as a tab
  in an existing Finder window is never that size. The old art had an arrow
  drawn between the two icon positions and "Drag it into Applications" across
  the middle, so in a wide tab the words stretched, the icons stayed put, and
  the Applications alias landed on top of "Drag". The arrow is gone and the
  text is anchored where it cannot collide: the icons sit between 157 and 275
  points from the top, always, which across every window height Finder produces
  covers 0.20 to 0.69 of the height. The title sits at 0.08, the instruction at
  0.155, the signing note at 0.90. Checked by rendering the window the way
  Finder draws it — background scaled, icons fixed — at 620x400, 1000x500 and
  1200x660.
- **`.background` and `.fseventsd` are parked below the window.** They carried
  no saved position, so Finder dropped them at the top left of the layout —
  invisible to most people, and sitting in the middle of the arrangement for
  anyone with ⌘⇧. on.
- **The build checks the layout it shipped, from the bytes.** The first version
  of this check asked Finder to read the layout back, and it passed with the
  layout deliberately broken: Finder caches icon-view state per volume *name*,
  so a volume called "Decanter" is answered from whatever it learned last time
  one was mounted, including from a window somebody resized by hand. It now
  parses `.DS_Store` with no Finder in the loop, and was proved to fail by
  moving an icon and watching it stop the build.

## v0.7.2 — 2026-08-30

A game page that was working perfectly offered forty-odd things to do, across
five sections of identical weight, before anything had gone wrong. Counted
rather than estimated, and the count was the smaller half of the problem.

- **Two launch verbs, not three.** "Test Launch" did not launch — it ran the
  preflight and predicted. "Troubleshoot Launch" did launch, with verbose
  logging. Two controls four words apart, one of which starts a game and one of
  which does not. They are now one **Troubleshoot**: the check runs first and
  stops if it names something that would prevent the game starting, because a
  blocker is an answer and launching would only produce a second copy of it; if
  nothing does, the game starts with the log running, which is the only way to
  learn more. That a press can put a game window on screen is written on the
  control rather than discovered.
- **One problem card, ranked.** Five could apply to a game at once — an
  unanswered verdict, a diagnosis, an unsound environment, a setup
  recommendation, stray Wine processes — and they stacked, all about the same
  game, free to contradict each other in front of the reader. That is the fault
  0.6.3 fixed one level down; this is the same fix one level up. The order is
  `Concern` in the kit, not a chain of `else if` in a view: it is a claim about
  which problem is more urgent, it will be argued with, and a claim nothing can
  test is a claim that quietly stops being true. The unanswered question comes
  first, because every recommendation below it is formed without knowing the
  answer.
- **Five sections became three**, grouped by when somebody needs them rather
  than by what they are. Graphics and Windows Components are both "how this game
  is set up" and were two doors. The repair tools were filed under "Saves &
  Maintenance", which is not where anybody looks when a game will not start —
  they are now "If something is wrong", and that section opens itself when
  something is.
- **The duplicate "Reveal in Finder" is gone.** The same button appeared twice
  on one page, doing the same thing. The one that survives sits beside the
  prefix path it opens.
- Section headers say what is inside them while closed: the graphics layer and
  how many Windows components have been added.

## v0.7.1 — 2026-08-30

- **0.7.0's build was red.** `switch someOptionalBool { case true: … case nil: … }`
  is exhaustive to Swift 6.3 and is not to the compiler on macOS 15, which is
  what CI builds with. The local gate did not catch it and could not: `STRICT=1`
  passes CI's flags to a different toolchain, so it proves the code has no
  warnings and says nothing about whether it compiles there. Written as
  `.some(true)` / `.none`, and there is now a rule looking for the shape.

## v0.7.0 — 2026-08-30

Setup's remaining honesty problem, and the machinery to fix it.

Decanter fetches nothing, which is the whole argument: Whisky's installed copies
died when the runtime it downloaded was deleted upstream. But that guarantee was
being paid for by the user, who was sent to three strangers' releases pages to
collect a Wine build, a DXVK tarball and a DXMT archive, and had to know which of
the files on each page was the right one. That is the same dependency Whisky had,
moved onto a person.

- **Runtime packs.** One file holding what a first run needs, assembled once and
  published, with a manifest naming every component, its version, its licence,
  its upstream and its SHA-256. Decanter still fetches nothing — the browser
  downloads it and Decanter reads it off the disk, exactly as it reads a dropped
  Wine build. What is new is that there is one file instead of three, and that
  Decanter can say whether the copy that arrived is the copy that was published.
  A pack is verified in full before a single component is touched, and one that
  fails installs nothing at all rather than leaving half a runtime behind.
  Installing one is `decanter use`, like everything else: there is no second verb,
  because a second verb is a second place for "what did it just do with my file"
  to be answered differently.
- **A manifest is treated as a stranger's document.** Every field decodes by
  hand, a component whose file name is a path rather than a leaf is refused
  outright, a pack claiming a newer format is refused rather than half-read, and
  a component of an unknown kind stops the read instead of being skipped over.
- **Packs can be signed, with the key that already exists.** The endorsement key
  signs the manifest, and the manifest covers every component by hash, so one
  signature stands for the whole pack and cannot be forgotten after a component
  changes. The signed bytes carry a domain of their own: one key that signs two
  kinds of document without separating them is a key whose signature over one
  can be presented as a signature over the other. Endorsements are untouched, so
  every signature already published stays valid.
- **The assembler audits what it is about to publish.** The sixth rule of this
  project is that once Decanter hands someone a runtime, a missing library inside
  it is Decanter's defect and not upstream's — and that rule means nothing unless
  the thing assembling the pack checks. The Wine build is unpacked and audited
  before it goes in, and a hard gap stops the build with the count in the message.
  `--allow-incomplete-wine` overrides it, and has to be typed.
- **A pack carries upstream archives, byte for byte, never a tree re-packed from
  this Mac.** The first sketch tarred up the pinned runtimes, and it was wrong in
  a way that only became visible when the licences file was written. A re-packed
  tree matches no hash anyone upstream publishes, so "is this really DXVK 2.7"
  has no answer. It can also quietly contain repairs: `repair` borrows missing
  libraries from any pinned build, and on the machine this was written on, the
  one runtime that can host DXMT is complete only because seven files were copied
  out of Apple's Game Porting Toolkit — legitimate there, not ours to hand on,
  and invisible once copied. And "unmodified binaries from the projects below"
  would then be a false statement in a licences file, which is the one thing a
  licences file may not be.
- **Redistribution has a check with teeth.** `Pack.redistributionBlockers` reads
  the record `repair` leaves inside a build it changed and names, in a sentence,
  what may not be published and why. It counts files rather than listing them,
  and it survives the donor being removed from the library — the record outlives
  the runtime it came from.
- **"Look in Downloads."** The instruction on the setup page is to drag a file
  onto the window, and that is the part of setup that goes wrong: the file is in
  Downloads, the window is behind the browser, and the thing being dragged is a
  `.tar.xz` the browser may have half-unpacked into a folder beside it. Decanter
  can now look, list what it recognises with each item switched on, and wait.
  Looking is separate from taking on purpose — Downloads is not a folder anyone
  curated, and a button that pinned whatever Wine build happened to be sitting
  in it would be doing something nobody asked for. It is also where the system's
  folder-access prompt belongs: one beat after a deliberate press, rather than at
  launch because the app went looking. `decanter use --look <folder>` at the
  prompt.
- **`decanter pack check <path>`** reads a pack, says what is inside it, hashes
  every component, reports whether the manifest carries a signature Decanter
  recognises, and exits 1 if anything is wrong.

## v0.6.6 — 2026-08-30

The rest of 0.6.x: the settings that only ever existed at the prompt, behind one
door, and two things the app knew and would not say.

- **Advanced, gated once.** Launch switches, the language environment and the
  graphics layer's exact version were reachable only from a terminal — by an app
  whose whole argument is that you should not have to open one. They are here
  now, in a section that is closed by default and asks once, not every time: a
  warning that appears on every visit is one people learn to click past, and
  then it is not there when it matters. The switches offered are the ones
  detection says are worth trying for *this* game, not a catalogue.
- **DLL overrides can be set.** `Game.dllOverrides` has been honoured at every
  launch since it existed and written by nothing — no command, no screen, no
  default past the empty dictionary in the initialiser. That is the same fault
  as `runtimeLocked`, which was written in two places and read in none, with the
  halves swapped. `decanter dll <game> winhttp=n,b`, and an editor in Advanced.
  Wine's own vocabulary is kept rather than translated, because anyone who needs
  this is following a forum thread that says `n,b`. Input Wine would not
  understand is refused rather than stored and left to fail silently at launch.
  Mod-loader proxies are still detected and overridden automatically — the
  interface now says which one it found, instead of leaving people to guess
  whether it was winhttp.
- **"Fix Fonts" says whether it would do anything.** `decanter fonts --check`
  has answered that all along; the button was an action with no diagnosis beside
  it, pressed on a hunch, reporting afterwards that it had done nothing. It now
  carries the count — two registry files per prefix, so it costs nothing to keep
  current.
- **Prune Old Snapshots.** `decanter saves gc` existed and the app had no
  equivalent, so snapshots accumulated with nothing on any screen offering to
  stop them.
- **The `--detail` promise is scoped to what honours it.** The help offered it
  on "any of these" and five commands implemented it. A flag that silently does
  nothing teaches people to stop trying flags.
- **The README no longer says Decanter cannot do DXMT.** It has since 0.5, which
  is most of what 0.5 and 0.6 were about. The line sat in the comparison table,
  which is the part people read first.


## v0.6.5 — 2026-08-30

- **The app says when it is not the app that is installed.** Installing over a
  running Decanter replaces the bundle and leaves the process alone, so the old
  build keeps drawing the old interface for as long as the window is open — and
  closing the window does not end it. Nothing said so. One window stayed open
  across four releases, and every screenshot from it was reported against the
  build that had just shipped; twice it sent someone looking for a fault that
  had already been fixed. A banner now compares the version compiled into this
  process with the one in the bundle on disk and says plainly that quitting is
  what fixes it. Deliberately not a "Restart Now" button: relaunching would
  discard whatever is in flight, and the app has no business quitting itself on
  the strength of a version string.
- **An action about one game no longer reports on every page.** Fixing fonts and
  repairing a runtime are global in effect and almost always pressed from one
  game's page, so their results went to the unscoped list and turned up on
  Setup — nobody's page. They now report where the button was. A rule in
  `check-rules.sh` fails the build if an action names a game and has no scope,
  because forgetting it is silent and looks like nothing until it does not.
- **The details pane says what this game is running on.** It never did. It
  opened on detection weights and a confidence to two decimal places — the
  answer to "how did Decanter identify this?", asked once per game, ever — while
  the first thing anybody actually looks for, which Wine build and which
  graphics layer, was not in it anywhere. It now leads with that, plus whether
  the setup has been vouched for, whether the environment is sound and which
  generation it is on, and how much the saves come to. The detection evidence is
  still there, behind a disclosure, where a question asked once belongs.


## v0.6.4 — 2026-08-30

One fix, and it is the one that matters: **the knowledge base is written under a
lock, against the copy on disk.**

`Store.mutate` has done this for the library since the beginning, with the
reason written beside it — the GUI and the CLI are routinely open at the same
time, and without it whichever writes last silently discards the other's
changes. Every word of that was true of the knowledge base, and it had none of
the protection: `knowledge.save` wrote whatever was in memory over whatever was
on the disk.

The failure is not subtle once it is named. An app left open holds the knowledge
it read at launch. An endorsement made at the prompt afterwards lands on the
disk, and the next thing done in that window — confirming a launch, importing a
file, anything at all — writes the launch-time copy back over it. Nothing is
said, the row still reads "worked", and the only visible sign is `endorse list`
going empty later for no reason connected to anything anybody did. It is also
the one thing here that cannot be reconstructed without the private key.

This ate a real endorsement twice on the maintainer's own Mac while 0.6.1 to
0.6.3 were being written, and both times it was read as a different bug: the
first as `record` replacing rows too eagerly, which was also true and was fixed
in 0.6.1, and the second as a stale display, which was also true and was fixed
in 0.6.2. Neither was this.

Every write now takes the lock, re-reads the file, applies the change to *that*,
and saves — expressed as a function of the current state rather than as a
finished value, because a value computed before the lock is exactly the stale
write this exists to prevent. Recording a success, recording a failure,
endorsing, revoking and importing all go through it. The suite holds a stale
engine and a fresh one open at once and checks that the stale one cannot erase
what it never saw.


## v0.6.3 — 2026-08-30

Three cards said the same thing, and the strongest thing Decanter can say about
a setup could only be read at a terminal.

- **One card, one decision.** A game that had been moved around could show a
  warning that it was not known to run here, an offer to go back to what last
  worked, and a recommendation to try something else — three views, three
  sources, stacked, all about the same question and free to disagree about it in
  front of the reader. Three ways to say one thing is not three times the help;
  it is a reader deciding which card to believe. The decision is now made once,
  in `Engine.advice(for:)`, where it can be tested without a window, and the
  card renders it and decides nothing. Going back outranks a recommendation: a
  setup this game was seen working on is a stronger claim than any advice, and
  offering both asks someone to choose between Decanter's memory and Decanter's
  opinion.
- **Endorsement is visible, beside the game's name.** It is a fact about the
  setup rather than a step in getting the game running, so it sits with the
  title rather than in the queue of things to do. On a Mac holding a key there
  is an Endorse control there too — with the note field, and the warning that
  the text is signed, travels, and cannot be recalled. On every other Mac
  nothing appears, because the capability is simply having the key file: there
  is no mode to enter and nothing for anyone else to find.
- **An endorsement can be taken back.** `decanter endorse revoke <game>`, and
  Withdraw in the app. A key that can only ever add is a key whose holder cannot
  correct themselves. The observation stays — it is still true that this ran
  here — and the vouching and its note go. Anyone who already took a copy still
  has the old one, and it says so.
- **`--note ""` clears the note.** It was swallowed by the same test that
  ignored a missing flag, so a note could be written and never taken back — and
  re-endorsing without one silently re-signed the old text, which reads exactly
  like Decanter having invented prose of its own.
- **Shared knowledge has a door in the app.** Import and export on the Setup
  page, framed as what they are: a file a person hands you, not an update you
  receive. There is no automatic version and there will not be one — that would
  mean reaching out somewhere, and "Decanter makes no network requests" is
  checkable precisely because it has no convenient exception. An export still
  carries situations and outcomes only; there is no setting for names because a
  name is never recorded.
- **`decanter endorse keygen` and `revoke` are in the program's own help.** The
  documentation had been more complete than the tool, which is backwards: the
  person who needs help is at the prompt, not on a website.


## v0.6.2 — 2026-08-30

Decanter did things and did not say what happened. The activity list at the
bottom of the page answered "what has been done", which is a different question
from "did the thing I just clicked work" — and it was answering the second one
from six inches away, on whichever game's page you happened to be looking at.

- **A control says what happened, where it was pressed.** Every keyed action now
  reports back on its own button: a tick and the result for a few seconds, or a
  warning and the reason, which stays until something else is pressed because it
  is the thing still needing attention.
- **Activity belongs to the game it was about.** The list was global, so a
  problem report collected for one game sat on another game's page presenting
  itself as that game's history. A game's page now shows its own actions plus
  what was done to the Mac — repairing a runtime is part of the story of why a
  game started working — and the Windows Environments and Setup pages show only
  the Mac's.
- **The escape hatch is a button.** "This game is not known to run here" named
  the one setup that could work, in prose, and then left the reader to find it.
  Where that setup is one Decanter can reach, it is now offered in the card
  itself; where it is not, the missing piece is named instead. The separate
  recommendation banner no longer appears alongside it — two cards recommending
  different things, one of them a setup known to fail, is worse than either.
- **Test Launch.** `decanter check` has answered "would this start?" since the
  beginning and the app had no way to ask; the alternative on offer was to press
  Play and watch for a black window. It resolves the path, applies the drive
  scopes and asks Wine whether it can see the program — everything a launch does
  except the launch. The sentence it gives back is written in the shared library
  and used by both surfaces, so they cannot drift.
- **The graphics list says what is missing from it.** It showed what a build
  provides and nothing about what it does not, so "where is Metal graphics?" had
  no answer in the app — while `decanter bench` had measured one and written it
  down. The unavailable options are now listed under the picker with the reason,
  as explanations rather than choices.
- **A release build reports its version and stops.** The commit stamped beside
  it could never have been right: install.sh runs from release.sh, before the
  release commit exists, so the hash it wrote always named the commit *before*
  the tag — v0.6.0 shipped saying `7f1ffae` while the tag pointed at `bde58b5`.
  A clean tree now stamps nothing and the version is the whole attribution,
  which also terminates: the second run over the release commit produces no diff
  at all. A build from a modified tree still carries its hash, which is the case
  the hash was for.


## v0.6.1 — 2026-08-30

A release about telling the truth. Everything here is something Decanter
already knew and was displaying wrongly, or was quietly throwing away.

- **An endorsement is no longer destroyed by playing the game.** `record`
  replaced the row for a situation unconditionally, and the observation built
  when a launch is confirmed carries no note and no signature — so confirming an
  endorsed setup still worked overwrote the endorsed row with a bare one. The
  row went on saying "worked", so the only symptom was `endorse list` going
  empty later, for no reason connected to anything the user had done. An
  endorsement cannot be remade without the private key, which makes this the one
  loss in Decanter that the machine cannot recover from by itself. The
  endorsement and its note are now carried forward when the claim is unchanged,
  and correctly dropped when the outcome is not — a signature moved onto a
  different claim would fail to verify, and that reads as tampering.
- **The app reads the files again.** `Store.refresh()` existed for exactly this
  and had no callers; the knowledge base was a `lazy var` loaded once. One
  Engine was held for the app's whole lifetime, so anything changed at the
  prompt stayed invisible until the app was quit and reopened: a game moved to
  another backend went on being drawn on the old one, and an endorsement made in
  the terminal changed nothing on screen. The Refresh menu item recomputed the
  interface over the same frozen snapshot, which is worse than having no Refresh
  at all — it answers without looking. The app now reloads on every action and
  whenever its window becomes active, which is the moment it is most likely to
  be stale.
- **"This game is not known to run here" now loses to evidence.** The banner
  read a static rule about the engine and never consulted the knowledge base, so
  a game this Mac had watched run — endorsed, even — went on being told it could
  not. `Engine.recommend` was given that precedence in 0.6.0; the interface was
  not. A warning that survives its own disproof teaches people to ignore
  warnings.
- **An unknown command fails.** `usage()` took its exit status from whether any
  argument had been given, so a command Decanter had never heard of reported
  success — on stdout, with the whole manual attached, which scrolled the error
  itself off the screen and made `decanter typo | head` look like help had been
  asked for. It now exits 2, writes three lines to stderr, and names the nearest
  real command when there is an obvious one.
- **`decanter knowledge` stops calling other people's observations its own.**
  Three provenances were printed as two: an imported row is not seeded, so it
  fell through and announced itself as "observed here", in the one listing whose
  entire job is saying where an answer came from. Endorsement is shown there
  too — `endorse list` and `knowledge` described the same row differently.
- **`decanter doctor` reads the bench table.** It called a build "untested"
  after `bench` had started that build and asked it directly, so two commands in
  one session disagreed about the same file. The DXMT verdict also moved up
  beside the runtime it describes, from eight lines below, past the game and
  bottle counts.


## v0.6.0 — 2026-08-30

Decanter could tell you a game had failed. It could not tell you why the Wine
build it ran on was incapable, because it had never looked.

- **`decanter bench` measures what each Wine build can actually provide**, and
  keeps the evidence. This was decided once, at the moment a build was pinned,
  written into the library, and never revisited — so a build repaired or
  extended afterwards kept being offered the old list, and there was no way to
  tell Decanter it had changed short of unpinning and pinning it again. It is
  now something you run, and it corrects the record where the two disagree.
- **`decanter audit` finds what a build references but does not carry.** This is
  the silent class of fault: the file is present, so every check that asks "is
  it there?" says yes, and `dlopen` fails anyway — the caller takes its fallback
  path and a game renders blank boxes or plays no video, with nothing written
  anywhere. Found on this Mac: one build could not play video at all, and
  Apple's Game Porting Toolkit cannot on its 32-bit side.
- **`decanter repair` offers to fill those gaps from builds already on this
  Mac.** Nothing is downloaded — Decanter still makes no network requests, and a
  repair is not an exception. It describes by default and acts only when told
  to, saying what it changes, where, and how to undo it. `--undo` removes
  exactly the files it copied and nothing else.
- **Every finding now has two registers.** A plain answer anyone can act on, and
  the reasoning underneath it, shown only when asked for with `--detail`. The
  rule is enforced by the suite rather than intended: no plain answer may
  contain a file format, a symbol name or a library name. A refusal that reads
  "its Mac driver is a Mach-O bundle" states the reason for the answer instead
  of the answer, which is "this needs a different Wine build, and no setting
  will change that".
- **One vocabulary everywhere.** The app said "Metal graphics" and the command
  line said "DXMT" about the same setting. The plain names moved into the shared
  library; the real names are kept beside them, never hidden, because someone
  following a forum thread needs to recognise "DXVK".

Three faults in this work, each caught by measuring rather than reasoning:

- A consequence was read from the missing library's *name*, so `libbz2` absent
  from the video decoder announced that text would not draw — the font library
  also happens to use bz2. It is read from the dependent now.
- dyld's fallback search was not modelled, so eleven libraries were reported
  missing that were sitting on disk. The resolver mirrors what the launcher
  actually sets.
- The first repair closed six gaps and opened three: a library moved out of its
  own directory can no longer find its siblings. A plan now works to a fixed
  point, examining every file it would copy at the place it would land.

**Knowledge can be vouched for, and the vouching is checkable.**

- **`decanter endorse` marks a setup as one somebody actually ran**, signing the
  row with a key only the maintainer holds. An earlier plan had the app verify
  its own code signature instead; that would have been theatre, since Decanter
  is ad-hoc signed by design and anyone rebuilding from source gets a binary
  that passes the same check. Signing the knowledge works, and it keeps
  everything anonymous: a signature proves a tier and carries no name. A fork
  should ship its own key and cannot forge an endorsement in this one.
- **An endorsement never overrules what your own Mac has seen.** It outranks a
  generalisation and loses to an observation about this machine, and when it
  displaces one, the displaced answer is offered second rather than dropped. Its
  only other power is to let an imported failure count — an unendorsed one never
  does, or one stranger's broken install takes an option away from everyone who
  imported it.
- **The confidence badge became provenance.** "High" and "medium" gave no way to
  tell a rule nobody has ever tested from an observation on an identical
  machine. Provenance says what happened and lets you decide what it is worth.

- **A measurement now outranks an assumption Decanter shipped with.** A game
  confirmed working on this Mac, and endorsed, went on being described as *"not
  known to run here"*: the built-in claim that its engine needs a particular
  graphics layer answered before the record of it working was ever consulted.
  The rule was already written as a comment three lines below the check that
  contradicted it. Only a confirmed or vouched-for answer gets this — a shipped
  starting assumption is not evidence and does not overrule another one.
- **An endorsement survives export.** It used to stop at the boundary and arrive
  as an ordinary shared row, which is the one thing it is not. Its note travels
  with it and is kept **only** when the signature checks out on arrival — the
  signature covers the note, so text edited in transit is dropped. Unsigned
  notes are still dropped entirely, which is what has always kept a game title
  out of anything that travels.
- **A game no longer corroborates itself through an endorsement.** The ordinary
  walk had this rule; the endorsement path did not, so a lone endorsed row read
  as "1 game has since agreed" about the game doing the asking.
- Two wording faults with it: "this worked for someone ran this and confirmed
  it", and a second option offered that was the same option with a different
  layer version attached.

**Two ways back from a launch that went wrong.**

- **A game remembers the setup it last worked on**, with a date, and offers to
  go back to it. Saves are kept.
- **Decanter now asks about the launches it refuses to judge.** A clean launch is
  recorded and asks nothing — being asked to confirm the obvious is how a prompt
  becomes something people dismiss unread. An ambiguous one, which is the kind
  most worth learning from, previously taught the knowledge base nothing at all.
  The question says what Decanter actually saw, is asked once, and expires
  rather than asking about a launch nobody remembers.
- **A failure on a setup you chose yourself says nothing about the suggestion.**
  It is recorded against that setup and no further; the suggestion stays
  unjudged, which is not the same as having been tried and found wanting.

**Red text in a mod log that is nobody's mod's fault.**

- **BepInEx's "Unable to start Unity log writer" is no longer reported as a mod
  failing.** Every plugin loads and the game runs; the loader is talking about
  itself. A message the loader writes on every start otherwise made every one of
  those games look broken.
- **But it is not called harmless either, because it is not.** It is the reason
  the log file stops just after startup: with that listener unattached, the
  game's own messages reach only the console window and are never written down.
  So a log that looks like it ends when the game began is *this*, and not a game
  that stopped — which is worth being told, since it is exactly what makes a
  later problem impossible to diagnose. The first version of this text said
  "nothing is lost"; reading the log showed the file held no game output at all.
- **A loader that did not finish gets no benefit of the doubt.** The same line is
  a real failure when nothing in the log shows the chainloader completing.
- **What the game itself said is separated from what the mods did.** A game that
  cannot reach Steam warns and carries on, and that warning — visible nowhere
  else — now reads as "the game works; achievements, cloud saves and friends
  will not" rather than as an exception type.
- Mod failures in the command line now lead with the explanation, with the exact
  line behind `--detail`, the same way everything else does.

**Found reviewing this release before shipping it:**

- **The verdict was never asked in the app.** Only the command line parked a
  question, so the card that displays it could not appear. A feature that only
  works in half the program is not shipped, it is written.
- **The build failed with warnings as errors**, which is how CI builds it — one
  discarded result. Caught by the release check that now runs it.
- **A comparison force-unwrapped its own index.** Correct for the three tiers
  that exist, a crash the moment a fourth was added. It is a switch now, which
  the compiler checks.
- **Verification did real work before asking the cheap question.** Every row at
  every level of the matching ladder parsed the key before discovering the row
  had no signature at all. The key is parsed once, and rows without one cost
  nothing.
- **Repair now refuses to write outside the build it names**, rather than that
  being true only because of how the paths happen to be built. Undo checks the
  same thing: the manifest lives inside the build, so anyone can edit it, and it
  must not become a list of things to delete.

**`scripts/release.sh`** gathers every precondition into one command: a dirty
tree, an already-used version, a placeholder changelog entry, a failing rule or
suite, an endorsement that no longer verifies. It does not tag and does not
push — deciding a thing is finished is a judgement, and only checking whether it
is sound belongs in a script.

## v0.5.7 — 2026-08-29

- **Every Windows-written log was being read as a single line.** Swift treats
  `\r\n` as one character, so splitting a log on `"\n"` did not split it at
  all — and every log Decanter reads is written by Windows software, which uses
  `\r\n`. Ten parsers were affected. The visible symptoms: a mod loader
  reporting one "failure" that was actually 150 characters of three
  concatenated lines, attributed to a plugin called *"Message: Preloader"* that
  does not exist; and launch diagnosis announcing that a log said nothing while
  the log said plenty. Everything that reads a log now splits on any newline.
- **The mod loader's own messages are no longer blamed on a mod.** BepInEx
  writes internal notices through the same tagged format its plugins use, so
  "Unable to start Unity log writer" — the loader talking about itself — was
  presented as a mod that failed to load, sending you hunting through plugins
  for a fault that was not there.
- **A severity tag can never be mistaken for a mod's name**, at any depth.

## v0.5.6 — 2026-08-29

- **Mods load whichever proxy DLL they actually use.** BepInEx and Doorstop hook
  a game through a proxy DLL sitting next to it, and *which* DLL is the mod
  pack author's choice — `winhttp` is only the most common. Decanter overrode
  `winhttp` and nothing else, so a game whose proxy was `hid.dll` started
  perfectly and ran completely vanilla: no loader, no plugins, no translation,
  no error anywhere. The same game under Whisky showed a full mod interface,
  which is how the difference surfaced at all. Every proxy Doorstop ships as is
  now named, gated on Doorstop's own files being present so a game's real
  `hid.dll` is not forced native on a guess. The graphics names it can also use
  — `dxgi`, `d3d9`, `opengl32` — are deliberately excluded: forcing one native
  for a mod loader would swap the renderer.
- **A granted folder is no longer reported as a drive that was closed.** The
  descope introduced in 0.5.3 ran before the grants were written and did not
  know about them, so every launch logged the game's own folder as "a drive this
  game should not have had" moments before recreating it. The doors were right
  and the account of them was false, which is the worse of the two failures.

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
