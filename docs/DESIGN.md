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


**Decanter downloads nothing, but that never meant "use Terminal".** The rule is that
no installed copy may depend on a server still existing — Whisky's copies broke when the
runtime repository it fetched from was deleted. A file the user already has on disk is
not such a dependency. So Setup accepts anything dropped on the window, identifies it by
content rather than by filename, and mounts a disk image the user hands over; the links
it shows open in the user's own browser. `check-rules.sh` fails the build if a
networking API appears anywhere in the sources, so the claim is enforced rather than
remembered.

**Names say what a thing is; the recommendation is separate.** The graphics options were
once Apple, Standard and Compatibility. Both of the latter smuggled a claim: a stuck user
reads "Compatibility" as the safe option to move to, when WineD3D is the slow fallback
and a modern game may do better on Apple's. Compatibility is per-game, not a ranking —
which is the whole reason Decanter recommends rather than sorts. So the options are named
for what they are, the real names sit beside them for forum threads, and Decanter's pick
is a badge that can land on a different row for the next game without implying any row is
worse.
