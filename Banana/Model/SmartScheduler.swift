import Foundation

/// Pure algorithm that turns the week's first-meeting times into a wake plan.
///
/// Policy (consistent weekly anchor):
///  • Days whose required wake is ≥ the floor are "routine" and define one
///    consistent anchor = the earliest of them, floored.
///  • Days whose required wake is below the floor are one-off early events
///    (e.g. a 4 AM flight): they wake you early *that day only*, bypassing the
///    floor, and do not drag the anchor.
///  • Meeting-free days follow the weekend mode (hold / sleep in / later).
enum SmartScheduler {
    static func plan(settings: SmartScheduleSettings,
                     firstMeetings: [Date: Date],
                     travelMinutes: [Date: Int] = [:],
                     healthWakeShift: Int = 0,       // minutes later on FREE days only (≤45)
                     healthBedtimeEarlier: Int = 0,  // minutes earlier to bed, to catch up
                     days: Int = 7,
                     now: Date = Date()) -> WakePlan {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        // The look-ahead days with their first meeting (required wake includes travel).
        struct Raw { let date: Date; let weekday: Int; let meeting: Date?; let required: Int? }
        var raws: [Raw] = []
        for offset in 0..<days {
            guard let date = cal.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            let meeting = firstMeetings[date]
            let travel = travelMinutes[date] ?? 0
            let required = meeting.map { max(0, minutes($0) - settings.prepBufferMinutes - travel) }
            raws.append(Raw(date: date, weekday: cal.component(.weekday, from: date), meeting: meeting, required: required))
        }

        let floor = settings.earliestWakeMinutes
        let wakeShift = max(0, min(45, healthWakeShift))   // regularity guard: never move more than 45m
        let bedEarlier = max(0, min(45, healthBedtimeEarlier))
        let meetingDays = raws.compactMap { $0.required }
        let routine = meetingDays.filter { $0 >= floor }

        let anchor: Int?
        if let earliestRoutine = routine.min() {
            anchor = max(floor, earliestRoutine)
        } else if let earliestAny = meetingDays.min() {
            anchor = earliestAny                    // whole routine is genuinely pre-floor
        } else {
            anchor = nil                            // no meetings at all
        }
        let effectiveAnchor = anchor ?? settings.defaultWakeMinutes

        var planDays: [WakePlan.Day] = []
        for raw in raws {
            let wakeMinutes: Int?
            if let required = raw.required {
                if required < floor && !routine.isEmpty {
                    wakeMinutes = required          // one-off early exception, floor bypassed
                } else {
                    wakeMinutes = effectiveAnchor   // routine meeting day → anchor
                }
            } else {
                // No meeting this day → weekend mode. Health-adaptive shift applies here
                // (free days only), never on meeting/anchor days — keeps the rhythm.
                switch settings.weekendMode {
                case .hold:    wakeMinutes = clampToDay(effectiveAnchor + wakeShift)
                case .sleepIn: wakeMinutes = nil
                case .later:   wakeMinutes = clampToDay(effectiveAnchor + settings.offDayShiftMinutes + wakeShift)
                }
            }

            let wake = wakeMinutes.flatMap { time(on: raw.date, minutes: $0, cal: cal) }
            let bedtime = wake.map { $0.addingTimeInterval(TimeInterval(-(settings.sleepTargetMinutes + settings.fallAsleepMinutes + bedEarlier) * 60)) }
            planDays.append(.init(date: raw.date, weekday: raw.weekday, firstMeeting: raw.meeting, wake: wake, bedtime: bedtime))
        }

        var explanation = buildExplanation(settings: settings, anchor: anchor,
                                           effectiveAnchor: effectiveAnchor,
                                           raws: raws.map { ($0.date, $0.required, $0.meeting) },
                                           floor: floor)
        if wakeShift > 0 || bedEarlier > 0 {
            var notes: [String] = []
            if wakeShift > 0 { notes.append("sleeping in +\(wakeShift)m on free days") }
            if bedEarlier > 0 { notes.append("bed \(bedEarlier)m earlier") }
            explanation += " Recovery: " + notes.joined(separator: ", ") + "."
        }

        return WakePlan(anchorMinutes: anchor, days: planDays, explanation: explanation)
    }

    // MARK: - Helpers

    private static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func clampToDay(_ m: Int) -> Int { min(max(0, m), 24 * 60 - 1) }

    private static func time(on day: Date, minutes m: Int, cal: Calendar) -> Date? {
        let c = clampToDay(m)
        return cal.date(bySettingHour: c / 60, minute: c % 60, second: 0, of: day)
    }

    static func label(minutesOfDay m: Int) -> String {
        var comps = DateComponents(); comps.hour = m / 60; comps.minute = m % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: date)
    }

    private static func buildExplanation(settings: SmartScheduleSettings, anchor: Int?,
                                         effectiveAnchor: Int, raws: [(Date, Int?, Date?)], floor: Int) -> String {
        let sleepH = Double(settings.sleepTargetMinutes) / 60
        let sleepStr = sleepH == sleepH.rounded() ? "\(Int(sleepH))h" : String(format: "%.1fh", sleepH)
        let bedMinutes = clampToDay(effectiveAnchor - (settings.sleepTargetMinutes + settings.fallAsleepMinutes) + 24 * 60) % (24 * 60)
        let bedStr = label(minutesOfDay: bedMinutes)

        guard anchor != nil else {
            return "No meetings in the next 7 days — waking at your default \(label(minutesOfDay: settings.defaultWakeMinutes)). Bed by \(bedStr) for \(sleepStr)."
        }
        // Find the routine day that set the anchor.
        let routine = raws.compactMap { entry -> (Date, Int, Date)? in
            guard let r = entry.1, let meeting = entry.2, r >= floor else { return nil }
            return (entry.0, r, meeting)
        }
        let wakeStr = label(minutesOfDay: effectiveAnchor)
        if let driver = routine.min(by: { $0.1 < $1.1 }) {
            let day = driver.0.formatted(.dateTime.weekday(.abbreviated))
            let meetTime = driver.2.formatted(date: .omitted, time: .shortened)
            let travelNote = (settings.accountForTravel && settings.hasHome) ? " (incl. travel)" : ""
            return "Waking \(wakeStr) — earliest meeting \(day) \(meetTime)\(travelNote). Bed by \(bedStr) for \(sleepStr)."
        }
        return "Waking \(wakeStr). Bed by \(bedStr) for \(sleepStr)."
    }
}
