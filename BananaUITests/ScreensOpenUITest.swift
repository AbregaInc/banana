import XCTest

/// Every section, and every Settings page, opens without crashing — run on a real device in the
/// optimized (Release) build. Settings once needed more stack than an iPhone or iPad main thread
/// has once optimized, and crashed on open; the Simulator's bigger stack hid it. Only navigates:
/// nothing is toggled or changed.
final class ScreensOpenUITest: XCTestCase {

    private let sections = ["Plan", "Workouts", "Food", "Notes", "Library",
                            "Review", "Routines", "Settings"]
    private let settingsPages = ["Accounts & calendars", "Calendar", "Travel", "Wake & bedtime",
                                 "Podcasts", "Workouts", "Apple Watch", "iCloud", "Permissions", "About"]

    /// The rightmost element with this exact label: in the iPad's split view, the one in the
    /// content column rather than the sidebar's same-named section.
    private func rightmost(_ app: XCUIApplication, _ label: String) -> XCUIElement? {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
        return matches.max { $0.frame.minX < $1.frame.minX }
    }

    private func assertAlive(_ app: XCUIApplication, _ moment: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "Banana stopped running \(moment)", file: file, line: line)
    }

    private func showSidebar(_ app: XCUIApplication) {
        guard UIDevice.current.userInterfaceIdiom == .pad, !app.staticTexts["Review"].exists else { return }
        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
        if toggle.waitForExistence(timeout: 5) { toggle.tap() }
    }

    func testCalendarInclusionAndNotificationsAreIndependentAndPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--calendar-settings-preview", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        let include = app.buttons["calendars.include.wife@example.com"]
        let notify = app.buttons["calendars.notify.wife@example.com"]
        XCTAssertTrue(include.waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Calendar visibility"].exists)
        if include.value as? String == "Hidden" { include.tap() }
        app.buttons["Notifications"].tap()
        XCTAssertTrue(notify.waitForExistence(timeout: 5))
        if notify.value as? String == "Notifications on" { notify.tap() }
        XCTAssertTrue(waitUntil { notify.value as? String == "Notifications off" })
        app.buttons["Visibility"].tap()
        XCTAssertEqual(include.value as? String, "Shown", "Muting must keep the calendar enabled")
        include.tap()
        app.buttons["Notifications"].tap()
        XCTAssertTrue(waitUntil { !notify.isEnabled })
        app.buttons["Visibility"].tap()
        include.tap()
        app.buttons["Notifications"].tap()
        XCTAssertTrue(waitUntil { notify.isEnabled })
        XCTAssertEqual(notify.value as? String, "Notifications off", "Re-enabling must retain the mute")
        app.terminate(); app.launch()
        XCTAssertTrue(include.waitForExistence(timeout: 20))
        XCTAssertEqual(include.value as? String, "Shown")
        app.buttons["Notifications"].tap()
        XCTAssertEqual(notify.value as? String, "Notifications off", "The setting must survive relaunch")
    }

    func testEverySectionAndSettingsPageOpens() throws {
        // The crash this guards against needs an optimized build on a device's smaller stack;
        // a simulator can't show it, and its iPad lays the sections out as a top bar.
        #if targetEnvironment(simulator)
        throw XCTSkip("for a real device, in the Release build")
        #else
        let app = XCUIApplication()
        // Past the first run, whatever ran before this on the simulator.
        app.launchArguments = ["--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        sleep(3)
        assertAlive(app, "at launch")
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("walks the iPad sidebar")
        }

        for section in sections {
            showSidebar(app)
            // A bar button can carry a section's name too (the chart button is "Review") and sit
            // under the open sidebar: the row is the one a finger can reach.
            _ = app.staticTexts[section].firstMatch.waitForExistence(timeout: 5)
            guard let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", section))
                .allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                XCTFail("no \(section) in the sidebar"); continue
            }
            row.tap()
            sleep(2)
            assertAlive(app, "opening \(section)")
        }

        // Settings is open last. Walk its pages.
        for page in settingsPages {
            // The account row is labelled with the account itself.
            let byID = app.descendants(matching: .any)["settings.accounts"].firstMatch
            guard let row = page == "Accounts & calendars" && byID.exists ? byID : rightmost(app, page) else {
                XCTFail("no \(page) row in Settings"); continue
            }
            row.tap()
            sleep(2)
            assertAlive(app, "opening Settings › \(page)")
            // Back to the Settings list.
            // The first bar button on an iPad is the sidebar's, so name the back button.
            let back = ["Settings", "BackButton"]
                .flatMap { app.navigationBars.buttons.matching(identifier: $0).allElementsBoundByIndex }
                .last { $0.isHittable }
            if let back { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
            sleep(1)
        }
        #endif
    }
}
