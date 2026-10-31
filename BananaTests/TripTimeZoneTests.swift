import XCTest

final class TripTimeZoneTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let toronto = TimeZone(identifier: "America/Toronto")!
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    private func day(_ d: Int, _ hour: Int = 12) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = newYork
        return c.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))!
    }

    private func week(from d: Int) -> DateInterval {
        DateInterval(start: day(d, 0), end: day(d + 7, 0))
    }

    private var berlinTrip: [TripTimeZone.Flight] {
        [TripTimeZone.Flight(departs: day(5, 18), arrives: day(6, 2), zone: berlin),
         TripTimeZone.Flight(departs: day(10, 6), arrives: day(10, 14), zone: newYork)]
    }

    func testPlanningFromHomeShowsTheDestination() {
        let zone = TripTimeZone.secondaryZone(visible: week(from: 5), flights: berlinTrip,
                                              home: newYork, current: newYork)
        XCTAssertEqual(zone?.identifier, "Europe/Berlin")
    }

    func testAWeekWithoutTheTripHasOneColumn() {
        XCTAssertNil(TripTimeZone.secondaryZone(visible: week(from: 19), flights: berlinTrip,
                                                home: newYork, current: newYork))
    }

    func testAwayShowsHome() {
        let zone = TripTimeZone.secondaryZone(visible: week(from: 5), flights: berlinTrip,
                                              home: newYork, current: berlin)
        XCTAssertEqual(zone?.identifier, "America/New_York")
    }

    func testATripOnTheSameClockIsNotATimeZoneTrip() {
        let toToronto = [TripTimeZone.Flight(departs: day(5, 9), arrives: day(5, 11), zone: toronto)]
        XCTAssertTrue(TripTimeZone.stays(flights: toToronto, home: newYork).isEmpty)
        XCTAssertNil(TripTimeZone.secondaryZone(visible: week(from: 5), flights: toToronto,
                                                home: newYork, current: newYork))
    }

    func testAStayEndsWhenTheNextFlightLeaves() {
        let stays = TripTimeZone.stays(flights: berlinTrip, home: newYork)
        XCTAssertEqual(stays.count, 1, "the flight home is not a stay")
        XCTAssertEqual(stays.first?.interval, DateInterval(start: day(6, 2), end: day(10, 6)))
    }

    func testNoFlightHomeYetAssumesTwoWeeks() {
        let oneWay = [TripTimeZone.Flight(departs: day(5, 18), arrives: day(6, 2), zone: berlin)]
        let stay = try! XCTUnwrap(TripTimeZone.stays(flights: oneWay, home: newYork).first)
        XCTAssertEqual(stay.interval.duration, TripTimeZone.openEndedStay)
    }

    func testTheLongerStayWinsTheColumn() {
        let twoStops = [
            TripTimeZone.Flight(departs: day(5, 18), arrives: day(6, 2), zone: berlin),
            TripTimeZone.Flight(departs: day(6, 20), arrives: day(7, 8), zone: kolkata),
            TripTimeZone.Flight(departs: day(11, 1), arrives: day(11, 12), zone: newYork),
        ]
        let zone = TripTimeZone.secondaryZone(visible: week(from: 5), flights: twoStops,
                                              home: newYork, current: newYork)
        XCTAssertEqual(zone?.identifier, "Asia/Kolkata")
    }

    func testLabelsReadInTheOtherZone() {
        var primary = Calendar(identifier: .gregorian)
        primary.timeZone = newYork
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(TripTimeZone.label(forHour: 9, on: day(6), primary: primary, zone: berlin, locale: en), "3\u{202F}PM")
        XCTAssertEqual(TripTimeZone.label(forHour: 9, on: day(6), primary: primary, zone: kolkata, locale: en), "6:30\u{202F}PM",
                       "a part-hour offset shows its minutes")
    }

    func testShortNames() {
        XCTAssertTrue(["CEST", "Berlin"].contains(TripTimeZone.shortName(berlin, at: day(6))))
        XCTAssertFalse(TripTimeZone.shortName(kolkata, at: day(6)).isEmpty)
    }
}
