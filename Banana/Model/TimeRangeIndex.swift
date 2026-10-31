import Foundation

/// Immutable interval tree. A visible range visits matching records and the tree paths to them,
/// rather than scanning all retained history. Subtree maxima preserve long/overnight intervals.
struct TimeRangeIndex<Element> {
    private let rows: [Element]
    private let starts: [Date]
    private let ends: [Date]
    private var maximumEnds: [Date]

    init(_ values: [Element], start: (Element) -> Date, end: (Element) -> Date) {
        rows = values.sorted { start($0) < start($1) }
        starts = rows.map(start)
        ends = rows.map(end)
        maximumEnds = Array(repeating: .distantPast, count: rows.count)
        if !rows.isEmpty { _ = build(0, rows.count) }
    }

    private mutating func build(_ lower: Int, _ upper: Int) -> Date {
        guard lower < upper else { return .distantPast }
        let middle = (lower + upper) / 2
        let left = build(lower, middle)
        let right = build(middle + 1, upper)
        let value = max(ends[middle], max(left, right))
        maximumEnds[middle] = value
        return value
    }

    func overlapping(from start: Date, to end: Date) -> [Element] {
        guard end > start else { return [] }
        var result: [Element] = []
        func visit(_ lower: Int, _ upper: Int) {
            guard lower < upper else { return }
            let middle = (lower + upper) / 2
            guard maximumEnds[middle] > start else { return }
            visit(lower, middle)
            guard starts[middle] < end else { return }
            if ends[middle] > start { result.append(rows[middle]) }
            visit(middle + 1, upper)
        }
        visit(0, rows.count)
        return result
    }
}

/// Calendar boundaries are computed once per visible day, never once per retained event.
/// Uses calendar arithmetic so spring/fall DST days retain their actual 23/25-hour length.
struct CalendarDayRange {
    let start: Date
    let end: Date

    init(day: Date, calendar: Calendar) {
        start = calendar.startOfDay(for: day)
        end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    func contains(start itemStart: Date, end itemEnd: Date, timed: Bool) -> Bool {
        if !timed { return itemStart >= start && itemStart < end }
        return itemStart < end && itemEnd > start && itemEnd > itemStart
    }
}

/// Finds the first source record within a strict one-minute tolerance, without scanning
/// history in every event view. Neighboring buckets preserve matches across minute boundaries.
struct MinuteMatchIndex<Element> {
    private struct Entry { let order: Int; let date: Date; let value: Element }
    private var buckets: [Int: [Entry]] = [:]

    init(_ values: [(date: Date, value: Element)] = []) {
        for (order, item) in values.enumerated() {
            let key = Int(floor(item.date.timeIntervalSinceReferenceDate / 60))
            buckets[key, default: []].append(Entry(order: order, date: item.date, value: item.value))
        }
    }

    func first(near date: Date) -> Element? {
        let key = Int(floor(date.timeIntervalSinceReferenceDate / 60))
        var found: Entry?
        for bucket in (key - 1)...(key + 1) {
            for entry in buckets[bucket, default: []]
            where abs(entry.date.timeIntervalSince(date)) < 60 {
                if found == nil || entry.order < found!.order { found = entry }
            }
        }
        return found?.value
    }
}
