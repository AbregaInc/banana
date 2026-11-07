import XCTest

extension XCUIApplication {
    /// Opens one of the shell's pages (docs/design/BOTTOM-BAR-SHELL.md): from the rail where
    /// there is one, else from the switcher at the bottom left. `page` is a `ShellPage` raw value:
    /// plan, mail, body, notes, library, review, settings.
    func openPage(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = buttons["shell.page.\(page)"]
        if !(button.exists && button.isHittable) {
            let switcher = buttons["shell.switcher"]
            if !switcher.waitForExistence(timeout: 15) {
                // A shell with neither (a regular width before the rail): its tab bar or sidebar.
                let title = ["plan": "Plan", "mail": "Email", "body": "Body", "notes": "Notes", "library": "Library",
                             "review": "Review", "settings": "Settings"][page] ?? page
                let tab = tabBars.buttons[title].exists ? tabBars.buttons[title] : buttons[title].firstMatch
                XCTAssertTrue(tab.waitForExistence(timeout: 5), "no \(page) page", file: file, line: line)
                tab.tap()
                return
            }
            switcher.tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(page) page", file: file, line: line)
        button.tap()
    }

    /// The shell is up: the switcher (phone) or the rail (wide).
    func waitForShell(timeout: TimeInterval = 20) -> Bool {
        let switcher = buttons["shell.switcher"], rail = descendants(matching: .any)["shell.rail"]
        let tabs = tabBars.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in switcher.exists || rail.exists || tabs.exists }, object: nil)
        return XCTWaiter().wait(for: [ready], timeout: timeout) == .completed
    }
}
