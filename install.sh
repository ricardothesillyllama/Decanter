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

echo "building Decanter $VERSION (release)"
swift build -c release

echo "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist   "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/DecanterApp "$APP/Contents/MacOS/Decanter"


# The CLI goes to the first writable directory that is already on PATH, so this
# works without Homebrew. ~/.local/bin is created if nothing else fits.
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [ -d "$d" ] && [ -w "$d" ]; then CLI_DIR="$d"; break; fi
done
if [ -z "$CLI_DIR" ]; then CLI_DIR="$HOME/.local/bin"; mkdir -p "$CLI_DIR"; fi
cp .build/release/decanter "$CLI_DIR/decanter"
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
