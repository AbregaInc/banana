import XCTest

/// Typing an event the way you'd say it (`EventPhrase`): the dates are read by the system, so
/// these run against today's real date.
final class EventPhraseTests: XCTestCase {
    private let calendar = Calendar.current

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func testTitleTimeAndPlace() {
        let draft = EventPhrase.parse("Lunch with Sam tomorrow at 1pm at Balthazar")
        XCTAssertEqual(draft.title, "Lunch with Sam")
        XCTAssertEqual(draft.start, at(1, 13))
        XCTAssertEqual(draft.end, at(1, 14), "an hour unless it says")
        XCTAssertEqual(draft.location, "Balthazar")
        XCTAssertFalse(draft.isAllDay)
        XCTAssertNil(draft.recurrence)
    }

    func testABareHourIsAWakingHour() {
        XCTAssertEqual(EventPhrase.parse("Lunch tomorrow at 1").start, at(1, 13))
        XCTAssertEqual(EventPhrase.parse("Run tomorrow at 6am").start, at(1, 6))
    }

    func testADayWithNoTimeIsAllDay() {
        let draft = EventPhrase.parse("Dentist tomorrow")
        XCTAssertEqual(draft.title, "Dentist")
        XCTAssertTrue(draft.isAllDay)
        XCTAssertEqual(draft.start, at(1, 0))
        XCTAssertEqual(draft.end, at(2, 0))
    }

    func testHowLongItIs() {
        XCTAssertEqual(EventPhrase.parse("Call mom tomorrow at 6pm for half an hour").end, at(1, 18, 30))
        XCTAssertEqual(EventPhrase.parse("Review tomorrow at 2pm for 90 minutes").end, at(1, 15, 30))
        XCTAssertEqual(EventPhrase.parse("Hike tomorrow at 9am for an hour and a half").end, at(1, 10, 30))
    }

    func testRepeats() {
        let standup = EventPhrase.parse("Standup every weekday at 9:30am for 15 min")
        XCTAssertEqual(standup.title, "Standup")
        XCTAssertEqual(standup.recurrence?.repeatValue?.weekdays, EventRepeat.Weekday.workdays)
        XCTAssertEqual(standup.end.flatMap { end in standup.start.map { end.timeIntervalSince($0) } }, 15 * 60)

        let gym = EventPhrase.parse("Gym every Tuesday and Thursday at 7am")
        XCTAssertEqual(gym.title, "Gym")
        XCTAssertEqual(gym.recurrence?.repeatValue?.weekdays, [.tuesday, .thursday])
        XCTAssertEqual(gym.start.map { calendar.component(.hour, from: $0) }, 7)

        XCTAssertEqual(EventPhrase.parse("Piano on Mondays at 5pm").recurrence?.repeatValue?.weekdays, [.monday])

        // The place loses the time's "at", and the series starts on one of its days.
        let equinox = EventPhrase.parse("Gym every Tuesday and Thursday at 7am for 45 min at Equinox")
        XCTAssertEqual(equinox.location, "Equinox")
        XCTAssertEqual(equinox.title, "Gym")
        let weekday = equinox.start.map { calendar.component(.weekday, from: $0) }
        XCTAssertTrue(weekday == 3 || weekday == 5, "Tuesday or Thursday, not \(String(describing: weekday))")
        XCTAssertEqual(equinox.end.flatMap { end in equinox.start.map { end.timeIntervalSince($0) } }, 45 * 60)
        XCTAssertEqual(EventPhrase.parse("1:1 with Ana every other week at 11am").recurrence?.repeatValue?.interval, 2)
        XCTAssertEqual(EventPhrase.parse("Rent monthly").recurrence?.repeatValue?.frequency, .monthly)
    }

    func testATitleAloneSaysNothingMore() {
        XCTAssertFalse(EventPhrase.parse("Dentist").saysMore)
        XCTAssertFalse(EventPhrase.parse("Write the Q3 plan").saysMore)
    }

    func testAPlaceWithoutATime() {
        let draft = EventPhrase.parse("Drinks at the Ace Hotel tomorrow 7pm")
        XCTAssertEqual(draft.location, "the Ace Hotel")
        XCTAssertEqual(draft.title, "Drinks")
    }

    /// The model says which words are which; what isn't in the words is ignored.
    func testTheModelsReadingOnlyCountsWhereItHoldsUp() {
        let text = "dinner carbone friday 8pm with jess"
        let plain = EventPhrase.parse(text)
        let parts = EventPhrase.ModelParts(title: "Dinner with Jess", when: "friday 8pm", place: "Carbone",
                                           durationMinutes: 0, repeats: "none", repeatDays: [])
        let merged = EventPhrase.merged(plain, with: parts, text: text)
        XCTAssertEqual(merged.title, "Dinner with Jess")
        XCTAssertEqual(merged.location, "Carbone", "a place without 'at' the plain reading can't see")
        XCTAssertEqual(merged.start.map { calendar.component(.hour, from: $0) }, 20)

        let invented = EventPhrase.ModelParts(title: "Birthday dinner in Paris", when: "", place: "Paris",
                                              durationMinutes: 0, repeats: "none", repeatDays: [])
        let kept = EventPhrase.merged(plain, with: invented, text: text)
        XCTAssertNil(kept.location, "a place that isn't in the words is ignored")
        XCTAssertEqual(kept.title, plain.title)
    }

    func testTheModelsRepeatDays() {
        let text = "yoga tue thu 7am"
        let parts = EventPhrase.ModelParts(title: "Yoga", when: "7am", place: "", durationMinutes: 60,
                                           repeats: "weekly", repeatDays: ["Tuesday", "Thursday"])
        let merged = EventPhrase.merged(EventPhrase.parse(text), with: parts, text: text)
        XCTAssertEqual(merged.recurrence?.repeatValue?.weekdays, [.tuesday, .thursday])
    }

    func testThePreviewSaysWhatFillingInSets() {
        let draft = EventPhrase.parse("Gym every Tuesday and Thursday at 7am at Equinox")
        let preview = EventPhrase.preview(draft)
        XCTAssertTrue(preview.contains("Equinox"), preview)
        XCTAssertTrue(preview.contains("Weekly on Tue, Thu"), preview)
    }
}
