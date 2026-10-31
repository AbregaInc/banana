# Implementation Plan — Unified Timeline (L1–L4)

Status: **plan, not built.** Turns [the L1–L4 design](00-overview.md) into sequenced,
PR-sized work against the current codebase. Grounded in the real types as they exist today.

## Guiding constraints (from the current code)

- **Extend, don't rewrite.** `Routine` (`RoutineModels.swift`) stays the authored cue; the
  `Occurrence` layer sits *above* it as an adapter, not a replacement. Same for
  `MeetingInfo` (external) and `WakePlan.Day` (derived).
- **EventKit write is unlocked but unused.** `CalendarService` holds one `EKEventStore` and
  already calls `requestFullAccessToEvents` — full access permits writes, so **write-back
  needs no new permission prompt**, only new code (no `EKEvent` create/`save`/`remove`
  exists anywhere today).
- **Arming has a shape gap.** `AlarmStore` arms **relative weekly** alarms
  (`Alarm.Schedule.relative`, `AlarmManager.shared.schedule`, e.g. `scheduleSmartWakes`).
  One-off overrides/extras/placed items need **absolute one-shot** (`Alarm.Schedule.fixed`).
  The audio bridge (`WakeStopIntent.perform → WakeCoordinator.shared.startWake`) is reusable
  as-is.
- **A proto-materializer already exists.** `SmartScheduler.plan(...) → WakePlan`, driven by
  `SmartScheduleStore.recompute()`, already materializes per-day wake/bedtime and drives
  AlarmKit + `NotificationService`. The `OccurrenceStore` generalizes this one pattern.
- **Persistence conventions:** Application Support JSON (like `routines.json`) for models;
  UserDefaults for small state; seed versioning (`routinesSeedVersionKey`). New stores
  follow these.
- **Single-user (the author only).** No backward-compat / migration ceremony required —
  re-seeding or resetting app-owned stores (`routines.json`, new occurrence/exception
  stores) is acceptable. **The one data-loss guard:** never touch **podcast listen
  progress** (`Podcast.positions`/`completed` in `podcasts.json`, `WatchEpisodeStore`
  UserDefaults, `ListenHistory`) — it's orthogonal to this work and must stay untouched.
  **The one outward-facing / hard-to-reverse operation** is write-back creating/deleting
  events in *real* calendars — gate it behind a dedicated test calendar + explicit go-ahead.

---

## Phase 0 — De-risking spikes (throwaway, no user-facing change)

> **Status: verified in sim** via `Banana/Model/TimelineVerification.swift`
> (`--verify-timeline`), 35/35 checks. See [VERIFICATION-RESULTS.md](VERIFICATION-RESULTS.md).
> P0.1 fully proven (write, round-trip identity, exclusion, edit-detect, delete, native
> recurrence exceptions). P0.2 **API shape proven; runtime firing remains device-only.**
> Two constraints discovered: availability-capable write-target calendar required; reminders
> need `NSRemindersFullAccessUsageDescription` (added).

The two riskiest primitives, proven in isolation before anything is built on them.

- **P0.1 — EventKit write + round-trip identity.** Create/update/delete an `EKEvent` on a
  test calendar, stamped with an `AppItemID` in `notes` (+ `url`), backed by a persisted
  **write-back ledger** (`AppItemID ↔ EKEvent.eventIdentifier`). Prove that a re-read via
  `CalendarService` **excludes** app-marked events (no self-ingest), and that a user-moved
  marked event is detectable as an edit. *This is the primitive the whole design hangs on.*
- **P0.2 — AlarmKit absolute one-shot.** Prove `Alarm.Schedule.fixed(Date)` coexists with
  the existing weekly relatives, bridges to `WakeCoordinator.startWake`, and confirm
  **AlarmKit's scheduled-alarm limits** (how many concurrent, one-shot cleanup semantics).

Deliverable: two spikes + a short decision memo. Gate: both must pass before Phase 1.

---

## Phase 1 — L1: the Occurrence spine + write-back

**P1.1 — Occurrence model.** New `Model/Occurrence.swift`: `Occurrence`, `Source`
(`.external/.derived/.authored`), `Behavior` (`.event/.cue/.task/.block`), `Schedule`
(`mode`, `moveable`, `window`, `constraints`), `AppItemID`, `SeriesID`, `WriteState`,
`writePolicy (.busy/.free/.none)`. Codable + tolerant decoders, per convention.

**P1.2 — Source producers (read-only first).** Adapters that emit `Occurrence`s; nothing
written yet:
- *Authored:* wrap `RoutineStore.moments(now:wakeTime:activePodcastID:)` → cue occurrences;
  `SeriesID = routine.id`.
