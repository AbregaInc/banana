import XCTest

final class TravelBlockPolicyTests: XCTestCase {
    func testRouteDurationRoundsUpToFiveMinutes() {
        XCTAssertEqual(
            TravelBlockPolicy.blockDuration(routeSeconds: 601, fallbackMinutes: nil),
            15 * 60
        )
    }

    func testAReservationGrowsWithTheRouteButShrinksOnlyByMoreThanAStep() {
        let five: TimeInterval = 5 * 60, ten: TimeInterval = 10 * 60, fifteen: TimeInterval = 15 * 60
        XCTAssertEqual(TravelBlockPolicy.settledDuration(computed: ten, written: nil), ten, "nothing written yet")
        XCTAssertEqual(TravelBlockPolicy.settledDuration(computed: fifteen, written: ten), fifteen, "longer: grow")
        XCTAssertEqual(TravelBlockPolicy.settledDuration(computed: five, written: ten), ten,
                       "one step shorter is an ETA on a rounding edge, not a shorter trip")
        XCTAssertEqual(TravelBlockPolicy.settledDuration(computed: five, written: fifteen), five, "really shorter")
        XCTAssertEqual(TravelBlockPolicy.settledDuration(computed: ten, written: ten), ten)
    }

    /// A route of about five minutes rounds to 5 on one device and 10 on another (or on the same
    /// device a minute later). Each answer used to rewrite the block and its copies; with the
    /// calendar's reservation as the reference, both devices settle on 10 and stop writing.
    func testTwoDevicesOnARoundingEdgeSettleOnOneReservation() {
        let routes: [[TimeInterval]] = [[299, 301], [301, 299], [298, 302], [302, 297]]   // seconds, per round
        var written: TimeInterval?
        var writes: [Int] = []
        for round in routes {
            var count = 0
            for route in round {
                let computed = TravelBlockPolicy.blockDuration(routeSeconds: route, fallbackMinutes: nil)!
                let wanted = TravelBlockPolicy.settledDuration(computed: computed, written: written)
                if wanted != written { written = wanted; count += 1 }
            }
            writes.append(count)
        }
        XCTAssertEqual(written, 10 * 60)
        XCTAssertEqual(writes, [2, 0, 0, 0], "written once at 5, once grown to 10, then never again")
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
