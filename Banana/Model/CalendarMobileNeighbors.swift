import Foundation
import CoreGraphics

/// One immutable layout update, including optimistic dates and current width/zoom.
/// No cross-update cache: moving an event or changing a lane immediately replaces it.
enum CalendarMobileNeighbors {
    struct Input {
        let id: String
        let start: Date
        let end: Date
        let lane: Int
        let span: Range<CGFloat>
        let top: CGFloat
    }
    struct Result: Equatable {
        let visualEnd: Date
        let nextTop: CGFloat?
    }

    /// Source identity is not a placement identity: imported or retained snapshots can contain
    /// multiple placements for one ID. An ID index cannot describe their distinct geometry.
    /// Let the caller use the existing per-placement scans rather than trap or pick one result.
    static func indexed(_ items: [Input]) -> [String: Result]? {
        let neighbors = items.count < 24 ? make(items) : neighborsByStart(items)
        var index = [String: Result](minimumCapacity: items.count)
        for (item, neighbor) in zip(items, neighbors) {
            guard index.updateValue(neighbor, forKey: item.id) == nil else { return nil }
        }
        return index
    }

    /// Rows with the same horizontal span can share the minimum projected Y of all later
    /// rows in that span. Process equal starts together so neither row counts as later.
    private static func neighborsByStart(_ items: [Input]) -> [Result] {
        let order = items.indices.sorted { items[$0].start < items[$1].start }
        let lanes = Dictionary(grouping: order) { items[$0].lane }
        var spans: [Range<CGFloat>] = []
        var spanIndex: [Range<CGFloat>: Int] = [:]
        let columns = items.map { item in
            if let index = spanIndex[item.span] { return index }
            let index = spans.count
            spans.append(item.span)
            spanIndex[item.span] = index
            return index
        }
        var lowest = [CGFloat?](repeating: nil, count: spans.count)
        var result = items.map { Result(visualEnd: $0.end, nextTop: nil) }
        var end = order.count
        while end > 0 {
            var begin = end - 1
            let start = items[order[begin]].start
            while begin > 0, items[order[begin - 1]].start == start { begin -= 1 }
            for index in order[begin..<end] {
                let item = items[index]
                var nextTop: CGFloat?
                for column in spans.indices where spans[column].overlaps(item.span) {
                    if let top = lowest[column] { nextTop = min(nextTop ?? top, top) }
                }

                let lane = lanes[item.lane]!
                var low = 0, high = lane.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if items[lane[mid]].start < item.end { low = mid + 1 } else { high = mid }
                }
                if low < lane.count, lane[low] == index { low += 1 }
                var visualEnd = item.end
                if low < lane.count {
                    let next = items[lane[low]].start
                    if next.timeIntervalSince(item.end) <= 300 { visualEnd = next }
                }
                result[index] = Result(visualEnd: visualEnd, nextTop: nextTop)
            }
            for index in order[begin..<end] {
                let column = columns[index], top = items[index].top
                lowest[column] = min(lowest[column] ?? top, top)
            }
            end = begin
        }
        return result
    }

    static func make(_ items: [Input]) -> [Result] {
        items.map { item in
            var nextEnd: Date?
            var nextTop: CGFloat?
            for other in items where other.id != item.id {
                if other.lane == item.lane, other.start >= item.end,
                   nextEnd == nil || other.start < nextEnd! {
                    nextEnd = other.start
                }
                if other.start > item.start, other.span.overlaps(item.span) {
                    // Wall-clock Y is not monotonic across the repeated DST hour.
                    // Preserve the original minimum projected Y, not earliest date.
                    nextTop = min(nextTop ?? other.top, other.top)
                }
            }
            let end = nextEnd.flatMap { $0.timeIntervalSince(item.end) <= 300 ? $0 : nil } ?? item.end
            return Result(visualEnd: end, nextTop: nextTop)
        }
    }
}
