import XCTest

/// Deferred removal and applied-change undo, through the calendar's two uses and the generic
/// calls every other feature will use. The property that matters most: nothing is removed until
/// the undo window closes, and undo means nothing is ever sent.
@MainActor
final class ToastCenterTests: XCTestCase {
    private var deletes: [String] = []

    func testScopedDismissCannotCloseANewerToast() throws {
        let center = ToastCenter()
        center.present("Mail action")
        let old = try XCTUnwrap(center.toast?.id)
        center.present("Another action")
        let current = try XCTUnwrap(center.toast?.id)
        center.dismiss(ifMatching: old)
        XCTAssertEqual(center.toast?.id, current)
        center.dismiss(ifMatching: current)
        XCTAssertNil(center.toast)
    }

    private func deferDelete(_ center: ToastCenter, _ id: String,
                             span: CalendarEditSpan = .thisEvent, failure: String? = nil) async {
        await center.deferDelete(eventID: id, title: "Event \(id)", span: span) { [weak self] in
            self?.deletes.append(id)
            return failure
        }
    }

    func testDeleteHidesAtOnceButWaitsToSend() async {
        let center = ToastCenter()
        await deferDelete(center, "a")
        XCTAssertEqual(center.hiddenIDs, ["a"])
        XCTAssertEqual(deletes, [], "nothing sent inside the undo window")
        XCTAssertEqual(center.toast?.canUndo, true)

        await center.commitPending()
        XCTAssertEqual(deletes, ["a"])
        XCTAssertEqual(center.hiddenIDs, [])
        XCTAssertNil(center.toast)
    }

    func testUndoShowsTheEventAgainAndSendsNothing() async {
        let center = ToastCenter()
        await deferDelete(center, "a")
        await center.performUndo()
        XCTAssertEqual(center.hiddenIDs, [])
        await center.commitPending()
        XCTAssertEqual(deletes, [], "an undone delete is never sent")
    }

    func testTheNextEditCommitsThePreviousDelete() async {
        let center = ToastCenter()
        await deferDelete(center, "a")
        await deferDelete(center, "b")
        XCTAssertEqual(deletes, ["a"])
        XCTAssertEqual(center.hiddenIDs, ["b"])
        await center.performUndo()
        await center.commitPending()
        XCTAssertEqual(deletes, ["a"], "undo only reaches the latest edit")
    }

    func testAFailedDeleteBringsTheEventBackAndSaysSo() async {
        let center = ToastCenter()
        await deferDelete(center, "a", failure: "Forbidden")
        await center.commitPending()
        XCTAssertEqual(center.hiddenIDs, [])
        XCTAssertEqual(center.toast?.canUndo, false)
        XCTAssertTrue(center.toast?.message.contains("Forbidden") == true)
    }

    func testMoveUndoMovesBack() async {
        let center = ToastCenter()
        var movedBack = 0
        await center.offerMoveUndo(title: "Sync", to: Date(), span: .thisEvent) {
            movedBack += 1
            return nil
        }
        XCTAssertEqual(center.toast?.canUndo, true)
        await center.performUndo()
        XCTAssertEqual(movedBack, 1)
        XCTAssertNil(center.toast)
    }

    func testASeriesMoveOffersNoUndo() async {
        let center = ToastCenter()
        await center.offerMoveUndo(title: "Sync", to: Date(), span: .futureEvents) { nil }
        XCTAssertEqual(center.toast?.canUndo, false)
    }

    // MARK: Generic — what Notes, Nutrition and Library will call

    func testAGenericRemovalHidesItsIDAndCommitsOnce() async {
        let center = ToastCenter()
        var commits = 0
        await center.deferRemoval(id: "note-1", message: "Deleted note",
                                  failure: { "Couldn't delete: \($0)" }) {
            commits += 1
            return nil
        }
        XCTAssertEqual(center.hiddenIDs, ["note-1"])
        XCTAssertEqual(center.toast?.message, "Deleted note")
        await center.commitPending()
        await center.commitPending()
        XCTAssertEqual(commits, 1, "a removal is sent exactly once")
        XCTAssertEqual(center.hiddenIDs, [])
    }

