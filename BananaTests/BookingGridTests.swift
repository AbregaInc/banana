import XCTest

/// New bookings start on the hour or the half hour.
final class BookingGridTests: XCTestCase {

    private func nearest(_ minutes: Double) -> Int {
        BookingGrid.snappedStartMinutes(minutes, rounding: .nearest)
    }
    private func down(_ minutes: Double) -> Int {
        BookingGrid.snappedStartMinutes(minutes, rounding: .down)
    }

    func testAClickTakesTheNearestSlot() {
        XCTAssertEqual(nearest(14 * 60 + 20), 14 * 60 + 30)
        XCTAssertEqual(nearest(14 * 60 + 5), 14 * 60)
        XCTAssertEqual(nearest(14 * 60 + 50), 15 * 60)
    }

    func testAlreadyOnASlotIsLeftAlone() {
        XCTAssertEqual(nearest(9 * 60), 9 * 60)
        XCTAssertEqual(nearest(9 * 60 + 30), 9 * 60 + 30)
        XCTAssertEqual(down(9 * 60 + 30), 9 * 60 + 30)
    }

    /// A drag rounds its start DOWN so the block always covers where the press began. Rounding it
    /// forward would leave the gesture starting outside the event it just drew.
    func testADragStartRoundsDown() {
        XCTAssertEqual(down(14 * 60 + 50), 14 * 60 + 30)
        XCTAssertEqual(down(14 * 60 + 20), 14 * 60)
        XCTAssertEqual(down(14 * 60 + 29), 14 * 60)
    }

    func testNothingLandsOffAFiveMinuteOrOddMark() {
        for raw in stride(from: 0.0, through: 24 * 60, by: 7) {
            for value in [nearest(raw), down(raw)] {
                XCTAssertEqual(value % BookingGrid.startStepMinutes, 0,
                               "\(raw) snapped to \(value), which is not an hour or half hour")
            }
        }
    }

    /// Rounding up near midnight must not spill into the next day.
    func testLateEveningIsClamped() {
        XCTAssertEqual(nearest(23 * 60 + 50), BookingGrid.lastStartMinuteOfDay)
        XCTAssertEqual(nearest(24 * 60), BookingGrid.lastStartMinuteOfDay)
        XCTAssertLessThanOrEqual(nearest(23 * 60 + 59), 23 * 60 + 30)
    }

    func testNegativeAndZeroAreFloored() {
        XCTAssertEqual(nearest(-30), 0)
        XCTAssertEqual(down(0), 0)
    }

    // MARK: - Grid geometry

    func testYPositionConvertsThroughHourHeight() {
        // 56 pt per hour: 2.4 hours down is 2:24, which is nearest to 2:30.
        XCTAssertEqual(BookingGrid.snappedStartMinutes(atY: 56 * 2.4, hourHeight: 56, rounding: .nearest),
                       2 * 60 + 30)
        XCTAssertEqual(BookingGrid.snappedStartMinutes(atY: 56 * 2.4, hourHeight: 56, rounding: .down),
                       2 * 60)
    }

    func testAZeroHourHeightCannotDivideByZero() {
        XCTAssertEqual(BookingGrid.snappedStartMinutes(atY: 100, hourHeight: 0, rounding: .nearest), 0)
    }

    func testSnappedStartBuildsADateOnTheRequestedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_757_000_000)
        // 3.4 hours down the grid is 3:24, whose nearest slot is 3:30.
        let start = BookingGrid.snappedStart(on: day, atY: 56 * 3.4, hourHeight: 56,
                                             rounding: .nearest, calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute], from: start)
        XCTAssertEqual(parts.hour, 3)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertTrue(calendar.isDate(start, inSameDayAs: day))
    }

    // MARK: - Dragging out a length

    /// A dragged NEW booking sizes in quarter hours. Existing events still move on the finer
    /// five-minute grid — that is adjusting something, not choosing a length.
    func testADraggedEndSnapsToQuarterHours() {
        for raw in stride(from: 1.0, through: 8 * 60, by: 3.0) {
            XCTAssertEqual(BookingGrid.snappedEndMinutes(raw) % BookingGrid.dragStepMinutes, 0,
                           "\(raw) snapped to \(BookingGrid.snappedEndMinutes(raw))")
        }
    }

    /// Always upward, so the block covers everything the drag swept rather than stopping short.
    func testADraggedEndRoundsUp() {
        XCTAssertEqual(BookingGrid.snappedEndMinutes(1), 15)
        XCTAssertEqual(BookingGrid.snappedEndMinutes(16), 30)
        XCTAssertEqual(BookingGrid.snappedEndMinutes(44), 45)
    }

    func testAnExactQuarterHourIsLeftAlone() {
        XCTAssertEqual(BookingGrid.snappedEndMinutes(30), 30)
        XCTAssertEqual(BookingGrid.snappedEndMinutes(60), 60)
    }

    /// Start and end use different grids on purpose: a 2:30 start with a 45-minute drag is a
    /// booking, a 2:35 start is a mistake.
    func testStartAndEndUseTheirOwnGrids() {
        XCTAssertEqual(BookingGrid.startStepMinutes, 30)
        XCTAssertEqual(BookingGrid.dragStepMinutes, 15)
    }

    func testADraggedEndCannotSpillPastMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_757_000_000)
        let end = BookingGrid.snappedEnd(on: day, atY: 56 * 30, hourHeight: 56, calendar: calendar)
        XCTAssertLessThanOrEqual(end.timeIntervalSince(calendar.startOfDay(for: day)), 24 * 3600)
    }
}
