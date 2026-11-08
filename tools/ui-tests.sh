#!/bin/zsh
# Run the UI tests on the repo's simulators, in parallel, with a time limit on every test.
#
#   tools/ui-tests.sh                       # phone, everything but the timing tests
#   tools/ui-tests.sh pad                   # the iPad simulator
#   tools/ui-tests.sh phone timing          # the timing tests, one at a time
#   tools/ui-tests.sh phone ScanOneItemUITest MealEditorUITest/testTheUnconfirmedRowIsAlreadyOpen
#
# WORKERS=3 tools/ui-tests.sh               # copies of the simulator sharing the work (default 1)
# FRESH=1 tools/ui-tests.sh                 # erase the simulator first (a first boot: slow and heavy)
#
# Why it is shaped this way (11 Oct 2026: a full run took 37 minutes clean and 70 with failures):
#   - One simulator by default, kept booted between runs (8 Nov 2026). Erasing it, or letting
#     Xcode clone copies for WORKERS>1, means a first boot each run: hundreds of iOS services
#     (posters, asset downloads, Siri) loaded the Mac to 800+, and their kill at shutdown showed
#     "Family quit unexpectedly". Between runs the apps are uninstalled and the keychain and
#     privacy grants reset instead; the simulator shuts itself down after 30 idle minutes.
#     Each extra worker needs about 4 GB; the script says so when memory is short.
#   - Every test has a time limit, so one that hangs is stopped and the run goes on.
#   - The timing tests (scrolling speed, a quiet minute, a minute in the background) measure the
#     clock, so they run alone, one at a time, and only when asked for.
# Builds .build/sim first when the sources are newer than it.
#
# Locks (tools/agents/xcode-lock.sh), taken here, so don't wrap this script in one: the build
# holds `build` and the .build/sim guard; the run holds the simulator's lock (`sim-phone`,
# `sim-pad`) and the guard, not `build`, so another agent can compile while these tests run.
set -u
self=${0:A}
cd "$(dirname "$0")/.."
. tools/config.sh || exit 1

device="${1:-phone}"; [ $# -gt 0 ] && shift
scheme="${SCHEME:-Banana}"
test_config="${UI_CONFIG:-Debug}"
test_target="${UI_TEST_TARGET:-BananaUITests}"
physical="${PHYSICAL_DEVICE:-}"
case "$device" in
  phone) udid=$BANANA_SIM_PHONE;;
  pad)   udid=$BANANA_SIM_PAD;;
  *) echo "usage: $0 [phone|pad] [timing | Class[/test] ...]"; exit 1;;
esac
# An existing simulator can be selected for runtime comparisons without creating one.
udid="${SIMULATOR_UDID:-$udid}"
if [ -n "$physical" ]; then
  # Physical integration tests are confined to Beta. Never erase or uninstall hardware.
  [ "$scheme" = BananaPi ] && [ "$test_config" = PiDevelopment ] && [ "$test_target" = BananaAgentUITests ] || { echo "Physical UI tests require isolated BananaPi / PiDevelopment / BananaAgentUITests"; exit 1; }
  udid="$physical"
fi

timing=(${(f)"$(grep -hoE 'func test[A-Za-z0-9]*(Performance|Sustained|Responsive|DoesNotChain|RepeatedPagingPreservesExactTimePosition|AdjacentPageUsesCacheThenBackfillsWithoutJumping)[A-Za-z0-9]*' BananaUITests/VerifyTimelineUITest.swift | sed 's/func //')"})
workers="${WORKERS:-1}"
packages=()
# Optional local dependency cache for clean/offline source-release checks.
# Normal development keeps Xcode's default resolution behavior.
if [ -n "${SOURCE_PACKAGES_DIR:-}" ]; then
  packages=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)
fi
[ -n "$physical" ] && workers=1
only=(); skip=()
if [ "${1:-}" = timing ]; then
  workers=1
  for t in $timing; do only+=(-only-testing:$test_target/VerifyTimelineUITest/$t); done
