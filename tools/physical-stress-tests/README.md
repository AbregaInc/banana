# Physical full-app stress review

This extends the existing app fixture path to a separately signed iPhone/iPad
review app. It does not select an experimental renderer. Normal app targets do
not define `STRESS_DEVICE_AUDIT` and retain their existing behavior.

The review build must define both `DEBUG` and `STRESS_DEVICE_AUDIT`, use bundle ID
`com.boris.banana.stressreview`, and launch with `--disable-icloud`, exactly one
of `--plan` or `--mail`, and `--stress-actionable-calendar --stress-days N`
(N = 1...365). Missing launch
requirements fail before normal AppSupport access. Notes cloud access is disabled,
fixture Google writes are rejected, and fixture stores use a fresh temporary
directory. No Calendar renderer flag is required. This app is not a connected
production-account review build.

For replacement-renderer acceptance, build the fixture from the **Beta** scheme
with `BANANA_BETA` as well as the fixture flags. The normal Beta is the user's
replacement build; the non-Beta app remains their comparison. An isolated fixture
must not replace either installed app or borrow their account credentials.

Run the launch-policy checks separately from performance measurement:

```sh
python3 tools/physical-stress-tests/run.py --out .build/physical-stress-policy-run
```

This runs both ordinary/review configurations and verifies that
`STRESS_DEVICE_AUDIT` without `DEBUG` fails to compile. Calendar-core CI retains
these checks and their logs.
The full iOS app must be compiled and validated on the spare phone and iPad before
claiming this path works; these pure policy checks do not establish build, data
isolation, functional or performance acceptance. Testing a primary phone requires explicit user authorization.

## Physical Calendar UI checks

`project.yml` defines a standalone XCTest runner using the existing
`BananaUITests/ScaleStressUITests.swift`. `PHYSICAL_STRESS_UI_TESTS` binds it to
`com.boris.banana.stressreview`, never the production or Beta app. Install the
separately signed review app first; this runner neither builds nor installs it.
Build this project with automatic signing, then run its generated `.xctestrun`
against an explicitly selected test device. Initial focused cases are
`testNativeWeekInitialSelectedDayVisible`, `testNativeDayCalendarScroll`,
`testNativeWeekCalendarScroll` and `testNativeWeekRotation`. The startup case
checks that today's day-list control lies inside the actual native viewport and
is hittable. Its retained viewport trace diagnoses selection versus actual
position, including the deferred startup width reset; it does not measure latency.

The physical launch helper retains 90 days of Mail, 365 days of Calendar, 5,000
notes and 20,000 podcast episodes unless a case explicitly overrides a flag.
Simulator test workloads are unchanged. The launch guard accepts either the Plan
or Mail fixture route, rejects combining both, and retains the same isolation
requirements for each. `testMailScrollAndOpen` exercises the Mail fixture on a
physical phone; it does not establish live Gmail integration. Further interaction
coverage and real frame/input measurements remain
required; XCTest gesture duration does not establish UI latency.

`testDefaultVariedDayArtwork` and `testDefaultVariedWeekArtwork` exercise the
release-channel SwiftUI event artwork without renderer flags. The corresponding
`testPreparedVariedDayArtwork` and `testPreparedVariedWeekArtwork` cases require
visible prepared images or direct canvases. Both paths check the full 36,500
varied events, 12 calendars, distinct daily and weekly patterns, a populated
native viewport before and after scrolling, and the exact selected event’s detail.
Each retains screenshots and installed workload metadata. The prepared path also
checks for explicit preparation failures.

The physical runner accepts `STRESS_DEVICE_ORIENTATION=portrait` or `landscape`
in its test environment to exercise a flow in a specific window shape. It restores
the previous orientation when the device reported one.

## Day swipe recordings and redraw counts

`testDaySwipesKeepTheTimeInPortrait` and `testDaySwipesKeepTheTimeInLandscape`
drive the same four Day gestures on the phone and iPad. Each starts on a populated
timeline, checks the exact destination date and vertical offset after each swipe,
then compares visible event identities on return. Each restores the starting
orientation when XCTest reports it. The JSON attachment includes viewport geometry
and cumulative counts from SwiftUI and the native collection.

To inspect the transition itself, set `PreferredScreenCaptureFormat` to
`screenRecording` and `SystemAttachmentLifetime` to `keepAlways` in a copy of the
generated test configuration; keep its relative test-bundle paths resolvable.
Retain the original recording privately. The recording uses variable frame
timestamps and may omit long stretches of identical pixels. Analyze motion inside
the timeline separately from controls above it. A final screenshot only shows the
settled page.

```sh
python3 tools/physical-stress-tests/summarize-day-swipes.py day-swipes.xcresult --out day-swipes.json
```

On builds with gesture telemetry, `releaseToSettledMS` measures time from the native drag-release callback
to the scroll delegate's completion on that device. The recording and geometry show what moved during
this interval. Touch-to-first-frame latency requires its own timestamped presentation measurement.


