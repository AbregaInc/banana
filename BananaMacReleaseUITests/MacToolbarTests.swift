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
        app.launch()
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

    private func checkPlacement(_ name: String) {
        let previous = app.buttons["plan.previous"], next = app.buttons["plan.next"]
        wait("All navigation controls remain reachable") { self.toggle.isHittable && previous.isHittable && next.isHittable && self.period.isHittable }
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(toggle.frame.maxX, window.midX, "Sidebar control belongs on the left")
        XCTAssertGreaterThan(previous.frame.midX, window.midX, "Calendar navigation belongs on the right")
        XCTAssertGreaterThan(next.frame.minX, previous.frame.midX, "Next follows Previous")
        XCTAssertLessThanOrEqual(period.frame.maxX, previous.frame.minX + 2, "Range and paging form one ordered group")
        XCTAssertLessThanOrEqual(next.frame.maxX, window.maxX, "Next is not clipped into overflow")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "mac-toolbar-" + name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
        app.launchEnvironment["BANANA_AUDIT_WINDOW_WIDTH"] = "800"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        wait("Window launches at the requested narrow width") { window.frame.width < frame.width - 100 }
        checkPlacement("narrow")
    }
}
