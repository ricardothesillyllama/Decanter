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
# Not tolerated silently. If Finder automation is refused, or the layout does
# not take, the image still builds and still opens — it just looks broken, and
# nobody finds out until somebody downloads it. That is what happened: the
# background was sized in points Finder read from its DPI, the window grew to
# fit, the icon positions did not, and the Applications alias landed on top of
# the word "Drag". A release artifact that quietly looks wrong is worse than a
# build that stops.
osascript <<EOF >/dev/null || { echo "  window layout failed — Finder automation may not be permitted"; exit 1; }
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
    -- Parked below the window rather than left where Finder dropped them.
    -- They are invisible to almost everybody, and they were sitting at the top
    -- left of the layout for the people who have hidden files switched on —
    -- which is most people who would build this, and at least one person who
    -- reported the window looking wrong because of it. A saved position costs
    -- nothing and cannot be seen by anyone it does not affect.
    try
      set position of item ".background" of container window to {110, 620}
    end try
    try
      set position of item ".fseventsd" of container window to {230, 620}
    end try
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF
sync

# Check the bytes that ship, not what Finder says.
#
# The first version of this asked Finder to read the layout back, and it passed
# with the layout deliberately broken: Finder caches view state per volume
# *name*, so a volume called "Decanter" is answered from whatever it learned
# the last time one was mounted — including from a window somebody resized by
# hand. The positions actually shipped live in .DS_Store, so that is what is
# read, with no Finder in the loop.
DS="/Volumes/Decanter/.DS_Store"
python3 - "$DS" <<'PYEOF' || { echo "  the layout in .DS_Store is not what was set"; \
  hdiutil detach "$DEV" -quiet 2>/dev/null || hdiutil detach "$DEV" -force -quiet; exit 1; }
import re, struct, sys
d = open(sys.argv[1], 'rb').read()
found = {}
for m in re.finditer(re.escape(b'Iloc'), d):
    i = m.end()
    if d[i:i+4] != b'blob':
        continue
    if struct.unpack('>I', d[i+4:i+8])[0] != 16:
        continue
    x, y = struct.unpack('>ii', d[i+8:i+16])
    # The name is the UTF-16BE run immediately before the key.
    tail = d[max(0, m.start()-64):m.start()].decode('utf-16-be', 'ignore')
    for name in ("Decanter.app", "Applications"):
        if tail.endswith(name):
            found[name] = (x, y)
want = {"Decanter.app": (170, 205), "Applications": (450, 205)}
if found != want:
    print("    wanted", want)
    print("    got   ", found or "no icon positions at all")
    sys.exit(1)
PYEOF

hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
hdiutil convert "$TMP" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -f "$TMP"
rm -rf "$STAGE"

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
