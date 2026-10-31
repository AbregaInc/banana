import XCTest

/// Things due around other things (`AnchoredTiming`, docs/design/ANCHORED-TIMING.md): due at the
/// moment plus its offset, waiting until then, at its own time — or skipped — when it doesn't come.
final class AnchoredTimingTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: hour, minute: minute))!
    }

    private let creatine = TimingAnchor(moment: .workout)

    func testWaitingIsNotLate() {
        // Creatine's own time is 8 PM; it's 9 AM and no workout yet.
        XCTAssertEqual(AnchoredTiming.due(creatine, usual: at(20), signals: .init(), now: at(9), calendar: calendar),
                       .waiting("After your workout"))
    }

    func testDueWhenTheWorkoutEnds() {
        var signals = AnchoredTiming.Signals()
        signals.workouts = [(at(10), at(10, 50))]
        XCTAssertEqual(AnchoredTiming.due(creatine, usual: at(20), signals: signals, now: at(11), calendar: calendar), .at(at(10, 50)))
        let later = TimingAnchor(moment: .workout, minutes: 15)
        XCTAssertEqual(AnchoredTiming.due(later, usual: at(20), signals: signals, now: at(11), calendar: calendar), .at(at(11, 5)))
    }

    func testNoWorkoutFallsBackToItsOwnTimeOrSkips() {
        XCTAssertEqual(AnchoredTiming.due(creatine, usual: at(20), signals: .init(), now: at(20, 5), calendar: calendar), .at(at(20)))
        let skipping = TimingAnchor(moment: .workout, fallback: .skip)
        XCTAssertEqual(AnchoredTiming.due(skipping, usual: at(20), signals: .init(), now: at(23, 59), calendar: calendar),
                       .waiting("After your workout"))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: at(0, 30))!
        XCTAssertEqual(AnchoredTiming.due(skipping, usual: at(20), signals: .init(), now: tomorrow, calendar: calendar), .skipped)
    }

    func testBeforeUsesWhatsPlannedElseTheStart() {
        let preWorkout = TimingAnchor(moment: .workout, relation: .before, minutes: 30)
        var planned = AnchoredTiming.Signals()
        planned.plannedWorkout = at(18)
        XCTAssertEqual(AnchoredTiming.due(preWorkout, usual: at(17), signals: planned, now: at(9), calendar: calendar), .at(at(17, 30)))
        var started = AnchoredTiming.Signals()
        started.workoutStarted = at(7, 10)
        XCTAssertEqual(AnchoredTiming.due(preWorkout, usual: at(17), signals: started, now: at(7, 15), calendar: calendar), .at(at(6, 40)))
    }

    func testBeforeBreakfastUsesWhenYouUsuallyHaveIt() {
        let levothyroxine = TimingAnchor(moment: .meal(MealTextPart.breakfast.rawValue), relation: .before, minutes: 30)
        var signals = AnchoredTiming.Signals()
        signals.usualMeals = [.breakfast: 8 * 60 + 15]
        XCTAssertEqual(AnchoredTiming.due(levothyroxine, usual: at(7), signals: signals, now: at(6), calendar: calendar), .at(at(7, 45)))
        XCTAssertEqual(AnchoredTiming.label(levothyroxine), "30m before breakfast")
    }

    func testAfterAMealLogged() {
        let vitaminD = TimingAnchor(moment: .meal(MealTextPart.lunch.rawValue))
        var signals = AnchoredTiming.Signals()
        signals.meals = [(at(8), .breakfast), (at(12, 40), .lunch)]
        XCTAssertEqual(AnchoredTiming.due(vitaminD, usual: at(14), signals: signals, now: at(13), calendar: calendar), .at(at(12, 40)))
        XCTAssertEqual(AnchoredTiming.mealPart(at: at(12, 40), calendar: calendar), .lunch)
    }

    func testAfterAnotherReminderIsTicked() {
        let afterWorkoutReminder = TimingAnchor(moment: .reminder(id: "series-1", title: "Workout"))
        var signals = AnchoredTiming.Signals()
        // A completed copy of a repeating reminder can carry another id: its title still finds it.
        signals.ticked = ["workout": at(9, 30)]
        XCTAssertEqual(AnchoredTiming.due(afterWorkoutReminder, usual: at(20), signals: signals, now: at(9, 31), calendar: calendar),
                       .at(at(9, 30)))
        XCTAssertEqual(AnchoredTiming.label(afterWorkoutReminder), "After Workout")
    }

    func testAfterAnEventEnds() {
        let anchor = TimingAnchor(moment: .event(["gym"]), minutes: 10)
        var signals = AnchoredTiming.Signals()
        signals.events = [("Gym with Sam", at(17), at(18))]
        XCTAssertEqual(AnchoredTiming.due(anchor, usual: at(21), signals: signals, now: at(17, 30), calendar: calendar),
                       .waiting("10m after \u{201C}gym\u{201D}"), "not over yet")
        XCTAssertEqual(AnchoredTiming.due(anchor, usual: at(21), signals: signals, now: at(18, 5), calendar: calendar), .at(at(18, 10)))
    }

    func testWords() {
        XCTAssertEqual(AnchoredTiming.label(TimingAnchor(moment: .wake, minutes: 15)), "15m after waking")
        XCTAssertEqual(AnchoredTiming.label(TimingAnchor(moment: .workout, relation: .before)), "Just before your workout")
        XCTAssertEqual(AnchoredTiming.duration(90), "1h 30m")
    }

    func testAnAnchorFromANewerBuildLeavesTheItemAtItsTime() throws {
        let json = #"{"name":"Creatine","hour":20,"anchor":{"moment":{"somethingNew":{}},"relation":"after"}}"#
        let item = try JSONDecoder().decode(SupplementSchedule.self, from: Data(json.utf8))
        XCTAssertNil(item.anchor)
        XCTAssertEqual(item.hour, 20)
        let roundTrip = try JSONDecoder().decode(SupplementSchedule.self,
                                                 from: JSONEncoder().encode(SupplementSchedule(name: "Creatine", anchor: creatine)))
        XCTAssertEqual(roundTrip.anchor, creatine)
    }

    func testTheBadgeCountsADoseOnlyOnceItsDue() {
        let creatineItem = SupplementSchedule(name: "Creatine", hour: 8, anchor: creatine)
        let count = ActionItems.dosesDue([creatineItem], marked: { _ in false }, due: { _ in nil },
                                         now: at(9), calendar: calendar)
        XCTAssertEqual(count, 0, "waiting for the workout isn't due")
    }

    /// What Taken shows in yellow is what the badge counts: due, and not yet taken or skipped.
    func testDueSinceIsTheBadgesRule() {
        let item = SupplementSchedule(name: "Magnesium", hour: 8)
        XCTAssertEqual(ActionItems.dueSince(item, marked: false, due: at(8), now: at(9)), at(8))
        XCTAssertNil(ActionItems.dueSince(item, marked: true, due: at(8), now: at(9)), "taken or skipped")
        XCTAssertNil(ActionItems.dueSince(item, marked: false, due: at(10), now: at(9)), "later today")
        XCTAssertNil(ActionItems.dueSince(item, marked: false, due: nil, now: at(9)), "waiting for its moment")
        var off = item
        off.enabled = false
        XCTAssertNil(ActionItems.dueSince(off, marked: false, due: at(8), now: at(9)))
    }

    /// Ticking the reminder that is your workout counts as the workout, recorded or not; one
    /// that's something done around a workout doesn't.
    func testTickingTheWorkoutReminderIsTheWorkoutEnding() {
        XCTAssertTrue(AnchorSuggestions.isWorkout("Workout"))
        XCTAssertTrue(AnchorSuggestions.isWorkout("Gym"))
        XCTAssertTrue(AnchorSuggestions.isWorkout("Morning run"))
        XCTAssertFalse(AnchorSuggestions.isWorkout("Post-workout protein"), "taken after one, not the workout")
        XCTAssertFalse(AnchorSuggestions.isWorkout("Creatine"))

        let ticks = AnchoredTiming.tickedWorkouts([(start: at(7), done: at(9, 40)), (start: nil, done: at(9, 41)),
                                                   (start: at(11), done: at(9, 42))])
        XCTAssertEqual(ticks.map(\.start), [at(7), at(9, 40), at(9, 41)], "its time if before the tick, else just before")
        XCTAssertEqual(ticks.map(\.end), [at(9, 40), at(9, 41), at(9, 42)])

        var signals = AnchoredTiming.Signals()
        signals.workouts = AnchoredTiming.todaysWorkouts(AnchoredTiming.tickedWorkouts([(start: nil, done: at(9, 40))]),
                                                         now: at(9, 41), calendar: calendar)
        XCTAssertEqual(AnchoredTiming.due(TimingAnchor(moment: .workout, minutes: 15), usual: at(20), signals: signals,
                                          now: at(9, 41), calendar: calendar), .at(at(9, 55)),
                       "Creatine 15m after \u{201C}Workout\u{201D} was ticked")
    }

    /// Taken's reminders show while the app is in front; nothing else changes.
    func testOnlyTakenRemindersShowOverTheApp() {
        let id = UUID()
        XCTAssertTrue(SupplementSchedule.isReminder(notificationID: SupplementSchedule.notificationPrefix + id.uuidString))
        XCTAssertTrue(SupplementSchedule.isReminder(notificationID: SupplementSchedule.notificationPrefix + "\(id.uuidString).1791000000"))
        XCTAssertFalse(SupplementSchedule.isReminder(notificationID: "mealPhoto.\(id.uuidString)"))
    }

    /// A Watch workout is a moment as soon as the phone has it, before Health does — and the same
    /// workout from both counts once.
    func testTodaysWorkoutsComeFromEverySourceOnce() {
        let health = (start: at(7), end: at(7, 45))
        let watchCopy = (start: at(7, 0).addingTimeInterval(30), end: at(7, 46))
        let watchOnly = (start: at(9, 10), end: at(9, 50))
        let yesterday = (start: at(7).addingTimeInterval(-86_400), end: at(8).addingTimeInterval(-86_400))
        let underWay = (start: at(10), end: at(10, 40))
        let workouts = AnchoredTiming.todaysWorkouts([watchOnly, health, yesterday, watchCopy, underWay],
                                                     now: at(10, 5), calendar: calendar)
        XCTAssertEqual(workouts.count, 2)
        XCTAssertEqual(workouts.first?.end, at(7, 46))
        XCTAssertEqual(workouts.last?.end, at(9, 50))

        var signals = AnchoredTiming.Signals()
        signals.workouts = AnchoredTiming.todaysWorkouts([watchOnly], now: at(10), calendar: calendar)
        XCTAssertEqual(AnchoredTiming.due(TimingAnchor(moment: .workout, minutes: 15), usual: at(20), signals: signals,
                                          now: at(10), calendar: calendar), .at(at(10, 5)),
                       "Creatine 15m after a workout only the Watch knows about")
    }
}

