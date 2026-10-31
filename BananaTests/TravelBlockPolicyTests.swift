import XCTest

final class TravelBlockPolicyTests: XCTestCase {
    func testRouteDurationRoundsUpToFiveMinutes() {
        XCTAssertEqual(
            TravelBlockPolicy.blockDuration(routeSeconds: 601, fallbackMinutes: nil),
            15 * 60
        )
    }

    func testReturnHomeFallsBackToKnownOutboundDuration() {
        XCTAssertEqual(
            TravelBlockPolicy.blockDuration(routeSeconds: nil, fallbackMinutes: 10),
            10 * 60
        )
    }

    func testMissingRouteAndFallbackDoesNotInventTravel() {
        XCTAssertNil(TravelBlockPolicy.blockDuration(routeSeconds: nil, fallbackMinutes: nil))
        XCTAssertNil(TravelBlockPolicy.blockDuration(routeSeconds: .nan, fallbackMinutes: 0))
    }

    func testCachedOutboundKeepsReturnReservedWhenGapRoutingFails() {
        XCTAssertTrue(TravelBlockPolicy.shouldReserveReturnHome(routedDecision: nil, fallbackMinutes: 10
        , gapToNext: nil))
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(routedDecision: false, fallbackMinutes: 10
        , gapToNext: nil))
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(routedDecision: nil, fallbackMinutes: nil
        , gapToNext: nil))
    }

    func testPTGateIsContinuousFromDepartureThroughReturnHome() throws {
        let appointmentStart = Date(timeIntervalSinceReferenceDate: 810_151_500)
        let appointmentEnd = appointmentStart.addingTimeInterval(50 * 60)
        let outbound = DateInterval(
            start: appointmentStart.addingTimeInterval(-10 * 60),
            end: appointmentStart
        )
        let appointment = DateInterval(start: appointmentStart, end: appointmentEnd)
        let returnHome = try XCTUnwrap(TravelBlockPolicy.returnHomeInterval(
            departingAt: appointmentEnd,
            routeSeconds: nil,
            fallbackMinutes: 10
        ))

        XCTAssertEqual(outbound.end, appointment.start)
        XCTAssertEqual(appointment.end, returnHome.start)
        XCTAssertEqual(returnHome.duration, 10 * 60)
    }

    // MARK: - Reserving a trip home without a route

    /// The bug this guards: two meetings a few minutes and a few hundred feet apart got a full
    /// trip home reserved between them, drawn as a "Travel home" band immediately followed by a
    /// walk back. The old fallback only asked whether the outbound trip took any time at all.
    func testNoTripHomeWhenTheNextMeetingIsTooSoon() {
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: 5, gapToNext: 15 * 60))
    }

    func testTripHomeWhenThereIsRoomToGetHomeAndBack() {
        // 10 minutes each way plus the dwell, with room to spare.
        XCTAssertTrue(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: 10, gapToNext: 20 * 60 + TravelBlockPolicy.minimumHomeDwell + 60))
    }

    func testExactlyEnoughRoomCounts() {
        XCTAssertTrue(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: 10, gapToNext: 20 * 60 + TravelBlockPolicy.minimumHomeDwell))
    }

    /// The day's last physical place always ends at home, however short the outbound trip was.
    func testTheLastMeetingOfTheDayStillGoesHome() {
        XCTAssertTrue(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: 5, gapToNext: nil))
    }

    /// A real route always wins over the estimate, in both directions.
    func testARoutedDecisionOverridesTheFallback() {
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: false, fallbackMinutes: 30, gapToNext: nil))
        XCTAssertTrue(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: true, fallbackMinutes: nil, gapToNext: 60))
    }

    func testNoOutboundEstimateMeansNoReservation() {
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: nil, gapToNext: nil))
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: 0, gapToNext: nil))
    }

    /// Real case from the field: a swim open house 4–5 and a lap swim 4:45–5:30 at the same venue.
    /// The next meeting starts BEFORE this one ends, so the gap is negative and there is obviously
    /// no trip home in between. The old fallback reserved one anyway, because the outbound trip
    /// had taken a few minutes.
    func testOverlappingMeetingsNeverGetATripHomeBetweenThem() {
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: 15, gapToNext: -15 * 60))
    }

    func testBackToBackMeetingsNeverGetATripHomeBetweenThem() {
        XCTAssertFalse(TravelBlockPolicy.shouldReserveReturnHome(
            routedDecision: nil, fallbackMinutes: 15, gapToNext: 0))
    }
}