    func testAnAppliedChangeWithoutUndoIsJustANotice() async {
        let center = ToastCenter()
        await center.offerUndo("Marked as played", undo: nil)
        XCTAssertEqual(center.toast?.canUndo, false)
        await center.performUndo()
        XCTAssertEqual(center.toast?.message, "Marked as played", "nothing to undo leaves the notice up")
    }

    func testANewToastCommitsTheRemovalBeforeIt() async {
        let center = ToastCenter()
        var committed = false
        await center.deferRemoval(id: "meal", message: "Deleted lunch", failure: { $0 }) {
            committed = true
            return nil
        }
        await center.offerUndo("Logged coffee") { nil }
        XCTAssertTrue(committed, "undo only ever reaches the latest change")
        XCTAssertEqual(center.hiddenIDs, [])
    }

    // MARK: Review fixes

    /// Letting the window run out must commit in a task that isn't cancelled — a Google delete
    /// checks for cancellation and failed every time.
    func testTheWindowRunningOutCommitsUncancelled() async throws {
        let saved = ToastCenter.window
        ToastCenter.window = .milliseconds(30)
        defer { ToastCenter.window = saved }
        let center = ToastCenter()
        var wasCancelled: Bool?
        await center.deferRemoval(id: "e", message: "Deleted", failure: { $0 }) {
            wasCancelled = Task.isCancelled
            return nil
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(wasCancelled, false)
        XCTAssertEqual(center.hiddenIDs, [])
    }

    /// A removal that arrives while the previous one's commit is still awaiting the network
    /// keeps its own commit.
    func testOverlappingRemovalsEachCommit() async {
        let center = ToastCenter()
        var committed: [String] = []
        await center.deferRemoval(id: "a", message: "A", failure: { $0 }) {
            try? await Task.sleep(for: .milliseconds(50))
            committed.append("a")
            return nil
        }
        async let second: Void = center.deferRemoval(id: "b", message: "B", failure: { $0 }) {
            committed.append("b"); return nil
        }
        async let third: Void = center.deferRemoval(id: "c", message: "C", failure: { $0 }) {
            committed.append("c"); return nil
        }
        _ = await (second, third)
        await center.commitPending()
        XCTAssertEqual(Set(committed), ["a", "b", "c"])
        XCTAssertEqual(center.hiddenIDs, [])
    }

    // MARK: A change held for Undo

    func testAHeldChangeIsWrittenWhenTheWindowCloses() async {
        let center = ToastCenter()
        var written = false, undone = false
        await center.deferCommit(message: "Completed", undo: { undone = true }, commit: { written = true })
        XCTAssertTrue(center.hasPendingCommit)
        XCTAssertFalse(written, "nothing is written while it can still be undone")
        await center.commitPending()
        XCTAssertTrue(written)
        XCTAssertFalse(undone)
        XCTAssertNil(center.toast)
    }

    func testUndoingAHeldChangeWritesNothing() async {
        let center = ToastCenter()
        var written = false, undone = false
        await center.deferCommit(message: "Completed", undo: { undone = true }, commit: { written = true })
        await center.performUndo()
        XCTAssertTrue(undone)
        await center.commitPending()
        XCTAssertFalse(written, "an undone tick never reaches Reminders")
        XCTAssertFalse(center.hasPendingCommit)
    }

    func testTheNextChangeWritesTheOneBeforeIt() async {
        let center = ToastCenter()
        var written: [String] = []
        await center.deferCommit(message: "A", undo: {}, commit: { written.append("a") })
        await center.deferCommit(message: "B", undo: {}, commit: { written.append("b") })
        XCTAssertEqual(written, ["a"], "the first is settled once the second takes the toast")
        await center.performUndo()
        await center.commitPending()
        XCTAssertEqual(written, ["a"], "and the second was undone")
    }
}
