import XCTest

/// A list row's height at a text size (`MailRowHeight`, MAIL-UX 6.1.3): the token at the default
/// size, grown with the text at a larger one, never shrunk at a smaller one. Found on the phone at
/// the largest accessibility size, where three lines of text were drawn over the next row.
final class MailRowHeightTests: XCTestCase {

    func testTheDefaultSizeIsTheToken() {
        XCTAssertEqual(MailRowHeight.scaled(76, standard: 20, current: 20), 76)
        XCTAssertEqual(MailRowHeight.scaled(44, standard: 22, current: 22), 44)
    }

    func testALargerSizeGrowsTheRowByTheTextsFactor() {
        // The subheadline's line height at the largest accessibility size is near three times
        // the default's: the row is near three times the token, rounded to a point.
        XCTAssertEqual(MailRowHeight.scaled(76, standard: 20, current: 58), 220)
        XCTAssertEqual(MailRowHeight.scaled(76, standard: 20, current: 30), 114)
    }

    func testASmallerSizeNeverShrinksTheRow() {
        XCTAssertEqual(MailRowHeight.scaled(76, standard: 20, current: 17), 76)
        XCTAssertEqual(MailRowHeight.scaled(44, standard: 22, current: 19), 44)
    }

    func testAMissingStandardLeavesTheToken() {
        XCTAssertEqual(MailRowHeight.scaled(76, standard: 0, current: 58), 76)
    }

    func testThreeLinesAtTheLargestSizeFitInTheRow() {
        // What the phone draws in a three-line row: callout, then two subheadlines, with the
        // row's insets. At the largest accessibility size (callout 61, subheadline 58) the grown
        // row must hold them.
        let grown = MailRowHeight.scaled(76, standard: 20, current: 58)
        let lines: CGFloat = 61 + 58 + 58
        XCTAssertGreaterThanOrEqual(grown, lines + 16)
    }
}
