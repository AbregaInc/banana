# Crash and performance reports

Decided 19 Oct 2026, for the App Store release. Apple's Organizer shows crashes, hangs and energy
only for people who opted in to sharing with developers, a day or two late. Banana sends its own
copy of the same MetricKit reports to the Banana service, anonymously, only after the person enables
Settings › About › Share usage. An absent setting is off.

## What goes

`DiagnosticReports` (Banana/Model, iPhone, iPad and Mac) subscribes to MetricKit:

| Kind | From | Signature |
|---|---|---|
| `crash` | `MXCrashDiagnostic` | exception type, signal, code, termination reason |
| `hang` | `MXHangDiagnostic` | |
| `cpu` | `MXCPUExceptionDiagnostic` (the background-kill class) | |
| `disk` | `MXDiskWriteExceptionDiagnostic` | |
| `metrics` | the daily `MXMetricPayload`: launch, responsiveness, battery, memory, storage | |

Each report is MetricKit's own `jsonRepresentation()`: call stacks as binary UUIDs and offsets,
timings, device model, OS, region format, the app's build. A batch adds platform, channel
(App Store, TestFlight, dev), version and OS. Never the account's session, so nothing ties a report
to a person; the service keeps no address.

Reports wait in `diagnostics-outbox.json` (Application Support, newest 20, each at most 60 KB) and
go ten at a time on launch, on coming forward and as MetricKit delivers. Turning Share usage off
throws away what waits. `Metrics` (iOS) still writes its own reading into the playback journal.

## The service

`POST /v1/diagnostics` (`Service/src/diagnostics.js`): an allow-list like the usage batch; a
report off the list or over 64 KB is dropped alone; at most 20,000 a day across everyone (a flood
stops there, 429). Rows in `diagnostics` (migration 0008); the 15-minute job deletes them after
90 days.

To read them: `npx wrangler d1 execute DB --remote --command "SELECT kind, signature, version,
COUNT(*) FROM diagnostics GROUP BY 1, 2, 3 ORDER BY 4 DESC"` from `Service/`. A crash's
`payload` is the call-stack tree: symbolicate with `atos` against the dSYM of that build
(docs: crash stack symbolication).

## Declared

App Privacy: Crash Data and Performance Data, Analytics, not linked, no tracking. The privacy
policy's "Crash and performance reports" section goes live with the first build that sends them.
