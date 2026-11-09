#!/bin/bash
# Install a released Mac DMG on this Mac, the way a user's update lands, with a backup first.
#
#   tools/release/install-mac.sh beta   private/releases/beta-116/package/Banana.dmg
#   tools/release/install-mac.sh stable private/releases/stable-116/package/Banana.dmg
#
# 1. Verify: checksum against the package's release.json, Gatekeeper and the notarization ticket on
#    the DMG, and the app inside (signature, Gatekeeper, bundle id, build number).
# 2. Quit the running app (politely, then by force after 20 s).
# 3. Back up the installed app to ~/Library/Caches/banana-app-backups (the newest three are kept).
# 4. Copy the new app into place with ditto, swapping the whole bundle (never merging into it).
# 5. Relaunch it and check the installed build number.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/config.sh require
channel=${1:-}; dmg=${2:-}
[[ "$channel" == beta || "$channel" == stable ]] && [ -f "$dmg" ] || { sed -n '2,13p' "$0"; exit 2; }
release=$(dirname "$dmg")/release.json
[ -f "$release" ] || { echo "No release.json beside $dmg"; exit 1; }
name='Banana.app'; bundle=$(banana_setting BANANA_BUNDLE_ID)
[ "$channel" = beta ] && { name='Banana Beta.app'; bundle="$bundle.beta"; }
target="/Applications/$name"

read -r want_sha want_build < <(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["sha256"], r["version"])' "$release")
[ "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" = "$want_sha" ] || { echo "Checksum differs from release.json"; exit 1; }
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || { echo "Gatekeeper rejects the DMG"; exit 1; }
xcrun stapler validate "$dmg" >/dev/null || { echo "The DMG has no valid notarization ticket"; exit 1; }

mount=$(mktemp -d "${TMPDIR:-/tmp}/banana-dmg.XXXXXX")
trap 'hdiutil detach "$mount" -quiet 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
hdiutil attach "$dmg" -nobrowse -readonly -noverify -mountpoint "$mount" -quiet
app="$mount/$name"
[ -d "$app" ] || { echo "No $name in the DMG"; exit 1; }
# Strict verification of a copy without extended attributes: a DMG made before package.py
# dropped them carries macOS's provenance and Finder tags, which --strict refuses though they
# are not part of the signature.
check=$(mktemp -d "${TMPDIR:-/tmp}/banana-verify.XXXXXX")
ditto --norsrc --noextattr --noqtn "$app" "$check/$name"
codesign --verify --deep --strict "$check/$name" || { rm -rf "$check"; echo "$name fails strict signature verification"; exit 1; }
rm -rf "$check"
spctl -a -t exec "$app" 2>/dev/null || { echo "Gatekeeper rejects $name"; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$bundle" ] || { echo "Wrong bundle id"; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = "$want_build" ] || { echo "Wrong build number"; exit 1; }
echo "verified $name $want_build"

if pgrep -f "$target/Contents/MacOS/" >/dev/null; then
  osascript -e "tell application id \"$bundle\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 20); do pgrep -f "$target/Contents/MacOS/" >/dev/null || break; sleep 1; done
  pkill -f "$target/Contents/MacOS/" 2>/dev/null || true
  sleep 1
  echo "quit $name"
fi

backups="${BANANA_APP_BACKUPS:-$HOME/Library/Caches/banana-app-backups}"
if [ -d "$target" ]; then
  old=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist" 2>/dev/null || echo unknown)
  mkdir -p "$backups"
  ditto "$target" "$backups/${name%.app}-$old-$(date +%Y%m%d-%H%M%S).app"
  ls -dt "$backups/${name%.app}-"*.app 2>/dev/null | tail -n +4 | while read -r b; do rm -rf "$b"; done
  echo "backed up build $old to $backups"
fi

staged="/Applications/.${name%.app}-installing.app"
rm -rf "$staged"
ditto --norsrc --noextattr --noqtn "$app" "$staged"
rm -rf "$target"
mv "$staged" "$target"
open "$target"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")" = "$want_build" ]
echo "installed and relaunched $target ($want_build)"
