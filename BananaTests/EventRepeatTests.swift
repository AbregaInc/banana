import XCTest

/// The repeat rule an edit writes to a real calendar: built, read back, described — weekly on
/// several days above all ("every week on Mon, Wed and Fri").
final class EventRepeatTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private let british = Locale(identifier: "en_GB")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Tuesday 6 Oct 2026, 10:00 New York.
    private var tuesday: Date { date(2026, 10, 6) }

    private func rule(_ value: EventRepeat, allDay: Bool = false) -> String {
        value.rule(isAllDay: allDay, calendar: calendar)
    }

    // MARK: - Building

    func testDailyAndYearlyAreJustTheirFrequency() {
        XCTAssertEqual(rule(EventRepeat(frequency: .daily)), "RRULE:FREQ=DAILY")
        XCTAssertEqual(rule(EventRepeat(frequency: .yearly)), "RRULE:FREQ=YEARLY")
    }

    func testEveryWeekdayIsMondayToFriday() {
        guard case .rule(let weekdays) = EventRepeat.preset(.weekdays, start: tuesday, calendar: calendar) else {
            return XCTFail("no rule")
        }
        XCTAssertEqual(rule(weekdays), "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
    }

    func testSeveralDaysAreWrittenInWeekOrderWhateverOrderTheyWereTapped() {
        XCTAssertEqual(rule(EventRepeat(frequency: .weekly, weekdays: [.friday, .monday, .wednesday])),
                       "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR")
        XCTAssertEqual(rule(EventRepeat(frequency: .weekly, weekdays: [.sunday, .monday])),
                       "RRULE:FREQ=WEEKLY;BYDAY=MO,SU")
    }

    func testEveryOtherWeekOnTwoDays() {
        XCTAssertEqual(rule(EventRepeat(frequency: .weekly, interval: 2, weekdays: [.thursday, .tuesday])),
                       "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH")
    }

    func testMonthlyByDateOrByWeekday() {
        XCTAssertEqual(rule(EventRepeat(frequency: .monthly, monthly: .dayOfMonth(7))),
                       "RRULE:FREQ=MONTHLY;BYMONTHDAY=7")
        XCTAssertEqual(rule(EventRepeat(frequency: .monthly, monthly: .weekdayOrdinal(ordinal: 2, weekday: .tuesday))),
                       "RRULE:FREQ=MONTHLY;BYDAY=2TU")
        XCTAssertEqual(rule(EventRepeat(frequency: .monthly, monthly: .weekdayOrdinal(ordinal: -1, weekday: .friday))),
                       "RRULE:FREQ=MONTHLY;BYDAY=-1FR")
    }

    func testAnEndAfterSomeTimes() {
        XCTAssertEqual(rule(EventRepeat(frequency: .daily, end: .afterCount(10))), "RRULE:FREQ=DAILY;COUNT=10")
    }

    func testAnEndDateIncludesThatWholeDay() {
        let value = EventRepeat(frequency: .weekly, weekdays: [.tuesday], end: .onDate(date(2026, 10, 25, 0)))
        // 23:59:59 on the 25th in New York (EDT, UTC-4).
        XCTAssertEqual(rule(value), "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261026T035959Z")
    }

    func testAnEndDateAcrossTheClockChangeUsesThatDaysOffset() {
        let value = EventRepeat(frequency: .daily, end: .onDate(date(2026, 11, 2, 0)))
        // US clocks go back on 1 Nov: the 2nd ends at 23:59:59 EST (UTC-5).
        XCTAssertEqual(rule(value), "RRULE:FREQ=DAILY;UNTIL=20261103T045959Z")
    }

    func testAnAllDaySeriesEndsOnADate() {
        let value = EventRepeat(frequency: .daily, end: .onDate(date(2026, 10, 25, 0)))
        XCTAssertEqual(rule(value, allDay: true), "RRULE:FREQ=DAILY;UNTIL=20261025")
    }

    // MARK: - Reading

    func testEveryRuleReadsBackAsItself() {
        let values: [EventRepeat] = [
            EventRepeat(frequency: .daily),
            EventRepeat(frequency: .daily, interval: 3, end: .afterCount(4)),
            EventRepeat(frequency: .weekly, weekdays: [.monday, .wednesday, .friday]),
            EventRepeat(frequency: .weekly, interval: 2, weekdays: [.tuesday, .thursday],
                        end: .onDate(date(2026, 12, 18, 0))),
            EventRepeat(frequency: .monthly, monthly: .dayOfMonth(6)),
            EventRepeat(frequency: .monthly, monthly: .weekdayOrdinal(ordinal: -1, weekday: .friday)),
            EventRepeat(frequency: .yearly, end: .afterCount(5)),
        ]
        for value in values {
            for allDay in [false, true] {
                XCTAssertEqual(EventRepeat.parse([rule(value, allDay: allDay)], start: tuesday, calendar: calendar),
                               .rule(value), rule(value, allDay: allDay))
            }
        }
    }

    func testAWeeklyRuleWithoutDaysIsOnTheStartsDay() {
        XCTAssertEqual(EventRepeat.parse(["RRULE:FREQ=WEEKLY"], start: tuesday, calendar: calendar),
                       .rule(EventRepeat(frequency: .weekly, weekdays: [.tuesday])))
    }

    func testDailyOnlyOnWeekdaysIsEveryWeekday() {
        let parsed = EventRepeat.parse(["RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"], start: tuesday, calendar: calendar)
        XCTAssertEqual(parsed, .rule(EventRepeat(frequency: .weekly, weekdays: EventRepeat.Weekday.workdays)))
        XCTAssertEqual(EventRepeat.preset(of: parsed), .weekdays)
    }

    func testSkippedOccurrencesDontChangeTheRepeat() {
        let lines = ["EXDATE;TZID=America/New_York:20261013T100000", "RRULE:FREQ=WEEKLY;BYDAY=TU"]
        XCTAssertEqual(EventRepeat.parse(lines, start: tuesday, calendar: calendar),
                       .rule(EventRepeat(frequency: .weekly, weekdays: [.tuesday])))
    }

    func testWhatThePickerCantShowIsKeptVerbatim() {
        for lines in [["RRULE:FREQ=WEEKLY;BYDAY=TU", "RRULE:FREQ=MONTHLY;BYMONTHDAY=1"],
                      ["RRULE:FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=-1"],
                      ["RRULE:FREQ=HOURLY"],
                      ["RRULE:FREQ=WEEKLY;BYDAY=1MO"],
                      ["RRULE:FREQ=YEARLY;BYMONTH=3"]] {
            XCTAssertEqual(EventRepeat.parse(lines, start: tuesday, calendar: calendar), .unsupported(lines), "\(lines)")
        }
        XCTAssertEqual(EventRepeat.parse([], start: tuesday, calendar: calendar), EventRecurrence.none)
    }

    func testChangingTheRuleKeepsSkippedAndAddedOccurrences() {
        let lines = ["RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE:20261013T140000Z", "RDATE:20261015T140000Z"]
        XCTAssertEqual(EventRepeat.replacingRule(in: lines, with: "RRULE:FREQ=WEEKLY;BYDAY=TU,TH"),
                       ["RRULE:FREQ=WEEKLY;BYDAY=TU,TH", "EXDATE:20261013T140000Z", "RDATE:20261015T140000Z"])
    }

    // MARK: - Picker

    func testWhichPickerRowARuleReadsAs() {
        XCTAssertEqual(EventRepeat.preset(of: .none), .never)
        XCTAssertEqual(EventRepeat.preset(of: .rule(EventRepeat(frequency: .weekly, weekdays: [.tuesday]))), .weekly)
        XCTAssertEqual(EventRepeat.preset(of: .rule(EventRepeat(frequency: .weekly, weekdays: [.monday, .friday]))),
                       .weekly, "several days are still Weekly, with its day toggles")
        XCTAssertEqual(EventRepeat.preset(of: .rule(EventRepeat(frequency: .weekly, interval: 2, weekdays: [.tuesday]))),
                       .custom)
        XCTAssertEqual(EventRepeat.preset(of: .rule(EventRepeat(frequency: .monthly,
                                                                monthly: .weekdayOrdinal(ordinal: 1, weekday: .tuesday)))),
                       .custom)
        XCTAssertEqual(EventRepeat.preset(of: .unsupported(["RRULE:FREQ=HOURLY"])), .custom)
    }

    func testAStartOffTheChosenDaysMovesToTheFirstOfThem() {
        let value = EventRepeat(frequency: .weekly, weekdays: [.monday, .wednesday, .friday])
        XCTAssertEqual(value.alignedStart(tuesday, calendar: calendar), date(2026, 10, 7), "Wednesday, same time")
        XCTAssertNil(value.alignedStart(date(2026, 10, 5), calendar: calendar), "a Monday is already one of them")
        XCTAssertNil(EventRepeat(frequency: .daily).alignedStart(tuesday, calendar: calendar))
    }

    func testTheWeekStartsWhereTheLocaleStartsIt() {
        var us = calendar
        us.firstWeekday = 1
        XCTAssertEqual(EventRepeat.Weekday.ordered(for: us).first, .sunday)
        XCTAssertEqual(EventRepeat.Weekday.ordered(for: calendar).first, .monday)
        XCTAssertEqual(EventRepeat.Weekday.ordered(for: calendar).count, 7)
    }

    // MARK: - Words

    func testSummaries() {
        func summary(_ value: EventRepeat, _ calendar: Calendar? = nil) -> String {
            value.summary(start: tuesday, calendar: calendar ?? self.calendar, locale: british)
        }
        XCTAssertEqual(summary(EventRepeat(frequency: .weekly, weekdays: [.friday, .monday, .wednesday])),
                       "Every week on Mon, Wed and Fri")
        XCTAssertEqual(summary(EventRepeat(frequency: .weekly, weekdays: EventRepeat.Weekday.workdays)), "Every weekday")
        XCTAssertEqual(summary(EventRepeat(frequency: .weekly, interval: 2, weekdays: [.tuesday])), "Every 2 weeks on Tue")
        XCTAssertEqual(summary(EventRepeat(frequency: .daily)), "Every day")
        XCTAssertEqual(summary(EventRepeat(frequency: .monthly)), "Every month on the 6th")
        XCTAssertEqual(summary(EventRepeat(frequency: .monthly, monthly: .weekdayOrdinal(ordinal: -1, weekday: .friday))),
                       "Every month on the last Friday")
        XCTAssertEqual(summary(EventRepeat(frequency: .daily, end: .afterCount(10))), "Every day, 10 times")
        XCTAssertTrue(summary(EventRepeat(frequency: .daily, end: .onDate(date(2026, 10, 25, 0))))
            .hasPrefix("Every day, until 25 Oct"))
        var us = calendar
        us.firstWeekday = 1
        XCTAssertEqual(summary(EventRepeat(frequency: .weekly, weekdays: [.monday, .sunday]), us), "Every week on Sun and Mon",
                       "days in the locale's week order")
    }

    func testTheLineUnderAnEvent() {
        let line = EventRecurrence.rule(EventRepeat(frequency: .weekly, weekdays: [.monday, .wednesday, .friday]))
            .detailLine(start: tuesday, calendar: calendar, locale: british)
        XCTAssertEqual(line, "Repeats every week on Mon, Wed and Fri")
        XCTAssertNil(EventRecurrence.none.detailLine(start: tuesday))
        XCTAssertEqual(EventRecurrence.unsupported(["RRULE:FREQ=HOURLY"]).detailLine(start: tuesday),
                       "Repeats on a custom rule from Google Calendar")
    }
}
