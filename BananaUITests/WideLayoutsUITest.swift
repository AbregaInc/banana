import XCTest

/// Notes, Library, Routines and Settings on a screen with room: the list beside what it opens,
/// a grid, a readable column. (Each was the phone's list stretched across an iPad.) iPad only.
final class WideLayoutsUITest: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the wide arrangements need an iPad's width")
        continueAfterFailure = false
    }

    private func launch(tab: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--ui-audit", "--dummy-health", "--disable-icloud", "--no-space-sync", "--tab", tab,
                               "-onboardingCompleted", "YES"] + extra
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

    func testSettingsShowsItsPagesBesideItsList() {
        let app = launch(tab: "settings")
        // The list and a page at once: on the phone a page is pushed over the list.
        XCTAssertTrue(app.staticTexts["Wake & bedtime"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connect Google Calendar"].firstMatch.exists)
        app.staticTexts["Podcasts"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Podcast transcripts"].waitForExistence(timeout: 5)
                      || app.staticTexts["PODCAST TRANSCRIPTS"].exists, "the page opens on the right")
        XCTAssertTrue(app.staticTexts["Wake & bedtime"].exists, "and the list is still there")
        keep(app, "settings two panes")
    }

    func testNotesShowsTheListBesideTheNote() {
        let app = launch(tab: "notes")
        XCTAssertTrue(app.staticTexts["No note open"].waitForExistence(timeout: 10))
        // The list's one + sits in its own column, beside the note and not over it. (A capture
        // card and a "write instead" row were here: four ways in to two things.)
        let add = app.buttons["notes.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Notes has no + button")
        XCTAssertFalse(app.staticTexts["Capture a thought"].exists)
        XCTAssertLessThan(add.frame.maxX, app.staticTexts["No note open"].frame.minX, "the list is beside the note, not over it")
    }

    func testTheLibraryIsAGridOfShows() {
        let app = launch(tab: "library", ["--routine-start-sample"])   // brings the sample shows in
        let card = app.descendants(matching: .any).matching(identifier: "library.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        let cards = app.descendants(matching: .any).matching(identifier: "library.card")
        XCTAssertGreaterThan(cards.count, 2)
        // Side by side, not one under the other.
        XCTAssertEqual(cards.element(boundBy: 0).frame.minY, cards.element(boundBy: 1).frame.minY, accuracy: 2)
        XCTAssertLessThan(cards.element(boundBy: 0).frame.maxX, cards.element(boundBy: 1).frame.minX)
    }

    func testRoutinesIsAColumnInTheMiddle() {
        let app = launch(tab: "routines")
        let row = app.staticTexts["Wake & bedtime"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let screen = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(row.frame.minX, screen * 0.1, "not hard against the left edge of an iPad")
    }
}
