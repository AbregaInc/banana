import XCTest

/// One control for each job, on every main page (docs/design/DESIGN-SYSTEM.md): the chart
/// button at the top left, "…" at the top right, one + at the bottom right where the page can
/// add, the page's switch in the top bar, one date line. Walks the tabs and Review and keeps a
/// picture of each (`TEST_RUNNER_CONTROL_SHOTS` names a folder).
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

    private func launch(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tab", tab, "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES",
                               "-planMode", "day"]
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

    func testEveryTabHasTheSameControlsInTheSamePlaces() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("the phone's bar; the iPad walk is below") }
        // tab, and what the bar's + offers first there: the tab's own
        // tab, its +, and what the + offers first there: the tab's own
        let tabs: [(String, String, String, [String])] = [
            ("plan", "Plan", "mobile.week.newEvent", ["mobile.week.add.event", "mobile.week.newTask", "mobile.week.add.alarm"]),
            ("workouts", "Workouts", "workouts.add", ["mobile.week.add.event"]),
            ("nutrition", "Food", "wellness.add",
             ["wellness.textMeal", "wellness.searchFood", "wellness.barcodeMeal", "wellness.photoMeal", "wellness.manualMeal",
              "add.supplement"]),
            ("notes", "Notes", "notes.add", ["notes.capture", "notes.write"]),
            ("library", "Library", "library.add", ["add.podcast"]),
        ]
        for (tab, name, addID, offers) in tabs {
            let app = launch(tab: tab)
            let chart = app.buttons["page.review"].firstMatch
            XCTAssertTrue(chart.waitForExistence(timeout: 15), "\(name) has no chart button")
            let more = app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
            XCTAssertTrue(more.exists, "\(name) has no \u{2026} menu")
            let screen = app.windows.firstMatch.frame
            // Top left and top right.
            XCTAssertLessThan(chart.frame.midX, screen.width * 0.25, "\(name): the chart button isn't at the left")
            XCTAssertGreaterThan(more.frame.midX, screen.width * 0.75, "\(name): \u{2026} isn't at the right")
            XCTAssertLessThan(chart.frame.midY, screen.height * 0.2, "\(name): the chart button isn't at the top")
            keep(tab)

            // One +, the page's, in the same place on every tab: the top bar's right, beside "…".
            // (It was the tab bar's search slot, which iOS treats as a page: a tap stuttered.)
            let add = app.buttons[addID].firstMatch
            XCTAssertTrue(add.exists, "\(name) has no + button")
            XCTAssertGreaterThan(add.frame.midX, screen.width * 0.6, "\(name): + isn't at the right")
            XCTAssertLessThan(add.frame.midY, screen.height * 0.2, "\(name): + isn't in the top bar")
            XCTAssertFalse(app.tabBars.buttons["Add"].exists, "\(name): the tab bar has a + again")
            add.tap()
            for id in offers {
                XCTAssertTrue(app.buttons[id].firstMatch.waitForExistence(timeout: 4), "\(name): + doesn't offer \(id)")
            }
            keep("\(tab)-add")
            closeMenu(app)
            XCTAssertTrue(waitUntil(timeout: 4) { !app.descendants(matching: .any)["page.add.list"].exists },
                          "\(name): the list didn't close")

            // "…" ends with Settings, on every tab.
            more.tap()
            XCTAssertTrue(app.buttons["page.more.settings"].waitForExistence(timeout: 4), "\(name): \u{2026} has no Settings")
            XCTAssertTrue(app.buttons["page.more.routines"].exists, "\(name): \u{2026} has no Routines")
            keep("\(tab)-more")
            closeMenu(app)
            app.terminate()
        }
    }

    func testThePagesSwitchIsInTheTopBar() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("a wide Nutrition shows both halves") }
        let app = launch(tab: "nutrition")
        let food = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Food'")).firstMatch
        let taken = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Taken'")).firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 15) && taken.exists, "no Food \u{00B7} Taken switch")
        let chart = app.buttons["page.review"].firstMatch
        // Level with the chart button: in the bar, not a row under it.
        XCTAssertEqual(food.frame.midY, chart.frame.midY, accuracy: 12, "Food \u{00B7} Taken isn't in the top bar")
        // The date line is under the bar, with the day on it.
        let day = element(app, "nutrition.day")
        XCTAssertTrue(day.exists, "Nutrition has no date line")
        XCTAssertGreaterThan(day.frame.minY, food.frame.maxY)
        app.buttons["Previous day"].firstMatch.tap()
        XCTAssertTrue(app.buttons["dateLine.home"].waitForExistence(timeout: 4), "no way back to today")
        keep("nutrition-yesterday")
        app.buttons["dateLine.home"].tap()
        taken.tap()
        app.plus("wellness.addSupplement").tap()
        XCTAssertTrue(app.buttons["add.supplement"].waitForExistence(timeout: 4), "the + doesn't offer something to take")
        keep("nutrition-taken")
    }

    func testWorkoutsIsForNowAndReviewHoldsThePast() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("a sidebar lists Review itself") }
        let app = launch(tab: "workouts")
        XCTAssertTrue(app.buttons["page.review"].firstMatch.waitForExistence(timeout: 15))
        // No span switch and no trends on the page for doing.
        for gone in ["Month", "Quarter", "Year"] {
            XCTAssertFalse(app.buttons[gone].exists, "Workouts still has a \(gone) span")
        }
        XCTAssertFalse(element(app, "workouts.allTrends").exists)
        XCTAssertFalse(element(app, "workouts.sleep").exists)

        app.buttons["page.review"].firstMatch.tap()
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
        XCTAssertTrue(app.buttons["page.review"].firstMatch.waitForExistence(timeout: 5), "Done didn't close Review")
    }

    func testTheWidePagesFollowTheSameRules() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("the iPad's pages") }
        for (tab, addID) in [("plan", "mobile.week.newEvent"), ("workouts", nil), ("nutrition", "nutrition.add"),
                             ("notes", "notes.add"), ("library", "library.add"), ("routines", "routines.add")] as [(String, String?)] {
            let app = launch(tab: tab)
            sleep(3)
            if tab != "routines" {
                XCTAssertTrue(app.buttons["page.review"].firstMatch.waitForExistence(timeout: 15), "\(tab) has no chart button")
            }
            if let addID {
                XCTAssertTrue(app.buttons[addID].firstMatch.waitForExistence(timeout: 8), "\(tab) has no + button")
            }
            keep(tab)
            app.terminate()
        }
        let app = launch(tab: "review")
        XCTAssertTrue(element(app, "review.fitness").waitForExistence(timeout: 15), "Review isn't a section on the iPad")
        keep("review")
    }
}
