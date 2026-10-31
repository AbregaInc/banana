import Foundation

/// A move is relative to the original event, including when the grabbed block is
/// a clipped continuation on another day. Calendar arithmetic preserves local
/// time for horizontal day steps; vertical steps retain the existing elapsed-minute rule.
enum CalendarMoveGeometry {
    static func start(original: Date, dayShift: Int, minutes: Double,
                      calendar: Calendar) -> Date? {
        guard minutes.isFinite else { return nil }
        // Preserve the precise instant for zero horizontal movement, including the
        // second occurrence of a repeated DST hour and sub-minute start precision.
        guard let base = dayShift == 0 ? original
            : calendar.date(byAdding: .day, value: dayShift, to: original) else { return nil }
        return base.addingTimeInterval((minutes / 5).rounded() * 5 * 60)
    }

    static func end(originalStart: Date, originalEnd: Date, displayedStart: Date) -> Date {
        originalEnd.addingTimeInterval(displayedStart.timeIntervalSince(originalStart))
    }
}
