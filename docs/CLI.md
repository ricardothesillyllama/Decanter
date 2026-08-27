# Command reference

The CLI and the app are one engine with two faces. Anything the app does, this
does — plus a few diagnostics that only exist here.

`decanter help` prints the same list. Add `--verbose` to any command for detail.

## Setting up

| Command | What it does |
|---|---|
| `decanter setup` | What Decanter has, what it needs, and where to get the rest |
| `decanter use <file>` | Hand over a Wine build, a Wine `.app`, a Game Porting Toolkit `.dmg`, `dxvk-*.tar.gz` or `dxmt-*.tar.gz`. Decanter works out which it is |
| `decanter doctor` | Check the stack — Rosetta, runtimes, template, and the Rosetta end-of-life horizon |
| `decanter pin` | Take Decanter's own copy of every Wine build already installed on this Mac |
| `decanter runtime list` | Pinned runtimes, their 32-bit capability, and what each can render with |
| `decanter runtime set <game> <id>` | Move a game to another runtime (rebuilds its environment; saves are kept) |
| `decanter template build [rt]` | Build the golden template a new game clones from |
| `decanter template list` | Which runtimes have a template |
| `decanter dxvk list` | Staged DXVK versions, and what each game actually has installed |
| `decanter dxvk use <game> <ver>` | Switch one game to a specific DXVK version |
| `decanter dxvk prefer <ver>` | Which version new templates bake in |
| `decanter dxmt list` | Staged DXMT builds, and which pinned runtimes can host one |
| `decanter dxmt stage <archive>` | Stage a DXMT build you supply |
| `decanter dxmt use <game>` | Move one game to Metal graphics — the Unity 6 path |

> **Get DXVK 1.10.3, not the newest.** 2.x and 3.x need Vulkan 1.3 features
> MoltenVK does not fully implement, so they fail on macOS in ways that look
> like a game bug.

## Running games

| Command | What it does |
|---|---|
| `decanter add <path>` | Add a game — a folder or an `.exe`. `--name` to rename, `--exe` to pick which executable |
| `decanter list` | Every game, with its runtime and graphics layer |
| `decanter info <game>` | Detection evidence and current settings |
| `decanter run <game>` | Launch it. `--debug` for verbose graphics logging, `--hud` for the overlay |
| `decanter check <game>` | Dry run — would it launch? Verifies the environment without starting anything |
| `decanter exe <game>` | List every executable; pick a different one, or run one once |
| `decanter recommend <game>` | Which setup to use, and why. Launches nothing. `--apply` to accept it |
| `decanter autoconfig <game>` | Try each setup for real and keep the one that works |
| `decanter args <game> [flags]` | Engine switches like `-force-d3d12`. No arguments lists suggestions |
| `decanter env <game> [japanese]` | Environment and locale overrides, for CJK games |
| `decanter install <game> <verb>` | Windows components — presets, or raw winetricks verbs |
| `decanter recipes` | Available presets, helper status, and what each game has installed |

## When something breaks

| Command | What it does |
|---|---|
| `decanter diagnose <game>` | Classify the last failure and name what would plausibly change it |
| `decanter report <game>` | Full problem report, copied to your clipboard. Home paths are replaced with `~` |
| `decanter mods <game>` | BepInEx status, plugins, and whether the loader actually ran |
| `decanter fonts [--check]` | Map Windows font names onto macOS faces — the fix for blank menus |
| `decanter reap [--list]` | Find and end Wine processes left running by an earlier session |
| `decanter redetect [game]` | Re-inspect with the current rules. All games if omitted |
| `decanter rederive <game>` | Throw the environment away and rebuild it. Saves are kept |
| `decanter worked <game>` | Remember the current setup as working, for games of the same shape |
| `decanter knowledge` | What Decanter has learned so far, grouped by situation. Never names games |
| `decanter knowledge explain <game>` | What the knowledge base says about one game, and how closely it matched |
| `decanter knowledge export [file]` | Write the observations out to hand over — situations and outcomes only |
| `decanter knowledge forget` | Throw away everything learned, back to the shipped defaults |

## Saves

| Command | What it does |
|---|---|
| `decanter saves list` | Every game's saves at a glance |
| `decanter saves show <game>` | What was found, and where |
| `decanter saves snapshot <game>` | Snapshot now. `--all` for every game |
| `decanter saves snapshots <game>` | List snapshots |
| `decanter saves restore <game>` | Restore the newest snapshot, or name one |
| `decanter saves search <text>` | Search across every game's saves |
| `decanter saves externalise <game>` | Move saves out of the environment so a rebuild cannot touch them |
| `decanter saves gc` | Prune old snapshots |
| `decanter import <game> <dir>` | Restore saves from elsewhere — files and registry both |

## Windows environments

| Command | What it does |
|---|---|
| `decanter bottles` | Every environment: runtime, graphics layer, health |
| `decanter backend <game> <dxvk\|d3dmetal\|wined3d\|dxmt>` | Change the graphics layer directly |
| `decanter remove <game>` | Delete the game and its environment. Saves are kept unless you say otherwise |
| `decanter gc` | Delete environments no game points at |

## Installing the CLI

`./install.sh` builds in release mode, assembles `Decanter.app` into
`/Applications`, and puts `decanter` on your `PATH`. A locally built app is
never quarantined, so this also avoids the unsigned-app warning entirely.
