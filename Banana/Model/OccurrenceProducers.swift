import Foundation

/// Pure adapters that turn the app's existing domain objects into `Occurrence`s. No I/O
/// here — the `OccurrenceStore` fetches the raw data (routines, meetings, the wake plan) and
/// calls these, so the mapping stays testable.
enum OccurrenceProducers {

    // MARK: - Authored (the user's cues)

    /// Expand enabled cues across `[today … +horizonDays]`. `wakeByDay` maps a day's start
    /// to that day's computed wake time, used for `.earliestMeeting` (smart-wake) cues and for
    /// the ones that follow waking (`.wakeUp`).
    static func authored(routines: [Routine], wakeByDay: [Date: Date],
                         horizonDays: Int, now: Date, calendar: Calendar = .current) -> [Occurrence] {
        var out: [Occurrence] = []
        let startDay = calendar.startOfDay(for: now)
        for offset in 0..<horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            for routine in routines where routine.enabled {
                switch routine.triggerKind {
                case .time:
                    // Every slot (primary + extras) whose weekdays include this day.
                    for slot in routine.effectiveSlots where slot.weekdays.isEmpty || slot.weekdays.contains(weekday) {
                        if let start = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day) {
                            out.append(cueOccurrence(from: routine, start: start, scheduled: true, slotID: slot.id))
                        }
                    }
                case .earliestMeeting:
                    let t = wakeByDay[calendar.startOfDay(for: day)]
                        ?? calendar.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: day)
                    if let start = t { out.append(cueOccurrence(from: routine, start: start, scheduled: true, slotID: "main")) }
                case .wakeUp:
                    // Follows the day's wake (`WakeFollowing`): on the day at a time, like the
                    // Wake routine it follows, and on its own weekdays when it has any.
                    guard routine.weekdays.isEmpty || routine.weekdays.contains(weekday) else { break }
                    let wake = routines.first { $0.enabled && $0.cueType == .wake && $0.id != routine.id }
                    if let start = WakeFollowing.start(
                        on: day, plannedWake: wakeByDay[calendar.startOfDay(for: day)],
                        wakeRoutine: wake.map { ($0.hour, $0.minute) }, own: (routine.hour, routine.minute),
                        minutesAfter: routine.leadMinutes, calendar: calendar) {
                        out.append(cueOccurrence(from: routine, start: start, scheduled: true, slotID: "main"))
                    }
                case .workoutStart, .manual:
                    if let start = calendar.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: day) {
                        out.append(cueOccurrence(from: routine, start: start, scheduled: false, slotID: "main"))
                    }
                case .calendarMatch:
                    break   // produced from matched events, not the clock
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// A workout you haven't booked a time for is the one cue that genuinely wants scheduling:
    /// it has to fit around your day, it takes real time, and "On start" leaves it stranded above
    /// the now marker looking overdue when it isn't. Make it moveable so Re-plan can find it a slot.
    private static func cueOccurrence(from r: Routine, start: Date, scheduled: Bool, slotID: String) -> Occurrence {
        // A smart-wake cue is timed by a derived source; everything else is a fixed clock.
        let mode: ScheduleMode = r.triggerKind == .earliestMeeting || r.triggerKind == .wakeUp ? .derived : .fixed
        let bookable = r.triggerKind == .workoutStart
        return Occurrence(
            id: Occurrence.makeID(series: r.id.uuidString, slot: slotID, day: start),
            seriesID: r.id.uuidString, slotID: slotID,
            source: .authored, behavior: .cue,
            schedule: OccurrenceSchedule(
                mode: mode,
                moveable: bookable,
                constraints: bookable
                    ? OccurrenceConstraints(duration: TimeInterval(r.durationMinutes * 60))
                    : nil),
            writePolicy: .none,   // cues notify in Banana; only placed tasks/blocks write back
            title: r.name, icon: r.icon, tint: r.color,
            start: start, end: nil, hasScheduledTime: scheduled,
            routineID: r.id)
    }

    // MARK: - Calendar-bound cues (a cue that fires alongside matching calendar events)

    /// For each `.calendarMatch` cue, produce a cue occurrence at every meeting whose title
    /// contains one of the cue's keywords (fired `leadMinutes` before the event start).
    static func calendarBoundCues(routines: [Routine], meetings: [MeetingInfo]) -> [Occurrence] {
        let bound = routines.filter { $0.enabled && $0.triggerKind == .calendarMatch && !$0.matchKeywords.isEmpty }
        guard !bound.isEmpty else { return [] }
        var out: [Occurrence] = []
        for m in meetings {
            let title = m.title.lowercased()
            for r in bound where r.matchKeywords.contains(where: { title.contains($0.lowercased()) }) {
                let key = m.eventID ?? m.id
                out.append(Occurrence(
                    id: "calcue:\(r.id.uuidString):\(key)",
                    seriesID: r.id.uuidString, slotID: "cal:\(key)",
                    source: .authored, behavior: .cue,
                    schedule: OccurrenceSchedule(mode: .fixed, moveable: false),
                    writePolicy: .none,   // mirrors an existing event — don't write it back
                    title: r.name, icon: r.icon, tint: r.color,
                    start: m.start.addingTimeInterval(-Double(r.leadMinutes) * 60),
                    end: nil, hasScheduledTime: true,
                    routineID: r.id))
            }
        }
        return out
    }

