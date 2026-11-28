#!/bin/bash
# Embeds mlx-serve (github.com/ddalcu/mlx-serve, MIT) in the Mac app as Contents/Resources/MlxServe.
# Macs with 32 GiB or more run Gemma 4 26B A4B on it (docs/design/PI-LOCAL-MODEL.md). The release
# tarball is pinned by version and SHA-256, fetched once into ~/Library/Caches (shared by every
# worktree) and never committed. Called by embed-runtime.sh, inside its cache lock.
set -euo pipefail
[ "${BANANA_LOCAL_AI:-NO}" = YES ] || exit 0
VERSION=26.11.4
ASSET=mlx-serve-bin-macos-arm64.tar.gz
SHA256=2079e8649b4a25aed267bf43117ef23b026c833453f0cdd0eff2d328aa1e0832
URL="https://github.com/ddalcu/mlx-serve/releases/download/v$VERSION/$ASSET"

cache="$HOME/Library/Caches/Banana Pi build/mlx-serve/$VERSION"
if [ ! -e "$cache/.complete" ]; then
  echo "Fetching mlx-serve ${VERSION}…" >&2
  mkdir -p "$(dirname "$cache")"
  work=$(mktemp -d "$(dirname "$cache")/.work.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  curl -fsSL --retry 3 -o "$work/$ASSET" "$URL"
  actual=$(shasum -a 256 "$work/$ASSET" | cut -d ' ' -f 1)
  [ "$actual" = "$SHA256" ] || { echo "error: $ASSET checksum $actual, expected $SHA256" >&2; exit 1; }
  mkdir "$work/out"
  tar -xzf "$work/$ASSET" -C "$work/out"
  [ -x "$work/out/mlx-serve-macos-arm64/mlx-serve" ] || { echo "error: $ASSET has no mlx-serve" >&2; exit 1; }
  rm -rf "$cache"
  mv "$work/out/mlx-serve-macos-arm64" "$cache"
  touch "$cache/.complete"
  rm -rf "$work"; trap - EXIT
fi

dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MlxServe"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ "${CODE_SIGNING_ALLOWED:-YES}" = NO ] && identity=""
helper_entitlements=""
case "${BANANA_RELEASE_CHANNEL:-}" in
  appstore|testflight) helper_entitlements="$SRCROOT/tools/pi-mac-inference/runtime-helper.entitlements" ;;
esac
stamp="$VERSION $SHA256 ${identity:--}"
if [ -n "$helper_entitlements" ]; then
  stamp="$stamp $(shasum -a 256 "$helper_entitlements" | cut -d ' ' -f 1)"
fi
if [ "$(cat "$dest/.mlx-serve" 2>/dev/null)" = "$stamp" ]; then exit 0; fi
mkdir -p "$dest"
# The upstream LICENSE, LICENSE-APACHE-2.0 and NOTICE travel with the binary.
rsync -a --delete --exclude .mlx-serve --exclude .complete "$cache/" "$dest/"
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
  # Libraries first, then the executable that loads them.
  for f in "$dest"/lib/*.dylib "$dest/mlx-serve"; do
    flags=(--force --options runtime --timestamp --sign "$identity")
    if [[ -n "$helper_entitlements" && "$f" == "$dest/mlx-serve" ]]; then
      flags+=(--entitlements "$helper_entitlements")
    fi
    codesign "${flags[@]}" "$f"
  done
fi
echo "$stamp" > "$dest/.mlx-serve"
