#!/bin/bash
# Copy local AI resources only into opted-in builds; remove stale copies when flags change.
set -euo pipefail
for setting in BANANA_LOCAL_AI BANANA_LOCAL_EMAIL; do
  case "${!setting:-NO}" in
    YES|NO) ;;
    *) echo "error: $setting must be YES or NO"; exit 1 ;;
  esac
done
if [ "${ACTION:-}" = install ] && { [ "${BANANA_LOCAL_AI:-NO}" = YES ] || [ "${BANANA_LOCAL_EMAIL:-NO}" = YES ]; }; then
  echo "error: Archives must exclude local AI and email. Set BANANA_LOCAL_AI=NO and BANANA_LOCAL_EMAIL=NO."
  exit 1
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
