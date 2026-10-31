import Foundation
import CoreGraphics

/// Projection for Day/Week's existing fixed, 24-hour wall-clock ruler. Unlike an
/// unanchored hour/minute conversion, next midnight is the BOTTOM of this day.
/// Agenda uses its separate elapsed-time geometry (including repeated DST hours).
struct CalendarDayClockGeometry {
    let calendar: Calendar
    let start: Date
    let end: Date
    let startHour: Int
    let hourHeight: CGFloat

    init(day: Date, calendar: Calendar, startHour: Int, hourHeight: CGFloat) {
        precondition((0...24).contains(startHour) && hourHeight.isFinite && hourHeight > 0)
        self.calendar = calendar
        start = calendar.startOfDay(for: day)
        end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        self.startHour = startHour
        self.hourHeight = hourHeight
    }

    func boundary(_ hour: Int) -> Date {
        precondition((0...24).contains(hour))
        if hour == 24 { return end }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start) ?? start
    }

    func y(_ date: Date) -> CGFloat {
        if date <= start { return -CGFloat(startHour) * hourHeight }
        if date >= end { return CGFloat(24 - startHour) * hourHeight }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (CGFloat(components.hour ?? 0) + CGFloat(components.minute ?? 0) / 60
                - CGFloat(startHour)) * hourHeight
    }
}
