import XCTest

/// Google's timestamps are read by hand (`GoogleCalendarDates.fastRFC3339`) because two
/// `ISO8601DateFormatter` attempts per timestamp were a large part of building a calendar window.
/// The hand reader must give exactly what the formatters gave, and leave anything else to them.
final class GoogleCalendarDatesTests: XCTestCase {
    private let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func formatterDate(_ value: String) -> Date? {
        fractional.date(from: value) ?? whole.date(from: value)
    }

    func testGoogleShapesReadTheSameAsTheFormatters() {
        for value in [
            "2026-10-04T09:00:00-07:00",
            "2026-10-04T16:00:00Z",
            "2026-10-04T09:00:00.123Z",
            "2026-10-04T09:00:00.5+02:00",
            "2024-02-29T23:59:59+05:30",
            "1999-12-31T23:59:59-12:00",
            "2026-01-01T00:00:00+14:00",
            "2000-03-01T00:00:00Z",
            "2100-02-28T12:00:00-03:30",
        ] {
            let fast = GoogleCalendarDates.fastRFC3339(value)
            let expected = formatterDate(value)
            XCTAssertNotNil(fast, value)
            XCTAssertEqual(fast?.timeIntervalSince1970 ?? 0, expected?.timeIntervalSince1970 ?? -1,
                           accuracy: 0.000_5, value)
        }
    }

    func testThousandsOfTimestampsAcrossOffsetsMatchTheFormatters() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let date = Date(timeIntervalSince1970: Double.random(in: 0..<4_100_000_000, using: &generator).rounded())
            let quarterHours = Int.random(in: -48...56, using: &generator)
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: quarterHours * 15 * 60)
            let value = formatter.string(from: date)
            XCTAssertEqual(GoogleCalendarDates.parseRFC3339(value), date, value)
            XCTAssertEqual(GoogleCalendarDates.fastRFC3339(value), date, value)
        }
    }

    func testAnythingElseIsLeftToTheFormatters() {
        for value in [
            "2026-02-30T09:00:00Z",        // no such day
            "2026-13-01T09:00:00Z",
            "2026-10-04T24:00:00Z",
            "2026-10-04T09:00:60Z",
            "2026-10-04T09:00:00",          // no zone
            "2026-10-04",
            "2026-10-04t09:00:00z",
            "2026-10-04T09:00:00.Z",
            "2026-10-04T09:00:00+0700",
            "2026-10-04T09:00:00-07:00 ",
            "",
        ] {
            XCTAssertNil(GoogleCalendarDates.fastRFC3339(value), value)
            XCTAssertEqual(GoogleCalendarDates.parseRFC3339(value), formatterDate(value), value)
        }
    }
}
