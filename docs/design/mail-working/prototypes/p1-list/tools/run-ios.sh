#!/bin/zsh
# usage: run-ios.sh <host> <variant> <scenario> <run>   -> results/ios/<host>-<variant>-<scenario>-r<run>.json
# Launches on the "Mail iPhone" simulator only, waits for the app to write its result, copies it out.
cd "$(dirname "$0")/.."
UDID=E5232BE0-8F82-4E85-A03B-5CA7160571E2
BID=com.boris.banana.proto.p1list
host=$1; variant=$2; scenario=$3; run=$4
mkdir -p results/ios
# Wait (up to 3 minutes) for the load average to fall under 12; if it does not, measure anyway: the load is in the file.
# Positional scenarios (prepend, rebuild, slide) do not depend on the load; the timing ones do.
waits=12; [[ $scenario == prepend || $scenario == rebuild || $scenario == slide ]] && waits=0
# If the load stayed high through a full wait in the last 30 minutes, do not wait again: record it and go.
[[ -n $(find results/.loud -mmin -30 2>/dev/null) ]] && waits=0
for i in $(seq 1 $waits); do
  load1=$(sysctl -n vm.loadavg | awk '{print int($2)}')
  (( load1 <= 12 )) && break
  sleep 15
  (( i == waits )) && touch results/.loud
done
DATA=$(xcrun simctl get_app_container $UDID $BID data)
vl=$variant; [[ $host == native ]] && vl=-; F="$host-$vl-$scenario-r$run.json"
rm -f "$DATA/Documents/p1-results/$F"
up="$(uptime | sed 's/^.*load averages*: *//')"
xb="$(pgrep -x xcodebuild | wc -l | tr -d ' ')"
xcrun simctl launch --terminate-running-process $UDID $BID --host $host --variant $variant --scenario $scenario --run $run --uptime "$up" --xcodebuilds $xb >/dev/null
limit=200; [[ $scenario == heldkey ]] && limit=260
for i in $(seq 1 $limit); do
  [[ -f "$DATA/Documents/p1-results/$F" ]] && break
  sleep 1
done
if [[ -f "$DATA/Documents/p1-results/$F" ]]; then
  cp "$DATA/Documents/p1-results/$F" results/ios/$F
  python3 -c "
import json,sys
d=json.load(open('results/ios/$F')); s=d['summary']
print('[load $up xb=$xb] host=%s/%s %s run=%s pass=%s deciding=%s' % (d['host'],d['variant'],d['scenario'],d['run'],d['pass'],s.get('decidingNumber')))"
else
  echo "[load $up xb=$xb] TIMEOUT $F"
fi
xcrun simctl terminate $UDID $BID >/dev/null 2>&1
