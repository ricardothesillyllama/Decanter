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

# Both keys carry the same dotted version. CFBundleVersion used to be
# incremented arithmetically here, which stopped working the moment it held
# "0.4.2" rather than a build number: sh cannot add 1 to a dotted string, so
# bump.sh exited half-done — after rewriting one key and before writing the
# changelog — and every release since has been bumped by hand.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$PLIST"

# The version constant moves here as well as in install.sh, so that the commit
# being tagged carries the version it is tagged as. install.sh alone stamps the
# working tree *after* a release is cut, which left every tag's source claiming
# the previous version: v0.4.2's Model.swift said "0.4.1", so anyone building
# from the tag got a binary that misreported itself. The commit constant cannot
# be fixed the same way — a file cannot contain its own hash — and stays
# install.sh's job.
/usr/bin/sed -i '' -E "s/public static let version = \".*\"/public static let version = \"$NEXT\"/" \
  Sources/DecanterKit/Model.swift

# A version with no changelog entry is a version nobody can find out about.
if ! grep -q "^## v$NEXT" CHANGELOG.md; then
  TODAY=$(date +%Y-%m-%d)
  /usr/bin/sed -i '' "s|^# Changelog$|# Changelog\\
\\
## v$NEXT — $TODAY\\
\\
_Unreleased._|" CHANGELOG.md
fi

echo "$CURRENT -> $NEXT"
echo "  next: edit the CHANGELOG entry, then ./install.sh"
