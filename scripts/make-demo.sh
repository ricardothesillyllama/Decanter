#!/bin/sh
# Builds a throwaway Decanter library with invented games, for documentation
# screenshots. Nothing here touches your real library: everything lives under
# $DEMO_ROOT and the app is pointed at it with DECANTER_ROOT.
#
#   ./scripts/make-demo.sh
#   DECANTER_ROOT=/tmp/decanter-demo open -n /Applications/Decanter.app
#
# The "games" are Wine's own winemine.exe wearing a different name, with the
# sibling files that make detection identify an engine. They launch, so the
# screenshots are of a working library rather than a mock-up.
set -e
cd "$(dirname "$0")/.."

DEMO_ROOT="${DEMO_ROOT:-/tmp/decanter-demo}"
GAMES="$DEMO_ROOT/games"
REAL="$HOME/Library/Application Support/Decanter"
CLI="$(pwd)/.build/release/decanter"
[ -x "$CLI" ] || CLI="$(pwd)/.build/debug/decanter"
[ -x "$CLI" ] || { echo "build first: swift build"; exit 1; }

echo "resetting $DEMO_ROOT"
rm -rf "$DEMO_ROOT"
mkdir -p "$DEMO_ROOT" "$GAMES"

# Borrow the real store's runtimes and golden template so this costs seconds
# rather than a full wineboot. APFS clones, so it costs no disk either.
for d in runtimes template; do
  [ -d "$REAL/$d" ] || { echo "no $d in the real store - run 'decanter pin' first"; exit 1; }
  cp -Rc "$REAL/$d" "$DEMO_ROOT/$d" 2>/dev/null || cp -R "$REAL/$d" "$DEMO_ROOT/$d"
done
cp "$REAL/state.json" /dev/null 2>/dev/null || true
python3 - "$DEMO_ROOT" "$REAL" <<'PY'
import json, sys, pathlib
demo, real = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
# Carry over only the pinned runtimes and template dates; no games, no bottles.
src = json.loads((real/"state.json").read_text())
out = {k: v for k, v in src.items() if k in ("runtimes", "templateBuiltAt", "templateRuntimeID", "templates")}
(demo/"state.json").write_text(json.dumps(out, indent=2))
PY

# A real 64-bit PE to stand in for each game.
WINE64=$(find "$REAL/runtimes" -name winemine.exe -path "*x86_64*" | head -1)
[ -n "$WINE64" ] || { echo "no winemine.exe found in the pinned runtimes"; exit 1; }

mk_unity() {   # name, data-folder engine marker
  d="$GAMES/$1"; mkdir -p "$d/$1_Data/Managed" "$d/$1_Data/StreamingAssets"
  cp "$WINE64" "$d/$1.exe"
  : > "$d/UnityPlayer.dll"
  : > "$d/$1_Data/Managed/Assembly-CSharp.dll"
  : > "$d/$1_Data/globalgamemanagers"
}

echo "creating demo games"
mk_unity "Lantern Hollow"
mk_unity "Turnip Tactics"

# One of them is modded, so the Mods panel has something to show.
M="$GAMES/Lantern Hollow/BepInEx"
mkdir -p "$M/plugins" "$M/config"
: > "$M/plugins/CameraTools.dll"
: > "$M/plugins/Autosave.dll"
: > "$M/plugins/UIScale.dll"
cat > "$M/LogOutput.log" <<'LOG'
[Message:   BepInEx] BepInEx 5.4.22.0 - Lantern Hollow
[Info   :   BepInEx] Loading [CameraTools 1.4.0]
[Info   :   BepInEx] Loading [Autosave 2.1.0]
[Error  :   BepInEx] Could not load [UIScale 0.9.0] : missing dependency
LOG

# A second executable beside one game, so the picker has real choices.
cp "$WINE64" "$GAMES/Lantern Hollow/LanternConfig.exe"

echo "registering games"
export DECANTER_ROOT="$DEMO_ROOT"
"$CLI" add "$GAMES/Lantern Hollow" >/dev/null
"$CLI" add "$GAMES/Turnip Tactics" >/dev/null
"$CLI" list

cat <<EOF

demo library ready at $DEMO_ROOT

  open it:   DECANTER_ROOT=$DEMO_ROOT open -n /Applications/Decanter.app
  cli:       DECANTER_ROOT=$DEMO_ROOT decanter list
  remove it: rm -rf $DEMO_ROOT
EOF
