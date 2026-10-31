import XCTest

/// Which columns show at which width of Mail's own area (`MailArrangement`: the list alone below 660,
/// a pane from 660, the control column from 828, the details from 1076). Mail's area is the window's
/// less the sidebar, so the cases measure it rather than assume it.
final class MailWindowSizeTests: MacMailTestCase {

    private func expectTheColumnsTheWidthCalls(for context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let width = mailWidth() else { return XCTFail("Mail's width cannot be measured \(context)", file: file, line: line) }
        // Within a few points of a breakpoint the layout may go either way.
        for edge in [MailArrangement.paneAt, MailArrangement.controlAt, MailArrangement.detailsAt] where abs(width - edge) < 14 {
            return
        }
        let expected = MailArrangement.choose(width: width)
        let said = "at \(Int(width)) points of Mail \(context)"
        XCTAssertEqual(has(MailID.control), expected.showsControl, "the control column \(said)", file: file, line: line)
        XCTAssertEqual(paneIsShowing, expected.showsPane, "the reading pane \(said)", file: file, line: line)
        XCTAssertEqual(has(MailID.details), expected.showsDetails, "the details column \(said)", file: file, line: line)
        XCTAssertTrue(has(MailID.list), "the list \(said)", file: file, line: line)
    }

    func testNarrowShowsTheListAlone() {
        launchMail(size: CGSize(width: 840, height: 780))
        shot("narrow")
        expectTheColumnsTheWidthCalls(for: "narrow")
        if let width = mailWidth() { XCTAssertLessThan(width, MailArrangement.paneAt + 60, "the window did not get narrow: Mail is \(width) wide") }
    }

    func testMediumShowsAPaneBesideTheList() {
        launchMail(size: CGSize(width: 960, height: 780))
        shot("medium")
        expectTheColumnsTheWidthCalls(for: "medium")
    }

    func testRegularShowsControlListAndPane() {
        launchMail(size: CGSize(width: 1120, height: 780))
        shot("regular")
        expectTheColumnsTheWidthCalls(for: "regular")
    }

    func testWideShowsAllFourColumns() throws {
        launchMail(size: CGSize(width: 1500, height: 780))
        shot("wide")
        guard let width = mailWidth(), width >= MailArrangement.detailsAt else {
            throw XCTSkip("The screen is too small for four columns (Mail is \(String(describing: mailWidth())) wide).")
        }
        expectTheColumnsTheWidthCalls(for: "wide")
    }

    func testResizingAcrossTheBreakpointsAddsAndDropsColumnsLive() {
        launchMail(size: CGSize(width: 840, height: 780))
        for width in [CGFloat(960), 1120, 1500, 1120, 960, 840] {
            resizeWindow(to: CGSize(width: width, height: 780))
            eventually("the columns to follow a window of \(Int(width))", timeout: 4, report: false) {
                guard let mail = self.mailWidth() else { return false }
                let expected = MailArrangement.choose(width: mail)
                return self.has(MailID.control) == expected.showsControl && self.paneIsShowing == expected.showsPane
            }
            expectTheColumnsTheWidthCalls(for: "after resizing to \(Int(width))")
        }
        shot("back to narrow")
    }

    func testANewMessageWhereThereIsNoPaneIsASheet() {
        launchMail(size: CGSize(width: 840, height: 780))
        press("c")
        eventually("a sheet for a new message with no pane to hold it", timeout: 8) { self.app.sheets.count > 0 }
        shot("sheet")
        press(.escape)
        eventually("Esc to close the sheet and keep the draft") { self.app.sheets.count == 0 }
    }
}
