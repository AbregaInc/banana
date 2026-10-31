# Calendar artwork reference

This is the real calendar event visual tree, isolated from stores and gestures so
prepared/native backends can be checked against production semantics. It is not
the fixture-only tile renderer and is not a UI performance acceptance test.

`LegacyArtwork.swift` freezes the previous desktop/mobile visual trees from
`WeekView.swift` and their decorations. The extraction mechanically substitutes
`CalendarEventPaint` fields for the previous occurrence/provider fields; actions,
blocked-day underlay and the cell's outer accessibility modifiers stay in
`WeekView`. Return captions and location text enter as resolved paint data. This
oracle checks the painting given those inputs, **not the Occurrence adapter or
provider-data correctness**. App UI tests remain required for that integration.
Do not regenerate the reference from a changed candidate after a pixel failure.

Compile/run on macOS without opening a window:

```sh
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  Shared/BananaDesign.swift Banana/Views/FreeIndicator.swift \
  Banana/Views/CalendarEventDecorations.swift Banana/Views/CalendarEventArtwork.swift \
  tools/calendar-artwork-tests/LegacyArtwork.swift tools/calendar-artwork-tests/main.swift \
  -o /tmp/calendar-artwork-tests
/tmp/calendar-artwork-tests NEW_OUTPUT_DIRECTORY
```

The 2,496-case matrix compares exact canonical RGBA bytes at 2x. It covers both
layout branches, light/dark appearance, left/right direction, 28/90/180-point
widths, eight heights spanning every title/time/location threshold, and thirteen
state/text variants. No tolerance or mismatch allowance is used. Images are
exported on failure. Both layout branches use macOS font rendering here; passing
this test does not prove iOS pixels, accessibility, gestures, frame delivery or
input-to-visible latency. Original/candidate render timings are retained only as
diagnostics: fixed order and offscreen execution do not establish a speedup.


## Prepared cache lifecycle and controlled ablations

Compile the cache test with the same shared sources and frozen reference, replacing
`main.swift` with `raster.swift`, adding `Banana/Views/CalendarArtworkRaster.swift`,
and targeting macOS 14. Run the resulting executable with a fresh output directory.
The cache now also references the custom candidate backend: include
`CalendarNativeText.swift`, `CalendarNativeEventRaster.swift` and
`CalendarNativeEventAdapter.swift` from `Banana/Views` when compiling cache or
preparation runners. The default reference checks remain unchanged.
Preparation runners also require `CalendarNativeEventCanvas.swift`, which draws
oversized native event artwork without inserting an oversized cache image.
It validates exact same-API reference pixels, content/environment invalidation,
color reconstruction, LRU/byte limits, clear/eviction recovery and explicit rejection.
The report retains 201 interleaved samples per cache policy, first-use time and
retained cache bytes. These are offscreen main-actor component measurements.

`--cgimage` selects the original export backend for diagnosis. Default preparation
uses the explicit Core Graphics rendering callback. Comparisons across the two
export APIs are reported separately and are **not exact parity passes**.
`repeat.swift`, linked without the cache source, independently repeats A/B/A 60 times;
`--context` selects the explicit callback. This separates image export instability
from cache mutation. Keep failures and never regenerate the frozen reference.


The production preparation coordinator has a separate async lifecycle runner:
compile `preparation.swift` instead of the reference/raster runners, add
`CalendarPreparedArtwork.swift` and `CalendarViewportEnvironment.swift`, and target macOS 15. It checks bounded queue and
consumer ownership, cancellation, then alternates direct, queued and immediate
warm lookup policies. Cold render and every API-completion sample are retained;
none are input-to-visible or frame measurements.

The replacement/cancellation tests inject only the drain scheduler, holding the
real render callback until queue admission is observed. One case deliberately
runs that callback after cancellation but before its actor callback, and requires
a nil result and released consumer bytes. Production still schedules each drain
on the main queue after one millisecond. This avoids relying on a test task seeing
a transient queue before it drains; enqueue observation retains a bounded timeout.

`--calendar-prepared-artwork`
on a DEBUG audit app enables the real-grid comparison; its UI test must observe
a prepared element and open its event detail, not merely accept fallback content.

`profile-app.py --device FIXTURE_SIMULATOR_UUID --out NEW_DIRECTORY` collects
bounded preparation timings from the actual Day/Week app (three alternating pairs
of fresh processes). Build the Release + DEBUG audit app first. The collector
requires an available Simulator and verifies preparation occurred, the queue drained,
no samples were dropped, memory-accounting bounds held and the idle redraw probe
passed. It retains binary/device identity, all timing samples, host activity and
RSS samples. These are individual cache-miss API timings; they exclude queue delay,
full-screen readiness and actual display delivery. Successful collection is not UI
acceptance and must never be passed to the frame/input gate as such.

The raster oracle also checks independent paint height versus canvas height: the
legacy compact Agenda text threshold stays intact inside duration-sized frames.
Both dimensions participate in cache identity. Its Agenda cache ablation retains
201 uncached/warm pairs alongside all original cold/warm/eviction cases.

Mode-switching UI tests must use a writable initial preference. `-planMode week`
overrides later picker writes; selected segments alone do not prove content changed.
Protocol 3 uses `STRESS_INITIAL_PLAN_MODE` only for isolated stress Simulator launches
and asserts the content surface. Fixed-mode fresh-process profiling can continue
using an argument-domain mode because it does not switch modes within the process.


Preparation lifecycle coverage also alternates immediate and one-turn queue admission
while cancelling an obsolete viewport request. It verifies replacement ownership and
queue drainage, and retains every API completion sample. The DEBUG app control flag
`--calendar-immediate-artwork-admission` preserves the immediate-rejection behavior.
The UI runner accepts `CALENDAR_ARTWORK_ADMISSION=immediate` for same-binary checks.
The one-shot idle profile is not an end-of-interaction counter snapshot.

The actual Day viewport experiment can be isolated with `--mode day` and
`--day-viewport native` (default: `reference`). For a controlled comparison, run
four fresh output directories in reference/native/native/reference order with
`--trials 1`, using the same binary and Simulator. The default command still
collects the original Day/Week sequence. This is preparation/ownership evidence,
not scrolling or presentation evidence; run `ScaleStressUITests` native Day
scroll, paging/zoom and creation checks separately.


## Native Day drag redraw comparison

After an optimized `build-for-testing`, run:

```sh
python3 tools/calendar-artwork-tests/compare-drag.py --device SIMULATOR_UUID \
  --xctestrun .build/stress-dd/Build/Products/Banana_iphonesimulator27.0-arm64.xctestrun \
  --out .build/calendar-drag-NEW
```

Runs parent/local/local/parent feedback in one binary, with short and beyond-viewport
moves on the unchanged stress workload. Preserves raw XCTest bundles/logs, exact test
selections, summaries and parent redraw deltas. A nonzero exit reports missing/failed
correctness evidence. It does not gate frame or input latency, update a baseline, or
claim physical performance. Inspect the retained redraw comparison separately.
Use an owned fixture Simulator: the runner reinstalls the app/test runner there.
