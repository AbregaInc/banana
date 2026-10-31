import Foundation

/// What's waiting on you, for the badges on the app icon, the tab bar and the sidebar
/// (`ActionBadges`): reminders that are overdue, meals to log, and doses due that haven't been
/// marked. Pure, for tests.
enum ActionItems {
    struct Counts: Equatable, Sendable {
        /// Overdue reminders (the Plan tab).
        var plan = 0
        /// Meals that need you: a photo asking what it was, an estimate to check, one that failed.
        var food = 0
        /// Doses due today and not yet marked taken or skipped (the Taken tab).
        var taken = 0

        var nutrition: Int { food + taken }
        var total: Int { plan + food + taken }
    }

    /// Meals waiting on the person — not the ones being estimated, which need nothing from them yet.
    static func food(_ items: [MealInboxItem]) -> Int {
        items.filter(foodNeedsAttention).count
    }

    static func foodNeedsAttention(_ item: MealInboxItem) -> Bool {
        item.state == .awaitingNote || item.state == .proposed || item.state == .failed
    }

    /// An explicitly scheduled routine is due from its time, until completed or skipped.
    /// Untimed routines have no deadline to invent; they stay in the day's routine moments.
    static func routineDueSince(start: Date, hasTime: Bool, completed: Bool, skipped: Bool, now: Date = Date()) -> Date? {
        hasTime && !completed && !skipped && start <= now ? start : nil
    }

    /// Today's doses whose time has come and that aren't marked yet. A dose later today isn't
    /// counted until its time: there's nothing to do about it before then — nor one waiting for
    /// its moment ("after your workout", `AnchoredTiming`). `due`: when each is due today, nil
    /// while it waits; its own time when not given.
    static func dosesDue(_ supplements: [SupplementSchedule], marked: (UUID) -> Bool,
                        due: ((SupplementSchedule) -> Date?)? = nil,
                        now: Date = Date(), calendar: Calendar = .current) -> Int {
        supplements.filter { supplement in
            dueSince(supplement, marked: marked(supplement.id), due: due.map { $0(supplement) } ?? usual(supplement, now, calendar),
                     now: now) != nil
        }.count
    }

    /// When a dose became due, if it's due and not marked: what the badge counts and what Taken
    /// shows in yellow — one rule for both. `due`: when it's due today, nil while it waits.
    static func dueSince(_ supplement: SupplementSchedule, marked: Bool, due: Date?, now: Date = Date()) -> Date? {
        guard supplement.enabled, !marked, let due, due <= now else { return nil }
        return due
    }

    /// What a due dose's row says in place of its time: "Due now" in its first minute, then
    /// "Due since 8:00 AM". One wording for the phone's Taken tab and the wide Nutrition page.
    static func dueText(since: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(since) < 60
            ? "Due now"
            : "Due since \(since.formatted(date: .omitted, time: .shortened))"
    }

    private static func usual(_ supplement: SupplementSchedule, _ now: Date, _ calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: supplement.safeHour, minute: supplement.safeMinute, second: 0, of: now)
    }
}
