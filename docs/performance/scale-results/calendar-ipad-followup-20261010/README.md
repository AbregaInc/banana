# Physical iPad follow-up — October 10

The user reauthorized iPad testing and confirmed no other apps were running.
Device `<device-udid>`, AyePad, iPadOS 27.0.1. The installed isolated
app is the repaired physical stress fixture from the merged-device regression,
not a new renderer. Workload remains 100 varied events/day across 12 calendars,
365 retained days, 180,000 emails, 5,000 notes and 20,000 podcast episodes.

## Test-driver blocker and controlled repair

Original Week attempts repeatedly waited 60 seconds for SpringBoard animation
notifications. Restarting the test session reproduced it. Missing accessibility
services belonged to system `pointeruid`/`druid` processes, not evidence of another
user app. The original recording does not prove sustained-scroll performance.
Retain `week/` and `restarted-week.*` beneath the artifact root below.

`PhysicalSystemIdlePolicy.swift` is an explicit test-runner-only probe. With
`STRESS_SYSTEM_ANIMATION_WAIT=exclude`, it wraps XCTest's process idle selector
and excludes **SpringBoard animation** waits only. App quiescence remains enabled.
Unsupported selectors fail setup. It uses the established selector mechanism in
[WebDriverAgent](https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Categories/XCUIApplicationProcess%2BFBQuiescence.m).
This private XCTest compatibility mechanism may need revision with future Xcode.
It ships in no application target, changes no performance threshold, and defaults off.

The copied `PhysicalStressUITests-system-idle-probe.xctestrun` resides beside the
original so `__TESTROOT__` resolution is preserved. Its runner environment enables
the probe. The unchanged Week artwork test then passed in about 18 seconds,
including real scrolling and opening an event, without 60-second waits. This is
a driver repair, not an app speedup. Original and repaired logs remain available.

## Actual scrolling evidence

Both Day and Week scrolling tests passed; both eight-second Instruments recordings
finalized successfully while the tests scrolled. Both performance gates **fail**.

| View | App update p95 / max | Updates >8.3 ms | Associated render p95 / max | GPU max |
| --- | --- | --- | --- | --- |
| Day | 10.252 / 53.992 ms | 34 / 485 | 8.465 / 24.329 ms | 3.155 ms |
| Week | 5.745 / 77.400 ms | 3 / 494 | 8.861 / 12.293 ms | 3.522 ms |

These are app-attributed update intervals and associated compositor intervals,
not input-to-visible latency or proof of CPU stack attribution. Render intervals
may include waits. Variable display cadence and pipeline lifetime are separate;
neither is automatically a missed 120 Hz deadline. No renderer change was made
between these runs and the preceding phone measurements, and differing devices
are not a before/after comparison. The tail causes still need attribution.

Artifact root: `.build/merged-device-regression-20261010/ipad-priority/`.
`idle-policy-{day,week}-trace` retains xcresults, exact commands, device/process
identity, record logs, raw traces, exported tables and all timing samples.
`summary.json` beside this document retains compact timing summaries.
The component suite was not rerun for this test-runner-only change; the previous
merged-device suite's monitoring failures remain recorded and unresolved.

## Functional completion

`day-mail-correctness.xcresult`: Day artwork/event opening and Mail scroll/open
passed (2 tests, zero failures/skips/runtime warnings), on the physical iPad Pro
12.9-inch fifth generation above. Together with `idle-policy-week.xcresult`,
Day/Week/Mail fixture smoke coverage passed. This does not cover connected Gmail,
all Calendar editing workflows, accessibility, or input latency. The normal
installed Beta was successfully relaunched afterward (`restore-beta.json`);
it was not replaced with a new normal build.
