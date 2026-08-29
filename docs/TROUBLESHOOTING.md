# Troubleshooting

The [symptom table in the README](../README.md#troubleshooting) covers the
common cases. This is the detail behind it.

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

The hard case: nothing crashes, so the log is nearly empty. Turn the noise up
before reporting it:

    decanter run <game> --debug    # verbose D3D/DXGI/Vulkan/DXVK/MoltenVK logging

Then `decanter report <game>` as above. The same flow is in the app under
"Something looks wrong?", and on the right-click menu of any game in the
sidebar.

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

If mapping the fonts changes nothing, the problem may be one layer down — the
Wine build's own font library failing to load. See below.

## Nothing wrong with the game: the Wine build is incomplete

The worst failures here are silent. A Wine build that is missing a library it
references does not report anything: the load returns nothing, the caller takes
its fallback path, and the result is text that never draws or video that never
plays. Every check that asks "is the file there?" says yes, because the file
that is missing is one the *other* file needs.

    decanter audit                    # what each build is missing, and what stops working
    decanter audit <runtime> --detail # exactly which, and what needs them
    decanter repair <runtime>         # what could be done about it, without doing it
    decanter repair <runtime> --do    # do it
    decanter repair <runtime> --undo  # remove exactly what was copied

Everything comes from a Wine build already on this Mac — nothing is downloaded,
and a build that has nothing to borrow from says so rather than reaching for the
network. Two real examples, both found this way:

- A hand-assembled build had `libfreetype` copied in without the four libraries
  FreeType itself links against. Every font call failed and no font mapping
  could have helped.
- Apple's Game Porting Toolkit cannot reach its own bundled GStreamer from its
  32-bit side, so 32-bit games play no video on it.

## What worked before

If a game used to run and now does not, you do not have to work out what
changed:

    decanter restore <game>        # what it last worked on, and when
    decanter restore <game> --do   # put it back there

Saves are kept. If Decanter could not tell whether the last launch worked, it
asks once:

    decanter verdict               # the question, and how to answer it
    decanter verdict worked
    decanter verdict failed --why noDevice
    decanter verdict skip          # nothing is recorded, and it does not come back

## Red text in a mod log that is not a mod's fault

BepInEx logs `Unable to start Unity log writer` on some games at error level.
No mod is affected — every plugin still loads and the game runs. What it does
mean is that the game's own messages reach only the console window and are never
written to `LogOutput.log`, so the file appears to stop moments after startup.

A log that ends just after "Chainloader startup complete" is that, not a game
that stopped. If you need the game's own output, read the console window while
it runs.

    decanter mods <game>            # what actually went wrong, and what did not
    decanter mods <game> --detail   # the exact lines

A game that cannot reach Steam is reported the same way — as a notice rather
than a failure. The game runs; achievements, cloud saves and friends do not.

## When a game names a missing Windows file

Wine provides most of what games need, but some ask for a Visual C++ runtime or
a codec by name. **Windows Components** on the game page installs those one at a
time, or:

```sh
decanter install <game> vcrun      # the usual answer to a missing MSVC file
decanter install <game> media      # video and audio codecs
decanter recipes                   # everything available
```

This is the one part of Decanter that reaches the network: winetricks fetches
the redistributables from their publishers. It is deliberately opt-in and
per-component — installing everything up front is how a Windows environment goes
wrong.

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

