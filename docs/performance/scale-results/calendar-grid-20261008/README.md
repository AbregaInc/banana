# Independent calendar grid experiment — October 8, 2026

**Decision: retain an opt-in experiment; do not change the default renderer.** Separating the static grid reduces its draw count, but the AppKit image implementation worsens cold loading, resize, cache recovery and memory. UIKit has a different tradeoff. None of these measurements establish physical frame delivery or input-to-visible acceptance. Production code, baselines and budgets are unchanged.

## Hypothesis and native framework investigation

Grid lines and hour labels do not change when paging between equal-length weeks or scrolling. They could retain their pixels while event content updates. Apple exposes [layer-backed view redraw policies](https://developer.apple.com/documentation/appkit/nsview/layercontentsredrawpolicy-swift.property) and [wantsUpdateLayer](https://developer.apple.com/documentation/appkit/nsview/wantsupdatelayer) for updating layer contents. UIKit also distinguishes [opaque and transparent drawing](https://developer.apple.com/documentation/uikit/uiview/isopaque). We tested these existing native facilities rather than introducing a rendering library.

An initial instrumented dense Mac control recorded 16.29 ms in grid drawing and 89.90 ms in event drawing across 35 draws. Grid work was about 15% of those two custom drawing totals. It was not 15% of total frame time: these counters exclude layout, accessibility, backing-store allocation, compositor and GPU work. The raw [diagnostic run](profile-dense.json) is retained.

Two implementations were measured:

1. An independent full-height native grid view below the transparent event surface. AppKit still repainted the underlying grid: 35 control draws became 64 split-grid draws. The [first matrix](mac-pairs/summary.json) showed no dependable benefit. The two `*-first.swift` source snapshots preserve that version.
2. An explicit AppKit CGImage retained in `updateLayer`, while UIKit retains its normal native backing. AppKit grid draws fell from 35 to 5; UIKit split-grid runs recorded 10 grid draws. This is the current opt-in `--ablation split-grid` implementation. The [second Mac matrix](mac-hosted-pairs/summary.json) uses the same unchanged workload and alternating controls.

The cache keeps only the active size/scale/style/day-column configuration, never date history. Width and day-column changes invalidate it; appearance and scale are handled by the native view; the recovery probe explicitly invalidates it. The grid spans 1,920 points vertically. This bounds history retention but is not a small byte budget: backing/image/framework allocations are substantial. Process peak RSS does not include every render-server/GPU allocation. Removing just the event surface independently of its document is not a supported lifecycle in this isolated prototype.

## Correctness and visibility

Both paths use the same grid drawing code. Six offscreen AppKit captures cover initial display, scrolling, two widths, paging, eviction and return to the original viewport. The final captures match the monolithic control byte for byte. The lifecycle suite also checks visible IDs, grid dimensions and empty-page invalidation. CI now runs these checks and retains PNGs and JSON reports.

The initial experiment had an explicit transparent clear that erased the underlying grid in flattened captures. Removing that redundant clear fixed it. The first explicit-image version then produced different colors because its DeviceRGB space differed from the native reference; GenericRGB restored pixel equality. Failed images and logs remain beside the passing `pixels-hosted-v2` results. These checks cover the captured AppKit appearance; they do not establish every appearance, scale, mobile pixel path or complete calendar behavior.

Visible native CUA verification used 365 days and 100 events/day: scrolling preserved aligned hour labels/events, event `4:19-73` selected correctly, Clear cache recovered, and Next changed Oct 8 to Oct 13 with the new event IDs. The isolated window was closed before Simulator measurement. This functional check is not a latency measurement. No new Instruments or physical 120 Hz/input trace was collected.

## Measurement method

Each focused matrix has three alternating-order pairs at 100 and 300 events/day, retaining 365 days. Every case includes cold mount, 12 pages, 120 offsets, six uncached pages, one eviction recovery and three resizes. The `--grid-only` option explicitly selects this subset; ordinary library/history matrices are unchanged. All raw samples, maxima, failed runs, environment and binary identities are preserved. Comparison is within each platform, never Mac timings versus Simulator timings. The fixture store is in memory; this does not benchmark disk paging or provider sync.

The final report and aggregate retain cold, warm, resize, recovery and RSS tradeoffs. A lower draw count alone is not an adoption criterion. The default remains the monolithic canvas. The next useful drawing experiment should target event painting/backing updates with bounded reusable regions or tiles, including cold installation and memory; this result does not justify another full-height image cache.

## Reproduction

```sh
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/Native/MacBenchmark.swift -o /tmp/calendar-grid-benchmark
python3 tools/calendar-library-benchmark/run-mac.py \
  --binary /tmp/calendar-grid-benchmark --grid-only --out /tmp/calendar-grid-mac-NEW
```

The native runner opens visible windows; use only an idle desktop or dedicated test machine. For Simulator, build the pinned `CalendarLibraryBenchmark` Release scheme, then run `run.py --device UUID --app APP --candidates native --grid-only --out NEW_DIRECTORY`. Do not focus Simulator during background checks. The CI workflow contains the exact offscreen correctness commands. No baseline reduction is proposed for this rejected default change; verified future gains need separate reviewed references.

## Final renderer results

All **48 cases** (two Mac matrices and one matrix per Simulator) completed with valid coverage and recorded budget failures. Summaries were regenerated from raw data and matched. The final implementation accounts for 36 of those cases; the first Mac implementation accounts for 12.

The following table pools 360 scroll samples per configuration, preserving every maximum. Values are synchronous renderer work in milliseconds, not frame delivery or input-to-visible latency. The [aggregate](aggregate.json) also retains every phase, per-run tails, draw counts and RSS.

| Platform / density | Control scroll p95 / max | Split scroll p95 / max | Control / split peak MiB |
| --- | ---: | ---: | ---: |
| Mac / 100 | 6.83 / 10.38 | 7.07 / 11.02 | 103.6 / 368.0 |
| Mac / 300 | 8.94 / 20.84 | 8.83 / 22.63 | 115.6 / 379.7 |
| iPhone Simulator / 100 | 28.31 / 34.90 | 25.16 / 35.08 | 188.8 / 269.5 |
| iPhone Simulator / 300 | 46.73 / 68.89 | 17.92 / 31.70 | 194.4 / 244.9 |
| iPad Simulator / 100 | 40.65 / 46.58 | 35.22 / 42.37 | 226.8 / 308.3 |
| iPad Simulator / 300 | 72.63 / 94.97 | 71.29 / 91.65 | 233.6 / 315.4 |

On dense Mac, cold maximum rose **87.05 → 136.31 ms**, eviction recovery **27.09 → 77.41 ms**, and resize **15.54 → 79.40 ms**. The six split-grid cold samples all exceeded 100 ms. Scroll p95 barely changed and the maximum worsened. Reducing grid drawing to five calls did not offset image/backing costs.

On dense iPhone Simulator, scroll p95 improved in all three pairs; cold maximum fell **77.02 → 55.66 ms** and recovery **68.24 → 38.25 ms**, with about 50 MiB higher peak RSS. At 100/day, the smaller scroll benefit came with a slightly worse maximum, cold load, resize and recovery. This is a useful platform-specific result, but still fails scrolling budgets and lacks mobile pixel/device acceptance.

On dense iPad Simulator, pooled scroll p95 only fell **72.63 → 71.29 ms**; cold maximum rose **119.51 → 126.68 ms**, resize **78.21 → 87.15 ms**, and peak RSS rose about 82 MiB. The early trial looked better than the final pooled result, which is why all three trials and tails remain in the report. There is no reliable general performance improvement to adopt.

## Validation and app-wide gate

Both Release builds succeeded. Final checks passed **2,088 geometry/cache checks, 28 text pixel comparisons, 233 raster checks, 19 gate tests and 7 renderer-evidence tests**. The grid control passed seven checks; split-grid passed 20, including the six exact pixel comparisons. Both dense accessibility variants passed 689,946 assertions. Logs and the commands are retained in [checks](checks/run.sh). Offscreen accessibility timings collected during this validation are not used as a performance comparison.

The first required [app-wide regression attempt](app-regression/gate.json) was **unmeasured**: after its build, the runner detected a separate active Xcode build and refused to collect measurements. That other build was left alone. Once it finished, a [fresh complete eight-case run](app-regression-retry/gate.json) **failed** the unchanged baseline: Mail first-page p95 in the Mail redraw scenario was **16.474 ms**, above the reference **12.830 + 2.000 ms** tolerance. All absolute component budgets and memory guards passed, and all four watched redraw probes recorded zero redraws. This isolated renderer experiment does not change that Mail fixture path; attribution of the regression remains open. The collector calls `MailFixtureSource.cachedFirstPage`, not the live provider/storage engine, so this result must not be presented as live-engine performance. Both attempts and all samples are retained; no threshold or baseline changed.

Host contention also limits interpretation: the separate build started at **22:38:29**, overlapping the latter portion of the iPad matrix (**22:37:41–22:39:32**). All samples remain included, but the iPad comparison is not a quiet-host calibrated result and its smaller differences cannot be confidently attributed to the renderer. Mac and iPhone pairs preceded that build. Per-case host loads and binary identities remain in the raw reports. No current result certifies physical-device input latency, compositor/GPU delivery or 120 Hz acceptance.
