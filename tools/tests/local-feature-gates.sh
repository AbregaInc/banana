#!/bin/bash
# Exercise resource gating, stale-file cleanup and release rejection without starting the app.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export SRCROOT="$root" TARGET_BUILD_DIR="$scratch" UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources
export BANANA_LOCAL_AI=invalid BANANA_LOCAL_EMAIL=NO ACTION=build
if tools/local-feature-resources.sh > "$scratch/invalid.log" 2>&1; then echo 'Invalid flag accepted'; exit 1; fi
export BANANA_LOCAL_AI=YES
tools/local-feature-resources.sh
[ -f "$scratch/Resources/pi-agent.js" ]
grep -qx AI "$scratch/Resources/banana-local-features.txt"
if tools/check-release.sh "$scratch" > "$scratch/check.log" 2>&1; then echo 'AI resource accepted'; exit 1; fi
mkdir -p "$scratch/Resources/PiRuntime"
echo stale > "$scratch/Resources/PiRuntime/stale"
export BANANA_LOCAL_AI=NO BANANA_LOCAL_EMAIL=YES
tools/local-feature-resources.sh
[ ! -e "$scratch/Resources/pi-agent.js" ]
[ ! -e "$scratch/Resources/PiRuntime" ]
grep -qx EMAIL "$scratch/Resources/banana-local-features.txt"
if tools/check-release.sh "$scratch" > "$scratch/check.log" 2>&1; then echo 'Email marker accepted'; exit 1; fi
export ACTION=install
if tools/local-feature-resources.sh > "$scratch/archive.log" 2>&1; then echo 'Local feature archive accepted'; exit 1; fi
# TestFlight is Stable: the primary identity may not archive Email. Only the direct Beta target may.
export BANANA_BUNDLE_ID=org.example.banana
if BANANA_RELEASE_CHANNEL=testflight PRODUCT_BUNDLE_IDENTIFIER=org.example.banana TARGET_NAME=Banana \
  tools/local-feature-resources.sh > "$scratch/testflight.log" 2>&1; then echo 'TestFlight Email archive accepted'; exit 1; fi
BANANA_RELEASE_CHANNEL=beta PRODUCT_BUNDLE_IDENTIFIER=org.example.banana.beta TARGET_NAME=BananaMacBetaDirect \
  tools/local-feature-resources.sh
unset BANANA_BUNDLE_ID
export BANANA_LOCAL_EMAIL=NO
tools/local-feature-resources.sh
[ ! -e "$scratch/Resources/banana-local-features.txt" ]
# A clean Mach-O passes. Either embedded feature marker must fail, even without resources.
printf 'int main(void) { return 0; }\n' > "$scratch/probe.c"
xcrun clang "$scratch/probe.c" -o "$scratch/probe"
tools/check-release.sh "$scratch" > "$scratch/check.log"
for marker in banana-local-ai-built-in banana-unreleased-modules-built-in; do
  printf '#include <stdio.h>\nint main(void) { puts("%s"); return 0; }\n' "$marker" > "$scratch/probe.c"
  xcrun clang "$scratch/probe.c" -o "$scratch/probe"
  if tools/check-release.sh "$scratch" > "$scratch/check.log" 2>&1; then echo "Binary marker accepted: $marker"; exit 1; fi
done
# Even with both flags off, Archive must inspect the actual binary for a mismatch.
mkdir -p "$scratch/Public.app"
cp "$scratch/probe" "$scratch/Public.app/probe"
export WRAPPER_NAME=Public.app
if tools/local-feature-resources.sh > "$scratch/archive-scan.log" 2>&1; then echo 'Archive binary scan bypassed'; exit 1; fi
echo 'Local feature resource and release guard checks passed.'
