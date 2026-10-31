# Skia color/path fixes and command reuse — October 9, 2026

**Command reuse is promising, but this candidate still fails acceptance.** At
100 events/day, warm four-tile raster-job medians dropped from 30–34 ms to
5.4–8.2 ms. Tails exceed 8.3 ms; cold/eviction work remains too slow at 300/day.
Native pixel parity still fails. The matrix has sampled host contention in 44/72
processes, so these timings are provisional. Nothing is adopted into the app and
no baseline is changed.

## What changed, and what each comparison isolates

The same pinned Skia engine, varied fixtures, two seeds, 365 retained days,
12 calendars, three densities (1/100/300), five-day layout and four 256-point
tiles remain. Both widths, all cache states and three fresh trials are retained.
Four policies run in alternating order, totaling 72 processes and 432 paired
Core Graphics/Skia phase samples. Coverage is complete with no invalid reports.

1. **Unmanaged → managed colors.** The original adapter exported raw components
   while discarding their source color spaces. `CGColor(red:green:blue:alpha:)`
   uses Generic RGB here, and the reference bitmap uses Device RGB. Generic Gray
   needs conversion too. The adapter now uses Core Graphics' conversion before
   exporting components. The isolated native color check passes all 13 palette/
   grid swatches within one channel value; the old unmanaged calculation fails
   all 13. This fixes an adapter bug, not an upstream Skia color defect.
2. **Managed rounded rectangles → Core Graphics cubic paths.** On this workload,
   Skia's thin/tall rounded-rectangle primitive yields substantially darker narrow
   lanes than the native reference. Feeding Core Graphics-generated cubic paths
   removes most of that difference. This is a measured alternative, not proof of
   the internal cause. It increases drawing cost and worsens some wider-case edges.
3. **Direct paths → recorded paths.** Skia's built-in `SkPictureRecorder` retains
   immutable drawing commands and text blobs, avoiding repeated shaping and command
   construction on warm redraw. The first draw still records and plays back;
   eviction releases pictures and GPU resources, then rebuilds. No events, labels
   or fixture days are omitted.

The adapter retains at most four pictures per immutable snapshot and checks an
8 MiB **estimated command-size** guard using `SkPicture::approximateBytesUsed`.
Upstream explicitly excludes large referenced objects from that estimate. This
is not a total memory ceiling. Highest recorded estimate was 793,100 bytes;
native font, glyph/driver caches and actual RSS remain separate. New snapshots
create a new probe, releasing the previous probe's pictures at scope exit.
Mutable live-sync invalidation, cancellation and UI integration are not implemented.

## Timing and memory evidence

Median / maximum ms below; six samples per cell, including contended runs.
These are serial offscreen raster jobs, **not frames or input-to-visible timing**.

| Width | Events/day | State | Direct cubic paths | Recorded commands |
|---|---:|---|---:|---:|
| 393 | 100 | First raster | 56.33 / 85.91 | 44.98 / 63.54 |
| 393 | 100 | Warm | 30.49 / 33.99 | 5.40 / 13.20 |
| 393 | 100 | Eviction | 31.06 / 38.82 | 35.72 / 55.48 |
| 1366 | 100 | First raster | 39.42 / 71.65 | 46.04 / 68.27 |
| 1366 | 100 | Warm | 33.88 / 48.83 | 8.20 / 9.45 |
| 1366 | 100 | Eviction | 36.22 / 48.17 | 35.45 / 53.70 |
| 393 | 300 | Warm | 96.80 / 214.90 | 12.04 / 13.72 |
| 1366 | 300 | Warm | 90.57 / 170.57 | 14.30 / 22.11 |
| 393 | 300 | Eviction | 97.15 / 170.01 | 107.27 / 118.80 |
| 1366 | 300 | Eviction | 103.29 / 122.82 | 130.96 / 185.64 |

