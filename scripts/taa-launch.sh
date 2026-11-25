#!/usr/bin/env bash
# Launch a macOS app/binary with the TAA/MetalFX injector loaded via DYLD_INSERT_LIBRARIES.
#
#   scripts/taa-launch.sh /Applications/Some.app [args...]
#   TAA_OUTPUT=4k TAA_LOG=1 scripts/taa-launch.sh path/to/binary
#
# Unsupported study PoC — see README.md. Use at your own risk.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
dylib="${TAA_DYLIB:-$here/build/libtaa_inject.dylib}"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <App.app | executable> [args...]" >&2
  exit 2
fi
target="$1"; shift

if [[ ! -f "$dylib" ]]; then
  echo "injector not built: run 'make' first ($dylib)" >&2
  exit 1
fi

if [[ -d "$target" && "$target" == *.app ]]; then
  exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target/Contents/Info.plist")"
  bin="$target/Contents/MacOS/$exe_name"
  bundle="$target"
else
  bin="$target"
  bundle="$target"
fi
[[ -x "$bin" ]] || { echo "not executable: $bin" >&2; exit 1; }

# Architecture check: a Rosetta (x86_64-only) game needs the x86_64 slice, which the default build has.
archs="$(lipo -archs "$bin" 2>/dev/null || true)"
echo "[taa-launch] target: $bin ($archs)"

# Hardened runtime check: DYLD_INSERT_LIBRARIES is ignored, or the ad-hoc dylib is refused,
# unless the app has the matching entitlements.
sig="$(codesign -dv "$bundle" 2>&1 || true)"
if grep -q 'flags=.*runtime' <<<"$sig"; then
  ents="$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
  missing=()
  grep -q 'com.apple.security.cs.allow-dyld-environment-variables' <<<"$ents" || missing+=(allow-dyld-environment-variables)
  grep -q 'com.apple.security.cs.disable-library-validation' <<<"$ents" || missing+=(disable-library-validation)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[taa-launch] WARNING: hardened runtime without: ${missing[*]}" >&2
    echo "[taa-launch]          injection will most likely be ignored or the dylib rejected." >&2
    echo "[taa-launch]          see scripts/resign-copy.sh (re-signs a COPY of the app; at your own risk)." >&2
  fi
fi

export DYLD_INSERT_LIBRARIES="$dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
exec "$bin" "$@"
