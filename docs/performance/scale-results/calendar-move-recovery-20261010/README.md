# Calendar move recovery integration — October 10

Status: **occurrence/entire-series move path connected; iPhone/iPad Simulator recovery checks and final persistent component suite pass.**
Full Calendar renderer adoption and physical performance acceptance remain incomplete.

`SmartScheduleStore.moveMeeting` now durably records occurrence/series moves before
provider work. A resolved target (including a series master), account, absolute
times and ETag is persisted before dispatch. Retry checks that exact target:
already-applied times retire the intent, unchanged version permits an `If-Match`
PATCH, and other versions conflict. The patch changes only start/end. Failed or
uncertain writes retain their operation; a failed local enqueue retains an
explicitly unsaved in-memory draft and calls no provider. Another conflicting
move for the same event is rejected until the first is resolved.

Plan now exposes a Calendar Moves recovery list after a failure. It survives
leaving the view, dismissal of the transient error, and relaunch. Retry preserves
the operation identity; discard requires confirmation and explains that it does
not undo a remotely accepted change. Disk IO/encoding stays on the journal actor.
The existing `futureEvents` multi-request move remains on its old provider path;
this is a separate open durability gap, not covered by a single PATCH journal.
The drag UI offers this occurrence or entire series, both using the new path.

## Evidence

- Optimized strict-concurrency injected-provider tests passed **14 checks**:
  persist-before-provider, prepare-before-dispatch, failed prepare, uncertain send,
  relaunch with an immutable target, reconciliation, local-storage failure,
  conflicting pending intent, and explicit discard. No real accounts/network.
- `initial-moves.xcresult`: **2/2 passed** (short and beyond-viewport moves), no skips.
  Both measured **6→8 WeekView render counts**, matching the prior two-redraw
  result despite durable failure recovery. Counts are not frame/input latency.
- `relaunch.xcresult`: **1/1 passed**, no skips. The real app dragged the same stress
  event, dismissed the failure, exposed recovery, relaunched, restored the exact
  operation ID, retried to a retained failure, discarded, and relaunched again
  without the pending operation. Drag count remained 6→8.
- The test uses a UUID-scoped journal directory only with DEBUG + stress arguments;
  other fixture stores keep per-process isolation. Provider fixture lookup rejects
  before account restore/networking. No real calendar was written.

A later source correction invalidates cached events when reconciliation finds an
already-applied move, as well as after a successful PATCH. Initial UI tests used
the preceding binary; their fixture rejects before that live-provider branch.
Subsequent checks are recorded below. Source identities and raw
reports are retained here and under `.build/calendar-move-recovery-20261010/`.

Live Google account/recurring-series behavior, native Mac UI, physical 120 Hz
frame/input measurements, local-storage-failure UI and the multi-request following
scope are not established by these checks. Existing prepared iPad Agenda and cold
query failures remain separate retained evidence. No baseline or budget changed.


The iPad Simulator run passed **3/3 checks**, no skips: beyond-viewport move,
recovery/retry/discard with two relaunches, and paging/zoom. Move render counts
remained 6→8. The first integration component suite passed all eight cases,
terminal exit 0, unchanged baseline/budgets; raw data is retained as
`first-component-measurements.json`. The native arm64 AppKit build passed.
The initial Simulator builds/tests preceded small live-provider response validation/GET-URL fixes;
the fixture never enters those network branches. Final results follow below.

The lifecycle checks are now part of the calendar-core CI job. Full-app stress
fixtures are currently compiled only for Simulator and Mac. Extending safe storage
and provider isolation is required before full-app fixture tests on physical iOS.
The connected spare phone is present in `devices.json`; availability is not an
unlocked-device or successful UI-test result. No test was launched on it here.


## Final verification

- The final real-iOS-SDK arm64 Release + DEBUG build passed with signing disabled;
  nothing was installed or launched on a physical phone. The fixture guard now
  matches the Simulator/Mac-only availability of `ScaleStress`.
- The final Simulator build and all **eight** component cases passed, terminal exit
  0. `final-component-gate.json` and `final-component-measurements.json` retain the
  unchanged gate, binary identity, all samples and host monitoring.
- Xcode emitted non-terminal widget/Watch compiler diagnostics saying “failed with
  exit code 0” during that build, alongside warnings. The build itself returned 0
  and the suite completed. The raw log is retained; no unsupported cause is assigned.
- `final-relaunch.xcresult` passed the recovery scenario again on the final binary,
  **1/1, no skips**, including both relaunches and a retained failed retry. The drag
  render count remained 6→8. Exact source hashes are in `final-source-identity.json`.
- `recovery-sheet.png` was inspected: event title, destination, recovery explanation,
  Retry, Discard and Done are visible and unclipped in the native sheet/List layout.
  This is iPhone visual evidence; the iPad run provides interaction evidence.

No optimization or physical latency improvement is claimed from journal timing or
XCTest duration. Live provider/API behavior, physical-device UI latency, native Mac
UI behavior, the following-scope transaction, and full renderer adoption remain open.
The next renderer step is default native Day adoption and remaining Calendar views,
followed by Mail. Physical full-app workload tests first need device-safe fixture
support; the standalone physical renderer benchmark does not substitute for it.

Cleanup shut down both owned Simulators and removed 32 temporary stress/recovery fixture directories (4.306 GiB logical). Workspaces, binaries, reports and prior failed-query databases were preserved.
