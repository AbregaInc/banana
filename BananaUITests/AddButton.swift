import XCTest

extension XCUIApplication {
    /// A page's +, once the screen has one: in its top bar on every device (`PageChrome`).
    func plus(_ page: String) -> XCUIElement {
        let own = buttons[page].firstMatch
        _ = own.waitForExistence(timeout: 20)
        return own
    }
}
