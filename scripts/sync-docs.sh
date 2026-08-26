#!/bin/sh
# Rewrites the check count in the docs from the suite itself.
#
# The number drifted to 328 in CONTRIBUTING against 337 in the README, which is
# the argument for generating it: a figure kept in step by hand is a figure that
# is wrong. CI runs this and fails if it produces a diff.
set -e
cd "$(dirname "$0")/.."

swift build -c release >/dev/null
N=$(./.build/release/selftest "$@" 2>/dev/null | grep '^TOTAL_CHECKS=' | cut -d= -f2)
[ -n "$N" ] || { echo "could not read a check count from the suite"; exit 1; }

for f in README.md CONTRIBUTING.md; do
  /usr/bin/sed -i '' -E "s/\*\*[0-9]+ checks\*\*/**$N checks**/g; s/\*\*[0-9]+ checks\.\*\*/**$N checks.**/g" "$f"
done
echo "docs report $N checks"
