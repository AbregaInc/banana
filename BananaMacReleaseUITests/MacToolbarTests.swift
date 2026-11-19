import XCTest
import AppKit
import Darwin

/// Visible shell checks in an idle test VM, separate from the exact-release startup gate.
final class MacToolbarTests: XCTestCase {
    private var app: XCUIApplication!
    private var candidate: URL!
    private var candidateInfo: Data!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let home = getpwuid(getuid())?.pointee.pw_dir,
              FileManager.default.fileExists(atPath: String(cString: home) + "/.config/banana/mac-release-test-account"),
              let path = ProcessInfo.processInfo.environment["BANANA_TOOLBAR_APP"],
              let identifier = Bundle(path: path)?.bundleIdentifier,
              !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == identifier }) else {
            throw NSError(domain: "MacToolbarTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use an idle dedicated test account and an explicit fixture app; never the owner's desktop."])
        }
        candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        candidateInfo = try Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))
        app = XCUIApplication(url: candidate)
        app.launchArguments = ["--ui-audit", "--disable-icloud", "--mac-section", "plan"]
        if name.contains("Scheduling") {
            app.launchArguments = ["--ui-audit", "--disable-icloud", "--mac-section", "plan", "--mail", "--mail-fresh",
                                   "--booking-fixture", "--booking-linked", "--modules", "everything",
                                   "-onboardingCompleted", "YES"]
        }
        if name.contains("FieldPrompt") { app.launchArguments += ["--mac-new-event"] }
        if name.contains("BodyMenu") { app.launchArguments += ["--modules", "everything", "-onboardingCompleted", "YES"] }
        app.launch()
        if name.contains("FieldPrompt") {
            // A newly signed fixture can raise Local Network privacy before its window opens.
            // This editor check needs no discovery access; dismiss only that system prompt.
            for bundle in ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent"] {
                let system = XCUIApplication(bundleIdentifier: bundle)
                let deny = system.buttons.matching(NSPredicate(format: "title == %@ OR title == %@", "Don’t Allow", "Don't Allow")).firstMatch
                if deny.waitForExistence(timeout: 5) && deny.isHittable { deny.click() }
            }
            app.activate()
        }
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "mac-toolbar-final"
            image.lifetime = .keepAlways
            add(image)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "mac-toolbar-accessibility"
            tree.lifetime = .keepAlways
            add(tree)
            app.terminate()
        }
        if let candidate, let candidateInfo {
            XCTAssertEqual(try Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")), candidateInfo,
                           "The fixture candidate must not be replaced by an automatic update")
        }
    }

    private func wait(_ description: String, _ predicate: @escaping () -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, description)
    }

    private var period: XCUIElement { app.descendants(matching: .any)["mac.planner.view"].firstMatch }
    private var toggle: XCUIElement { app.buttons["shell.railToggle"] }

    func testBodyMenuSwitchesBetweenWorkoutsAndFood() {
        let body = app.buttons["shell.page.body"]
        wait("Body is visible in the rail") { body.isHittable }
        body.click()

        let menu = app.descendants(matching: .any)["body.title"].firstMatch
        let workouts = app.descendants(matching: .any)["workouts.period"].firstMatch
        let food = app.textFields["nutrition.phrase"].firstMatch
        wait("Workouts and its page menu are visible") { workouts.exists && menu.isHittable }
        menu.click()
        app.menuItems["Food"].firstMatch.click()
        wait("Picking Food opens the nutrition page") { food.isHittable && menu.label.contains("Food") }
        menu.click()
        app.menuItems["Workouts"].firstMatch.click()
        wait("Picking Workouts returns to its calendar period") { workouts.exists && menu.label.contains("Workouts") }
    }

    private func checkPlacement(_ name: String) {
        let previous = app.buttons["plan.previous"], next = app.buttons["plan.next"]
        wait("All navigation controls remain reachable") { self.toggle.isHittable && previous.isHittable && next.isHittable && self.period.isHittable }
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(toggle.frame.maxX, window.midX, "Sidebar control belongs on the left")
        XCTAssertGreaterThan(previous.frame.midX, window.midX, "Calendar navigation belongs on the right")
        XCTAssertGreaterThan(next.frame.minX, previous.frame.midX, "Next follows Previous")
        XCTAssertGreaterThanOrEqual(previous.frame.width, 28)
        XCTAssertGreaterThanOrEqual(next.frame.width, 28)
        XCTAssertLessThanOrEqual(period.frame.maxX, previous.frame.minX + 2, "Range and paging form one ordered group")
        XCTAssertLessThanOrEqual(next.frame.maxX, window.maxX, "Next is not clipped into overflow")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "mac-toolbar-" + name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testEventFieldPromptsStayInsideEmptyFields() {
        let title = app.textFields["event.title"]
        wait("The real event editor is ready") { title.isHittable }
        XCTAssertEqual(title.label, "Event title")
        XCTAssertEqual(title.placeholderValue, "Lunch with Sam Fri 1pm")
        XCTAssertFalse(app.staticTexts["Lunch with Sam Fri 1pm"].exists,
                       "An example must not become a permanent form label")
        let editor = app.sheets.firstMatch
        XCTAssertTrue(editor.exists)
        if editor.exists {
            XCTAssertGreaterThan(title.frame.width, editor.frame.width * 0.75,
                                 "The title needs the row, not a narrow trailing value column")
        }
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "event-title-empty-prompt"; empty.lifetime = .keepAlways; add(empty)
        title.click(); title.typeText("Interview Blocker")
        XCTAssertEqual(title.value as? String, "Interview Blocker")
        XCTAssertFalse(app.staticTexts["Lunch with Sam Fri 1pm"].exists)
        let filled = XCTAttachment(screenshot: app.screenshot())
        filled.name = "event-title-filled"; filled.lifetime = .keepAlways; add(filled)
        let location = app.textFields["event.location"], guest = app.textFields["event.guestField"]
        for field in [location, guest] {
            for _ in 0..<6 {
                if field.exists && field.isHittable { break }
                editor.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350)
            }
            XCTAssertTrue(field.exists && field.isHittable, "The form field remains reachable")
        }
        XCTAssertEqual(location.label, "Location")
        XCTAssertEqual(location.placeholderValue, "Location or room")
        XCTAssertEqual(guest.label, "Guest")
        XCTAssertEqual(guest.placeholderValue, "Add a guest — name or email")
    }

    func testSchedulingLinkInTheMacComposer() {
        wait("The shell window is ready") { self.app.windows.firstMatch.exists }
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Email"].firstMatch.click()
        let compose = app.buttons["mail.list.compose"].firstMatch
        wait("Mail actions are ready") { compose.isHittable || self.app.descendants(matching: .any)["mail.more"].firstMatch.isHittable }
        if compose.isHittable {
            compose.click()
        } else {
            app.descendants(matching: .any)["mail.more"].firstMatch.click()
            let new = app.menuItems["New message"].firstMatch
            wait("New message menu action is ready") { new.isHittable }
            new.click()
        }
        let body = app.textViews["mail.composer.body"].firstMatch
        wait("The new message editor is ready") { body.isHittable }
        let insert = app.buttons["mail.composer.schedulingLink"].firstMatch
        XCTAssertTrue(insert.isHittable)
        insert.click()
        wait("The confirmed link is inserted") { (body.value as? String)?.contains("https://book.bananatheapp.com/noor") == true }
        body.typeText("Thanks")
        XCTAssertTrue((body.value as? String)?.contains("Thanks") == true)
    }

    func testSidebarAndWeekNavigationAtWideAndNarrowWidths() {
        wait("Period menu") { self.period.isHittable }
        period.click()
        var week: XCUIElement?
        wait("Opened Week choice") {
            week = self.app.menuItems.matching(identifier: "Week").allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled }
            return week != nil
        }
        guard let week else { return }
        week.click()
        checkPlacement("wide")
        let before = period.value as? String
        XCTAssertNotNil(before)
        app.buttons["plan.next"].click()
        wait("Next changes the displayed week") { (self.period.value as? String) != before }
        checkPlacement("paged") // Includes Today while paged away.
        app.buttons["plan.today"].click()
        wait("Today restores the original week") { (self.period.value as? String) == before }

        wait("Today disappears in the current period") { !self.app.buttons["plan.today"].exists }

        toggle.click()
        wait("Sidebar button remains reachable while collapsed") { self.toggle.isHittable && self.toggle.label == "Show sidebar" }
        app.typeKey("s", modifierFlags: [.control, .command])
        wait("Native sidebar shortcut restores the same column") { self.toggle.label == "Hide sidebar" }
        XCTAssertEqual(period.value as? String, before, "Sidebar changes must not page the calendar")

        let window = app.windows.firstMatch, frame = window.frame
        app.terminate()
        app.launchArguments += ["--mac-window-size", "800x780"]
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        wait("Window launches at the requested narrow width") { window.frame.width < frame.width - 100 }
        checkPlacement("narrow")
        app.buttons["plan.next"].click()
        wait("Narrow paging shows Today") { self.app.buttons["plan.today"].isHittable }
        checkPlacement("narrow-paged")
    }
}
