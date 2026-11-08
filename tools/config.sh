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

# The repo's two test simulators (AGENTS.md: reuse them, name them by UDID).
BANANA_SIM_PHONE="${BANANA_SIM_PHONE:-6DFFC0F9-AA09-41C8-B868-FB0D9CC28255}"
BANANA_SIM_PAD="${BANANA_SIM_PAD:-43EFC551-5368-4F79-9E52-E3DB87A72F48}"

# Builds use every core. The build lock already lets one build run at a time, so the old
# `-jobs 2` left eight of ten cores idle (8 Nov 2026). Override with BUILD_JOBS=N.
: "${BUILD_JOBS:=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
export BUILD_JOBS

# One compilation cache for every worktree and checkout, outside them all. Prefix mapping keys
# each compile by the source relative to its checkout and derived data, so a new worktree reuses
# what another one already compiled. Debug and test builds only (BANANA_CACHE_CONFIGS): see
# docs/performance/build-pipeline.md for the measurements and why Release is not cached. Under
# the mapping `#filePath` reads /^src/...; tests use SourceTree.root for the checkout.
# BANANA_CACHE=0 turns it off; tools/clean-builds.sh keeps the folder under its cap.
BANANA_XCODE_CAS="${BANANA_XCODE_CAS:-$HOME/Library/Caches/banana-xcode-cas}"
BANANA_CACHE_CONFIGS="${BANANA_CACHE_CONFIGS:-Debug PiDevelopment}"
BANANA_CACHE_LIMIT_GB="${BANANA_CACHE_LIMIT_GB:-30}"
_banana_root=$(pwd -P)

# banana_xcode ARGS...: xcodebuild with the shared defaults, under the shared locks.
#   - `-jobs $BUILD_JOBS` unless the caller passed -jobs;
#   - the compilation cache settings for a cached -configuration;
#   - compiling actions hold the `build` lock; every action that writes a -derivedDataPath holds
#     that folder's guard, so two xcodebuilds never write one folder (tools/agents/xcode-lock.sh).
# BANANA_NO_LOCK=1 runs it unlocked (a caller that already holds what it needs).
banana_xcode() {
  # zsh callers (ui-tests.sh) split the settings string like sh does.
  [ -z "${ZSH_VERSION:-}" ] || setopt local_options sh_word_split
  _bx_action=none _bx_dd="" _bx_config="" _bx_jobs="" _bx_prev=""
  for _bx_arg in "$@"; do
    case "$_bx_prev" in
      -derivedDataPath) _bx_dd=$_bx_arg ;;
      -configuration) _bx_config=$_bx_arg ;;
    esac
    case "$_bx_arg" in
      build|build-for-testing|archive|test|analyze|install|clean|docbuild) _bx_action=compile ;;
      test-without-building) [ "$_bx_action" = compile ] || _bx_action=run ;;
      -jobs) _bx_jobs=1 ;;
      -exportArchive|-showBuildSettings|-resolvePackageDependencies|-list|-version) _bx_action=none ;;
    esac
    _bx_prev=$_bx_arg
  done
  _bx_extra=""
  if [ "$_bx_action" = compile ]; then
    [ -n "$_bx_jobs" ] || _bx_extra="-jobs $BUILD_JOBS"
    case " $BANANA_CACHE_CONFIGS " in
      *" ${_bx_config:-unset} "*)
        if [ "${BANANA_CACHE:-1}" != 0 ]; then
          _bx_extra="$_bx_extra COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH=$BANANA_XCODE_CAS"
          _bx_extra="$_bx_extra COMPILATION_CACHE_LIMIT_SIZE=${BANANA_CACHE_LIMIT_GB}G"
          _bx_extra="$_bx_extra SWIFT_ENABLE_PREFIX_MAPPING=YES CLANG_ENABLE_PREFIX_MAPPING=YES"
          _bx_extra="$_bx_extra SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES"
          # The derived data too: each worktree's package checkouts and generated module maps
          # live there, and an unmapped path in any input makes every compile that sees it miss.
          if [ -n "$_bx_dd" ] && mkdir -p "$_bx_dd" 2>/dev/null; then
            _bx_dd_abs=$(cd "$_bx_dd" && pwd -P)
            _bx_extra="$_bx_extra SWIFT_OTHER_PREFIX_MAPPINGS=$_bx_dd_abs=/^dd CLANG_OTHER_PREFIX_MAPPINGS=$_bx_dd_abs=/^dd"
          fi
        fi ;;
    esac
  fi
  _bx_lock="$_banana_root/tools/agents/xcode-lock.sh"
  if [ "${BANANA_NO_LOCK:-0}" = 1 ] || [ "$_bx_action" = none ] || [ ! -x "$_bx_lock" ]; then
    # shellcheck disable=SC2086
    command xcodebuild $_bx_extra "$@"
  elif [ "$_bx_action" = compile ] && [ -n "$_bx_dd" ]; then
    # shellcheck disable=SC2086
    "$_bx_lock" -l build -d "$_bx_dd" xcodebuild $_bx_extra "$@"
  elif [ "$_bx_action" = compile ]; then
    # shellcheck disable=SC2086
    "$_bx_lock" -l build xcodebuild $_bx_extra "$@"
  elif [ -n "$_bx_dd" ]; then
    "$_bx_lock" -d "$_bx_dd" xcodebuild "$@"
  else
    command xcodebuild "$@"
  fi
}

# Use the configured signing key when Xcode has no interactive developer login.
# Explicit AUTH_ARGS remains available to existing callers.
banana_xcodebuild() {
  [ -z "${ZSH_VERSION:-}" ] || setopt local_options sh_word_split
  if [ -n "${AUTH_ARGS:-}" ]; then
    # Legacy callers supply an argument list, not executable shell code.
    # shellcheck disable=SC2086
    banana_xcode $AUTH_ARGS "$@"
  elif [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    _banana_signing_key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
    [ -f "$_banana_signing_key" ] || { echo "Configured Apple signing key is missing." >&2; return 1; }
    banana_xcode -authenticationKeyPath "$_banana_signing_key" \
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" "$@"
  else
    banana_xcode "$@"
  fi
}
