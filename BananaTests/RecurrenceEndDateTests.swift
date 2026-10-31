import XCTest

/// "Repeats every day until the 25th" — where the boundary actually lands.
///
/// The person picks a DAY and means it inclusively. EventKit wants the last instant included;
/// Google's UNTIL is expressed via the first occurrence removed. Getting this off by one gives a
/// blocker that stops the morning before it should, which nobody notices until something is booked
/// over it.
final class RecurrenceEndDateTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testTheChosenDayIsIncluded() {
        // Picked "until Fri 25 Sep", with the event itself at 07:30.
        let chosen = date("2026-09-25T07:30:00-04:00")
        let last = RecurrenceEndDate.lastIncludedInstant(lastDayIncluded: chosen, calendar: calendar)
        XCTAssertGreaterThan(last, chosen, "the 25th's own occurrence has to fall inside the end")
    }

    func testTheFollowingDayIsExcluded() {
        let chosen = date("2026-09-25T07:30:00-04:00")
        let firstExcluded = RecurrenceEndDate.firstExcludedInstant(lastDayIncluded: chosen, calendar: calendar)
        let saturdayMorning = date("2026-09-26T07:30:00-04:00")
        XCTAssertLessThan(firstExcluded, saturdayMorning, "Saturday must not be generated")
        XCTAssertEqual(firstExcluded, date("2026-09-26T00:00:00-04:00"))
    }

    func testTheTwoEndpointsAreOneSecondApart() {
        let chosen = date("2026-09-25T15:00:00-04:00")
        let last = RecurrenceEndDate.lastIncludedInstant(lastDayIncluded: chosen, calendar: calendar)
        let firstExcluded = RecurrenceEndDate.firstExcludedInstant(lastDayIncluded: chosen, calendar: calendar)
        XCTAssertEqual(firstExcluded.timeIntervalSince(last), 1)
    }

    /// The time of day the person happened to be looking at must not change which day ends it.
    func testTheTimeOfDayDoesNotAffectTheBoundary() {
        let early = RecurrenceEndDate.firstExcludedInstant(
            lastDayIncluded: date("2026-09-25T00:05:00-04:00"), calendar: calendar)
        let late = RecurrenceEndDate.firstExcludedInstant(
            lastDayIncluded: date("2026-09-25T23:55:00-04:00"), calendar: calendar)
        XCTAssertEqual(early, late)
    }

    /// Computed through Calendar, not by adding 86,400 seconds, so a series spanning the DST change
    /// still ends on the day that was picked. 1 Nov 2026 is the US fall-back.
    func testADaylightSavingBoundaryDoesNotShiftTheEnd() {
        let chosen = date("2026-11-01T09:00:00-05:00")
        let firstExcluded = RecurrenceEndDate.firstExcludedInstant(lastDayIncluded: chosen, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: firstExcluded)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 0, "must be midnight local, not shifted by the extra hour")
    }

    /// The two halves of the feature have to agree: what Google is told to exclude is exactly one
    /// second past what EventKit is told to include.
    func testGoogleAndEventKitEndpointsDescribeTheSameBoundary() {
        let chosen = date("2026-09-25T07:30:00-04:00")
        let firstExcluded = RecurrenceEndDate.firstExcludedInstant(lastDayIncluded: chosen, calendar: calendar)
        let rule = GoogleRecurrenceRule.truncated(["RRULE:FREQ=DAILY"], before: firstExcluded)[0]
        let last = RecurrenceEndDate.lastIncludedInstant(lastDayIncluded: chosen, calendar: calendar)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertTrue(rule.hasSuffix("UNTIL=\(formatter.string(from: last))"))
    }
}