Export one orientation test's attachments with `xcresulttool export attachments`.
The motion analyzer uses FFmpeg, NumPy and Pillow. If the test rotates after
recording starts, inspect an image during a drag and pass `--rotation clockwise`
or `--rotation counterclockwise` to put the text upright.

```sh
python3 tools/physical-stress-tests/day-swipe-motion.py attachments --out motion.json
```

The analyzer counts changed images separately in the event area and the left
32 points of the ruler, during the drag and around release. Its output retains
the number of recorded samples in each interval. Display-rate and input latency
measurements require independent presentation timestamps.

The summary reports the movement of the same hour in window coordinates. It
also reports how many times the app prepared days, applied collection data,
reloaded membership, configured cells and performed layout. A cell configuration
updates content. A body evaluation or layout pass can finish without a pixel change.

### Interrupting a Day swipe

Run `ScaleStressUITests/testConsecutiveDayFlicksDuringTheCoast` in each orientation. Set the runner environment variable `STRESS_DEVICE_ORIENTATION` to `portrait` or `landscape`. The test sends the touches in one XCTest event record so the framework does not wait for the grid to settle between flicks. A finger travels 56% of the viewport in 138 ms and lifts at 145 ms. The next touch starts 115 ms after lift. The sequences include forward paging, reversals and repeated flicks beyond the three reusable columns.

The attachments retain the physical offsets, selected dates, ruler position, returned event identities and native gesture callbacks. At a column change, the old and new offsets must represent the same position on the same date. The first input after the change must still follow the finger. Check the final date as well. The Objective-C event helper is compiled into the physical XCTest runner only and checks the recorder's selectors at runtime.

### First readable Mail paragraphs

Run the physical `ScaleStressUITests` cases for an in-memory body (`testLongMailBodyPresentationAfterARealRowTap`), a reopened SQLite store (`testPreparedMailBodyPresentationAfterADiskRead`) and the retained HTML after its prepared copy has been evicted (`testMailBodyPresentationAfterRebuildingAnEvictedCopy`). The latter two run the production blob reader and parser with an isolated synthetic account. Each case opens the real row, scrolls into the message and returns to the original paragraph. The disk cases require a single read of the selected body after the lift and verify all 1,200 blocks.

Export one test's attachments before running the analyzer. FFmpeg, ffprobe and Tesseract must be on the path.

```sh
xcrun xcresulttool export attachments --path run.xcresult \
  --test-id 'ScaleStressUITests/testPreparedMailBodyPresentationAfterADiskRead()' \
  --output-path prepared-attachments
python3 tools/physical-stress-tests/mail-presentation.py prepared-attachments --out prepared.json
```

The fixture changes five colored squares before the gesture, records their display-link target times, and stops the link. A passive recognizer timestamps the actual row touch. The analyzer matches successive color changes to recording timestamps and finds the first image with section one and at least one of sections two through six. Read the previous frame time, transition spread and selection timestamp together. XCTest's variable recording cadence limits the precision of any one result.

## Plugged-in power during Mail and Calendar runs

For the always-on iPad case, run the following alongside a known review-app fixture.
The M1 measurements used Python 3.12, `pymobiledevice3==11.64.0`, and Xcode's
paired developer connection. The collector reads diagnostics and writes one JSON
line per sample, including the time of an unavailable reading.

```sh
python3 tools/physical-stress-tests/sample-power.py \
  --device '<authorized-device-udid>' --seconds 900 --interval 60 --out plugged-power.jsonl
```

On the tested iPad, `SystemPowerIn`, `SystemLoad`, and signed `BatteryPower` are in
milliwatts. A negative battery reading means the battery is supplying part of the
device load. The adapter's reported wattage is a separate field. Each reading
includes the screen and the rest of the system. To attribute a window to an app,
match it to the fixture's foreground journal and process counters, record charging
conditions, and report startup separately from the settled screen. Preserve individual
readings because plugging in and crossing into full charge change the interpretation.

For a foreground power control, launch the same isolated app with the same `--plan` fixture
and add `--stress-empty-scene`. The app prepares its stores, mounts a system-background surface
and records “empty scene appeared” in its fixture journal. The normal Plan launch mounts the
calendar. Use the same signed build, orientation, brightness and monitoring for both, alternate
their order, and verify foreground journal intervals. A different image on the display can
also change measured whole-device watts. `testEmptyPowerControlPreparesTheSameFixtureWithoutMountingCalendar`
checks the control and waits for the full dataset.

`testDaySwipeRoundTripHitches` measures UIKit scrolling and deceleration signposts over five
forward-and-back Day iterations. It checks tomorrow and the starting date in each iteration.
Use the test environment's orientation override for both phone and tablet and retain each metric's
unit and raw samples. Inspect each result bundle with `xcresulttool get test-results metrics`.

## Integrated Calendar scrolling traces

Build the standalone UI runner after changing its test source, and install the
isolated review app. Then capture a bounded Instruments trace while XCTest
scrolls its real native Day or Week viewport:

