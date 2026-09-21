# Sourced by the scripts that build. Picks an SDK the Command Line Tools can
# actually compile the app against.
#
# macOS 27's SDK made SwiftUI's @State a macro, and the macro's implementation
# ships with Xcode only — the Command Line Tools for 27 have no SwiftUI macro
# plugin at all, so every view with @State fails with "external macro
# implementation type 'SwiftUIMacros.StateMacro' could not be found". The 26.x
# SDK the same tools install alongside still declares @State as a property
# wrapper, and an app built against it runs on 27 unchanged. Only applies when
# nothing was chosen already, when the active tools are the Command Line Tools,
# and when the plugin really is missing — Xcode, or tools that ship it, are
# left alone.
CLT=/Library/Developer/CommandLineTools
if [ -z "$SDKROOT" ] && [ "$(xcode-select -p 2>/dev/null)" = "$CLT" ] \
   && [ -z "$(find "$CLT/usr/lib/swift" -iname '*SwiftUIMacros*' 2>/dev/null | head -1)" ]; then
  for sdk in "$CLT"/SDKs/MacOSX26.[0-9]*.sdk; do
    [ -d "$sdk" ] && SDKROOT="$sdk"
  done
  if [ -n "$SDKROOT" ]; then
    export SDKROOT
    echo "  building against $(basename "$SDKROOT"): these Command Line Tools cannot expand SwiftUI's macros"
  fi
fi
