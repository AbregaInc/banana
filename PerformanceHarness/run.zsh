#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
build_dir=${TMPDIR:-/tmp}/banana-performance-harness
mkdir -p "$build_dir"

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  print "usage: zsh PerformanceHarness/run.zsh [artwork|workout|podcasts|wake|sync] ..."
  exit 0
fi
for selection in "$@"; do
  case "$selection" in
    artwork|workout|podcasts|wake|sync) ;;
    *)
      print -u2 "unknown comparison: $selection"
      exit 64
      ;;
  esac
done

xcrun swiftc \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  "$root/Shared/FitnessModels.swift" \
  "$root/Banana/Model/Podcast.swift" \
  "$root/PerformanceHarness/PerformanceComparison.swift" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ImageIO \
  -o "$build_dir/banana-performance-comparison"

"$build_dir/banana-performance-comparison" "$@"
