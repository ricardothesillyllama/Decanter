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

[ "$fail" = 0 ] && echo "  ✓ all rules hold"
exit "$fail"
