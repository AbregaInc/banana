import XCTest

/// Guests on an event that already exists: add one, take one off, in the editor every device
/// shares. On a sample event (`--event-editor`); nothing is saved, so no calendar is touched.
final class EventGuestsUITest: XCTestCase {

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // `--guest-fixtures`: people to match without calendars or contacts, so typing in the
        // guest field never raises the Contacts permission sheet over the test.
        app.launchArguments = arguments + ["--guest-fixtures", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scroll until it's on screen: a Form is lazy, and Guests is below the fold.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    func testAGuestCanBeAddedToAnEventThatHasNone() {
        let app = launch(["--event-editor"])
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))
        XCTAssertEqual(element(app, "eventEditor.save").label, "Save")

        let field = element(app, "eventEditor.guestField")
        reveal(field, in: app)
        XCTAssertTrue(field.exists, "an event with no guests still has somewhere to add one")
        field.tap()
        field.typeText("alex@example.com\n")

        XCTAssertTrue(element(app, "eventEditor.guest.added").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["alex@example.com"].exists)
        XCTAssertEqual(element(app, "eventEditor.save").label, "Save & Invite", "Save says an invitation goes out")
        keep(app, "guest added")
    }

    func testAGuestCanBePickedByName() {
        let app = launch(["--event-editor"])
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))
        let field = element(app, "eventEditor.guestField")
        reveal(field, in: app)
        field.tap()
        field.typeText("Sam")
        let suggestion = element(app, "eventEditor.guest.suggestion")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 4), "the people you meet are offered by name")
        suggestion.tap()
        XCTAssertTrue(element(app, "eventEditor.guest.added").waitForExistence(timeout: 4))
        XCTAssertEqual(element(app, "eventEditor.save").label, "Save & Invite")
    }

    func testANameThatIsNotAnAddressInvitesNobody() {
        let app = launch(["--event-editor"])
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))
        let field = element(app, "eventEditor.guestField")
        reveal(field, in: app)
        field.tap()
        field.typeText("zzyzx\n")
        XCTAssertFalse(element(app, "eventEditor.guest.added").waitForExistence(timeout: 2))
        XCTAssertEqual(element(app, "eventEditor.save").label, "Save")
    }

    func testAGuestCanBeTakenOffAndPutBack() {
        let app = launch(["--event-editor", "--event-editor-guests"])
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))

        let field = element(app, "eventEditor.guestField")
        reveal(field, in: app)
        // Two guests can go; the organizer (you) has no remove button.
        let removes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '"))
        XCTAssertEqual(removes.count, 2)
        XCTAssertTrue(app.staticTexts["Organizer"].exists)

        app.buttons["Remove Sam Rivera"].tap()
        XCTAssertTrue(app.staticTexts["Taken off when you save"].waitForExistence(timeout: 3))
        keep(app, "guest taken off")

        app.buttons["Keep Sam Rivera"].tap()
        XCTAssertFalse(app.staticTexts["Taken off when you save"].exists)
    }

    func testSomeoneElsesInvitationShowsItsGuestsWithoutControls() {
        let app = launch(["--event-editor", "--event-editor-invite"])
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 8))
        let guest = element(app, "eventEditor.guest")
        reveal(guest, in: app)
        XCTAssertTrue(guest.exists)
        XCTAssertFalse(element(app, "eventEditor.guestField").exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).count, 0)
    }
}
