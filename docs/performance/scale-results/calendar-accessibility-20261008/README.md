# Calendar accessibility retention experiment — October 8, 2026

**Result: repeated accessibility work reduced; calendar performance acceptance still fails.** Production rendering is unchanged. This experiment modifies the isolated renderer only, preserves all budgets and keeps the rebuilding control as `--ablation rebuild-accessibility`.

## Different area investigated

The renderer recreated every virtual accessibility element, callback, label and frame, then sorted/published the array whenever the overscan band changed. This work ran on the main thread even when most events survived unchanged. We investigated object lifetime and hierarchy updates instead of changing drawing strategy again.

Apple's [NSAccessibilityElement documentation](https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class) supports virtual controls with parent-relative frames and a parent's child array. UIKit provides [UIAccessibilityContainer](https://developer.apple.com/documentation/uikit/uiaccessibilitycontainer) for custom-drawn elements. The existing native framework objects remain in use; this needs no new library or replacement accessibility system. It addresses a lifecycle problem in our adapter.

The new implementation retains an element under the same event ID while it remains in the prepared viewport, updates changed frames, and rebuilds the ordered child list only when membership changes. Retired elements lose their activation callback and are never repurposed for another event. Retention is bounded by the current prepared viewport, independent of history; there is no spare or history-wide accessibility cache. Lexicographic order and event coverage are preserved. Labels/content are fixed fixtures here; production adoption must handle live label/semantic changes and VoiceOver focus behavior.

## Correctness repair found during exploration

The initial [failing check](initial-checks.log) exposed an empty-page early return that left stale accessible content. Empty installation now clears presentation IDs, accessible children, attached event views and raster pixels. An externally retained retired virtual element cannot activate a stale event and reports unsuccessful activation. Both ablation modes include these correctness repairs.

The new offscreen suite verifies child IDs/order, role, parent-relative frames, unchanged identity for surviving events, scroll/resize behavior, cache eviction, activation, retirement and empty state. It runs both densities and both implementations; raster correctness additionally checks clearing an empty page. Initial and final component runs are both retained. The initial component run predates the final explicit unsuccessful-retired-activation return; use `components-final` for the final implementation comparison.

## Measurements

The final offscreen AppKit component trials at 300/day measured same-page accessibility work at **2.307 ms median rebuilding versus 0.108 ms retaining**. Across the same 360 scroll updates, new element allocations fell from **42,615 to 4,005** (about 91% fewer). Cold construction and navigation to disjoint pages still create new elements and show no established improvement. Component timings omit drawing/display; do not substitute them for visible interaction latency.

[Mac](mac-pairs/summary.json), [iPhone Simulator](iphone-pairs/summary.json) and [iPad Simulator](ipad-pairs/summary.json) each completed **24 valid cases**: three alternating-order paired trials, both 100/300 daily densities, canvas/raster. Each case retains the original cold mount, 12 pages, 120 offsets, six uncached pages, memory-pressure recovery and three resizes. All 72 cases have budget failures. These are explicit focused subsets, not reruns of every library/history case. Host load began around 9 on the Mac rather than the previous run's 143; matched controls are from this same run, not a speed comparison to the overloaded historical matrix.

The table pools all 360 scroll samples per configuration; every maximum remains included. Values are synchronous renderer work in milliseconds, **not input-to-visible or physical frame delivery**. Per-run tails, every phase, RSS and case paths are in [aggregate.json](aggregate.json); individual raw samples remain beside each run summary.

| Platform / renderer / density | Rebuild scroll p95 / max | Retain scroll p95 / max |
| --- | ---: | ---: |
| mac / canvas / 100 | 7.46 / 11.97 | 7.16 / 9.92 |
| mac / canvas / 300 | 10.75 / 22.46 | 9.75 / 21.56 |
| mac / raster / 100 | 2.13 / 4.21 | 1.50 / 2.94 |
| mac / raster / 300 | 3.16 / 8.72 | 2.76 / 4.67 |
| iphone / canvas / 100 | 30.53 / 37.15 | 28.83 / 38.87 |
| iphone / canvas / 300 | 52.39 / 72.85 | 49.64 / 69.69 |
| iphone / raster / 100 | 1.74 / 4.44 | 0.68 / 2.96 |
| iphone / raster / 300 | 2.31 / 5.38 | 1.31 / 7.39 |
| ipad / canvas / 100 | 41.98 / 49.61 | 41.09 / 48.54 |
| ipad / canvas / 300 | 75.16 / 97.87 | 72.67 / 95.90 |
| ipad / raster / 100 | 1.11 / 2.90 | 1.05 / 2.91 |
| ipad / raster / 300 | 2.61 / 6.70 | 1.19 / 4.47 |

Dense Mac canvas p95 was lower in each matched pair (rebuild 10.55–10.78 ms; retain 9.33–9.75 ms). That is a modest integrated improvement, not achievement of 8.3 ms. Raster scrolling generally benefits, but noise/outliers remain: iPhone dense raster maximum increased from 5.38 to 7.39 ms, and iPad 100/day was essentially unchanged. Do not describe every tail as improved.

Memory is also mixed. Dense Mac canvas peaks were 117.8–118.1 MiB rebuilding versus 114.9–115.1 MiB retaining; one 100/day retained raster run reached 452.8 MiB versus about 412.8 MiB in controls. The dictionary adds retained indexing overhead while reducing object churn; framework/image lifetime dominates some peaks. No general RSS reduction is claimed.

Cold and cache-miss failures persist. Retained raster cold maxima reached 187.57 ms on Mac, 170.13 ms on iPhone Simulator and 186.49 ms on iPad Simulator. The work does not fix full-page image preparation/installation. Native dense canvas scroll maxima still exceed 20 ms. No baseline was updated or reduced automatically.

## Visible functional verification and limits

CUA checked the final native canvas at 365 days, 100 events/day. After scrolling, event `4:19-73` activated correctly, survived Clear cache, and activated correctly again. Next moved Oct 8 to Oct 13; the new page's `4:24-73` activated correctly. The snapshot preserved surviving element identities instead of replacing the entire tree. The test instance was closed afterward.

The offscreen dense child/label/frame oracle passes, but the earlier external CUA snapshot omission at 300/day has not been independently resolved with VoiceOver/XCTest. This run does not certify external assistive-technology behavior at that density, physical iPhone/iPad input, or 120 Hz display delivery. No fresh Instruments trace was collected for this patch. Prior failed native traces remain relevant evidence gaps, not passes.

## Persistent reproduction

```sh
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/AccessibilityTests/main.swift -o /tmp/calendar-ax-checks
/tmp/calendar-ax-checks --mode week --density 300 --ablation rebuild-accessibility --output /tmp/ax-rebuild.json
/tmp/calendar-ax-checks --mode week --density 300 --ablation none --output /tmp/ax-retain.json
```

The CI component workflow runs both variants at both densities. Use `--accessibility-only` with `run-mac.py` or `run.py` to repeat the complete 24-case focused matrix; normal default matrices are unchanged. On Simulator also pass `--candidates native`. Use a new output directory every time. Commands, full runtime source hashes and binary identities are captured by the runners and [implementation manifest](implementation.json).

After repeated dedicated-host and physical-device validation, propose a separate reviewed reduction of the appropriate scrolling reference. Do not set a passing baseline around the current failing cold/dense paths. The next large cost to attribute is canvas drawing and raster cold/miss installation; this measured accessibility improvement cannot remove those costs.


## Validation and app-wide gate

Both optimized builds succeeded. The shared suites passed **2,088 geometry/cache checks, 28 pixel-exact text checks, 233 raster checks, 19 gate tests and 7 renderer-evidence tests**; logs are in [checks](checks/geometry.log). All 72 renderer summaries were independently regenerated from raw reports and matched exactly. The twelve final offscreen comparisons passed their full accessibility oracles.

The required [eight-case app-wide component suite](app-regression/gate.json) completed and **failed** the unchanged baseline. At 90 days, notes search reached 227.11 ms, next-podcast selection 252.54 ms and download candidates 274.45 ms. In the Library redraw scenario, notes search reached 697.29 ms and download candidates 496.83 ms. Those production paths are unchanged by this isolated renderer patch; attribution and fixes remain separate open work. Preserve these failures alongside the renderer improvement. See [raw measurements](app-regression/measurements.json) for all metrics and redraw counts.
