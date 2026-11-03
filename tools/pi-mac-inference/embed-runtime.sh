#!/bin/bash
# Xcode build phase (BananaMacBeta): puts Banana Pi's Python runtime inside the app, at
# Contents/Resources/PiRuntime. PiDevelopment only; other configurations carry nothing.
set -euo pipefail
[ "${CONFIGURATION:-}" = PiDevelopment ] || exit 0
# The embed caller keeps this lock until its copy is complete. Standalone builds take it too.
if [ "${BANANA_RUNTIME_CACHE_LOCKED:-}" != 1 ]; then
  exec /usr/bin/python3 "$(dirname "$0")/runtime-cache-lock.py" /bin/bash "$0" "$@"
fi
runtime=$("$SRCROOT/tools/pi-mac-inference/build-runtime.sh")
key=$(basename "$runtime")
dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/PiRuntime"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ "${CODE_SIGNING_ALLOWED:-YES}" = NO ] && identity=""
stamp="$key ${identity:--}"
if [ "$(cat "$dest/.runtime" 2>/dev/null)" = "$stamp" ]; then exit 0; fi
mkdir -p "$dest"
rsync -a --delete --exclude .runtime "$runtime/python/" "$dest/"
# Its binaries come ad-hoc signed (CPython build, wheels). A real identity signs them as its own,
# with the hardened runtime, as notarization needs.
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
  find "$dest" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
      codesign --force --options runtime --timestamp --sign "$identity" "$f"
    fi
  done
fi
echo "$stamp" > "$dest/.runtime"
