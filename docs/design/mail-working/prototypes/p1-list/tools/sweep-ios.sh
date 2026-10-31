#!/bin/zsh
# usage: sweep-ios.sh <scenario> <run> <host:variant> ...   one run of each, brief line to stdout
cd "$(dirname "$0")/.."
sc=$1; run=$2; shift 2
for hv in "$@"; do
  h=${hv%%:*}; v=${hv##*:}
  tools/run-ios.sh $h $v $sc $run >/dev/null
  vl=$v; [[ $h == native ]] && vl=-
  python3 tools/brief.py results/ios/$h-$vl-$sc-r$run.json 2>&1 | cut -c1-420
done
