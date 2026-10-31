# Native calendar renderer experiments — October 8, 2026

**Status: component budget failures remain; full UI acceptance is unmeasured.** This is an isolated prototype, not a replacement for the production calendar. All thresholds and existing baselines remain unchanged.

The host was shared and load varied substantially. Repeated adjacent controls help expose drift, but these are not calibrated quiet-host or physical-device acceptance results. Simulator API/layout/flush work and AppKit API/layout/display/flush work are different measurements.

## Retained runs

| Run | Requested cases | Valid measured cases | Missing/invalid cases |
| --- | ---: | ---: | --- |
| [mac-matrix-1](mac-matrix-1/summary.json) | 18 | 18 | None |
| [mac-matrix-2](mac-matrix-2/summary.json) | 26 | 26 | None |
| [mac-matrix-3](mac-matrix-3/summary.json) | 28 | 28 | None |
| [mac-matrix-4](mac-matrix-4/summary.json) | 48 | 42 | 6 unmeasured-user-interrupted |
| [mac-matrix-5](mac-matrix-5/summary.json) | 52 | 52 | None; all 52 record budget failures |
| [iphone-comparison-1](iphone-comparison-1/summary.json) | 39 | 38 | 1 failed-or-timeout |
| [iphone-comparison-2](iphone-comparison-2/summary.json) | 30 | 30 | None |
| [ipad-comparison-1](ipad-comparison-1/summary.json) | 54 | 54 | None |

Mac matrix 4 stopped at the user’s request to avoid foreground windows while they used the computer. All 42 completed cases remain; six remaining dense paired cases are explicitly unmeasured. Later Simulator runs were performed without opening/focusing Simulator. The iPhone library timeout is retained, not excluded to obtain a pass.

## Selected complete-matrix observations

These full matrices precede the final raster retention/publication fixes; targeted post-fix evidence is documented below. All times below are milliseconds of **synchronous component work**, not input-to-visible latency. Page p95 is also the maximum because the probe has 12 page samples. Scroll retains 120 samples. Each row has 365 retained days; density is events/day. “Recovery” clears presentation caches; RSS is process peak MiB, not total GPU/render-server memory.

| Platform / renderer / mode / density | Cold mount | Page p95/max | Scroll p95 | Scroll max | Recovery max | Peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [Mac canvas week 100](mac-matrix-4/04-native-week-365d-100perday-canvas-none.json) | 59.48 | 7.29 | 5.62 | 8.06 | 12.43 | 104.42 |
| [Mac canvas week 300](mac-matrix-4/05-native-week-365d-300perday-canvas-none.json) | 81.04 | 13.03 | 9.99 | 20.80 | 25.01 | 118.00 |
| [Mac raster week 100](mac-matrix-4/34-native-week-365d-100perday-raster-none.json) | 146.21 | 43.59 | 2.70 | 7.88 | 104.17 | 413.38 |
| [Mac raster week 300](mac-matrix-4/35-native-week-365d-300perday-raster-none.json) | 186.20 | 44.97 | 3.45 | 12.42 | 138.64 | 414.42 |
| [iPhone cells week 100](iphone-comparison-2/native-week-365d-100perday-bounded-cells-matrix.json) | 53.66 | 8.33 | 3.84 | 9.30 | 6.61 | 175.05 |
| [iPhone cells week 300](iphone-comparison-2/native-week-365d-300perday-bounded-cells-matrix.json) | 110.08 | 14.69 | 5.65 | 19.66 | 10.57 | 183.89 |
| [iPhone raster week 100](iphone-comparison-2/native-week-365d-100perday-bounded-raster.json) | 103.82 | 15.90 | 1.98 | 5.29 | 80.18 | 307.27 |
| [iPhone raster week 300](iphone-comparison-2/native-week-365d-300perday-bounded-raster.json) | 141.45 | 19.36 | 2.93 | 7.23 | 106.45 | 305.42 |
| [iPad cells week 100](ipad-comparison-1/native-week-365d-100perday-bounded-cells-matrix.json) | 92.19 | 41.70 | 4.51 | 10.35 | 7.85 | 216.16 |
| [iPad cells week 300](ipad-comparison-1/native-week-365d-300perday-bounded-cells-matrix.json) | 130.01 | 20.63 | 4.33 | 17.24 | 9.29 | 211.48 |
| [iPad raster week 100](ipad-comparison-1/native-week-365d-100perday-bounded-raster.json) | 103.20 | 19.85 | 1.94 | 4.38 | 86.57 | 394.17 |
| [iPad raster week 300](ipad-comparison-1/native-week-365d-300perday-bounded-raster.json) | 143.50 | 20.53 | 2.86 | 7.74 | 116.27 | 398.34 |

