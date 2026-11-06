#!/bin/bash
# Copy local AI resources only into opted-in builds; remove stale copies when flags change.
set -euo pipefail
for setting in BANANA_LOCAL_AI BANANA_LOCAL_EMAIL; do
  case "${!setting:-NO}" in
    YES|NO) ;;
    *) echo "error: $setting must be YES or NO"; exit 1 ;;
  esac
done
if [ "${ACTION:-}" = install ]; then
  if [ "${BANANA_LOCAL_AI:-NO}" = YES ]; then
    echo "error: Distributed archives must exclude local AI."; exit 1
  fi
  if [ "${BANANA_LOCAL_EMAIL:-NO}" = YES ]; then
    email_distribution=NO
    if [ -n "${BANANA_BUNDLE_ID:-}" ]; then
      if [ "${BANANA_RELEASE_CHANNEL:-}" = testflight ] && [ "${PRODUCT_BUNDLE_IDENTIFIER:-}" = "$BANANA_BUNDLE_ID" ]; then email_distribution=YES; fi
      if [ "${BANANA_RELEASE_CHANNEL:-}" = beta ] && [ "${PRODUCT_BUNDLE_IDENTIFIER:-}" = "$BANANA_BUNDLE_ID.beta" ] && [ "${TARGET_NAME:-}" = BananaMacBetaDirect ]; then email_distribution=YES; fi
    fi
    if [ "$email_distribution" != YES ]; then
      echo "error: Email distribution requires primary TestFlight or the dedicated direct Beta target."; exit 1
    fi
  fi
fi
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources"
for source in "$SRCROOT"/Banana/Pi/Resources/*; do
  destination="$resources/$(basename "$source")"
  if [ "${BANANA_LOCAL_AI:-NO}" = YES ]; then
    cp "$source" "$destination"
  else
    rm -f "$destination"
  fi
done
if [ "${BANANA_LOCAL_AI:-NO}" != YES ]; then
  rm -rf "$resources/PiRuntime"
fi
# An inspectable marker survives optimizer stripping and catches incorrectly configured archives.
marker="$resources/banana-local-features.txt"
rm -f "$marker"
if [ "${BANANA_LOCAL_AI:-NO}" = YES ]; then echo AI >> "$marker"; fi
if [ "${BANANA_LOCAL_EMAIL:-NO}" = YES ]; then echo EMAIL >> "$marker"; fi

# Also covers Archive from Xcode, not only the command-line upload script.
if [ "${ACTION:-}" = install ] && [ -n "${WRAPPER_NAME:-}" ]; then
  "$SRCROOT/tools/check-release.sh" "$TARGET_BUILD_DIR/$WRAPPER_NAME"
fi
