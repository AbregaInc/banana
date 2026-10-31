#!/bin/zsh
set -e
out=.build/calendar-tiles/final-checks
swiftc -O tools/calendar-library-benchmark/Shared/Fixtures.swift tools/calendar-library-benchmark/Shared/DayGeometry.swift tools/calendar-library-benchmark/GeometryTests/main.swift -o "$out/geometry-tests"
"$out/geometry-tests" > "$out/geometry.log" 2>&1
swiftc -O tools/calendar-library-benchmark/Shared/PreparedText.swift tools/calendar-library-benchmark/TextTests/main.swift -o "$out/text-tests"
"$out/text-tests" "$out/text-components.json" > "$out/text.log" 2>&1
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift tools/calendar-library-benchmark/GridTests/main.swift -o "$out/grid-tests"
"$out/grid-tests" --mode week --density 300 --output "$out/grid-control" > "$out/grid-control.log" 2>&1
"$out/grid-tests" --mode week --density 300 --ablation split-grid --output "$out/grid-split" --reference "$out/grid-control" > "$out/grid-split.log" 2>&1
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift tools/calendar-library-benchmark/AccessibilityTests/main.swift -o "$out/accessibility-tests"
for variant in none rebuild-accessibility; do
  "$out/accessibility-tests" --mode week --density 300 --ablation $variant --output "$out/accessibility-$variant.json" > "$out/accessibility-$variant.log" 2>&1
done
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift tools/calendar-library-benchmark/RasterTests/main.swift -o "$out/raster-tests"
"$out/raster-tests" --renderer raster --output "$out/raster.json" > "$out/raster.log" 2>&1
python3 -m unittest discover -s tools/tests -v > "$out/python-gates.log" 2>&1
python3 -m unittest discover -s tools/calendar-library-benchmark -p 'test_*.py' -v > "$out/python-renderer.log" 2>&1

swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift tools/calendar-library-benchmark/TileTests/main.swift -o "$out/tile-tests"
"$out/tile-tests" --renderer tiles --mode week --density 300 --output "$out/tile-checks.json" > "$out/tile.log" 2>&1
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift tools/calendar-library-benchmark/TileTests/prefetch.swift -o "$out/tile-prefetch-tests"
"$out/tile-prefetch-tests" --mode week --density 300 --output "$out/tile-prefetch.json" > "$out/tile-prefetch.log" 2>&1
swiftc -O Banana/Model/CalendarOverflowRules.swift tools/calendar-overflow-tests/main.swift -o "$out/overflow-tests"
"$out/overflow-tests" > "$out/overflow.log" 2>&1
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" Banana/Views/CalendarHourLines.swift tools/calendar-hour-lines-tests/main.swift -o "$out/hour-line-tests"
"$out/hour-line-tests" "$out/hour-lines" > "$out/hour-lines.log" 2>&1
