#!/bin/zsh
# Run the UI tests on the repo's simulators, in parallel, with a time limit on every test.
#
#   tools/ui-tests.sh                       # phone, everything but the timing tests
#   tools/ui-tests.sh pad                   # the iPad simulator
#   tools/ui-tests.sh phone timing          # the timing tests, one at a time
#   tools/ui-tests.sh phone ScanOneItemUITest MealEditorUITest/testTheUnconfirmedRowIsAlreadyOpen
#
# WORKERS=3 tools/ui-tests.sh               # how many copies of the simulator share the work
#
# Why it is shaped this way (11 Oct 2026: a full run took 37 minutes clean and 70 with failures):
#   - Classes run side by side on copies of the simulator (Xcode makes and reuses the copies).
#     Two by default: each copy needs about 4 GB, and a Mac that is swapping makes every test
#     time out. The script says so when memory is short.
#   - Every test has a time limit, so one that hangs is stopped and the run goes on.
#   - The timing tests (scrolling speed, a quiet minute, a minute in the background) measure the
#     clock, so they run alone, one at a time, and only when asked for.
# Builds .build/sim first when the sources are newer than it.
set -u
cd "$(dirname "$0")/.."
. tools/config.sh || exit 1

device="${1:-phone}"; [ $# -gt 0 ] && shift
case "$device" in
  phone) udid=6DFFC0F9-AA09-41C8-B868-FB0D9CC28255;;
  pad)   udid=43EFC551-5368-4F79-9E52-E3DB87A72F48;;
  *) echo "usage: $0 [phone|pad] [timing | Class[/test] ...]"; exit 1;;
esac
# An existing simulator can be selected for runtime comparisons without creating one.
udid="${SIMULATOR_UDID:-$udid}"

timing=(${(f)"$(grep -hoE 'func test[A-Za-z0-9]*(Performance|Sustained|Responsive|DoesNotChain|RepeatedPagingPreservesExactTimePosition|AdjacentPageUsesCacheThenBackfillsWithoutJumping)[A-Za-z0-9]*' BananaUITests/VerifyTimelineUITest.swift | sed 's/func //')"})
workers="${WORKERS:-2}"
packages=()
# Optional local dependency cache for clean/offline source-release checks.
# Normal development keeps Xcode's default resolution behavior.
if [ -n "${SOURCE_PACKAGES_DIR:-}" ]; then
  packages=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)
fi
only=(); skip=()
if [ "${1:-}" = timing ]; then
  workers=1
  for t in $timing; do only+=(-only-testing:BananaUITests/VerifyTimelineUITest/$t); done
elif [ $# -gt 0 ]; then
  for t in "$@"; do only+=(-only-testing:BananaUITests/$t); done
else
  only=(-only-testing:BananaUITests)
  for t in $timing; do skip+=(-skip-testing:BananaUITests/VerifyTimelineUITest/$t); done
fi

free_gb=$(( ($(vm_stat | awk '/Pages free|Pages inactive|Pages speculative/ {gsub("\\.",""); n+=$NF} END {print n}') * $(sysctl -n hw.pagesize)) / 1073741824 ))
if [ "$free_gb" -lt $(( workers * 4 )) ]; then
  echo "note: about ${free_gb} GB of memory is free; $workers simulators want $(( workers * 4 )). Expect timeouts, or free some memory first."
fi

log="${LOG:-.build/ui-tests-$device.log}"; mkdir -p .build
# Only a successful UI build advances this stamp. A unit build also writes Products, so that
# directory's mtime cannot tell whether the UI runner includes the latest test sources.
stamp=.build/sim/ui-tests-built.stamp
if [ ! -f "$stamp" ] || [ project.yml -nt "$stamp" ] ||
   [ -n "$(find Banana BananaUITests Shared \( -name '*.swift' -o -name '*.json' \) -newer "$stamp" 2>/dev/null | head -1)" ]; then
  echo "building…"
  xcodebuild build-for-testing -jobs "${BUILD_JOBS:-2}" -project Banana.xcodeproj -scheme Banana -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    -derivedDataPath .build/sim "${packages[@]}" > .build/ui-tests-build.log 2>&1 || { grep -E ' error: ' .build/ui-tests-build.log | head; echo "build failed: .build/ui-tests-build.log"; exit 1; }
  touch "$stamp"
fi

xcrun simctl shutdown "$udid" 2>/dev/null
xcrun simctl erase "$udid"
parallel=(-parallel-testing-enabled NO)
[ "$workers" -gt 1 ] && parallel=(-parallel-testing-enabled YES -parallel-testing-worker-count "$workers")
started=$(date +%s)
# Explicit results live outside Xcode's auto-pruned test-log store. Another test invocation can
# prune an in-progress bundle there; always read this run's own bundle, never the newest one.
mkdir -p .build/ui-results
result="$PWD/.build/ui-results/${device}-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild test-without-building -collect-test-diagnostics never -project Banana.xcodeproj -scheme Banana \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath .build/sim "${packages[@]}" -resultBundlePath "$result" "${only[@]}" "${skip[@]}" "${parallel[@]}" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 150 -maximum-test-execution-time-allowance 300 \
  > "$log" 2>&1 &
runner=$!
# A finished run sometimes leaves xcodebuild waiting: stop it once the result is written.
while kill -0 $runner 2>/dev/null; do
  LC_ALL=C grep -aqE '\*\* TEST (SUCCEEDED|FAILED|EXECUTE FAILED) \*\*|Testing failed:' "$log" && { sleep 2; kill $runner 2>/dev/null; break; }
  sleep 2
done
xcrun simctl shutdown "$udid" 2>/dev/null
xcrun simctl --set testing shutdown all 2>/dev/null

# What failed and why, from the result bundle (a parallel run's log has no reasons in it).
xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for f in d.get("testFailures", []):
    print("FAILED", f.get("targetName", ""), f.get("testIdentifierString") or f.get("testName"), "|", " ".join(f.get("failureText", "").split())[:300])
print("%s: %s passed, %s failed, %s skipped" % (sys.argv[1], d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))
sys.exit(0 if d.get("failedTests") == 0 and d.get("passedTests", 0) > 0 else 1)' "$device"
ok=$?
echo "took $(( ($(date +%s) - started) / 60 )) min $(( ($(date +%s) - started) % 60 )) s  (log: $log, results: $result)"
exit $ok
