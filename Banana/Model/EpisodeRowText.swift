import Foundation

/// The words on an episode row: when it came out, and how much is left.
enum EpisodeRowText {
    /// "Today", "Yesterday", "Tuesday" within the week, then "Sep 25" (with the year once it's
    /// not this year's) — the date line above the title.
    static func dateLine(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 99
        var style = Date.FormatStyle(locale: locale, calendar: calendar)
        if (2..<7).contains(days) { return date.formatted(style.weekday(.wide)) }
        style = style.month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// "1h 5m", "45m" — a length. Under a minute reads "1m", never "0m".
    static func length(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds < 1_000_000 else { return "\u{2014}" }   // a feed can report anything
        let m = max(1, Int((seconds / 60).rounded()))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// What the play capsule says: "20m left" part-way through, the length before starting,
    /// "Played" after. nil when there's nothing honest to say (no duration, not started).
    static func capsule(duration: Double?, progress: Double?, completed: Bool) -> String? {
        if completed { return "Played" }
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        if let progress, progress > 0.01, progress < 0.99 {
            return "\(length(duration * (1 - progress))) left"
        }
        return length(duration)
    }
}