    // MARK: - External (calendar meetings, read-only)

    static func external(meetings: [MeetingInfo]) -> [Occurrence] {
        meetings.map { m in
            Occurrence(
                id: "ext:\(m.eventID ?? m.id)",
                seriesID: nil, slotID: nil,
                source: .external, behavior: .event,
                schedule: OccurrenceSchedule(mode: .fixed, moveable: false),
                writePolicy: .none,   // never write external events
                title: m.title,
                icon: m.isVirtual ? "video.fill" : (m.hasPhysicalLocation ? "mappin.and.ellipse" : "calendar"),
                tint: .gray,
                start: m.start, end: m.end,
                externalEventID: m.eventID, meeting: m)
        }
    }

    /// All-day events, one occurrence per day they cover: untimed, so they sit in the day's
    /// "No time" row; the whole day as their span, which is what a Busy one blocks.
    static func allDay(_ events: [MeetingInfo], calendar: Calendar = .current) -> [Occurrence] {
        events.flatMap { event -> [Occurrence] in
            let end = event.end ?? calendar.date(byAdding: .day, value: 1, to: event.start) ?? event.start
            return AllDayEvents.days(from: event.start, to: end, calendar: calendar).map { day in
                let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                return Occurrence(
                    id: "allday:\(event.eventID ?? event.id):\(Int(day.timeIntervalSince1970))",
                    seriesID: nil, slotID: nil,
                    source: .external, behavior: .allDay,
                    schedule: OccurrenceSchedule(mode: .fixed, moveable: false),
                    writePolicy: .none,   // never write the event itself; its busy copies are write-back's
                    title: event.title,
                    icon: "calendar",
                    tint: .gray,
                    start: day, end: next, hasScheduledTime: false,
                    externalEventID: event.eventID, meeting: event)
            }
        }
    }

    /// Read-only occupancy recovered from provider-synced Banana travel markers. This is how a
    /// device that did not calculate the route still keeps its own Re-plan operation out of the
    /// transit interval. `source == .external` prevents write-back from reflecting it again.
    static func syncedTravelBlocks(_ blocks: [CalendarSyncedTravelBlock]) -> [Occurrence] {
        blocks.map { block in
            Occurrence(
                id: block.appItemID,
                seriesID: nil, slotID: nil,
                source: .external, behavior: .block,
                schedule: OccurrenceSchedule(mode: .fixed, moveable: false),
                writePolicy: .busy,
                title: block.title,
                icon: "car.fill", tint: .orange,
                start: block.start, end: block.end,
                hasScheduledTime: true
            )
        }
    }

    // MARK: - Tasks (Apple Reminders)

