import Foundation
import CoreGraphics

/// A day uses elapsed time so DST's repeated hour has two distinct positions. Clip before
/// drawing: overnight events must not cover the next day's section or collapse into 6 AM.
struct CalendarAgendaGeometry {
    struct Frame: Equatable {
        let y: CGFloat
        let height: CGFloat
    }
    let start: Date
    let end: Date
    let hourHeight: CGFloat
    var height: CGFloat { y(end) }

    init(day: Date, calendar: Calendar, hourHeight: CGFloat) {
        precondition(hourHeight.isFinite && hourHeight > 0)
        start = calendar.startOfDay(for: day)
        end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        self.hourHeight = hourHeight
    }

    func y(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(start), 0), end.timeIntervalSince(start))) / 3600 * hourHeight
    }

    var ticks: [Date] {
        let count = Int(end.timeIntervalSince(start) / 3600)
        var result = (0...count).map { start.addingTimeInterval(Double($0) * 3600) }
        if result.last != end { result.append(end) }
        return result
    }

    /// Extend short artwork only into unoccupied time, never across another start or day end.
    /// A single sorted set replaces a per-event scan; equal starts share the same successor.
    func frames(_ intervals: [DateInterval], minimum: CGFloat) -> [Frame] {
        precondition(minimum.isFinite && minimum >= 0)
        let starts = intervals.map { y($0.start) }
        let ordered = Set(starts).sorted()
        let next = Dictionary(uniqueKeysWithValues: zip(ordered, ordered.dropFirst()))
        return zip(intervals, starts).map { interval, top in
            guard (interval.end > start || interval.start == start), interval.start < end else { return Frame(y: top, height: 0) }
            let natural = max(0, y(interval.end) - top)
            let room = (next[top] ?? height) - top
            let drawn = CalendarBlockHeight.height(natural: natural, minimum: minimum, roomBelow: room)
            return Frame(y: top, height: min(drawn, height - top))
        }
    }
}
