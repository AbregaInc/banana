import Foundation

/// What the menu bar says right now: the meeting in progress with its time left, else the next
/// one with how long until it starts. Pure, so it can be tested and reused by the join shortcut.
enum MenuBarAgendaState {
    struct Moment: Equatable {
        enum Kind: Equatable { case now, next }
        let kind: Kind
        let meeting: MeetingInfo
        /// Minutes left (now) or minutes until it starts (next), rounded up.
        let minutes: Int
    }

    /// The meeting in progress, or else the next one today. Free-marked events are skipped for
    /// the headline — they are on your day but not what you need to be told about.
    static func moment(in meetings: [MeetingInfo], at now: Date) -> Moment? {
        let timed = meetings.filter { !$0.showsAsFree }.sorted { $0.start < $1.start }
        if let current = timed.last(where: { $0.start <= now && ($0.end ?? $0.start) > now }) {
            let end = current.end ?? current.start
            return Moment(kind: .now, meeting: current, minutes: minutes(from: now, to: end))
        }
        if let next = timed.first(where: { $0.start > now }) {
            return Moment(kind: .next, meeting: next, minutes: minutes(from: now, to: next.start))
        }
        return nil
    }

    /// The meeting "Join" should open: one in progress with a link, else the next with a link
    /// starting within the hour.
    static func joinable(in meetings: [MeetingInfo], at now: Date) -> MeetingInfo? {
        let linked = meetings.filter { $0.joinURL != nil }.sorted { $0.start < $1.start }
        if let current = linked.last(where: { $0.start.addingTimeInterval(-10 * 60) <= now
                                               && ($0.end ?? $0.start) > now }) {
            return current
        }
        return linked.first { $0.start > now && $0.start.timeIntervalSince(now) <= 60 * 60 }
    }

    /// "45m", "1h 5m", "2h".
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// The menu bar text, kept short: the bar is shared with every other app's items. When the
    /// next meeting has a trip and it's time to think about leaving, that's what it says:
    /// "Leave in 8m · Standup".
    static func label(for moment: Moment?, leaveBy: Date? = nil, now: Date = Date()) -> String? {
        guard let moment else { return nil }
        let title = shortTitle(moment.meeting.title)
        switch moment.kind {
        case .now: return "\(title) · \(duration(moment.minutes)) left"
        case .next:
            if let leaveBy, leaveBy > now.addingTimeInterval(-60), leaveBy.timeIntervalSince(now) <= 60 * 60 {
                let m = minutes(from: now, to: leaveBy)
                return m == 0 ? "Leave now · \(title)" : "Leave in \(duration(m)) · \(title)"
            }
            return "\(title) in \(duration(moment.minutes))"
        }
    }

    static func shortTitle(_ title: String, limit: Int = 22) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) / 60).rounded(.up)))
    }
}
