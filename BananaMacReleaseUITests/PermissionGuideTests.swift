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
    }

    private func openGuide() {
        app.launch()
        let permissions = app.buttons["onboarding.permissions"]
        for _ in 0..<10 {
            if permissions.exists && permissions.isHittable { break }
            let skip = app.buttons["onboarding.notNow"]
            let next = app.buttons["onboarding.continue"]
            wait("An onboarding action", until: {
                permissions.exists || (skip.exists && skip.isHittable) || (next.exists && next.isHittable)
            })
            if permissions.exists { break }
            if skip.exists && skip.isHittable { skip.click() }
            else { next.click() }
        }
        wait("Optional permissions entry", until: { permissions.exists && permissions.isHittable })
        permissions.click()
        wait("Permissions panel", until: { self.app.windows["Permissions"].exists })
    }

    private func denyReminderPrompt() {
        let agents = [app!, XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter"),
                      XCUIApplication(bundleIdentifier: "com.apple.CoreServicesUIAgent"), settings]
        var deny: XCUIElement?
        wait("Native Reminders denial button", until: {
            for agent in agents where agent.state != .notRunning {
                let button = agent.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Don’t Allow", "Don't Allow")).firstMatch
                if button.exists && button.isHittable { deny = button; return true }
            }
            return false
        })
        capture("reminders-prompt")
        deny?.click()
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

    func testNativeRemindersRecoveryAndSettingsFollowing() {
        openGuide()
        let guide = app.windows["Permissions"]
        let reminders = guide.buttons["mac.permissions.allow.Reminders"]
        wait("Native Reminders request", until: { reminders.exists && reminders.isHittable })
        XCTAssertEqual(reminders.label, "Allow")
        capture("before-request")
        reminders.click()
        denyReminderPrompt()
        wait("Denied permission offers Settings", until: { reminders.exists && reminders.label == "Open Settings" })
        reminders.click()
        let target = settings.windows.firstMatch
        wait("System Settings opens", until: { target.exists && settings.state == .runningForeground })
        assertAdjacent(guide, target)
        capture("docked")
        // Drag the real Settings title bar; the guide must follow without covering it.
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
        let finish = start.withOffset(CGVector(dx: -80, dy: 40))
        start.press(forDuration: 0.1, thenDragTo: finish)
        assertAdjacent(guide, target)
        capture("after-move")
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        wait("Guide hides for other apps", until: { !guide.exists || !guide.isHittable })
        app.activate()
        wait("Guide returns with Banana", until: { guide.exists && guide.isHittable })
        capture("returned")
        let close = guide.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] %@", "CloseWindow")).firstMatch
        wait("Native panel close control", until: { close.exists && close.isHittable })
        close.click()
        wait("Guide closes", until: { !guide.exists || !guide.isHittable })
    }
}
