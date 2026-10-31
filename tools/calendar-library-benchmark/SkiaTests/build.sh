#!/bin/bash
# Existing pinned Skia checkout/build required; see README. No global install.
set -euo pipefail
skia_root=${1:?Pass the pinned Skia checkout path}
build_out=${2:?Pass a NEW output directory}
mkdir "$build_out"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -DSK_GANESH -DSK_METAL \
  -I "$skia_root" -c tools/calendar-library-benchmark/SkiaTests/bridge.mm \
  -o "$build_out/bridge.o" > "$build_out/bridge-build.log" 2>&1
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/SkiaTests/main.swift "$build_out/bridge.o" \
  "$skia_root/out/CalendarMetal/libskia.a" -lc++ \
  -framework Metal -framework Foundation -framework ApplicationServices \
  -framework CoreText -framework CoreGraphics -framework QuartzCore \
  -framework CoreVideo -framework IOKit -o "$build_out/probe" > "$build_out/swift-build.log" 2>&1
