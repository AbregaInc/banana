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

`testDefaultVariedDayArtwork` and `testDefaultVariedWeekArtwork` specifically
exercise the Beta event renderer without an opt-in flag. They assert 36,500
installed varied events, 12 calendars, distinct daily/weekly patterns, a native
collection viewport, visible prepared artwork before and after scrolling, no
explicit preparation failures, and the exact selected event's detail. Screenshots
and workload metadata are retained. These are functional checks, not timing
acceptance; they do not cover live Google sync, writes, VoiceOver or rotation.
An empty normal Calendar cannot satisfy these populated-event checks.

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
