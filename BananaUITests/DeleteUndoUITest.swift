import XCTest

/// A delete happens at once and the toast offers Undo (docs/design/DESIGN-SYSTEM.md, "Confirming
/// and undoing"; `DeleteUndo`). Driven as a person does it: swipe or press-and-hold, Delete, and
/// the thing is gone with no question first; Undo puts it back where it was; left alone, it
/// stays deleted once the toast has gone.
final class DeleteUndoUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the phone's lists and sheets")
    }

    // MARK: - Launching

    /// The real tabs on sample data (`--ui-preview`), opened on `tab`. `samples` names what to
    /// seed: `--notes`, `--library`, `--listenmap`, `--wake-following-sample` (the routines, set
    /// back to the seed on every launch, so one test's delete is never the next one's start).
    private func launch(tab: String, samples: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", tab] + samples
            + ["--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// The Routines sheet, from the page's "…" menu.
    private func openRoutines() -> XCUIApplication {
        let app = launch(tab: "library", samples: ["--wake-following-sample"])
        let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        more.tap()
        let routines = app.buttons["page.more.routines"]
        XCTAssertTrue(routines.waitForExistence(timeout: 5), app.debugDescription)
        routines.tap()
        XCTAssertTrue(app.navigationBars["Routines"].waitForExistence(timeout: 6), app.debugDescription)
        return app
    }

    // MARK: - Finding

    /// Whatever on screen is called `name`. Never the toast, whose line is "Deleted <name>".
    private func item(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND NOT (label BEGINSWITH 'Deleted') AND NOT (label BEGINSWITH 'Cleared')", name)
        ).firstMatch
    }

    /// Every toast on screen. A sheet has its own host and the page under it keeps its own, so
    /// while a sheet is up there are two; the one to use is the one that can be tapped.
    private func toasts(_ app: XCUIApplication) -> XCUIElementQuery { app.buttons.matching(identifier: "toast.undo") }

    /// The toast's Undo that a finger can reach, once it is up.
    private func reachableUndo(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        guard toasts(app).firstMatch.waitForExistence(timeout: 3) else {
            XCTFail("no Undo in a toast\n\(app.debugDescription)", file: file, line: line)
            return nil
        }
        XCTAssertTrue(waitUntil { self.toasts(app).allElementsBoundByIndex.contains(where: { $0.isHittable }) })
        guard let undo = toasts(app).allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("the toast's Undo is under something\n\(app.debugDescription)", file: file, line: line)
            return nil
        }
        return undo
    }

    private func gone(_ element: XCUIElement, within seconds: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: seconds) == .completed
    }

    private func swipeToDelete(_ app: XCUIApplication, _ row: XCUIElement) {
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 4), "the swipe offers Delete\n\(app.debugDescription)")
        delete.tap()
    }

    private func holdToDelete(_ app: XCUIApplication, _ row: XCUIElement) {
        row.press(forDuration: 1.2)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "press-and-hold offers Delete\n\(app.debugDescription)")
        delete.tap()
    }

    /// The whole promise, for one thing in a list: there, deleted `how`, gone at once with Undo
    /// in the toast and no question, and back where it was — against `neighbour`, which never
    /// moved from the list — once Undo is tapped.
    private func deleteThenUndo(_ app: XCUIApplication, _ name: String, neighbour neighbourName: String,
                                how delete: (XCUIElement) -> Void, file: StaticString = #filePath, line: UInt = #line) {
        let row = item(app, name), neighbour = item(app, neighbourName)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(name) isn't there to delete\n\(app.debugDescription)", file: file, line: line)
        XCTAssertTrue(neighbour.exists, "\(neighbourName) isn't there\n\(app.debugDescription)", file: file, line: line)
        sleep(1)   // a sheet or a pushed page still sliding in reports frames on the way
        let label = row.label, place = row.frame, neighbourPlace = neighbour.frame
        let above = place.minY < neighbourPlace.minY

        delete(row)

        XCTAssertTrue(gone(row, within: 2), "\(name) is still listed after Delete", file: file, line: line)
        guard let undo = reachableUndo(app, file: file, line: line) else { return }
        // Tap while the six-second offer is live; extra remote AX queries can consume it.
        undo.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "a delete asks nothing first", file: file, line: line)
        XCTAssertTrue(neighbour.exists, "\(neighbourName) went with \(name)", file: file, line: line)

        XCTAssertTrue(row.waitForExistence(timeout: 4), "Undo didn't bring \(name) back\n\(app.debugDescription)", file: file, line: line)
        XCTAssertTrue(gone(toasts(app).firstMatch, within: 3), "the toast stays after Undo", file: file, line: line)
        sleep(1)   // the row slides back in
        XCTAssertEqual(row.label, label, "back, but not the same", file: file, line: line)
        XCTAssertEqual(row.frame.minY < neighbour.frame.minY, above,
                       "\(name) came back on the other side of \(neighbourName)", file: file, line: line)
        XCTAssertEqual(row.frame.minY, place.minY, accuracy: 2, "\(name) came back somewhere else", file: file, line: line)
        XCTAssertEqual(neighbour.frame.minY, neighbourPlace.minY, accuracy: 2, "\(neighbourName) isn't where it was", file: file, line: line)
    }

    // MARK: - Routines

    func testARoutineSwipedAwayComesBackWithUndo() {
        let app = openRoutines()
        deleteThenUndo(app, "Commute", neighbour: "Focus") { swipeToDelete(app, $0) }
    }

    func testARoutineDeletedFromItsMenuComesBackWithUndo() {
        let app = openRoutines()
        deleteThenUndo(app, "Focus", neighbour: "Commute") { holdToDelete(app, $0) }
    }

    /// The editor's own Delete closes it, and the toast is on the list it came from.
    func testARoutineDeletedInItsEditorComesBackWithUndo() {
        let app = openRoutines()
        deleteThenUndo(app, "Commute", neighbour: "Focus") { row in
            row.tap()
            XCTAssertTrue(app.navigationBars["Commute"].waitForExistence(timeout: 5), "the editor didn't open\n\(app.debugDescription)")
            let delete = app.buttons["Delete"].firstMatch
            for _ in 0..<6 where !(delete.exists && delete.isHittable) { app.swipeUp() }
            XCTAssertTrue(delete.exists && delete.isHittable, "the editor has no Delete\n\(app.debugDescription)")
            delete.tap()
            XCTAssertTrue(app.navigationBars["Routines"].waitForExistence(timeout: 5), "Delete didn't close the editor")
        }
    }

    // MARK: - Notes

    private let firstNote = "The useful distinction"
    private let secondNote = "Ask the team"

    func testANoteSwipedAwayComesBackWithUndo() {
        let app = launch(tab: "notes", samples: ["--notes"])
        deleteThenUndo(app, firstNote, neighbour: secondNote) { swipeToDelete(app, $0) }
    }

    func testANoteDeletedFromItsMenuComesBackWithUndo() {
        let app = launch(tab: "notes", samples: ["--notes"])
        deleteThenUndo(app, secondNote, neighbour: firstNote) { holdToDelete(app, $0) }
    }

    /// Without Undo the delete stands: the toast goes after its six seconds and the note with it.
    func testANoteDeletedAndLeftAloneStaysDeleted() {
        let app = launch(tab: "notes", samples: ["--notes"])
        let row = item(app, firstNote), neighbour = item(app, secondNote)
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        swipeToDelete(app, row)
        XCTAssertTrue(gone(row, within: 2), "the note is still listed after Delete")
        guard reachableUndo(app) != nil else { return }

        XCTAssertTrue(toasts(app).firstMatch.waitForNonExistence(timeout: 10), "the toast is still up after its window")
        XCTAssertFalse(row.exists, "the note came back when the toast went")
        XCTAssertTrue(neighbour.exists, "the other note went too")
    }

    // MARK: - Podcasts

    func testAShowSwipedAwayComesBackWithUndo() {
        let app = launch(tab: "library", samples: ["--library"])
        deleteThenUndo(app, "Complex Systems", neighbour: "Gamecraft") { swipeToDelete(app, $0) }
    }

    func testAShowDeletedFromItsMenuComesBackWithUndo() {
        let app = launch(tab: "library", samples: ["--library"])
        deleteThenUndo(app, "Gamecraft", neighbour: "Complex Systems") { row in
            row.press(forDuration: 1.2)
            let unsubscribe = app.buttons["Unsubscribe"]
            XCTAssertTrue(unsubscribe.waitForExistence(timeout: 5), "A show's menu offers Unsubscribe")
            unsubscribe.tap()
        }
    }

    /// Left alone, the show is removed for good when the toast goes.
    func testAShowDeletedAndLeftAloneStaysDeleted() {
        let app = launch(tab: "library", samples: ["--library"])
        let row = item(app, "Complex Systems"), neighbour = item(app, "Gamecraft")
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        swipeToDelete(app, row)
        XCTAssertTrue(gone(row, within: 2), "the show is still listed after Delete")
        guard reachableUndo(app) != nil else { return }

        XCTAssertTrue(toasts(app).firstMatch.waitForNonExistence(timeout: 10), "the toast is still up after its window")
        XCTAssertFalse(row.exists, "the show came back when the toast went")
        XCTAssertTrue(neighbour.exists, "the next show went too")
    }

    // MARK: - Listening history

    func testClearedListeningHistoryComesBackWithUndo() {
        let app = launch(tab: "library", samples: ["--listenmap"])
        let chart = app.buttons["page.review"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 20), app.debugDescription)
        chart.tap()
        let listening = app.descendants(matching: .any).matching(identifier: "review.listening").firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 6), app.debugDescription)
        listening.tap()
        let bar = app.navigationBars["Listening"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), app.debugDescription)

        let rows = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*Episode [0-9]+.*"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "no sample history\n\(app.debugDescription)")
        sleep(1)
        let first = rows.firstMatch.label, place = rows.firstMatch.frame

        // The page's own menu: the last button in its bar.
        let menu = bar.buttons.element(boundBy: bar.buttons.count - 1)
        menu.tap()
        let clear = app.buttons["Clear history"]
        XCTAssertTrue(clear.waitForExistence(timeout: 4), app.debugDescription)
        clear.tap()

        XCTAssertTrue(gone(rows.firstMatch, within: 2), "the history is still listed after Clear history")
        XCTAssertTrue(app.staticTexts["Nothing played then"].waitForExistence(timeout: 2), "the page doesn't say it is empty")
        guard let undo = reachableUndo(app) else { return }
        XCTAssertFalse(app.alerts.firstMatch.exists, "clearing asks nothing first")

        undo.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 4), "Undo didn't bring the history back\n\(app.debugDescription)")
        sleep(1)
        XCTAssertEqual(rows.firstMatch.label, first)
        XCTAssertEqual(rows.firstMatch.frame.minY, place.minY, accuracy: 2)
    }

    // MARK: - One-off alarms

    func testAnAlarmDeletedComesBackWithUndo() throws {
        let app = launch(tab: "plan", samples: ["--plan"])
        let add = app.plus("mobile.week.newEvent")
        XCTAssertTrue(add.waitForExistence(timeout: 20), app.debugDescription)
        add.tap()
        let alarm = app.buttons["mobile.week.add.alarm"].firstMatch
        XCTAssertTrue(alarm.waitForExistence(timeout: 4), app.debugDescription)
        alarm.tap()
        XCTAssertTrue(app.navigationBars["Alarms"].waitForExistence(timeout: 5), app.debugDescription)

        let label = app.textFields["Label (optional)"]
        XCTAssertTrue(label.waitForExistence(timeout: 3), app.debugDescription)
        label.tap()
        label.typeText("Pick up keys")
        app.buttons["Set alarm"].firstMatch.tap()

        // A fresh simulator asks first whether Banana may schedule alarms: the system's question.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Allow")).firstMatch
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        // The iOS 27 simulator's AlarmKit refuses without asking, so no alarm can be set there.
        // The list's delete and Undo are in DeleteUndoTests; a phone answers the question.
        let refused = app.alerts.staticTexts["Banana needs alarm permission to wake you up."]
        try XCTSkipIf(refused.exists, "this simulator's AlarmKit grants nothing and shows no prompt")

        // The row's own Delete: there once the alarm is listed under Scheduled.
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "the alarm wasn't set\n\(app.debugDescription)")
        let row = app.staticTexts["Pick up keys"]
        XCTAssertTrue(row.exists, app.debugDescription)
        if app.keyboards.firstMatch.exists { app.navigationBars["Alarms"].tap() }
        sleep(1)
        let place = row.frame

        delete.tap()
        XCTAssertTrue(gone(row, within: 2), "the alarm is still listed after Delete")
        guard let undo = reachableUndo(app) else { return }
        XCTAssertFalse(app.alerts.firstMatch.exists, "a delete asks nothing first")

        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Undo didn't bring the alarm back\n\(app.debugDescription)")
        sleep(1)
        XCTAssertEqual(row.frame.minY, place.minY, accuracy: 2, "the alarm came back somewhere else")

        // Nothing left armed in the simulator.
        delete.tap()
        XCTAssertTrue(gone(row, within: 2))
    }

    // MARK: - Meal backlog

    /// "Not a meal" on a photo that's waiting for its words: out of the backlog, and back.
    func testNotAMealComesBackWithUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--meal-backlog", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        // The waiting photo's own field: there while that meal is in the backlog.
        let asking = app.descendants(matching: .any).matching(identifier: "mealInbox.note").firstMatch
        XCTAssertTrue(asking.waitForExistence(timeout: 20), app.debugDescription)
        // Its menu is the one on its row: the nearest above the field.
        let mine = app.buttons.matching(identifier: "mealInbox.more").allElementsBoundByIndex
            .filter { $0.frame.minY <= asking.frame.minY }
            .max { $0.frame.minY < $1.frame.minY }
        let more = try XCTUnwrap(mine, app.debugDescription)
        sleep(1)
        let place = asking.frame

        more.tap()
        let button = app.buttons["Not a meal"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 4), "no Not a meal in its menu\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(gone(asking, within: 4), "the meal is still in the backlog after Not a meal")
        guard let undo = reachableUndo(app) else { return }
        XCTAssertFalse(app.alerts.firstMatch.exists, "it asks nothing first")

        undo.tap()
        XCTAssertTrue(asking.waitForExistence(timeout: 4), "Undo didn't bring the meal back\n\(app.debugDescription)")
        sleep(1)
        XCTAssertEqual(asking.frame.minY, place.minY, accuracy: 2, "the meal came back somewhere else")
    }
}