    /// Reminders with a due date within the horizon → task occurrences. Timed reminders sit
    /// at their due time; day-level ones sit at 9am on their due day.
    /// `anchored`: when a reminder tied to a moment (`ReminderAnchors`) is due today — given the
    /// reminder and its instance's own due time — or nil for one that isn't.
    /// `missedBefore`: how many were missed before a reminder's stored instance, which Banana keeps
    /// once it has moved the reminder on to it (`MissedRepeats`).
    static func tasks(_ tasks: [TaskInfo], horizonDays: Int, now: Date, calendar: Calendar = .current,
                      anchored: ((TaskInfo, Date) -> AnchoredTiming.Due?)? = nil,
                      missedBefore: ((TaskInfo) -> Int?)? = nil) -> [Occurrence] {
        let startDay = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: startDay) else { return [] }
        return tasks.flatMap { t -> [Occurrence] in
            guard let stored = t.due else { return [] }
            // A repeating one is overdue until its next instance's day begins; then that one is
            // the one to do (`ReminderRollover`). Yesterday's creatine stood in for today's, which
            // wasn't shown at all — and ticking it marked yesterday done.
            let rolled = t.isCompleted
                ? (due: stored, missed: 0)
                : ReminderRollover.current(storedDue: stored, recurrence: t.recurrence, now: now, calendar: calendar)
            let due = rolled.due
            let missedCount = t.isCompleted ? 0 : rolled.missed + (missedBefore?(t) ?? 0)
            let dueDates = recurrenceDates(
                startingAt: due,
                recurrence: t.recurrence,
                completed: t.isCompleted,
                now: now,
                before: end,
                calendar: calendar
            )
            return dueDates.map { occurrenceDue in
            // Natural slot: at the due time (timed) or 9am on the due day (day-level); today's
            // instance of one tied to a moment, around that moment (`AnchoredTiming.taskTiming`).
            // Any incomplete, past-due task is pulled up to "now" so it sits below the
            // current-time line — actionable, not buried in the past.
            let anchorDue = !t.isCompleted && calendar.isDate(occurrenceDue, inSameDayAs: now)
                ? anchored?(t, occurrenceDue) : nil
            let timing = AnchoredTiming.taskTiming(due: occurrenceDue, hasTime: t.hasTime, completed: t.isCompleted,
                                                   anchored: anchorDue, now: now, calendar: calendar)
            let start = timing.start
            let pastDue = timing.overdue
            let minutes = TaskDurationStore.shared.minutes(for: t.id, externalID: t.externalID)
            let duration = TimeInterval(minutes) * 60
            let constraints = OccurrenceConstraints(duration: duration, deadline: timing.deadline,
                                                    priority: t.priority == 0 ? 5 : t.priority)
            let occurrenceID = ReminderRollover.occurrenceID(
                reminder: t.id, instanceDue: t.recurrence == .never ? nil : occurrenceDue)
            return Occurrence(
                id: occurrenceID,
                seriesID: nil, slotID: nil,
                source: .authored, behavior: .task,
                schedule: OccurrenceSchedule(mode: .flexible, moveable: true, constraints: constraints),
                writePolicy: .busy,   // placed tasks become calendar blocks (write-back go-live)
                title: t.title, icon: "checklist", tint: .green,
                start: start, end: start.addingTimeInterval(duration),
                hasScheduledTime: timing.hasScheduledTime,
                skipped: timing.skipped, completed: t.isCompleted, completedAt: t.completedAt, overdue: pastDue,
                reminderID: t.id,
                reminderExternalID: t.externalID,
                missed: occurrenceDue == due && missedCount > 0 ? ReminderMissed(count: missedCount, every: t.recurrence) : nil,
                waitingFor: timing.waitingFor)
            }
        }
    }

    /// EventKit returns a recurring reminder as one reminder carrying a rule, not as every future
    /// instance. Expand the lightweight planner occurrences ourselves so write-back can reserve the
    /// entire planning horizon. The underlying Reminder remains the single source of truth.
    private static func recurrenceDates(
        startingAt due: Date,
        recurrence: CalendarItemRecurrence,
        completed: Bool,
        now: Date,
        before end: Date,
        calendar: Calendar
    ) -> [Date] {
        guard due < end else { return [] }
        guard !completed, recurrence != .never else { return [due] }

        let component: Calendar.Component
        switch recurrence {
        case .never: return [due]
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        }

        var dates = [due]
        guard var candidate = calendar.date(byAdding: component, value: 1, to: due) else {
            return dates
        }

        // A reminder can be years overdue. Jump close to the live horizon before stepping rather
        // than burning one loop per missed day; only the single outstanding due occurrence is kept.
        if candidate < now {
            let difference = calendar.dateComponents([component], from: candidate, to: now)
                .value(for: component) ?? 0
            if difference > 0,
               let advanced = calendar.date(byAdding: component, value: difference, to: candidate) {
                candidate = advanced
            }
            while candidate < now,
                  let next = calendar.date(byAdding: component, value: 1, to: candidate) {
                candidate = next
            }
        }

        while candidate < end {
            dates.append(candidate)
            guard let next = calendar.date(byAdding: component, value: 1, to: candidate) else { break }
            candidate = next
        }
        return dates
    }

    // MARK: - One-off alarms (ad-hoc, set from Today)

    /// The user's one-off alarms become point occurrences on the timeline, so an ad-hoc
    /// "wake me at 4pm" shows inline alongside cues and meetings — not just in the sheet.
    static func oneOffAlarms(_ alarms: [OneOffAlarm]) -> [Occurrence] {
        alarms.map { a in
            Occurrence(
                id: "alarm:\(a.id.uuidString)",
                seriesID: nil, slotID: nil,
                source: .authored, behavior: .alarm,
                schedule: OccurrenceSchedule(mode: .fixed, moveable: false),
                writePolicy: .none,   // local alarm, never written to the calendar
                title: a.label.isEmpty ? "Alarm" : a.label,
                icon: "alarm", tint: .orange,
                start: a.fire, end: nil, hasScheduledTime: true)
        }
    }

    // MARK: - Derived (computed blocks without their own cue)

    /// Bedtime blocks from the wake plan. (Wind-down/Sleep *cues* are authored; this is only
    /// for a derived bedtime marker when no cue covers it — kept minimal for L1.)
    static func derived(plan: WakePlan?, calendar: Calendar = .current) -> [Occurrence] {
        guard let plan else { return [] }
        return plan.days.compactMap { day -> Occurrence? in
            guard let bedtime = day.bedtime else { return nil }
            return Occurrence(
                id: Occurrence.makeID(series: "derived.bedtime", slot: "main", day: bedtime),
                seriesID: "derived.bedtime", slotID: "main",
                source: .derived, behavior: .block,
                schedule: OccurrenceSchedule(mode: .derived, moveable: false),
                writePolicy: .none,   // informational; not written in L1
                title: "Bedtime", icon: "bed.double.fill", tint: .indigo,
                start: bedtime, end: nil,
                routineID: nil)
        }
    }
}
