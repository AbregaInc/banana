# Calendar move journal foundation — October 10

Status: **tested foundation; not yet wired into Calendar actions.** The existing
move failure still rolls back with a transient alert. Full integration is incomplete.

Inspection confirmed that `PendingCalendarWriteStore` persists creations only;
`PendingEventEditStore` and `SmartScheduleStore.moveMeeting` do not preserve failed
moves across relaunch. The new `CalendarMoveJournal` uses Foundation atomic writes
on an actor, with one file per pending operation. Enqueue/acknowledgement do not
rewrite a whole calendar history or the entire pending-operation collection.
No external persistence library is needed for this small independent journal;
the repository already uses Foundation atomic files for pending creations.
[Apple documents atomic writing](https://developer.apple.com/documentation/foundation/data/writingoptions)
as the native primitive. It does not establish power-loss/fsync guarantees.

A pending move retains the absolute requested time, original event identity,
original times and recurrence scope. Before any provider mutation, the caller
must persist its resolved calendar/account, exact event/series target, absolute
start/end and expected ETag. Preparation cannot later silently change that target.
A recovered request checks the target: exact destination already present means
no replay; unchanged ETag permits a conditional write; any other version conflicts.
[Google's version documentation](https://developers.google.com/calendar/api/guides/version-resources)
supports conditional `If-Match` updates. Provider wiring must use that header,
not just a preflight comparison that can race with another editor.

The strict-concurrency optimized Foundation test passed **24 checks**. Tests cover
relaunch, acknowledgement, concurrent enqueue, conflicting IDs/preparations,
corruption preservation, failed storage, lost-response reconciliation and changed
remote data. `reconciliation-report.json` retains all 100 timed atomic enqueue
samples. This is a component cost only, not a before/after speedup or UI acceptance.
The earlier 14/19-check stages are retained under `.build/calendar-move-journal-20261010/`.
No UI behavior changed in this foundation pass; the prior app component/UI result
must not be presented as validation of a future integration.

Next required integration: journal before dispatch, persist the resolved provider
request before mutation, conditional replay/reconciliation, visible durable retry
and discard after relaunch, and local-write failure handling. Recurring
"this and following" requires a separate multi-request transaction plan; a single
PATCH record must not pretend to cover that operation. Drag currently offers
this occurrence or entire series. Retain the full existing behavior and tests.
Then rerun controlled drag comparison, correctness/relaunch tests and the persistent
component suite. Week/Agenda/Mac adoption and physical frame/input acceptance remain
open, followed by Mail optimization.

The subsequent optimized iOS app build passed with the journal included. The full
persistent component suite passed all eight cases, terminal exit 0, unchanged
baseline/budgets (`component-gate.json`, `component-measurements.json`). This proves
build compatibility and those component checks, not recovery UI/provider behavior:
the journal still has no live caller. No new physical-device latency claim is made.
