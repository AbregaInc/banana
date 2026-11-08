#!/bin/bash
# Prepare a signed archive/export; upload only when explicitly requested.
# Both platforms use the existing primary app identity and production service.
# TestFlight is the Stable channel: Email and local AI are compiled out.
#
#   tools/testflight.sh ios|mac BUILD [prepare]   archive, check, export (no upload)
#   tools/testflight.sh ios|mac BUILD upload      export with destination upload
#   tools/testflight.sh ios|mac BUILD check       archive and check only (tools/preflight.sh). The
#                                                 archive stays in the derived data, and prepare
#                                                 adopts it when it is the same commit and build:
#                                                 xcodebuild archive starts from empty
#                                                 intermediates every time, so a second archive of
#                                                 the same source is never incremental
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { echo 'Usage: tools/testflight.sh ios|mac BUILD_NUMBER [prepare|upload|check]'; }
if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
platform=${1:-}
build=${2:-}
mode=${3:-prepare}
[[ "$platform" == ios || "$platform" == mac ]] || { usage >&2; exit 2; }
[[ "$build" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
[[ "$mode" == prepare || "$mode" == upload || "$mode" == check ]] || { usage >&2; exit 2; }
[[ $# -le 3 ]] || { usage >&2; exit 2; }
[[ "$mode" == check || -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo 'Commit the reviewed source before preparing a traceable build.' >&2; exit 1;
}
. tools/config.sh require
: "${ASC_KEY_ID:?Set ASC_KEY_ID}" "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[[ -f "$key_path" ]] || { echo 'App Store Connect signing key is missing.' >&2; exit 1; }
revision=$(git rev-parse HEAD)
[[ "$mode" != check ]] || revision=$(banana_source_revision)
team=$(banana_setting DEVELOPMENT_TEAM)
[[ -n "$team" ]] || { echo 'DEVELOPMENT_TEAM is missing.' >&2; exit 1; }
root=".build/$platform-testflight"
archive="$root/Banana-$build.xcarchive"
export_path="$root/$mode-$build"
checked=".build/$platform-testflight-check/Banana-$build.xcarchive"
if [[ "$mode" == check ]]; then
  rm -rf ".build/$platform-testflight-check"
  archive=$checked
fi
[[ "$mode" == upload || "$mode" == check || ( ! -e "$archive" && ! -e "$export_path" ) ]] || {
  echo 'That build already has retained artifacts. Use a new build number.' >&2; exit 1;
}
scheme=Banana
platform_args=(-destination 'generic/platform=iOS')
derived=.build/ios-prod
if [[ "$platform" == mac ]]; then
  scheme=BananaMac
  platform_args=(-destination 'generic/platform=macOS' ARCHS=arm64)
  derived=.build/mac-check
fi
mkdir -p "$root"
options=$(mktemp -t banana-testflight)
trap 'result=$?; rm -f "$options"; exit "$result"' EXIT
python3 - "$options" "$team" "$mode" <<'PY'
import plistlib, sys
options = plistlib.load(open('TestFlightExportOptions.plist', 'rb'))
options['teamID'] = sys.argv[2]
options['destination'] = 'upload' if sys.argv[3] == 'upload' else 'export'
with open(sys.argv[1], 'wb') as output: plistlib.dump(options, output)
PY
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
identity_ok() {  # identity_ok ARCHIVE: one primary app with this commit, build, bundle id and channel
  python3 - "$1" "$revision" "$build" "$(banana_setting BANANA_BUNDLE_ID)" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1]) / "Products/Applications"
apps = list(root.glob("*.app"))
if len(apps) != 1: sys.exit("Archive must contain one primary app")
p = apps[0] / "Info.plist"
if not p.exists(): p = apps[0] / "Contents/Info.plist"
info = plistlib.load(p.open("rb"))
expected = {"BananaSourceCommit": sys.argv[2], "CFBundleVersion": sys.argv[3],
            "CFBundleIdentifier": sys.argv[4], "BananaReleaseChannel": "testflight"}
sys.exit(0 if all(info.get(k) == v for k, v in expected.items()) else "Archive identity, channel or source does not match")
PY
}
if [[ "$mode" == prepare && ! -d "$archive" && -d "$checked" ]]; then
  if identity_ok "$checked" 2>/dev/null; then
    mv "$checked" "$archive"
    echo "Adopted the preflight archive of $revision, build $build"
  fi
  rm -rf ".build/$platform-testflight-check"
fi
if [[ ! -d "$archive" ]]; then
xcodegen generate
banana_xcode -project Banana.xcodeproj -scheme "$scheme" -configuration TestFlight \
  "${platform_args[@]}" -derivedDataPath "$derived" -archivePath "$archive" \
  BANANA_UNRELEASED=NO BANANA_LOCAL_AI=NO BANANA_LOCAL_EMAIL=NO \
  "CURRENT_PROJECT_VERSION=$build" "BANANA_SOURCE_COMMIT=$revision" \
  "${auth[@]}" archive
fi
identity_ok "$archive"
tools/check-release.sh "$archive"
if [[ "$mode" == check ]]; then printf 'TestFlight check passed: %s %s\n' "$platform" "$build"; exit 0; fi
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_path" \
  -exportOptionsPlist "$options" "${auth[@]}"
python3 - "$root/build-$build.json" "$platform" "$build" "$revision" "$mode" <<'PY'
import json, sys
with open(sys.argv[1], 'w') as output:
    json.dump(dict(platform=sys.argv[2], build=sys.argv[3], revision=sys.argv[4],
                   channel='testflight', environment='production', action=sys.argv[5]), output, indent=2)
PY
printf 'TestFlight %s complete: %s\n' "$mode" "$archive"
