import Foundation

/// The window Rhythm is showing. A granularity (week/month/quarter/year) plus an `offset`
/// back from the current period (0 = current, -1 = previous, …). Computes the date range,
/// a human label, and the chart bucket size so aggregation and the UI stay in agreement.
enum RhythmGranularity: String, CaseIterable, Identifiable, Hashable {
    case week, month, quarter, year
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Calendar component one step of this granularity spans.
    var component: Calendar.Component {
        switch self {
        case .week:    return .weekOfYear
        case .month:   return .month
        case .quarter: return .quarter
        case .year:    return .year
        }
    }

    /// How charts bucket the range: a week shows days, a month shows weeks, a quarter/year
    /// shows months.
    var bucket: Calendar.Component {
        switch self {
        case .week:               return .day
        case .month:              return .weekOfYear
        case .quarter, .year:     return .month
        }
    }
}

struct RhythmPeriod: Hashable {
    var granularity: RhythmGranularity
    var offset: Int = 0   // 0 = current, negative = further back

    static let current = RhythmPeriod(granularity: .week, offset: 0)

    /// Inclusive start / exclusive end of the window.
    func range(_ calendar: Calendar = .app, now: Date = Date()) -> (start: Date, end: Date) {
        let currentStart: Date
        let stepComponent: Calendar.Component
        let stepSize: Int
        if granularity == .quarter {
            // Foundation's `.quarter` date arithmetic is not implemented consistently:
            // adding one quarter can return the same date. Anchor explicitly to Jan/Apr/Jul/Oct
            // and advance by three calendar months.
            let components = calendar.dateComponents([.era, .year, .month], from: now)
            let firstMonth = ((components.month ?? 1) - 1) / 3 * 3 + 1
            var startComponents = components
            startComponents.month = firstMonth
            startComponents.day = 1
            currentStart = calendar.date(from: startComponents) ?? calendar.startOfDay(for: now)
            stepComponent = .month
            stepSize = 3
        } else {
            currentStart = calendar.dateInterval(of: granularity.component, for: now)?.start
                ?? calendar.startOfDay(for: now)
            stepComponent = granularity.component
            stepSize = 1
        }
        let start = calendar.date(byAdding: stepComponent, value: offset * stepSize, to: currentStart)
            ?? currentStart
        let end = calendar.date(byAdding: stepComponent, value: stepSize, to: start) ?? start
        return (start, end)
    }

    /// Whether we can page forward (never past the current period).
    var canGoForward: Bool { offset < 0 }

    func stepped(by delta: Int) -> RhythmPeriod {
        RhythmPeriod(granularity: granularity, offset: min(0, offset + delta))
    }

    /// A short label: "This week", "Last month", or an absolute name like "Q3 2026" / "2026".
    func label(_ calendar: Calendar = .app, now: Date = Date()) -> String {
        if offset == 0 { return "This \(granularity.rawValue)" }
        if offset == -1 { return "Last \(granularity.rawValue)" }
        let start = range(calendar, now: now).start
        switch granularity {
        case .week:
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return "Week of \(f.string(from: start))"
        case .month:
            let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
            return f.string(from: start)
        case .quarter:
            let q = (calendar.component(.month, from: start) - 1) / 3 + 1
            return "Q\(q) \(calendar.component(.year, from: start))"
        case .year:
            return "\(calendar.component(.year, from: start))"
        }
    }

    /// The date range spelled out, e.g. "Jul 4 – Jul 11".
    func rangeLabel(_ calendar: Calendar = .app, now: Date = Date()) -> String {
        let (start, end) = range(calendar, now: now)
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: start)) – \(f.string(from: last))"
    }
}
