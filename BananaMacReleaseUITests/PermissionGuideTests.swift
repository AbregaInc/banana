import XCTest
import AppKit
import Darwin

/// Run only in the dedicated VM account. The supplied app is built and signed
/// before testing; this runner never changes its signature or the host desktop.
final class PermissionGuideTests: XCTestCase {
    private var app: XCUIApplication!
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let home = getpwuid(getuid())?.pointee.pw_dir,
              FileManager.default.fileExists(atPath: String(cString: home) + "/.config/banana/mac-release-test-account"),
              let path = ProcessInfo.processInfo.environment["BANANA_PERMISSION_APP"] else {
            throw NSError(domain: "PermissionGuideTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Use the dedicated permission-test VM"])
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
    }

    override func tearDownWithError() throws {
        capture("final")
        if let app, app.state != .notRunning { app.terminate() }
    }

    private func wait(_ reason: String, until predicate: @escaping () -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, reason)
    }

    private func click(_ element: XCUIElement) {
        element.click()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "permissions-" + name
        shot.lifetime = .keepAlways
        add(shot)
        if let app {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "permissions-" + name + "-app-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        if settings.state != .notRunning {
            let tree = XCTAttachment(string: settings.debugDescription)
            tree.name = "permissions-" + name + "-settings-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
    }

    private func openGuide(launch: Bool = true) {
        if launch { app.launch() }
        // Local-network discovery may have prompted before XCTest attached.
        for bundle in ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent"] {
            let system = XCUIApplication(bundleIdentifier: bundle)
            guard system.state != .notRunning else { continue }
            let tree = XCTAttachment(string: system.debugDescription)
            tree.name = "startup-" + bundle
            tree.lifetime = .keepAlways
            add(tree)
            let unrelated = system.buttons.matching(NSPredicate(format: "title == %@ OR title == %@", "Don’t Allow", "Don't Allow")).firstMatch
            if unrelated.exists { click(unrelated) }
        }
        let permissions = app.buttons["onboarding.permissions"]
        for _ in 0..<10 {
            if permissions.exists && permissions.isHittable { break }
            let skip = app.buttons["onboarding.notNow"]
            let next = app.buttons["onboarding.continue"]
            wait("An onboarding action", until: {
                permissions.exists || (skip.exists && skip.isHittable) || (next.exists && next.isHittable)
            })
            if permissions.exists { break }
            if skip.exists && skip.isHittable { click(skip) }
            else { click(next) }
        }
        wait("Optional permissions entry", until: { permissions.exists && permissions.isHittable })
        click(permissions)
        wait("Permissions panel", until: { self.app.dialogs["Permissions"].exists })
    }

    private func denyReminderPrompt() {
        let agents = [app!, XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter"),
                      XCUIApplication(bundleIdentifier: "com.apple.coreservices.uiagent"), settings]
        var deny: XCUIElement?
        wait("Native Reminders denial button", until: {
            for agent in agents where agent.state != .notRunning {
                let button = agent.buttons.matching(NSPredicate(format: "title == %@ OR title == %@", "Don’t Allow", "Don't Allow")).firstMatch
                if button.exists && button.isHittable { deny = button; return true }
            }
            return false
        })
        capture("reminders-prompt")
        if let deny { click(deny) }
    }

    private func assertAdjacent(_ guide: XCUIElement, _ target: XCUIElement) {
        wait("Guide beside Settings", until: {
            guard guide.exists, guide.isHittable, target.exists else { return false }
            let g = guide.frame, s = target.frame
            return (g.minX >= s.maxX + 10 || g.maxX <= s.minX - 10)
                && abs(g.minY - s.minY) < 3
        })
        XCTAssertFalse(guide.frame.intersects(target.frame))
    }

    func testNativeRemindersRecoveryAndSettingsFollowing() throws {
        openGuide()
        let guide = app.dialogs["Permissions"]
        let reminders = guide.buttons["mac.permissions.allow.Reminders"]
        wait("Native Reminders request", until: { reminders.exists && reminders.isHittable })
        XCTAssertEqual(reminders.label, "Allow")
        capture("before-request")
        click(reminders)
        denyReminderPrompt()
        wait("Denied permission offers Settings", until: { reminders.exists && reminders.label == "Open Settings" })
        click(reminders)
        let target = settings.windows.firstMatch
        wait("System Settings opens", until: { target.exists && self.settings.state == .runningForeground })
        assertAdjacent(guide, target)
        capture("docked")
        // Drag the blank sidebar title bar, away from toolbar controls.
        // Assert actual movement as well as following, so a failed drag cannot pass.
        let screen = try XCTUnwrap(NSScreen.main).frame
        for (name, x) in [("right-side", screen.minX + 40),
                          ("left-side", screen.maxX - target.frame.width - 40)] {
            let before = target.frame
            let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 26))
            let finish = start.withOffset(CGVector(dx: x - before.minX, dy: 160 - before.minY))
            start.click(forDuration: 0.3, thenDragTo: finish)
            wait("Settings actually moves", until: { abs(target.frame.minX - before.minX) > 20 })
            assertAdjacent(guide, target)
            if name == "right-side" { XCTAssertGreaterThan(guide.frame.minX, target.frame.maxX) }
            else { XCTAssertLessThan(guide.frame.maxX, target.frame.minX) }
            capture(name)
        }
        let permissionSwitch = target.switches.firstMatch
        wait("Native Reminders switch", until: { permissionSwitch.exists && permissionSwitch.isHittable })
        XCTAssertEqual((permissionSwitch.value as? NSNumber)?.boolValue, false)
        click(permissionSwitch)
        wait("Reminders enabled in Settings", until: { (permissionSwitch.value as? NSNumber)?.boolValue == true })
        // macOS may withhold the effective grant until its own Quit & Reopen action.
        let reopen = settings.buttons["Quit & Reopen"]
        if reopen.waitForExistence(timeout: 3) {
            capture("restart-required")
            click(reopen)
            wait("System reopens Banana", until: { self.app.state == .runningForeground })
            openGuide(launch: false)
        }
        wait("Guide observes the real grant", until: { !reminders.exists && guide.images["Allowed"].exists })
        capture("granted")
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        wait("Guide hides for other apps", until: { !guide.exists || !guide.isHittable })
        app.activate()
        wait("Guide returns with Banana", until: { guide.exists && guide.isHittable })
        capture("returned")
        let close = guide.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] %@", "CloseWindow")).firstMatch
        wait("Native panel close control", until: { close.exists && close.isHittable })
        click(close)
        wait("Guide closes", until: { !guide.exists || !guide.isHittable })
    }
}
