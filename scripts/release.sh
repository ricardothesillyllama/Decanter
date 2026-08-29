#!/bin/sh
# Everything that has to be true before a release, in one command.
#
#   ./scripts/release.sh          -> check, build, package. Stops at the first failure.
#   ./scripts/release.sh --quick  -> skips the parts that touch real runtimes
#
# The pieces already existed as separate scripts, which meant a release was a
# sequence somebody had to remember. Every version shipped this month was cut by
# running them in the right order from memory, and the one time that went wrong
# it shipped a tag whose source claimed the previous version.
#
# This does not tag and does not push. Deciding a thing is finished is a
# judgement; checking whether it is sound is not, and only the second belongs in
# a script.
set -e
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
QUICK=0
[ "$1" = "--quick" ] && QUICK=1

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }

step "release check for $VERSION"

# 1. A release is cut from a commit, so there has to be one. A dirty tree means
#    the tag would point at something that is not what was tested.
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  fail "there are uncommitted changes — the tag would not point at what was tested"
fi
ok "working tree is clean"

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  fail "v$VERSION is already tagged — run ./scripts/bump.sh first"
fi
ok "v$VERSION is not yet tagged"

# 2. The rules that are enforced mechanically rather than remembered.
step "rules"
./scripts/check-rules.sh

# 3. The suite. Warnings are errors here for the same reason they are in CI:
#    a warning nobody has to fix is a warning nobody fixes.
step "build"
swift build -Xswiftc -warnings-as-errors 2>&1 | tail -3
ok "builds clean with warnings as errors"

step "suite"
swift run selftest > .build/selftest.log 2>&1 || {
  tail -20 .build/selftest.log
  fail "the suite did not pass"
}
tail -3 .build/selftest.log | head -2
ok "$(grep TOTAL_CHECKS .build/selftest.log | cut -d= -f2) checks passed"

# 4. The check count in the documents, regenerated from the suite that just ran.
#
#    This is the only place it can be done. CI runs a subset — the launch suite
#    needs a pinned runtime a fresh runner does not have — so regenerating it
#    there would write a smaller number every time. The `docs` suite compares
#    the documents to each other and not to reality, which is why all three
#    agreed on 577 for months while the suite ran hundreds more.
step "check count"
./scripts/sync-docs.sh > /dev/null
if [ -n "$(git status --porcelain README.md CONTRIBUTING.md)" ]; then
  git --no-pager diff --stat README.md CONTRIBUTING.md
  fail "the documented check count was out of date — it has been corrected, commit it and run this again"
fi
ok "README and CONTRIBUTING report the count this suite actually produced"

# 5. A changelog entry, because a version nobody can find out about is a version
#    that may as well not have shipped.
step "changelog"
grep -q "^## v$VERSION" CHANGELOG.md || fail "CHANGELOG.md has no entry for v$VERSION"
if grep -A2 "^## v$VERSION" CHANGELOG.md | grep -q "_Unreleased._"; then
  fail "the CHANGELOG entry for v$VERSION is still the placeholder"
fi
ok "CHANGELOG.md describes v$VERSION"

# 6. Anything vouched for has to still check out. A signature that no longer
#    verifies means either the row was edited after the fact or this build
#    carries a different key — and shipping either would put a claim in front of
#    people that Decanter itself cannot stand behind.
if [ "$QUICK" -eq 0 ]; then
  step "endorsements"
  if swift run decanter endorse list 2>/dev/null | grep -q '✗'; then
    swift run decanter endorse list 2>/dev/null | grep -A1 '✗'
    fail "an endorsed row no longer verifies"
  fi
  ok "every endorsement still checks out"

  # 7. The capability measurements, against whatever this Mac actually has.
  #    Not a gate — another Mac has other runtimes — but a release cut without
  #    looking is a release where nobody noticed the bench had stopped working.
  step "runtimes on this Mac (reported, not enforced)"
  swift run decanter bench 2>/dev/null | grep -E '^(wine|gptk)|✗|✓' | head -30 || true
fi

# 8. The artefacts.
step "package"
./install.sh > .build/install.log 2>&1 || { tail -20 .build/install.log; fail "install.sh failed"; }
ok "app and CLI built"
./scripts/make-dmg.sh > .build/dmg.log 2>&1 || { tail -20 .build/dmg.log; fail "make-dmg.sh failed"; }
ok "dist/Decanter-$VERSION.dmg"

# install.sh stamps the commit into the source, so the tree is dirty again by
# design. Saying so beats leaving somebody to discover it.
step "ready"
echo "  v$VERSION is sound. install.sh restamped the commit, so commit that, then:"
echo ""
echo "    git commit -am \"$VERSION\" && git tag v$VERSION && git push && git push --tags"
echo "    gh release create v$VERSION dist/Decanter-$VERSION.dmg --notes-file <(...)"
echo ""
