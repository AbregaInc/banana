#!/bin/bash
# Ship Beta build N: iOS Beta on the owner's iPhone and iPad, the Mac Beta direct download, and its
# feed on the website. Replaces the per-build scripts that were copied with sed.
#
#   tools/release/ship-beta.sh 116 --notes-file notes.md            # the whole rollout
#   tools/release/ship-beta.sh 116 --notes-file notes.md --dry-run  # every step, nothing changed
#   tools/release/ship-beta.sh 116 --notes-file notes.md --install-mac   # and install it on this Mac
#
# Options:
#   --notes-file FILE   GitHub release notes (Markdown). Required.
#   --feed-notes TEXT   the one line in the update feed; default: the notes' first line of text
#   --version V         user version; default: the latest release's
#   --install-mac       after publishing: verify the DMG, quit Banana Beta, back it up, install, relaunch
#   --unit "A B"        unit test classes for the preflight instead of the whole BananaTests target
#   --skip-preflight    when tools/preflight.sh already passed on this commit
#   --skip-ios          the Mac release only
#   --dry-run           print every step; runs only read-only parts (the plan into a temp file,
#                       device discovery)
#
# Steps: preflight; plan (checks the planned build is N); iOS Beta build, install and launch on
# the phone and iPad (found by kind through devicectl; a locked or unreachable device is waited
# for and retried, and a failure is reported without stopping the Mac release); Mac build, tag,
# GitHub draft, package and notarize, upload, publish; stage the site feed, deploy it, commit and
# push the three site files; optionally install on this Mac. Output: private/releases/beta-N/.
# Never deploys the service: that is tools/release/deploy-service.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tools/release/lib.sh

build=${1:-}; shift || true
[[ "$build" =~ ^[1-9][0-9]*$ ]] || { sed -n '2,26p' "$0"; exit 2; }
notes="" feed_notes="" version="" install_mac=0 preflight=1 ios=1 unit=()
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) notes=$2; shift 2 ;;
    --feed-notes) feed_notes=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --install-mac) install_mac=1; shift ;;
    --skip-preflight) preflight=0; shift ;;
    --unit) unit=($2); shift 2 ;;
    --skip-ios) ios=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[ -f "$notes" ] || die "--notes-file FILE is required"
version=${version:-$(last_release_version)}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no user version (pass --version)"
[ -n "$feed_notes" ] || feed_notes=$(grep -v -e '^#' -e '^Source:' -e '^Released:' -e '^[[:space:]]*$' "$notes" | head -1 | sed -E 's/^[-*] +//')
export DRY_RUN

if [ "$DRY_RUN" = 1 ]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/ship-beta-$build.XXXXXX"); else OUT=private/releases/beta-$build; fi
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
trap 'summary' EXIT
say "Ship Beta $version ($build) from $(git rev-parse --short HEAD) on $(git branch --show-current)$([ "$DRY_RUN" = 1 ] && echo ', dry run')"
say "  feed notes: $feed_notes"
say "  output: $OUT"

# The build number first: a taken number should not cost a preflight.
if require_clean_tree; then
  say "  checking build $build is the next free one"
  probe=$(mktemp -d "${TMPDIR:-/tmp}/plan-probe.XXXXXX")
  mac_plan beta "$version" "$build" "$probe/plan.json"
  rm -rf "$probe"
elif [ "$DRY_RUN" = 1 ]; then
  say "  (dry run continues; a real run stops here, and the plan below needs a clean tree)"
else
  die "commit or remove these first: a release is made from a clean commit"
fi

if [ "$preflight" = 1 ]; then
  step preflight
  if [ "$DRY_RUN" = 1 ]; then
    tools/preflight.sh --dry-run --build "$build" --version "$version" | sed 's/^/  | /'
  else
    tools/preflight.sh --build "$build" --version "$version" ${unit[@]+"${unit[@]}"} 2>&1 | tee "$STEP_LOG" | sed 's/^/  | /'
    [ "${PIPESTATUS[0]}" = 0 ] || die "preflight failed; nothing was shipped"
  fi
  step_done
else
  [ "$DRY_RUN" = 1 ] || require_clean_tree || die "commit or remove these first"
fi

step plan
plan=$OUT/plan.json
[ "$DRY_RUN" = 1 ] && rm -f "$plan"   # a dry run plans into its temp folder every time
mac_plan beta "$version" "$build" "$plan"
step_done

ios_status=skipped
if [ "$ios" = 1 ]; then
  step "iOS Beta build"
  build_ios_beta "$build" "$version" || die "iOS Beta build failed"
  if [ "$DRY_RUN" != 1 ]; then
    python3 - "$IOS_BETA_APP" "$plan" <<'PY' || die "the built app is not the planned one"
import json, plistlib, sys
info = plistlib.load(open(sys.argv[1] + "/Info.plist", "rb")); plan = json.load(open(sys.argv[2]))
wrong = {k: (info.get(k), v) for k, v in {"BananaSourceCommit": plan["sourceCommit"], "CFBundleVersion": plan["version"],
         "BananaReleaseChannel": "beta"}.items() if info.get(k) != v}
sys.exit(f"  mismatch: {wrong}" if wrong else 0)
PY
    run codesign --verify --deep --strict "$IOS_BETA_APP" || die "the iOS app's signature does not verify"
  fi
  step_done

  step "iOS Beta install"
  bundle=$( [ "$DRY_RUN" = 1 ] && echo '<beta bundle id>' || /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$IOS_BETA_APP/Info.plist")
  ios_status=ok
  run python3 tools/release/devices.py run phone ipad --log "$OUT/ios-install-devices.log" -- \
    xcrun devicectl device install app --device '{id}' "$IOS_BETA_APP" --timeout 180 || ios_status=FAIL
  run python3 tools/release/devices.py run phone ipad --wait 60 --log "$OUT/ios-launch-devices.log" -- \
    xcrun devicectl device process launch --device '{id}' "$bundle" --terminate-existing --timeout 30 || ios_status=FAIL
  [ "$DRY_RUN" = 1 ] || touch .build/ios-beta/.keep-build
  [ "$ios_status" = ok ] || say "  an iOS install or launch failed (above); the Mac release continues. Retry: tools/release/devices.py run phone ipad -- xcrun devicectl device install app --device {id} \"$IOS_BETA_APP\""
  step_done "$ios_status"
fi

mac_release beta "$plan" "$notes" "$feed_notes" "$OUT"

if [ "$install_mac" = 1 ]; then
  step "install on this Mac"
  run tools/release/install-mac.sh beta "$OUT/package/Banana.dmg" || die "Mac install failed"
  step_done
fi

[ "$ios_status" != FAIL ] || die "shipped, but an iOS device was not updated (see the iOS Beta install step)"
if [ "$DRY_RUN" = 1 ]; then say "Dry run of Beta $version ($build) complete: nothing was changed."; else say "Beta $version ($build) shipped."; fi