elif [ $# -gt 0 ]; then
  for t in "$@"; do only+=(-only-testing:$test_target/$t); done
else
  only=(-only-testing:$test_target)
  for t in $timing; do skip+=(-skip-testing:$test_target/VerifyTimelineUITest/$t); done
fi

free_gb=$(( ($(vm_stat | awk '/Pages free|Pages inactive|Pages speculative/ {gsub("\\.",""); n+=$NF} END {print n}') * $(sysctl -n hw.pagesize)) / 1073741824 ))
if [ "$free_gb" -lt $(( workers * 4 )) ]; then
  echo "note: about ${free_gb} GB of memory is free; $workers simulators want $(( workers * 4 )). Expect timeouts, or free some memory first."
fi

log="${LOG:-.build/ui-tests-$device.log}"; mkdir -p .build
platform_key=simulator
[ -n "$physical" ] && platform_key=device
stamp=".build/sim/.ui-$scheme-$test_config-$platform_key"
if [ -z "${UI_TESTS_RUN:-}" ] && { [ ! -f "$stamp" ] || [ project.yml -nt "$stamp" ] ||
   [ -n "$(find Banana BananaUITests Shared -type f -newer "$stamp" 2>/dev/null | head -1)" ]; }; then
  echo "building…"
  # Apple-silicon simulators only: a generic simulator destination otherwise compiles every file a
  # second time for x86_64 (175-188 s clean against 89-100 s, 8 Nov 2026).
  build_destination='generic/platform=iOS Simulator'
  arch=(ARCHS=arm64)
  [ -n "$physical" ] && { build_destination="platform=iOS,id=$udid"; arch=(); }
  banana_xcode build-for-testing -project Banana.xcodeproj -scheme "$scheme" -configuration "$test_config" -destination "$build_destination" \
    -allowProvisioningUpdates ONLY_ACTIVE_ARCH=YES "${arch[@]}" -derivedDataPath .build/sim "${packages[@]}" > .build/ui-tests-build.log 2>&1 || { grep -E ' error: ' .build/ui-tests-build.log | head; echo "build failed: .build/ui-tests-build.log"; exit 1; }
  touch "$stamp"
fi

# The run: the simulator's lock and the .build/sim guard, held from boot to shutdown mark.
sim_lock="sim-$device"
[ -n "$physical" ] && sim_lock="device-$udid"
if [[ ":${BANANA_LOCKS_HELD:-}:" != *":$sim_lock:"* ]]; then
  # The run never builds (UI_TESTS_RUN): waiting for `build` while holding a simulator could
  # deadlock against a caller that holds `build` and waits for that simulator.
  UI_TESTS_RUN=1 exec tools/agents/xcode-lock.sh -l "$sim_lock" -d .build/sim zsh "$self" "$device" "$@"
fi

if [ -z "$physical" ]; then
  if [ -n "${FRESH:-}" ]; then
    xcrun simctl shutdown "$udid" 2>/dev/null
    xcrun simctl erase "$udid"
  fi
  # Boot once and keep it; a clean slate comes from removing what earlier runs left.
  xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1
  for app in ${(f)"$(xcrun simctl listapps "$udid" 2>/dev/null | plutil -convert json -o - - 2>/dev/null |
      python3 -c 'import json,sys; [print(k) for k,v in json.load(sys.stdin).items() if v.get("ApplicationType")=="User"]' 2>/dev/null)"}; do
    xcrun simctl privacy "$udid" reset all "$app" 2>/dev/null
    xcrun simctl uninstall "$udid" "$app" 2>/dev/null
  done
  xcrun simctl keychain "$udid" reset 2>/dev/null
fi
parallel=(-parallel-testing-enabled NO)
[ "$workers" -gt 1 ] && parallel=(-parallel-testing-enabled YES -parallel-testing-worker-count "$workers")
started=$(date +%s)
# Explicit results live outside Xcode's auto-pruned test-log store. Another test invocation can
# prune an in-progress bundle there; always read this run's own bundle, never the newest one.
mkdir -p .build/ui-results
result="$PWD/.build/ui-results/${device}-$(date +%Y%m%d-%H%M%S).xcresult"
test_destination="platform=iOS Simulator,id=$udid"
[ -n "$physical" ] && test_destination="platform=iOS,id=$udid"
xcodebuild test-without-building -collect-test-diagnostics never -project Banana.xcodeproj -scheme "$scheme" -configuration "$test_config" \
  -destination "$test_destination" -derivedDataPath .build/sim "${packages[@]}" -resultBundlePath "$result" "${only[@]}" "${skip[@]}" "${parallel[@]}" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 150 -maximum-test-execution-time-allowance 300 \
  > "$log" 2>&1 &
runner=$!
hard_limit="${UI_HARD_TIMEOUT:-300}"
case_started=$started
last_case=""
watchdog_failed=0
# A completion banner can precede result-bundle finalization. Give Xcode time to flush it.
finished_at=0
while kill -0 $runner 2>/dev/null; do
  if LC_ALL=C grep -aqE '\*\* TEST (SUCCEEDED|FAILED|EXECUTE FAILED) \*\*|Testing failed:' "$log"; then
    [ "$finished_at" -ne 0 ] || finished_at=$(date +%s)
    if [ $(( $(date +%s) - finished_at )) -gt 60 ]; then
      echo "FAILED: Xcode did not exit after result finalization grace period" | tee -a "$log"
      watchdog_failed=1
      kill $runner 2>/dev/null
      break
    fi
  fi
  latest_case=$(LC_ALL=C grep -a 'Test Case .*started\.' "$log" | tail -1)
  if [ "$latest_case" != "$last_case" ]; then
    last_case="$latest_case"
    case_started=$(date +%s)
  fi
  # XCTest's own allowance does not bound a hung event-synthesis operation.
  # Also bound runner startup, before the first case has begun.
  # Parallel runners interleave case output; only a serial log identifies which
  # individual case is active. Keep XCTest's own limits for parallel runs.
  if [ "$finished_at" -eq 0 ] && [ "$workers" -eq 1 ] && [ $(( $(date +%s) - case_started )) -gt "$hard_limit" ]; then
    echo "FAILED: UI runner exceeded ${hard_limit}s: ${last_case:-runner startup}" | tee -a "$log"
    watchdog_failed=1
    kill $runner 2>/dev/null
    sleep 2
    kill -KILL $runner 2>/dev/null
    break
  fi
  sleep 2
done
if [ -z "$physical" ]; then
  [ "$workers" -gt 1 ] && xcrun simctl --set testing shutdown all 2>/dev/null
  # Shut the simulator down after 30 minutes with no further run (a later run moves the mark).
  mark="${TMPDIR:-/tmp}/banana-ui-sim-$udid"; date +%s > "$mark"; stamp_now=$(cat "$mark")
  # The check and the shutdown hold the simulator's lock, so they never land inside another run.
  ( sleep "${UI_IDLE_SHUTDOWN:-1800}"
    env -u BANANA_LOCKS_HELD tools/agents/xcode-lock.sh -l "$sim_lock" zsh -c \
      '[ "$(cat "$1" 2>/dev/null)" = "$2" ] && ! pgrep -f "xcodebuild.*$3" > /dev/null && xcrun simctl shutdown "$3"' \
      _ "$mark" "$stamp_now" "$udid" 2>/dev/null ) > /dev/null 2>&1 &!
fi

# What failed and why, from the result bundle (a parallel run's log has no reasons in it).
xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for f in d.get("testFailures", []):
    print("FAILED", f.get("targetName", ""), f.get("testIdentifierString") or f.get("testName"), "|", " ".join(f.get("failureText", "").split())[:300])
print("%s: %s passed, %s failed, %s skipped" % (sys.argv[1], d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))
sys.exit(0 if d.get("failedTests") == 0 and d.get("passedTests", 0) > 0 else 1)' "$device"
ok=$?
[ "$watchdog_failed" -eq 1 ] && ok=1
echo "took $(( ($(date +%s) - started) / 60 )) min $(( ($(date +%s) - started) % 60 )) s  (log: $log, results: $result)"
exit $ok
