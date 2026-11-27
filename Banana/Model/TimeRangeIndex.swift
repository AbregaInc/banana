import Foundation

/// Immutable interval tree. A visible range visits matching records and the tree paths to them,
/// rather than scanning all retained history. Subtree maxima preserve long/overnight intervals.
struct TimeRangeIndex<Element> {
    private let rows: [Element]
    private let starts: [Date]
    private let ends: [Date]
    private let maximumEnds: [Date]

    init(_ values: [Element], start: (Element) -> Date, end: (Element) -> Date) {
        let dates = values.map(start)
        if dates.indices.dropFirst().allSatisfy({ dates[$0 - 1] <= dates[$0] }) {
            // The published timeline is normally chronological. Share its array storage.
            rows = values
            starts = dates
        } else {
            let order = dates.indices.sorted { dates[$0] < dates[$1] }
            rows = order.map { values[$0] }
            starts = order.map { dates[$0] }
        }
        ends = rows.map(end)
        maximumEnds = Self.subtreeMaxima(ends)
    }

    private static func subtreeMaxima(_ ends: [Date]) -> [Date] {
        var maxima = ends
        // Each midpoint starts with its own end. Visit only nonempty children and
        // acquire mutable access to the output array once for the whole construction.
        maxima.withUnsafeMutableBufferPointer { buffer in
            func build(_ lower: Int, _ upper: Int) -> Date {
                let middle = (lower + upper) / 2
                var latest = buffer[middle]
                if lower < middle { latest = max(latest, build(lower, middle)) }
                if middle + 1 < upper { latest = max(latest, build(middle + 1, upper)) }
                buffer[middle] = latest
                return latest
            }
            if !buffer.isEmpty { _ = build(0, buffer.count) }
        }
        return maxima
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
