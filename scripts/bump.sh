#!/bin/sh
# Moves the version on, because a released one cannot move.
#
#   ./scripts/bump.sh          -> next patch  (0.3.0 -> 0.3.1)
#   ./scripts/bump.sh 0.4.0    -> exactly that
#
# Info.plist is the single source of truth; install.sh rewrites the constant in
# Model.swift from it, so there is nothing else to edit.
set -e
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

if [ -n "$1" ]; then
  NEXT="$1"
else
  # OFS must be set before the assignment: awk rebuilds the record using the
  # separator in effect at that moment, so setting it afterwards yields
  # "0 3 1".
  NEXT=$(printf '%s' "$CURRENT" | awk -F. -v OFS=. '{ $NF = $NF + 1; print }')
fi

case "$NEXT" in
  *.*.*) ;;
  *) echo "version must look like 1.2.3, got '$NEXT'"; exit 1 ;;
esac

if git rev-parse "v$NEXT" >/dev/null 2>&1; then
  echo "v$NEXT is already tagged — pick a later version"; exit 1
fi

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"

# A version with no changelog entry is a version nobody can find out about.
if ! grep -q "^## v$NEXT" CHANGELOG.md; then
  TODAY=$(date +%Y-%m-%d)
  /usr/bin/sed -i '' "s|^# Changelog$|# Changelog\\
\\
## v$NEXT — $TODAY\\
\\
_Unreleased._|" CHANGELOG.md
fi

echo "$CURRENT -> $NEXT (build $((BUILD + 1)))"
echo "  next: edit the CHANGELOG entry, then ./install.sh"