- *Derived:* map `WakePlan.Day.wake/bedtime` + commute legs → derived occurrences (reuse
  `SmartScheduler` output — don't recompute).
- *External:* map `MeetingInfo` → `.external/.fixed` event occurrences (reuse
  `CalendarService` fetches + dedupe).
- New **`OccurrenceStore`** (`@MainActor`, mirrors `SmartScheduleStore`) with a
  `recompute()` that merges the three producers across the horizon.

**P1.3 — TodayView on Occurrences.** Replace the private `DayItem` enum (`.cue/.meeting`)
and `dayItems` with `Occurrence` rendering. Behavior-neutral; keep `momentRow`/`meetingRow`
visuals. First user-visible unification, no new capability.

**P1.4 — Cue ↔ source binding + multi-slot schedule.** Add a `binding` to the cue
(generalizes `RoutineTriggerKind`: `.clock(recurrence)`, `.calendar(match)`,
`.sleepSchedule`, `.firstMeeting`, `.workoutStart`); re-express `.earliestMeeting` as the
`.firstMeeting` preset via tolerant migration. Replace the single `hour/minute/weekdays`
with a **multi-slot schedule** (`[Slot{ id, weekdays, hour, minute }]`) so per-day time
variation works and `slotID` exists for L2. Editor UI can lag; model + migration land here.

**P1.5 — Write-back engine.** New `CalendarWriteBack` service: writable occurrences →
`EKEvent` create/update/delete, using the P0.1 ledger + markers, **Busy**, adopt-user-edits.
Driven from `OccurrenceStore.recompute()`. Re-ingest/reconcile on `.EKEventStoreChanged`
(observer already exists in `SmartScheduleStore.observeCalendarChanges` — extend or move).

**P1.6 — Arming via Occurrences.** Route arming through materialized occurrences: base
recurrences → relative-weekly (reuse the `scheduleSmartWakes` pattern), one-offs → absolute
`fixed` (P0.2). Extend the `WakeStopIntent → WakeCoordinator.startWake` bridge so **any** cue
occurrence starts its pool (today only the wake cue does). This subsumes `scheduleSmartWakes`.

> Sequencing note: P1.5 and P1.6 both hang off one `OccurrenceStore.recompute()` cycle —
> the same shape as `SmartScheduleStore.recompute()` today (materialize → drive alarms →
> drive notifications). Model the new cycle on it.

---

## Phase 2 — L2: exceptions

- **P2.1 Exception store** — per-series `overrides`/`extras`, keyed
  `OccurrenceKey = (seriesID, slotID, date)` (slotID from P1.4). Application Support JSON;
  prune past-dated.
- **P2.2 Resolution** — `OccurrenceStore.recompute()` gains expand → apply overrides →
  union extras. External series keep EventKit-native exceptions; the app store covers
  authored series + cue-bindings layered on external events.
- **P2.3 Edit-scope UI** — "just this one / this & future / all" on occurrence tap in Today,
  Up-next, Plan Tomorrow; writes overrides/extras.
- **P2.4 Adopt manual calendar edits** — a user-moved app-written event reconciles into a
  `.reschedule` override (user wins), via the `.EKEventStoreChanged` + ledger-diff path.
- **P2.5 Write-back deltas** — skip→delete/EXDATE, reschedule→update, extra→create.

This is the layer that makes the founding scenario work: move Thursday's gym to 7 PM this
week, skip Saturday's yoga, add an extra Wednesday gym — none of it touching the base rule.

---

## Phase 3 — L3: tasks (Apple Reminders)

- **P3.1 Reminders ingest** — new `RemindersService` on the same `EKEventStore`
  (`requestFullAccessToReminders`); `TaskInfo` model; `AppItemID` marker in reminder notes.
- **P3.2 Task occurrences + states** — inbox / deadline / placed; app-side
  `TaskSchedulingMeta` (duration, window, priority, `moveable`). `Behavior == .task`.
- **P3.3 Two-way sync** — completion both directions; a placed task writes a Busy block.
- **P3.4 Inbox UI** — list unscheduled tasks; promote (schedule) / demote (un-place).

Per-behavior default: events/cues sticky, **tasks default moveable**.

---

## Phase 4 — L4: manual scheduler ("Re-plan")

- **P4.1 Constraints + free-intervals** — horizon − fixed obstacles − derived (sleep etc.).
- **P4.2 Placement heuristic** — order by priority → deadline → duration; earliest-fit in
  window; frequency spread; deterministic; record a "why here" reason per placement.
- **P4.3 "Re-plan my day/week" UI** — trigger → preview → apply as a **batch of write-back
  deltas**; a **"Couldn't place: N"** report (never drop); one-tap pin/override.
- **P4.4 Stability** — keep valid prior placements; pins become sticky L2 overrides.

Bounded because reflow is **manual only** — an on-demand engine, not a continuous optimizer.

---

## Cross-cutting workstreams

- **Permissions/entitlements** — full access already covers calendar writes (no new prompt);
  add a clearer write usage string when convenient; L3 adds Reminders full access. The
  entitlements file carries only HealthKit today; EventKit needs no special entitlement
  beyond authorization.
- **Migration/seed** — single-user, so just bump `routinesSeedVersion` and re-seed; the
  `triggerKind → binding` and single-slot → multi-slot changes can reset app-owned data
  rather than carry tolerant migrations. (Podcast progress is a different store — untouched.)
- **Watch** — cue occurrences that arm workout audio still push via `syncWorkoutSource`
  (`workoutPodcasts` context). Pushing next-occurrence times to the watch is optional/later.
- **Safety/observability** — write-back targets a dedicated **"Banana (test)" calendar**
  until an explicit "go live." Keep a lightweight **audit log** of every calendar write. The
  only irreversible/outward-facing act is creating/deleting *real* calendar events — never
  point deletion at real calendars without a heads-up. Podcast listen progress is never
  written or reset by any step here.
- **Testing** — the materializer, exception resolution, and write-back reconcile are
  pure-ish and unit-testable; prioritize: identity round-trip (no self-ingest), adopt-edit,
  skip/reschedule/extra correctness, the **never-drop** invariant. AlarmKit `fixed` + real
  EventKit writes need device testing (sim EventKit is limited).

## Risk register

1. **AppItemID round-trip integrity** (self-ingest loop, orphaned events) → ledger +
   reconcile + P0.1 spike.
2. **AlarmKit absolute-alarm limits/semantics** → P0.2 spike.
3. **Write churn** from derived items rewriting events often → diff + batch writes; per-item
   `writePolicy` escape hatch.
4. **Two-way conflict** → "user edits always win" adopt path; never clobber.
5. **Wrong-calendar writes** (Busy visible to others is intended) → user picks the
   write-target calendar; guard the default.
6. **Horizon perf / re-arm frequency** → bound horizon (~2–4 wks), debounce recompute.

## Recommended first slice (thinnest end-to-end)

Prove the spine with **one** occurrence before breadth: take the existing **Wake** derived
item → run it through `OccurrenceStore` → write a Busy calendar event via `CalendarWriteBack`
(AppItemID-stamped) → arm via the new occurrence path → render in Today as an `Occurrence`.
If Wake survives the full round-trip — written, read-back-excluded, user-move-adopted,
armed, rendered — the architecture holds, and L2–L4 are breadth on a proven spine.

---

## Appendix — Phase-0 spike specs (hand-off detail)

### P0.1 — EventKit write + round-trip identity

**Where writes go:** a dedicated calendar found/created by name **"Banana (test)"** (never
a real calendar during the spike).

**Marker:** each written `EKEvent` carries its `AppItemID` (a UUID) in **`event.url`** —
`banana://occ/<appItemID>?series=<seriesID>` — which is structured and not shown in the
event body. (`notes` is user-visible; avoid it for the marker.)

**Ledger:** `calendar-writeback-ledger.json` in Application Support:
```
[ { appItemID, seriesID, eventIdentifier, calendarID, writtenStart, writtenHash } ]
writtenHash = digest(start, end, title, isBusy)   // detects a later user edit
```

**Read-back exclusion:** `CalendarService` ingest drops any event whose `url` uses the
`banana` scheme *or* whose `eventIdentifier` is in the ledger → no self-ingest.

**Reconcile loop (on `.EKEventStoreChanged`):** for each ledger entry, fetch
`event(withIdentifier:)`:
- missing → user deleted it → mark detach/skip (spike: log);
- `start`/hash differs from `writtenStart`/`writtenHash` → user edited → adopt (spike: log),
  refresh the stored hash;
- occurrence no longer exists → delete the event + prune the ledger entry (orphan cleanup).

**Success criteria:** create N events; a fresh `CalendarService` read excludes all N; editing
one in Calendar.app is detected as an edit; deleting one is detected; removing the source
occurrence removes its event and ledger row.

### P0.2 — AlarmKit absolute one-shot

**Goal:** confirm `Alarm.Schedule.fixed(<Date ~2 min out>)` works alongside today's
`Alarm.Schedule.relative` weekly wakes.

**Checks:**
- Schedule one `fixed` alarm via `AlarmManager.shared.schedule` with a `WakeStopIntent`;
  confirm it fires **once**, bridges to `WakeCoordinator.shared.startWake`, and does **not**
  repeat.
- Schedule a `fixed` and a `relative` together; both fire.
- Probe **limits:** schedule ~25 `fixed` alarms; note any cap/error.
- Confirm **cleanup:** does a fired one-shot auto-remove, or need `manager.cancel(id:)`?

**Note:** must run on a **real device** — AlarmKit doesn't fully function in the Simulator.
