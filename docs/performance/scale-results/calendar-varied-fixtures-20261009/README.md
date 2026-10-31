# Varied calendar fixtures and concurrent fill correctness — October 9

Status: correctness fix validated offscreen; performance acceptance remains open.
This is the isolated calendar benchmark, not a shipping renderer replacement.

## Why the workload changed

The original `uniform-v1` fixture repeats daily start/duration/overlap patterns and
uses one calendar color. IDs and dates were unique, and raster cache keys include
page dates, but these facts do not make the repeated geometry representative.
The historical fixture remains unchanged as a control; its results cannot certify
varied, multi-calendar performance.

`--fixture varied-v1 --seed 20261009` introduces 12 calendar identities/colors,
busy/quiet days, different daily overlap patterns, 12 durations, overnight/36-hour
events, and short/long multilingual titles. Each seven-day block retains exactly
seven times the requested average daily density; the partial final block preserves
its proportional total. A five-day viewport is not a seven-day week. Reports include
actual minimum/maximum/mean daily volume, weekly totals, diversity counts and a stable
content checksum. Reproduction also requires the recorded calendar time zone. Durations
are intentionally adversarial: 24-hour and 36-hour timed events are two of the 12
duration choices, rather than a claim about a typical user distribution. `--hidden-calendars 1,3,5` filters presentation, retaining the source
history. Runners reject missing/ignored fixture configuration.

This is an immutable timed-event fixture. Recurrence expansion, true all-day layout,
provider synchronization, and dynamic edit/filter cache invalidation remain outside
its scope. It supplements rather than replaces the existing workload.

## Failure and reduction

The exact-pixel async oracle found incorrect calendar-color strips with two workers;
one-worker repetitions passed. The failure reproduces outside the app, tile cache,
Core Text and layers: `colors-large.swift` creates independent Core Graphics bitmap
contexts and draws antialiased colored rectangles concurrently. The environment is
macOS 26.6.2 (25G83), Xcode 27.0 (27A266a). This isolates an observed drawing-path
concurrency failure; it does not establish an Apple-confirmed framework diagnosis
or that all OS versions/platforms fail identically.

Eight 200-image micro runs retained in `micro-matrix.json` found failures in the
original, flush-after-fill, and alternate BGRA paths. Disabling antialiasing avoided
failures in that probe but changes pixels and was not adopted. Copying colors and
removing text also failed; diagnostic artifacts remain in `.build/calendar-varied-fix/`.

A shared lock around event color assignment/path fill preserves the original pixels
while geometry/text preparation stays parallel. Four initial varied runs passed,
then all 24 matrix cases passed 1,106 checks each (26,544 total): uniform/varied,
day/week, 100/300 average events/day, CGImage/CVPixelBuffer/native text. Cold, warm,
eviction, cancellation, supersession, bounded cache and exact-pixel checks remain.
The lock is local to the benchmark renderer, not a general synchronization guarantee
for unrelated drawing elsewhere in an application.

Independent fixture tests passed 11,513 assertions. An independent CGContext swatch
oracle passed 2,400 interior pixel comparisons for all 12 distinct colors. Its first
version incorrectly assumed arithmetic RGB compositing matched color-managed drawing;
that test-authoring failure is retained locally. The exact async pixel oracle was
never relaxed. These checks are now included in persistent CI.

## Measured cost of the first fix

`lock-cost/` contains three alternating before/after trials, both densities and
fixtures, with cold/warm/eviction, memory and host monitoring. The host monitor saw no
overlapping developer processes; its one-second sampling can miss short activity.
These are offscreen preparation measurements, not input/display response times.
The before binary has known wrong-pixel failures and is not an acceptable fallback.
The tables pool 393-point/3× and 1,200-point/2× offscreen widths over seven page
positions and three repeats (42 samples per phase). Raw rows retain each width/page.

| Fixture, average/day | Cold median before → locked | Cold maximum before → locked |
| --- | --- | --- |
| Uniform 100 | 16.750 → 25.179 ms | 21.510 → 28.486 ms |
| Uniform 300 | 33.139 → 46.568 ms | 41.815 → 64.716 ms |
| Varied 100 | 27.244 → 33.299 ms | 51.058 → 73.056 ms |
| Varied 300 | 72.807 → 78.653 ms | 154.086 → 147.601 ms |

The lock is a correctness repair with a measured cost, not a speed improvement.
A separate `--batch-event-fills` experiment batches event backgrounds under one
lock per tile, then draws clipped labels in parallel. It passed all 18 additional
oracle cases (19,908 checks), including a second seed, against the original
interleaved fill/text reference. It remains **default-off** because the cost results
below include a worse eviction tail. No baseline has been raised, scenario removed
or failed run discarded.

