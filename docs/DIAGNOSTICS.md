# Banana diagnostics

Banana uses an OpenTelemetry/W3C-style trace model on top of Apple unified logging and
`os_signpost`. It does not require a server.

## What is persisted

`Shared/DiagnosticsTracing.swift` writes two bounded files under the app's `Documents/Diagnostics`
directory:

- `events.ndjson`: structured start, checkpoint, terminal, recovery, and anomaly events. It is
  capped at 512 KB and retains the newest half when rotated.
- `active-spans.json`: an atomically-written map of operations that have started but not produced a
  terminal event.

The directory is excluded from backup. On iPhone and Watch it uses
`completeUntilFirstUserAuthentication` file protection so an already-unlocked device can continue
recording diagnostics while locked.

Every event is also mirrored to Apple unified logging. Every span emits an `os_signpost` interval,
so the same operation and trace ID can be matched in Instruments.

## Process-death detection

At launch, each app creates a new process-session ID. Any active span owned by a different process
becomes a `recoveredIncomplete` event containing:

- operation and trace ID;
- previous process-session ID;
- last checkpoint and its time;
- age since the checkpoint;
- last safe operation attributes;
- memory footprint, thermal state, and Low Power Mode state.

The Watch creates a durable diagnostics outbox entry whenever it recovers an unfinished operation
or validates a critical failure. WatchConnectivity transfers that incident snapshot to the phone.
The outbox survives another Watch-app termination, and the phone retains the ten newest peer
snapshots.

## Instrumented workflows

- Watch workout capture, one resource/sample checkpoint per minute, HealthKit state and failure,
  file creation/compression, Watch transfer, phone decode and durable ingest, and phone ACK.
- Voice-note capture on Watch or iPhone, audio-session route, recorder delegate result, actual
  encoded frame count and playable duration, Watch transfer, phone ingest, Reminders write-back,
  and transcription.
- Calendar-event creation, reminder creation, and cross-calendar write-back.
- Alarm wake playback through podcast or Apple Music.
- MetricKit crash, hang, CPU exception, CPU-limit exit, and memory-limit exit diagnostics.
- Sustained CPU and publisher-storm anomalies from `PerfWatchdog`.

The workout and voice-note trace context travels as W3C `traceparent` metadata through
WatchConnectivity. Voice notes retain it in their Codable/iCloud metadata so later transcription
remains part of the original capture trace.

## Retrieving an incident

On iPhone or Mac:

1. Open **Settings → Diagnostics**.
2. The view contains the local structured journal, automatically received Watch incidents, and the
   specialized playback journal.
3. Use **… → Share diagnostics** or **Copy**.

No tethered Mac is required for this path.

## Power and privacy constraints

- There is no telemetry timer, network exporter, or backend.
- Most operations write only start and terminal transitions.
- A running Watch workout adds one checkpoint per minute; sensor samples are never logged.
- Watch incident files cross the radio only after recovery or a validated critical failure.
- Attribute values are bounded, and event payloads contain state and identifiers rather than event
  titles, note transcripts, contact information, or audio.

## Deterministic verification

`DiagnosticJournalTests` verifies:

- W3C trace-context parsing and parent/child propagation;
- recovery of an operation whose previous process never emitted a terminal event;
- no false incident after a completed operation;
- bounded rotation while retaining decodable events.

Run:

```sh
swift test
xcodebuild -project Banana.xcodeproj -scheme Banana \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Banana.xcodeproj -scheme BananaMac \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```
