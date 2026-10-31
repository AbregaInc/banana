import Foundation
import CoreGraphics

private struct MinHeap<Element> {
    var values: [Element] = []
    let less: (Element, Element) -> Bool
    var first: Element? { values.first }
    mutating func clear() { values.removeAll(keepingCapacity: true) }
    mutating func push(_ value: Element) {
        values.append(value)
        var child = values.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard less(values[child], values[parent]) else { break }
            values.swapAt(child, parent); child = parent
        }
    }
    mutating func pop() -> Element? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]; values[0] = values.removeLast()
        var parent = 0
        while parent * 2 + 1 < values.count {
            var child = parent * 2 + 1
            if child + 1 < values.count, less(values[child + 1], values[child]) { child += 1 }
            guard less(values[child], values[parent]) else { break }
            values.swapAt(child, parent); parent = child
        }
        return result
    }
}

// Immutable, width-independent geometry. No view, formatter or UI-thread dependency.
// Half-open intervals: an event ending at midnight does not appear the following day.
struct EventPlacement: Sendable {
    let id: String
    let start: Double
    let end: Double
    var lane: Int
    var lanes: Int
    var title: String? = nil
    var calendarIndex: Int = 0
    func rect(day: Int, dayCount: Int, width: CGFloat, height: CGFloat, gutter: CGFloat) -> CGRect {
        let dayWidth = max(1, width - gutter) / CGFloat(max(1, dayCount))
        let laneWidth = dayWidth / CGFloat(lanes)
        let x = gutter + CGFloat(day) * dayWidth + CGFloat(lane) * laneWidth
        let eventWidth = max(0.5, laneWidth - min(2, laneWidth * 0.15))
        let eventHeight = max(0.5, CGFloat(end - start) * height - 1)
        return CGRect(x: x, y: CGFloat(start) * height, width: eventWidth, height: eventHeight)
    }
}

struct DayGeometry: Sendable {
    let date: Date
    let duration: Double
    let placements: [EventPlacement]
    private let buckets: [[Int]]
    static let bucketCount = 96

    init(date: Date, calendar: Calendar, events: [Fixture], useHeap: Bool? = nil, buildIndex: Bool = true) {
        let dayStart = calendar.startOfDay(for: date)
        self.date = dayStart
        let next = calendar.date(byAdding: .day, value: 1, to: self.date)!
        let dayDuration = next.timeIntervalSince(dayStart)
        duration = dayDuration
        var entries = events.compactMap { event -> EventPlacement? in
            let start = max(0, event.start.timeIntervalSince(dayStart))
            let end = min(dayDuration, event.end.timeIntervalSince(dayStart))
            guard end > start else { return nil }
            return EventPlacement(id: event.id, start: start / dayDuration, end: end / dayDuration, lane: 0, lanes: 1, title: event.title, calendarIndex: event.calendarIndex)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        // Retained microbenchmarks: linear wins through 2k; heap wins at 4k and 10k.
        let heapEnabled = useHeap ?? (entries.count >= 4000)
        var laneEnds: [Double] = []
        var busy = MinHeap<(end: Double, lane: Int)>(less: { $0.end == $1.end ? $0.lane < $1.lane : $0.end < $1.end })
        var free = MinHeap<Int>(less: <)
        var groupStart = 0
        var groupEnd = -Double.infinity
        func finishGroup(_ end: Int) {
            for index in groupStart..<end { entries[index].lanes = laneEnds.count }
        }
        for index in entries.indices {
            if entries[index].start >= groupEnd {
                finishGroup(index)
                laneEnds.removeAll(keepingCapacity: true)
                busy.clear(); free.clear()
                groupStart = index
            }
            // Interval partitioning: reuse a lane once its half-open interval ends.
            let lane: Int
            if heapEnabled {
                while let first = busy.first, first.end <= entries[index].start { free.push(busy.pop()!.lane) }
                lane = free.pop() ?? laneEnds.count
                busy.push((end: entries[index].end, lane: lane))
            } else {
                lane = laneEnds.firstIndex { $0 <= entries[index].start } ?? laneEnds.count
            }
            if lane == laneEnds.count { laneEnds.append(entries[index].end) }
            else { laneEnds[lane] = entries[index].end }
            entries[index].lane = lane
            groupEnd = max(groupEnd, entries[index].end)
        }
        finishGroup(entries.count)
        placements = entries
        guard buildIndex else { buckets = []; return }
        var index = Array(repeating: [Int](), count: Self.bucketCount)
        for (offset, event) in entries.enumerated() {
            let first = min(Self.bucketCount - 1, Int(event.start * Double(Self.bucketCount)))
            let last = min(Self.bucketCount - 1, max(first, Int(ceil(event.end * Double(Self.bucketCount))) - 1))
            for bucket in first...last { index[bucket].append(offset) }
        }
        buckets = index
    }

    func visible(from start: Double, to end: Double) -> [EventPlacement] {
        guard end > start, end > 0, start < 1 else { return [] }
        if buckets.isEmpty { return placements.filter { $0.end > start && $0.start < end } }
        let first = max(0, min(Self.bucketCount - 1, Int(max(0, start) * Double(Self.bucketCount))))
        let last = max(first, min(Self.bucketCount - 1, Int(ceil(min(1, end) * Double(Self.bucketCount))) - 1))
        var seen = Set<Int>()
        var result: [EventPlacement] = []
        for bucket in first...last {
            for index in buckets[bucket] where seen.insert(index).inserted {
                let entry = placements[index]
                if entry.end > start && entry.start < end { result.append(entry) }
            }
        }
        return result
    }
}

// Instance ownership fixes calendar/timezone; invalidation removes only changed days.
// Entries contain normalized geometry, so width changes do not invalidate overlap layout.
final class GeometryCache {
    let capacity: Int
    private var values: [Date: DayGeometry] = [:]
    private var order: [Date] = []
    private(set) var misses = 0
    init(capacity: Int = 21) { precondition(capacity > 0); self.capacity = capacity }
    var count: Int { values.count }
    func get(_ date: Date) -> DayGeometry? {
        guard let value = values[date] else { misses += 1; return nil }
        order.removeAll { $0 == date }; order.append(date)
        return value
    }
    func put(_ geometry: DayGeometry) {
        values[geometry.date] = geometry
        order.removeAll { $0 == geometry.date }; order.append(geometry.date)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    func invalidate(_ dates: Set<Date>) {
        for date in dates { values.removeValue(forKey: date) }
        order.removeAll { dates.contains($0) }
    }
    func clear() { values.removeAll(); order.removeAll() }
}
