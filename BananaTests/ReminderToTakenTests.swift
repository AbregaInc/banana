import XCTest

/// A repeating reminder that's something taken, moved into Taken (`ReminderToTaken`,
/// docs/design/ANCHORED-TIMING.md): which reminders read that way, the Taken item one becomes,
/// and its ticks as doses.
final class ReminderToTakenTests: XCTestCase {
    private typealias RT = ReminderToTaken

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 22))! }
    private func at(_ daysAgo: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    // MARK: - Which reminders

    func testSomethingTakenReadsAsTaken() {
        for title in ["Creatine", "Vitamin D", "Take meds", "Magnesium", "Fish oil", "Omega-3", "Probiotic",
                      "Melatonin", "Take my pills", "Electrolytes", "D3", "Levothyroxine", "Iron"] {
            XCTAssertTrue(RT.readsAsTaken(title), title)
        }
    }

    func testEverythingElseDoesNot() {
        for title in ["Workout", "Call Grandma", "Water the plants", "Coffee", "Buy creatine", "Order vitamins",
                      "Iron shirts", "Refill the pill organizer", "Ironing", ""] {
            XCTAssertFalse(RT.readsAsTaken(title), title)
        }
    }

    func testOnlyRepeatingDailyOrWeeklyAndStillGoing() {
        XCTAssertTrue(RT.isCandidate(title: "Creatine", recurrence: .daily, completed: false))
        XCTAssertTrue(RT.isCandidate(title: "Vitamin D", recurrence: .weekly, completed: false))
        XCTAssertFalse(RT.isCandidate(title: "Creatine", recurrence: .never, completed: false), "a one-off")
        XCTAssertFalse(RT.isCandidate(title: "Creatine", recurrence: .monthly, completed: false))
        XCTAssertFalse(RT.isCandidate(title: "Creatine", recurrence: .daily, completed: true), "finished for good")
        XCTAssertFalse(RT.isCandidate(title: "Workout", recurrence: .daily, completed: false))
    }

    func testAPrescriptionWhenTheTitleSaysSo() {
        XCTAssertEqual(RT.kind("Take meds"), .medication)
        XCTAssertEqual(RT.kind("Medication"), .medication)
        XCTAssertEqual(RT.kind("Prescription refill time"), .medication)
        XCTAssertEqual(RT.kind("Levothyroxine"), .medication, "a drug Banana knows is a prescription")
        XCTAssertEqual(RT.kind("Creatine"), .supplement)
        XCTAssertEqual(RT.kind("Vitamin D"), .supplement)
    }

    func testTheNameLeavesOutTake() {
        XCTAssertEqual(RT.name("Take meds"), "Meds")
        XCTAssertEqual(RT.name("take vitamin D"), "Vitamin D")
        XCTAssertEqual(RT.name("Take my pills"), "Pills")
        XCTAssertEqual(RT.name("  Creatine "), "Creatine")
        XCTAssertEqual(RT.name("Take"), "Take")
    }

    // MARK: - What it becomes

    private func offer(_ title: String = "Creatine", due: Date? = nil, hasTime: Bool = false,
                       anchor: TimingAnchor? = nil) -> RT.Offer {
        RT.Offer(reminderID: "local", externalID: "stable", title: title, due: due, hasTime: hasTime, anchor: anchor)
    }

    func testTheTakenItemKeepsTheRemindersTimeElse8PM() {
        let timed = RT.schedule(for: offer(due: at(0, 7, 30), hasTime: true), calendar: calendar)
        XCTAssertEqual([timed.hour, timed.minute], [7, 30])
        let untimed = RT.schedule(for: offer(due: at(0, 0), hasTime: false), calendar: calendar)
        XCTAssertEqual([untimed.hour, untimed.minute], [20, 0])
        XCTAssertNil(untimed.anchor)
    }

    func testTheTakenItemCarriesItsMomentAndKind() {
        let afterWorkout = TimingAnchor(moment: .workout, minutes: 15)
        let item = RT.schedule(for: offer("Take meds", anchor: afterWorkout), calendar: calendar)
        XCTAssertEqual(item.name, "Meds")
        XCTAssertEqual(item.kind, .medication)
        XCTAssertEqual(item.anchor, afterWorkout)
        XCTAssertEqual(offer().id, "reminder:stable", "the key a learned anchor for it uses")
    }

    func testItsTicksBecomeOneDoseADay() {
        let id = UUID()
        let ticks = [
            at(1, 18, 20), at(1, 18, 15),   // ticked twice: the first is the day's dose
            at(2, 9),
            at(59, 8),                      // inside 60 days
            at(70, 8),                      // too long ago
            now.addingTimeInterval(60),     // not yet
        ]
        let logs = RT.logs(for: id, completions: ticks, now: now, calendar: calendar)
        XCTAssertEqual(logs.map(\.date), [at(1, 18, 15), at(2, 9), at(59, 8)], "newest first")
        XCTAssertEqual(logs.map(\.day), ["20261002", "20261001", "20260805"])
        XCTAssertTrue(logs.allSatisfy { $0.status == .taken && $0.supplementID == id })
    }

    func testTheOfferSaysWhatMovingGives() {
        XCTAssertEqual(offer().sentence,
                       "Creatine is a reminder. Move it to Taken? It\u{2019}ll be logged taken or skipped, checked for clashes, and can be due after your workout.")
        XCTAssertEqual(offer(anchor: TimingAnchor(moment: .workout, minutes: 15)).sentence,
                       "Creatine is a reminder. Move it to Taken? It\u{2019}ll be logged taken or skipped, checked for clashes, and due 15m after your workout.")
    }
}
