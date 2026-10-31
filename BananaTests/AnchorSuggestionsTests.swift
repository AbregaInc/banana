import XCTest

/// Learning what something is done after (`AnchorSuggestions`, docs/design/ANCHORED-TIMING.md):
/// done within the hour after the same moment on most days both happened, and on at least four,
/// is offered that moment. As much care on what must NOT be offered — a suggestion that's wrong
/// teaches you to ignore the ones that are right.
final class AnchorSuggestionsTests: XCTestCase {
    private typealias AS = AnchorSuggestions

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    /// Saturday 3 October 2026, 10 PM.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 22))! }
    /// `daysAgo` days before today, at this time.
    private func at(_ daysAgo: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private let creatineID = UUID()
    private func creatine(_ done: [Date], anchored: Bool = false) -> AS.Item {
        AS.Item(subject: .taken(creatineID), name: "Creatine", done: done, anchored: anchored)
    }

    /// Workouts at all hours; Creatine 12–20 min after on six days, before the workout on two.
    private var habit: (workouts: [Date], creatine: [Date]) {
        let workouts = [at(1, 7), at(2, 12, 30), at(3, 18), at(5, 6, 45), at(6, 17, 10), at(8, 9), at(9, 19), at(11, 13)]
        let creatine = [at(1, 7, 12), at(2, 12, 44), at(3, 18, 15), at(5, 7, 1), at(6, 17, 28), at(8, 9, 20),
                        at(9, 8), at(11, 8)]
        return (workouts, creatine)
    }

    func testAClearHabitIsOffered() throws {
        let suggestion = try XCTUnwrap(AS.best(for: creatine(habit.creatine),
                                               moments: [.init(.workout, times: habit.workouts)],
                                               now: now, calendar: calendar))
        XCTAssertEqual(suggestion.anchor, TimingAnchor(moment: .workout, relation: .after, minutes: 15, fallback: .usualTime))
        XCTAssertEqual(suggestion.followed, 6)
        XCTAssertEqual(suggestion.together, 8)
        XCTAssertEqual(suggestion.sentence,
                       "Creatine usually follows your workout \u{2014} about 15m after, on 6 of the last 8 days.")
        XCTAssertEqual(suggestion.question, "Creatine after workouts?")
    }

    func testNoHabitIsNotOffered() {
        // Taken at 8 every morning whenever the workout was.
        let creatine = habit.workouts.map { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0)! }
        XCTAssertNil(AS.best(for: self.creatine(creatine), moments: [.init(.workout, times: habit.workouts)],
                             now: now, calendar: calendar))
    }

    func testTooFewDaysAreNotAHabit() {
        let workouts = [at(1, 7), at(2, 12), at(3, 18)]
        let creatine = workouts.map { $0.addingTimeInterval(15 * 60) }
        XCTAssertNil(AS.best(for: self.creatine(creatine), moments: [.init(.workout, times: workouts)],
                             now: now, calendar: calendar), "three days out of three is still only three")
    }

    func testFollowingOnFewerThanMostDaysIsNotAHabit() {
        // Five of nine days: 56%.
        let workouts = (1...9).map { at($0, 7 + $0) }
        let creatine = workouts.enumerated().map { $0.offset < 5 ? $0.element.addingTimeInterval(10 * 60) : at($0.offset + 1, 6) }
        XCTAssertNil(AS.best(for: self.creatine(creatine), moments: [.init(.workout, times: workouts)],
                             now: now, calendar: calendar))
    }

    func testOnlyTheLastThreeWeeksCount() {
        let workouts = (25...32).map { at($0, 7) }
        let creatine = workouts.map { $0.addingTimeInterval(15 * 60) }
        XCTAssertNil(AS.best(for: self.creatine(creatine), moments: [.init(.workout, times: workouts)],
                             now: now, calendar: calendar), "last month's routine doesn't speak for this one")
    }

    func testTheMomentFollowedOnMoreDaysWins() throws {
        // Breakfast shortly before the workout: Creatine follows both within the hour on most
        // days — breakfast on five, the workout on six.
        let breakfasts = [at(1, 6, 30), at(2, 12, 10), at(3, 17, 40), at(5, 6, 20), at(6, 16, 40), at(8, 8, 10),
                          at(9, 6), at(11, 6)]
        let suggestion = try XCTUnwrap(AS.best(for: creatine(habit.creatine),
                                               moments: [.init(.meal(MealTextPart.breakfast.rawValue), times: breakfasts),
                                                         .init(.workout, times: habit.workouts)],
                                               now: now, calendar: calendar))
        XCTAssertEqual(suggestion.anchor.moment, .workout)
        XCTAssertEqual(AS.best(for: creatine(habit.creatine),
                               moments: [.init(.meal(MealTextPart.breakfast.rawValue), times: breakfasts)],
                               now: now, calendar: calendar)?.followed, 5, "breakfast alone would have been offered")
    }

    func testOnEqualDaysTheSteadierGapWins() throws {
        let days = Array(1...6)
        let done = days.map { at($0, 12) }
        // Waking wanders from 5 to 55 min before; the walk is always 15 min before.
        let wakes = days.enumerated().map { done[$0.offset].addingTimeInterval(-Double([5, 55, 20, 45, 10, 35][$0.offset]) * 60) }
        let walks = done.map { $0.addingTimeInterval(-15 * 60) }
        let suggestion = try XCTUnwrap(AS.best(
            for: creatine(done),
            moments: [.init(.wake, times: wakes), .init(.event(["Walk"]), times: walks)],
            now: now, calendar: calendar))
        XCTAssertEqual(suggestion.anchor.moment, .event(["Walk"]))
        XCTAssertEqual(suggestion.anchor.minutes, 15)
    }

