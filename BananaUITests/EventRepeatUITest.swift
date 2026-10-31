import XCTest

/// Repeat on several days of the week, driven for real: the toggles sit inside a Form row, where
/// a tap can land on the row instead of the day, and only a real tap shows which.
final class EventRepeatUITest: XCTestCase {

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// Kept in the test results, for looking at the screen afterwards.
    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        if identifier.contains(".repeatDay.") || identifier.hasSuffix(".recurrence") { return app.buttons.matching(identifier: identifier).firstMatch }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scroll until it's on screen: a Form is lazy, and Repeat is below the fold.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Exactly these days on, tapping on before off — the last day on can't be turned off.
    private func choose(_ wanted: Set<String>, prefix: String, in app: XCUIApplication) {
        let all = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
        for code in all where wanted.contains(code) {
            let day = element(app, "\(prefix).repeatDay.\(code)")
            if !day.isSelected { day.tap() }
        }
        for code in all where !wanted.contains(code) {
            let day = element(app, "\(prefix).repeatDay.\(code)")
            if day.isSelected { day.tap() }
        }
    }

    /// Its label and value together: the Repeat row says the rule as its value.
    private func waitForLabel(_ element: XCUIElement, containing parts: [String], excluding: [String] = []) {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let label = element.label + " " + ((element.value as? String) ?? "")
            return parts.allSatisfy(label.contains) && !excluding.contains(where: label.contains)
        }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 4)
    }

    func testANewEventCanRepeatOnMondayWednesdayAndFriday() {
        let app = launch(["--new-calendar-event"])
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 8))

        // A freshly erased simulator can present the keyboard’s first-use tutorial.
        let keyboardTutorial = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Speed up your typing")).firstMatch
        if keyboardTutorial.exists { app.buttons["Continue"].tap() }

        let repeatPicker = element(app, "event.recurrence")
        reveal(repeatPicker, in: app)
        repeatPicker.tap()
        let weekly = app.buttons.matching(NSPredicate(format: "label == %@", "Weekly")).firstMatch
        XCTAssertTrue(weekly.waitForExistence(timeout: 3), app.debugDescription)
        weekly.tap()

        let monday = element(app, "event.repeatDay.MO")
        reveal(monday, in: app)
        XCTAssertTrue(monday.waitForExistence(timeout: 3), "a weekly repeat shows a toggle per day")
        choose(["MO", "WE", "FR"], prefix: "event", in: app)

        // The Repeat row says Weekly; the day chips say which days. No second line repeating it.
        reveal(repeatPicker, in: app)
        waitForLabel(repeatPicker, containing: ["Weekly"])
        XCTAssertFalse(element(app, "event.repeatSummary").exists)
        keep(app, "New event - weekly on Mon Wed Fri")
        XCTAssertTrue(element(app, "event.repeatDay.WE").isSelected)
        XCTAssertFalse(element(app, "event.repeatDay.TU").isSelected)
    }

    func testAnEventsRepeatShowsAndChangesInTheEditor() {
        let app = launch(["--event-editor"])
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))

        keep(app, "Editor - top")
        let summary = element(app, "eventEditor.recurrence")
        reveal(summary, in: app)
        waitForLabel(summary, containing: ["Weekly"])
        XCTAssertTrue(element(app, "eventEditor.repeatDay.FR").isSelected)
        keep(app, "Editor - repeat")

        choose(["MO", "WE"], prefix: "eventEditor", in: app)
        waitForLabel(summary, containing: ["Weekly"])
        XCTAssertFalse(element(app, "eventEditor.repeatDay.FR").isSelected)
        XCTAssertTrue(app.buttons["eventEditor.save"].isEnabled)

        // Mon–Fri is Weekdays.
        choose(["MO", "TU", "WE", "TH", "FR"], prefix: "eventEditor", in: app)
        waitForLabel(summary, containing: ["Weekdays"])
    }

    func testSomeoneElsesInvitationOffersOnlyYourOwnSettings() {
        let app = launch(["--event-editor", "--event-editor-invite"])
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Sam Rivera"))
            .firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3), app.debugDescription)
        keep(app, "Editor - invitation")
        XCTAssertFalse(element(app, "eventEditor.recurrence").exists, "the repeat is the organizer's")
        XCTAssertFalse(app.buttons["Delete event"].exists)
    }
}
