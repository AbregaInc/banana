# Asynchronous foreground calendar preparation — October 9, 2026

Experimental prototype only. Production rendering defaults and all performance budgets remain
unchanged. Device validation is in progress; no input/display acceptance is claimed.

## Why this experiment

The previous bounded background-prefetch experiments still missed when navigation outran
speculation. On a miss, the foreground path drew every visible tile synchronously. Moving that
same immutable drawing work off the main actor allows input processing to continue. Old page
pixels, date and accessibility remain together until the complete replacement is prepared.

Native alternatives were reviewed first. [CATiledLayer](https://developer.apple.com/documentation/quartzcore/catiledlayer)
supports asynchronous tile drawing, but does not supply this prototype's explicit complete-band
publication boundary. [CALayer.drawsAsynchronously](https://developer.apple.com/documentation/quartzcore/calayer/drawsasynchronously)
also requires measurement and does not establish page readiness. The existing explicit CALayer
renderer therefore uses native [Swift task groups](https://developer.apple.com/documentation/swift/taskgroup)
for one or two foreground workers, with [cooperative cancellation](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/).
No custom thread pool or new calendar layout engine was introduced.

The existing spare LRU remains bounded at 64 MiB / 24 images. Preparing a replacement temporarily
retains both old and new visible bands; those active images are additional to the spare-cache
limit. Measurements must report that cost. Immutable prepared images remain retained through
publication even if the spare LRU evicts them, preventing an accidental synchronous redraw.

## Reproducible component checks

```sh
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/TileTests/async.swift -o /tmp/calendar-async-tests
/tmp/calendar-async-tests --density 100 --output /tmp/calendar-async-100.json
/tmp/calendar-async-tests --density 300 --output /tmp/calendar-async-300.json
```

The initial component runs use one visible day (`--mode day`, the default); device runs use five
visible days (`--mode week`). Seven alternating trials compare synchronous, one-worker and two-worker preparation at 393 pt / 3x
and 1200 pt / 2x, with an 800 pt viewport. Cold pixel caches, warm reuse and explicit eviction
remain separate. These are not process-cold startup measurements. Pixel bytes and event IDs are
compared against the original renderer outside the timed interval. Additional checks cover tiny
LRUs, coherent old-page retention, and cancellation without retired-generation publication.

`--workers 0`, `1` or `2` selects a single policy. Add `--memory-probe` for supplemental fresh-process memory measurements
without allocating pixel-oracle reference images between samples; these runs are explicitly labeled
`memory-probe-complete` and never replace the required pixel correctness runs. Memory probes
require a single policy; ordinary comparisons keep all three policies by default. Peak RSS in the alternating process is cumulative and
must not be attributed to one implementation. A one-millisecond main-actor heartbeat measures
scheduling delay only; it does not measure frames or input-to-visible response.

## Physical-device protocol

`run-device.py --matrix foreground --foreground-navigation --navigation-stress` keeps every
original cold, paging, scrolling, resize, eviction and rapid-navigation sample, then appends
68 foreground samples. Three trials alternate all three policies at 100 and 300 events/day.
The new response interval ends at synchronous layout/transaction flush after complete page
publication, not physical display. Main-thread sections are separately reported; runtime
bookkeeping outside instrumented sections is excluded. Missing phases, incorrect IDs/date,
non-finite timings, cache-bound violations and synchronous fallback invalidate evidence.

`test-device-interactive.py --async-workers 0|1|2` launches the isolated native prototype and
uses actual XCTest button taps and swipe gestures. It checks forward dates, reverse traversal,
scrolling and eviction. Gesture wall clock and the three-second correctness timeout are not
performance budgets. Full frame delivery and input-to-visible timing require separate traces.

## Initial results and retained failures

The first offscreen component binary passed 1,099 checks at each density. Its one-day narrow
cold-page median/max at 300 events/day was 48.637/59.951 ms synchronously, 48.989/51.385 ms with one
worker and 31.249/32.491 ms with two. At 1200 pt / 2x, two-worker median/max was 34.316/53.996 ms;
the worst heartbeat gap was 8.483 ms. The result is promising main-thread relief, not proof that
every page meets the 32/50 ms goals. Raw cold/warm/eviction and memory samples are retained under
`component-initial/`. Later checks and platform measurements supplement these runs.

The original synchronous touch build passed one physical iPhone test at each density, plus one
300-density profiled test. The async build passed one at each density with stronger per-page
assertions; its 300-density run overlaps the short trace attempt below. This is not a matched
latency comparison. The async100 screenshot was inspected: the timeline and controls are present,
but five densely overlapping columns on a phone are not a production-ready calendar layout.

Physical Instruments failures remain retained under `touch-initial/`: name/PID attachment using
the device identifier failed in earlier attempts; a 60-second Animation Hitches recording did
not finish postprocessing within its deadline and was terminated; an eight-second capture during
async swipes saved a trace but exited 2 with an internal `backtrace` / `tagged-backtrace` type error.
None establishes complete frame delivery. The short trace raw path is
`.build/calendar-touch/iphone-async2-300-short-trace/touch.trace`; the longer failed trace remains
at `.build/calendar-touch/iphone-control-300-full-trace/touch.trace`. Idle five-second schema probes
are not interaction evidence. Touch logs and XCTest summaries are retained independently.

## Physical iPhone: complete 18-case foreground comparison

The same Release binary (`ccb0f7cce298352609150f6cf9d8dfec0461ea40604613b3c6712e2a36a07503`)
ran three alternating trials per policy/density on iPhone 14 Pro, iOS 27.0.1, 393 pt / 3x.
All 18 reports have valid original and appended phase coverage; all original acceptance gates
still fail. Foreground component limits hold for all six async100 cases, but all async300 cases
still exceed the measured main-section threshold. This is not UI/frame acceptance.

Pooled request-to-publication p95 / maximum in milliseconds (flush ends the interval):

| Density | Policy | Uncached page | Rapid forward | Rapid return |
| --- | --- | ---: | ---: | ---: |
| 100 | Synchronous | 63.44 / 63.44 | 25.92 / 27.79 | 16.15 / 16.19 |
| 100 | One worker | 66.12 / 66.12 | 27.25 / 28.90 | 36.33 / 38.92 |
| 100 | Two workers | 49.55 / 49.55 | 20.39 / 20.70 | 11.49 / 11.55 |
| 300 | Synchronous | 94.88 / 94.88 | 49.57 / 49.84 | 50.40 / 52.33 |
| 300 | One worker | 90.99 / 90.99 | 82.87 / 85.71 | 60.41 / 67.54 |
| 300 | Two workers | 70.15 / 70.15 | 60.75 / 60.82 | 53.19 / 55.47 |

Two workers improve cold-miss preparation and 100-density rapid paging. At 300 density, rapid
forward tails **worsen** despite lower measured main-thread blocking; extra scheduling and
speculation compete with foreground work. One worker also worsens rapid response tails. No
blanket improvement or production adoption is justified. The 300-density warm installation
path still exceeds 8.3 ms; accessibility construction/publication remains a candidate for the
next controlled comparison. Original cold mount, scrolling, resizing and recovery failures
remain visible in `physical-iphone/summary.json`. Every sample and pooled percentile is retained.

## AppKit backing experiment (pending)

Initial native foreground runs still spend about 18–21 ms in the layout/display/flush section
at 100 events/day after moving bitmap creation off-main. A separate default-off
`tile-prefetch-async-layer` ablation uses AppKit's native
[`wantsUpdateLayer`](https://developer.apple.com/documentation/appkit/nsview/wantsupdatelayer) /
[`updateLayer`](https://developer.apple.com/documentation/appkit/nsview/updatelayer%28%29) path with
`onSetNeedsDisplay`. The hypothesis is that the old no-op `draw(_:)` still makes AppKit maintain
an unnecessary surface bitmap around the already-rendered tile sublayers. The candidate keeps
those sublayers, event geometry, accessibility and cache policy identical; it does not substitute
an approximate scroll image. It applies only to the native tiled surface. Counters distinguish
actual draw callbacks from layer updates. Use `run-mac.py --foreground-layer-only
--foreground-navigation --navigation-stress` for three alternating trials at both densities.
Visual correctness and measured benefit remain pending; this is not adopted by the app.

## Expanded component validation and memory

The next probe revision adds model-resolution coherence, superseded-request retirement, and
parent-task cancellation. All four day/week × 100/300 runs passed 1,106 checks each (4,424 total).
All sampled host monitors were clean. Separate week-view processes at each worker count omit
pixel-reference allocation while keeping cold/warm/eviction preparation and lifecycle checks.
They do not replace those full oracle runs.

| Events/day | Synchronous peak MiB | One worker peak MiB | Two workers peak MiB |
| --- | ---: | ---: | ---: |
| 100 | 26.41 | 26.62 | 33.88 |
| 300 | 29.27 | 30.72 | 36.61 |

These are process peak RSS values within the measured workload, not device memory limits. Active
image bytes peak at 18.75 MiB in these probes; caches and in-flight contexts add memory separately.
Two workers cost roughly 7–8 MiB over synchronous preparation. Complete raw timing samples,
fresh-process commands and host evidence are under `component-v3/`.

A later controller review also found a request-intent race: an older canceled task's deferred
cleanup could clear a newer request before its task started. Interactive input now invalidates
the old generation before cancellation. A separate programmatic native-controller probe exercises
running-request cancellation, accumulated rapid input, eviction and recovery; its results remain
pending. Sequential foreground timings above do not exercise that race.

## Completed native foreground and backing follow-up

All 18 AppKit foreground cases completed with valid coverage and clean sampled host monitoring;
all still failed the main-section gate. At 100 density, worst response/main section was
55.46/37.17 ms synchronously, 63.77/21.77 ms with one worker, and 47.05/21.31 ms with two. At 300,
the corresponding maxima were 82.97/65.27, 90.40/20.16 and 64.69/21.49 ms. Peak RSS ranged up to
about 242 MiB. Raw reports and pooled percentiles are under `native-mac/`.

The 12-case `updateLayer` follow-up also completed; it removed surface draw callbacks but did not
remove the transaction-flush stall. All full-case gates remain failed. The offscreen layer-tree
oracle initially passed 25 control and 31 paired checks with exact composited pixels. Its export
coordinate orientation was subsequently corrected for readable snapshots; the corrected snapshot
probe still needs rerunning. The backing variant remains default-off. Full results are retained
under `native-layer/`.

The subsequent [native pixel-buffer experiment](../calendar-native-surfaces-20261009/README.md)
uses CoreVideo/IOSurface-backed layer contents and shows a substantially larger native improvement,
with remaining cold-mount and dense-page failures retained.
