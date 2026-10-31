#!/bin/zsh
# DO NOT RUN WITHOUT THE OWNER'S GO: this puts a (non-activating, click-through) panel on the main
# screen for the length of the scenario. See RESULTS.md, "Mac: to run when the owner says go".
#
# usage: run-mac.sh <host> <variant> <scenario> <run>   -> results/mac/<host>-<variant>-<scenario>-r<run>.json
# Launched with `open -g -n` so macOS does not bring it forward. Records `uptime` and the number of
# running xcodebuild processes (pgrep -x, never -f) into the result. Waits for the load average to
# fall under 12 (up to 10 minutes) before measuring; if it never does, runs anyway and the load is in the file.
cd "$(dirname "$0")/.."
host=$1; variant=$2; scenario=$3; run=$4
APP=$PWD/build-mac/Build/Products/Release/P1List.app
OUT=$PWD/results/mac
mkdir -p $OUT
vl=$variant; [[ $host == native ]] && vl=-
F="$OUT/$host-$vl-$scenario-r$run.json"
rm -f "$F"
for i in $(seq 1 20); do
  load1=$(sysctl -n vm.loadavg | awk '{print int($2)}')
  (( load1 <= 12 )) && break
  sleep 30
done
up="$(uptime | sed 's/^.*load averages*: *//')"
xb="$(pgrep -x xcodebuild | wc -l | tr -d ' ')"
open -g -n "$APP" --args --host $host --variant $variant --scenario $scenario --run $run --out "$F" --uptime "$up" --xcodebuilds $xb ${MAC_WINDOW:+--mac-window $MAC_WINDOW}
limit=200; [[ $scenario == heldkey ]] && limit=260
for i in $(seq 1 $limit); do [[ -f "$F" ]] && break; sleep 1; done
sleep 1
if [[ -f "$F" ]]; then echo "[load $up xb=$xb] ok $F"; else echo "[load $up xb=$xb] TIMEOUT $F"; pkill -x P1List; fi
