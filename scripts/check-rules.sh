#!/bin/sh
# Enforces the rules in CONTRIBUTING mechanically.
#
# Each of these exists because breaking it caused a real failure. A rule kept
# only in a document is a rule enforced by memory, which is not enforcement.
set -e
cd "$(dirname "$0")/.."
fail=0
note() { echo "  ✗ $1"; fail=1; }

# 1. No external dependencies — every dependency is a future 404.
if grep -qE '^\s*\.package\(' Package.swift; then
  note "Package.swift declares an external dependency"
fi

# 2. Never build a command as a shell string. A verb interpolated into sh -c
#    was a command injection.
if grep -rn 'Shell.run(URL(filePath: "/bin/sh")' Sources/ >/dev/null 2>&1; then
  note "Shell.run is invoking /bin/sh — pass an argv array instead"
fi
# Only a shell's -c matters. cp -c is an APFS clone and is fine, which the
# first version of this check did not know.
if grep -rnE '(bin/(sh|bash|zsh)|/usr/bin/env")' Sources/DecanterKit/ Sources/decanter/ 2>/dev/null \
   | grep -v '^\s*//' >/dev/null 2>&1; then
  note "a shell is being invoked from the engine or CLI — pass an argv array instead"
fi

# 3. Never compare file URLs with ==. Directory-flagged URLs and /var versus
#    /private/var both make identical paths compare unequal.
if grep -rnE '\.standardizedFileURL\s*==|resolvingSymlinksInPath\(\)\s*==' Sources/ >/dev/null 2>&1; then
  note "file URLs compared with == — use url.pathKey"
fi

# 4. No game may see the whole filesystem. z: is the mapping Whisky shipped.
if grep -rn 'dosdevices/z:' Sources/DecanterKit/Prefix.swift 2>/dev/null | grep -viE 'remove|delete|descope|escap' >/dev/null 2>&1; then
  note "prefix construction appears to create a z: mapping"
fi

# 5. Decanter must never fetch anything. This is the project's central claim:
#    Whisky's installed copies broke when the runtime it downloaded was deleted
#    upstream, and "we don't download" is only true if nothing here can. The
#    Setup page points at download pages, which the *user's browser* opens —
#    NSWorkspace.open is allowed, URLSession and friends are not.
if grep -rnE 'URLSession|NSURLConnection|CFNetwork|Network\.framework|import Network\b' \
     Sources/DecanterKit/ Sources/decanter/ Sources/DecanterApp/ 2>/dev/null \
   | grep -vE '^\s*//' >/dev/null 2>&1; then
  note "networking API found — Decanter downloads nothing, by design"
fi
if grep -rnE 'Shell\.run\(URL\(filePath: "/usr/bin/(curl|wget)"' Sources/ >/dev/null 2>&1; then
  note "curl or wget is being invoked — Decanter downloads nothing, by design"
fi

# 6. Persisted types decode by hand. Synthesised Decodable requires every
#    non-optional key and has wiped the library twice.
for type in "struct DecanterState" "struct Game" "struct Bottle" "struct DetectionResult"; do
  f=$(grep -rln "$type" Sources/DecanterKit/ 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  grep -q "init(from decoder" "$f" || note "$type has no hand-written init(from:) in $f"
done

# 7. A released version is immutable. The remote refuses to move or delete a
#    v* tag, so any change to Sources/ at a version that is already tagged is
#    code the published release does not contain — and the DMG people download
#    stops matching the tree they read.
if [ -f Resources/Info.plist ] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || true)
  # Only meaningful with tags present; a shallow clone has none, and a missing
  # tag simply means this version has not shipped yet.
  if [ -n "$VERSION" ] && git rev-parse "v$VERSION" >/dev/null 2>&1; then
    # Against the working tree, not HEAD: the point is to catch this while the
    # change is still in your editor, not after it is committed.
    if ! git diff --quiet "v$VERSION" -- Sources/ 2>/dev/null; then
      note "Sources changed since v$VERSION was tagged — run ./scripts/bump.sh"
    fi
  fi
fi

# 8. A shared signature can only hold closed vocabularies.
#
#    The knowledge base identifies a *situation*, never a game, and the
#    guarantee is that no game name can leave this machine. That holds only as
#    long as every field is an enum, a bool, or a bounded integer: one free-form
#    String is enough for a title, a path or a build id to arrive without anyone
#    deciding to let it in — and it would be a fingerprint anybody holding a
#    copy of the game could recompute.
SIG=$(/usr/bin/sed -n '/public struct Signature/,/^    }$/p' Sources/DecanterKit/Knowledge.swift)
#    Stored fields only: a computed `var label: String` is a rendering of the
#    situation, not a part of it, and flagging those made the rule cry wolf.
if printf '%s' "$SIG" | grep -vE '\{\s*$' \
   | grep -nE '^\s*public var [a-zA-Z]+: (String|URL|\[String\]|Set<String>)' >/dev/null 2>&1; then
  note "Knowledge.Signature has a free-form field — situations must be closed vocabularies"
fi
#    The export must not carry the local game id either. It is a UUID that means
#    nothing on another machine, but it is still an identifier.
if grep -n 'gameID' Sources/DecanterKit/Knowledge.swift | grep -i 'export' >/dev/null 2>&1; then
  note "the knowledge export references gameID — it must not leave this machine"
fi

[ "$fail" = 0 ] && echo "  ✓ all rules hold"
exit "$fail"
