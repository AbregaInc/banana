import XCTest

/// One control for each job, on every main page (docs/design/DESIGN-SYSTEM.md,
/// docs/design/BOTTOM-BAR-SHELL.md): the page's title menu at the top left, "…" at the top right,
/// the bar at the bottom (the switcher, "Search or ask", which adds when tapped with nothing
/// typed, and the assistant), one date line. Walks the pages and Review and keeps a picture of
/// each (`TEST_RUNNER_CONTROL_SHOTS` names a folder).
final class ControlRulesWalkUITest: XCTestCase {
    private let folder = ProcessInfo.processInfo.environment["CONTROL_SHOTS"].map { URL(fileURLWithPath: $0) }
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "phone" }
    private var step = 0

    override func setUp() { continueAfterFailure = true }

    private func keep(_ name: String) {
        step += 1
        let shot = XCUIScreen.main.screenshot()
        guard let folder else {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(String(format: "%@-%02d-%@.png", device, step, name)))
    }

    private func launch(tab: String, fixedPlanMode: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tab", tab, "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES",
                               "-planMode", "day"]
        if !fixedPlanMode { app.launchArguments.removeLast(2) }
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Closes an open menu without touching the page under it.
    private func closeMenu(_ app: XCUIApplication) {
        // Bare top bar, between the chart button and the switch: a tap outside an open menu
        // only closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.095)).tap()
        usleep(600_000)
    }

    func testEveryPageHasTheSameControlsInTheSamePlaces() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the phone's bar; the iPad walk is below") }
        // page, its title's identifier, and what the field offers first there: the page's own
        let pages: [(String, String, String, [String])] = [
            ("plan", "Plan", "plan.mode", ["mobile.week.add.event", "mobile.week.newTask", "mobile.week.add.alarm"]),
            ("workouts", "Workouts", "body.title", ["mobile.week.add.event"]),
            ("nutrition", "Food", "body.title",
             ["wellness.textMeal", "wellness.searchFood", "wellness.barcodeMeal", "wellness.photoMeal", "wellness.manualMeal",
              "add.supplement"]),
            ("notes", "Notes", "page.title", ["notes.capture", "notes.write"]),
            ("library", "Library", "page.title", ["add.podcast"]),
        ]
        for (tab, name, titleID, offers) in pages {
            let app = launch(tab: tab)
            let title = element(app, titleID)
            XCTAssertTrue(title.waitForExistence(timeout: 15), "\(name) has no title")
            let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
            XCTAssertTrue(more.exists, "\(name) has no \u{2026} menu")
            let screen = app.windows.firstMatch.frame
            // Top left and top right; nothing else up there.
            XCTAssertLessThan(title.frame.minX, screen.width * 0.25, "\(name): the title isn't at the left")
            XCTAssertGreaterThan(more.frame.midX, screen.width * 0.75, "\(name): \u{2026} isn't at the right")
            XCTAssertLessThan(title.frame.midY, screen.height * 0.2, "\(name): the title isn't at the top")
            XCTAssertFalse(app.buttons["page.review"].exists, "\(name): the chart button is back")
            XCTAssertFalse(app.tabBars.firstMatch.exists, "\(name): the tab bar is back")
            keep(tab)

            // The bar, at the bottom: the switcher, the field, the assistant.
            let field = app.textFields["shell.field"]
            XCTAssertTrue(field.exists, "\(name) has no field")
            XCTAssertGreaterThan(field.frame.midY, screen.height * 0.8, "\(name): the field isn't at the bottom")
            XCTAssertLessThan(app.buttons["shell.switcher"].frame.midX, field.frame.minX)
            // Tapped with nothing typed, it offers what can be added, this page's first.
            field.tap()
            for id in offers {
                XCTAssertTrue(app.buttons[id].firstMatch.waitForExistence(timeout: 4), "\(name): the field doesn't offer \(id)")
            }
            keep("\(tab)-add")
            app.buttons["shell.field.clear"].tap()
            XCTAssertTrue(waitUntil(timeout: 4) { !app.descendants(matching: .any)["page.add.list"].exists },
                          "\(name): the list didn't close")

            // "…" has Routines; Settings is the switcher's.
            more.tap()
            XCTAssertTrue(app.buttons["page.more.routines"].waitForExistence(timeout: 4), "\(name): \u{2026} has no Routines")
            XCTAssertFalse(app.buttons["page.more.settings"].exists, "\(name): Settings is the switcher's")
            keep("\(tab)-more")
            closeMenu(app)
            app.terminate()
        }
    }

    func testPlanSwitchUsesTheTitleRow() {
        continueAfterFailure = false
        let app = launch(tab: "plan", fixedPlanMode: false)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        // Day and Week under the title ("Today ⌄"; an iPad upright has the phone's layout).
        let title = element(app, "plan.mode")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
        XCTAssertEqual(title.frame.midY, more.frame.midY, accuracy: 12, "the title isn't in the top row")
        XCTAssertFalse(app.segmentedControls.buttons["Day"].exists, "the segmented switch is gone")
        title.tap()
        app.buttons["Week"].firstMatch.tap()
        XCTAssertTrue(element(app, "plan.surface.week").waitForExistence(timeout: 8))
        element(app, "plan.mode").tap()
        app.buttons["Day"].firstMatch.tap()
        XCTAssertTrue(element(app, "plan.surface.day").waitForExistence(timeout: 8))
        keep("plan-title-row")
        if pad {
            // On its side: the rail, and Day or Week as the toolbar's "Week ⌄".
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(element(app, "plan.mode").waitForExistence(timeout: 8))
            XCTAssertTrue(element(app, "shell.rail").exists, "on its side the rail")
            keep("plan-landscape-toolbar")
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testThePagesSwitchIsInTheTopBar() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("a wide Nutrition shows both halves") }
        let app = launch(tab: "nutrition")
        let title = element(app, "body.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15), "no Body title")
        XCTAssertTrue(title.label.hasPrefix("Food"), title.label)
        // The date line is under the bar, with the day on it.
        let day = element(app, "nutrition.day")
        XCTAssertTrue(day.exists, "Nutrition has no date line")
        XCTAssertGreaterThan(day.frame.minY, title.frame.maxY)
        app.buttons["Previous day"].firstMatch.tap()
        XCTAssertTrue(app.buttons["dateLine.home"].waitForExistence(timeout: 4), "no way back to today")
        keep("nutrition-yesterday")
        app.buttons["dateLine.home"].tap()
        title.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Taken'")).firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { title.label.hasPrefix("Taken") }, title.label)
        app.plus("wellness.addSupplement").tap()
        XCTAssertTrue(app.buttons["add.supplement"].waitForExistence(timeout: 4), "the field doesn't offer something to take")
        keep("nutrition-taken")
    }

    func testWorkoutsIsForNowAndReviewHoldsThePast() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the rail lists Review itself") }
        let app = launch(tab: "workouts")
        XCTAssertTrue(app.buttons["shell.switcher"].firstMatch.waitForExistence(timeout: 15))
        // No span switch and no trends on the page for doing.
        for gone in ["Month", "Quarter", "Year"] {
            XCTAssertFalse(app.buttons[gone].exists, "Workouts still has a \(gone) span")
        }
        XCTAssertFalse(element(app, "workouts.allTrends").exists)
        XCTAssertFalse(element(app, "workouts.sleep").exists)

        app.buttons["shell.switcher"].tap()
        app.buttons["shell.page.review"].tap()
        let fitness = element(app, "review.fitness")
        XCTAssertTrue(fitness.waitForExistence(timeout: 6), "Review didn't open")
        // Opened from Workouts, Fitness leads; every part is there.
        for part in ["sleep", "food", "listening"] {
            let row = element(app, "review.\(part)")
            XCTAssertTrue(row.exists, "Review has no \(part)")
            XCTAssertLessThan(fitness.frame.minY, row.frame.minY, "Fitness isn't first when opened from Workouts")
        }
        // The app's one span switch, in Review's top bar.
        for span in ["Week", "Month", "Year"] {
            XCTAssertTrue(app.buttons[span].firstMatch.exists, "Review has no \(span)")
        }
        keep("review-week")
        app.buttons["Month"].firstMatch.tap()
        keep("review-month")
        app.buttons["Previous month"].firstMatch.tap()
        XCTAssertTrue(app.buttons["dateLine.home"].waitForExistence(timeout: 4), "no way back to now")
        keep("review-last-month")
        app.buttons["dateLine.home"].tap()

        fitness.tap()
        XCTAssertTrue(app.navigationBars["Fitness"].waitForExistence(timeout: 5))
        keep("review-fitness")
        app.navigationBars.buttons.firstMatch.tap()
        // Not Sleep: opening it asks Apple Health for access, and the system's sheet stops the walk.
        for (part, title) in [("food", "Food"), ("listening", "Listening")] {
            element(app, "review.\(part)").tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(title) didn't open")
            keep("review-\(part)")
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["shell.switcher"].firstMatch.waitForExistence(timeout: 5), "Done didn't close Review")
    }

    func testTheWidePagesFollowTheSameRules() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("the iPad's pages") }
        // The rail and one toolbar are an iPad's on its side; upright it has the phone's bar.
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for tab in ["plan", "workouts", "nutrition", "notes", "library", "routines"] {
            let app = launch(tab: tab)
            XCTAssertTrue(element(app, "shell.rail").waitForExistence(timeout: 15), "\(tab) has no rail")
            if tab != "routines" {
                XCTAssertTrue(app.textFields["shell.field"].waitForExistence(timeout: 10), "\(tab) has no field in its toolbar")
                XCTAssertFalse(app.buttons["page.review"].exists, "\(tab): the chart button is back")
            }
            for plus in ["mobile.week.newEvent", "nutrition.add", "notes.add", "library.add"] {
                XCTAssertFalse(app.buttons[plus].exists, "\(tab): a + is back in the toolbar")
            }
            keep(tab)
            app.terminate()
        }
        let app = launch(tab: "review")
        XCTAssertTrue(element(app, "review.fitness").waitForExistence(timeout: 15), "Review isn't a page on the iPad")
        XCTAssertTrue(app.buttons["shell.page.review"].isSelected)
        keep("review")
    }
}
