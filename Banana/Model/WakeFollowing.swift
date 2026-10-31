import Foundation

/// When a routine that follows your wake-up starts on a day: that day's wake, plus its minutes.
///
/// The wake it follows is the one the Wake routine rings for: the smart schedule's time for the
/// day (which moves with the first meeting), or the Wake routine's own time on a day the schedule
/// has none for. A workout routine waits for the Watch to say a workout has begun; waking has a
/// time ahead of it, so this one is on the day at that time and moves when the wake does. With no
/// Wake routine at all there is nothing to follow, and it keeps its own time. Pure, for tests.
enum WakeFollowing {
    typealias Clock = (hour: Int, minute: Int)

    static func start(on day: Date, plannedWake: Date?, wakeRoutine: Clock?, own: Clock,
                      minutesAfter: Int, calendar: Calendar = .current) -> Date? {
        let wake = plannedWake
            ?? wakeRoutine.flatMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: day) }
        if let wake { return wake.addingTimeInterval(TimeInterval(max(0, minutesAfter) * 60)) }
        return calendar.date(bySettingHour: own.hour, minute: own.minute, second: 0, of: day)
    }

    /// "When you wake up", "15 min after you wake up".
    static func describe(minutesAfter: Int) -> String {
        minutesAfter > 0 ? "\(minutesAfter) min after you wake up" : "When you wake up"
    }

    /// The offsets the editor offers.
    static let minuteChoices = [5, 10, 15, 20, 30, 45, 60, 90]
}
