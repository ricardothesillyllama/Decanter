#!/bin/sh
# Builds Decanter and installs the app plus the CLI.
#
# The .app bundle is assembled here from Resources/ rather than kept in the
# repo: a committed bundle means a fresh clone carries a stale binary, and the
# _CodeSignature inside it conflicts on every rebuild. Everything under
# .build/ is disposable and reproducible from source.
set -e
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=.build/Decanter.app

# Stamp the commit so a problem report from a source build is attributable —
# but only when there is something to attribute that the version does not
# already say.
#
# Stamping a hash into a release could never be right. install.sh runs from
# release.sh, before the release commit exists, so the hash it wrote always
# named the commit *before* the tag: v0.6.0 shipped reporting 7f1ffae while the
# tag pointed at bde58b5. Writing it afterwards is not possible either, because
# writing it changes the commit it would have to name.
#
# A clean tree stamps nothing, and that terminates: the second run over the
# release commit produces the same empty stamp and so no diff at all. A clean
# tree is also a tree whose contents are public, and the version identifies it.
# A dirty one is the case the hash was for, and it still gets one.
if [ -n "$(git status --porcelain 2>/dev/null | grep -v 'Sources/DecanterKit/Model.swift')" ]; then
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
elif git rev-parse HEAD >/dev/null 2>&1; then
  COMMIT=""
else
  COMMIT="dev"
fi
/usr/bin/sed -i '' -E "s/public static let version = \".*\"/public static let version = \"$VERSION\"/; s/public static let commit = \".*\"/public static let commit = \"$COMMIT\"/" Sources/DecanterKit/Model.swift

echo "building Decanter $VERSION (release)"
# -gnone keeps debug info out of the binary. Swift otherwise embeds the
# absolute path of every source file, which puts the builder's home directory
# — and so their username — inside anything published as a release artifact.
swift build -c release -Xswiftc -gnone

echo "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist   "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/DecanterApp "$APP/Contents/MacOS/Decanter"

# Belt and braces: strip local and debug symbols regardless of how it was
# built. Must happen before signing, since stripping invalidates a signature.
strip -S "$APP/Contents/MacOS/Decanter" 2>/dev/null || true


# The CLI goes to the first writable directory that is already on PATH, so this
# works without Homebrew. ~/.local/bin is created if nothing else fits.
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [ -d "$d" ] && [ -w "$d" ]; then CLI_DIR="$d"; break; fi
done
if [ -z "$CLI_DIR" ]; then CLI_DIR="$HOME/.local/bin"; mkdir -p "$CLI_DIR"; fi
cp .build/release/decanter "$CLI_DIR/decanter"
strip -S "$CLI_DIR/decanter" 2>/dev/null || true
echo "CLI installed to $CLI_DIR/decanter"
case ":$PATH:" in
  *":$CLI_DIR:"*) ;;
  *) echo "  note: $CLI_DIR is not on your PATH" ;;
esac

# Signing with a stable identity matters more than it looks. An ad-hoc
# signature makes the app's designated requirement its cdhash, so macOS treats
# every rebuild as a different app and forgets granted permissions.
# NOTE: -v lists only TRUSTED identities. A self-signed cert that has not had
# its trust setting changed is usable for signing but invisible to -v.
if security find-certificate -c "Decanter Dev" >/dev/null 2>&1; then
  echo "signing with the stable 'Decanter Dev' identity"
  codesign --force --deep -s "Decanter Dev" "$APP"
else
  echo "no 'Decanter Dev' identity found - falling back to ad-hoc."
  echo "  permissions will reset on every rebuild until you create one; see README."
  codesign --force --deep -s - "$APP"
fi

# Install the signed bundle, not an unsigned copy of it. Signing /Applications
# afterwards left the bundle in .build unsigned, so anything packaged from it
# for a release shipped without a signature and with the wrong identifier.
rm -rf /Applications/Decanter.app
cp -R "$APP" /Applications/Decanter.app
echo "installed Decanter $VERSION."
