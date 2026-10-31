# L2 — Exceptions: per-occurrence move / skip / add

Status: **design only, not built.** Builds on [L1](L1-occurrence-model.md).

## Purpose

Satisfy the founding scenario — a recurring pattern plus one-off changes *this week* —
without corrupting the recurring rule:

> Run M/T/W 7 AM, Gym Tu/Th 5 PM, Yoga Sat 11 AM. This week: move Thursday's gym to 7 PM,
> skip Saturday's yoga, add an extra Wednesday gym.

Each of those is a *per-occurrence exception*, and the model must apply the same way to
authored recurrence and to cues bound to external calendar series.

## 1. The exception store

Keyed by the L1 identity `OccurrenceKey = (seriesID, slotID, date)`:

```
Override  = .skip                       // remove this instance
          | .reschedule(newTime|window) // move this instance
          | .modify(behaviorPatch)      // one-instance param change (e.g. different pool)
Extra     = a dated one-off instance added to a series      // iCal RDATE
```

- Stored per series, tiny, and **pruned once the date passes**.
- `.modify` is included for completeness (e.g. "use my sleep-story pool for tonight's
  wind-down only") but can ship after skip/reschedule/extra.

## 2. Resolution (materialization) algorithm

For each series across the ~2–4 week horizon:

1. **Expand** the base schedule/source into candidate instances — a `.clock` recurrence, or
   a source binding (`.calendar` / `.sleepSchedule` / `.firstMeeting`).
2. **Apply overrides** — drop `.skip`; shift `.reschedule`; patch `.modify`.
3. **Union extras** (RDATE).
4. **Emit** resolved `Occurrence`s.

This resolved set is the single input to Today, Up-next, the watch, AlarmKit scheduling,
**and** write-back. Exceptions are therefore applied *before* anything is armed or written.

### External series are special
Events already in the user's calendar carry their *own* exceptions natively — EventKit
expands a recurring event with its per-occurrence edits for free. So the app's exception
store is used for:
- **authored** series (native cues), and
- **cue-bindings layered on external events** — e.g. "skip the cue for just this instance"
  or "arm the pool 10 min earlier this once" *without* editing the underlying calendar event.

## 3. Edit scopes — "this one vs. the series"

Every occurrence edit resolves to one of three scopes (the familiar calendar choice):

| Scope | Effect |
|---|---|
| **Just this one** | Writes an `Override` / `Extra`. Base rule untouched. |
| **This and future** | Splits the series at this date (iCal `THISANDFUTURE`): close the old rule, start a new segment. |
| **All** | Edits the base schedule. |

Edits originate wherever an occurrence is shown — **Today, Up-next, Plan Tomorrow, the cue
editor** — because the occurrence carries the identity needed to write the right exception.

## 4. Interaction with write-back (the key reconciliation)

Since L1 writes *everything* to the calendar, each exception is also a **calendar delta**:

| Exception | Calendar effect |
|---|---|
| `.skip` an authored instance that was written | delete / EXDATE that event |
| `.reschedule` | update the linked event's time in place |
| `Extra` | create a new event (Busy, AppItemID-stamped) |

**A manual calendar edit *is* an exception.** When the user drags an app-written event in
Calendar, the app **adopts** it as an implicit `.reschedule` override (L1: user edits always
win). It records the exception rather than fighting or overwriting it. This is the single
most important reconciliation rule in the layer — it's what makes "write into existing
calendars" coexist with a recurring model.

## 5. Identity & housekeeping

- `slotID` is durable, so an override survives editing/reordering the base slots (you can
  change Gym's base time and the "moved this Thursday" override still points at the right
  instance).
- Prune overrides/extras with `date < today`.
- If an override's base slot is deleted, drop the override (or surface it as "orphaned").

## 6. Out of scope for L2

- Placement of `moveable` items — that's [L4](L4-scheduler.md).
- Task-specific ingest/state — that's [L3](L3-tasks.md).