```sh
python3 tools/physical-stress-tests/profile-scroll.py \
  --device '<authorized-physical-device-udid>' \
  --instruments-device '<device name> (27.0.1)' \
  --xctestrun .build/physical-stress-ui-dd/Build/Products/PhysicalStressUITests_iphoneos27.0-arm64.xctestrun \
  --mode Week --out .build/NEW-INTEGRATED-WEEK-TRACE
```

The runner permits only the spare phone and test iPad, attaches only when exactly
one `Banana Stress Review.app` process is found, and preserves partial/failed
captures. It reuses the existing bounded Instruments collector and frame reporter.
The physical test requires 36,500 events, 12 calendars and 365 different daily
patterns, then performs 16 up/down pairs. This captures part of a sustained
scrolling session. Inspect actual process attribution, capture/gesture overlap,
schema completeness and refresh rate before interpreting the trace. It does not
measure input-to-visible latency, cold navigation, mutations or concurrent sync.
A successful recording or XCTest result alone is never performance acceptance.

Use the current exact Instruments name/version from `xcrun xctrace list devices`.
A retained attempt using the phone UDID could not resolve a running PID; the
same PID attached using its listed name/version. The runner therefore records
both identifiers explicitly. This is an observed attachment workaround, not a
general claim that Instruments cannot accept UDIDs. The scroll case explicitly
requires portrait before measurement.

Use `--template 'Time Profiler'` for an exploratory CPU capture with the same
interaction case. Resolve symbols using the exact matching app dSYM before
interpreting samples; inclusive stack weights overlap and are not frame timings.
`--cell-host-policy preserve` selects the DEBUG hosting-view reuse ablation;
`clear` is the unchanged default. Both require a rebuilt UI runner and an app
containing the ablation. Keep comparisons matched and validate state identity,
memory retention and gesture behavior before changing the production default.


For supplementary capacity exploration, use `--density 1`, `10` or `30` with
`--mode Day` or `Week`. The default remains 100/day, with its original fixture
assertions intact. Sparse cases assert the requested retained count and weekly
volume, keep 365 calendar days and all other app datasets unchanged, and retain
actual daily extrema, calendar distribution and pattern diversity in the workload
attachment. They use the default cell policy; combining a reduced density with
the reuse ablation is rejected. Rebuild the UI runner before using these cases.

Compare repeated runs on the same installed binary and viewport. The initial
geometry attachment includes the instantiated cell count: an empty visible time
range must not be reported as dense-event rendering acceptance. These traces
sample scrolling only; even a passing sparse trace cannot establish a maximum
supported daily/weekly capacity without representative busy windows, paging,
repeats, cache lifecycle and input-to-visible evidence. Preserve failing densities
and the original 100/day target separately.

## Matched old/new viewport comparison

`compare-viewports.py run` captures, for each of Day and Week, four `profile-scroll.py` traces
in reference/native/native/reference order (`--viewport reference` selects the pre-virtualization
host through `--calendar-reference-day` / `--calendar-reference-week`; the reference host is a
SwiftUI `ScrollView`, so the test scrolls `scrollViews.firstMatch` there). `summarize` prints a
table from each run's `analysis.json`. The first such run is
`docs/performance/scale-results/calendar-viewport-device-20261029/`.

Building the review app on 29 October 2026 (Xcode 27.1): the BananaBeta scheme, Release, with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG STRESS_DEVICE_AUDIT'`,
`GCC_PREPROCESSOR_DEFINITIONS='$(inherited) DEBUG=1'`, `PRODUCT_BUNDLE_IDENTIFIER=com.boris.banana.stressreview`
and `CODE_SIGN_ENTITLEMENTS=tools/physical-stress-tests/StressReview.entitlements` (no HealthKit,
push, iCloud or WeatherKit, so the wildcard team profile signs it without an Xcode account).
Do not override `PRODUCT_NAME` on the command line: it applies to the Swift package resource
bundles too and the build fails with "Multiple commands produce". Instead copy the built
`Banana Beta.app` to `Banana Stress Review.app`, rename the executable, set `CFBundleExecutable`
and a distinct `CFBundleDisplayName`, dump the entitlements Xcode signed into the original
(`codesign -d --entitlements :file`, which carries `application-identifier` and the team), and
re-sign the copy with them; a plain empty entitlements file fails installation with
"missing the application-identifier entitlement". Install with `devicectl device install app`.

## Calendar’s first visible movement

Run `ScaleStressUITests/testFirstVisibleDayMotionDuringARealFlick` with the isolated app on a physical iPhone. Set the runner’s `STRESS_DEVICE_ORIENTATION` to `portrait` or `landscape`. The test alternates four directions, verifies the expected date and saves native touch samples and the viewport at rest. Export the test’s attachments with `xcrun xcresulttool export attachments`. Run `python3 tools/physical-stress-tests/calendar-presentation.py <attachments> --out motion.json` with FFmpeg, NumPy and SciPy installed. It uses the original movie timestamps, follows the event grid separately from the pinned ruler, and preserves the last stationary and first reliably shifted image. The interval between recorded frames limits the precision of the result.
