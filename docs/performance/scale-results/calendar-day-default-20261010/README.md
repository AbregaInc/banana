# Default native Day adoption and midnight correction — October 10

Status: **iPhone/iPad selected default-path checks and full component regression gate passed; physical UI performance remains unmeasured.**

The iPhone/iPad Day viewport now selects the native reusable collection by default
in both DEBUG and production builds. DEBUG `--calendar-reference-day` retains the
old host for comparisons. Native interaction tests no longer pass an opt-in flag;
they require an actual CollectionView. The reference tests/profiler now explicitly
select the old host. Prepared artwork remains independently opt-in; Week/Agenda
retain their current hosts and native Mac is separate.

Before accepting this change, source review found both mobile renderers projecting
next midnight as y=0. The new real-app `testDayMidnightExtent` failed on the pre-fix
binary: 24-hour events 0/10 did not intersect the midday viewport. The raw result
`midnight-before.xcresult` and summary are retained; terminal exit was 65.
This was a shared geometry bug, not a failure introduced by native reuse.

`CalendarDayClockGeometry` anchors projection/clipping to the actual local day.
Next midnight is the bottom of the existing fixed 24-hour wall-clock ruler, even
on 23-, 25-, or half-hour-DST days. Both mobile Day hosts, Week events and travel
bands now share it. Boundaries are computed once per day rather than per point.
Agenda retains its separate elapsed-time model. This preserves the existing
wall-clock treatment of repeated hours; it does not establish complete DST
creation/drag UX correctness.

The pure component test passed **99 checks**. Matched in-day R/N/N/R work retained
28 samples of 2,000 projections. Reference median/max: 1.194/1.787 ms; anchored:
1.220/2.360 ms. This is **not a speedup** and not frame/input latency evidence.
The geometry fix renders previously collapsed long blocks at their proper extent;
its additional rendering/memory cost must be measured in the app. No cache or
baseline was changed. The component test is now included in calendar-core CI.

A separate fixture gap remains: the full-app legacy scale fixture has regular
per-day geometry and one calendar. The varied/multi-calendar workload exists in
the standalone benchmark, not yet in the full app. Keep the reviewed legacy
baseline and add supplementary varied app scenarios before broad acceptance claims.

## Corrected-geometry integration measurements

Optimized iPhone 17 Pro / iOS 26.5 Simulator: all five selected integration tests
passed with zero skips: midnight extent, create gesture, paging/zoom, long move,
and durable move recovery. Four counterbalanced reference/native/native/reference
scroll-and-open tests passed, plus one native prepared-artwork scroll-and-open test.
Native tests require CollectionView without an opt-in flag; reference tests require
ScrollView with `--calendar-reference-day`.

Steady physical memory medians per scroll run (kB): reference 202,082.752;
native 197,315.008; native 197,921.216; reference 204,097.984. Across six samples
per host, native is about 5.2 MB lower. The single prepared-native run used
205,162.968 kB; it is separate coverage, not a paired prepared/reference verdict.
All gesture/signpost durations remain in the raw metric exports; they measure
scroll activity/automation, **not frame work or input latency**.

The separate same-binary prepared-artwork R/N/N/R startup comparison retained:

| Host | Preparation jobs | Sum preparation ms | p95 / max ms | Peak RSS MiB | Consumer pixel bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Reference | 106 | 94.083 | 2.030 / 2.583 | 467.078 | 11,292,480 |
| Native | 50 | 53.551 | 2.390 / 2.631 | 453.969 | 9,892,160 |
| Native | 50 | 52.301 | 2.408 / 2.654 | 453.984 | 9,892,160 |
| Reference | 106 | 92.619 | 1.988 / 2.502 | 465.703 | 11,292,480 |

All four preparation collectors returned zero, with complete samples, no pending
jobs, bounded image ownership and passing idle-redraw probes. Native avoids
preparing offscreen short events; long events correctly intersecting the viewport
remain materialized. Its per-job tails are slightly higher. These numbers are
cache-miss API work, not queue-to-ready, frames or input-to-visible measurements.
Raw samples, host observations and binary/collector identity are retained.

Visual inspection of `day-midnight-extent` confirms corrected full-height blocks,
but also shows narrow, largely unreadable columns under this workload. Functional
passes do not resolve high-density presentation. The fixed legacy fixture has
many overlapping 24-hour timed events; a supplementary varied multi-calendar
full-app fixture and density/capacity exploration remain required.

Further source-review candidates (not fixes or measured improvements): continuation
moves appear anchored to the displayed day instead of the original start day;
optimistic event ends do not yet follow moved starts. Mail's two native list hosts
retain row/display dictionaries across membership changes. Add focused correctness
and retention checks before changing these paths.

The full persistent component suite completed with exit 0: four history tiers
(1/7/30/90 days) plus Notes/Library/Plan/Mail redraw probes, eight cases total.
`components-gate.json` has no failures against baseline version 1. These runs
continue to seed Week and therefore do not replace the targeted Day UI checks.
The 90-day calendar query maxima were 8.40 ms for visible Week and 0.68 ms for
Day. No budget, reference, scenario, workload count or checksum was changed.

Raw build/test bundles and collection logs live under
`.build/calendar-day-default-20261010/`. `identity.json` records the dirty-tree
source and optimized Simulator binary hashes. The persistent runner's rebuild
produced the same binary hash. Both comparison hosts therefore used the same
corrected geometry and fixture; earlier collapsed-event preparation figures are
historical, not the cost of this implementation.

After representative varied-fixture and cold/warm/eviction repetitions, propose a
reviewed native-Day preparation/memory baseline reduction reflecting the avoided
offscreen work. Do not alter the existing component baseline automatically or use
aggregate preparation time as a frame/input baseline.

## iPad and cleanup

The same optimized binary passed all five selected iPad Pro 13-inch M5 / iOS 26.5
Simulator tests, with zero failures or skips: midnight extent, dense scroll/open,
long move, durable recovery and paging/zoom. Exact device/counts and scrolling
samples are in `ipad-default-summary.json` and `ipad-default-metrics.json`.
`iphone-midnight.png` and `ipad-midnight.png` were visually inspected; both show
the corrected extent, with the dense-column readability limitation retained.

Both owned fixture Simulators were shut down. Removed 33 UUID-scoped temporary
fixture directories, **4.557 GiB logical**, after retaining results. Prior failing
query databases, result bundles, comparison binaries, workspace and worktree remain.
The original expected failing midnight test is also retained.

Native `BananaMac` Release/arm64 compile/link also completed with exit 0. No Mac
window was opened or driven; desktop interaction/frame acceptance remains open.
