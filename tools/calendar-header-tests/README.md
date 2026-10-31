# Calendar header delivery

Run `python3 tools/calendar-header-tests/run.py --out NEW_DIRECTORY` on Mac.
The runner extracts the actual coordinator delivery policy from WeekView and
compiles it without UIKit or the service graph. Checks cover synchronous input,
coalescing during representable and UIKit layout updates, superseding stale offsets, dismantling
and weak coordinator lifetime. Calendar-core CI runs the same checks.

The JSON retains callback overhead samples and main-queue delivery delays. These
are component measurements, not header presentation, frame or input latency.
Use an idle host for comparisons; keep contended runs but label them explicitly.

Real-app `testNativeWeekRotation` and `testNativeWeekNavigation` exercise width,
pinch and page updates. The DEBUG-only `testReferenceWeekHeaderPublication` uses
`--calendar-reference-header-publication` to restore synchronous publication from
view updates. Compare reference/native/native/reference with the same binary;
inspect xcresult runtime warnings as well as functional passes. A reference pass
with the expected warning is a control, not production acceptance.

After an optimized DEBUG `build-for-testing`, collect on a booted test Simulator:

```sh
python3 tools/calendar-header-tests/compare-app.py --device SIMULATOR_UDID --out NEW_DIRECTORY
```

Recheck existing result bundles without rerunning:

```sh
python3 tools/calendar-header-tests/compare-app.py --verify-only --out EXISTING_DIRECTORY
```

The comparator requires exact test counts, zero skips, the expected reference
warning and no publication warning in the candidate/integration runs. It leaves
Simulator lifecycle and the separate full persistent component suite to the caller.
Do not rebuild or modify the binary during collection. Retain all failed bundles.
