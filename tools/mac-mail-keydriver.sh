#!/bin/bash
# Plays a key script against the Mac's real Mail, offscreen: no window on the screen, no activation,
# no sound, nothing sent anywhere (docs: Banana/Views/MailKeyDriver.swift).
#
#   tools/mac-mail-keydriver.sh <script.keys> <output-dir> [--no-build]
#
# It works with the screen locked and alongside a running "Banana Beta", because the copy it runs is
# not the Beta:
#   - the app is a COPY of the Debug build, with another bundle identifier (so another
#     UserDefaults domain), no provisioning profile and no entitlements (so no iCloud, and no
#     access to the keychain group the Google accounts live in), signed ad hoc;
#   - HOME is a throwaway folder, so "Application Support/Banana Beta" is a new, empty one;
#   - sandbox-exec denies it every outbound IP connection, and every write to the real Banana Beta
#     folder, the real Banana Beta preferences and /Applications/Banana Beta.app.
# The installed Beta is never started, stopped, signalled or written to.
set -euo pipefail

script="${1:?usage: mac-mail-keydriver.sh <script.keys> <output-dir> [--no-build]}"
out="${2:?usage: mac-mail-keydriver.sh <script.keys> <output-dir> [--no-build]}"
build=1
[ "${3:-}" = "--no-build" ] && build=0

cd "$(dirname "$0")/.."
root="$(pwd)"
dd="$root/.build/macuitest-dd"
built="$dd/Build/Products/Debug/Banana Beta.app"
mkdir -p "$(dirname "$out")"

if [ "$build" = 1 ]; then
  xcodegen generate >/dev/null
  xcodebuild build -project Banana.xcodeproj -scheme BananaMacBeta -configuration Debug \
    -derivedDataPath "$dd" > "$out.build.log" 2>&1 || { echo "build failed: see $out.build.log"; exit 1; }
fi
[ -d "$built" ] || { echo "no Debug build at $built (run without --no-build)"; exit 1; }

work="$(dirname "$out")/driver-copy"
home="$(dirname "$out")/home"
rm -rf "$work" "$out"
mkdir -p "$work" "$home/Library/Preferences" "$home/Library/Application Support" "$out"
app="$work/Banana Beta.app"
cp -R "$built" "$app"
rm -f "$app/Contents/embedded.provisionprofile"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.boris.banana.mac.beta.keydriver" "$app/Contents/Info.plist"
for dylib in "$app"/Contents/MacOS/*.dylib; do codesign --force --sign - "$dylib" >/dev/null 2>&1; done
codesign --force --deep --sign - "$app" >/dev/null 2>&1

real="$HOME"
policy="(version 1)(allow default)(deny network-outbound (remote ip))\
(deny file-write* (subpath \"$real/Library/Application Support/Banana Beta\"))\
(deny file-write* (literal \"$real/Library/Preferences/com.boris.banana.mac.beta.plist\"))\
(deny file-write* (subpath \"/Applications/Banana Beta.app\"))"

echo "driver copy: $app"
echo "home:        $home"
echo "output:      $out"
set +e
env CFFIXED_USER_HOME="$home" MAIL_KEY_TIMEOUT="${MAIL_KEY_TIMEOUT:-150}" \
  sandbox-exec -p "$policy" "$app/Contents/MacOS/Banana Beta" \
  --mail-key-script "$script" --mail-key-out "$out" \
  --ui-audit --disable-icloud --mac-section mail --mail --mail-fresh -onboardingCompleted YES ${KEYDRIVER_EXTRA:-} \
  > "$out/stdout.log" 2> "$out/stderr.log"
status=$?
set -e
echo "exit status: $status"
cat "$out/SUMMARY.txt" 2>/dev/null || echo "(no SUMMARY.txt: the run did not finish; see $out/stderr.log)"
exit $status
