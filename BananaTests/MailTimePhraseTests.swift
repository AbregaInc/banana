import XCTest

/// A time typed the way you would say it (MAIL-UX 6.5.2), read by the app's reader of typed event
/// times and the system's date detector. The detector reads relative words ("tomorrow", "fri")
/// against the real date, so those tests assert what a time is — a weekday, an hour — and not a
/// date; the spans, which are ours, are exact.
final class MailTimePhraseTests: XCTestCase {

    private let calendar = Calendar.current
    private let now = Date()

    private func date(_ text: String) -> Date? {
        switch MailTimePhrase.parse(text, now: now, calendar: calendar) {
        case .at(let date)?, .past(let date)?: return date
        case nil: return nil
        }
    }

    private func parts(_ text: String) -> DateComponents? {
        date(text).map { calendar.dateComponents([.weekday, .hour, .minute], from: $0) }
    }

    // MARK: Spans, which the detector does not read

    func testASpanOfHoursOrMinutesIsFromNow() {
        XCTAssertEqual(MailTimePhrase.parse("in 2 hours", now: now), .at(now.addingTimeInterval(7_200)))
        XCTAssertEqual(MailTimePhrase.parse("2h", now: now), .at(now.addingTimeInterval(7_200)))
        XCTAssertEqual(MailTimePhrase.parse("in an hour", now: now), .at(now.addingTimeInterval(3_600)))
        XCTAssertEqual(MailTimePhrase.parse("45 min", now: now), .at(now.addingTimeInterval(2_700)))
        XCTAssertEqual(MailTimePhrase.parse("in 1 minute", now: now), .at(now.addingTimeInterval(60)),
                       "a minute is a minute, so a message can be watched going")
        XCTAssertEqual(MailTimePhrase.parse("IN 90 MINUTES", now: now), .at(now.addingTimeInterval(5_400)))
    }

    func testASpanOfDaysIsThatManyDaysAheadInTheMorning() throws {
        for text in ["3 days", "in 3 days"] {
            let found = try XCTUnwrap(date(text), text)
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: found)).day
            XCTAssertEqual(days, 3, text)
            XCTAssertEqual(calendar.component(.hour, from: found), 8, "morning is 8 AM")
            XCTAssertEqual(calendar.component(.minute, from: found), 0)
        }
        let week = try XCTUnwrap(date("2 weeks"))
        XCTAssertEqual(calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: week)).day, 14)
    }

    // MARK: Read by the event reader

    func testADayAndATimeAreRead() throws {
        let friday = try XCTUnwrap(parts("fri 9am"))
        XCTAssertEqual(friday.weekday, 6)
        XCTAssertEqual(friday.hour, 9)
        XCTAssertEqual(friday.minute, 0)

        let tomorrow = try XCTUnwrap(date("tomorrow 8:30"))
        let wanted = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(calendar.startOfDay(for: tomorrow), wanted)
        XCTAssertEqual(calendar.component(.hour, from: tomorrow), 8)
        XCTAssertEqual(calendar.component(.minute, from: tomorrow), 30)
    }

    func testABareDayIsThatDayInTheMorning() throws {
        let friday = try XCTUnwrap(parts("fri"))
        XCTAssertEqual(friday.weekday, 6)
        XCTAssertEqual(friday.hour, 8, "the detector says noon; a snooze wants the morning")
        let tomorrow = try XCTUnwrap(parts("tomorrow"))
        XCTAssertEqual(tomorrow.hour, 8)
    }

    func testAWeekdayAndANumberIsAnHourAndNotTheDayOfAMonth() throws {
        let monday = try XCTUnwrap(parts("monday 9"))
        XCTAssertEqual(monday.weekday, 2)
        XCTAssertEqual(monday.hour, 9)
        // And the afternoon rule of the event reader holds: an hour from 1 to 6 with no am or pm.
        XCTAssertEqual(try XCTUnwrap(parts("monday 3")).hour, 15)
    }

    func testABareClockTimeIsTheNextTimeTheClockShowsIt() throws {
        let found = try XCTUnwrap(date("8am"))
        XCTAssertEqual(calendar.component(.hour, from: found), 8)
        XCTAssertGreaterThan(found, now, "the next 8 AM, today or tomorrow")
    }

    // MARK: Three fixed words

    func testNoonNextWeekAndTheWeekend() throws {
        let noon = try XCTUnwrap(parts("noon"))
        XCTAssertEqual(noon.hour, 12)
        let week = try XCTUnwrap(parts("next week"))
        XCTAssertEqual(week.weekday, 2, "Monday")
        XCTAssertEqual(week.hour, 8)
        for text in ["weekend", "this weekend"] {
            let weekend = try XCTUnwrap(parts(text))
            XCTAssertEqual(weekend.weekday, 7, "Saturday")
            XCTAssertEqual(weekend.hour, 9)
        }
    }

    // MARK: What is not a time, and what has gone

    func testWordsThatAreNotATimeShowNothing() {
        XCTAssertNil(MailTimePhrase.parse("", now: now))
        XCTAssertNil(MailTimePhrase.parse("   ", now: now))
        XCTAssertNil(MailTimePhrase.parse("hello there", now: now))
        XCTAssertNil(MailTimePhrase.parse("meet bob friday", now: now), "more than a time is not a time")
        XCTAssertNil(MailTimePhrase.parse("soon", now: now))
    }

    func testATimeInThePastIsReadAndSaidToBeGone() {
        guard case .past? = MailTimePhrase.parse("jan 1 2020", now: now) else {
            return XCTFail("\(String(describing: MailTimePhrase.parse("jan 1 2020", now: now)))")
        }
    }
}
