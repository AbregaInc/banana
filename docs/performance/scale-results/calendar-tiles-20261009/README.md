# Explicit calendar tiles — October 9, 2026

Experimental only; production rendering and acceptance budgets are unchanged. Work remains in progress.

Apple's [CATiledLayer](https://developer.apple.com/documentation/quartzcore/catiledlayer) asynchronously supplies tile content. A completed setter is insufficient evidence of complete pixels. This experiment uses native CALayer image contents with explicit bounded tiles; installation completes only after all required tile images exist. Existing library/native-framework comparisons remain in the earlier calendar reports.

The tile cache retains at most 64 MiB and 24 entries. Visible layers separately retain their pixels through eviction. This is an experiment limit, not the application's total memory budget. Cold, warm, uncached paging, resize, eviction/recovery and peak RSS remain in every case. No failed run was removed.

## Initial comparisons

`iphone-first` and `ipad-first` each contain 18 completed cases: three alternating-order trials, 100/300 events per day for 365 days, canvas/full raster/256-point tiles. All evidence is valid; budget failures remain. Exact initial sources and hashes are in `initial-sources`.

Tiles reduce cold work relative to full-page raster but introduce foreground work when scrolling to missing tiles. At 300 events/day the worst measured Simulator scroll was 25.07 ms on iPhone and 17.86 ms on iPad. Full raster scroll maxima were 4.00 and 3.89 ms, with cold maxima of 144.93 and 159.52 ms. Neither tradeoff meets the complete contract.

## Separate prefetch ablations

`iphone-prefetch` and `ipad-prefetch` each retain 24 completed cases: no prefetch, neighboring scroll tiles, adjacent pages, and both, repeated three times at both densities. Sources are in `prefetch-sources`. Maxima across three trials at 300 events/day:

| Simulator | Variant | Cold ms | Page ms | Scroll ms | Recovery ms | Resize ms |
|---|---|---:|---:|---:|---:|---:|
| iPhone | None | 75.08 | 59.20 | 19.18 | 62.18 | 52.04 |
| iPhone | Scroll | 75.81 | 60.81 | 7.53 | 59.41 | 51.38 |
| iPhone | Page | 75.20 | 8.71 | 17.63 | 61.10 | 51.59 |
| iPhone | Both | 76.39 | 8.77 | 6.59 | 57.48 | 50.18 |
| iPad | None | 105.67 | 86.42 | 15.87 | 88.69 | 71.61 |
| iPad | Scroll | 112.73 | 94.14 | 6.21 | 90.26 | 72.78 |
| iPad | Page | 107.63 | 95.30 | 14.33 | 90.93 | 73.38 |
| iPad | Both | 111.21 | 92.27 | 6.80 | 83.81 | 70.18 |

Scroll prefetch helps these measured warm scrolls. iPad page prefetch does not help; counters show foreground rebuilding after adjacent pages compete for the bounded cache. A follow-up capacity/LRU ablation is underway. No increase to cache limits is proposed.

## Correctness and limitations

`lifecycle-300.json` records 982 offscreen checks across pixel configurations, scrolling, paging, resizing, eviction/recovery and empty installation. `prefetch-checks.json` records the initial 12 cancellation/availability checks. Extended cache tests are pending.

Tiles are **not byte-exact** against the single full-page image. Across widths 400/1200, scales 1/2/3 and tile heights 128/256/512, differences were at most one 8-bit channel level. The initial strict failures, difference counts and rejected padded experiment are retained. Guard-band rendering did not materially resolve the rounding difference and was removed. The explicit pixel check allows one channel level; it does not change a performance threshold or coverage requirement.

These are synchronous renderer measurements in Simulator. They do not establish 120 Hz display delivery, input-to-visible latency, physical iPhone/iPad performance, or production-app acceptance. Native Mac and physical-device comparisons, final correctness reruns and the full persistent app gate remain required. No baseline reduction is proposed until verification is complete.

## Fixed-budget cache experiment (both Simulators complete)

`ipad-cache` retains all 18 cases and `cache-sources` the exact implementation. Independent LRU lookahead did not materially improve paging in this matrix. Budget-aware prefetch chooses one adjacent page when the visible band plus both neighbors cannot fit, preferring the previously visited page when adjacent; it otherwise preloads forward. This deliberately favors a warm return over speculative forward navigation under tight capacity. Cold and forced uncached pages remain measured.

Across three trials at 300 events/day, page maximum was 93.60 ms for the previous prefetch, 91.01 ms with lookahead, and 14.06 ms with capacity-aware prefetch. Scroll maxima were 6.51/6.73/6.96 ms. Cold maxima remained 116.39/118.09/118.86 ms; forced uncached maxima were 92.27/99.40/94.46 ms; recovery 91.75/88.29/90.43 ms; resize 72.02/73.08/74.54 ms. This is a warm-paging improvement only, with all remaining failures preserved. The 64 MiB/24-entry limits are unchanged.

