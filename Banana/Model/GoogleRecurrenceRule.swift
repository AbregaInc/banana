import Foundation

/// Recurrence-rule text handling for Google Calendar, kept apart from the service so it can be
/// tested without the Google Sign-In SDK or a network.
enum GoogleRecurrenceRule {
/// Rewrites an `RRULE` so the series stops before `cutoff`.
///
/// RFC 5545 requires `UNTIL` in UTC basic format, and it is inclusive — the last instance kept
/// is the latest one starting at or before it — so the cutoff is placed one second before the
/// first occurrence being removed. Any existing `UNTIL` or `COUNT` is dropped: both express an
/// end, and leaving a stale `COUNT` beside a new `UNTIL` is how a truncation silently does
/// nothing. Non-RRULE lines (EXDATE, RDATE) are passed through untouched.
///
/// An all-day series takes `UNTIL` as a date — the last day kept — since RFC 5545 requires it in
/// the same form as the series' start, and Google rejects a date-time there.
///
/// Pure and network-free, so the string handling is covered by tests.
static func truncated(_ recurrence: [String], before cutoff: Date, allDay: Bool = false,
                      calendar: Calendar = .current) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if allDay {
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
    } else {
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
    }
    let until = formatter.string(from: cutoff.addingTimeInterval(-1))

    return recurrence.map { line in
        guard line.uppercased().hasPrefix("RRULE:") else { return line }
        let body = String(line.dropFirst("RRULE:".count))
        let parts = body
            .split(separator: ";")
            .map(String.init)
            .filter {
                let key = $0.uppercased()
                return !key.hasPrefix("UNTIL=") && !key.hasPrefix("COUNT=")
            }
        return "RRULE:" + (parts + ["UNTIL=\(until)"]).joined(separator: ";")
    }
}
}
