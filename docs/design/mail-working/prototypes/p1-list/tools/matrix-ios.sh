#!/bin/zsh
# The iPhone Simulator matrix: 3 runs of every scenario on every host (SwiftUI hosts in the variants the
# prepend/rebuild/slide sweep singled out). About 50 minutes on a quiet machine. Results: results/ios/*.json
# Skips a run whose result file exists, so it can be re-run to fill gaps. Positional scenarios first (they do
# not depend on the load), then the timing ones, which wait for the load average to fall under 12.
cd "$(dirname "$0")/.."
run_set() {
  for run in 1 2 3; do
    for sc in "$@"; do
      for hv in native:- list:reader lazy:positionY lazy:id; do
        h=${hv%%:*}; v=${hv##*:}; vl=$v; [[ $h == native ]] && vl=-
        [[ -f results/ios/$h-$vl-$sc-r$run.json ]] && continue
        tools/run-ios.sh $h $v $sc $run
      done
    done
  done
}
run_set prepend rebuild slide
run_set heldkey-still heldkey idle
echo MATRIX DONE
