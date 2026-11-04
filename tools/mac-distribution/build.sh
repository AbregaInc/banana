#!/bin/bash
# Build a sandboxed direct-download app. Never installs or publishes it.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/config.sh require
mode=${1:-test}
[[ "$mode" == test || "$mode" == release ]] || { echo 'Usage: build.sh test|release'; exit 2; }
: "${BANANA_UPDATE_FEED_URL:?Set the HTTPS feed URL (Tailscale HTTP permitted for test only)}"
: "${BANANA_UPDATE_PUBLIC_KEY:?Set the Sparkle public Ed25519 key}"
mkdir -p private/mac-distribution .build/mac-distribution
if [[ "$mode" == release ]]; then
  : "${BANANA_RELEASE_PLAN:?Prepare a release-plan.py JSON file from a clean commit}"
  release_identity=$(python3 tools/mac-distribution/release-plan.py --check "$BANANA_RELEASE_PLAN")
  read -r source_commit release_version release_build <<< "$release_identity"
fi
xcodegen generate
scheme=BananaMacDirect
[[ "$mode" != test ]] || scheme=BananaMacInstallerTest
args=(-project Banana.xcodeproj -scheme "$scheme" -configuration Release
  -destination 'generic/platform=macOS' -derivedDataPath .build/mac-distribution
  -packageAuthorizationProvider netrc
  -clonedSourcePackagesDirPath .build/ios-prod/SourcePackages
  BANANA_UNRELEASED=NO ARCHS=arm64 ENABLE_HARDENED_RUNTIME=YES
  "BANANA_UPDATE_FEED_URL=$BANANA_UPDATE_FEED_URL"
  "BANANA_UPDATE_PUBLIC_KEY=$BANANA_UPDATE_PUBLIC_KEY")
if [[ "$mode" == test ]]; then
  # Separate sandbox, preferences, keychain and URL schemes. No production cloud/service.
  xcodebuild "${args[@]}" build > private/mac-distribution/build-test.log 2>&1
  echo '.build/mac-distribution/Build/Products/Release/Banana Installer Test.app'
else
  [[ "$BANANA_UPDATE_FEED_URL" == https://* ]] || { echo 'Release feed requires HTTPS'; exit 1; }
  : "${BANANA_DEVELOPER_ID_PROFILE:?Set Developer ID provisioning profile name}"
  : "${BANANA_DEVELOPER_ID_IDENTITY:?Set Developer ID Application signing identity}"
  args+=("BANANA_DEVELOPER_ID_IDENTITY=$BANANA_DEVELOPER_ID_IDENTITY"
    "BANANA_DEVELOPER_ID_PROFILE=$BANANA_DEVELOPER_ID_PROFILE"
    "BANANA_SOURCE_COMMIT=$source_commit"
    "MARKETING_VERSION=$release_version" "CURRENT_PROJECT_VERSION=$release_build")
  python3 tools/mac-distribution/release-plan.py --check "$BANANA_RELEASE_PLAN" >/dev/null
  xcodebuild "${args[@]}" -archivePath .build/mac-distribution/Banana.xcarchive archive \
    > private/mac-distribution/build-release.log 2>&1
  tools/check-release.sh .build/mac-distribution/Banana.xcarchive
  python3 - <<'PY'
import os, plistlib
from pathlib import Path
info=plistlib.loads(Path('.build/mac-distribution/Banana.xcarchive/Info.plist').read_bytes())['ApplicationProperties']
options={'method':'developer-id','signingStyle':'manual','teamID':info['Team'],
 'signingCertificate':os.environ['BANANA_DEVELOPER_ID_IDENTITY'],
 'provisioningProfiles':{info['CFBundleIdentifier']:os.environ['BANANA_DEVELOPER_ID_PROFILE']}}
Path('private/mac-distribution/ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
  xcodebuild -exportArchive -archivePath .build/mac-distribution/Banana.xcarchive \
    -exportPath private/mac-distribution/export \
    -exportOptionsPlist private/mac-distribution/ExportOptions.plist \
    > private/mac-distribution/export.log 2>&1
  python3 tools/mac-distribution/release-plan.py --check "$BANANA_RELEASE_PLAN" >/dev/null
  echo 'private/mac-distribution/export/Banana.app'
fi
