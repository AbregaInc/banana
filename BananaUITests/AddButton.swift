import XCTest

extension XCUIApplication {
    /// A page's way to add, once the screen has one: its + in the top bar (`PageChrome`), or in
    /// the new shells (docs/design/BOTTOM-BAR-SHELL.md) the "Search or ask" field, which lists
    /// what can be added (`page.add.list`) when it is tapped with nothing typed.
    func plus(_ page: String) -> XCUIElement {
        let own = buttons[page].firstMatch
        let field = textFields["shell.field"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in own.exists || field.exists }, object: nil)
        _ = XCTWaiter().wait(for: [ready], timeout: 20)
        return own.exists || !field.exists ? own : field
    }
}
