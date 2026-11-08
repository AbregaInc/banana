#!/bin/bash
# Build a sandboxed direct-download app. Never installs or publishes it.
#
#   build.sh test      the isolated installer-test app
#   build.sh release   archive and export the planned release (BANANA_RELEASE_PLAN)
#   build.sh check     the release archive without a plan, checked and exported to a scratch
#                      folder (tools/preflight.sh). BANANA_CHECK_VERSION / BANANA_CHECK_BUILD
#                      name the version it stamps. The archive is kept in
#                      .build/mac-distribution/check-CHANNEL/: `release` adopts it instead of
#                      archiving again when it is the planned commit, version, build and feed
#                      (xcodebuild archive starts from empty intermediates every time, so a
#                      second archive is never incremental).
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/config.sh require
mode=${1:-test}
channel=${BANANA_DISTRIBUTION_CHANNEL:-stable}
[[ "$channel" == stable || "$channel" == beta ]] || exit 2
[[ "$mode" == test || "$mode" == release || "$mode" == check ]] || { echo 'Usage: build.sh test|release|check'; exit 2; }
: "${BANANA_UPDATE_FEED_URL:?Set the HTTPS feed URL (Tailscale HTTP permitted for test only)}"
: "${BANANA_UPDATE_PUBLIC_KEY:?Set the Sparkle public Ed25519 key}"
mkdir -p private/mac-distribution .build/mac-distribution
if [[ "$mode" == release ]]; then
  : "${BANANA_RELEASE_PLAN:?Prepare a release-plan.py JSON file from a clean commit}"
  release_identity=$(python3 tools/mac-distribution/release-plan.py --check "$BANANA_RELEASE_PLAN")
  read -r source_commit release_version release_build <<< "$release_identity"
fi
archive=.build/mac-distribution/Banana.xcarchive
export_dir=private/mac-distribution/export
log_dir=private/mac-distribution
if [[ "$mode" == check ]]; then
  source_commit=$(banana_source_revision)
  release_version=${BANANA_CHECK_VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)}
  release_build=${BANANA_CHECK_BUILD:-$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)}
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/banana-mac-$channel-check.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  # The export is thrown away; the archive and logs stay beside the derived data.
  log_dir=.build/mac-distribution/check-$channel archive=.build/mac-distribution/check-$channel/Banana.xcarchive
  export_dir=$scratch/export
  mkdir -p "$log_dir"; rm -rf "$archive"
fi
xcodegen generate
scheme=BananaMacDirect
[[ "$channel" != beta ]] || scheme=BananaMacBetaDirect
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
  banana_xcode "${args[@]}" build > private/mac-distribution/build-test.log 2>&1
  echo '.build/mac-distribution/Build/Products/Release/Banana Installer Test.app'
else
  [[ "$BANANA_UPDATE_FEED_URL" == https://* ]] || { echo 'Release feed requires HTTPS'; exit 1; }
  : "${BANANA_DEVELOPER_ID_PROFILE:?Set Developer ID provisioning profile name}"
  : "${BANANA_DEVELOPER_ID_IDENTITY:?Set Developer ID Application signing identity}"
  if [[ "$mode" == release ]]; then
    planned_channel=$(python3 -c 'import json,os; print(json.load(open(os.environ["BANANA_RELEASE_PLAN"])).get("channel","stable"))')
    [[ "$channel" == "$planned_channel" ]] || { echo 'Plan channel mismatch'; exit 1; }
  fi
  args+=("BANANA_DEVELOPER_ID_IDENTITY=$BANANA_DEVELOPER_ID_IDENTITY"
    "BANANA_DEVELOPER_ID_PROFILE=$BANANA_DEVELOPER_ID_PROFILE"
    "BANANA_SOURCE_COMMIT=$source_commit"
    "MARKETING_VERSION=$release_version" "CURRENT_PROJECT_VERSION=$release_build")
  [[ "$mode" != release ]] || python3 tools/mac-distribution/release-plan.py --check "$BANANA_RELEASE_PLAN" >/dev/null
  checked=.build/mac-distribution/check-$channel/Banana.xcarchive
  if [[ "$mode" == release && -d "$checked" ]] && python3 - "$checked" "$source_commit" "$release_version" "$release_build" <<'PY'
import os, plistlib, sys
from pathlib import Path
apps = list((Path(sys.argv[1]) / 'Products/Applications').glob('*.app'))
info = plistlib.loads((apps[0] / 'Contents/Info.plist').read_bytes()) if len(apps) == 1 else {}
want = {'BananaSourceCommit': sys.argv[2], 'CFBundleShortVersionString': sys.argv[3], 'CFBundleVersion': sys.argv[4],
        'SUFeedURL': os.environ['BANANA_UPDATE_FEED_URL'], 'SUPublicEDKey': os.environ['BANANA_UPDATE_PUBLIC_KEY']}
sys.exit(0 if info and all(info.get(k) == v for k, v in want.items()) else 1)
PY
  then
    # The preflight's archive of this exact commit, version, build and feed: the same build.
    rm -rf "$archive"; mv "$checked" "$archive"
    echo "Adopted the preflight archive of $source_commit ($release_version, $release_build)" > "$log_dir/build-release.log"
  else
    rm -rf "$checked"
    banana_xcode "${args[@]}" -archivePath "$archive" archive \
      > "$log_dir/build-release.log" 2>&1 || { [[ "$mode" != check ]] || grep -E ' error: ' "$log_dir/build-release.log" | sort -u | head -20; exit 1; }
  fi
  tools/check-release.sh "$archive"
  BANANA_ARCHIVE="$archive" BANANA_EXPORT_OPTIONS="$log_dir/ExportOptions.plist" python3 - <<'PY'
import os, plistlib
from pathlib import Path
info=plistlib.loads((Path(os.environ['BANANA_ARCHIVE'])/'Info.plist').read_bytes())['ApplicationProperties']
options={'method':'developer-id','signingStyle':'manual','teamID':info['Team'],
 'signingCertificate':os.environ['BANANA_DEVELOPER_ID_IDENTITY'],
 'provisioningProfiles':{info['CFBundleIdentifier']:os.environ['BANANA_DEVELOPER_ID_PROFILE']}}
Path(os.environ['BANANA_EXPORT_OPTIONS']).write_bytes(plistlib.dumps(options))
PY
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$log_dir/ExportOptions.plist" \
    > "$log_dir/export.log" 2>&1 || { tail -20 "$log_dir/export.log"; exit 1; }
  if [[ "$mode" == check ]]; then echo "Mac $channel check passed: $release_version ($release_build)"; exit 0; fi
  python3 tools/mac-distribution/release-plan.py --check "$BANANA_RELEASE_PLAN" >/dev/null
  if [[ "$channel" == beta ]]; then echo 'private/mac-distribution/export/Banana Beta.app'; else echo 'private/mac-distribution/export/Banana.app'; fi
fi
