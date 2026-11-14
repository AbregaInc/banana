#!/bin/zsh
# Prepare only the selected Simulator, under its existing lock, then run an optional command.
# tools/simulator-run.sh phone slim private/run -- xcodebuild test-without-building ...
set -eu
cd "${0:A:h}/.."
. tools/config.sh
family=${1:?phone or pad}; mode=${2:?slim or stock}; evidence=${3:?new evidence directory}; shift 3
case "$family" in
  phone) udid=${SIMULATOR_UDID:-$BANANA_SIM_PHONE} ;;
  pad) udid=${SIMULATOR_UDID:-$BANANA_SIM_PAD} ;;
  *) echo 'Expected phone or pad' >&2; exit 2 ;;
esac
case "$mode" in slim|stock) ;; *) echo 'Expected slim or stock' >&2; exit 2 ;; esac
# Re-enter under the same named locks as UI tests. Never change another run's simulator.
if [[ ":${BANANA_LOCKS_HELD:-}:" != *":sim-$family:"* ]]; then
  exec tools/agents/xcode-lock.sh -l "sim-$family" -d .build/sim "$0" "$family" "$mode" "$evidence" "$@"
fi
command -v simslim >/dev/null || { echo 'Install: brew tap mobai-app/tap && brew install mobai-app/tap/simslim' >&2; exit 2; }
version=$(simslim --version)
[[ "$version" == 'simslim 0.14.0' ]] || { echo "Expected simslim 0.14.0; found $version. Review profiles before upgrading." >&2; exit 2; }
[[ ! -e "$evidence" ]] || { echo "Evidence directory already exists: $evidence" >&2; exit 2; }
mkdir -p "$evidence"
profile="tools/simulators/$mode.json"
cp "$profile" "$evidence/profile.json"
print -r -- "$version" > "$evidence/version.txt"
print -r -- "$mode" > "$evidence/mode.txt"
# A matching booted device avoids a reboot. An offline device is configured before boot.
# Exact verification also repairs services disabled beyond this conservative profile.
if ! simslim verify "$udid" --profile "$profile" --json > "$evidence/before.json" 2> "$evidence/before.log"; then
  simslim on "$udid" --profile "$profile" > "$evidence/apply.log" 2>&1
fi
xcrun simctl bootstatus "$udid" -b > "$evidence/boot.log" 2>&1
simslim verify "$udid" --profile "$profile" --json > "$evidence/verify.json"
simslim doctor "$udid" --requires push,storekit,universal-links,spotlight,files-recents,siri,icloud,keychain-sync,contacts,calendar,reminders,mail,photos,health,widgets --json > "$evidence/doctor.json"
simslim status "$udid" --json > "$evidence/status.json"
[[ ${1:-} != -- ]] || shift
if (( $# )); then exec "$@"; fi
