#!/bin/bash
# Xcode build phase: embed Banana's Python runtime when local AI is enabled.
set -euo pipefail
[ "${BANANA_LOCAL_AI:-NO}" = YES ] || exit 0
# The embed caller keeps this lock until its copy is complete. Standalone builds take it too.
if [ "${BANANA_RUNTIME_CACHE_LOCKED:-}" != 1 ]; then
  exec /usr/bin/python3 "$(dirname "$0")/runtime-cache-lock.py" /bin/bash "$0" "$@"
fi
# Macs with 32 GiB or more serve their model with mlx-serve instead of the Python worker.
"$SRCROOT/tools/pi-mac-inference/embed-mlx-serve.sh"
runtime=$("$SRCROOT/tools/pi-mac-inference/build-runtime.sh")
key=$(basename "$runtime")
dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/PiRuntime"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ "${CODE_SIGNING_ALLOWED:-YES}" = NO ] && identity=""
helper_entitlements=""
case "${BANANA_RELEASE_CHANNEL:-}" in
  appstore|testflight) helper_entitlements="$SRCROOT/tools/pi-mac-inference/runtime-helper.entitlements" ;;
esac
stamp="$key ${identity:--}"
if [ -n "$helper_entitlements" ]; then
  stamp="$stamp $(shasum -a 256 "$helper_entitlements" | cut -d ' ' -f 1)"
fi
if [ "$(cat "$dest/.runtime" 2>/dev/null)" = "$stamp" ]; then exit 0; fi
mkdir -p "$dest"
rsync -a --delete --exclude .runtime "$runtime/python/" "$dest/"
# Its binaries come ad-hoc signed (CPython build, wheels). A real identity signs them as its own,
# with the hardened runtime, as notarization needs.
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
  find "$dest" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    format=$(file -b "$f")
    case "$format" in *Mach-O*) ;; *) continue ;; esac
    flags=(--force --options runtime --timestamp --sign "$identity")
    # Apple distribution requires embedded commands to inherit the parent's sandbox.
    # Libraries stay signed without process entitlements.
    if [[ -n "$helper_entitlements" && "$format" == *executable* ]]; then
      flags+=(--entitlements "$helper_entitlements")
    fi
    codesign "${flags[@]}" "$f"
  done
fi
echo "$stamp" > "$dest/.runtime"
