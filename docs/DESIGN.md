# Why Decanter is built this way

Every decision here exists because the alternative failed in practice.

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

**A Wine build is not a prefix, and it is repaired.** `decanter repair <runtime>` looks like
the opposite of the rule above and is not: a prefix is disposable, rebuilt in half a second
from a template, so repairing one buys nothing and costs a heuristic that will be wrong
later. A Wine build is neither — it is gigabytes, it was assembled by somebody, and throwing
it away means acquiring it again. What is repaired is also not a guess: an audit reads the
build's own load commands and finds libraries it references but does not carry, which is a
fact about the file rather than a theory about the symptom. Every file comes from another
build already on this Mac, nothing is downloaded, and `--undo` removes exactly what was
copied.

**A capability is measured, not remembered.** `decanter bench` asks each pinned build what
it can actually provide and keeps the evidence. This was previously decided once, at the
moment a build was pinned, and written into the library — so a build repaired or extended
afterwards kept being offered the stale answer, and there was no way to correct it short of
unpinning and pinning again.

**Answers are silent when they fail.** The reason both of the above exist is that the
failure mode here has no error message. A missing library makes `dlopen` return null, the
caller takes its fallback path, and a game renders blank boxes or plays no video with
nothing written anywhere. Every check that asks "is the file there?" says yes. Finding these
needs a scan, so Decanter does the scan.

**No `z: -> /`, and no drive Decanter did not create.** Whisky mapped the entire Mac
filesystem into every bottle, so any Windows binary could read `~/Documents`, `~/.ssh` and
iCloud. Removing `z:` alone was not enough: `wineboot` maps a drive letter at every mounted
volume, plus a raw `/dev/rdisk` node beside it, so a prefix gained a door onto each external
disk, network share and mounted image the moment one appeared. Before every launch Decanter
now removes every letter that is not `c:` and not a granted scope, and records what it
closed. A game sees its own folder plus a shared games dir, and nothing else.

**Detection decides the runtime.** The binary's PE header gives bitness; sibling files
(`UnityPlayer.dll`, `GameAssembly.dll`, `package.nw`, `renpy/`, `.pck`, Unreal layout,
`BepInEx/`) give the engine; and a `.dxvk-cache` is treated as proof DXVK already worked.
Note that Unity and Unreal link `d3d12.dll` while rendering D3D11 — Decanter does not
fall for that.

**Backends are clamped to what the runtime can provide.** D3DMetal only exists inside
GPTK; storing it against a Wine runtime would silently mean no acceleration at all. What a
runtime provides is measured rather than inferred from its version — MoltenVK being present
decides Vulkan, and two independent properties of the Mac driver decide Metal.

**Every answer has two registers.** A plain sentence somebody can act on, and the reasoning
behind it, shown only when asked for. A refusal reading "its Mac driver is a Mach-O bundle"
gives the reason for the answer instead of the answer, which is "this needs a different Wine
build, and no setting will change that". The suite enforces the split: no plain answer may
contain a file format, a symbol name or a library name.

**Knowledge is signed, not the program.** Marking something as verified means one thing —
somebody ran it and watched it work — and it is proved by a signature over the row's own
contents, made with a key only the maintainer has. Verifying the *app's* signature instead
would have been theatre: Decanter is ad-hoc signed by design, an ad-hoc signature carries no
identity, and anyone rebuilding from source gets a binary that passes the same check. A fork
should ship its own key, and cannot forge an endorsement in this one. The signature proves a
tier and carries no name.

**What this Mac has seen outranks what anyone vouched for.** An endorsement slots in above a
generalisation and below an observation about this machine. When it displaces a local
answer, that answer is offered second rather than dropped. Its one other power is to let a
failure that arrived in somebody else's export count — an unendorsed one never does, because
a single stranger's broken install would otherwise take an option away from everyone who
imported it.

**An endorsement outlives being re-confirmed, and not a changed outcome.** Confirming that an
endorsed setup still works is the most ordinary thing anyone does to one, and it must not
cost the signature — an endorsement is the only thing in Decanter that cannot be rebuilt from
the machine it lives on. So the signature and its note are carried onto the replacement row
whenever the claim is identical. When the outcome has changed they are dropped instead: the
signature covers `worked`, `failure` and the note, so moving it onto a different claim would
leave an endorsement that fails to verify, which reads as tampering rather than as an honest
change of mind. Nobody vouched for the new answer, and the row should not pretend otherwise.

**Anything two processes can write is written under a lock, against the disk.** The app and the
command line are routinely open together, so every write takes the lock, re-reads the file,
applies the change to that, and saves. The change is expressed as a function of the current
state, never as a finished value: a value computed before the lock is precisely the stale
write this prevents. The library had this from the start and the knowledge base did not,
which cost two endorsements before anyone worked out that the missing lock — rather than
either of the two real bugs found while looking for it — was the cause.

**Decanter records what it can see, and asks about what it cannot.** A clean launch is
recorded and asks nothing. An ambiguous one — a window that appeared and then exited, a
process with no window, a log full of errors — is a case it refuses to judge, and those are
the launches most worth learning from. It asks once, says what it saw, and expires the
question rather than asking about a launch nobody remembers. A failure on a setup somebody
chose by hand is recorded against that setup and no further: the suggestion stays *unjudged*,
which is not the same as having been tried and found wanting.


**Decanter downloads nothing, but that never meant "use Terminal".** The rule is that
no installed copy may depend on a server still existing — Whisky's copies broke when the
runtime repository it fetched from was deleted. A file the user already has on disk is
not such a dependency. So Setup accepts anything dropped on the window, identifies it by
content rather than by filename, and mounts a disk image the user hands over; the links
it shows open in the user's own browser. `check-rules.sh` fails the build if a
networking API appears anywhere in the sources, so nobody has to remember the claim
for it to hold.

**Names say what a thing is; the recommendation is separate.** The graphics options were
once Apple, Standard and Compatibility. Both of the latter smuggled a claim: a stuck user
reads "Compatibility" as the safe option to move to, when WineD3D is the slow fallback
and a modern game may do better on Apple's. Compatibility is per-game, not a ranking —
which is the whole reason Decanter recommends rather than sorts. So the options are named
for what they are, the real names sit beside them for forum threads, and Decanter's pick
is a badge that can land on a different row for the next game without implying any row is
worse.
