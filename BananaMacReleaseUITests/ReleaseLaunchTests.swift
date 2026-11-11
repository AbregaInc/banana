import XCTest
import AppKit
import Darwin

/// Normal startup of the exact signed archive, in a dedicated signed-out macOS test account.
/// This suite takes desktop input. It is never part of the everyday Simulator run.
final class ReleaseLaunchTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // XCTest's runner is sandboxed; FileManager's home points to its container.
        guard let accountHome = getpwuid(getuid())?.pointee.pw_dir else {
            throw NSError(domain: "ReleaseLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Cannot resolve the test account home directory"])
        }
        let marker = URL(fileURLWithPath: String(cString: accountHome), isDirectory: true)
            .appendingPathComponent(".config/banana/mac-release-test-account")
        guard FileManager.default.fileExists(atPath: marker.path),
              let path = ProcessInfo.processInfo.environment["BANANA_RELEASE_APP"],
              let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier else {
            throw NSError(domain: "ReleaseLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Run tools/mac-release-tests.py in the dedicated test account"])
        }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == identifier }) else {
            throw NSError(domain: "ReleaseLaunch", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Candidate identity is already running; refusing to terminate or attach to it"])
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        // No launch arguments or environment overrides in the app under test.
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "release-final-state"
            image.lifetime = .keepAlways
            add(image)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "release-accessibility-state"
            tree.lifetime = .keepAlways
            add(tree)
            app.terminate()
        }
    }

    private func ready(_ element: XCUIElement, _ description: String) {
        let usable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [usable], timeout: 30), .completed, description)
    }

    private var period: XCUIElement {
        app.descendants(matching: .any)["mac.planner.view"].firstMatch
    }

    private func choose(_ name: String) {
        ready(period, "Plan period menu")
        // AppKit exposes a menu button's displayed name as its title, not its AX label.
        if period.title == name { return }
        period.click()
        // The menu bar can expose another item with this name. Wait for the opened menu's
        // usable item, including the menu-opening animation, rather than choosing firstMatch.
        var item: XCUIElement?
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            item = self.app.menuItems.matching(identifier: name).allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled }
            return item != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 30), .completed, "Calendar view \(name)")
        guard let item else { return }
        item.click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.period.title == name
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

    private func survivesStartup() {
        // Time is the subject: fail if a deferred startup task kills the app in this interval.
        let exited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.state == .notRunning
        }, object: nil)
        exited.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 10), .completed,
                       "App exited during deferred startup")
    }

    func testFirstLaunchOnboardingCalendarAndRelaunch() {
        app.launch()
        ready(app.staticTexts["onboarding.terms"], "Fresh account must show the normal welcome")
        survivesStartup()
        app.buttons["onboarding.continue"].click()
        ready(app.descendants(matching: .any)["onboarding.wake.time"].firstMatch, "Wake setup")
        app.buttons["onboarding.continue"].click()
        ready(app.descendants(matching: .any)["onboarding.windDown.time"].firstMatch, "Wind-down setup")
        app.buttons["onboarding.continue"].click()
        ready(app.buttons["onboarding.notNow"], "Continue without a Google account")
        app.buttons["onboarding.notNow"].click()
        choose("Day")
        choose("Week")
        let initialWeek = Date()
        let before = period.value as? String
        XCTAssertNotNil(before, "Period must expose the displayed dates")
        ready(app.buttons["plan.next"], "Next period")
        app.buttons["plan.next"].click()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (self.period.value as? String) != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        let today = app.buttons["plan.today"]
        if today.waitForExistence(timeout: 5) {
            ready(today, "Return to today")
            today.click()
        } else {
            // This is a live-clock release build: crossing the week boundary can make the
            // page we just advanced to today's week, so Today is correctly absent.
            XCTAssertFalse(Calendar.current.isDate(initialWeek, equalTo: Date(), toGranularity: .weekOfYear))
        }
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let sameWeek = Calendar.current.isDate(initialWeek, equalTo: Date(), toGranularity: .weekOfYear)
            return !self.app.buttons["plan.today"].exists && (!sameWeek || (self.period.value as? String) == before)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        app.terminate()
        app.launch()
        ready(period, "Relaunch must restore Plan")
        XCTAssertFalse(app.staticTexts["onboarding.terms"].exists, "Onboarding completion must persist")
        choose("Day")
        choose("Week")
        survivesStartup()
    }

    func testFoundationDateOperatorsOnRuntime() {
        // A sentinel for SDK/runtime compatibility, including the 27.2 back-deployed operators.
        // Numeric timestamps are the SDK's fallback implementation, and preserve NaN behavior.
        guard let imports = ProcessInfo.processInfo.environment["BANANA_RELEASE_DATE_OPERATORS"] else {
            XCTFail("Runner must inventory the exact candidate's imported Date operators")
            return
        }
        // A candidate that removes these imports must not be blocked by the probe's own imports.
        let operators = imports.split(separator: ",").map(String.init)
        XCTAssertTrue(operators.allSatisfy { [">=", "<="].contains($0) })
        let inventory = XCTAttachment(string: "Candidate Date operator imports: \(imports)")
        inventory.lifetime = .keepAlways
        add(inventory)
        let values: [Double] = [-Double.infinity, -1, 0, 1, Double.infinity, Double.nan]
        for lhs in values {
            for rhs in values {
                let left = Date(timeIntervalSinceReferenceDate: lhs)
                let right = Date(timeIntervalSinceReferenceDate: rhs)
                if operators.contains(">=") { XCTAssertEqual(left >= right, lhs >= rhs) }
                if operators.contains("<=") { XCTAssertEqual(left <= right, lhs <= rhs) }
            }
        }
    }
}
