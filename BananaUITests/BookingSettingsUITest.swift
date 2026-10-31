import XCTest

/// Settings › Booking and the Plan's share button (docs/design/BOOKING.md §12), on sample types and a
/// stand-in service (`--booking-preview`): nothing here reaches the Banana service or a real account.
/// Keeps a picture of each screen (`TEST_RUNNER_BOOKING_SHOTS` names a folder).
final class BookingSettingsUITest: XCTestCase {
    private let folder = ProcessInfo.processInfo.environment["BOOKING_SHOTS"].map { URL(fileURLWithPath: $0) }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "phone" }

    override func setUp() { continueAfterFailure = false }

    private func keep(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        guard let folder else {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent("\(device)-\(name).png"))
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--booking-preview", "--disable-icloud", "-onboardingCompleted", "YES"] + extra
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// No handle yet: the suggestion is in the field, and "Use" takes it (one tap). Copy and Share follow.
    func testTheSuggestedLinkIsOneTap() throws {
        let app = launch()
        let field = app.textFields["booking.handle"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertEqual(field.value as? String, "noor", "the service's first suggestion")
        XCTAssertTrue(element(app, "booking.type.meeting").exists)
        XCTAssertTrue(element(app, "booking.type.intro-call").exists)
        keep("booking-suggested")

        element(app, "booking.use").tap()
        XCTAssertTrue(element(app, "booking.copy").waitForExistence(timeout: 5), "taken at once, Copy and Share show")
        XCTAssertTrue(element(app, "booking.shareLink").exists)
        XCTAssertFalse(element(app, "booking.use").exists)
        keep("booking-linked")
    }

    /// A handle someone else has: said under the field, in one word.
    func testATakenHandleIsSaidUnderTheField() throws {
        let app = launch()
        let field = app.textFields["booking.handle"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + "sam")
        element(app, "booking.use").tap()
        let problem = app.staticTexts["Taken"]
        let said = problem.waitForExistence(timeout: 5)
        keep("booking-taken")
        XCTAssertTrue(said)
    }

    /// A type's switch turns it off in its row; a tap on its name opens the editor.
    func testATypeTurnsOffInItsRowAndOpensOnTap() throws {
        let app = launch(["--booking-linked"])
        let coffee = app.switches["booking.type.coffee.active"]
        XCTAssertTrue(coffee.waitForExistence(timeout: 20))
        XCTAssertEqual(coffee.value as? String, "0", "the sample's coffee is off")
        coffee.tap()
        XCTAssertTrue(waitUntil { coffee.value as? String == "1" })

        element(app, "booking.type.intro-call").tap()
        let title = app.textFields["booking.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Intro call")
        keep("editor")

        app.staticTexts["Hours"].firstMatch.tap()
        let monday = app.switches[Calendar.current.weekdaySymbols[1]]
        let opened = monday.waitForExistence(timeout: 5)
        keep("editor-hours")
        XCTAssertTrue(opened, "Monday's hours")

        app.swipeUp()
        XCTAssertTrue(element(app, "booking.editor.place.zoom").waitForExistence(timeout: 5))
        keep("editor-places")

        let more = element(app, "booking.editor.more")
        for _ in 0..<3 where !more.isHittable { app.swipeUp() }
        more.tap()
        app.swipeUp()
        keep("editor-more")
    }

    /// The Plan's top bar: one tap on Share opens the share sheet with the link (then the person, then
    /// Send: three taps).
    func testThePlansShareButtonOpensTheShareSheetInOneTap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--booking-preview", "--booking-linked", "--tab", "plan", "--disable-icloud",
                               "-onboardingCompleted", "YES", "-planMode", "day"]
        app.withoutSpaceSync()
        app.launch()
        let share = element(app, "booking.share")
        XCTAssertTrue(share.waitForExistence(timeout: 30))
        keep("plan-share-button")
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        let shown = waitUntil(timeout: 10) {
            sheet.exists || app.navigationBars["UIActivityContentView"].exists || app.buttons["Copy"].exists
                || app.cells["Copy"].exists || app.staticTexts["Book a time"].exists || app.popovers.firstMatch.exists
        }
        // Settled: its actions are there.
        waitUntil(timeout: 5) { app.cells["Copy"].exists || app.buttons["Copy"].exists || app.staticTexts["Copy"].exists }
        keep("plan-share-sheet")
        XCTAssertTrue(shown, "the system's share sheet")
    }

    /// The largest text sizes: the site above the field, Copy over Share, the lengths as a menu,
    /// From over To. Pictures to check by eye.
    func testTheLargestTextSizesStillFit() throws {
        let app = launch(["--booking-linked", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(app.textFields["booking.handle"].waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "booking.copy").exists)
        keep("ax-booking")
        element(app, "booking.type.intro-call").tap()
        XCTAssertTrue(app.textFields["booking.editor.title"].waitForExistence(timeout: 5))
        keep("ax-editor")
        app.staticTexts["Hours"].firstMatch.tap()
        XCTAssertTrue(app.switches[Calendar.current.weekdaySymbols[1]].waitForExistence(timeout: 5))
        app.swipeUp()
        keep("ax-editor-hours")
    }

    /// No Banana account (this build has no service): the Plan's bar has no booking button and no
    /// empty place where it would be.
    func testWithoutAnAccountThePlanHasNoShareButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "plan", "--disable-icloud", "-onboardingCompleted", "YES", "-planMode", "day"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(element(app, "mobile.week.more").waitForExistence(timeout: 30))
        XCTAssertFalse(element(app, "booking.share").exists)
        keep("plan-no-account")
    }
}