## Batched-fill ablation (not adopted)

Three alternating repeats in `batch-cost/` compare per-event locking with batching.
The host monitor saw no competing developer processes. Cold medians decreased:
uniform 100: 26.816 → 18.691 ms; uniform 300: 47.173 → 32.319 ms;
varied 100: 34.189 → 28.902 ms; varied 300: 77.351 → 68.503 ms.
However, uniform 300 eviction maximum increased **67.759 → 94.189 ms**. That sample
also had a 30.637 ms heartbeat gap and 0.362 ms measured main sections; this does not
establish the cause or justify discarding it. Varied 300 eviction maximum decreased
106.854 → 80.663 ms. Warm medians stayed 0.014–0.018 ms; full tails remain retained.
Peak RSS increased by roughly 0.1–0.3 MiB across these cases; maximum footprint
increase was about 0.5 MiB. The visible-event tuple buffer is bounded by page volume,
not retained history. These are component measurements, not UI acceptance.


The physical iPhone passed varied 300/day paging, scrolling, cache clearing and
return-navigation correctness using the per-event lock (binary SHA in the retained
summary). Its screenshot visibly contains multiple calendar colors and different
column shapes, but the deliberately dense week view has unreadably narrow event
columns. This benchmark is not a finished product layout, and geometry coverage
is not a claim of usable labels at that density. Physical iPad launch was rejected
because the device relocked; launch failure and summary are retained.
The full-app persistent component suite completed all eight cases and **failed**
against unchanged baseline v1 (`app-regression/gate.json`). Plan notes-search p95
was 50.631 ms versus 19.235 + 2.885 ms; podcast download-candidate median was
26.026 ms versus 23.332 + 2.333 ms. Mail is unverified because process monitoring
timed out after two seconds, not because a competing developer process was seen.
All samples remain retained. These app paths were not modified by this benchmark
change; that does not excuse or turn the failed validation into a pass.
Neither these offscreen checks nor touch automation certifies 120 Hz or input latency.
No supported maximum event volume has been established; see the
[event-capacity search protocol](../../event-capacity-search.md).

## On-device byte comparison

`test-device-raster.py` runs the shared `--check raster-pixels` probe on a physical
device. It compares 96 concurrently rendered tiles with serial references per case,
validates fixture configuration/density and rendering policy, and retains all pending
cases if launch or collection fails. This separates pixel correctness from touch
navigation and performance acceptance.

The iPhone15,2 on iOS 27.0.1 (24A446) passed all eight cases, **768 exact byte
comparisons**, at 100/300 average events/day with CGImage/CVPixelBuffer and default/
batched fills. The final-source desktop checks also passed both 1,106-check async
oracles and both 96-check shared-probe cases. Native Mac and signed iOS builds passed.
These results do not make the default-off batching experiment a performance pass.

```sh
python3 tools/calendar-library-benchmark/test-device-raster.py \
  --device YOUR_DEVICE \
  --app .build/calendar-library-touch-dd/Build/Products/Release-iphoneos/CalendarLibraryBenchmark.app \
  --out .build/calendar-device-pixels-NEW --fixture varied-v1
```

The signed app must already be built from the corresponding sources. For the shared
host probe, compile `Shared/*.swift` with `FixtureTests/concurrency.swift`; persistent
CI runs both default and batched variants. The physical runner needs an unlocked
device and installs only the isolated benchmark bundle.

## Bounded text reuse experiment (default-off)

A late Time Profiler capture of a dense physical iPhone case included PreparedText
construction in 2,712 of 4,296 samples, including foreground and prefetch workers.
The retained `late-profile-cpu-summary.json` describes sampled stacks, not exclusive
CPU time. The case originally exceeded the 90-second collection deadline; its late
report may overlap profiling and is diagnostic only. It must not replace the timeout
in `iphone-matrix/`. The initial matrix measured three 100/day cases, timed out on
three 300/day cases and left twelve cases unmeasured. No overall acceptance passed.

`--memo-raster-text` reuses immutable prepared glyph data within one sequential
preparation job/worker, using Swift Dictionary and the existing Core Text path.
Each memo is capped at 1,024 entries and 4 MiB logical payload, is released with its
job, and renders misses uncached once full. Logical payload excludes allocator and
framework overhead; it is not a process-memory ceiling. Font/color styles are fixed
per memo and checked, hour and event labels have separate namespaces, and the native
CTLine experiment is incompatible. There is no cross-job/global mutable text cache.

All 16 initial async oracle cases passed 1,106 checks each (17,696 total), plus 33
memo-specific correctness/capacity/style checks. Physical iPhone memo pixel coverage
passed all eight cases / 768 exact comparisons (`iphone-memo-pixels/`).