/// A tied reminder on the day, and in Reminders.
final class AnchoredReminderTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testWaitingIsUntimedAndNeverOverdue() {
        let timing = AnchoredTiming.taskTiming(due: at(8), hasTime: true, completed: false,
                                               anchored: .waiting("After your workout"), now: at(9), calendar: calendar)
        XCTAssertFalse(timing.overdue, "8 AM passed, but it waits for the workout")
        XCTAssertFalse(timing.hasScheduledTime)
        XCTAssertEqual(timing.waitingFor, "After your workout")
    }

    func testDueAtItsMomentThenLateAfter() {
        let soon = AnchoredTiming.taskTiming(due: at(20), hasTime: true, completed: false, anchored: .at(at(11, 5)),
                                             now: at(11), calendar: calendar)
        XCTAssertEqual(soon.deadline, at(11, 5))
        XCTAssertTrue(soon.hasScheduledTime)
        XCTAssertFalse(soon.overdue)
        let late = AnchoredTiming.taskTiming(due: at(20), hasTime: true, completed: false, anchored: .at(at(10, 50)),
                                             now: at(11), calendar: calendar)
        XCTAssertTrue(late.overdue)
        XCTAssertEqual(late.start, at(11), "pulled up to now")
    }

    func testAnUntiedReminderIsAsBefore() {
        let plain = AnchoredTiming.taskTiming(due: at(8), hasTime: true, completed: false, anchored: nil, now: at(9), calendar: calendar)
        XCTAssertTrue(plain.overdue)
        XCTAssertNil(plain.waitingFor)
    }

    func testRemindersMovesTodayToTheMomentAndOtherDaysBack() {
        // The workout ended at 10:50: today's 8 PM creatine moves there.
        XCTAssertEqual(AnchoredTiming.reminderMove(storedDue: at(20), hasTime: true, usualMinutes: 20 * 60,
                                                   today: .at(at(10, 50)), now: at(11), calendar: calendar), at(10, 50))
        // Already there: nothing to do.
        XCTAssertNil(AnchoredTiming.reminderMove(storedDue: at(10, 50), hasTime: true, usualMinutes: 20 * 60,
                                                 today: .at(at(10, 50)), now: at(11), calendar: calendar))
        // Ticked, the series came back tomorrow at 10:50: put back to 8 PM.
        XCTAssertEqual(AnchoredTiming.reminderMove(storedDue: at(10, 50, day: 4), hasTime: true, usualMinutes: 20 * 60,
                                                   today: nil, now: at(11), calendar: calendar), at(20, day: 4))
        // Waiting today at a moved time: back to its own.
        XCTAssertEqual(AnchoredTiming.reminderMove(storedDue: at(10, 50), hasTime: true, usualMinutes: 20 * 60,
                                                   today: .waiting("After your workout"), now: at(9), calendar: calendar), at(20))
        XCTAssertNil(AnchoredTiming.reminderMove(storedDue: at(10, 50), hasTime: false, usualMinutes: 20 * 60,
                                                 today: .at(at(11)), now: at(11), calendar: calendar), "no time, nothing to move")
    }
}
