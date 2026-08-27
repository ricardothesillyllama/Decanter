# Getting the runtimes

Decanter downloads nothing and bundles nothing. It never contacts the network at
all. You supply the runtimes; Decanter takes its own copy of each and manages
them from then on.

That is deliberate, and it is the reason this project exists. Whisky fetched its
Wine at setup time, the upstream repository was deleted, and every installed copy
became unable to finish setting itself up. Nothing upstream can reach into a
Decanter install.

**It does not mean you have to use the Terminal.** Open **Setup** in the app and
it tells you which pieces are missing, what each one is for, and links to where
it comes from. Then drop the file on the window — Decanter works out what it is
by looking inside, so the exact path and the exact filename do not matter.

## Before you start

- An **Apple Silicon Mac**, macOS 14 or later.
- **Rosetta 2.** Everything here is an x86_64 program, so this is not optional.
  Setup installs it for you; `softwareupdate --install-rosetta` does the same
  thing from a terminal.
- **At least one Wine build** — the first of the three below. The other two are
  optional and each buys you something specific.

Building from source additionally needs the **Xcode Command Line Tools**
(`xcode-select --install`). Full Xcode is not needed, and neither is any of this
if you use the released disk image.

> **Rosetta has an end date.** Apple has said macOS 27 is the last release to
> include it in full, and macOS 28 removes it, keeping only a subset aimed at
> older unmaintained games. Wine is unlikely to fall under that carve-out.
> `decanter doctor` reports where your Mac sits relative to that. There is no
> fix in this project — an arm64-native Wine is upstream work — but it is an
> assumption Decanter rests on, so it says so plainly rather than letting you
> find out later.

## A mainline Wine build — required

This is the part that lets a Windows program run at all. Any Apple Silicon Wine
build works — for example the builds published by
[Gcenx](https://github.com/Gcenx/macOS_Wine_builds/releases/latest), where the
file to take is the one ending `-osx64.tar.xz`.

Drop the downloaded archive, the app, or its folder on the window. If it is
already in `/Applications`,
Setup will have found it already and offers a **Use It** button instead.

## Game Porting Toolkit — optional, and usually worth it

GPTK gives you D3DMetal, Apple's Direct3D-to-Metal translation, which is the
fastest option for modern 3D games. Apple distributes it from the
[developer downloads](https://developer.apple.com/download/all/) page (search
"Game Porting Toolkit"; an ordinary Apple ID is enough).

It arrives as a disk image — **drop the whole `.dmg` on the window.** Decanter
mounts it, takes the Wine tree out, and ejects it.

GPTK is built on Wine 7.7 from 2022, so it is not a replacement for a current
Wine: newer titles often refuse it. Having both, and letting Decanter pick per
game, is the point.

## Metal graphics (DXMT) — optional, and the only way to run Unity 6

DXMT translates Direct3D 11 straight to Metal. It is the only layer here that
runs a Unity 6 game: D3DMetal has no `ID3D11Fence`, DXVK on MoltenVK cannot
create the device at any feature level, and WineD3D cannot either.

It is fussier about its Wine than anything else, and about a detail nothing
else cares about. **Two things must both be true of the Wine build:**

1. `lib/wine/x86_64-unix/winemac.so` is a Mach-O **dylib**. DXMT's Metal bridge
   hard-links it, and macOS refuses to link against a Mach-O *bundle*. This
   rules out the Game Porting Toolkit, whose driver is a bundle.
2. That same driver **exports `macdrv_functions`**. DXMT asks for it with
   `dlsym` at the first frame, so a build that fails only this test loads fine,
   reaches a Direct3D 11 device, and then dies with *"your Wine has no exported
   symbols needed by DXMT"*. Mainline Wine is exactly that build.

`decanter doctor` reports which of the two a pinned runtime fails.

A build satisfying both: **Gcenx's Sikarugir build of Wine 10**, published as
`WS12WineSikarugir10.0_6.tar.xz` at
[Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines/releases/tag/v1.0)
(LGPL-2.1+). Drop the `.tar.xz` on the window like any other Wine build.

> **It is not self-contained.** That engine expects its supporting libraries
> (GStreamer, ffmpeg, glib, libinotify, libintl, freetype) to be supplied
> alongside it, and ships none of them. Without them `wineboot` fails with
> "no prefix". If you already have the Game Porting Toolkit pinned, its `lib`
> directory contains every one of them — copying them into the Sikarugir
> runtime's `lib` is enough. Decanter does not do this for you yet.

Then hand Decanter a DXMT release (`dxmt-*.tar.gz` from
[3Shain/dxmt](https://github.com/3Shain/dxmt/releases)) and pick Metal graphics
for the game. Choosing DXMT clones the runtime and installs DXMT into the copy,
so the original stays clean; the clone appears in `decanter runtime list` with
a `-dxmt` suffix and is removed along with its base by
`decanter runtime remove`.

## DXVK — optional

DXVK translates Direct3D to Vulkan. It is a second way to draw a game, and often
works when Apple's does not. Download a release tarball from
[doitsujin/dxvk](https://github.com/doitsujin/dxvk/releases) and drop it on the
window.

> **Get 1.10.3, not the newest.** DXVK 2.x and 3.x require Vulkan 1.3 features
> MoltenVK does not fully implement, so they fail on macOS in ways that look
> like game bugs. 1.10.3 targets Vulkan 1.1 and is the one that works here. You
> can stage several versions and switch per game with `decanter dxvk use`.

## Licensing

None of these are this project's work, and none are redistributed by it: Wine is
LGPL, DXVK is zlib-licensed, and the Game Porting Toolkit is Apple's, under
Apple's terms.
