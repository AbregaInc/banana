#!/bin/sh
# Build and install the prod or beta Mac app into /Applications. They coexist:
# different bundle ids, display names, icons, and local data roots (see
# Banana/Model/AppSupport.swift and the BananaMacBeta target in project.yml).
#
#   tools/mac-install.sh beta   # test build  -> /Applications/Banana Beta.app
#   tools/mac-install.sh prod   # daily build -> /Applications/Banana.app
#
# Prod Release keeps the iCloud entitlements, so signing may need the developer
# portal; pass the App Store Connect API key via AUTH_ARGS if Xcode has no
# account (the key ids are in ~/.config/banana/release.env).
set -e
variant="${1:-beta}"
case "$variant" in
  prod) unreleased=NO; scheme=BananaMac;     built="Banana.app";   installed="Banana.app";;
  beta) unreleased=YES; scheme=BananaMacBeta; built="Banana Beta.app"; installed="Banana Beta.app";;
  *) echo "usage: $0 [prod|beta]"; exit 1;;
esac

cd "$(dirname "$0")/.."
# Your own team and bundle id, or stop: never the stand-in app over one you use.
. tools/config.sh require
xcodegen generate
# NO_ICLOUD=1 signs prod locally with empty entitlements (no portal round-trip; matches
# what Debug builds run with). Full-iCloud prod needs a Mac provisioning profile, which
# the current API key cannot create — sign into Xcode once, then run without NO_ICLOUD.
extra=""
if [ "${NO_ICLOUD:-}" = "1" ]; then
  extra="CODE_SIGN_ENTITLEMENTS=BananaMac/BananaMacDebug.entitlements"
fi
# Mac builds support Apple silicon only, including local installs and archives.
# shellcheck disable=SC2086
# Email is built only into the separate Beta app, including local installs.
xcodebuild -jobs "${BUILD_JOBS:-2}" -project Banana.xcodeproj -scheme "$scheme" -configuration Release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES BANANA_UNRELEASED="$unreleased" \
  -derivedDataPath .build/mac-install -allowProvisioningUpdates ${AUTH_ARGS:-} $extra -quiet build

target="/Applications/$installed"

# Quit it first. Replacing the bundle under a RUNNING app changes nothing you can see: macOS
# keeps executing the image it already loaded, so the old build carries on and every fix looks
# like it did not land. This cost an afternoon of testing a binary from before the changes.
if pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1; then
  echo "Quitting the running $installed…"
  pkill -f "$target/Contents/MacOS/" || true
  sleep 2
fi

rm -rf "$target"
cp -R ".build/mac-install/Build/Products/Release/$built" "$target"
echo "Installed $target"
echo "Relaunch it to pick this up (the old process, if any, has been quit)."
