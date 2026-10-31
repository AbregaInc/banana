import CoreLocation
import XCTest

/// The bundled airport table (`Resources/Airports.tsv`, built by `tools/airports/build.py`): it
/// is whole, every row reads, and the airports people fly through say the city and the zone
/// people expect.
final class AirportTableTests: XCTestCase {
    func testTheTableIsThereAndWhole() {
        let all = AirportTable.all
        XCTAssertGreaterThan(all.count, 5_000, "it was 81 airports typed in by hand")
        XCTAssertGreaterThan(all.values.filter { $0.size == .large }.count, 1_000)
        for (code, airport) in all {
            XCTAssertEqual(code, airport.code)
            XCTAssertTrue(code.count == 3 && code.allSatisfy { $0.isUppercase && $0.isLetter }, code)
            XCTAssertTrue((-90...90).contains(airport.latitude) && (-180...180).contains(airport.longitude), code)
            XCTAssertEqual(airport.country.count, 2, code)
            XCTAssertFalse(airport.city.isEmpty, code)
        }
    }

    func testEveryTimeZoneIsOneThisSystemKnows() {
        // `Airport.timeZone` falls back to the device's zone for a name it can't read: a wrong
        // zone that looks right. No row may need the fallback.
        let unknown = AirportTable.all.values.filter { TimeZone(identifier: $0.tzIdentifier) == nil }
        XCTAssertEqual(unknown.map { "\($0.code) \($0.tzIdentifier)" }.sorted(), [])
    }

    func testTheAirportsPeopleFlyThroughSayTheCityAndZonePeopleExpect() {
        let expected: [(String, String, String, String)] = [
            ("JFK", "New York", "America/New_York", "US"), ("LGA", "New York", "America/New_York", "US"),
            ("EWR", "Newark", "America/New_York", "US"), ("BOS", "Boston", "America/New_York", "US"),
            ("ORD", "Chicago", "America/Chicago", "US"), ("DEN", "Denver", "America/Denver", "US"),
            ("PHX", "Phoenix", "America/Phoenix", "US"), ("LAX", "Los Angeles", "America/Los_Angeles", "US"),
            ("SFO", "San Francisco", "America/Los_Angeles", "US"), ("SEA", "Seattle", "America/Los_Angeles", "US"),
            ("HNL", "Honolulu", "Pacific/Honolulu", "US"), ("ANC", "Anchorage", "America/Anchorage", "US"),
            ("MIA", "Miami", "America/New_York", "US"), ("IAD", "Washington", "America/New_York", "US"),
            ("YYZ", "Toronto", "America/Toronto", "CA"), ("MEX", "Mexico City", "America/Mexico_City", "MX"),
            ("LHR", "London", "Europe/London", "GB"), ("STN", "London", "Europe/London", "GB"),
            ("CDG", "Paris", "Europe/Paris", "FR"), ("FRA", "Frankfurt am Main", "Europe/Berlin", "DE"),
            ("AMS", "Amsterdam", "Europe/Amsterdam", "NL"), ("MXP", "Milan", "Europe/Rome", "IT"),
            ("ZAG", "Zagreb", "Europe/Zagreb", "HR"), ("IST", "Istanbul", "Europe/Istanbul", "TR"),
            ("DXB", "Dubai", "Asia/Dubai", "AE"), ("DEL", "Delhi", "Asia/Kolkata", "IN"),
            ("SIN", "Singapore", "Asia/Singapore", "SG"), ("HKG", "Hong Kong", "Asia/Hong_Kong", "HK"),
            ("NRT", "Tokyo", "Asia/Tokyo", "JP"), ("HND", "Tokyo", "Asia/Tokyo", "JP"),
            ("TPE", "Taipei", "Asia/Taipei", "TW"), ("KUL", "Kuala Lumpur", "Asia/Kuala_Lumpur", "MY"),
            ("SYD", "Sydney", "Australia/Sydney", "AU"), ("AKL", "Auckland", "Pacific/Auckland", "NZ"),
            ("GRU", "São Paulo", "America/Sao_Paulo", "BR"), ("EZE", "Buenos Aires", "America/Argentina/Buenos_Aires", "AR"),
            ("JNB", "Johannesburg", "Africa/Johannesburg", "ZA"), ("CAI", "Cairo", "Africa/Cairo", "EG"),
        ]
        for (code, city, zone, country) in expected {
            let airport = AirportTable.lookup(code)
            XCTAssertNotNil(airport, code)
            XCTAssertEqual(airport?.city, city, code)
            XCTAssertEqual(airport?.country, country, code)
            // The same zone, whichever of its names the data uses (Asia/Calcutta is Asia/Kolkata).
            let now = Date()
            XCTAssertEqual(airport?.timeZone.secondsFromGMT(for: now), TimeZone(identifier: zone)?.secondsFromGMT(for: now),
                           "\(code) is in \(airport?.tzIdentifier ?? "nothing"), expected \(zone)")
            XCTAssertEqual(airport?.size, .large, code)
        }
    }

    func testAnAirportThatWasNotInTheHandTypedListIsThere() {
        // The smaller airports a real trip uses were the ones missing.
        for code in ["CLJ", "TSR", "SPU", "DBV", "TTN", "HPN", "ISP", "BZN", "JAC", "EGE", "FAO", "OPO", "BGY", "KEF", "PUJ", "SJD"] {
            XCTAssertNotNil(AirportTable.lookup(code), code)
        }
    }

    func testLookupIgnoresCaseAndUnknownCodesAreNothing() {
        XCTAssertEqual(AirportTable.lookup("jfk")?.code, "JFK")
        XCTAssertNil(AirportTable.lookup("ZZZ"))
        XCTAssertNil(AirportTable.lookup("NYC"), "a city code is not an airport")
    }

    func testAPlaceIsNamedForTheNearestAirportWithScheduledService() {
        func nearest(_ latitude: Double, _ longitude: Double) -> Airport? {
            AirportTable.nearest(to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))?.airport
        }
        XCTAssertEqual(nearest(40.7580, -73.9855)?.city, "New York")          // Times Square
        XCTAssertEqual(nearest(40.7580, -73.9855)?.tzIdentifier, "America/New_York")
        XCTAssertEqual(nearest(45.8150, 15.9819)?.city, "Zagreb")
        XCTAssertEqual(nearest(37.7749, -122.4194)?.timeZone.identifier, "America/Los_Angeles")
        XCTAssertEqual(nearest(35.6762, 139.6503)?.city, "Tokyo")
        for airport in [nearest(40.7580, -73.9855), nearest(51.5074, -0.1278), nearest(-33.8688, 151.2093)] {
            XCTAssertEqual(airport?.scheduled, true)
        }
    }

    func testALineThatDoesNotReadIsSkipped() {
        let table = AirportTable.parse("""
        JFK\t40.6394\t-73.7793\tAmerica/New_York\tNew York\tUS\tL\t1
        bad line
        XX\t1\t2\tUTC\tNowhere\tUS\tL\t1
        LHR\tnorth\t-0.4599\tEurope/London\tLondon\tGB\tL\t1
        TTN\t40.2767\t-74.8135\tAmerica/New_York\tTrenton\tUS\tM\t0
        """)
        XCTAssertEqual(table.keys.sorted(), ["JFK", "TTN"])
        XCTAssertEqual(table["TTN"]?.size, .medium)
        XCTAssertEqual(table["TTN"]?.scheduled, false)
    }
}
