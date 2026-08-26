# Getting the runtimes

Decanter downloads nothing and bundles nothing. It never contacts the network at
all. You supply the runtimes; Decanter takes its own copy of each and manages
them from then on.

That is deliberate, and it is the reason this project exists. Whisky fetched its
Wine at setup time, the upstream repository was deleted, and every installed copy
became unable to finish setting itself up. Nothing upstream can reach into a
Decanter install.

**It does not mean you have to use the Terminal.** Open **Setup** in the app and
it tells you which pieces are missing, what each is for, and links to where it
comes from. Then drop the file on the window — Decanter identifies it by looking
inside, so the exact path and filename do not matter.

Open **Setup** in the app and it tells you which of these you are missing, what
each one is for, and links to where it comes from. Then drop the file on the
window — Decanter works out what it is by looking inside, so the exact path and
the exact filename do not matter.

**Game Porting Toolkit (GPTK)** gives you D3DMetal, Apple's Direct3D-to-Metal
translation, which is the fastest option for modern 3D games. Apple distributes
it from the [developer downloads](https://developer.apple.com/download/all/)
page (search "Game Porting Toolkit"; a free Apple ID is enough). It arrives as a
disk image — **drop the whole `.dmg` on the window.** Decanter mounts it, takes
the Wine tree out, and ejects it.

**A mainline Wine build** covers everything GPTK cannot. GPTK is based on
Wine 7.7 from 2022, so newer titles often need something current. Any Apple
Silicon Wine build works — for example the casks published by
[Gcenx](https://github.com/Gcenx/homebrew-wine). Drop the app or its folder on
the window; if it is already in `/Applications`, Setup will have found it and
offers a **Use It** button instead.

**DXVK** translates Direct3D to Vulkan, and is a second way to draw a game that
often works when Apple's does not. Download a release tarball from
[doitsujin/dxvk](https://github.com/doitsujin/dxvk/releases) and drop it on the
window.

> **Get 1.10.3, not the newest.** DXVK 2.x and 3.x require Vulkan 1.3 features
> MoltenVK does not fully implement, so they fail on macOS in ways that look
> like game bugs. 1.10.3 targets Vulkan 1.1 and is the one that works here. You
> can stage several versions and switch per game with `decanter dxvk use`.

Neither runtime is redistributed by this project, and none of them are its work:
Wine is LGPL, DXVK is zlib-licensed, and GPTK is Apple's, under Apple's terms.

## Requirements

- Apple Silicon Mac, macOS 14 or later
- **Xcode Command Line Tools** — `xcode-select --install`. Full Xcode is not needed.
- **Rosetta 2** — `softwareupdate --install-rosetta`. Everything here is an
  x86_64 program, so this is not optional.

> **Rosetta has an end date.** Apple has said macOS 27 is the last release to
> include it in full, and macOS 28 removes it, keeping only a subset aimed at
> older unmaintained games. Wine is unlikely to fall under that carve-out.
> `decanter doctor` reports where your Mac sits relative to that. There is no
> fix in this project — an arm64-native Wine is upstream work — but it is an
> assumption Decanter rests on, so it says so plainly rather than finding out
> later.
- At least one Wine build, and ideally two (see below)

Decanter downloads nothing and bundles nothing. It never contacts the network at
all. You supply the runtimes; Decanter takes its own copy of each and manages
them. That is deliberate — Whisky died because the runtime it fetched at setup
time was deleted upstream, and installed copies could no longer finish setting
themselves up.
