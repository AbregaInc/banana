import Foundation

/// "When are you free?" as a paragraph you can paste into an email or chat.
///
/// Pure: busy intervals in, free slots and text out. The caller decides what counts as busy
/// (meetings not marked free, Banana's own busy blocks); this only does the arithmetic, so the
/// rules that matter — never offer the past, never offer a slot shorter than the meeting, keep
/// to working hours — are all testable without a calendar.
struct AvailabilityRequest: Equatable {
    /// How long the meeting would be. Gaps shorter than this are not offered.
    var duration: TimeInterval = 30 * 60
    /// Working hours, as minutes after local midnight.
    var dayStartMinutes = 9 * 60
    var dayEndMinutes = 18 * 60
    /// How many days to offer, counted from today and skipping weekends unless included.
    var dayCount = 5
    var includeWeekends = false
    /// Breathing room kept on both sides of every busy interval.
    var buffer: TimeInterval = 0
}

enum AvailabilityFinder {
    /// Offered times start and end on this grid, so a slot never reads "9:07 – 10:52".
    static let granularity: TimeInterval = 15 * 60

    /// The days a request covers, as start-of-day dates. Today counts only while some of its
    /// working hours are still ahead.
    static func days(for request: AvailabilityRequest, now: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: now)
        var guardCount = 0
        while result.count < max(request.dayCount, 0), guardCount < 60 {
            guardCount += 1
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
            if !request.includeWeekends, calendar.isDateInWeekend(day) { continue }
            let end = time(request.dayEndMinutes, on: day, calendar: calendar)
            if end <= now { continue }
            result.append(day)
        }
        return result
    }

    /// Free slots per offered day, in order. A day with nothing free is left out.
    static func freeSlots(busy: [DateInterval], request: AvailabilityRequest,
                          now: Date, calendar: Calendar) -> [DateInterval] {
        let padded = busy
            .map { DateInterval(start: $0.start.addingTimeInterval(-request.buffer),
                                end: $0.end.addingTimeInterval(request.buffer)) }
            .sorted { $0.start < $1.start }
        var slots: [DateInterval] = []
        for day in days(for: request, now: now, calendar: calendar) {
            let dayStart = max(time(request.dayStartMinutes, on: day, calendar: calendar), now)
            let dayEnd = time(request.dayEndMinutes, on: day, calendar: calendar)
            guard dayEnd > dayStart else { continue }
            var cursor = dayStart
            for interval in padded where interval.end > cursor && interval.start < dayEnd {
                if interval.start > cursor {
                    append(cursor, interval.start, to: &slots, request: request)
                }
                cursor = max(cursor, interval.end)
                if cursor >= dayEnd { break }
            }
            if cursor < dayEnd {
                append(cursor, dayEnd, to: &slots, request: request)
            }
        }
        return slots
    }

    /// The paragraph to paste: one line per day, times in `timeZone`, the zone named once.
    static func text(for slots: [DateInterval], request: AvailabilityRequest,
                     timeZone: TimeZone, locale: Locale = .current) -> String {
        guard !slots.isEmpty else { return "I don't have any open time in the days you asked about." }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayFormat = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
        let zone = timeZone.abbreviation(for: slots[0].start) ?? timeZone.identifier
        let minutes = Int(request.duration / 60)
        var lines = ["I'm free for \(minutes) minutes at any of these times (\(zone)):"]
        var currentDay: Date?
        var dayParts: [String] = []
        func flush() {
            guard let currentDay, !dayParts.isEmpty else { return }
            lines.append("• \(currentDay.formatted(dayFormat)): \(dayParts.joined(separator: ", "))")
        }
        for slot in slots {
            let day = calendar.startOfDay(for: slot.start)
            if day != currentDay {
                flush()
                currentDay = day
                dayParts = []
            }
            dayParts.append(TimeRangeText.compact(slot.start, slot.end, calendar: calendar, locale: locale))
        }
        flush()
        return lines.joined(separator: "\n")
    }

    private static func append(_ start: Date, _ end: Date, to slots: inout [DateInterval],
                               request: AvailabilityRequest) {
        let roundedStart = Date(timeIntervalSinceReferenceDate:
            (start.timeIntervalSinceReferenceDate / granularity).rounded(.up) * granularity)
        let roundedEnd = Date(timeIntervalSinceReferenceDate:
            (end.timeIntervalSinceReferenceDate / granularity).rounded(.down) * granularity)
        guard roundedEnd.timeIntervalSince(roundedStart) >= request.duration else { return }
        slots.append(DateInterval(start: roundedStart, end: roundedEnd))
    }

    private static func time(_ minutes: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            ?? day.addingTimeInterval(TimeInterval(minutes * 60))
    }
}
