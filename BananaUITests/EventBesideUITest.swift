import XCTest

/// On an iPad on its side an event opens in a panel beside the calendar, as the Mac's drawer
/// does, and the day stays in view; upright it opens as a sheet over the calendar.
/// (`LayoutClass.opensBeside`; `--open-event` opens a sample invitation as a tap would.)
final class EventBesideUITest: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's width")
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait   // later tests expect the iPad upright
    }

    private func open(_ orientation: UIDeviceOrientation) -> (XCUIApplication, XCUIElement) {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "plan", "--plan", "-planMode", "day", "--open-event",
                               "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES", "-finishSetupDismissed", "YES"]
        app.withoutSpaceSync()
        app.launch()
        let title = app.staticTexts["Design review with Sam"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the event didn't open\n\(app.debugDescription)")
        return (app, title)
    }

    func testOnItsSideTheEventOpensBesideTheDay() {
        let (app, title) = open(.landscapeLeft)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(title.frame.minX, window.width * 0.6, "the event isn't in a panel on the right")
        XCTAssertTrue(app.buttons["Day"].firstMatch.isHittable, "the day isn't still there beside it")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "event beside the day"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["Done"].firstMatch.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "Done didn't close the panel")
    }

    func testUprightTheEventOpensAsASheet() {
        let (app, title) = open(.portrait)
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(title.frame.minX, window.width * 0.5, "upright, the event should be a sheet, not a side panel")
    }
}
