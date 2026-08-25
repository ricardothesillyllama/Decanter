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

