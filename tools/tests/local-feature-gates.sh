#!/bin/bash
# Exercise resource gating, stale-file cleanup and release rejection without starting the app.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Public.app/Contents/MacOS"
export SCRATCH="$scratch"
python3 - <<'PYTEST'
import os,pathlib,plistlib
app=pathlib.Path(os.environ['SCRATCH'])/'Public.app'
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='probe',CFBundleIdentifier='org.example.banana',BananaModules='')))
PYTEST
export SRCROOT="$root" TARGET_BUILD_DIR="$scratch/Public.app" UNLOCALIZED_RESOURCES_FOLDER_PATH=Contents/Resources
export BANANA_LOCAL_AI=invalid BANANA_LOCAL_EMAIL=NO ACTION=build
if tools/local-feature-resources.sh > "$scratch/invalid.log" 2>&1; then echo 'Invalid flag accepted'; exit 1; fi
export BANANA_LOCAL_AI=YES
tools/local-feature-resources.sh
[ -f "$scratch/Public.app/Contents/Resources/pi-agent.js" ]
grep -qx AI "$scratch/Public.app/Contents/Resources/banana-local-features.txt"
if tools/check-release.sh "$scratch" > "$scratch/check.log" 2>&1; then echo 'AI resource accepted'; exit 1; fi
mkdir -p "$scratch/Public.app/Contents/Resources/PiRuntime"
echo stale > "$scratch/Public.app/Contents/Resources/PiRuntime/stale"
export BANANA_LOCAL_AI=NO BANANA_LOCAL_EMAIL=YES
tools/local-feature-resources.sh
[ ! -e "$scratch/Public.app/Contents/Resources/pi-agent.js" ]
[ ! -e "$scratch/Public.app/Contents/Resources/PiRuntime" ]
grep -qx EMAIL "$scratch/Public.app/Contents/Resources/banana-local-features.txt"
if tools/check-release.sh "$scratch" > "$scratch/check.log" 2>&1; then echo 'Email marker accepted'; exit 1; fi
export ACTION=install
if tools/local-feature-resources.sh > "$scratch/archive.log" 2>&1; then echo 'Local feature archive accepted'; exit 1; fi
# TestFlight is Stable: the primary identity may not archive Email. Only the direct Beta target may.
export BANANA_BUNDLE_ID=org.example.banana
if BANANA_RELEASE_CHANNEL=testflight PRODUCT_BUNDLE_IDENTIFIER=org.example.banana TARGET_NAME=Banana \
  tools/local-feature-resources.sh > "$scratch/testflight.log" 2>&1; then echo 'TestFlight Email archive accepted'; exit 1; fi
BANANA_RELEASE_CHANNEL=beta PRODUCT_BUNDLE_IDENTIFIER=org.example.banana.beta TARGET_NAME=BananaMacBetaDirect \
  tools/local-feature-resources.sh
# Both features may archive only in the direct Beta target.
export BANANA_LOCAL_AI=YES
BANANA_RELEASE_CHANNEL=beta PRODUCT_BUNDLE_IDENTIFIER=org.example.banana.beta TARGET_NAME=BananaMacBetaDirect \
  tools/local-feature-resources.sh
if BANANA_RELEASE_CHANNEL=beta PRODUCT_BUNDLE_IDENTIFIER=org.example.banana TARGET_NAME=BananaMacBetaDirect \
  tools/local-feature-resources.sh > "$scratch/wrong-identity.log" 2>&1; then echo 'AI archive accepted for primary identity'; exit 1; fi
