#!/bin/bash
# Ship Stable build N: TestFlight for iOS and Mac (uploaded; added to the public beta group and
# submitted for Beta App Review only with --public-beta), the Mac direct download and its feed, and
# the Stable app on the owner's iPhone and iPad. Only on the owner's word for this build.
#
#   tools/release/ship-stable.sh 116 --notes-file notes.md
#   tools/release/ship-stable.sh 116 --notes-file notes.md --public-beta --what-to-test wtt.txt --review-notes review.txt
#   tools/release/ship-stable.sh 116 ... --dry-run
#
# Options:
#   --notes-file FILE     GitHub release notes for the Mac download (Markdown). Required.
#   --what-to-test FILE   TestFlight What to Test (both platforms). Required with --public-beta.
#   --review-notes FILE   notes for Beta App Review. Required with --public-beta.
#   --feed-notes TEXT     the update feed's one line; default: the notes' first line of text
#   --version V           user version; default: the latest release's
#   --public-beta         also add the build to the public beta group with What to Test and submit
#                         it for Beta App Review; without it the build is uploaded only (internal
#                         testers get it) and tools/asc-public-beta.py can do the rest later
#   --unit "A B"        unit test classes for the preflight instead of the whole BananaTests target
#   --skip-preflight      when tools/preflight.sh --channel stable already passed on this commit
#   --skip-devices        no installs on the phone and iPad
#   --dry-run             print every step; runs only read-only parts
#
# The TestFlight build and the Mac download share the number, so the plan must pick N too.
# Output: private/releases/stable-N/. The production service deploy is separate:
# tools/release/deploy-service.sh prod --yes-prod.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tools/release/lib.sh

build=${1:-}; shift || true
[[ "$build" =~ ^[1-9][0-9]*$ ]] || { sed -n '2,23p' "$0"; exit 2; }
notes="" what="" review="" feed_notes="" version="" public=0 preflight=1 devices=1 unit=()
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) notes=$2; shift 2 ;;
    --what-to-test) what=$2; shift 2 ;;
    --review-notes) review=$2; shift 2 ;;
    --feed-notes) feed_notes=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --public-beta) public=1; shift ;;
    --no-public-beta) public=0; shift ;;
    --skip-preflight) preflight=0; shift ;;
    --unit) unit=($2); shift 2 ;;
    --skip-devices) devices=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[ -f "$notes" ] || die "--notes-file FILE is required"
[ "$public" = 0 ] || { [ -f "$what" ] && [ -f "$review" ]; } || die "--what-to-test and --review-notes files are required with --public-beta"
version=${version:-$(last_release_version)}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no user version (pass --version)"
[ -n "$feed_notes" ] || feed_notes=$(grep -v -e '^#' -e '^Source:' -e '^Released:' -e '^[[:space:]]*$' "$notes" | head -1 | sed -E 's/^[-*] +//')
need ASC_KEY_ID ASC_ISSUER_ID
export DRY_RUN

if [ "$DRY_RUN" = 1 ]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/ship-stable-$build.XXXXXX"); else OUT=private/releases/stable-$build; fi
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
trap 'summary' EXIT
say "Ship Stable $version ($build) from $(git rev-parse --short HEAD) on $(git branch --show-current)$([ "$DRY_RUN" = 1 ] && echo ', dry run')"
say "  feed notes: $feed_notes"
say "  output: $OUT"

# The build number first: a taken number should not cost a preflight.
if require_clean_tree; then
  say "  checking build $build is the next free one"
  probe=$(mktemp -d "${TMPDIR:-/tmp}/plan-probe.XXXXXX")
  mac_plan stable "$version" "$build" "$probe/plan.json"
  rm -rf "$probe"
elif [ "$DRY_RUN" = 1 ]; then
  say "  (dry run continues; a real run stops here, and the plan below needs a clean tree)"
else
  die "commit or remove these first: a release is made from a clean commit"
fi

if [ "$preflight" = 1 ]; then
  step preflight
  if [ "$DRY_RUN" = 1 ]; then
    tools/preflight.sh --dry-run --channel stable --build "$build" --version "$version" | sed 's/^/  | /'
  else
    tools/preflight.sh --channel stable --build "$build" --version "$version" ${unit[@]+"${unit[@]}"} 2>&1 | tee "$STEP_LOG" | sed 's/^/  | /'
    [ "${PIPESTATUS[0]}" = 0 ] || die "preflight failed; nothing was shipped"
  fi
  step_done
else
  [ "$DRY_RUN" = 1 ] || require_clean_tree || die "commit or remove these first"
fi

step plan
plan=$OUT/plan.json
[ "$DRY_RUN" = 1 ] && rm -f "$plan"
mac_plan stable "$version" "$build" "$plan"
step_done

for platform in ios mac; do
  step "TestFlight $platform"
  run tools/testflight.sh "$platform" "$build" prepare || die "TestFlight $platform prepare failed"
  run tools/testflight.sh "$platform" "$build" upload || die "TestFlight $platform upload failed"
  step_done
done

if [ "$public" = 1 ]; then
  step "public beta group and What to Test"
  if [ "$DRY_RUN" = 1 ]; then
    say "  would wait until App Store Connect has processed $build on both platforms"
  else
    # Apple processes an upload for several minutes; asc-public-beta.py refuses until it is VALID.
    deadline=$(( $(date +%s) + ${BANANA_ASC_WAIT:-3600} ))
    until attempt=$(python3 tools/asc-public-beta.py "$build" --what-to-test "$what" --review-notes "$review" 2>&1); do
      printf '%s\n' "$attempt" >> "$STEP_LOG"
      grep -q 'wait until Apple' <<< "$attempt" || die "asc-public-beta.py failed; see $STEP_LOG"
      [ "$(date +%s)" -lt "$deadline" ] || die "build $build is still processing after an hour; run tools/asc-public-beta.py later"
      sleep 60
    done
  fi
  run python3 tools/asc-public-beta.py "$build" --what-to-test "$what" --review-notes "$review" --apply ||
    die "adding $build to the public beta failed"
  step_done
fi

mac_release stable "$plan" "$notes" "$feed_notes" "$OUT"

if [ "$devices" = 1 ]; then
  step "Stable on the phone and iPad"
  # ios-install.sh builds the Stable app with this build number and installs over it (never an
  # uninstall); it asks before touching the production app, and this rollout is that yes.
  if run python3 tools/release/devices.py run phone ipad --log "$OUT/ios-install-devices.log" -- \
      sh -c 'printf "yes\n" | BUILD_NUMBER="$1" tools/ios-install.sh prod "$2"' _ "$build" '{id}'; then
    step_done
  else
    step_done FAIL
    die "shipped, but a device was not updated: retry with BUILD_NUMBER=$build tools/ios-install.sh prod <device>"
  fi
fi
if [ "$DRY_RUN" = 1 ]; then say "Dry run of Stable $version ($build) complete: nothing was changed."; else say "Stable $version ($build) shipped."; fi
