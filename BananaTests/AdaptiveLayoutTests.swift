import XCTest

/// Layout by room (`LayoutClass`): where one column becomes two, and how wide a list reads well.
final class AdaptiveLayoutTests: XCTestCase {
    func testAPhoneIsCompactAndAnIPadIsRegular() {
        XCTAssertEqual(LayoutClass(width: 402), .compact)     // an iPhone
        XCTAssertEqual(LayoutClass(width: 599), .compact)
        XCTAssertEqual(LayoutClass(width: 600), .regular)
        XCTAssertEqual(LayoutClass(width: 1032), .regular)    // an iPad, full screen
        XCTAssertEqual(LayoutClass(width: 375), .compact, "an iPad in a narrow split is a phone's width")
    }

    func testAListIsAReadableColumnInTheMiddleOfAWideScreen() {
        // 1032 pt of iPad: a 720 pt column with 156 pt each side, not rows stretched across it.
        XCTAssertEqual(LayoutClass.readableMargin(width: 1032), 156)
        XCTAssertEqual(LayoutClass.readableMargin(width: 1400), 340)
        XCTAssertEqual(LayoutClass.readableMargin(width: 721), 0, "half a point isn't a margin")
    }

    func testNothingChangesWhereTheScreenIsNoWiderThanTheColumn() {
        XCTAssertEqual(LayoutClass.readableMargin(width: 402), 0)
        XCTAssertEqual(LayoutClass.readableMargin(width: 720), 0)
        XCTAssertEqual(LayoutClass.readableMargin(width: 0), 0)
    }

    func testAnEventOpensBesideTheCalendarOnlyWhereThereIsRoom() {
        XCTAssertTrue(LayoutClass.opensBeside(width: 1376), "a 13-inch iPad on its side")
        XCTAssertTrue(LayoutClass.opensBeside(width: 1056), "the same with the sidebar showing")
        XCTAssertTrue(LayoutClass.opensBeside(width: 1210), "an 11-inch iPad on its side")
        XCTAssertFalse(LayoutClass.opensBeside(width: 1032), "a 13-inch iPad upright: a sheet")
        XCTAssertFalse(LayoutClass.opensBeside(width: 834), "an 11-inch iPad upright")
        XCTAssertFalse(LayoutClass.opensBeside(width: 932), "a phone on its side")
        XCTAssertFalse(LayoutClass.opensBeside(width: 402), "a phone")
    }
}
