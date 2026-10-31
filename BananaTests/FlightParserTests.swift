import XCTest

/// Which calendar events are flights, and from where to where (`FlightParser`). With every
/// airport in the table, three capital letters are an airport more often than not, so the
/// look-alikes matter as much as the flights.
final class FlightParserTests: XCTestCase {
    private func parse(_ title: String, location: String? = nil, notes: String? = nil) -> FlightParser.Result? {
        FlightParser.parse(title: title, location: location, notes: notes)
    }

    private func route(_ title: String, location: String? = nil, notes: String? = nil) -> String? {
        parse(title, location: location, notes: notes).map { "\($0.origin?.code ?? "?")-\($0.destination.code)" }
    }

    // MARK: Flights

    func testAnAirlinesOrATripPlannersEvent() {
        XCTAssertEqual(route("UA857 EWR to MIA"), "EWR-MIA")
        XCTAssertEqual(route("United Airlines flight UA 857", notes: "Newark (EWR) to Miami (MIA)\nConfirmation ABC123"), "EWR-MIA")
        XCTAssertEqual(route("Flight: New York (JFK) – London (LHR)", notes: "BA 178"), "JFK-LHR")
    }

    func testGooglesOwnFlightEvent() {
        // The city in the title, the airport you leave from in the location.
        XCTAssertEqual(route("Flight to Miami (UA 1234)", location: "Newark EWR"), "EWR-MIA")
        XCTAssertEqual(route("Flight to London (BA 178)", location: "New York JFK"), "JFK-LHR")
    }

    func testARouteYouTypedYourself() {
        XCTAssertEqual(route("EWR → MIA"), "EWR-MIA")
        XCTAssertEqual(route("EWR-MIA"), "EWR-MIA")
        XCTAssertEqual(route("✈ SFO > JFK"), "SFO-JFK")
        XCTAssertEqual(route("EWR → DEN"), "EWR-DEN", "one everyday code beside a plain one is still a route")
    }

    func testAnAirlineWhoseCodeHasADigit() {
        // "B6", "U2", "W6": a pattern of two letters never saw these as flight numbers.
        XCTAssertEqual(route("B6 623 to Boston", location: "JFK"), "JFK-BOS")
        XCTAssertEqual(route("W6 2314 CLJ → LTN"), "CLJ-LTN")
        XCTAssertNotNil(parse("U2 8123 to Nice", location: "LGW"))
    }

    func testAirportsThatWereNotInTheHandTypedList() {
        XCTAssertEqual(route("Flight TSR-OTP"), "TSR-OTP")
        XCTAssertEqual(route("OU 652 ZAG - SPU"), "ZAG-SPU")
        XCTAssertEqual(route("Flight TTN → PVD"), "TTN-PVD", "a medium airport, with the word that says flight")
    }

    func testAFlightFromJacksonStillCounts() {
        // JAN reads as a month, so the route alone isn't enough; the flight number makes it one.
        XCTAssertEqual(route("DL 1234 JAN → ATL"), "JAN-ATL")
    }

    func testACityIsTheSameAirportEveryTime() {
        // It was whichever airport the dictionary happened to list first for the city.
        for _ in 0..<5 {
            XCTAssertEqual(parse("Flight to London (BA 178)")?.destination.code, "LHR")
            XCTAssertEqual(parse("Flight to New York (DL 44)")?.destination.code, "JFK")
            XCTAssertEqual(parse("Flight to Tokyo (NH 9)")?.destination.code, "HND")
        }
    }

    func testTheLongestCityWins() {
        XCTAssertEqual(parse("Flight to San José del Cabo (AS 1392)")?.destination.code, "SJD")
        XCTAssertEqual(parse("Flight to San Jose (AS 334)")?.destination.code, "SJC")
        XCTAssertEqual(parse("Flight to Sao Paulo (LA 8181)")?.destination.code, "GRU", "accents don't matter")
    }

    func testAnInternationalFlightKnowsItsCountries() {
        let flight = parse("BA 178 JFK → LHR")
        XCTAssertEqual(flight?.origin?.country, "US")
        XCTAssertEqual(flight?.destination.country, "GB")
        XCTAssertEqual(flight?.destination.timeZone.identifier, "Europe/London")
    }

    // MARK: Not flights

    func testMonthsAndWeekdaysAreNotRoutes() {
        XCTAssertNil(parse("JAN-MAR budget review"))
        XCTAssertNil(parse("SAT - SUN: cabin"))
        XCTAssertNil(parse("Coverage MON to FRI"))
        XCTAssertNil(parse("JAN-MAR flight budget"), "the word alone doesn't make a quarter a flight")
    }

    func testEverydayCapitalsAreNotRoutes() {
        XCTAssertNil(parse("USA - CAN"))
        XCTAssertNil(parse("API - SDK sync"))
        XCTAssertNil(parse("SEA-DEN"), "two everyday codes with nothing else: not enough")
    }

    func testOneCodeWithNothingElseIsNotAFlight() {
        XCTAssertNil(parse("SFO parking"))
        XCTAssertNil(parse("Pick up at JFK"))
        XCTAssertNil(parse("Lunch", location: "EWR"))
    }

    func testAVideoCallIsNotAFlight() {
        XCTAssertNil(parse("MIA → NYC sync", location: "https://zoom.us/j/123"))
        XCTAssertNil(parse("EWR-MIA planning", location: "https://meet.google.com/abc-defg-hij"))
    }

    func testAPersonIsNotACity() {
        XCTAssertNil(parse("Talk to Austin about the United flight"), "the flight word comes after: Austin is who you talk to")
        XCTAssertNil(parse("Send deck to Sydney"))
        XCTAssertNil(parse("Intro to Phoenix team"))
    }

    func testNumbersThatAreNotFlightNumbers() {
        XCTAssertNil(parse("10 AM 2026 planning to Boston"), "AM after a time is the morning")
        XCTAssertNil(parse("Review PR 1234"), "no destination")
        XCTAssertNil(parse("Room AB 12 to Chicago"), "AB is no airline here")
    }

    func testOrdinaryEvents() {
        for title in ["Standup", "Dentist", "Lunch with Sam", "Q3 planning", "Gym", "Call mom", "1:1",
                      "Drive to Boston", "Train to London", "Move to Denver", "Welcome to Miami party"] {
            XCTAssertNil(parse(title), title)
        }
    }

    // MARK: How much a route says

    func testHowMuchARouteSaysByItself() throws {
        func airport(_ code: String) throws -> Airport { try XCTUnwrap(AirportTable.lookup(code), code) }
        XCTAssertEqual(FlightParser.strength(of: try airport("EWR"), to: try airport("MIA")), 3)
        XCTAssertEqual(FlightParser.strength(of: try airport("TTN"), to: try airport("PVD")), 2, "one of them isn't large")
        XCTAssertEqual(FlightParser.strength(of: try airport("JAN"), to: try airport("ATL")), 1, "a month")
        XCTAssertEqual(FlightParser.strength(of: try airport("SAT"), to: try airport("SUN")), 1, "weekdays")
        XCTAssertEqual(FlightParser.strength(of: try airport("USA"), to: try airport("CAN")), 1, "everyday capitals")
        XCTAssertEqual(FlightParser.strength(of: try airport("EWR"), to: try airport("DEN")), 3)
    }
}
