#!/bin/bash
# Everything a rollout can fail on, before the rollout: run this and get a pass before shipping.
#
#   tools/preflight.sh                          # Beta rollout checks, default unit tests
#   tools/preflight.sh --channel stable         # Stable: TestFlight iOS + Mac, Mac direct
#   tools/preflight.sh --channel appstore       # the App Store app: iOS + Mac, configuration
#                                               # AppStore (BANANA_APP_STORE_MODULES only)
#   tools/preflight.sh CalendarOwnershipTests   # these unit test classes instead of the default
#   tools/preflight.sh --build 116 --version 1.0.4   # stamp what the rollout will stamp
#                                               # (default: the next build number, last version)
#   tools/preflight.sh --skip ios-stable,unit   # leave steps out (names as in the summary)
#   tools/preflight.sh --dry-run                # print the steps and commands only
#
# Steps (Beta): clean tree, xcodegen, iOS Beta Release build, the Stable iOS archive (Email off,
# then the strict tools/check-release.sh), the Mac Beta direct archive and export (with its check),
# unit tests in Debug and optimized (`unit`, `unit-optimized`), and the Service tests when
# Service/ changed since the last release tag. Stable swaps the iOS Beta build for the Mac
# TestFlight archive and builds the Stable direct app. App Store archives the iOS and Mac App
# Store app (`testflight.sh … check appstore`), each checked by tools/check-release.sh, which
# refuses anything of a module the app leaves out.
#
# The builds are the rollout's own (tools/release/lib.sh, testflight.sh check, build.sh check),
# in its derived data (.build/ios-beta, .build/ios-prod, .build/mac-check, .build/mac-distribution)
# with its settings. The iOS Beta build after this is incremental. An archive never is (xcodebuild
# archive starts from empty intermediates), so the rollout adopts these archives instead when they
# are the same commit, version and build. Pass the rollout's --build and --version to get that.
# Each step runs even when an earlier one failed, so one run lists every problem.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/release/lib.sh

channel=beta skip="" allow_dirty=0 build="" version="" tests=()
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) channel=$2; shift 2 ;;
    --build) build=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --skip) skip=",$2,"; shift 2 ;;
    --allow-dirty) allow_dirty=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) tests+=("$1"); shift ;;
  esac
