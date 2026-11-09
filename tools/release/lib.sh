# Shared by tools/preflight.sh and tools/release/*.sh. Source it from the repo root, in bash.
#
# Private values never live in this tree. They come from:
#   Config/Local.xcconfig (via tools/config.sh)         team, bundle ids, Google clients
#   ~/.config/banana/release.env                         App Store Connect key, Beta update key/profile
#   ~/.config/banana/distribution.env                    Developer ID identities and profiles, Sparkle
#                                                        tools and keys, which devices get installs
# The names each script needs are listed in tools/release/README.md.

. tools/config.sh require
_dist="${BANANA_DISTRIBUTION_ENV:-$HOME/.config/banana/distribution.env}"
if [ -f "$_dist" ]; then set -a; . "$_dist"; set +a; fi

DRY_RUN=${DRY_RUN:-0}
REPO_SLUG=${BANANA_REPO_SLUG:-AbregaInc/banana}
SITE_HOST=${BANANA_SITE_HOST:-https://bananatheapp.com}
STEP_NO=0
STEP_LOG=/dev/null
SUMMARY=()

say() { printf '%s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

# need NAME...: stop unless each variable is set (names only, never values).
need() {
  local missing=()
  for v in "$@"; do [ -n "${!v:-}" ] || missing+=("$v"); done
  [ ${#missing[@]} -eq 0 ] || die "not configured: ${missing[*]} (see tools/release/README.md)"
}

# step NAME: start a numbered step with its own log in $OUT.
step() {
  STEP_NO=$((STEP_NO + 1))
  STEP_NAME=$1
  STEP_LOG="$OUT/$(printf '%02d' "$STEP_NO")-${1// /-}.log"
  STEP_START=$(date +%s)
  printf '\n== %d. %s  (%s)\n' "$STEP_NO" "$1" "$(date '+%H:%M:%S')"
}

step_done() {
  local secs=$(( $(date +%s) - STEP_START ))
  SUMMARY+=("$(printf '%-34s %-6s %3dm%02ds' "$STEP_NAME" "${1:-ok}" $((secs / 60)) $((secs % 60)))")
}

summary() {
  printf '\n%-34s %-6s %s\n' step result time
  [ ${#SUMMARY[@]} -eq 0 ] || printf '%s\n' "${SUMMARY[@]}"
}

# run CMD...: run and log to the step's log; in a dry run, print it instead.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  would run:'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  printf '  $'; printf ' %q' "$@"; printf '\n'
  "$@" >> "$STEP_LOG" 2>&1 || {
    local rc=$?
    printf '  exit %d; last lines of %s:\n' "$rc" "$STEP_LOG"
    grep -E ' error: |error:|FAILED|Not for|UNRELEASED' "$STEP_LOG" | sort -u | head -15 | sed 's/^/    /'
    tail -8 "$STEP_LOG" | sed 's/^/    /'
    return "$rc"
  }
}

# safe CMD...: read-only work that runs even in a dry run (plans into a temp file, listings).
safe() {
  printf '  $'; printf ' %q' "$@"; printf '\n'
  "$@" >> "$STEP_LOG" 2>&1
}

require_clean_tree() {
  local dirty
  dirty=$(git status --porcelain --untracked-files=normal)
  [ -z "$dirty" ] && return 0
  printf '  not clean:\n%s\n' "$(printf '%s\n' "$dirty" | head -20 | sed 's/^/    /')"
  return 1
}

project_setting() {  # MARKETING_VERSION | CURRENT_PROJECT_VERSION from project.yml
  sed -n "s/^ *$1: *\"\\(.*\\)\"/\\1/p" project.yml | head -1
}

# The newest Mac release tag reachable from HEAD (either channel), by build number.
last_release_tag() {
  git tag --merged HEAD --list 'mac-v*' 'mac-beta-v*' |
    awk -F- '{ print $NF "\t" $0 }' | sort -n | tail -1 | cut -f2
}

# The build number the next release will get: one past every Mac release tag known here and
# project.yml (release-plan.py makes the same choice, with GitHub's releases added).
next_build() {
  { git tag --list 'mac-v*' 'mac-beta-v*' | awk -F- '{ print $NF }'; project_setting CURRENT_PROJECT_VERSION; } |
    sort -n | tail -1 | awk '{ print $1 + 1 }'
}

# The user version the latest release used, for releases that keep it.
last_release_version() {
  last_release_tag | sed -E 's/^mac(-beta)?-v([0-9.]+)-[0-9]+$/\2/'
}

# --- The builds. Preflight and the rollouts call these same functions, with the same derived
# data and settings, so the rollout's builds after a preflight are incremental. ---------------

IOS_BETA_APP=".build/ios-beta/Build/Products/Release-iphoneos/Banana Beta.app"

# build_ios_beta BUILD VERSION: the Beta iOS app that goes on the owner's devices (Email on,
# local AI off). Not distributed, so no release check.
build_ios_beta() {
  run banana_xcodebuild -project Banana.xcodeproj -scheme BananaBeta -configuration Release \
    BANANA_UNRELEASED=NO BANANA_LOCAL_EMAIL=YES BANANA_LOCAL_AI=NO \
    "BANANA_SOURCE_COMMIT=$(banana_source_revision)" "CURRENT_PROJECT_VERSION=$1" "MARKETING_VERSION=$2" \
    -destination 'generic/platform=iOS' -derivedDataPath .build/ios-beta -allowProvisioningUpdates -quiet build
}

# The Mac direct-download environment for a channel (build.sh reads these).
mac_direct_env() {
  export BANANA_DISTRIBUTION_CHANNEL=$1
  if [ "$1" = beta ]; then
    need BANANA_UPDATE_PUBLIC_KEY_BETA BANANA_DEVELOPER_ID_PROFILE_BETA BANANA_DEVELOPER_ID_IDENTITY_BETA
    export BANANA_UPDATE_FEED_URL="$SITE_HOST/updates/mac-beta/appcast.xml"
    export BANANA_UPDATE_PUBLIC_KEY="$BANANA_UPDATE_PUBLIC_KEY_BETA"
    export BANANA_DEVELOPER_ID_PROFILE="$BANANA_DEVELOPER_ID_PROFILE_BETA"
    export BANANA_DEVELOPER_ID_IDENTITY="$BANANA_DEVELOPER_ID_IDENTITY_BETA"
  else
    need BANANA_UPDATE_PUBLIC_KEY_STABLE BANANA_DEVELOPER_ID_PROFILE_STABLE BANANA_DEVELOPER_ID_IDENTITY_STABLE
    export BANANA_UPDATE_FEED_URL="$SITE_HOST/updates/mac/appcast.xml"
    export BANANA_UPDATE_PUBLIC_KEY="$BANANA_UPDATE_PUBLIC_KEY_STABLE"
    export BANANA_DEVELOPER_ID_PROFILE="$BANANA_DEVELOPER_ID_PROFILE_STABLE"
    export BANANA_DEVELOPER_ID_IDENTITY="$BANANA_DEVELOPER_ID_IDENTITY_STABLE"
  fi
}

# check_mac_direct CHANNEL BUILD VERSION: the release archive and export, thrown away after.
check_mac_direct() {
  mac_direct_env "$1"
  run env BANANA_CHECK_BUILD="$2" BANANA_CHECK_VERSION="$3" tools/mac-distribution/build.sh check
}

# --- The Mac direct release, both channels: plan, build, tag, draft, package, publish, site. ---

# mac_plan CHANNEL VERSION BUILD PLAN: write the plan and check it names the expected build.
mac_plan() {
  local channel=$1 version=$2 build=$3 plan=$4
  git fetch origin --tags --quiet >> "$STEP_LOG" 2>&1 || true
  if [ -e "$plan" ]; then
    say "  plan exists: $plan (kept; delete it to plan again)"
  else
    safe python3 tools/mac-distribution/release-plan.py --channel "$channel" --version "$version" --build "$build" --out "$plan" ||
      die "release-plan.py failed; see $STEP_LOG"
  fi
  local planned
  planned=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$plan")
  say "  planned build $planned, tag $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$plan")"
  [ "$planned" = "$build" ] || {
    rm -f "$plan"
    if [ "$planned" -gt "$build" ]; then die "build $build is taken (the next free build is $planned)"
    else die "the next free build is $planned, not $build: ship $planned, or check for a missing tag"; fi
  }
}

plan_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

# mac_release CHANNEL PLAN NOTES_FILE FEED_NOTES DIR: everything after the plan up to the site.
mac_release() {
  local channel=$1 plan=$2 notes=$3 feed_notes=$4 dir=$5
  local tag version build commit app title prerelease
  tag=$(plan_field "$plan" tag); version=$(plan_field "$plan" shortVersion)
  build=$(plan_field "$plan" version); commit=$(plan_field "$plan" sourceCommit)
  if [ "$channel" = beta ]; then app='Banana Beta.app'; title="Banana Beta $version ($build)"; prerelease=(--prerelease --latest=false)
  else app='Banana.app'; title="Banana for Mac $version ($build)"; prerelease=(--latest); fi

  step "Mac $channel build"
  mac_direct_env "$channel"
  [ "$DRY_RUN" = 1 ] || [ "$(git rev-parse HEAD)" = "$commit" ] || die "HEAD is not the planned commit"
  case "$plan" in /*) ;; *) plan="$PWD/$plan" ;; esac
  run env BANANA_RELEASE_PLAN="$plan" tools/mac-distribution/build.sh release || die "Mac build failed"
  step_done

  step "tag and draft $tag"
  run git tag -a "$tag" "$commit" -m "$title" || die "tag failed"
  run git push origin "$tag" || die "tag push failed (the private-text guard runs here)"
  run gh release create "$tag" --repo "$REPO_SLUG" --verify-tag --draft "${prerelease[@]}" \
    --title "$title" --notes-file "$notes" || die "draft failed"
  step_done

  step "package and notarize"
  local sign=()
  if [ "$channel" = beta ]; then need BANANA_SPARKLE_KEY_ACCOUNT_BETA; sign=(--key-account "$BANANA_SPARKLE_KEY_ACCOUNT_BETA")
  else need BANANA_SPARKLE_KEY_FILE_STABLE; sign=(--key-file "$BANANA_SPARKLE_KEY_FILE_STABLE"); fi
  need BANANA_SPARKLE_BIN ASC_KEY_ID ASC_ISSUER_ID
  export ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  run python3 tools/mac-distribution/package.py "private/mac-distribution/export/$app" \
    --out "$dir/package" --base-url "$(plan_field "$plan" baseURL)" --sparkle-bin "$BANANA_SPARKLE_BIN" \
    "${sign[@]}" --identity "$BANANA_DEVELOPER_ID_IDENTITY" --notes "$feed_notes" || die "packaging failed"
  [ "$DRY_RUN" = 1 ] || [ -f "$dir/package/release.json" ] || die "no release.json from package.py"
  step_done

  step "upload and publish $tag"
  run gh release upload "$tag" --repo "$REPO_SLUG" "$dir/package/Banana.dmg" "$dir/package/Banana.dmg.sha256" || die "upload failed"
  run gh release edit "$tag" --repo "$REPO_SLUG" --draft=false "${prerelease[@]}" || die "publish failed"
  step_done

  site_release "$channel" "$dir" "$version" "$build"
}

# site_release CHANNEL DIR VERSION BUILD: stage the feed and redirect, deploy, commit the files.
site_release() {
  local channel=$1 dir=$2 version=$3 build=$4 route=mac name='Mac'
  [ "$channel" = beta ] && { route=mac-beta; name='Mac Beta'; }
  step "stage and publish the site"
  run python3 tools/mac-distribution/stage-site.py --release "$dir/package" --out "$dir/site" || die "staging failed"
  # Only this channel's feed, its redirect and the headers may change; anything else is a mistake.
  local allowed=(_headers _redirects "updates/$route/appcast.xml" "updates/$route/release.json")
  if [ "$DRY_RUN" = 1 ]; then
    say "  would copy ${allowed[*]} from $dir/site into LandingPage/site after checking nothing else differs"
  else
    local changed
    changed=$(cd "$dir/site" && find . -type f | sed 's|^\./||' | while read -r f; do
      cmp -s "$f" "$OLDPWD/LandingPage/site/$f" || echo "$f"; done)
    for f in $changed; do
      case " ${allowed[*]} " in *" $f "*) ;; *) die "staging changed $f, which a $channel release must not touch";; esac
      cp "$dir/site/$f" "LandingPage/site/$f"
    done
  fi
  run bash LandingPage/publish.sh || die "site publish failed"
  run curl -fsS -o /dev/null "$SITE_HOST/updates/$route/appcast.xml" || die "the feed is not reachable"
  if [ "$DRY_RUN" != 1 ]; then
    curl -fsS "$SITE_HOST/updates/$route/appcast.xml" | grep -q "sparkle:version=\"$build\"" ||
      die "the live $route feed does not offer build $build yet"
    say "  live: $route feed offers $build; /download/$route -> $(curl -s -o /dev/null -w '%{redirect_url}' "$SITE_HOST/download/$route")"
  fi
  local files=()
  for f in "${allowed[@]}"; do git diff --quiet -- "LandingPage/site/$f" || files+=("LandingPage/site/$f"); done
  [ "$DRY_RUN" = 1 ] && files=("LandingPage/site/_redirects" "LandingPage/site/updates/$route/appcast.xml" "LandingPage/site/updates/$route/release.json")
  local message=(-m "Publish $name $version ($build)")
  [ -z "${BANANA_COMMIT_TRAILER:-}" ] || message+=(-m "$BANANA_COMMIT_TRAILER")
  run git commit "${message[@]}" -- "${files[@]}" || die "site commit failed"
  run git push origin HEAD || say "  push failed: push the site commit by hand"
  if [ "$DRY_RUN" != 1 ] && [ -n "$(git status --porcelain)" ]; then
    say "  note: publishing left other changes in the tree (not committed):"
    git status --porcelain | head -10 | sed 's/^/    /'
  fi
  step_done
}