Recorded-command warm encode medians at 100/day were 0.78/0.98 ms, versus
26.38/26.11 ms without recording. Completion includes GPU submission and waiting;
these data do not separately identify GPU execution versus driver scheduling.
The warm benefit does not excuse cold/rebuild regressions. The matrix's recorded
first-raster maximum is 229.41 ms; earlier development checks reached 302.05 ms
for recording and 410.70 ms for the cubic path. All remain retained locally.
They cannot be replaced by later process runs with warmer system shader caches.

Combined-process RSS median/max: direct paths 148.92/166.48 MiB, recorded commands
150.17/170.17 MiB. Both include fixtures, native reference tiles and retained
first-phase pixel buffers. Do not compare directly with the previous report's
RSS: this oracle now retains first-phase pixels to check phase stability.
The extra referenced-picture memory is not fully described by estimated bytes.

No clean full matrix was obtained. The 28 processes without sampled competing
developer work do not substitute for a complete clean result. Host monitoring
only samples developer processes; it does not exclude other CPU/GPU contention.

## Fidelity and cache correctness

At 300/day, median mean-absolute channel differences versus native output were:

| Policy | 393pt/3x | 1366pt/2x |
|---|---:|---:|
| Original unmanaged | 8.281 | 1.053 |
| Converted colors | 6.535 | 0.098 |
| Native cubic paths | 0.549 | 0.296 |
| Recorded cubic paths | 0.549 | 0.296 |

The cubic path greatly improves the densest narrow case, but its wider-case
error is worse than the converted rounded-rectangle path. Maximum native pixel
differences still reach 143/163; all 72 cases fail native parity. No tolerance
was relaxed. The original renderer remains the reference.

All **144 first-render picture/direct PNG pairs in the timing matrix are exactly
identical**. A separate lifecycle oracle tests direct drawing, retained pictures,
and recording with a zero-byte cache at both seeds and all three densities:
**286/288 exact-image comparisons pass; the overall oracle fails (exit 1).**
Two first-render comparisons at seed 20261009 / 300 events/day differ: one has
67 changed pixels with maximum channel difference 1; the other has 28 changed
pixels with maximum difference 2. Every warm, eviction and zero-budget comparison
matches its same-stage control in this run. The zero-budget path retains no
pictures and records all four tiles again. These results do not establish
deterministic rendering across future runs.

Cold-to-warm differences of up to 3 also occur with direct cubic paths, independent
of picture retention. They remain a separate renderer stability failure under the
existing one-value tolerance. The cache oracle does not waive native parity.

## Reproduction and retained evidence

[Commands and policy semantics](../../../../tools/calendar-library-benchmark/SkiaTests/README.md),
[aggregate with every tail](analysis.json), [matrix status](summary.json),
[source hashes](environment.json), [binary identity](identity.json),
[lifecycle oracle](oracle-summary.json), [its two differences](oracle-differences.json),
[native color check](color-check.json), [49 passing harness tests](final-harness-tests.log),
and [30 passing policy tests](policy-tests.log) are retained. Raw phase reports,
time/RSS logs and host records are under `raw/`. Selected image stages are
[unmanaged](unmanaged-393-2.png), [converted](managed-393-2.png),
[cubic paths](paths-393-2.png), [recorded](pictures-393-2.png), and
[native reference](reference-393-2.png).

All geometry, images and diagnostics remain under
`.build/calendar-skia-picture-fixed-20261009/`, `.build/calendar-skia-oracle-20261009/`,
`.build/calendar-skia-color-20261009/` and `.build/calendar-skia-path-20261009/`.
An interrupted development build (source edited during compilation) remains in
`.build/calendar-skia-picture-20261009/swift-build.log`; its fresh rebuild passed.
No Simulator or visible UI was launched for this experiment. Full app regression
and UI suites were not rerun for the isolated nonshipping adapter.

The next useful work is to resolve native edge/text fidelity and measure actual
presentation/GPU scheduling with bounded prepared commands. Cold preparation,
live-update invalidation, native accessibility and physical-device input/display
evidence remain open. No performance baseline reduction is proposed yet.
