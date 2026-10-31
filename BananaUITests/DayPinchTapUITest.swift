import XCTest

/// Zooming from on top of an event doesn't open it, and taps still open events around a zoom.
///
/// The real bug — one finger lands on an event, the second joins, the first lifts over the event
/// and counts as a tap — needs fingers that land and lift at different moments. XCUITest's pinch
/// puts both down and lifts both together, so it can't recreate it (this passes with the gate off
/// too); `ZoomTapGateTests` covers that timing. What this guards is the other side: the gate must
/// never swallow an ordinary tap, before or after a zoom.
final class DayPinchTapUITest: XCTestCase {

    private func block(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title),")).firstMatch
    }

    func testAPinchOnACueZoomsWithoutOpeningIt() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--day", "-planMode", "day", "--ui-audit", "--disable-icloud", "--reset-day-scroll-offset"]
        app.withoutSpaceSync()
        app.launch()
        var focus = try revealCalendarButton("Wake", in: app)
        // The routine's sheet (its time, at the top). A tap on a routine moment has opened this
        // sheet, not the routine's editor, since the sheet was added; the test still looked for
        // the editor's Save button.
        let editor = app.descendants(matching: .any).matching(identifier: "cueSheet.time").firstMatch

        // A tap opens it — so the test can tell when something did.
        focus.tap()
        if !editor.waitForExistence(timeout: 5) { print("TREE-START\n\(app.debugDescription)\nTREE-END") }
        XCTAssertTrue(editor.exists, "tapping the cue should open it")
        app.buttons["Done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))

        // Zooming from on top of it, in and out, opens nothing.
        for scale in [1.6, 0.7, 1.4] {
            focus = try revealCalendarButton("Wake", in: app)
            focus.pinch(withScale: scale, velocity: scale > 1 ? 1.2 : -1.2)
            XCTAssertFalse(editor.exists, "a pinch on the cue opened it (scale \(scale))")
            if editor.exists { app.buttons["Done"].tap() }
        }

        // Once the fingers have been up a moment, a tap opens it again.
        let focusAfter = try revealCalendarButton("Wake", in: app)
        focusAfter.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "a tap after zooming should open the cue")
    }
}
