import XCTest

/// A reminder ticked a moment ago stays ticked wherever it is drawn and whatever is read
/// meanwhile, until a read made after the tick is in (`TaskTicks`).
final class TaskTicksTests: XCTestCase {
    private struct Item: Equatable {
        var id: String
        var reminder: String?
        var completed = false
        var completedAt: Date?
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func applied(_ items: [Item], _ ticks: [String: TaskTicks.Tick]) -> [Item] {
        TaskTicks.applied(to: items, ticks: ticks, reminderID: \.reminder, id: \.id, completed: \.completed) { item, done, at in
            var item = item
            item.completed = done
            item.completedAt = at
            return item
        }
    }

    func testAWindowReadBeforeTheTickShowsItTicked() {
        // The calendar's cached window still has Reminders' older answer.
        let window = [Item(id: "task:plumber", reminder: "plumber"), Item(id: "event:standup")]
        let shown = applied(window, ["plumber": .init(completed: true, at: now)])
        XCTAssertEqual(shown[0], Item(id: "task:plumber", reminder: "plumber", completed: true, completedAt: now))
        XCTAssertEqual(shown[1], window[1], "nothing else changes")
    }

    func testOnlyTheTickedDayOfARepeatingReminder() {
        let days = [Item(id: "task:creatine:100", reminder: "creatine"), Item(id: "task:creatine:200", reminder: "creatine")]
        let shown = applied(days, ["creatine": .init(completed: true, onlyOccurrence: "task:creatine:100", at: now)])
        XCTAssertEqual(shown.map(\.completed), [true, false])
    }

    func testUntickingShowsToo() {
        let read = [Item(id: "task:plumber", reminder: "plumber", completed: true, completedAt: now)]
        let shown = applied(read, ["plumber": .init(completed: false)])
        XCTAssertEqual(shown, [Item(id: "task:plumber", reminder: "plumber")])
    }

    func testNoTicksIsTheReadItself() {
        let read = [Item(id: "task:plumber", reminder: "plumber")]
        XCTAssertEqual(applied(read, [:]), read)
    }

    func testWhatAReadStillDisagreesAboutIsWhatToGoBackTo() {
        // Reminders refused the tick: the next read still says not done.
        let read = [Item(id: "task:plumber", reminder: "plumber"),
                    Item(id: "task:passport", reminder: "passport", completed: true, completedAt: now)]
        let ticks: [String: TaskTicks.Tick] = ["plumber": .init(completed: true, at: now), "passport": .init(completed: true, at: now)]
        let back = TaskTicks.disagreements(in: read, ticks: ticks, reminderID: \.reminder, id: \.id, completed: \.completed)
        XCTAssertEqual(back, ["task:plumber": read[0]], "the one the read agrees about needs nothing")
    }

    // MARK: Undo

    func testATickWhoseWriteIsStillWaitingIsNotRetiredByARead() {
        // Ticked, and held for a few seconds so it can be undone: Reminders hasn't been told, so
        // the next read says "not done". That must not un-tick it on screen.
        let ticks: [String: TaskTicks.Tick] = ["plumber": .init(completed: true, at: now), "passport": .init(completed: true, at: now)]
        let result = TaskTicks.retiring(ticks, waiting: ["plumber"])
        XCTAssertEqual(Array(result.keep.keys), ["plumber"])
        XCTAssertEqual(Array(result.retire.keys), ["passport"])
        XCTAssertEqual(TaskTicks.retiring(ticks, waiting: []).keep, [:])
    }

    func testTheToastNamesTheReminderAndWhatHappened() {
        XCTAssertEqual(TaskTicks.message(title: "Call the plumber", completed: true), "Completed \u{201C}Call the plumber\u{201D}")
        XCTAssertEqual(TaskTicks.message(title: "Call the plumber", completed: false), "\u{201C}Call the plumber\u{201D} is not done")
        let long = TaskTicks.message(title: "Ask the building manager about the boiler inspection and the roof", completed: true)
        XCTAssertTrue(long.hasSuffix("\u{2026}\u{201D}"), long)
        XCTAssertLessThan(long.count, 60)
    }

    func testANarrowBlockOpensAsAWhole() {
        // A phone's seven-day week: about 50 pt a column. No room for a circle and words both.
        XCTAssertFalse(TaskTicks.blockHasTickTarget(width: 50))
        // The phone's Day, an iPad's week column, half a Day shared with another event.
        XCTAssertTrue(TaskTicks.blockHasTickTarget(width: 360))
        XCTAssertTrue(TaskTicks.blockHasTickTarget(width: 140))
        XCTAssertTrue(TaskTicks.blockHasTickTarget(width: 179))
    }
}
