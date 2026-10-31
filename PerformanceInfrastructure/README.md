# Device performance runs

This harness separates three product behaviors instead of treating one idle number as an app
performance result:

- `planner.refresh` (silent): reads the device's real Calendar and Reminders data and runs Banana's
  production occurrence materialization. It explicitly disables calendar write-back and alarm
  scheduling, then transitions to locked standby.
- `playback.local` (audible): runs the production player against one local fixture, including
  episode advance and progress commits while locked.
- `control.idle` (silent): measures only harness/process overhead. It is a control, not evidence
  that the planner is fast or efficient.

The planner phase records its own duration, CPU, footprint, wakeups, syscalls, context switches,
agenda event count, occurrence count, and reminder count. Its phase boundaries are written to
`events.ndjson` so the same interval can be selected in Apple's Power Profiler trace.

The fixture is stored once in Banana's download directory. Every synthetic episode maps to that
same filename, so an eight-hour run does not multiply audio disk usage. Use a 30–60 minute spoken
podcast file; the harness refuses fixtures that would require more than 64 auto-advanced episodes.

Both silent scenarios leave audio untouched. Once the planner workload finishes, iOS should
suspend Banana while the phone is locked; that suspension is itself the expected standby result,
not an active-workload benchmark. UI responsiveness and rapid reminder toggling need short,
unlocked interaction traces and must not be inferred from an overnight standby trace.

## What each run records

The app writes a versioned bundle under `Documents/PerformanceRuns/<run-id>`:

- `manifest.json`: code, fixture, device, OS build, and starting conditions.
- `events.ndjson`: ordered scenario, phase, and one-minute sample events.
- `result.json`: pass/fail/invalid status and cumulative measurements.

Samples contain process CPU seconds, physical footprint, interrupt/idle/timer wakeups, syscalls,
context switches, battery level, elapsed time, and raw AVPlayer playing state. The host preserves
raw `devicectl` JSON and validates the bundle without parsing console prose.

Power impact comes from Apple's on-device Power Profiler. Apple documents that on-device traces
can run for up to 10 hours, charging makes overall system power read as zero, and connected Xcode
prevents meaningful sleep/wake data. The playback scenario starts audio while connected; the
planner scenario waits until the cable is disconnected and all baseline conditions are valid
before recording its workload phase. See
[Measuring your app’s power use with Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler).

## One-time device setup

Use iOS 26 or later. `playback.local` requires a dedicated test phone. The silent
`planner.refresh` and `control.idle` scenarios also support an explicitly acknowledged personal
phone: the instrumented build is installed in place without uninstalling Banana or copying an
audio fixture, and its only intentional container addition is the small
`Documents/PerformanceRuns/<run-id>` evidence bundle. Reinstall the normal/TestFlight build after
collection.

1. Enable Developer Mode.
2. Build the host tool with `swift build`.
3. For `playback.local` only, choose a stable 30–60 minute local podcast audio file.
4. Keep Low Power Mode off and use the same device model, OS build, audio route, and system volume
   for every comparable run.

For an audible playback baseline, use the same fixed audio route and volume every time. Never use
that scenario when sound is not acceptable; `control.idle` does not activate an audio session.

## Prepare

List known devices using stable CoreDevice JSON:

```sh
.build/debug/perfctl devices --output /tmp/banana-devices.json
```

Prepare the useful silent planner + locked-standby run on an acknowledged personal phone:

```sh
.build/debug/perfctl prepare-device \
  --device DEVICE_ID \
  --scenario planner.refresh \
  --duration 28800 \
  --sample-interval 60 \
  --settle 60 \
  --personal-device
```

The personal-device path refuses `playback.local` and refuses every `--audio` argument. It still
temporarily replaces the installed Banana binary, because the production container and its real
Calendar/Reminders authorization are what make this product-representative; it does not uninstall
the app or deliberately clear its data.

Prepare the silent idle control if a harness-only comparison is needed:

```sh
.build/debug/perfctl prepare-device \
  --device DEVICE_ID \
  --scenario control.idle \
  --duration 28800 \
  --sample-interval 60 \
  --settle 60 \
  --personal-device
```

Only on a dedicated device, prepare the audible playback run with a single reused fixture:

```sh
.build/debug/perfctl prepare-device \
  --device DEVICE_ID \
  --scenario playback.local \
  --audio /absolute/path/to/podcast.m4a \
  --duration 28800 \
  --sample-interval 60 \
  --settle 60 \
  --dedicated-device
```

The command prints the run directory and exact `launch-device` command.

## Start the on-device trace and app

After installation, on the iPhone:

1. Open Settings > Developer > Performance Trace.
2. Enable Performance Trace, select Power Profiler mode, and enable Banana in monitored apps.
3. Add the Performance Trace control to Control Center if it is not already present.
4. Turn on Airplane Mode, verify Low Power Mode is off, and leave the phone connected by USB.
5. Start recording from the Performance Trace Control Center control.
6. Run the printed host command:

```sh
.build/debug/perfctl launch-device --run-dir /absolute/path/to/PerformanceRuns/RUN_ID
```

For `planner.refresh`, disconnect USB but keep the phone unlocked. Banana prevents auto-lock while
the settling and planner phases run. It will not start the workload until the phone is unplugged,
offline, out of Low Power Mode, and thermally nominal; the screen names any condition still
blocking it. Lock it only after the screen says **Planner refresh complete**. The run does not
activate audio, write calendar blockers, change reminders, schedule alarms, or start cloud
synchronization.

For `playback.local`, audio starts immediately; disconnect during the settling window and lock the
phone. Do not use this scenario where sound is unacceptable. Leave the device uncovered on a hard
surface at room temperature.

## Collect in the morning

1. Stop Performance Trace from Control Center.
2. In Settings > Developer > Performance Trace, share the resulting `.aar` file to the Mac.
3. Reconnect USB.
4. Collect and independently validate the app bundle:

```sh
.build/debug/perfctl collect-device --run-dir /absolute/path/to/PerformanceRuns/RUN_ID
```

5. Archive the raw Apple trace beside the run:

```sh
.build/debug/perfctl import-trace \
  --run-dir /absolute/path/to/PerformanceRuns/RUN_ID \
  --trace /absolute/path/to/exported-trace.aar
```

6. Deterministically expand the `.aar`, import its `.atrc` with the Power Profiler template,
   export the lifecycle/system/process tables, and create `analysis.json`:

```sh
.build/debug/perfctl analyze-trace \
  --run-dir /absolute/path/to/PerformanceRuns/RUN_ID
```

The raw archive and SHA-256 digest remain immutable beside the regenerated analysis. Phase times
in `events.ndjson` identify the active planner interval; lifecycle rows identify foreground,
background, and suspended intervals. Whole-system battery estimates must not be presented as
Banana-attributed drain.

## Interpretation

A run is automatically invalid when thermal state is non-nominal, Low Power Mode is on, the
physical device is charging, the battery level is unavailable, or the audio route changes.
`playback.local` additionally requires offline networking and strict duration tolerance, and fails
if AVPlayer stops or falls off the local source. Silent locked runs report deadline overrun without
invalidating it because a suspended app cannot wake itself merely to write `result.json`.

One overnight run proves the pipeline and gives a useful bound; it does not establish a reliable
optimization win. Compare changes using at least three runs per variant on the same device, paired
in alternating order, and compare medians. Never compare Power Profiler values across device
models.
