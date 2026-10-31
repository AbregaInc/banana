import XCTest

/// A delete happens at once and Undo puts the thing back exactly: the same id, the same place,
/// everything inside it. The two ways the app does that (`DeleteUndo`): the store takes it out
/// and puts it back (`Removed`), or it is only hidden until the Undo window closes.
@MainActor
final class DeleteUndoTests: XCTestCase {
    // MARK: - Put back: routines, guided plans, extras

    private func plan(_ title: String, exercises: Int) -> WorkoutPlan {
        WorkoutPlan(title: title, focus: .mixed, targetMinutes: 30,
                    exercises: (0..<exercises).map {
                        ExercisePrescription(exerciseID: "ex\($0)", sets: 3, reps: 8 + $0, durationSeconds: nil, restSeconds: 60)
                    },
                    rationale: "why \(title)")
    }

    func testAPlanComesBackWhereItWasWithItsExercises() {
        let original = [plan("A", exercises: 2), plan("B", exercises: 4), plan("C", exercises: 1)]
        var plans = original
        let removed = plans.take { $0.id == original[1].id }
        XCTAssertEqual(plans.map(\.title), ["A", "C"], "gone at once")
        XCTAssertEqual(removed?.index, 1)

        plans.putBack(removed!)
        XCTAssertEqual(plans, original, "same id, same place, same exercises")
    }

    func testTheFirstAndTheLastComeBackInPlace() {
        let original = [plan("A", exercises: 1), plan("B", exercises: 1), plan("C", exercises: 1)]
        for index in [0, 2] {
            var plans = original
            let removed = plans.take { $0.id == original[index].id }!
            plans.putBack(removed)
            XCTAssertEqual(plans, original)
        }
    }

    func testTakingWhatIsNotThereChangesNothing() {
        let original = [plan("A", exercises: 1)]
        var plans = original
        XCTAssertNil(plans.take { $0.title == "Z" })
        XCTAssertEqual(plans, original)
    }

    /// Another device's copy arriving inside the Undo window must not leave two of them.
    func testPuttingBackReplacesACopyThatArrivedMeanwhile() {
        let original = [plan("A", exercises: 1), plan("B", exercises: 3)]
        var plans = original
        let removed = plans.take { $0.id == original[1].id }!
        var stale = original[1]
        stale.title = "B from the iPad"
        plans.insert(stale, at: 0)

        plans.putBack(removed)
        XCTAssertEqual(plans.filter { $0.id == original[1].id }, [original[1]])
        XCTAssertEqual(plans.count, 2)
    }

    /// The list shrank while the toast was up: the item still comes back, at the end.
    func testPuttingBackIntoAShorterListStaysInBounds() {
        let original = [plan("A", exercises: 1), plan("B", exercises: 1), plan("C", exercises: 1)]
        var plans = original
        let removed = plans.take { $0.id == original[2].id }!
        plans.removeAll()
        plans.putBack(removed)
        XCTAssertEqual(plans, [original[2]])
    }

    // MARK: - Put back: one-off alarms (the list is kept soonest first)

    func testACancelledAlarmComesBackWithItsIdTimeAndPlace() {
        let now = Date()
        let alarms = [600.0, 1200, 1800].map { OneOffAlarm(fire: now.addingTimeInterval($0), label: "in \(Int($0))") }
        let cancelled = alarms[1]
        let after = alarms.filter { $0.id != cancelled.id }
        XCTAssertEqual(after.count, 2)

        let restored = OneOffAlarmList.adding(cancelled, to: after)
        XCTAssertEqual(restored, alarms, "the same alarm (its id is what the phone arms) where it was")
    }

    // MARK: - Deferred: notes, shows, the listening history

    private func show() -> Podcast {
        var podcast = Podcast(feedURL: URL(string: "https://example.com/feed")!, title: "Show")
        podcast.positions = ["e1": 312.5, "e2": 40]
        podcast.completed = ["e0"]
        return podcast
    }

    private func deferRemoval(_ center: ToastCenter, id: String, remove: @escaping () -> Void) async {
        await center.deferRemoval(id: id, message: "Deleted Show", failure: { $0 }) {
            remove()
            return nil
        }
    }

    func testADeletedShowIsHiddenAtOnceAndUndoLeavesItsProgressUntouched() async {
        let center = ToastCenter()
        let original = show()
        var library = [original]
        let id = "podcast|" + original.id.uuidString

        await deferRemoval(center, id: id) { library.removeAll { $0.id == original.id } }
        let visible = PendingRemovals.visible(library, id: { "podcast|" + $0.id.uuidString }, hiding: center.hiddenIDs)
        XCTAssertTrue(visible.isEmpty, "gone from the Library at once")
        XCTAssertEqual(library.count, 1, "nothing removed inside the Undo window")
        XCTAssertEqual(center.toast?.canUndo, true)

        await center.performUndo()
        await center.commitPending()
        XCTAssertEqual(center.hiddenIDs, [])
        XCTAssertEqual(library.first?.id, original.id)
        XCTAssertEqual(library.first?.positions, original.positions)
        XCTAssertEqual(library.first?.completed, original.completed)
    }

    func testWithoutUndoTheShowIsRemovedWhenTheWindowCloses() async {
        let center = ToastCenter()
        let original = show()
        var library = [original]
        await deferRemoval(center, id: "podcast|" + original.id.uuidString) { library.removeAll { $0.id == original.id } }
        await center.commitPending()
        XCTAssertTrue(library.isEmpty)
        XCTAssertEqual(center.hiddenIDs, [])
    }

    /// Two deletes in a row: the second one's toast replaces the first, which is then final.
    func testASecondDeleteCommitsTheFirstAndCanStillBeUndone() async {
        let center = ToastCenter()
        var notes = ["a", "b", "c"]
        await deferRemoval(center, id: "note|a") { notes.removeAll { $0 == "a" } }
        await deferRemoval(center, id: "note|b") { notes.removeAll { $0 == "b" } }
        XCTAssertEqual(notes, ["b", "c"])
        XCTAssertEqual(center.hiddenIDs, ["note|b"])

        await center.performUndo()
        await center.commitPending()
        XCTAssertEqual(notes, ["b", "c"])
        XCTAssertEqual(center.hiddenIDs, [])
    }

    // MARK: - Applied, with the files kept until the window closes ("Not a meal")

    func testUndoPutsBackAndNeverRunsTheDeferredCleanUp() async {
        let center = ToastCenter()
        var backlog = ["meal"]
        var photosDiscarded = false
        backlog.removeAll()
        await center.deferCommit(message: "Deleted meal",
                                 undo: { backlog.append("meal") },
                                 commit: { photosDiscarded = true })
        XCTAssertTrue(center.hasPendingCommit)

        await center.performUndo()
        await center.commitPending()
        XCTAssertEqual(backlog, ["meal"])
        XCTAssertFalse(photosDiscarded, "the photos are still there for the meal that came back")
    }

    func testWithoutUndoTheCleanUpRunsOnce() async {
        let center = ToastCenter()
        var discarded = 0
        await center.deferCommit(message: "Deleted meal", undo: {}, commit: { discarded += 1 })
        await center.commitPending()
        await center.commitPending()
        XCTAssertEqual(discarded, 1)
    }
}