These selections do not hide failures in other phases or cases. Consult each summary for cold/warm/uncached/recovery/resize distributions, every over-budget sample count, and raw reports for individual samples and counters.

## What the experiments established

- Rendering strategy is platform-dependent. Reusable UIKit event views substantially reduce scrolling work versus the canvas. AppKit favors the canvas at the tested densities. This does not establish full calendar feature parity or physical-device performance.
- In-place reuse matters: iPhone comparison 1 measured week page p95 7.37 ms with reuse versus 35.78 ms without it. Its 8.81 ms scroll maximum still exceeded 8.3 ms. Mac matrix 3 measured page p95 32.90 versus 49.04 ms for the same cell comparison.
- Text preparation/cache reuse and adjacent preparation have separate ablations. Preparing only the destination viewport avoids displacing useful titles at 300/day without increasing the 4,096-entry limit; foreground title-build counters verify the mechanism.
- A smaller backing surface helps UIKit in this workload: iPhone comparison 1 measured page/scroll p95 31.60/22.58 ms versus 53.87/45.82 ms for the full surface. The Mac result was much less clear; no universal percentage gain is claimed.
- The bucket index lost to a compact active-day scan for broad viewports. Linear lane allocation won at lower densities; heap allocation won at 4,000 and 10,000 placements. The adaptive threshold and alternatives are retained with exact-placement correctness checks and all microbenchmark samples.
- Prerendered images make scrolling cheap but produce costly cold misses, recovery, resizing and first installation, with additional memory. The raster path remains an explicit experiment, not the default or a claimed solution. Native segmented samples show the first-page flush cost as well as preparation cost.
- Overscan reduces reconciliation counts; geometry cache lookup is cheaper in microbenchmarks. Whole-view latency improvements for every switch are not consistently distinguishable from noise. No-benefit and failing variants remain recorded.

## Correctness and persistent checks

- [2,088 geometry/cache checks](checks/geometry-checks-final-v2.log): interval clipping, randomized visible-ID oracle, exact heap/linear placements, viewport-prefetch equality, DST day duration, bounded LRU and invalidation.
- [28 text pixel comparisons](checks/text-checks-final-v2.log): Latin, CJK, Arabic, emoji and clipping. An initial accent-clipping failure is retained; the fixed path preserves the antialias fringe.
- [232 final raster checks](checks/raster-retention-stream.log): known pixels, asymmetric interval orientation/clipping, 1x/2x/3x sizes, worker equivalence, byte/count limits, resize keys and 200 active-image eviction trials. The earlier 27-check suite and failed retention test are also retained.
- [19 existing gate tests](checks/python-tests-final-v2.log) and [7 renderer-evidence tests](checks/report-tests-final-v2.log). CI compiles/runs the pure checks and retains microbenchmark samples.
- The [app-wide persistent component suite](app-regression-2/gate.json) completed all eight cases and failed its unchanged baseline. At 90 days, notes search reached 199.12 ms, next-podcast selection 237.98 ms and download candidates 283.36 ms. Peak RSS was 668.9 MiB; all four watched redraw probes were zero. The earlier build-blocked attempt is also retained. Production source is unchanged in this iteration; attribution of these current-app failures remains separate from the renderer experiment.

## Final raster repairs and targeted evidence

Cache eviction initially cleared the active layer’s pixels. The [before test](raster-retention-before.json) reproduces that failure; the [fixed test](raster-retention-final.json) preserves the active image through 200 evictions. Cached/speculative images are cleared, while the current image remains until replacement. Its memory is part of active presentation, outside the cache’s byte count.

The [two post-retention device probes](raster-retention-device-checks/summary.json) validated layer contents but still observed 118.69/144.66 ms page maxima on iPhone/iPad when prefetch missed. These failures remain retained. Publishing each prepared page independently is now available with `batch-raster-prefetch` as the control. The offscreen [batched](raster-prefetch-batch.json) and [individual](raster-prefetch-stream.json) five-trial probes measured first-page availability medians of 150.25 and 68.62 ms; the first observation contained two versus one prepared pages respectively. This includes 1 ms polling and does not measure visible UI response.

All [eight paired Simulator cases](raster-stream-device-checks/summary.json) had valid coverage and attached raster contents. After 250 ms settling, page p95 ranged from 13.46–22.99 ms across both strategies; they do not establish a decisive navigation benefit. Cold/recovery/resize failures persist. The offscreen checks, paired publication variants and raw sample retention are part of the persistent tooling/CI. The subsequent native matrix and foreground review are recorded below; no post-fix Mac UI acceptance is claimed.

## Evidence limits and remaining work

