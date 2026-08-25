#!/bin/sh
# Builds a disk image for release. This is how a Mac app is expected to arrive:
# open it, drag it into Applications, eject. Nothing to read first.
#
#   ./scripts/make-dmg.sh   ->  dist/Decanter-<version>.dmg
set -e
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=".build/Decanter.app"
STAGE=".build/dmg-stage"
OUT="dist/Decanter-$VERSION.dmg"

[ -d "$APP" ] || { echo "no built app — run ./install.sh first"; exit 1; }
mkdir -p dist
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/.background"

cp -R "$APP" "$STAGE/Decanter.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.png "$STAGE/.background/background.png"

# Lay the window out so the arrow in the background points from the app to the
# Applications alias. Without this the icons land wherever Finder feels like.
TMP=".build/dmg-rw.dmg"
rm -f "$TMP"
hdiutil create -srcfolder "$STAGE" -volname "Decanter" -fs HFS+ \
  -format UDRW -ov -quiet "$TMP"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP" | grep '/Volumes/' | head -1 | awk '{print $1}')
sleep 1
osascript <<EOF >/dev/null 2>&1 || echo "  (window layout skipped — Finder automation not permitted)"
tell application "Finder"
  tell disk "Decanter"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, 820, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:background.png"
    set position of item "Decanter.app" of container window to {170, 205}
    set position of item "Applications" of container window to {450, 205}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF
sync
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
hdiutil convert "$TMP" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -f "$TMP"
rm -rf "$STAGE"

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
