import Foundation

/// When a Taken item's reminder rings, one day at a time. Pure, for tests.
///
/// A fixed-time dose used to be one notification repeating daily, which can't skip a day: it rang
/// at nine whether or not the dose had been ticked at eight. Every dose is now rung day by day,
/// as the ones that follow a moment already were, and today's is left out once the dose is marked.
enum DoseReminderPlan {
    /// How many days past today are scheduled. iOS keeps an app's 64 soonest pending
    /// notifications and drops the rest, and the plan's event alerts want some of those: about
    /// forty for doses, a week ahead when there are few and never less than three days.
    static func daysAhead(reminders: Int) -> Int {
        min(6, max(2, 40 / max(reminders, 1) - 1))
    }

    /// When a fixed-time dose rings on a day: at its time. Not today once it is marked (taken or
    /// skipped), and not for a time that has already gone by.
    static func fixedTime(usual: Date, isToday: Bool, marked: Bool, now: Date) -> Date? {
        guard isToday else { return usual }
        return !marked && usual > now ? usual : nil
    }

    /// The Taken item a reminder is for, from its notification's id
    /// ("banana.supplement.<id>.<day>", or "banana.supplement.<id>" from before days).
    static func supplementID(notificationID: String, prefix: String) -> UUID? {
        guard notificationID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(notificationID.dropFirst(prefix.count).prefix(36)))
    }
}
