# Location-service startup regression

Use optimized DEBUG audit builds on a dedicated, already booted Simulator. This
collector installs each supplied build on that Simulator and replaces only the
stress collector's prior report. It never targets physical devices or the Mac app.
Keep both build directories and use a new output directory for every run.

```sh
python3 tools/onboarding-location-tests/profile-startup.py \
  --device FIXTURE_SIMULATOR_UUID --before BEFORE.app --after AFTER.app \
  --out NEW_RESULTS_DIRECTORY --pause-location-service
```

The controlled fault temporarily stops the selected Simulator's `locationd` and
resumes it in `finally`, including interruption/error paths. Do not use a Simulator
someone else is using. Omitting the flag measures the normal service condition.
The sequence is before/after/after/before. Every run retains its binary identity,
30-day workload report or 30-second timeout and blocked-process sample, screenshot,
launch arguments and collector identity. A candidate timeout or wrong workload
returns failure; baseline failures remain visible comparison outcomes.

This tests whether scene/fixture startup depends on a synchronous location-service
reply. Launch-to-report time includes fixture construction and component queries;
it is neither first-frame latency nor a UI budget acceptance measurement. It does
not test the underlying daemon, permission-dialog behavior or live weather accuracy.
The app's normal XCUITest readiness, mode switching and event-selection assertions
remain required after service recovery. Keep failed runs and do not relax budgets.

For a recurring regression-only check, pass the same candidate app to both build
arguments. A complete dataset must load even while locationd is paused. Exit 0
means candidate startup succeeded, 1 means a candidate timeout, and 2 means
incomplete/reordered evidence or a workload mismatch in either build. The verdict
checks run in the existing CI `tools/tests` discovery suite; the Simulator fault
collection itself requires the explicit command above.