Three paired local repetitions are retained in `memo-cost/`, including every cold,
warm, eviction and memory sample. At varied 300/day with two workers, cold median
fell 106.21 → 86.68 ms but maximum worsened 247.20 → 321.82 ms; eviction median fell
104.62 → 89.10 ms but maximum worsened 172.10 → 321.71 ms. Peak RSS rose about
58.09 → 61.86 MiB. Uniform 100/day with one worker showed no median benefit.
These noisy, mixed tails do not support adoption or a baseline reduction. The
experiment remains off by default. This initial local binary predates the subsequent
synchronous-install memo hook; device comparisons record the final binary separately.

## Foreground collection protocol

Dense collection timeouts are not yet explained. A report appeared after profiler
attachment; suspension/auto-lock is a hypothesis, not an established diagnosis.
The isolated iOS harness now waits up to ten seconds for foreground activation,
disables its idle timer only during the automated run, restores its previous value
on return, and records foreground lifecycle transitions and stage elapsed times.
This follows [UIApplication idle-timer guidance](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled).
The device runner rejects inactive/interrupted or missing-protocol reports. Earlier
timeouts remain failures/incomplete evidence. The 90-second collection deadline and
all UI budgets are unchanged. Foreground control improves measurement validity; it
is not an app-rendering optimization or evidence of display delivery.

### Matched physical iPhone pairs

`iphone-memo-paired/` retains three alternating on/off pairs from one signed binary,
varied seed 20261009, 365 days × 300 average starts/day, five-day week view, two
foreground workers. All six collections completed in approximately 30–32 seconds
with zero recorded lifecycle transitions; each kept the original 90-second deadline.
This is consistent with the foreground-protocol hypothesis but does not retrospectively
prove why the original runs timed out. Each run still **fails performance acceptance**.

| Phase | Control maximum across three runs | Memo maximum across three runs |
| --- | ---: | ---: |
| Cold mount | 126.97 ms | 87.42 ms |
| Uncached page | 145.82 ms | 108.34 ms |
| Memory-pressure page | 113.08 ms | 72.10 ms |
| Programmatic scroll offset | 47.86 ms | **68.91 ms** |
| Rapid forward page | 107.84 ms | 68.16 ms |
| Rapid return page | 112.38 ms | 72.48 ms |
| Async request-to-publication (all foreground phases) | 103.59 ms | 96.67 ms |

The consistent cold/paging reductions support a benefit in those operations, not
universal non-regression. The worse scroll maximum is retained. Samples are API/
layout/flush or async publication timing, not displayed frames or physical input
latency. Phone process memory was not sampled in these pairs; local memory-probe
tradeoffs above remain the available evidence. A background Mac compile overlapped
part of collection; these are device-side durations, but the paired wrapper did not
record a host monitor. Device thermal/power state and binary SHA are retained in
raw reports. No baseline reduction or default enablement is justified yet.

The final memo build also passed the physical iPhone touch correctness suite
(`iphone-memo-touch/`, binary SHA `10e4d2cea9cb53902f5cf10df17ae44a5683ff0a58f128327e5daef1f1eb9ad5`),
covering paging, scrolling and recovery. The final shared async oracle passed
1,106 checks after the synchronous-install hook. Native AppKit compilation passed;
no visible Mac timing run was performed during this background session. iPad remains
unmeasured after its locked-device launch failure. Python checks: 41 benchmark-runner
tests and 30 root performance-tool tests passed. Physical frame delivery and
input-to-visible latency remain unmeasured for these new varied-fixture changes.

## Bounded full-app repeat: still failing

One complete repeat, reusing the compiled app, is retained in `app-regression-repeat/`.
All eight host-monitor reports were complete and found no competing developer process;
this does not exclude other system activity. The unchanged baseline gate **failed**.
At 90 days, notes-search p95/max was 124.744 ms, podcast next-across-catalog was
238.605 ms and download-candidates was 283.114 ms, all exceeding the absolute
component ceiling. Other relative regressions appear in the retained gate, including
Mail first-page p95 15.593 ms. Both complete runs remain available; the second does
not replace the first. No retries-until-pass, baseline changes or result exclusions
were applied. These findings require profiling the existing notes/podcast query
paths separately; their cause has not been established by this calendar experiment.

Final cleanup shut down and erased the owned test iPhone simulator and removed
0.69 GiB of rebuildable intermediates/module/index caches. About 120.7 GiB was
free afterward. Workspaces, worktrees, binaries, traces and results remain. An
unrelated booted iPad simulator was left untouched; see `cleanup-final.json`.
