# Security Policy

## Reporting a vulnerability

Please report privately using GitHub's
[security advisory form](https://github.com/ricardothesillyllama/Decanter/security/advisories/new)
rather than opening a public issue.

Decanter is a personal project with no paid support, so please do not expect a
same-day reply — but reports are read.

## What is in scope

Decanter runs untrusted Windows binaries. The security boundary it tries to
hold is **the game cannot read the rest of your Mac**. Anything that breaks that
is in scope, in particular:

- A prefix that exposes a path outside the game's own folder and the shared
  games directory — including through Wine's mapped user folders (Documents,
  Downloads, Desktop and the rest), which are a second route to your home
  directory and not only the `z:` drive.
- A way to make Decanter write outside its own store or the prefixes it owns —
  including `decanter repair`, which copies files into a pinned Wine build and
  must never write outside the build it names, nor take a file from Apple's
  `lib/external` directory, nor accept one built for a different architecture.
- A save import or registry merge that escapes the destination prefix.
- A way to make a piece of knowledge appear **verified** without a valid
  signature from the key this build ships. The tier is meant to carry exactly
  one claim — somebody ran this and watched it work — and anything that lets an
  unsigned or edited row wear it defeats the point. Note that a fork shipping
  its own public key is correct and expected, not a vulnerability: what must not
  be possible is forging an endorsement inside *this* distribution.

## What is not in scope

- Vulnerabilities in Wine, DXVK, MoltenVK, or Apple's Game Porting Toolkit.
  Decanter neither ships nor patches them; report those upstream. This includes
  a library `decanter repair` copies between two builds you pinned yourself:
  Decanter checks that it loads and where it came from, not what is in it.
- The fact that a Windows game can read and write its own folder. That is the
  point of the program.
- Missing notarisation. Releases are signed with a self-signed certificate
  because there is no paid Apple Developer account; this is documented in the
  README rather than hidden.
