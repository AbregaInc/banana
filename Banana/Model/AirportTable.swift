import Foundation
import CoreLocation

/// A bundled IATA airport table — the key to resolving flights WITHOUT any external flight API.
/// A parsed destination code (or a bare coordinate, via `nearest`) resolves to a city and,
/// crucially, an IANA time zone that comes as a column of the data — no coord→tz computation,
/// no network.
///
/// The table is `Resources/Airports.tsv`: every open airport with an IATA code that is large or
/// medium or has scheduled service (about 5,400), built by `tools/airports/build.py` from
/// OurAirports (public domain) and mwgg/Airports (MIT, for the time zones). It was 81 airports
/// typed in by hand, so a flight through any other came to nothing. Read once, on first use.
struct Airport: Hashable {
    /// How big: a bare "EWR → MIA" between two large airports is a flight by itself; anything
    /// smaller needs something else to say so (`FlightParser`).
    enum Size: String { case large = "L", medium = "M", small = "S" }

    let code: String          // IATA (3 letters, uppercase)
    let latitude: Double
    let longitude: Double
    let tzIdentifier: String  // IANA — the segment time zone for weather sampling
    let city: String
    let country: String       // ISO-3166 alpha-2 — decides the domestic/international flight buffer
    var size: Size = .large
    var scheduled = true

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var timeZone: TimeZone { TimeZone(identifier: tzIdentifier) ?? .current }
}

enum AirportTable {
    /// Resolve an IATA code (case-insensitive) to an airport, or nil if unknown.
    static func lookup(_ code: String) -> Airport? { all[code.uppercased()] }

    /// The nearest airport to a coordinate and its distance in km — turns a bare structured-location
    /// or hotel coordinate into a city + time zone with zero network (the offline coord→tz resolver).
    /// Among airports with scheduled service: an airstrip names a field, not the town you're in.
    static func nearest(to coord: CLLocationCoordinate2D) -> (airport: Airport, distanceKm: Double)? {
        var best: (Airport, Double)?
        // A degree of latitude is 111 km: skip the trigonometry for anything that can't win.
        for a in served {
            if let found = best, abs(a.latitude - coord.latitude) * 111 > found.1 { continue }
            let d = haversineKm(coord.latitude, coord.longitude, a.latitude, a.longitude)
            if best == nil || d < best!.1 { best = (a, d) }
        }
        return best.map { (airport: $0.0, distanceKm: $0.1) }
    }

    /// Airports with scheduled service, for `nearest`.
    private static let served: [Airport] = all.values.filter(\.scheduled)

    static func haversineKm(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let R = 6371.0
        let dLat = (bLat - aLat) * .pi / 180, dLon = (bLon - aLon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(aLat * .pi / 180) * cos(bLat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }

    static let all: [String: Airport] = load(from: resourceBundle)

    /// The bundle holding `Airports.tsv`: the app's, or the test bundle's when the tests run.
    private static var resourceBundle: Bundle {
        if Bundle.main.url(forResource: "Airports", withExtension: "tsv") != nil { return .main }
        return Bundle.allBundles.first { $0.url(forResource: "Airports", withExtension: "tsv") != nil } ?? .main
    }

    /// One airport per line: code, latitude, longitude, time zone, city, country, size, scheduled.
    /// A line that doesn't read is skipped; a missing file is an empty table (no flights found),
    /// never a crash.
    static func load(from bundle: Bundle) -> [String: Airport] {
        guard let url = bundle.url(forResource: "Airports", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: Airport] {
        var table: [String: Airport] = [:]
        table.reserveCapacity(6_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 8, fields[0].count == 3,
                  let latitude = Double(fields[1]), let longitude = Double(fields[2]),
                  let size = Airport.Size(rawValue: String(fields[6])) else { continue }
            let code = String(fields[0])
            table[code] = Airport(code: code, latitude: latitude, longitude: longitude,
                                  tzIdentifier: String(fields[3]), city: String(fields[4]),
                                  country: String(fields[5]), size: size, scheduled: fields[7] == "1")
        }
        return table
    }
}
