import Foundation

/// The one thing the plan may ask for above the day, most pressing first (`PlanPromptCard`):
/// a calendar that isn't connected, then a trip timed to a guessed place (it has a clock on it),
/// then what a just-connected calendar makes worth asking, each at the moment its reason is on
/// the screen, then the rest of setup. One at a time: stacked, they pushed the day itself off
/// the screen.
enum PlanPrompt: Equatable {
    case connectCalendar
    case placeQuestion
    /// Which calendars keep each other busy. It was a sheet between Google's sign-in and the
    /// plan; now the plan comes first and this asks from it. Nothing is written until answered.
    case busyCalendars
    /// With a sample made from the person's next real meeting.
    case notifications
    case reminders
    case finishSetup

    /// What is still open to ask from the plan. Each is false once answered or put off
    /// ("Not now" sends it to the setup list for good).
    struct Open: Equatable {
        var busyCalendars = false
        var notifications = false
        var reminders = false
    }

    static func current(calendarConnected: Bool, hasPlaceQuestion: Bool, open: Open = Open()) -> PlanPrompt {
        if !calendarConnected { return .connectCalendar }
        if hasPlaceQuestion { return .placeQuestion }
        if open.busyCalendars { return .busyCalendars }
        if open.notifications { return .notifications }
        if open.reminders { return .reminders }
        return .finishSetup
    }
}

/// Whether busy blocks may switch themselves on at a first Google connection.
///
/// They used to, the moment an account connected, with the sheet that explains them shown
/// straight after. That sheet no longer stands between the sign-in and the plan, so the rule is
/// now: nothing is written to someone's calendars until they have seen the question and said
/// yes. A device that already has a choice, its own or one synced from another device, is not
/// asked again and is not changed.
enum WriteBackStart {
    static func mayStartByDefault(questionAnswered: Bool, hasPreference: Bool, sharedChoice: Bool?) -> Bool {
        questionAnswered && !hasPreference && sharedChoice == nil
    }

    /// Whether busy blocks already have an answer, here or on another device.
    static func settled(questionAnswered: Bool, hasPreference: Bool, sharedChoice: Bool?) -> Bool {
        questionAnswered || hasPreference || sharedChoice != nil
    }

    /// Whether the plan should ask. Only someone connected, with a calendar of their own to
    /// write to, and no choice made anywhere yet.
    static func needsAnswer(connected: Bool, ownsACalendar: Bool, questionAnswered: Bool,
                            hasPreference: Bool, sharedChoice: Bool?) -> Bool {
        connected && ownsACalendar && !questionAnswered && !hasPreference && sharedChoice == nil
    }
}

/// The alert Banana would send next, as a sample for the card that asks to send them: the
/// person's own next meeting, in the words the real alert uses (`EventAlertPlan`).
enum NextAlertSample {
    static func sample(candidates: [EventAlertPlan.Candidate], leads: [Int], now: Date,
                       formatter: DateFormatter) -> (title: String, body: String)? {
        guard let item = EventAlertPlan.items(from: candidates, leads: leads, now: now)
            .min(by: { $0.fireAt < $1.fireAt }) else { return nil }
        return (item.title, EventAlertPlan.body(for: item, now: item.fireAt, formatter: formatter))
    }
}
