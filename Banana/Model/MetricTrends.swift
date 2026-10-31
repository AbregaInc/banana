import Foundation

/// How a Health metric is moving, compared fairly: the last N finished days against the N days
/// before them, per day — never an unfinished day, week or month against finished ones, which
/// made every total look like it was falling. A period you've paged back to (last month, Q2) is
/// finished, so it's compared with the one before it the same way.
///
/// Pure, and fed from the daily series in `HealthTrends`, so the phone and the Mac (which has
/// only the synced copy) show the same numbers.
enum TrendWindow: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case week = 7, month = 30, quarter = 90, year = 365

    var id: Int { rawValue }
    var days: Int { rawValue }

    init(_ granularity: RhythmGranularity) {
        switch granularity {
        case .week: self = .week
        case .month: self = .month
        case .quarter: self = .quarter
        case .year: self = .year
        }
    }

    /// "7D", "1Y" — column heads and the picker.
    var shortTitle: String {
        switch self {
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        case .year: "1Y"
        }
    }

    /// "7 days", "12 months".
    var title: String {
        self == .year ? "12 months" : "\(days) days"
    }

    /// Days per point when charting two windows over each other: daily up to a month, weekly
    /// for a quarter, fortnightly for a year — about 7 to 30 points a line.
    var chartBucketDays: Int {
        switch self {
        case .week, .month: 1
        case .quarter: 7
        case .year: 14
        }
    }
}

/// A stretch of whole days, start inclusive, end exclusive.
struct TrendSpan: Hashable, Sendable {
    var start: Date
    var end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

struct MetricTrend: Identifiable, Sendable {
    var kind: MetricKind
    var current: TrendSpan
    var previous: TrendSpan
    /// Per day for totals (steps, energy…); the mean reading for everything else.
    var currentValue: Double?
    var previousValue: Double?
    /// Days with a reading in each span — how much the comparison rests on.
    var currentReadings: Int
    var previousReadings: Int
    /// Totals only: today so far, which neither span includes.
    var today: Double?

    var id: MetricKind { kind }

    /// Smaller moves than this read as flat.
    static let flatThreshold = 0.02

    enum Direction: Sendable { case up, down, flat }

    var change: Double? {
        guard let c = currentValue, let p = previousValue, p != 0 else { return nil }
        return c / p - 1
    }

    var direction: Direction? {
        change.map { abs($0) < Self.flatThreshold ? .flat : ($0 > 0 ? .up : .down) }
    }

    /// Whether the move is good news — nil when flat, or when neither way is better (weight).
    var isBetter: Bool? {
        guard let direction, direction != .flat, let higher = kind.higherIsBetter else { return nil }
        return (direction == .up) == higher
    }
}

extension MetricKind {
    /// A stable name for routes: "steps", "restingHR".
    var trendID: String { String(describing: self) }

    init?(trendID: String) {
        guard let kind = Self.allCases.first(where: { $0.trendID == trendID }) else { return nil }
        self = kind
    }

    /// Added up over a day (steps, energy, exercise, flights) rather than a reading taken at a
    /// moment (heart rate, weight, sleep). Totals compare per day; readings compare as means.
    var isCumulative: Bool {
        switch self {
        case .steps, .activeEnergy, .basalEnergy, .exercise, .flightsClimbed: true
        default: false
        }
    }

    /// The headline value with its per-day unit where it's a total: "20,899 a day".
    func perDay(_ value: Double) -> String {
        isCumulative ? "\(format(value)) a day" : format(value)
    }
}

enum MetricTrends {
    /// What's compared for the period the picker shows: now, the last N finished days (to the
    /// start of today) against the N before; for an earlier period, it against the one before.
    static func spans(for period: RhythmPeriod, calendar: Calendar, now: Date) -> (current: TrendSpan, previous: TrendSpan) {
        guard period.offset < 0 else {
            return spans(window: TrendWindow(period.granularity), calendar: calendar, now: now)
        }
        let current = period.range(calendar, now: now)
        let previous = period.stepped(by: -1).range(calendar, now: now)
        return (TrendSpan(start: current.start, end: current.end), TrendSpan(start: previous.start, end: previous.end))
    }

