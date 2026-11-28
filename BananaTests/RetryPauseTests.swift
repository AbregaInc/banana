import XCTest

final class RetryPauseTests: XCTestCase {
    func testThePauseStartsShortDoublesAndStopsAtTheCap() {
        XCTAssertEqual(RetryPause.delay(streak: 1), 5)
        XCTAssertEqual(RetryPause.delay(streak: 2), 10)
        XCTAssertEqual(RetryPause.delay(streak: 3), 20)
        XCTAssertEqual(RetryPause.delay(streak: 6), 160)
        XCTAssertEqual(RetryPause.delay(streak: 7), 300)
        XCTAssertEqual(RetryPause.delay(streak: 500), 300)
        // Nothing before the first refusal, and nothing odd breaks it.
        XCTAssertEqual(RetryPause.delay(streak: 0), 5)
        XCTAssertEqual(RetryPause.delay(streak: -3), 5)
    }

    func testTheServicesOwnWaitCountsOnlyWhenItIsLonger() {
        XCTAssertEqual(RetryPause.delay(streak: 1, hint: 60), 60)
        XCTAssertEqual(RetryPause.delay(streak: 3, hint: 2), 20)
        for bad in [-5, 0, .infinity, .nan] as [TimeInterval] {
            XCTAssertEqual(RetryPause.delay(streak: 2, hint: bad), 10, "\(bad)")
        }
        // A hint cannot hold a device for hours.
        XCTAssertEqual(RetryPause.delay(streak: 1, hint: 86_400), 300)
    }

    func testJitterSpreadsDevicesApartAndNeverPastACapAndAQuarter() {
        XCTAssertEqual(RetryPause.delay(streak: 1, jitter: 1.25), 6.25)
        XCTAssertEqual(RetryPause.delay(streak: 99, jitter: 1.25), 375)
        XCTAssertEqual(RetryPause.delay(streak: 1, jitter: 0.1), 5, "jitter only ever adds")
        for _ in 0..<200 { XCTAssertTrue((1...1.25).contains(RetryPause.jitter())) }
    }

    func testOneRefusalPausesEveryChangeAndAnAcceptedOneEndsIt() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        var gate = OperationBackoff()
        XCTAssertNil(gate.remaining(at: t))
        gate.refused(at: t)
        XCTAssertEqual(gate.remaining(at: t), 5)
        XCTAssertEqual(gate.remaining(at: t.addingTimeInterval(4.5)) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(gate.remaining(at: t.addingTimeInterval(5)))
        // Refused again straight after: twice as long.
        gate.refused(at: t.addingTimeInterval(5))
        XCTAssertEqual(gate.remaining(at: t.addingTimeInterval(5)), 10)
        gate.accepted()
        XCTAssertNil(gate.remaining(at: t.addingTimeInterval(5)))
        gate.refused(at: t.addingTimeInterval(6))
        XCTAssertEqual(gate.remaining(at: t.addingTimeInterval(6)), 5, "the streak started over")
    }
}
