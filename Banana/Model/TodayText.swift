import Foundation

/// Morning, afternoon or evening — how Today groups the day, the way people talk about it.
enum DayPart: String, CaseIterable {
    case morning = "Morning", afternoon = "Afternoon", evening = "Evening"

    static func of(_ date: Date, calendar: Calendar = .current) -> DayPart {
        switch calendar.component(.hour, from: date) {
        case ..<12: .morning
        case 12..<17: .afternoon
        default: .evening
        }
    }
}

/// The words Today uses for time: countdowns and free gaps.
enum TodayText {
    /// The briefing's greeting for the hour it is opened at. It said "Good morning" at any hour:
    /// it opens after the wake alarm, and from the plan's menu whenever you like.
    static func greeting(at date: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// "in 12 min", "in 1 hr 5 min", "now" — how long until `date`, rounded up to the minute so
    /// "in 1 min" never shows for something already due.
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 30 else { return "now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) hr" : "in \(h) hr \(m) min"
    }

    /// Up next, in words: "Leave in 12 min" when there's a trip to make, else "Starts in 25 min" —
    /// only within a few hours; further out the clock time says it better.
    static func upNextLead(start: Date, leaveBy: Date?, now: Date = Date(),
                           horizon: TimeInterval = 3 * 3_600) -> String? {
        if let leaveBy, leaveBy > now.addingTimeInterval(-60), leaveBy.timeIntervalSince(now) < horizon {
            return leaveBy <= now.addingTimeInterval(30) ? "Leave now" : "Leave \(countdown(to: leaveBy, now: now))"
        }
        guard start > now, start.timeIntervalSince(now) < horizon else { return nil }
        return "Starts \(countdown(to: start, now: now))"
    }

    /// Free time worth naming: "45 min free", "2 hr free". nil under half an hour — a
    /// ten-minute gap isn't time you'd plan anything into.
    static func freeGap(from start: Date, to end: Date, minimum: TimeInterval = 30 * 60) -> String? {
        let seconds = end.timeIntervalSince(start)
        guard seconds >= minimum else { return nil }
        let minutes = Int(seconds / 60)
        // Rounded to 5 minutes: "47 min free" is false precision.
        let rounded = minutes >= 60 ? (minutes / 15) * 15 : (minutes / 5) * 5
        if rounded < 60 { return "\(rounded) min free" }
        let h = rounded / 60, m = rounded % 60
        return m == 0 ? "\(h) hr free" : "\(h) hr \(m) min free"
    }
}