An earlier native CUA interaction trace recorded 123 main-thread commits, p95 2.83 ms and max 6.23 ms, but also a 107.01 ms main-run-loop busy interval with unresolved attribution. Its [summary](native-interaction-trace/summary.json) and binary identity identify that earlier implementation. It does not certify the latest renderer or input/display latency. Raw Instruments traces remain local because they contain process-environment metadata.

Latest foreground Mac visual/interaction checks resumed after the user explicitly left the computer; results follow below. iPhone/iPad results are Simulator components, not physical 120 Hz evidence. Drag/edit, recurrence expansion, all-day and local-wall-clock/DST presentation, readable dense-overlap handling, keyboard/VoiceOver parity, live data invalidation, durability, disk paging and full-app integration remain outside this renderer experiment. Fixture generation is recorded separately and the fixture store is in memory.

No baseline was automatically updated. Proposed next baseline review: after repeated quiet-host and real-device validation, preserve the selected platform renderer’s lower paging/scrolling tails in a separately reviewed reference. Do not adopt the current failing cold/resize paths as acceptable limits or transfer these renderer measurements into the production app’s component baseline.

Implementation details, per-optimization ledger and commands: [regression-testing.md](../../regression-testing.md). Source/binary identities and retained local failed diagnostics: [manifest](manifest.json).


## Resumed native verification after user left the computer

[Mac matrix 5](mac-matrix-5/summary.json) completed all **52 cases**, with valid date/event/drawing coverage. Every case recorded at least one budget violation. It includes the final raster retention/publication implementation and the formerly deferred dense paired cases. Matrix 4 remains preserved as interrupted. Host load started at roughly 143 on 10 logical CPUs; this is contention evidence, not a calibrated quiet-host baseline. No source, workload, threshold or baseline was changed for this run.

Selected synchronous component maxima (ms), all with 365 retained days:

| Renderer / week density | Cold | Page | Scroll | Uncached page | Recovery | Resize | Peak RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Canvas / 100 | 75.78 | 9.09 | 6.95 | 19.24 | 9.99 | 9.92 | 98.42 |
| Canvas / 300 | 90.55 | 13.68 | 22.83 | 36.11 | 25.82 | 18.28 | 109.27 |
| Raster / 100 | 146.47 | 40.65 | 1.65 | 106.85 | 103.65 | 126.71 | 446.34 |
| Raster / 300 | 187.77 | 79.48 | 4.70 | 199.16 | 150.44 | 177.86 | 443.06 |

The 100/day native-cell pair measured page maxima 37.96 ms with reuse versus 50.67 ms without reuse; both remain failing alternatives on Mac. Individual versus batched raster publication measured page maxima 38.39/37.97 ms at 100/day and 41.87/40.85 ms at 300/day after the unchanged 250 ms settle. This does **not** establish an integrated paging advantage for individual publication. Its earlier first-page availability evidence remains a separate component result. Adjacent canvas controls also include a 58.46 ms page outlier; retain this noise rather than selecting only favorable pairs.

CUA visible-window checks verified scrolling, Next/Previous, event activation and post-clear-cache content in the latest canvas and raster builds. The [functional review](native-functional-review.json) records exact observations and limits. Dense labels remain unreadable. At 300/day both renderers exposed no event children in the CUA snapshot; at 100/day event children and activation worked. Attribution to app accessibility versus inspection limits is unresolved and requires independent VoiceOver/XCTest verification.

Two fresh 45-second Instruments recordings captured real CUA interaction. Both completed with the app still running and both **failed** the 8.3 ms commit budget:

| Trace | Main commits | Commit p95 | Commit max | Main-loop busy max |
| --- | ---: | ---: | ---: | ---: |
| [Canvas, 100/day](native-canvas-trace-2/summary.json) | 154 | 2.58 ms | 9.45 ms | 109.37 ms |
| [Raster, 300/day](native-raster-trace-1/summary.json) | 78 | 3.09 ms | 40.85 ms | 114.36 ms |

These workloads/densities differ, so the traces are diagnostic checks, not a matched renderer speed comparison. Main-loop busy durations are not input latency and do not attribute the stall to a particular operation. CPU stack attribution and input/display correlation remain open. Full raw traces stay local under `.build/native-calendar-prototype/native-{canvas-trace-2,raster-trace-1}` because they contain process environment metadata; parsed samples, recording logs and binary/environment identities are retained here.

No test windows/processes were left running. Production code and the previously failing eight-case component suite are unchanged; that suite was not rerun for this evidence-only update. The next renderer experiment should target expensive cold/miss/resize work (bounded independently prepared tiles are one candidate), with a matched control and the unchanged correctness, memory and cold/warm contract. Physical 120 Hz acceptance remains unmeasured.
