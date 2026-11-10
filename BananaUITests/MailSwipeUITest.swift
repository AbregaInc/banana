import XCTest

/// A sideways swipe in the open conversation reads through the list it was opened from
/// (`MailConversationPager`): left for the next older, right for the newer, Back to the list at
/// the row where he stopped. A wide table scrolls itself, not the pager, and the left edge is Back.
final class MailSwipeUITest: MailUITestCase {

    private var title: XCUIElement { element(MailID.conversationTitle) }
    private var pager: XCUIElement { element(MailID.pager) }

    /// The subject of the conversation on screen, once it is there.
    private func subject(timeout: TimeInterval = 5) -> String {
        XCTAssertTrue(title.waitForExistence(timeout: timeout), app.debugDescription)
        return title.label
    }

    /// A thumb's swipe across the middle of the page.
    private func swipe(left: Bool) {
        let from = pager.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.55))
        let to = pager.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.1 : 0.9, dy: 0.55))
        from.press(forDuration: 0.02, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Waits for the subject to become something other than `old`.
    private func subject(after old: String) -> String {
        _ = waitUntil(timeout: 5) { self.title.exists && self.title.label != old }
        return subject()
    }

    func testSwipingReadsThroughTheListAndBackReturnsToTheRow() {
        launch()
        let keys = visibleRowKeys()
        XCTAssertGreaterThanOrEqual(keys.count, 4, "the sample inbox shows rows")
        guard keys.count >= 4 else { return }
        openConversation(keys[0])
        let first = subject()
        swipe(left: true)
        let second = subject(after: first)
        snap("swipe-1")
        XCTAssertNotEqual(second, first, "a swipe left shows the next older conversation")
        swipe(left: true)
        let third = subject(after: second)
        snap("swipe-2")
        XCTAssertNotEqual(third, second)
        XCTAssertNotEqual(third, first)
        swipe(left: false)
        XCTAssertEqual(subject(after: third), second, "a swipe right goes back to the newer one")
        snap("swiped")
        element(MailID.back).tap()
        XCTAssertTrue(waitGone(element(MailID.conversation)))
        XCTAssertTrue(row(keys[1]).waitForExistence(timeout: 5))
        XCTAssertTrue(row(keys[1]).isHittable, "the list is at the row where the swiping stopped")
    }

    func testTheNewestConversationRubberBandsAtTheTop() {
        launch()
        let keys = visibleRowKeys()
        guard let top = keys.first else { return XCTFail("no rows") }
        openConversation(top)
        let first = subject()
        swipe(left: false)
        XCTAssertFalse(waitUntil(timeout: 2) { self.title.label != first }, "nothing newer: no wrap")
        XCTAssertEqual(subject(), first)
    }

    /// A message whose body is one data table wider than any phone: six columns of long cells.
    private static let wideTable: String = {
        let header = (1...6).map { "<th>Column \($0) with a long heading</th>" }.joined()
        let rows = (1...4).map { row in
            "<tr>" + (1...6).map { "<td>Row \(row) cell \($0) holds a long value</td>" }.joined() + "</tr>"
        }.joined()
        return "<p>The weekly numbers:</p><table><thead><tr>\(header)</tr></thead><tbody>\(rows)</tbody></table><p>That is all.</p>"
    }()

    /// A data table wider than the page scrolls sideways itself; the conversation stays.
    func testAWideTableScrollsItselfNotThePager() throws {
        // The app reads the case from the runner's own folder (`--mail-case`, Debug Simulator).
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mail-swipe-wide-table.html")
        try Self.wideTable.write(to: file, atomically: true, encoding: .utf8)
        launch(extra: ["--mail-case", file.path])
        scrollToRow("receipt")
        openConversation("receipt")
        let receipt = subject()
        let table = app.scrollViews[MailID.bodyTable].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5), "the table is drawn\n\(app.debugDescription)")
        let cell = table.staticTexts.firstMatch
        let before = cell.frame.minX
        let from = table.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        from.press(forDuration: 0.02, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                   withVelocity: .default, thenHoldForDuration: 0.2)
        XCTAssertLessThan(cell.frame.minX, before - 20, "the table scrolled sideways")
        XCTAssertEqual(subject(), receipt, "the conversation did not change")
        snap("wide-table")
    }

    /// The left edge closes the conversation, as a pushed screen's does, and never pages.
    func testTheLeftEdgeGoesBack() {
        launch()
        let keys = visibleRowKeys()
        guard keys.count >= 3 else { return XCTFail("no rows") }
        openConversation(keys[1])
        _ = subject()
        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        edge.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                   withVelocity: .default, thenHoldForDuration: 0)
        XCTAssertTrue(waitGone(element(MailID.conversation)), "the edge closed the conversation\n\(app.debugDescription)")
        XCTAssertTrue(row(keys[1]).isHittable)
    }

    /// Frame hitches while swiping from conversation to conversation. Simulator evidence for
    /// comparison only, not 120 Hz acceptance.
    func testSwipingHitches() {
        launch()
        let keys = visibleRowKeys()
        guard let top = keys.first else { return XCTFail("no rows") }
        openConversation(top)
        _ = subject()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<3 {
                let old = title.label
                swipe(left: true)
                _ = waitUntil(timeout: 3) { self.title.label != old }
            }
        }
    }
}
