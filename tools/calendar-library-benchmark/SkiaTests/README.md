# Isolated Skia Metal/Core Text feasibility check

Pinned upstream revision: `9f2a9afc0c4ec8c7a596d23981c57764aaed882b`.
These command-line probes target native arm64 macOS. This does not add an app
dependency or establish calendar parity, accessibility, or UI performance.
The separate [physical-device preview](../../../docs/performance/scale-results/calendar-live-metal-20261009/README.md)
adds experimental iOS Metal rendering and native scrolling with retained failures.

From a checkout of that revision, fetch its pinned tools with `python3 bin/fetch-gn`
and `python3 bin/fetch-ninja`. Copy this directory's `args.gn` into
`out/CalendarMetal/args.gn`, then run:

```sh
bin/gn gen out/CalendarMetal
third_party/ninja/ninja -C out/CalendarMetal -j 2 skia skshaper
```

From this repository, with the checkout at the retained local path:

```sh
xcrun clang++ -std=c++20 -O2 -fobjc-arc -DSK_GANESH -DSK_METAL \
  -I .build/calendar-skia-evaluation-20261009/skia \
  tools/calendar-library-benchmark/SkiaTests/smoke.mm \
  .build/calendar-skia-evaluation-20261009/skia/out/CalendarMetal/libskshaper.a \
  .build/calendar-skia-evaluation-20261009/skia/out/CalendarMetal/libskia.a \
  -framework Metal -framework Foundation -framework ApplicationServices \
  -framework CoreText -framework CoreGraphics -framework QuartzCore \
  -framework CoreVideo -framework IOKit -o .build/skia-smoke
.build/skia-smoke
```

The check draws offscreen, shapes three strings including Japanese, Arabic,
accents and emoji, then reads pixels back. Nonempty text blobs and changed pixels
are only smoke checks, not glyph correctness or a reference-image comparison.
The explicit native font manager avoids the legacy convenience overload's null
fallback manager in this revision. Keep multilingual coverage when updating Skia.

See [retained results](../../../docs/performance/scale-results/calendar-skia-feasibility-20261009/README.md).

## Calendar raster comparison

`bridge.mm` uses Skia's Metal drawing and glyph cache with the same Core Text
line/run shaping as `PreparedText`. `main.swift` supplies the existing varied
fixture and `DayGeometry` rectangles, and runs the unmodified `RasterPage` control.
Both render four 256-point tiles at 393pt/3x and 1366pt/2x. Geometry/data loading
are excluded from both raster timings. Shape/encode/GPU-completion work is included
for Skia; pixel readback, image comparison and PNG output are outside the timings.

```sh
bash tools/calendar-library-benchmark/SkiaTests/build.sh \
  .build/calendar-skia-evaluation-20261009/skia .build/NEW_SKIA_BUILD
python3 tools/calendar-library-benchmark/run-skia-raster.py \
  --binary .build/NEW_SKIA_BUILD/probe --out .build/NEW_SKIA_MATRIX
python3 tools/calendar-library-benchmark/report-skia-raster.py \
  .build/NEW_SKIA_MATRIX --out .build/NEW_SKIA_ANALYSIS.json
python3 -m unittest discover -s tools/calendar-library-benchmark -p 'test_*.py'
```

The matrix runs two fixed seeds, densities 1/100/300 and three fresh processes per
pair, alternating candidate order. Every process retains cold, warm reraster and
eviction reraster samples. These are **raster jobs**, not cached-tile scrolling.
The wide viewport runs second, so its first raster is not process-cold. Core Text
and OS shader caches are not purged. Both paths discard prior tile outputs;
Skia additionally calls `freeGpuResources` for eviction. This does not simulate
OS memory pressure or guarantee all driver caches are empty.

Every sample checks four tiles and matching event counts, and records differences
against the unchanged Core Graphics pixels. Exit 1 means pixel mismatch; even
exact pixels leave UI acceptance unmeasured (exit 2). No mismatched image becomes
a new baseline. Raw reports, PNGs, geometry, peak combined-process RSS and sampled
competing developer processes are retained. GPU-cache bytes are not process RSS.

See [calendar results and open fidelity issue](../../../docs/performance/scale-results/calendar-skia-raster-20261009/README.md).

## Color, path and recorded-command ablations

Color export now converts Generic RGB/Gray into the reference bitmap's Device RGB
space. `--legacy-unmanaged-colors` preserves the original faulty adapter as a
control. `--cg-paths` sends Core Graphics rounded-rectangle cubic paths to Skia,
instead of Skia's rounded-rectangle primitive. It improves the narrowest dense
lanes but does not establish native pixel parity and can worsen other edges.

`--reuse-pictures` uses Skia's existing `SkPictureRecorder` API, retaining at most
four immutable pictures for one immutable viewport/data snapshot. A new probe
owns each new snapshot. Eviction releases all pictures before GPU resource purge.
The 8 MiB limit uses `approximateBytesUsed`, which **excludes some referenced
objects**; it is an estimated command-storage guard, not a total memory bound.
`--picture-cache-bytes 0` exercises recording/playback without retention. Picture
hits, misses, count and estimated bytes are reported for every phase. Reuse stays
disabled by default. No shipping cache or renderer changes.

```sh
python3 tools/calendar-library-benchmark/run-skia-ablation.py \
  --binary .build/NEW_SKIA_BUILD/probe --out .build/NEW_ABLATION
python3 tools/calendar-library-benchmark/report-skia-ablation.py \
  .build/NEW_ABLATION --out .build/NEW_ABLATION_ANALYSIS.json
python3 tools/calendar-library-benchmark/run-skia-picture-check.py \
  --binary .build/NEW_SKIA_BUILD/probe --out .build/NEW_PICTURE_ORACLE
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/FixturePalette.swift \
  tools/calendar-library-benchmark/SkiaTests/color-check.swift -o .build/color-check
.build/color-check
```

The ablation uses 72 fresh processes: the unchanged two seeds, three densities,
three trials, and four policies in alternating order. Each policy changes only
one item from its predecessor: raw colors → converted colors → native cubic paths
→ recorded-command reuse. No scenario is removed. Native image differences and
cold/warm/eviction instability remain failures. The separate picture oracle compares
all stages against direct Skia output, including a zero-budget path. It writes
all phase images with `--all-phase-images`; its exact-image gate is separate from
the unchanged native tolerance. Neither oracle measures displayed UI performance.

See [retained results and failures](../../../docs/performance/scale-results/calendar-skia-pictures-20261009/README.md).
