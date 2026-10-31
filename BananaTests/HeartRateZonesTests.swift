import XCTest

/// Time in heart-rate zones, from your own maximum.
final class HeartRateZonesTests: XCTestCase {
    func testMaxComesFromYourPeaksButNeverSinksTooLow() {
        XCTAssertEqual(HeartRateZones.estimatedMax(peaks: [176, 188, 181]), 188)
        XCTAssertEqual(HeartRateZones.estimatedMax(peaks: [150, 145]), 170, "easy weeks don't shrink the scale")
        XCTAssertEqual(HeartRateZones.estimatedMax(peaks: [255, 180]), 180, "a sensor glitch isn't a maximum")
    }

    func testReadingsLandInTheRightZone() {
        XCTAssertEqual(HeartRateZones.zone(of: 80, max: 200), 0, "below zone 1 counts as zone 1")
        XCTAssertEqual(HeartRateZones.zone(of: 125, max: 200), 1)
        XCTAssertEqual(HeartRateZones.zone(of: 150, max: 200), 2)
        XCTAssertEqual(HeartRateZones.zone(of: 185, max: 200), 4)
    }

    func testTimeAddsUpAndGapsAreCapped() {
        let samples = [HRPoint(t: 0, bpm: 150), HRPoint(t: 10, bpm: 150), HRPoint(t: 20, bpm: 185),
                       HRPoint(t: 200, bpm: 150)]   // a 180 s dropout after the 185
        let totals = HeartRateZones.timeInZones(samples, max: 200)
        XCTAssertEqual(totals[2], 20)
        XCTAssertEqual(totals[4], 30, "the dropout counts only 30 s")
        XCTAssertEqual(totals.reduce(0, +), 50)
    }

    func testRangesForLabels() {
        let ranges = HeartRateZones.ranges(max: 200)
        XCTAssertEqual(ranges[0].lower, 100)
        XCTAssertEqual(ranges[0].upper, 119)
        XCTAssertNil(ranges[4].upper)
    }
}
