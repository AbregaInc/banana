import XCTest

/// Which columns Mail shows at which width (`MailArrangement`): the control column, the list,
/// the reading pane and the details, with the details the first to drop and the control column
/// the second. A table, because the widths are the rule.
final class MailArrangementTests: XCTestCase {

    private func columns(_ width: Double, pane: Bool = true, details: Bool = true) -> String {
        let a = MailArrangement.choose(width: width, wantsPane: pane, wantsDetails: details)
        return [a.showsControl ? "control" : nil, "list", a.showsPane ? "pane" : nil,
                a.showsDetails ? "details" : nil].compactMap { $0 }.joined(separator: " ")
    }

    func testThePhoneAndAnyNarrowWindowGetTheListAlone() {
        for width in [320.0, 375, 393, 430, 599, 600, 659] {
            XCTAssertEqual(columns(width), "list", "\(width)")
        }
    }

    func testAComposerIsASheetBelowAPhonesWidthAndNotAt600OrMore() {
        XCTAssertEqual(MailArrangement.compactBelow, 600)
        XCTAssertTrue(MailArrangement.choose(width: 390).isCompact)
        XCTAssertTrue(MailArrangement.choose(width: 599).isCompact)
        XCTAssertFalse(MailArrangement.choose(width: 600).isCompact)
        XCTAssertFalse(MailArrangement.choose(width: 1_120).isCompact)
    }

    func testTheBreakpointsAreTheColumnsOwnWidths() {
        XCTAssertEqual(MailArrangement.paneAt, 660)
        XCTAssertEqual(MailArrangement.controlAt, 828)
        XCTAssertEqual(MailArrangement.detailsAt, 1_076)
        XCTAssertEqual(MailArrangement.paneAt, MailArrangement.listWidth + MailArrangement.paneMinWidth)
        XCTAssertEqual(MailArrangement.controlAt, MailArrangement.paneAt + MailArrangement.controlWidth)
        XCTAssertEqual(MailArrangement.detailsAt, MailArrangement.controlAt + MailArrangement.detailsWidth)
    }

    func testColumnsJoinAsTheWidthGrowsPaneThenControlThenDetails() {
        XCTAssertEqual(columns(660), "list pane")
        XCTAssertEqual(columns(827), "list pane")
        XCTAssertEqual(columns(828), "control list pane")
        XCTAssertEqual(columns(1_075), "control list pane")
        XCTAssertEqual(columns(1_076), "control list pane details")
        XCTAssertEqual(columns(1_800), "control list pane details")
    }

    func testTheDetailsDropFirstAndTheControlColumnSecondAsTheWidthShrinks() {
        let widths = stride(from: 1_400.0, through: 300, by: -10).map { $0 }
        var lostDetails: Double?
        var lostControl: Double?
        var lostPane: Double?
        for width in widths {
            let a = MailArrangement.choose(width: width)
            if !a.showsDetails, lostDetails == nil { lostDetails = width }
            if !a.showsControl, lostControl == nil { lostControl = width }
            if !a.showsPane, lostPane == nil { lostPane = width }
        }
        XCTAssertGreaterThan(try XCTUnwrap(lostDetails), try XCTUnwrap(lostControl))
        XCTAssertGreaterThan(try XCTUnwrap(lostControl), try XCTUnwrap(lostPane))
    }

    func testAHiddenPaneLeavesTheListWideWithTheControlColumnBesideItAndNoDetails() {
        XCTAssertEqual(columns(1_200, pane: false), "control list")
        XCTAssertEqual(columns(700, pane: false), "list")
        let a = MailArrangement.choose(width: 1_200, wantsPane: false)
        XCTAssertTrue(a.canShowPane, "the toggle is still offered: it can be turned back on")
        XCTAssertEqual(a.listColumnWidth, 1_200 - MailArrangement.controlWidth)
        XCTAssertTrue(a.usesOneLineRows)
        XCTAssertTrue(a.tapOpens, "no pane to show it in: a tap opens full width")
    }

    func testHiddenDetailsGiveTheirRoomToThePane() {
        XCTAssertEqual(columns(1_200, details: false), "control list pane")
        XCTAssertTrue(MailArrangement.choose(width: 1_200, wantsDetails: false).canShowDetails)
    }

    func testTheTogglesAreOfferedOnlyWhereTheyCouldTakeEffect() {
        XCTAssertFalse(MailArrangement.choose(width: 390).canShowPane)
        XCTAssertFalse(MailArrangement.choose(width: 659).canShowPane)
        XCTAssertTrue(MailArrangement.choose(width: 660).canShowPane)
        XCTAssertFalse(MailArrangement.choose(width: 1_075).canShowDetails)
        XCTAssertTrue(MailArrangement.choose(width: 1_076).canShowDetails)
    }

    func testTheListIsThreeLinesBesideAPaneAndOneLineOnlyWhenItHasTheRoom() {
        // Beside a pane the list is a column of 320, which is three-line rows on a Mac as on a phone.
        let beside = MailArrangement.choose(width: 1_300)
        XCTAssertEqual(beside.listColumnWidth, MailArrangement.listWidth)
        XCTAssertFalse(beside.usesOneLineRows)
        // Alone, it is one line from 720 (MAIL-UX 6.1.2).
        XCTAssertFalse(MailArrangement.choose(width: 719, wantsPane: false).usesOneLineRows)
        XCTAssertTrue(MailArrangement.choose(width: 720, wantsPane: false).usesOneLineRows)
        XCTAssertFalse(MailArrangement.choose(width: 390).usesOneLineRows, "a phone")
    }

    func testATapPlacesTheCursorWhenThereIsAPaneAndOpensWhenThereIsNot() {
        XCTAssertFalse(MailArrangement.choose(width: 900).tapOpens)
        XCTAssertTrue(MailArrangement.choose(width: 390).tapOpens)
        XCTAssertTrue(MailArrangement.choose(width: 900, wantsPane: false).tapOpens)
    }

    func testTheMacsDefaultWindowAndAnIPadGetTheColumnsThatFit() {
        // The Mac's 1120-point window less the app's sidebar of 210.
        XCTAssertEqual(columns(1_120 - 210), "control list pane")
        // The same window with the sidebar hidden.
        XCTAssertEqual(columns(1_120), "control list pane details")
        // An iPad in landscape beside its sidebar, and without it.
        XCTAssertEqual(columns(1_194 - 320), "control list pane")
        XCTAssertEqual(columns(1_194), "control list pane details")
        // An iPad in portrait, 820 points: a pane and no more.
        XCTAssertEqual(columns(820), "list pane")
    }
}
