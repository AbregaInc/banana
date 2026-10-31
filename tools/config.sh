# Sourced by the build scripts, from the repo root:  . tools/config.sh [require]
#
# The team, bundle id, iCloud container and Google client a build is made with come from
# Config/Local.xcconfig, which is not tracked (see Config/Local.example.xcconfig). Keep yours in
# one place outside the repo, ~/.config/banana/Local.xcconfig (or $BANANA_CONFIG), and this links
# it into whichever checkout or worktree is building.
#
# `require` stops when there is none: a script that installs over an app you use must not build
# the stand-in one, which has another bundle id and no iCloud.
_own="${BANANA_CONFIG:-$HOME/.config/banana/Local.xcconfig}"
if [ "${BANANA_NO_LOCAL_CONFIG:-0}" = 1 ] && { [ -e Config/Local.xcconfig ] || [ -L Config/Local.xcconfig ]; }; then
  echo "Clean-config mode refuses an existing Config/Local.xcconfig. Use an unconfigured checkout."
  return 1
fi
if [ "${BANANA_NO_LOCAL_CONFIG:-0}" != 1 ] && [ ! -e Config/Local.xcconfig ] && [ -f "$_own" ]; then
  ln -s "$_own" Config/Local.xcconfig
fi
if [ "${1:-}" = require ] && [ ! -e Config/Local.xcconfig ]; then
  echo "No Config/Local.xcconfig, so this would build the stand-in app, not yours."
  echo "Copy Config/Local.example.xcconfig to Config/Local.xcconfig (or to $_own) and fill it in."
  exit 1
fi

# banana_setting NAME: the value from your config, else the stand-in.
banana_setting() {
  for _f in Config/Local.xcconfig Config/Base.xcconfig; do
    [ -e "$_f" ] || continue
    _v=$(sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$_f" | head -1)
    if [ -n "$_v" ]; then printf '%s\n' "$_v"; return; fi
  done
}

# App Store Connect API key, for the scripts that upload or ask Apple about builds:
# ASC_KEY_ID, ASC_ISSUER_ID and optionally ASC_KEY_PATH, in the environment or in this file.
_release="${BANANA_RELEASE_ENV:-$HOME/.config/banana/release.env}"
if [ "${BANANA_NO_LOCAL_CONFIG:-0}" != 1 ] && [ -f "$_release" ]; then . "$_release"; fi
