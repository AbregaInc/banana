import Foundation

/// Where a NEW booking is allowed to start.
///
/// Existing events still move on a five-minute grid, because moving one is an adjustment to
/// something whose time you already chose. Creating one is different: you are picking a slot, and
/// people book on the hour and the half hour. Landing a new event at 2:20 because that is where
/// the pointer happened to be means correcting it by hand every time, which was the whole
/// complaint that led here.
///
/// Only the START is coarsened. The end stays on the finer grid so a drag can still express "an
/// hour and a half" or "twenty minutes" — it is the beginning that people care about lining up.
enum BookingGrid {
    /// Minutes between the slots a new booking may begin on: the hour and the half hour.
    static let startStepMinutes = 30

    /// Minutes a dragged booking's END moves in.
    ///
    /// Coarser than the five-minute grid an existing event moves on, because dragging out a NEW
    /// booking is choosing a length — quarter, half, three-quarters, an hour — not nudging one
    /// that already exists. The start stays on `startStepMinutes`; only the extent uses this.
    static let dragStepMinutes = 15

    /// Snap a dragged end to the booking-length grid, always rounding UP so the block covers
    /// everything the drag swept.
    static func snappedEndMinutes(_ rawMinutes: Double) -> Int {
        let step = Double(dragStepMinutes)
        return Int(ceil(max(0, rawMinutes) / step) * step)
    }

    /// The end of a dragged booking, from a vertical position in a day grid.
    static func snappedEnd(on day: Date,
                           atY y: CGFloat,
                           hourHeight: CGFloat,
                           calendar: Calendar = .current) -> Date {
        guard hourHeight > 0 else { return calendar.startOfDay(for: day) }
        let minutes = min(24 * 60, snappedEndMinutes(Double(max(0, y) / hourHeight) * 60))
        return calendar.date(byAdding: .minute, value: minutes,
                             to: calendar.startOfDay(for: day)) ?? day
    }

    /// The last slot of the day a booking may start on, so rounding up near midnight cannot spill
    /// into the following day.
    static let lastStartMinuteOfDay = 23 * 60 + 30

    enum Rounding {
        /// The nearest slot. Used for a click, where there is no swept region to preserve and the
        /// closest boundary is what "snap" means to the person clicking.
        case nearest
        /// The slot at or before the point. Used for the start of a drag, so the block always
        /// covers the place the press began — rounding a drag start forward would leave the
        /// gesture starting outside the event it just drew.
        case down
    }

    /// Snap a raw minutes-from-midnight offset to a booking slot.
    static func snappedStartMinutes(_ rawMinutes: Double, rounding: Rounding) -> Int {
        let step = Double(startStepMinutes)
        let slots = max(0, rawMinutes) / step
        let snapped = rounding == .down ? floor(slots) : slots.rounded()
        return min(lastStartMinuteOfDay, Int(snapped * step))
    }

    /// Snap a vertical position in a day grid to a booking slot, in minutes from midnight.
    static func snappedStartMinutes(atY y: CGFloat, hourHeight: CGFloat, rounding: Rounding) -> Int {
        guard hourHeight > 0 else { return 0 }
        return snappedStartMinutes(Double(max(0, y) / hourHeight) * 60, rounding: rounding)
    }

    /// The booking slot a point in a day grid falls on.
    static func snappedStart(on day: Date,
                             atY y: CGFloat,
                             hourHeight: CGFloat,
                             rounding: Rounding,
                             calendar: Calendar = .current) -> Date {
        let minutes = snappedStartMinutes(atY: y, hourHeight: hourHeight, rounding: rounding)
        return calendar.date(byAdding: .minute, value: minutes,
                             to: calendar.startOfDay(for: day)) ?? day
    }
}
