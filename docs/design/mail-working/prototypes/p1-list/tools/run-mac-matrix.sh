#!/bin/zsh
# DO NOT RUN WITHOUT THE OWNER'S GO. Runs the whole Mac matrix once: 3 runs of every host x scenario,
# then one run of every variant of the two SwiftUI hosts for prepend / rebuild / slide.
#
#   tools/build-mac.sh && tools/run-mac-matrix.sh
#
# Takes about 70 minutes with the owner's screen free (4 host variants x 3 runs x ~4 min of scenarios, plus a
# variant sweep). The panel is click-through, never key, bottom-right of the main screen, 380 x 520 pt;
# `MAC_WINDOW=x,y,w,h` moves it. It must stay uncovered while it runs (a covered window gets no
# display-link callbacks). Results land in results/mac/*.json; summarise with tools/aggregate.py mac --md.
cd "$(dirname "$0")/.."
for run in 1 2 3; do
  for sc in prepend rebuild slide heldkey-still heldkey idle; do
    tools/run-mac.sh native - $sc $run
    tools/run-mac.sh list reader $sc $run
    tools/run-mac.sh lazy positionY $sc $run
    tools/run-mac.sh lazy id $sc $run
  done
done
for v in positionY positionID reader readerNow readerAsync none anchor id idBox; do
  for sc in prepend rebuild slide; do
    tools/run-mac.sh list $v $sc 1
    tools/run-mac.sh lazy $v $sc 1
  done
done
