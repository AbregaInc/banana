#!/bin/sh
# Build and install an iOS variant to a connected iPhone or iPad.
#
#   tools/ios-install.sh beta [device-id]   # test build  -> "Banana Beta", separate everything
#   tools/ios-install.sh prod [device-id]   # the app you actually use
#
# Default is BETA on purpose. `prod` touches the app holding real podcast progress, routines
# and voice notes, and its permission grants; it should be a decision, not a default.
#
# Always an install-OVER. Never `devicectl device uninstall`: that deletes the data container
# AND revokes every TCC grant AND removes the paired Watch app, and reinstalling restores none
# of it. If a clean slate is genuinely needed, use beta and reset its data from Settings.
# AUTH_ARGS: optional App Store Connect API key arguments, as in mac-install.sh — lets a new
# capability be added to the App ID and the profile regenerated when Xcode has no signed-in account.
#
# CONFIG: Release by default — optimized, as the Mac already is. The phone ran Debug builds for
# months, which is unoptimized Swift: every SwiftUI body (the Day grid above all) and every
# recompute several times slower than shipping code, on the app used all day. Release is signed
# with the same development profile and the same production iCloud container, so nothing about
# data or sync changes. `CONFIG=Debug tools/ios-install.sh …` when a debug build is wanted.
# (A Release build has no Banana.debug.dylib: symbolicate crash stacks against the dSYM.)
set -e
config="${CONFIG:-Release}"

variant="${1:-beta}"
case "$variant" in
  prod) unreleased=NO; scheme=Banana;     app="Banana.app";      suffix="";;
  beta) unreleased=YES; scheme=BananaBeta; app="Banana Beta.app"; suffix=".beta";;
  *) echo "usage: $0 [beta|prod] [device-id]"; exit 1;;
esac

cd "$(dirname "$0")/.."
# Your own team and bundle id, or stop: never the stand-in app over one you use.
. tools/config.sh require
bundle="$(banana_setting BANANA_BUNDLE_ID)$suffix"
# Device selection is EXPLICIT-first and refuses to guess between several.
#
# The old auto-detect matched /connected/ && /iPhone/ and took the first hit. The author's phone
# reports "available (paired)" while a second, borrowed phone reported "connected" — so the
# guess would have installed onto someone else's device. Names contain spaces too, so the old
# positional $(NF-2) was not the identifier either. Match the UUID by shape, and when more than
# one iPhone is present, stop and make the caller name it.
device="${2:-}"
if [ -z "$device" ]; then
  uuid='[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}'
  phones=$(xcrun devicectl list devices 2>/dev/null \
    | grep -E "iPhone|iPad" | grep -Ev "unavailable" | grep -o "$uuid")
  count=$(printf '%s\n' "$phones" | grep -c . || true)
  if [ "$count" -gt 1 ]; then
    echo "More than one iPhone or iPad is present. Name the one you mean:"
    echo "  $0 $variant <device-id>"
    echo
    xcrun devicectl list devices | grep -E "Identifier|iPhone|iPad"
    exit 1
  fi
  device=$(printf '%s\n' "$phones" | head -1)
fi
if [ -z "$device" ]; then
  echo "No iPhone or iPad found. Pass a device id: $0 $variant <device-id>"
  xcrun devicectl list devices
  exit 1
fi

if [ "$variant" = "prod" ]; then
  target_name=$(xcrun devicectl list devices 2>/dev/null | grep "$device" | sed 's/  */ /g' | cut -d' ' -f1-3)
  printf 'This installs over the PRODUCTION app (%s) on:\n  %s  [%s]\nType yes to continue: ' "$bundle" "$target_name" "$device"
  read -r reply
  [ "$reply" = "yes" ] || { echo "Aborted."; exit 1; }
fi

xcodegen generate
# Email is built only into the separate Beta app, including local installs.
xcodebuild -jobs "${BUILD_JOBS:-2}" -project Banana.xcodeproj -scheme "$scheme" -configuration "$config" BANANA_UNRELEASED="$unreleased" \
  -destination "id=$device" -derivedDataPath ".build/ios-$variant" \
  -allowProvisioningUpdates ${AUTH_ARGS:-} -quiet build

