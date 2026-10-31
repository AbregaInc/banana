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
        var duplicates = false
        let index = Dictionary(zip(items.map(\.id), make(items)), uniquingKeysWith: { first, _ in
            duplicates = true
            return first
        })
        return duplicates ? nil : index
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
