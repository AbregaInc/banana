#!/bin/zsh
# The data platform end to end (docs/design/DATA-PLATFORM.md §12): the real service on Node over
# plain HTTP, a fresh database and space folder, one seeded account with an iPhone, an iPad and a
# Mac, and BananaTests/SpaceSyncHTTPTests running real engines and HTTPSyncTransport against it on
# the phone simulator (which reaches this Mac's 127.0.0.1).
#
#   tools/e2e-sync.sh                  # everything in SpaceSyncHTTPTests
#   tools/e2e-sync.sh testABlob…       # one test (or several)
#   E2E_DIR=/some/folder tools/e2e-sync.sh
#
# The service's folder (database, spaces, blobs, its log, the seed) is made fresh every run, under
# E2E_DIR (default: a folder in $TMPDIR). Builds into .build/sim, shared with the other scripts, and
# waits its turn for xcodegen/xcodebuild on $XCODEBUILD_LOCK. No Google, no APNs: the sync pushes
# fail (no key) and are logged, which must not get in sync's way.
set -u
cd "$(dirname "$0")/.."
. tools/config.sh

udid=6DFFC0F9-AA09-41C8-B868-FB0D9CC28255   # "Banana tests iPhone" (AGENTS.md)
dir="${E2E_DIR:-${TMPDIR:-/tmp}/banana-e2e}"
lock="${XCODEBUILD_LOCK:-${TMPDIR:-/tmp}/banana-xcodebuild.lock}"
log=.build/e2e-sync.log
mkdir -p .build

rm -rf "$dir" && mkdir -p "$dir" || exit 1
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

(cd Service && DATABASE_PATH="$dir/banana.db" PORT=$port node tools/e2e-seed.mjs) > "$dir/seed.json" || { echo "seeding failed"; exit 1; }

token_key=$(node -e 'console.log(Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64"))')
TOKEN_KEY="$token_key" DATABASE_PATH="$dir/banana.db" DATA_DIR="$dir/data" PORT=$port \
  node Service/src/node.js > "$dir/service.log" 2>&1 &
service=$!

finish() {
  # zsh puts the background job in a subshell, so $! may not be node: stop what holds the port.
  kill $service $(lsof -t -iTCP:$port -sTCP:LISTEN 2>/dev/null) 2>/dev/null
  wait $service 2>/dev/null
  xcrun simctl shutdown "$udid" 2>/dev/null
}
trap finish EXIT INT TERM

for _ in {1..50}; do
  curl -sf "http://127.0.0.1:$port/v1/health" > /dev/null && break
  sleep 0.2
done
curl -sf "http://127.0.0.1:$port/v1/health" > /dev/null || { echo "the service didn't start:"; tail -20 "$dir/service.log"; exit 1; }
echo "service on :$port (pid $service), seed $dir/seed.json"

only=()
if [ $# -gt 0 ]; then
  for t in "$@"; do only+=(-only-testing:BananaTests/SpaceSyncHTTPTests/$t); done
else
  only=(-only-testing:BananaTests/SpaceSyncHTTPTests)
fi

lockf -t 7200 "$lock" xcodegen generate --quiet || { echo "xcodegen failed"; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null
# TEST_RUNNER_<NAME> reaches the test process as <NAME>.
TEST_RUNNER_BANANA_E2E="$dir/seed.json" lockf -t 7200 "$lock" \
  xcodebuild test -project Banana.xcodeproj -scheme Banana -destination "id=$udid" -derivedDataPath .build/sim \
  -parallel-testing-enabled NO "${only[@]}" > "$log" 2>&1
rc=$?

grep -E "Test Case .*(passed|failed|skipped)|error:|\*\* TEST|Executed [0-9]+ test" "$log" | grep -v "^ld: warning" | tail -40
if [ $rc -ne 0 ]; then
  echo "--- xcodebuild failed ($rc): $log"
  echo "--- service log, last lines ($dir/service.log):"
  tail -40 "$dir/service.log"
fi
exit $rc
