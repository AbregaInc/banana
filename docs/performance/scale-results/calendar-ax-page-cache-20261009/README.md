# Same-event accessibility page retention — October 9, 2026

The optional `tile-prefetch-ax-cache` policy adds bounded retention to `tile-prefetch-budgeted`.
It retains at most three retired page dictionaries and 4,096 retired accessibility objects,
in addition to the active viewport. Objects never change event ID. Retiring a page disables its
elements/actions; returning to that same page restores their identity, actions and frames.
The requested cached page is removed before insertion/eviction of the outgoing page. Memory
pressure releases all retired pages while preserving active content. Default policies are unchanged.

All **12 physical iPhone cases completed with valid coverage and budget failures**. Device:
iPhone 14 Pro / iOS 27.0.1, same 365-day 100/300-event workloads and three alternating-order trials.
The control and variant share one binary. All phases and samples remain in physical-iphone.
No other build or performance test ran concurrently. These are synchronous renderer components,
not input-to-visible or 120 Hz compositor acceptance. Warm paging alternates two pages after a
250 ms settle; it does not establish a gain for rapid or continuously forward navigation.

| Density/day | Policy | Cold max ms | Page max ms | Scroll max ms | Uncached max ms | Recovery max ms | Resize max ms | Peak RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | Control | 38.174 | 9.958 | 4.098 | 64.307 | 32.959 | 20.300 | 43.61 |
| 100 | AX page cache | 35.576 | 5.789 | 4.436 | 65.405 | 33.065 | 20.530 | 43.77 |
| 300 | Control | 57.807 | 18.059 | 8.656 | 88.993 | 41.171 | 39.592 | 48.03 |
| 300 | AX page cache | 57.181 | 10.896 | 9.301 | 88.723 | 41.678 | 39.857 | 48.58 |

This is a measured warm-revisit paging gain with a small RSS increase. Scrolling did not improve;
cold/miss and recovery costs remain. The dense variant still misses 8.3 ms even on warm pages.
Do not sum this gain with other optimization claims or substitute it for app-wide acceptance.
A reviewed future regression reference could preserve the verified warm-revisit gain after
broader validation, but no baseline or budget is changed here.

Offscreen AppKit checks pass: 690,239 control and 726,740 cached checks, covering identity, order,
frames, activation, retired references, requested-hit ordering, bounded eviction and empty pages.
Those counts include per-element checks; they are not independent timing trials. The recorded
page allocations fell from 24,300 to 1,215 across 20 page changes. Offscreen maximum page time
was 17.03 versus 17.21 ms, so it does not establish an AppKit speedup. UIKit-specific API checks and Simulator comparisons are recorded below. Native Mac UI
comparisons and VoiceOver navigation remain pending.

The physical source snapshot uses Benchmark.swift from the preceding scene-lifecycle build;
the later UIKit correctness-probe route and VoiceOver-state metadata were added after this binary
was built. They are deliberately excluded from the physical-source identity snapshot. The fixture
labels/data are immutable; real editable-content integration needs revision-aware invalidation.

## Simulator follow-up

Both 12-case matrices completed with valid evidence and budget failures. All per-case developer-process samples were clean. These remain Simulator component measurements. Maximum milliseconds over three trials:

| Device | Density | Policy | Cold | Page | Scroll | Uncached | Recovery | Resize |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| sim-iphone | 100 | budgeted | 60.604 | 11.094 | 7.863 | 43.263 | 42.063 | 29.833 |
| sim-iphone | 100 | ax-cache | 54.156 | 7.840 | 6.278 | 42.000 | 41.051 | 28.915 |
| sim-iphone | 300 | budgeted | 80.846 | 10.964 | 5.312 | 68.036 | 61.127 | 55.211 |
| sim-iphone | 300 | ax-cache | 88.325 | 13.852 | 6.645 | 69.698 | 61.752 | 51.867 |
| sim-ipad | 100 | budgeted | 87.120 | 14.292 | 4.262 | 66.279 | 60.949 | 44.894 |
| sim-ipad | 100 | ax-cache | 77.107 | 13.864 | 6.399 | 68.316 | 62.151 | 45.987 |
| sim-ipad | 300 | budgeted | 111.545 | 15.404 | 7.689 | 112.088 | 91.774 | 76.234 |
| sim-ipad | 300 | ax-cache | 124.851 | 14.187 | 6.821 | 100.686 | 93.030 | 78.326 |

UIKit offscreen API checks passed on both iPhone and iPad Simulators: 74,293 control checks and 75,510 cache checks each. They cover ordering, identity, frames, activation, retired references, eviction and empty pages. They do not establish VoiceOver focus/navigation behavior. Exact Simulator sources are retained in `sim-sources`; native Mac UI and VoiceOver comparisons remain pending.