`cache-checks.json` records 23 checks, including an adversarial LRU order where lookahead preserves two pending hits instead of rebuilding four tiles, wide-page cache coverage, cancellation, eviction and generation retirement. The adversarial correctness/cost result does not imply a measured win in the full iPad matrix.

The matching iPhone matrix also completed all 18 cases with valid coverage. At 300 events/day, page maxima were 14.71/9.11/11.05 ms for previous/lookahead/budgeted policies, scroll 6.25/5.96/6.37 ms, cold 76.74/81.25/78.02 ms, forced uncached 65.16/68.15/68.46 ms, recovery 59.62/59.50/57.55 ms, and resize 50.98/50.32/49.98 ms. Its smaller bands already fit; this does not show the large capacity-policy benefit seen on iPad. The unchanged control's variation across matrices is retained.

## Memory tradeoffs

Peak process RSS maxima at 300 events/day in the initial comparison were 194.7/311.3/228.6 MiB
for iPhone canvas/full raster/tiles, and 233.8/398.5/273.8 MiB on iPad. Tiles therefore retain
more process memory than the canvas, while using less than the full-page raster in these runs.
These are Simulator process peaks, not a physical-device or production-app memory budget.

For the cache-policy matrix, dense iPhone RSS maxima were 230.7/230.2/230.4 MiB and iPad maxima
273.4/273.3/277.5 MiB for previous/lookahead/budgeted policies. The paging gain is not presented
as a memory reduction. Maximum cache images were 63.7 MiB on iPhone and 61.8 MiB on iPad;
active image references reached 17.7 and 32.2 MiB respectively. Active images can also be in
the cache, so adding these two counters would double-count shared images. All raw counters and
peak RSS are retained, including eviction/recovery and resize samples.

## Invisible-text culling (experimental, mixed results)

Both `ipad-text` and `iphone-text` contain all 12 paired cases. `text-sources` captures the implementation before host monitoring was added to the runners. The renderer avoids shaping hour/event labels whose font ink bounds cannot intersect the tile. This bound is valid for the benchmark's ASCII labels and exact fonts; arbitrary user text would require accounting for fallback fonts. `text-cull-checks.json` records 1,306 checks, including byte-exact culling/control pixels for all 162 tile captures, unchanged ID coverage, and the existing lifecycle checks. The separate full-page/tile rounding tolerance remains unchanged.

Dense maxima, control / culling (ms):

| Simulator | Cold | Page | Scroll | Uncached | Recovery | Resize |
|---|---:|---:|---:|---:|---:|---:|
| iPhone | 98.46 / 81.97 | 51.78 / 51.02 | 6.70 / 6.62 | 80.95 / 64.96 | 75.26 / 56.07 | 59.94 / 46.47 |
| iPad | 111.05 / 110.85 | 16.73 / 15.68 | 5.90 / 12.49 | 108.95 / 91.78 | 94.39 / 82.26 | 77.41 / 64.58 |

This did not solve dense iPad cold loading and the culling variant includes a scroll failure. Another `xcodebuild`/`xctest` process was observed immediately after the iPhone matrix; its exact overlap with cases is unknown. Per-case host loads are retained (some around 50–65). The first dense iPhone control page rebuilt three missing tiles after only two prefetch tiles had arrived; the first-page tail is real, but contention prevents treating this matrix as clean comparative evidence. No run is removed and no default is changed.

All warm paging matrices allow a 250 ms settle period between page actions. They do not establish equally fast rapid consecutive navigation or directional prediction. Forced uncached cases are retained, but further fast/directional sequences are needed before adoption. Future runner invocations continuously sample competing developer processes and label observed contention; that evidence cannot be retroactively applied to these matrices.

Text-culling matrix dense peak RSS was 230.47 / 230.34 MiB on iPhone and 278.09 / 276.84 MiB
on iPad (control / culling); this is not evidence of a meaningful memory reduction. The new
screen metadata reports a maximum supported 60 Hz for these Simulator screens. Physical builds
now enable Apple's [high-refresh-rate Info.plist option](https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone),
as the production app already does. This permits higher-rate requests; it does not prove delivery.

## App-wide component gate

`app-regression/gate.json` passes all eight unchanged cases against baseline version 1, with clean sampled developer-process evidence in all eight. All component budgets, regression comparisons, memory limits and redraw checks passed for that recorded binary. This does not overturn the failing native UI traces. Further native popover anchoring and observation experiments were authored afterward, so another final app gate remains required for the final source state.

## Broader correctness rerun

The retained `checks/run.sh` completed successfully: 2,088 geometry/cache checks; 28 text pixel comparisons; 233 raster checks; 1,306 tile checks; 23 tile prefetch/LRU/cancellation checks; 15 overflow coverage checks; 18 native hour-line pixel comparisons using the production primary-color opacities; grid control/split checks (7/20); accessibility retention/rebuild checks (689,946/689,825); 27 gate/host-monitor tests and 8 renderer-evidence tests. All logs and images are retained. Offscreen timings from these correctness runs are not comparative UI performance evidence.
