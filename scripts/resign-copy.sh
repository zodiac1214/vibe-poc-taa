#!/usr/bin/env bash
# Make a COPY of an app and ad-hoc re-sign it with the entitlements DYLD_INSERT_LIBRARIES needs
# under the hardened runtime. The original app is never touched. No code is modified, only the
# code signature, but the copy loses its developer signature/notarization.
#
#   scripts/resign-copy.sh /Applications/Some.app [~/taa-apps/Some.app]
#
# This weakens the security of the copy and may break DRM, launchers, anti-cheat or online play,
# and may violate the software's terms. Unsupported study PoC — see README.md. Use at your own risk.
set -euo pipefail

src="${1:?usage: $0 <Source.app> [Dest.app]}"
src="${src%/}"
dst="${2:-$HOME/taa-apps/$(basename "$src")}"

[[ -d "$src" && "$src" == *.app ]] || { echo "not an .app bundle: $src" >&2; exit 1; }
if [[ -e "$dst" ]]; then
  echo "destination exists, refusing to overwrite: $dst" >&2
  exit 1
fi

mkdir -p "$(dirname "$dst")"
echo "[resign] copying $src -> $dst"
ditto "$src" "$dst"

ent="$(mktemp -t taa-ent).plist"
trap 'rm -f "$ent"' EXIT
# Keep the app's existing entitlements, then add the two we need.
if ! codesign -d --entitlements - --xml "$dst" >"$ent" 2>/dev/null || [[ ! -s "$ent" ]]; then
  plutil -create xml1 "$ent"
fi
for key in com.apple.security.cs.allow-dyld-environment-variables com.apple.security.cs.disable-library-validation; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$ent" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$key bool true" "$ent"
done

echo "[resign] ad-hoc signing with:"
plutil -p "$ent"
codesign --force --sign - --options runtime --entitlements "$ent" "$dst"
xattr -dr com.apple.quarantine "$dst" 2>/dev/null || true

echo "[resign] done. launch with: scripts/taa-launch.sh \"$dst\""
