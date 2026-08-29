# Getting help

Decanter is maintained by one person. These are the fastest routes, roughly in
the order worth trying.

## A game will not run

1. **Open Setup.** If anything required is missing, the app says so and says
   what it is for. Most "it does nothing" reports are a missing piece.
2. **Apply Decanter's recommendation** — the suggestion on the game page, or
   `decanter recommend <game> --apply`. It costs nothing and resolves a
   surprising share of problems.
3. **If it used to work, go back.** `decanter restore <game>` says what it last
   ran on and when; `--do` puts it back. Saves are kept.
4. **Check the Wine build itself.** `decanter audit` finds libraries a build
   references but does not carry — a silent fault that looks like a broken game
   and is not one. `decanter repair <runtime>` offers to fill the gaps from
   builds already on your Mac.
5. **Check the [symptom table](README.md#troubleshooting).** Blank text, black
   screens, failing cutscenes and stuck processes each have a known cause.
6. **Read the [troubleshooting guide](docs/TROUBLESHOOTING.md)** for the detail
   behind those.
7. **Open an issue** with the *A game does not work* template. Press **Report a
   Problem** on the game page first — it copies everything the report needs.

You never have to name the game. Rename or redact it; the report is still
useful without a title.

## Something in Decanter itself is broken

Open an issue with the *Something in Decanter is broken* template, and include
`decanter doctor` output.

## A question, not a problem

[Discussions](https://github.com/ricardothesillyllama/Decanter/discussions) —
for "should I use this?", "what does this setting do?", and anything you are
not sure is a bug.

## A security issue

Do not open a public issue. See [SECURITY.md](SECURITY.md).

## What this project cannot help with

- **Games with kernel-level anti-cheat.** They do not work under any Wine and
  never will.
- **Obtaining games, or running ones you do not own.**
- **Apple's Game Porting Toolkit itself**, which is Apple's and under Apple's
  terms. Decanter only manages a copy you supply.
