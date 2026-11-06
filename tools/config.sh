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

# Cloud Dev must have its own native identity and staging provider/service configuration.
banana_require_dev() {
  for _dev_key in BANANA_SERVICE_HOST_DEV BANANA_GOOGLE_CLIENT_DEV BANANA_GOOGLE_SERVER_CLIENT_DEV; do
    _dev_value=$(banana_setting "$_dev_key")
    _stable_key=${_dev_key%_DEV}
    _stable_value=$(banana_setting "$_stable_key")
    if [ -z "$_dev_value" ] || [ "$_dev_value" = "$_stable_value" ]; then
      echo "Cloud Dev requires a separate, configured $_dev_key. Not building or installing."
      return 1
    fi
  done
  case "$(banana_setting BANANA_SERVICE_HOST_DEV)" in
    api.bananatheapp.com|app.bananatheapp.com|*://*|*/*)
      echo "Cloud Dev requires an isolated service hostname. Not building or installing."
      return 1;;
  esac
}

# Local installs must identify the source too; a dirty tree must not claim to be the commit.
banana_source_revision() {
  _banana_revision=$(git rev-parse HEAD) || return 1
  [ -z "$(git status --porcelain)" ] || _banana_revision="$_banana_revision-dirty"
  printf '%s\n' "$_banana_revision"
}

# Use the configured signing key when Xcode has no interactive developer login.
# Explicit AUTH_ARGS remains available to existing callers.
banana_xcodebuild() {
  if [ -n "${AUTH_ARGS:-}" ]; then
    # Legacy callers supply an argument list, not executable shell code.
    command xcodebuild $AUTH_ARGS "$@"
  elif [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    _banana_signing_key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
    [ -f "$_banana_signing_key" ] || { echo "Configured Apple signing key is missing." >&2; return 1; }
    command xcodebuild -authenticationKeyPath "$_banana_signing_key" \
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" "$@"
  else
    command xcodebuild "$@"
  fi
}