    static func spans(window: TrendWindow, calendar: Calendar, now: Date) -> (current: TrendSpan, previous: TrendSpan) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -window.days, to: today) ?? today
        let before = calendar.date(byAdding: .day, value: -window.days, to: start) ?? start
        return (TrendSpan(start: start, end: today), TrendSpan(start: before, end: start))
    }

    /// "Last 7 days vs the 7 before" / "August vs the month before".
    static func comparisonLabel(for period: RhythmPeriod, calendar: Calendar, now: Date) -> String {
        guard period.offset < 0 else {
            let window = TrendWindow(period.granularity)
            return window == .year ? "Last 12 months vs the 12 before"
                : "Last \(window.days) days vs the \(window.days) before"
        }
        return "\(period.label(calendar, now: now)) vs the \(period.granularity.rawValue) before"
    }

    static func trend(_ kind: MetricKind, daily: [MetricPoint], current: TrendSpan, previous: TrendSpan,
                      calendar: Calendar, now: Date) -> MetricTrend {
        let firstDay = daily.map(\.date).min().map { calendar.startOfDay(for: $0) }
        let c = value(kind, daily: daily, in: current, firstDay: firstDay, calendar: calendar)
        let p = value(kind, daily: daily, in: previous, firstDay: firstDay, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let todaySoFar = kind.isCumulative && current.end == today
            ? daily.first { calendar.isDate($0.date, inSameDayAs: now) }?.value
            : nil
        return MetricTrend(kind: kind, current: current, previous: previous,
                           currentValue: c.value, previousValue: p.value,
                           currentReadings: c.readings, previousReadings: p.readings,
                           today: todaySoFar)
    }

    /// Every window at once, for the table on a wide screen and a metric's detail: how the last
    /// week, month, quarter and year each compare — short-term and long-term side by side.
    static func ladder(_ kind: MetricKind, daily: [MetricPoint], calendar: Calendar, now: Date) -> [TrendWindow: MetricTrend] {
        Dictionary(uniqueKeysWithValues: TrendWindow.allCases.map { window in
            let spans = spans(window: window, calendar: calendar, now: now)
            return (window, trend(kind, daily: daily, current: spans.current, previous: spans.previous,
                                  calendar: calendar, now: now))
        })
    }

    /// A span's value: a total's average per day — a day without a reading counts as nothing
    /// done, except before the series' first reading, where there's simply no data — or the
    /// mean of a reading's values.
    static func value(_ kind: MetricKind, daily: [MetricPoint], in span: TrendSpan, firstDay: Date?,
                      calendar: Calendar) -> (value: Double?, readings: Int) {
        let inSpan = daily.filter { span.contains($0.date) }
        if kind.isCumulative {
            guard let firstDay else { return (nil, 0) }
            let from = max(span.start, firstDay)
            let days = calendar.dateComponents([.day], from: from, to: span.end).day ?? 0
            guard days > 0 else { return (nil, inSpan.count) }
            return (inSpan.map(\.value).reduce(0, +) / Double(days), inSpan.count)
        }
        guard !inSpan.isEmpty else { return (nil, 0) }
        return (inSpan.map(\.value).reduce(0, +) / Double(inSpan.count), inSpan.count)
    }

    /// A point on a two-window chart: how far into its window (in days), and its value.
    struct ChartPoint: Hashable, Sendable {
        var day: Int
        var value: Double
    }

    /// The two windows' values by how far into each they fall, so they can be drawn over each
    /// other on one axis. Grouped `bucketDays` at a time: totals as their average per day, readings
    /// as their mean.
    static func overlay(_ kind: MetricKind, daily: [MetricPoint], current: TrendSpan, previous: TrendSpan,
                        bucketDays: Int, calendar: Calendar) -> (current: [ChartPoint], previous: [ChartPoint]) {
        let firstDay = daily.map(\.date).min().map { calendar.startOfDay(for: $0) }
        func points(_ span: TrendSpan) -> [ChartPoint] {
            let days = calendar.dateComponents([.day], from: span.start, to: span.end).day ?? 0
            return stride(from: 0, to: days, by: max(1, bucketDays)).compactMap { offset in
                guard let start = calendar.date(byAdding: .day, value: offset, to: span.start),
                      let end = calendar.date(byAdding: .day, value: min(offset + bucketDays, days), to: span.start)
                else { return nil }
                return value(kind, daily: daily, in: TrendSpan(start: start, end: end), firstDay: firstDay,
                             calendar: calendar).value.map { ChartPoint(day: offset, value: $0) }
            }
        }
        return (points(current), points(previous))
    }
}

/// Workouts so far this period against the same stretch of the last one: on Wednesday at 3 pm,
/// last Monday to last Wednesday at 3 pm — so a week that's only half done isn't set against a
/// whole one. A period you've paged back to is finished, and is set against the whole period
/// before it.
enum PeriodPace {
    static func comparison(for period: RhythmPeriod, calendar: Calendar, now: Date) -> TrendSpan {
        let before = period.stepped(by: -1).range(calendar, now: now)
        guard period.offset == 0 else { return TrendSpan(start: before.start, end: before.end) }
        let current = period.range(calendar, now: now)
        let elapsed = now.timeIntervalSince(current.start)
        return TrendSpan(start: before.start, end: min(before.start.addingTimeInterval(elapsed), before.end))
    }

    /// "last week by now" / "the week before".
    static func label(for period: RhythmPeriod) -> String {
        period.offset == 0
            ? "last \(period.granularity.rawValue) by now"
            : "the \(period.granularity.rawValue) before"
    }
}

extension String {
    /// "last week by now" → "Last week by now".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
