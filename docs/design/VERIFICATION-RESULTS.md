# Verification Results — L1–L4 assumptions

Status: **verified in implementation.** A real harness
(`Banana/Model/TimelineVerification.swift`, DEBUG-only, `--verify-timeline` launch arg)
exercises every load-bearing assumption. It runs pure-logic checks plus **real EventKit and
Reminders reads/writes** against a throwaway "Banana (test)" calendar and reminder, then
deletes everything it made. Nothing touches podcast progress or real user data.

**Result: 35 passed, 0 failed, 0 skipped** (iPhone 17 Pro sim, iOS 26.5).

## How to re-run

```
xcodebuild -scheme Banana -destination "id=<SIM>" -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcrun simctl install <SIM> <app>
xcrun simctl privacy <SIM> grant calendar com.boris.banana
xcrun simctl privacy <SIM> grant reminders com.boris.banana
xcrun simctl launch <SIM> com.boris.banana --verify-timeline
# report: <app data container>/Library/Application Support/verify-report.txt
```

## What was proven

| Layer | Assumption | Verdict |
|---|---|---|
| L1 | EventKit write works with the existing full-access grant — **no new permission prompt** | ✅ |
| L1 | `AppItemID` marker in `event.url` (`banana://occ/<id>`) survives round-trip | ✅ |
| L1 | Read-back **excludes** app-marked events → no self-ingest loop | ✅ |
| L1 | A user edit is detectable via a change hash (→ adopt as override) | ✅ |
| L1 | Delete round-trips (reconcile sees the event gone) | ✅ |
| L1 | `Alarm.Schedule.fixed(Date)` exists and coexists with `.relative` (API shape) | ✅ (runtime = device) |
| L2 | EventKit **natively** expands a recurring series and applies per-occurrence **skip** (this-event delete → EXDATE) and **move** (detached exception) | ✅ |
| L1/L2 | Materializer (expand → apply overrides → union extras) reproduces the founding scenario (move Thu gym→7pm, skip Sat yoga, add Wed gym) with the base rule untouched | ✅ |
| L3 | Reminders full access + read title/priority/due + `AppItemID` marker + **two-way completion** | ✅ |
| L4 | Placement heuristic: priority order, window + deadline respected, no overlap with fixed obstacles, and **impossible items reported, never dropped** | ✅ |

## Findings that change the build (not failures — constraints discovered)

1. **Busy holds are a calendar-source capability.** The sim's local calendar reports
   `supportedEventAvailabilities` = neither busy nor free, so setting `.busy` is silently
   dropped (`availability` reads back `.notSupported`). **Implication:** the "defend my time
   as Busy" decision only holds on availability-capable calendars (iCloud). Write-target
   selection **must filter** to calendars where
   `supportedEventAvailabilities.contains(.busy)` **and** `allowsContentModifications == true`
   (subscribed/holiday calendars are read-only). If none qualify, fall back to `.free`/`.none`
   and tell the user. → reflected in [L1](L1-occurrence-model.md) §4.

2. **Reminders need their own usage string + authorization.** `requestFullAccessToReminders`
   is a **separate** grant from calendar, and requires `NSRemindersFullAccessUsageDescription`
   (now added to `project.yml`). Without it the request fails/crashes. → L3 prerequisite.

3. **AlarmKit runtime is the one device-only gap.** The `.fixed` schedule type compiles and
   constructs, and coexists with `.relative`. Whether one-shots actually **fire**, how they
   **clean up** after firing, and AlarmKit's **alarm-count limit** cannot be verified in the
   Simulator — this is the remaining P0.2 item to confirm on a physical device before the
   arming work in P1.6.

## Bottom line

Every assumption verifiable without hardware **holds**. The unified-timeline architecture is
sound: write-back identity, native recurrence exceptions, reminders round-trip, and the
materializer/scheduler logic all work against real frameworks. Two constraints were
discovered (availability-capable write target; reminders usage string) and folded into the
docs. One item (AlarmKit one-shot runtime) remains device-only and is flagged for on-device
confirmation. **Cleared to proceed with the buildout, starting from the Wake vertical slice.**
