#if os(iOS)
// DEBUG harness built on AlarmKit.

#if DEBUG
import Foundation
import EventKit
import AlarmKit
import AppIntents
import SwiftUI

/// One-shot verification harness for the unified-timeline design (docs/design/).
/// Runs with the `--verify-timeline` launch argument and prints a PASS/FAIL report so we
/// can validate every load-bearing assumption across L1–L4 BEFORE building the real thing.
///
/// It exercises a real throwaway reminder — then **deletes everything it creates**. It never
/// touches podcast progress or any real user data; stray artifacts are self-labelled.
enum TimelineVerification {

    private static let marker = "banana-verify"
    private static var pass = 0
    private static var fail = 0
    private static var skip = 0

    static func runIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("--verify-timeline") { Task { await run() } }
    }

    static func run() async {
        line("========================================================")
        line("TIMELINE VERIFICATION — L1–L4 assumption checks")
        line("========================================================")

        // Pure-logic checks first (no permissions needed).
        verifyMaterializer()          // L1/L2 resolution algorithm
        verifyScheduler()             // L4 placement heuristic (reference)
        verifyTaskProducer()          // L3 — the REAL OccurrenceProducers.tasks (overdue/completed)
        verifyCalendarLaneLayout()    // iOS/Mac grid — adjacent events stay full width
        verifyAgendaVisibility()      // privacy blockers occupy time without polluting the agenda
        verifyCalendarBoundCues()     // L1 — calendar-bound cue matching
        verifyMultiSlot()             // L1 — multi-slot cue times
        verifyAlarmKitShape()         // L1 arming API shape (runtime = device only)

        // Reminders (needs reminders permission; grant via simctl before launch). Calendar
        // events are Google's now and are covered by the unit tests and the Mac probes.
        await verifyReminders()       // L3 tasks access + round-trip

        // AlarmKit RUNTIME (device only; skips gracefully in the Simulator).
        await verifyAlarmKitRuntime()

        line("========================================================")
        let summary = "RESULT: \(pass) passed, \(fail) failed, \(skip) skipped"
        line(summary)
        line(fail == 0 ? "ALL VERIFIABLE ASSUMPTIONS HOLD ✅" : "SOME ASSUMPTIONS FAILED ❌")
        line("========================================================")
        Task { @MainActor in VerificationResults.shared.summary = summary; VerificationResults.shared.done = true }
    }

    // MARK: - L1/L2: materializer (expand recurrence → apply overrides → union extras)

    struct Slot { let id: String; let weekdays: Set<Int>; let hour: Int; let minute: Int }
    struct Series { let id: String; let name: String; let slots: [Slot] }
    enum Override { case skip; case reschedule(hour: Int, minute: Int) }
    struct OccKey: Hashable { let seriesID: String; let slotID: String; let day: Date }
    struct Occ { let seriesID: String; let name: String; let slotID: String; let start: Date }

    /// Reference implementation of the L2 resolution: this doubles as the algorithm we'll
    /// port into OccurrenceStore. Weekday: 1=Sun…7=Sat (matches Routine.weekdays).
    static func materialize(series: [Series], overrides: [OccKey: Override],
                            extras: [Occ], days: [Date], cal: Calendar) -> [Occ] {
        var out: [Occ] = []
        for s in series {
            for day in days {
                let wd = cal.component(.weekday, from: day)
                for slot in s.slots where slot.weekdays.contains(wd) {
                    let key = OccKey(seriesID: s.id, slotID: slot.id, day: cal.startOfDay(for: day))
                    if case .skip? = overrides[key] { continue }
                    var h = slot.hour, m = slot.minute
                    if case .reschedule(let rh, let rm)? = overrides[key] { h = rh; m = rm }
                    if let start = cal.date(bySettingHour: h, minute: m, second: 0, of: day) {
                        out.append(Occ(seriesID: s.id, name: s.name, slotID: slot.id, start: start))
                    }
                }
            }
        }
        out.append(contentsOf: extras)
        return out.sorted { $0.start < $1.start }
    }

    static func verifyMaterializer() {
        group("L1/L2 — materializer (the founding scenario)")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Build a known week: pick a Sunday anchor so weekday math is deterministic.
        let anchor = cal.date(from: DateComponents(year: 2026, month: 7, day: 5))! // 2026-07-05 = Sunday
        let week = (0..<7).map { cal.date(byAdding: .day, value: $0, to: anchor)! }
        let (sun, mon, tue, wed, thu, _, sat) = (week[0], week[1], week[2], week[3], week[4], week[5], week[6])

        // Mon=2, Tue=3, Wed=4, Thu=5, Sat=7 (1=Sun)
        let run  = Series(id: "run",  name: "Run",  slots: [Slot(id: "r", weekdays: [2,3,4], hour: 7, minute: 0)])
        let gym  = Series(id: "gym",  name: "Gym",  slots: [Slot(id: "g", weekdays: [3,5], hour: 17, minute: 0)])
        let yoga = Series(id: "yoga", name: "Yoga", slots: [Slot(id: "y", weekdays: [7], hour: 11, minute: 0)])

        // Base week, no exceptions
        let base = materialize(series: [run, gym, yoga], overrides: [:], extras: [], days: week, cal: cal)
        check("base week has 3 runs + 2 gyms + 1 yoga = 6", base.count == 6)
        check("run only on Mon/Tue/Wed", base.filter { $0.seriesID == "run" }.count == 3)
        check("gym only on Tue/Thu", base.filter { $0.seriesID == "gym" }.count == 2)

        // Exceptions: move Thursday gym → 7 PM (19:00), skip Saturday yoga, add extra Wed gym.
        let thuKey = OccKey(seriesID: "gym", slotID: "g", day: cal.startOfDay(for: thu))
        let satKey = OccKey(seriesID: "yoga", slotID: "y", day: cal.startOfDay(for: sat))
        let overrides: [OccKey: Override] = [thuKey: .reschedule(hour: 19, minute: 0), satKey: .skip]
        let extraGymWed = Occ(seriesID: "gym", name: "Gym", slotID: "g+extra",
                              start: cal.date(bySettingHour: 17, minute: 0, second: 0, of: wed)!)
        let resolved = materialize(series: [run, gym, yoga], overrides: overrides, extras: [extraGymWed], days: week, cal: cal)

        check("Saturday yoga is gone (skip)", !resolved.contains { $0.seriesID == "yoga" })
        let thuGym = resolved.first { $0.seriesID == "gym" && cal.isDate($0.start, inSameDayAs: thu) }
        check("Thursday gym moved to 19:00", cal.component(.hour, from: thuGym?.start ?? .distantPast) == 19)
        let wedGyms = resolved.filter { $0.seriesID == "gym" && cal.isDate($0.start, inSameDayAs: wed) }
        check("extra Wednesday gym added", wedGyms.count == 1)
        check("base rule untouched: total = 6 - 1 skip + 1 extra = 6", resolved.count == 6)
        // Sun/Mon sanity: no gym Monday, run Monday exists
        check("no gym on Sunday/Monday", !resolved.contains { $0.seriesID == "gym" && ($0.start < mon || cal.isDate($0.start, inSameDayAs: sun)) })
        _ = tue
    }

    // MARK: - L4: manual placement scheduler

    struct Interval { var start: Date; var end: Date }
    struct Placeable { let id: String; let duration: TimeInterval; let window: Interval; let deadline: Date?; let priority: Int }
    struct Placement { let id: String; let start: Date }

    /// Reference placement heuristic: order by priority↑ then deadline↑ then duration↓;
    /// earliest-fit inside window within free time; never drop — return unplaced list.
    static func place(obstacles: [Interval], items: [Placeable], horizon: Interval)
        -> (placed: [Placement], unplaced: [String]) {
        var busy = obstacles.sorted { $0.start < $1.start }
        var placed: [Placement] = []
        var unplaced: [String] = []
        let order = items.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            let d0 = $0.deadline ?? .distantFuture, d1 = $1.deadline ?? .distantFuture
            if d0 != d1 { return d0 < d1 }
            return $0.duration > $1.duration
        }
        for item in order {
            let lo = max(item.window.start, horizon.start)
            let hi = min(item.window.end, item.deadline ?? horizon.end, horizon.end)
            var cursor = lo
            var slotted: Date? = nil
            while cursor.addingTimeInterval(item.duration) <= hi {
                let candidateEnd = cursor.addingTimeInterval(item.duration)
                if let clash = busy.first(where: { $0.start < candidateEnd && cursor < $0.end }) {
                    cursor = clash.end   // jump past the obstacle
                } else {
                    slotted = cursor; break
                }
            }
            if let s = slotted {
                placed.append(Placement(id: item.id, start: s))
                busy.append(Interval(start: s, end: s.addingTimeInterval(item.duration)))
                busy.sort { $0.start < $1.start }
            } else {
                unplaced.append(item.id)
            }
        }
        return (placed, unplaced)
    }

    static func verifyScheduler() {
        group("L4 — manual placement heuristic")
        let cal = Calendar(identifier: .gregorian)
        let day0 = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day0)! }
        let horizon = Interval(start: at(6), end: at(22))
        // Fixed obstacles: a 9–10 meeting and a 13–14 meeting.
        let obstacles = [Interval(start: at(9), end: at(10)), Interval(start: at(13), end: at(14))]
        // Items: a 45-min run (morning window), a 60-min focus block (work hours, deadline 12:00),
        // and an impossible 3h task in a 1h window (should fail to place → reported, not dropped).
        let items = [
            Placeable(id: "run", duration: 45*60, window: Interval(start: at(6), end: at(9)), deadline: nil, priority: 2),
            Placeable(id: "focus", duration: 60*60, window: Interval(start: at(8), end: at(18)), deadline: at(12), priority: 1),
            Placeable(id: "toobig", duration: 3*3600, window: Interval(start: at(10), end: at(11)), deadline: nil, priority: 3),
        ]
        let (placed, unplaced) = place(obstacles: obstacles, items: items, horizon: horizon)
        check("focus placed (priority 1 first)", placed.contains { $0.id == "focus" })
        check("run placed in its morning window", placed.first { $0.id == "run" }.map { $0.start >= at(6) && $0.start.addingTimeInterval(45*60) <= at(9) } ?? false)
        let focus = placed.first { $0.id == "focus" }
        check("focus respects its noon deadline", focus.map { $0.start.addingTimeInterval(3600) <= at(12) } ?? false)
        check("no placement overlaps the 9–10 meeting", !placed.contains {
            let end = $0.start.addingTimeInterval($0.id == "focus" ? 3600 : 45*60)
            return $0.start < at(10) && at(9) < end
        })
        check("impossible task reported as unplaced (never dropped)", unplaced == ["toobig"])
    }

    // MARK: - L3/L4: real producer + scheduler on Occurrences

    private static func sampleOcc(_ behavior: OccurrenceBehavior, start: Date, end: Date? = nil,
                                  hasTime: Bool = true, overdue: Bool = false, completed: Bool = false,
                                  reminder: String? = nil) -> Occurrence {
        Occurrence(id: UUID().uuidString, source: .authored, behavior: behavior,
                   schedule: OccurrenceSchedule(mode: .fixed, moveable: behavior == .task),
                   title: "t", icon: "circle", tint: .gray, start: start, end: end,
                   hasScheduledTime: hasTime, completed: completed, overdue: overdue, reminderID: reminder)
    }

    static func verifyTaskProducer() {
        group("L3 — real OccurrenceProducers.tasks (overdue / completed / horizon)")
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let tomorrow3pm = cal.date(bySettingHour: 15, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        let farFuture = cal.date(byAdding: .day, value: 60, to: now)!
        let recurringDue = cal.date(byAdding: .hour, value: 3, to: now)!
        let tasks = [
            TaskInfo(id: "a", title: "Overdue", due: yesterday, hasTime: true, isCompleted: false, priority: 0),
            TaskInfo(id: "b", title: "Future", due: tomorrow3pm, hasTime: true, isCompleted: false, priority: 0),
            TaskInfo(id: "c", title: "Done", due: now, hasTime: true, isCompleted: true, priority: 0),
            TaskInfo(id: "d", title: "TooFar", due: farFuture, hasTime: true, isCompleted: false, priority: 0),
            TaskInfo(id: "r", title: "Daily", due: recurringDue, hasTime: true, isCompleted: false,
                     priority: 0, recurrence: .daily),
        ]
        let out = OccurrenceProducers.tasks(tasks, horizonDays: 14, now: now, calendar: cal)
        check("far-future task excluded (beyond horizon)", !out.contains { $0.reminderID == "d" })
        let overdue = out.first { $0.reminderID == "a" }
        check("overdue task pulled onto today", overdue.map { cal.isDate($0.start, inSameDayAs: now) } ?? false)
        check("overdue task flagged overdue", overdue?.overdue == true)
        check("future task stays on its own day", out.first { $0.reminderID == "b" }.map { cal.isDate($0.start, inSameDayAs: tomorrow3pm) } ?? false)
        check("completed task included + flagged completed", out.first { $0.reminderID == "c" }?.completed == true)
        let recurring = out.filter { $0.reminderID == "r" }.sorted { $0.start < $1.start }
        let tomorrowOccurrence = recurring.first {
            abs($0.start.timeIntervalSince(recurringDue.addingTimeInterval(86_400))) < 60
        }
        check("daily reminder expands through the planning horizon", recurring.count > 1)
        check("daily reminder reserves the +24h occurrence", tomorrowOccurrence?.isWritable == true)
        check("recurring blocker IDs are unique", Set(recurring.map(\.id)).count == recurring.count)
    }

    static func verifyCalendarLaneLayout() {
        group("Calendar grid — adjacent intervals are not overlaps")
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: second, of: day)!
        }

        let first = sampleOcc(.event, start: at(8, 30), end: at(9))
        let second = sampleOcc(.event, start: at(9), end: at(9, 30))
        let adjacent = CalendarLaneAllocator.placements([first, second])
        check("8:30–9:00 and 9:00–9:30 both use full width",
              adjacent.allSatisfy { $0.lane == 0 && $0.laneCount == 1 })

        let hiddenSeconds = sampleOcc(.event, start: at(8, 30), end: at(9, 0, 30))
        let roundedBoundary = CalendarLaneAllocator.placements([hiddenSeconds, second])
        check("sub-minute precision hidden by labels does not split lanes",
              roundedBoundary.allSatisfy { $0.laneCount == 1 })

        let realOverlap = sampleOcc(.event, start: at(8, 30), end: at(9, 5))
        let overlapping = CalendarLaneAllocator.placements([realOverlap, second])
        check("visible five-minute overlap still uses side-by-side lanes",
              overlapping.allSatisfy { $0.laneCount == 2 })

        // Source refreshes are not ordered (first-paint cache vs. live calendars). Equal
        // intervals must therefore retain their side-by-side position irrespective of input
        // order; otherwise the blocks visibly swap sides during the refresh.
        var equalA = sampleOcc(.event, start: at(10), end: at(10, 30))
        var equalB = sampleOcc(.event, start: at(10), end: at(10, 30))
        equalA.id = "calendar-a"
        equalB.id = "calendar-b"
        let forward = CalendarLaneAllocator.placements([equalA, equalB])
        let reverse = CalendarLaneAllocator.placements([equalB, equalA])
        let forwardLanes = Dictionary(uniqueKeysWithValues: forward.map { ($0.occurrence.id, $0.lane) })
        let reverseLanes = Dictionary(uniqueKeysWithValues: reverse.map { ($0.occurrence.id, $0.lane) })
        check("equal intervals retain their lanes across source ordering", forwardLanes == reverseLanes)

        // A multi-day booking (car hire, hotel, conference) is drawn per column: a band from its
        // start to midnight here, a fresh band tomorrow. Taking the height from the raw end
        // instead asked for 120 hours of block inside a 24-hour day — it covered its own column
        // and every row beneath it, so the day read as one giant item and nothing else.
        let fiveDay = sampleOcc(.event, start: at(17),
                                end: cal.date(byAdding: .day, value: 5, to: at(17))!)
        let midnight = cal.date(byAdding: .day, value: 1, to: day)!

        let onStartDay = DayColumn.visibleInterval(of: fiveDay, on: day)
        check("a 5-day entry is clipped to midnight on the day it starts",
              onStartDay.start == at(17) && onStartDay.end == midnight)
        check("its drawn height never exceeds one day", onStartDay.duration <= 86_400)

        let middleDay = cal.date(byAdding: .day, value: 2, to: day)!
        check("on a day it spans end to end, it fills exactly that column",
              DayColumn.visibleInterval(of: fiveDay, on: middleDay).duration == 86_400)
        check("a spanning entry is included in every day column it intersects",
              DayColumn.occurrences([fiveDay], on: middleDay, calendar: cal).map(\.id) == [fiveDay.id])

        let afterEnd = cal.date(byAdding: .day, value: 6, to: day)!
        check("a spanning entry is excluded after it ends",
              DayColumn.occurrences([fiveDay], on: afterEnd, calendar: cal).isEmpty)

        let ordinary = sampleOcc(.event, start: at(9), end: at(10, 30))
        check("an ordinary same-day event is unchanged by the clamp",
              DayColumn.visibleInterval(of: ordinary, on: day).duration == 90 * 60)

        var untimed = sampleOcc(.cue, start: at(23, 55), end: midnight.addingTimeInterval(5 * 60))
        untimed.hasScheduledTime = false
        check("an untimed item stays assigned to its start date",
              DayColumn.occurrences([untimed], on: midnight, calendar: cal).isEmpty)
    }

    static func verifyAgendaVisibility() {
        group("L1 — privacy blocker agenda visibility")
        check("Busy placeholder is hidden from the agenda",
              CalendarEventTitlePolicy.isPrivacyPlaceholder("Busy"))
        check("Private placeholder is hidden case-insensitively",
              CalendarEventTitlePolicy.isPrivacyPlaceholder("  PRIVATE  "))
        check("a titled meeting remains agenda content",
              !CalendarEventTitlePolicy.isPrivacyPlaceholder("Board meeting"))
    }

    static func verifyCalendarBoundCues() {
        group("L1 — calendar-bound cues (title matching + lead time)")
        let cal = Calendar.current
        let now = Date()
        let gym = Routine(name: "Gym", icon: "dumbbell.fill", color: .orange, triggerKind: .calendarMatch,
                          autonomy: .nudge, sourceLabel: "x", matchKeywords: ["gym", "lift"], leadMinutes: 10)
        let run = Routine(name: "Run", icon: "figure.run", color: .green, triggerKind: .calendarMatch,
                          autonomy: .nudge, sourceLabel: "x", matchKeywords: ["run"])
        let gymEvent = MeetingInfo(start: cal.date(bySettingHour: 17, minute: 0, second: 0, of: now)!,
                                   isVirtual: false, title: "Evening Gym Session", eventID: "e1")
        let standup = MeetingInfo(start: cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!,
                                  isVirtual: false, title: "Team Standup", eventID: "e2")
        let out = OccurrenceProducers.calendarBoundCues(routines: [gym, run], meetings: [gymEvent, standup])
        check("gym cue matched the gym event", out.contains { $0.routineID == gym.id })
        check("exactly one occurrence (standup didn't match)", out.count == 1)
        check("no run cue (no matching event)", !out.contains { $0.routineID == run.id })
        let occ = out.first { $0.routineID == gym.id }
        check("fires 10 min before the event", occ.map { abs($0.start.timeIntervalSince(gymEvent.start) + 600) < 1 } ?? false)
        check("carries a durable occurrence key", occ?.occurrenceKey != nil)
    }

    static func verifyMultiSlot() {
        group("L1 — multi-slot cue times (primary + extra slots)")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let anchor = cal.date(from: DateComponents(year: 2026, month: 7, day: 5))!  // Sunday
        // Gym cue: primary Tue(3) 17:00, extra Thu(5) 18:00.
        var gym = Routine(name: "Gym", icon: "dumbbell.fill", color: .orange, triggerKind: .time,
                          autonomy: .nudge, sourceLabel: "x")
        gym.hour = 17; gym.minute = 0; gym.weekdays = [3]
        gym.extraSlots = [CueSlot(weekdays: [5], hour: 18, minute: 0)]
        let out = OccurrenceProducers.authored(routines: [gym], wakeByDay: [:], horizonDays: 7, now: anchor, calendar: cal)
        let tue = out.first { cal.component(.weekday, from: $0.start) == 3 }
        let thu = out.first { cal.component(.weekday, from: $0.start) == 5 }
        check("primary slot fires Tuesday 17:00", tue.map { cal.component(.hour, from: $0.start) == 17 } ?? false)
        check("extra slot fires Thursday 18:00", thu.map { cal.component(.hour, from: $0.start) == 18 } ?? false)
        check("two occurrences this week (Tue + Thu only)", out.count == 2)
        check("slots have distinct keys", Set(out.compactMap { $0.slotID }).count == 2)
    }

    // MARK: - L1: AlarmKit fixed one-shot (API shape; runtime firing = device only)

    static func verifyAlarmKitShape() {
        group("L1 — AlarmKit absolute one-shot API shape")
        // If this compiles + constructs, the type-level assumption holds. We do NOT schedule
        // here (Simulator can't ring); runtime coexistence/limits must be checked on device.
        let fireDate = Date().addingTimeInterval(120)
        let schedule: Alarm.Schedule = .fixed(fireDate)
        if case .fixed = schedule {
            check("Alarm.Schedule.fixed(Date) constructs", true)
        } else {
            check("Alarm.Schedule.fixed(Date) constructs", false)
        }
        // Relative still available (existing wake path).
        let rel = Alarm.Schedule.Relative(time: .init(hour: 7, minute: 0), repeats: .weekly([.monday]))
        let relSchedule: Alarm.Schedule = .relative(rel)
        if case .relative = relSchedule { check("both .fixed and .relative coexist", true) }
        else { check("both .fixed and .relative coexist", false) }
        note("Runtime firing + AlarmKit alarm-count limits require a physical device (P0.2).")
    }

    // MARK: - L1: AlarmKit one-shot RUNTIME (device only)

    @MainActor
    static func verifyAlarmKitRuntime() async {
        group("L1 — AlarmKit one-shot RUNTIME (device only)")
        #if targetEnvironment(simulator)
        skipAll("AlarmKit runtime firing requires a physical device")
        return
        #else
        let manager = AlarmManager.shared
        let state: AlarmManager.AuthorizationState
        do { state = try await manager.requestAuthorization() }
        catch { skipAll("alarm auth request failed: \(error.localizedDescription)"); return }
        guard state == .authorized else { skipAll("alarm authorization not granted (state=\(state))"); return }
        check("AlarmKit authorization granted", true)

        // Schedule a fixed one-shot ~15s out and confirm it actually fires.
        let id = UUID()
        do {
            _ = try await manager.schedule(id: id, configuration: fixedConfig(id: id, fire: Date().addingTimeInterval(15), title: "Verify one-shot"))
            check("schedule Alarm.Schedule.fixed one-shot (no throw)", true)
        } catch {
            check("schedule Alarm.Schedule.fixed one-shot (no throw)", false)
            note("schedule error: \(error.localizedDescription)"); return
        }
        let fired = await waitForAlerting(manager, id: id, timeout: 45)
        check("fixed one-shot actually FIRES (enters .alerting)", fired)
        try? manager.stop(id: id)
        try? manager.cancel(id: id)

        // Count-limit probe: schedule far-future one-shots until the limit or 40.
        var made: [UUID] = []
        var hitLimit = false
        for i in 0..<40 {
            let cid = UUID()
            do {
                _ = try await manager.schedule(id: cid, configuration: fixedConfig(id: cid, fire: Date().addingTimeInterval(3600 + Double(i) * 120), title: "cap\(i)"))
                made.append(cid)
            } catch AlarmManager.AlarmError.maximumLimitReached { hitLimit = true; break }
            catch { note("count probe stopped at \(made.count): \(error.localizedDescription)"); break }
        }
        note("scheduled \(made.count) concurrent one-shots before \(hitLimit ? "hitting AlarmKit's limit" : "stopping at 40 (no limit hit)")")
        check("AlarmKit alarm-count behavior observed", true)
        for cid in made { try? manager.cancel(id: cid) }
        #endif
    }

    private static func fixedConfig(id: UUID, fire: Date, title: String) -> AlarmManager.AlarmConfiguration<BananaMetadata> {
        let schedule = Alarm.Schedule.fixed(fire)
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            secondaryButton: AlarmButton(text: "Open", textColor: .white, systemImageName: "arrow.up.forward.app"),
            secondaryButtonBehavior: .custom)
        let attributes = BananaAlarmAttributes(presentation: AlarmPresentation(alert: alert),
                                                 metadata: BananaMetadata(), tintColor: .orange)
        return AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule, attributes: attributes,
            stopIntent: WakeStopIntent(alarmID: id.uuidString),
            secondaryIntent: WakeOpenIntent(), sound: .default)
    }

    private static func waitForAlerting(_ manager: AlarmManager, id: UUID, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await alarms in manager.alarmUpdates {
                    if alarms.contains(where: { $0.id == id && $0.state == .alerting }) { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let r = await group.next() ?? false
            group.cancelAll()
            return r
        }
    }

    // MARK: - L1: EventKit write-back + AppItemID round-trip

    // MARK: - L3: Reminders access + round-trip

    static func verifyReminders() async {
        group("L3 — Apple Reminders access + task round-trip")
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { skipAll("reminders access not granted (needs NSRemindersFullAccessUsageDescription + simctl grant)"); return }
        check("full reminders access", true)

        guard let list = store.defaultCalendarForNewReminders() else {
            check("has a default reminders list", false); return
        }
        check("has a default reminders list", true)
        guard AppVariant.current.mayChangeReminder(inListTitled: list.title) else {
            skipAll("Beta leaves real reminders alone"); return
        }

        let appItemID = UUID().uuidString
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = "Verify task round-trip"
        reminder.priority = 5
        reminder.dueDateComponents = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],
                                                                     from: Date().addingTimeInterval(86400))
        reminder.url = URL(string: "banana://task/\(appItemID)")     // round-trip marker
        guard (try? store.save(reminder, commit: true)) != nil else {
            check("write a reminder with AppItemID marker", false); return
        }
        check("write a reminder with AppItemID marker", true)

        // Read back fields we depend on for L3 scheduling metadata.
        let readBack = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder
        check("reminder round-trips (title/priority/due/marker readable)",
              readBack?.title == "Verify task round-trip" && readBack?.priority == 5 &&
              readBack?.dueDateComponents?.day != nil && (readBack?.url?.scheme == "banana"))

        // Completion two-way.
        readBack?.isCompleted = true
        try? store.save(readBack!, commit: true)
        let done = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder
        check("completion round-trips (two-way sync viable)", done?.isCompleted == true)

        try? store.remove(reminder, commit: true)
        check("delete the reminder (cleanup)", (store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder) == nil)
    }

    // MARK: - helpers

    // MARK: - reporting

    private static func group(_ s: String) { line("\n— \(s) —") }
    private static func check(_ label: String, _ ok: Bool) {
        if ok { pass += 1; line("  ✅ \(label)") } else { fail += 1; line("  ❌ \(label)") }
    }
    private static func note(_ s: String) { line("  ℹ️  \(s)") }
    private static func skipAll(_ why: String) { skip += 1; line("  ⏭️  SKIPPED: \(why)") }

    /// Report file — read from the sim via `xcrun simctl get_app_container`.
    private static let reportURL: URL = {
        let dir = AppSupport.directory
        return dir.appendingPathComponent("verify-report.txt")
    }()
    private static var buffer = ""
    private static func line(_ s: String) {
        print("VERIFY: \(s)")
        buffer += s + "\n"
        try? buffer.write(to: reportURL, atomically: true, encoding: .utf8)   // flush after every line
        let snapshot = buffer
        Task { @MainActor in VerificationResults.shared.text = snapshot }     // feed the on-screen report
    }
}

/// Observable results so the on-device XCUITest can read PASS/FAIL from the UI (there's no
/// `simctl get_app_container` for a physical device).
@MainActor final class VerificationResults: ObservableObject {
    static let shared = VerificationResults()
    @Published var text = ""
    @Published var summary = ""
    @Published var done = false
}

/// Shown instead of RootView under `--verify-timeline`. Exposes accessibility identifiers
/// the UITest asserts on: `verify.status` ("DONE"), `verify.summary`, `verify.report`.
struct VerificationView: View {
    @ObservedObject private var r = VerificationResults.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.done ? "DONE" : "RUNNING")
                .font(.headline).accessibilityIdentifier("verify.status")
            Text(r.summary).font(.subheadline.monospaced())
                .accessibilityIdentifier("verify.summary")
            ScrollView {
                Text(r.text).font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("verify.report")
        }
        .padding()
    }
}
#endif
#endif