done
[ "$channel" = beta ] || [ "$channel" = stable ] || [ "$channel" = appstore ] || die "--channel beta|stable|appstore"
build=${build:-$(next_build)}
version=${version:-$(last_release_version)}
version=${version:-$(project_setting MARKETING_VERSION)}
# The default unit set: the whole BananaTests target on the phone simulator (4,000-odd tests),
# run twice. `unit` is Debug: its build is the cached one ui-tests.sh shares, and only Debug stops
# at the main-thread and other Debug-only traps. `unit-optimized` is the Release BananaModelTests
# scheme: the component cost budgets are set for optimized code, so they are enforced there and
# report "not measured in an unoptimized build" in Debug (BananaTests/CostBudget.swift).
[ ${#tests[@]} -gt 0 ] || tests=(BananaTests)

OUT=${PREFLIGHT_OUT:-.build/preflight}
mkdir -p "$OUT"; rm -f "$OUT"/*.log; OUT=$(cd "$OUT" && pwd -P)
failed=0
skipped() { [[ "$skip" == *",$1,"* ]] && { SUMMARY+=("$(printf '%-34s %-6s' "$1" skip)"); return 0; }; return 1; }
check() {  # check NAME CMD...: one step, recorded pass/FAIL, never stops the run
  local name=$1; shift
  skipped "$name" && return 0
  step "$name"
  if "$@"; then step_done ok; else step_done FAIL; failed=1; fi
}

say "preflight: $channel, build $build, version $version, $(git rev-parse --short HEAD) on $(git branch --show-current), BUILD_JOBS=$BUILD_JOBS"

clean_tree() {
  [ "$DRY_RUN" = 1 ] && { say "  would check git status is empty"; return 0; }
  require_clean_tree && return 0
  [ "$allow_dirty" = 1 ] && { say "  continuing (--allow-dirty); a rollout refuses this tree"; return 0; }
  return 1
}
check clean-tree clean_tree
check xcodegen run xcodegen generate

if [ "$channel" = appstore ]; then
  check ios-appstore run tools/testflight.sh ios "$build" check appstore
  check mac-appstore run tools/testflight.sh mac "$build" check appstore
  mac_launch_evidence() {
    local candidate=".build/mac-appstore/Banana-$build.xcarchive"
    [ -d "$candidate" ] || candidate=".build/mac-appstore-check/Banana-$build.xcarchive"
    run python3 tools/mac-release-tests.py verify "$candidate"
  }
  check mac-appstore-launch mac_launch_evidence
else
  if [ "$channel" = beta ]; then
    check ios-beta build_ios_beta "$build" "$version"
  fi
  check ios-stable run tools/testflight.sh ios "$build" check
  if [ "$channel" = stable ]; then
    check mac-testflight run tools/testflight.sh mac "$build" check
    check mac-stable check_mac_direct stable "$build" "$version"
  else
    check mac-beta check_mac_direct beta "$build" "$version"
  fi
fi

unit_tests() {  # unit_tests CONFIGURATION SCHEME
  local config=$1 scheme=$2 only=() t
  for t in "${tests[@]}"; do
    case "$t" in BananaTests|BananaTests/*) only+=("-only-testing:$t") ;; *) only+=("-only-testing:BananaTests/$t") ;; esac
  done
  run banana_xcode build-for-testing -project Banana.xcodeproj -scheme "$scheme" -configuration "$config" \
    -destination 'generic/platform=iOS Simulator' ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -derivedDataPath .build/sim || return 1
  local booted=1
  xcrun simctl list devices booted | grep -q "$BANANA_SIM_PHONE" || booted=0
  local result="$OUT/unit-$config-$(date +%Y%m%d-%H%M%S).xcresult"
  run tools/agents/xcode-lock.sh -l sim-phone -d .build/sim xcodebuild test-without-building -project Banana.xcodeproj \
    -scheme "$scheme" -configuration "$config" -destination "platform=iOS Simulator,id=$BANANA_SIM_PHONE" \
    -derivedDataPath .build/sim -resultBundlePath "$result" -collect-test-diagnostics never "${only[@]}" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 300
  local rc=$?
  # A simulator this run booted goes down again; one that was already up stays for its owner.
  [ "$booted" = 1 ] || [ "$DRY_RUN" = 1 ] || xcrun simctl shutdown "$BANANA_SIM_PHONE" 2>/dev/null
  if [ "$DRY_RUN" != 1 ] && [ -d "$result" ]; then
    xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for f in d.get("testFailures", [])[:15]:
    print("    FAILED", f.get("testIdentifierString") or f.get("testName"), "|", " ".join(f.get("failureText", "").split())[:200])
print("    %s passed, %s failed, %s skipped" % (d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))'
  fi
  return $rc
}
check unit unit_tests Debug Banana
check unit-optimized unit_tests Release BananaModelTests

service_tests() {
  local tag
  tag=$(last_release_tag)
  if [ -n "$tag" ] && git diff --quiet "$tag" HEAD -- Service/; then
    say "  Service/ unchanged since $tag"
    return 0
  fi
  say "  Service/ changed since ${tag:-the first release}"
  # npm runs inside Service/ so a version manager (Volta) picks the Node it pins there.
  [ -d Service/node_modules ] || (cd Service && run npm ci) || return 1
  (cd Service && run npm test)
}
check service service_tests

summary
if [ "$DRY_RUN" = 1 ]; then say "PREFLIGHT DRY RUN: nothing was built"
elif [ "$failed" = 0 ]; then say "PREFLIGHT PASSED  (logs: $OUT)"; else say "PREFLIGHT FAILED  (logs: $OUT)"; fi
exit $failed
