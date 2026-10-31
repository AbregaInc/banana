import Foundation

/// All-day events: which show, and which block (docs/design/ALL-DAY-EVENTS.md).
///
/// **One rule: an all-day event shows if it's yours, and blocks if your copy says Busy.**
/// - *Yours:* on a calendar you own — your accounts' calendars, which is also where an invitation
///   you've accepted lands — unless you've hidden that calendar's all-day events; on anyone else's
///   (a shared calendar, a subscribed feed of launches or holidays) only if you've switched it on.
/// - *Busy:* Google's own "Show as", on your copy. Google makes all-day events Free by default,
///   an accepted all-day invitation included, so a day trip someone invites you to blocks nothing
///   until you say so ("Block this day"). Free ones show and block nothing.
/// - Google's working-location markers ("Home", "Office") are a status, not an event: never shown.
///
/// Pure, for tests.
enum AllDayEvents {
    /// Whether a calendar's all-day events show. `hidden`: your calendars you've hidden them on;
    /// `shown`: other people's and subscribed calendars you've shown them on. Raw Google ids.
    static func shows(calendarID: String, isOwner: Bool, hidden: Set<String>, shown: Set<String>) -> Bool {
        isOwner ? !hidden.contains(calendarID) : shown.contains(calendarID)
    }

    /// The choices you've made, by raw Google calendar id — synced as settings
    /// (`SmartScheduleSettings.allDayHiddenCalendarIDs` / `allDayShownCalendarIDs`).
    struct Choice: Equatable, Sendable {
        var hidden: Set<String> = []
        var shown: Set<String> = []
        /// Events you've hidden, by title (`titleKey`) — so a birthday you don't care about
        /// stays hidden every year. Google won't let an app delete a birthday (they come from
        /// Google Contacts), and nothing should be on your calendar you can't get rid of.
        var hiddenTitles: Set<String> = []
        /// Google's birthdays from your contacts, all at once.
        var showsBirthdays = true
    }

    /// How an all-day event's time reads where a timed one says "9–10 AM": "All day", or
    /// "All day · 2 days". Its midnights are not a time: the Mac's event panel said "12 AM–12 AM".
    static func timeText(from start: Date, to end: Date?, calendar: Calendar = .current) -> String {
        let count = days(from: start, to: end ?? start.addingTimeInterval(86_400), calendar: calendar).count
        return count > 1 ? "All day \u{00B7} \(count) days" : "All day"
    }

    /// The order a day's all-day events show in: the ones that block the day first, otherwise as
    /// they came. Where only some fit, a day you can't be booked on is never the one left out.
    static func busyFirst<Event>(_ events: [Event], blocks: (Event) -> Bool) -> [Event] {
        events.filter(blocks) + events.filter { !blocks($0) }
    }

    /// Where there's room for `limit`: the ones shown, and how many are behind "+N more".
    static func fitting<Event>(_ events: [Event], limit: Int) -> (shown: [Event], more: Int) {
        (Array(events.prefix(limit)), max(0, events.count - limit))
    }

    /// The key a title is hidden by: trimmed, lowercased.
    static func titleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Hidden by you: its title, or every birthday.
    static func isHidden(title: String, eventType: String?, choice: Choice) -> Bool {
        (!choice.showsBirthdays && eventType == "birthday") || choice.hiddenTitles.contains(titleKey(title))
    }

    /// Google's own kinds that are a status rather than something on your day.
    static let statusEventTypes: Set<String> = ["workingLocation"]

    static func isEvent(eventType: String?) -> Bool {
        !statusEventTypes.contains(eventType ?? "default")
    }

    /// The days an all-day event covers: its first day's start to the start of the day after its
    /// last, one entry per day. A trip Friday to Sunday is three days, each its own.
    static func days(from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: start)
        while day < end, days.count < 62 {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
}