built=".build/ios-$variant/Build/Products/$config-iphoneos/$app"
# What was built is what was meant: the id inside the app, not the one this script expects.
made=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$built/Info.plist")
[ "$made" = "$bundle" ] || { echo "Built $made, expected $bundle. Not installing."; exit 1; }
xcrun devicectl device install app --device "$device" "$built"
echo "Installed $app ($bundle) to $device"

# The Watch is a SEPARATE install for a development build.
#
# The Watch app is embedded at $app/Watch/BananaWatch.app, but that copy exists for App Store
# distribution: the TestFlight/App Store pipeline is what hands it to the Watch. A dev build
# never enters that pipeline, and the Watch app on iPhone refuses to install an unsigned one.
# So `devicectl install` to the phone leaves the Watch on whatever it had, silently — which is
# how the two ended up running unrelated code more than once.
#
# Beta embeds no Watch app by design (see project.yml), so this only applies to prod.
if [ "$variant" = "prod" ]; then
  uuid='[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}'
  # Match EITHER identifier shape. devicectl used to list a CoreDevice UUID (8-4-4-4-12) and
  # now prints the hardware UDID (8 hex, a dash, 16 hex) for a Watch — which the UUID pattern
  # silently fails to match, so a perfectly reachable Watch reported as "not found".
  hwudid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}'
  uuidE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
  watch=$(xcrun devicectl list devices 2>/dev/null \
    | grep -E "Watch" | grep -Ev "unavailable|simulated" \
    | grep -oE "$hwudid|$uuidE" | head -1)

  # A failed Watch install must NOT abort before the warning prints — the whole point is to say
  # out loud that only half the pair moved. `set -e` would otherwise kill the script on
  # xcodebuild's exit code and leave the phone silently ahead.
  set +e
  watch_ok=0
  if [ -z "$watch" ]; then
    echo "No paired Watch found."
  else
    # xcodebuild addresses a Watch by its HARDWARE UDID (00008310-…), not the CoreDevice
    # identifier devicectl lists (D0F09E1A-…). Passing the latter matches no destination and
    # xcodebuild waits until it times out.
    # Already a hardware UDID? Then the list gave us what xcodebuild wants and there is nothing
    # to look up. Otherwise resolve it — case-insensitively, because devicectl prints "UDID:"
    # and the old lowercase pattern matched nothing, which read as "the Watch isn't ready".
    case "$watch" in
      0000*) watchUDID="$watch" ;;
      *) watchUDID=$(xcrun devicectl device info details --device "$watch" 2>/dev/null \
           | awk -F': ' 'tolower($0) ~ /udid:/ {gsub(/ /,"",$2); print $2; exit}') ;;
    esac
    # Validate the SHAPE, not just non-emptiness. A Watch that is listed but not actually ready
    # can return a blank or partial line here, and a whitespace-y value passes an -z test happily.
    # xcodebuild then matches no destination and sits there until it times out — ten minutes to
    # be told nothing. Fail in a second instead, with the reason.
    case "$watchUDID" in
      000*-*) : ;;
      *)
        echo "Could not read the Watch's hardware UDID (got: '$watchUDID')."
        echo "The Watch is usually listed but not yet ready. Unlock it, keep it on your wrist"
        echo "near this Mac, and run this again."
        watchUDID=""
        ;;
    esac
    [ -n "$watchUDID" ] && echo "Building the Watch app for $watchUDID…"
    [ -n "$watchUDID" ] \
      && xcodebuild -jobs "${BUILD_JOBS:-2}" -project Banana.xcodeproj -scheme BananaWatch -configuration "$config" \
      -destination "id=$watchUDID" -derivedDataPath ".build/ios-$variant-watch" \
      -allowProvisioningUpdates ${AUTH_ARGS:-} -quiet build \
      && xcrun devicectl device install app --device "$watch" \
           ".build/ios-$variant-watch/Build/Products/$config-watchos/BananaWatch.app" \
      && watch_ok=1
  fi
  set -e

  if [ "$watch_ok" = "1" ]; then
    echo "Installed BananaWatch. Both sides now match."
  else
    echo
    echo "============================================================"
    echo " WARNING: the phone was updated and the WATCH WAS NOT."
    echo " The two are now running different builds."
    echo
    echo " Watch installs need it UNLOCKED, on-wrist, and near this Mac."
    echo " Retry this script, or run the BananaWatch scheme from Xcode."
    echo " Settings > Versions in the app shows which build each side is on."
    echo "============================================================"
  fi
fi