export BANANA_LOCAL_AI=NO
unset BANANA_BUNDLE_ID
export BANANA_LOCAL_EMAIL=NO
tools/local-feature-resources.sh
[ ! -e "$scratch/Public.app/Contents/Resources/banana-local-features.txt" ]
# A clean Mach-O passes. Either embedded feature marker must fail, even without resources.
printf 'int main(void) { return 0; }\n' > "$scratch/probe.c"
xcrun clang "$scratch/probe.c" -o "$scratch/Public.app/Contents/MacOS/probe"
tools/check-release.sh "$scratch" > "$scratch/check.log"
# A compiled Core ML model with more than one user-defined metadata entry builds differently
# every time (coremlc writes that map in random order); one entry is fine.
mkdir -p "$scratch/Model.mlmodelc"
echo '[{"userDefinedMetadata": {"source": "torch"}}]' > "$scratch/Model.mlmodelc/metadata.json"
tools/check-release.sh "$scratch" > "$scratch/check.log"
echo '[{"userDefinedMetadata": {"source": "torch", "date": "2026-09-11"}}]' > "$scratch/Model.mlmodelc/metadata.json"
if tools/check-release.sh "$scratch" > "$scratch/check.log" 2>&1; then echo 'Unordered model metadata accepted'; exit 1; fi
grep -q 'Not reproducible' "$scratch/check.log"
rm -rf "$scratch/Model.mlmodelc"
for marker in banana-local-ai-built-in banana-unreleased-modules-built-in; do
  printf '#include <stdio.h>\nint main(void) { puts("%s"); return 0; }\n' "$marker" > "$scratch/probe.c"
  xcrun clang "$scratch/probe.c" -o "$scratch/Public.app/Contents/MacOS/probe"
  if tools/check-release.sh "$scratch" > "$scratch/check.log" 2>&1; then echo "Binary marker accepted: $marker"; exit 1; fi
done
# Even with both flags off, Archive must inspect the actual binary for a mismatch.
export TARGET_BUILD_DIR="$scratch" WRAPPER_NAME=Public.app
if tools/local-feature-resources.sh > "$scratch/archive-scan.log" 2>&1; then echo 'Archive binary scan bypassed'; exit 1; fi
# The actual bundle, identity, channel and feed authorize AI; caller flags cannot.
printf '#include <stdio.h>\nint main(void) { puts("banana-local-ai-built-in banana-unreleased-modules-built-in"); return 0; }\n' > "$scratch/probe.c"
xcrun clang "$scratch/probe.c" -o "$scratch/Public.app/Contents/MacOS/probe"
export SCRATCH="$scratch"
python3 - <<'PYTEST'
import os, pathlib, plistlib, shutil
app=pathlib.Path(os.environ['SCRATCH'])/'Integrated.app'
(app/'Contents/MacOS').mkdir(parents=True)
(app/'Contents/Resources/PiRuntime').mkdir(parents=True)
shutil.copy(pathlib.Path(os.environ['SCRATCH'])/'Public.app/Contents/MacOS/probe',app/'Contents/MacOS/probe')
(app/'Contents/Resources/banana-local-features.txt').write_text('AI\nEMAIL\n')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='probe',CFBundleIdentifier='org.example.banana.beta',BananaPrimaryBundleIdentifier='org.example.banana',BananaReleaseChannel='beta',BananaModules='BANANA_MODULE_EMAIL',SUFeedURL='https://bananatheapp.com/updates/mac-beta/appcast.xml')))
PYTEST
tools/check-release.sh "$scratch/Integrated.app" > "$scratch/beta.log" 2>&1 || { cat "$scratch/beta.log"; exit 1; }
for pair in 'BananaReleaseChannel testflight' 'CFBundleIdentifier org.example.banana' 'SUFeedURL https://bananatheapp.com/updates/mac/appcast.xml'; do
  read -r key value <<< "$pair"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$scratch/Integrated.app/Contents/Info.plist"
  if tools/check-release.sh "$scratch/Integrated.app" > "$scratch/not-beta.log" 2>&1; then echo "AI bundle accepted with invalid $key"; exit 1; fi
  # Restore the canonical Beta value before the next independent mutation.
  case "$key" in
    BananaReleaseChannel) original=beta;;
    CFBundleIdentifier) original=org.example.banana.beta;;
    SUFeedURL) original=https://bananatheapp.com/updates/mac-beta/appcast.xml;;
  esac
  /usr/libexec/PlistBuddy -c "Set :$key $original" "$scratch/Integrated.app/Contents/Info.plist"
done
echo 'Local feature resource and release guard checks passed.'
