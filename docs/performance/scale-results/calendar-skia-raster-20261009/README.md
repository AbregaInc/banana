# Skia calendar raster comparison — October 9, 2026

**Experimental candidate only. No adoption or performance acceptance.** Skia
shows lower repeated-raster timings, but all 864 tile comparisons across the two
matrices fail the existing one-channel-value pixel tolerance. Very dense narrow
lanes visibly render darker. Neither matrix is fully free of sampled competing
developer work. No app rendering or performance baseline changed.

## Controlled workload and measurement

Pinned Skia `9f2a9afc0c4ec8c7a596d23981c57764aaed882b`, optimized native arm64,
Ganesh Metal, on Apple M1 Max. Same varied-v1 fixtures, seeds 20261009/20261010,
365 retained days, 12 calendars, densities 1/100/300 events/day; three fresh
process trials each. Existing five-day week geometry supplies identical event
rectangles/titles/colors. Four 256-point tiles use 393pt/3x and 1366pt/2x widths.
These are Mac GPU runs at those dimensions, not iPhone/iPad measurements.

Core Graphics uses unchanged `RasterPage`/`PreparedText`. Skia uses Core Text
line/run shaping, native fallback fonts and copied glyph positions, then Skia
text blobs and Metal drawing. No downsampling, title removal or event truncation.
Both regenerate raster outputs; warm reraster is not reuse of completed tiles.
Skia completion includes preparation, submission and a serial GPU wait, on this
offscreen CLI only. Encode time includes host scheduling, and may include internal
driver work; it is not exclusive CPU execution or a GPU timestamp. JSON setup,
reference readback, pixel comparison and PNG output are outside both raster timings.

The first width is process-cold; the second shares warmed Core Text/OS shader state.
Candidate order alternates across trials/seeds. GPU eviction releases prior
surfaces and calls `freeGpuResources`; Core Graphics releases prior images.
Neither clears system font/shader caches or represents actual OS memory pressure.
The 32 MiB Skia cache limit is experimental; its maximum measured usage was
31.98 MiB. Combined-process peak RSS reached 119.58 MiB in the first matrix and
118.39 MiB in the follow-up, including both engines, fixtures and pixel oracles.
These numbers cannot assign per-candidate RSS or define a device memory budget.

## Timing evidence, including interference

The initial unmonitored development run is retained separately: at 100/day the
first Skia draw reached **207.93 ms**. It must not be replaced by later warm shader
results. Its source differs only by the subsequently added event-count check;
both binaries remain local and are hashed in [identity](identity.json).

The first full matrix sampled an overlapping Xcode build in **18/18** processes.
After it ended, a full follow-up encountered renewed developer activity in
**11/18** processes. Keep all samples, including the seven uncontended follow-up
processes; they do not form a complete clean matrix. No further retries were used
to select a passing run.

Below: follow-up median / maximum milliseconds, six samples per cell. These are
**provisional component observations under mixed contention**, not verified wins.

| Width | Events/day | State | Core Graphics | Skia completion |
|---|---:|---|---:|---:|
| 393 | 1 | Warm reraster | 5.91 / 18.60 | 1.72 / 3.75 |
| 1366 | 1 | Warm reraster | 9.10 / 12.91 | 1.83 / 2.31 |
| 393 | 100 | First raster | 54.33 / 69.27 | 38.54 / 42.86 |
| 393 | 100 | Warm reraster | 50.31 / 55.50 | 25.13 / 31.28 |
| 393 | 100 | Eviction reraster | 47.67 / 55.13 | 25.65 / 30.51 |
| 1366 | 100 | First raster | 54.63 / 56.75 | 31.67 / 33.83 |
| 1366 | 100 | Warm reraster | 55.39 / 61.32 | 27.89 / 41.05 |
| 1366 | 100 | Eviction reraster | 56.12 / 72.02 | 27.09 / 34.88 |
| 393 | 300 | Warm reraster | 130.75 / 138.57 | 69.29 / 88.67 |
| 1366 | 300 | Warm reraster | 141.11 / 154.07 | 68.00 / 74.45 |

The original contended matrix includes Skia completion outliers of **210.90 ms**
and Core Graphics **415.48 ms**. They remain failures, not discarded noise.
At 100/day follow-up warm Skia encode medians were 23.47/25.31 ms, accounting for
most of the 25.13/27.89 ms completion times. This motivates profiling and bounded
reuse of prepared drawing work, not an assumption that a faster GPU alone solves it.
No synchronous raster job at those densities belongs on the input path.

## Correctness and retained artifacts

Both matrices completed all 18 processes and 108 paired phase samples each.
Every tile's Core Graphics event-ID set matches the fixture, and Skia's submitted
event count matches. Geometry/font/glyph inputs are shared, but **this does not
prove pixel or glyph-output parity**. All 432 comparisons in each matrix exceed
tolerance. First-matrix mean absolute channel differences range 0.135–10.306;
1.78–68.49% of pixels differ by more than one channel value. Mismatches are
especially substantial for thin dense lanes and must not be dismissed as harmless
antialiasing without diagnosis. Both runner invocations exit 1.

Inspected image pairs: [sparse CG](1-cg-1366-2.png) / [sparse Skia](1-skia-1366-2.png),
[100/day CG](100-cg-1366-1.png) / [100/day Skia](100-skia-1366-1.png), and
[dense CG](300-cg-393-2.png) / [dense Skia](300-skia-393-2.png).

[Original aggregate](analysis-contended.json), [follow-up aggregate](analysis-followup.json),
raw reports/host logs under `matrix/` and `matrix-followup/`, and
[48 passing harness tests](harness-tests.log) and
[30 passing performance-policy tests](performance-policy-tests.log) are retained. Full geometry and all
PNG pairs remain under `.build/calendar-skia-raster-20261009/`; all failures and
binaries are preserved. The linked [reproduction instructions](../../../../tools/calendar-library-benchmark/SkiaTests/README.md)
also describe timing boundaries and cache semantics.

Next: diagnose compositing/coverage differences against native output, then
measure bounded reuse of prepared text/drawing commands with an explicit ablation.
A clean full matrix, real presentation/input timing, accessibility and physical
iPhone/iPad checks remain required. Full-app component/UI suites were not rerun
for this isolated, nonshipping prototype. No baseline reduction is proposed.
