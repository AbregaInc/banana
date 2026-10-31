import Foundation

/// Which upcoming events get a "starting soon" notification, and when each one fires.
///
/// Banana owns its own alerts. It does not inspect whether an event carries a calendar alarm and
/// stay quiet on the assumption that something else will announce it — an alarm on the data says
/// nothing about whether any app is permitted to show it, and no API can tell us whether Calendar
/// or Google's own notifications are switched on. An earlier version guessed, and the guess failed
/// in both directions: silence when Calendar was muted, and doubling up on Google events fetched
/// directly. Whether another app also notifies is that app's setting to manage, not ours.
///
/// Kept as a pure function because the decisions here are all easy to get quietly wrong and
/// impossible to notice afterwards: a notification that never arrives looks identical to an event
/// that simply had none.
/// Alert candidates derived once per timeline snapshot and mute set, never once per view body.
///
/// `PlanPromptCard` reads the next alert sample on every refresh. Scanning the whole timeline for
/// it took 100–135 ms of main-thread time every few seconds on an iPhone 14 Pro with 36,500
/// events (`docs/performance/scale-results/calendar-viewport-device-20261029`). The revision is
/// bumped whenever `OccurrenceStore.occurrences` is assigned; the mute set is the other input.
struct AlertCandidateCache {
    private var revision = Int.min
    private var muted: Set<String> = []
    private(set) var candidates: [EventAlertPlan.Candidate] = []
    /// How many times the scan actually ran: the tests' witness that reads are free.
    private(set) var computations = 0

    mutating func candidates(revision: Int, muted: Set<String>,
                             compute: () -> [EventAlertPlan.Candidate]) -> [EventAlertPlan.Candidate] {
        if revision != self.revision || muted != self.muted {
            candidates = compute()
            self.revision = revision
            self.muted = muted
            computations += 1
        }
        return candidates
    }
}

enum EventAlertPlan {

    /// A merged meeting rings if any calendar it belongs to is enabled for alerts.
    /// Calendar info ids are decoded because the setting uses portable raw Google ids.
    static func allows(calendarID: String?, alsoOn: [String] = [], muted: Set<String>) -> Bool {
        let calendars = ([calendarID].compactMap { $0 } + alsoOn)
            .map { GoogleCalendarIDs.rawCalendarID(from: $0) ?? $0 }
        let quiet = Set(muted.map { GoogleCalendarIDs.rawCalendarID(from: $0) ?? $0 })
        return calendars.isEmpty || calendars.contains { !quiet.contains($0) }
    }

    /// One event worth notifying about.
    struct Candidate: Hashable, Sendable {
        var id: String
        var title: String
        var start: Date
    }

    struct Item: Hashable, Sendable {
        var id: String
        var title: String
        var start: Date
        var fireAt: Date
    }

    /// How many event alerts may be pending at once.
    ///
    /// iOS keeps at most 64 pending notifications per app and silently drops the rest. Bedtimes,
    /// wind-downs, leave-by and commute alerts all draw on the same 64, so events take a bounded
    /// share instead of filling the queue and starving the alerts that were there first.
    static let maximumPending = 24

    /// How far ahead to schedule. Beyond this the calendar has usually changed anyway, and every
    /// slot spent on next week is a slot not spent on tomorrow.
    static let horizon: TimeInterval = 7 * 24 * 60 * 60

    /// Every lead time a new event gets unless the listener changes it: one as it starts, and one
    /// five minutes ahead so there is time to actually get there.
    static let defaultLeads = [5, 0]

    /// The lead times offered in Settings.
    static let offeredLeads = [0, 5, 10, 15, 30]

    /// The alerts to schedule, soonest first.
    ///
    /// - Parameters:
    ///   - leads: minutes before the start. 0 means at the moment it starts. Empty means off.
    static func items(from candidates: [Candidate],
                      leads: [Int],
                      now: Date,
                      limit: Int = maximumPending,
                      horizon: TimeInterval = horizon) -> [Item] {
        guard limit > 0, !leads.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(horizon)
        let ordered = Set(leads).sorted(by: >)   // furthest ahead first

        var seenEvents = Set<String>()
        var items: [Item] = []
        for candidate in candidates {
            guard candidate.start > now, candidate.start <= cutoff else { continue }
            guard seenEvents.insert(candidate.id).inserted else { continue }

            var forEvent: [Item] = []
            for lead in ordered {
                let fireAt = candidate.start.addingTimeInterval(-Double(lead) * 60)
                guard fireAt > now else { continue }
                forEvent.append(Item(id: "\(candidate.id)#\(lead)",
                                     title: candidate.title,
                                     start: candidate.start,
                                     fireAt: fireAt))
            }
            // Every lead has already passed but the event has not started — an event five minutes
            // away with only a fifteen-minute lead, say. Announce it now rather than silently
            // dropping it. Only when nothing else would fire, so the common case does not get an
            // extra notification on top of the one already coming.
            if forEvent.isEmpty {
                forEvent.append(Item(id: "\(candidate.id)#now",
                                     title: candidate.title,
                                     start: candidate.start,
                                     fireAt: now.addingTimeInterval(1)))
            }
            items.append(contentsOf: forEvent)
        }
        return items.sorted { $0.fireAt < $1.fireAt }.prefix(limit).map { $0 }
    }

    /// The body text for one alert. Says the time, because a notification read three minutes late
    /// is otherwise indistinguishable from one read on time.
    static func body(for item: Item, now: Date, formatter: DateFormatter) -> String {
        let minutes = Int((item.start.timeIntervalSince(now) / 60).rounded())
        if minutes <= 0 { return "Starting now." }
        if minutes == 1 { return "Starts in 1 minute, at \(formatter.string(from: item.start))." }
        if minutes < 60 { return "Starts in \(minutes) minutes, at \(formatter.string(from: item.start))." }
        return "Starts at \(formatter.string(from: item.start))."
    }
}
