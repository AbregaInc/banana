# L3 — Tasks (Apple Reminders)

Status: **design only, not built.** Builds on [L1](L1-occurrence-model.md) and
[L2](L2-exceptions.md).

## Purpose

Bring to-dos onto the same timeline as everything else — as `Occurrence`s with
`behavior == .task` — in three states: an **unscheduled inbox**, **deadline-driven**, and
**placed into a concrete time**. Tasks are the canonical *moveable* workload the L4
scheduler arranges.

## 1. Source & binding

- Backed by **Apple Reminders via EventKit** (`EKReminder`). Read: title, due date/time,
  priority, list, notes, completion, recurrence.
- `source == .authored`, but ingested from Reminders the way external events are ingested
  from Calendar. Each reminder maps to a task `Occurrence` and carries a stable `AppItemID`
  marker (in the reminder's notes/url), mirroring L1's calendar round-trip identity, so the
  app recognizes its own scheduling metadata and never double-counts.

## 2. Task states

| State | Has a time? | On the timeline? | Calendar event? |
|---|---|---|---|
| **Inbox** (unscheduled) | no | no — lives in a task inbox | no |
| **Deadline-bound** | due date only | shows as a deadline marker | no (until placed) |
| **Placed** | concrete block | yes (`.task`/`.block`) | **yes** — Busy, per L1 decision 4 |

## 3. Scheduling metadata (feeds L4)

`EKReminder` has no duration/window fields, so the app stores per-task scheduling metadata
via the `AppItemID` marker:

```
TaskSchedulingMeta
  estimatedDuration
  deadline        // from the reminder's due date
  priority        // from the reminder
  preferredWindow // e.g. mornings, work hours
  moveable = true // tasks default moveable (unlike events/cues, which default sticky)
```

Per-behavior sticky defaults: **events and cues default sticky; tasks default moveable.**
A user can pin a task (make it sticky). This is the one place the global "sticky by default"
is intentionally overridden per behavior — noted as an assumption; easy to flip.

## 4. Two-way sync

- **Completion:** completing the placed block marks the reminder done; completing it in
  Reminders removes the block (and its calendar event).
- **Deadline:** the reminder's due date stays the source of truth for *when it's due*; the
  placed block is a separate calendar event for *when you'll do it*. (Optionally reflect the
  chosen start back into the reminder — deferred.)
- **Recurring reminders:** each occurrence is a task instance; per-instance skip/move flows
  through the [L2](L2-exceptions.md) exception store.

## 5. Promotion / demotion flow

- **Inbox → placed:** either manually ("schedule this") or pulled in by **Re-plan**
  ([L4](L4-scheduler.md)), which drops placeable tasks into open time before deadlines.
- **Placed → inbox:** un-placing a task deletes its calendar block and returns it to the
  inbox. No commitment is ever silently dropped (see L4 legibility rules).

## 6. Out of scope for L3

- The placement algorithm itself — [L4](L4-scheduler.md).
- Native (non-Reminders) task store — not planned unless Reminders proves insufficient.
