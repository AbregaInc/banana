import XCTest

final class CalendarWeekEdgeTests: XCTestCase {
    func testOnlyADeliberatePullStartingAtTheEdgePages() {
        XCTAssertEqual(CalendarWeekEdge.page(start: 400, offset: 475, maximum: 400, width: 400,
                                            translation: CGPoint(x: -200, y: 2)), 1)
        XCTAssertEqual(CalendarWeekEdge.page(start: 0, offset: -75, maximum: 400, width: 400,
                                            translation: CGPoint(x: 200, y: 2)), -1)
        XCTAssertNil(CalendarWeekEdge.page(start: 300, offset: 475, maximum: 400, width: 400,
                                          translation: CGPoint(x: -200, y: 2)))
        XCTAssertNil(CalendarWeekEdge.page(start: 400, offset: 420, maximum: 400, width: 400,
                                          translation: CGPoint(x: -40, y: 0)))
        XCTAssertNil(CalendarWeekEdge.page(start: 400, offset: 400, maximum: 400, width: 400,
                                          translation: CGPoint(x: -300, y: 0)))
    }

    func testFullWidthIPadWeekSupportsBothEdges() {
        XCTAssertEqual(CalendarWeekEdge.page(start: 0, offset: 80, maximum: 0, width: 1000,
                                            translation: CGPoint(x: -200, y: 0)), 1)
        XCTAssertEqual(CalendarWeekEdge.page(start: 0, offset: -80, maximum: 0, width: 1000,
                                            translation: CGPoint(x: 200, y: 0)), -1)
    }

    func testVerticalDiagonalReversedAndInvalidPullsDoNotPage() {
        for translation in [CGPoint(x: -100, y: 200), CGPoint(x: -100, y: 100), CGPoint(x: 200, y: 0)] {
            XCTAssertNil(CalendarWeekEdge.page(start: 400, offset: 480, maximum: 400, width: 400,
                                              translation: translation))
        }
        XCTAssertNil(CalendarWeekEdge.page(start: 0, offset: -.infinity, maximum: 0, width: 400,
                                          translation: CGPoint(x: 200, y: 0)))
        XCTAssertNil(CalendarWeekEdge.page(start: 0, offset: -100, maximum: 0, width: 0,
                                          translation: CGPoint(x: 200, y: 0)))
    }
}