    func testSomethingAlreadyAnchoredIsNotOffered() {
        XCTAssertNil(AS.best(for: creatine(habit.creatine, anchored: true), moments: [.init(.workout, times: habit.workouts)],
                             now: now, calendar: calendar))
    }

    func testNeverAnchoredToItself() {
        let done = habit.creatine
        XCTAssertNil(AS.best(for: creatine(done), moments: [.init(.dose(id: creatineID, name: "Creatine"), times: done.map { $0.addingTimeInterval(-600) })],
                             now: now, calendar: calendar), "its own dose")
        // A reminder called "Workout" is ticked after the workout because it is the workout.
        let workout = AS.Item(subject: .reminder(externalID: "w", title: "Workout"), name: "Workout",
                              done: habit.workouts.map { $0.addingTimeInterval(20 * 60) })
        XCTAssertNil(AS.best(for: workout, moments: [.init(.workout, times: habit.workouts),
                                                     .init(.reminder(id: "w", title: "Workout"), times: workout.done)],
                             now: now, calendar: calendar))
        // Something taken after the workout is not the workout.
        let shake = AS.Item(subject: .reminder(externalID: "p", title: "Post-workout protein"), name: "Post-workout protein",
                            done: habit.workouts.map { $0.addingTimeInterval(20 * 60) })
        XCTAssertEqual(AS.best(for: shake, moments: [.init(.workout, times: habit.workouts)], now: now, calendar: calendar)?
            .anchor.moment, .workout)
    }

    func testNeverTiedToSomethingTiedToIt() {
        // Vitamin D already waits for Creatine; Creatine isn't then offered Vitamin D.
        let vitaminD = UUID()
        let taken = habit.creatine.map { $0.addingTimeInterval(-10 * 60) }
        let moment = AS.Moment(.dose(id: vitaminD, name: "Vitamin D"), times: taken,
                               anchoredTo: .dose(id: creatineID, name: "Creatine"))
        XCTAssertNil(AS.best(for: creatine(habit.creatine), moments: [moment], now: now, calendar: calendar))
    }

    func testTicksInOneSittingAreNotOneFollowingTheOther() {
        // The morning pills, ticked down the list: Vitamin D 20 seconds after Magnesium each day.
        let magnesium = (1...10).map { at($0, 8, $0) }
        let vitaminD = AS.Item(subject: .taken(UUID()), name: "Vitamin D", done: magnesium.map { $0.addingTimeInterval(20) })
        XCTAssertNil(AS.best(for: vitaminD, moments: [.init(.dose(id: UUID(), name: "Magnesium"), times: magnesium)],
                             now: now, calendar: calendar))
        // Right after the workout is a habit, though.
        let rightAfter = AS.best(for: creatine(habit.workouts.map { $0.addingTimeInterval(60) }),
                                 moments: [.init(.workout, times: habit.workouts)], now: now, calendar: calendar)
        XCTAssertEqual(rightAfter?.anchor.minutes, 0)
        XCTAssertEqual(rightAfter?.sentence,
                       "Creatine usually follows your workout \u{2014} right after, on 8 of the last 8 days.")
    }

    func testSuggestionsAreOnePerItemStrongestFirst() {
        let magnesiumID = UUID()
        let magnesium = AS.Item(subject: .taken(magnesiumID), name: "Magnesium",
                                done: habit.workouts.prefix(5).map { $0.addingTimeInterval(30 * 60) })
        let all = AS.suggestions([magnesium, creatine(habit.creatine)], moments: [.init(.workout, times: habit.workouts)],
                                 now: now, calendar: calendar)
        XCTAssertEqual(all.map(\.name), ["Creatine", "Magnesium"])
        XCTAssertNotEqual(all[0].id, all[1].id)
    }

    func testGapsRoundToWhatTheEditorOffers() {
        XCTAssertEqual(AS.rounded(0.4), 0)
        XCTAssertEqual(AS.rounded(13), 15)
        XCTAssertEqual(AS.rounded(22.5), 15, "halfway goes to the shorter gap")
        XCTAssertEqual(AS.rounded(23), 30)
        XCTAssertEqual(AS.rounded(52), 45)
    }

    func testADoseTickedOffForAPastDayIsNotWhenItWasTaken() {
        let supplement = SupplementSchedule(name: "Creatine", hour: 20)
        let logs = [
            SupplementLog(supplementID: supplement.id, date: at(1, 18, 14), status: .taken),
            SupplementLog(supplementID: supplement.id, date: at(2, 20), status: .taken),   // ticked off afterwards
            SupplementLog(supplementID: supplement.id, date: at(3, 18, 2), status: .skipped),
            SupplementLog(supplementID: UUID(), date: at(1, 9), status: .taken),
        ]
        XCTAssertEqual(AS.observed(logs, for: supplement, calendar: calendar), [at(1, 18, 14)])
    }

    func testKeysAreStableAcrossDevices() {
        XCTAssertEqual(AS.key(.reminder(externalID: "abc", title: "Creatine")), "reminder:abc")
        XCTAssertEqual(AS.key(.reminder(externalID: nil, title: " Creatine ")), "reminder:title:creatine")
        XCTAssertEqual(AS.key(.meal(nil)), "meal:first")
        XCTAssertEqual(AS.key(.reminder(id: "x", title: "Workout")), "reminder:workout")
    }
}
