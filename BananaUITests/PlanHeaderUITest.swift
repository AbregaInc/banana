import XCTest

final class PlanHeaderUITest: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testViewSwitchUsesTheTopBarAndRemindersAreNotCountedTwice() {
        let app = XCUIApplication()
        app.launchArguments = ["--plan", "--outstanding-reminders", "--ui-audit", "--disable-icloud", "--no-space-sync",
                               "-onboardingCompleted", "YES", "-finishSetupDismissed", "YES", "-planMode", "day"]
        app.withoutSpaceSync()
        app.launch()
        let day = app.segmentedControls.buttons["Day"]
        let search = app.buttons["calendar.search.open"]
        XCTAssertTrue(day.waitForExistence(timeout: 15))
        XCTAssertTrue(search.exists)
        XCTAssertLessThan(day.frame.minY, search.frame.maxY, "The view switch uses the top bar after removing the page title")
        XCTAssertFalse(day.frame.intersects(search.frame), "The picker must not overlap search")
        XCTAssertTrue(app.buttons["Mark Call the plumber done"].exists)
        if app.buttons["plan.attention"].exists {
            XCTAssertFalse(app.buttons["plan.attention"].label.contains("reminder"), "Reminders already appear in their own actionable row")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Plan header — sample data"; shot.lifetime = .keepAlways; add(shot)
        search.tap()
        XCTAssertTrue(app.textFields["filters.plan.query"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar.search.dates"].exists)
        let searchShot = XCTAttachment(screenshot: app.screenshot())
        searchShot.name = "Calendar search — empty state"; searchShot.lifetime = .keepAlways; add(searchShot)
    }

    func testTabReturnReusesCalendarPreparationAndNotesPage() {
        func run(reference: Bool) -> [String: Int] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-preview", "--tab", "plan", "--modules", "everything", "--ui-audit",
                                   "--tab-reentry-probe", "--calendar-viewport-audit", "--disable-icloud", "--no-space-sync",
                                   "-onboardingCompleted", "YES", "-finishSetupDismissed", "YES", "-planMode", "day"]
            if reference { app.launchArguments += ["--calendar-reprepare-on-appear", "--notes-reload-on-appear"] }
            app.withoutSpaceSync()
            app.launch()
            XCTAssertTrue(app.waitForShell())
            func count(_ metric: String) -> Int {
                Int(app.descendants(matching: .any)[metric].firstMatch.value as? String ?? "") ?? -1
            }
            func awaitCount(_ metric: String, atLeast: Int) {
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in count(metric) >= atLeast }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, metric)
            }
            awaitCount("calendar.performance.preparations", atLeast: 1)
            app.openPage("notes")
            awaitCount("notes.performance.loads", atLeast: 1)
            app.openPage("plan")
            awaitCount("calendar.performance.appearances", atLeast: 2)
            let beforeCalendar = count("calendar.performance.preparations")
            let beforeNotes = count("notes.performance.loads")
            let beforeCalendarRenders = count("day.performance.renderCount")
            let beforeNotesRenders = count("notes.performance.renderCount")
            let began = Date()
            for visit in 2...3 {
                app.openPage("notes")
                awaitCount("notes.performance.appearances", atLeast: visit)
                app.openPage("plan")
                awaitCount("calendar.performance.appearances", atLeast: visit + 1)
            }
            let result = ["calendarPreparations": count("calendar.performance.preparations") - beforeCalendar,
                          "notesLoads": count("notes.performance.loads") - beforeNotes,
                          "calendarBodyEvaluations": count("day.performance.renderCount") - beforeCalendarRenders,
                          "notesBodyEvaluations": count("notes.performance.renderCount") - beforeNotesRenders,
                          // Automation wall time, not input-to-visible or frame evidence.
                          "automationMilliseconds": Int(Date().timeIntervalSince(began) * 1000)]
            let attachment = XCTAttachment(string: "\(result)")
            attachment.name = reference ? "Tab return reference" : "Tab return reuse"
            attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
            return result
        }
        let reference = run(reference: true)
        let reuse = run(reference: false)
        XCTAssertGreaterThanOrEqual(reference["calendarPreparations"] ?? 0, 2)
        XCTAssertGreaterThanOrEqual(reference["notesLoads"] ?? 0, 2)
        XCTAssertEqual(reuse["calendarPreparations"], 0)
        XCTAssertEqual(reuse["notesLoads"], 0)
    }
}
