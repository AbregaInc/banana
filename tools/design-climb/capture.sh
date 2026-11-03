#!/bin/zsh
# Photograph every Pi workspace state on the repo's simulators, for the design climb.
#
#   tools/design-climb/capture.sh <label> [phone|pad|both]     # default both
#
# Pictures land in design-climb/runs/<label>/<device>-<NN-state>.png (gitignored). The walk is
# PiDesignTourUITest: fixture model, fixed words, so two runs differ only where the UI did.
# Builds .build/sim when sources are newer (tools/ui-tests.sh), one simulator at a time.
set -u
cd "$(dirname "$0")/../.."
label="${1:?usage: $0 <label> [phone|pad|both]}"
which="${2:-both}"
out="$PWD/design-climb/runs/$label"
mkdir -p "$out"
devices=(phone pad); [ "$which" != both ] && devices=("$which")
ok=0
for d in $devices; do
  rm -f "$out/$d-"*.png(N)
  TEST_RUNNER_DESIGN_SHOTS="$out" SCHEME=BananaPi UI_CONFIG=PiDevelopment UI_TEST_TARGET=BananaAgentUITests \
    WORKERS=1 BUILD_JOBS="${BUILD_JOBS:-4}" LOG=".build/design-capture-$d.log" \
    tools/ui-tests.sh "$d" PiDesignTourUITest || ok=1
  echo "$d: $(ls "$out/$d-"*.png(N) 2>/dev/null | wc -l | tr -d ' ') pictures"
done
echo "$out"
exit $ok
