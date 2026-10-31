#!/bin/sh
# Archive the Mac app for TestFlight and upload it to App Store Connect.
# Sandboxed App Store entitlements (BananaMacAppStore.entitlements) replace the local
# non-sandboxed set at archive time; cloud signing + upload use the Banana TestFlight
# API key (~/.config/banana/release.env). Bump CURRENT_PROJECT_VERSION in project.yml first.
set -e
cd "$(dirname "$0")/.."

. tools/config.sh require
: "${ASC_KEY_ID:?set ASC_KEY_ID and ASC_ISSUER_ID (see tools/config.sh)}" "${ASC_ISSUER_ID:?}"
KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
AUTH="-authenticationKeyPath $KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
# The export options name the team that signs: yours, from the config.
options=$(mktemp -t banana-export).plist
sed "s/BANANA_TEAM/$(banana_setting DEVELOPMENT_TEAM)/" TestFlightExportOptions.plist > "$options"

xcodegen generate
build=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/[^0-9]//g')
archive=".build/mac-testflight/BananaMac-$build.xcarchive"

# shellcheck disable=SC2086
xcodebuild -project Banana.xcodeproj -scheme BananaMac -configuration Release \
  BANANA_UNRELEASED=NO ARCHS=arm64 -destination 'generic/platform=macOS' -archivePath "$archive" \
  CODE_SIGN_ENTITLEMENTS=BananaMac/BananaMacAppStore.entitlements \
  -allowProvisioningUpdates $AUTH -quiet archive

# Nothing unreleased goes to Apple (Config/Base.xcconfig): stop here if any of it got in.
tools/check-release.sh "$archive"

# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$archive" \
  -exportPath ".build/mac-testflight/export-$build" \
  -exportOptionsPlist "$options" \
  -allowProvisioningUpdates $AUTH
