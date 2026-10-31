import CoreLocation
import Foundation

/// A place you confirmed for a calendar location: "Chelsea" means Chelsea Piers Fitness, and
/// you walk there.
///
/// Calendar locations are often a neighbourhood, a brand or a nickname rather than an address.
/// Geocoded as an address, "Chelsea" landed on the neighbourhood's centre a few hundred metres from home and
/// every swim got a 10-minute trip that was really 25. There's no way to tell from the text which
/// Chelsea is meant, so Banana asks once (the place picker) and remembers the answer here. Kept
/// in the synced settings, so answering on the phone fixes the Mac too.
struct SavedPlace: Codable, Equatable, Identifiable, Hashable {
    /// The calendar location text this answers, normalised (`SavedPlace.key`).
    var query: String
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    /// How you get there, when you said. nil = the usual rule (walk if it's close, else your
    /// default).
    var mode: TransitMode?

    var id: String { query }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    init(query: String, name: String, address: String? = nil,
         latitude: Double, longitude: Double, mode: TransitMode? = nil) {
        self.query = Self.key(query)
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.mode = mode
    }

    /// Tolerant: a mode this build doesn't know (added by a newer one) reads as "not set"
    /// rather than failing the whole settings payload.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        mode = try? c.decodeIfPresent(TransitMode.self, forKey: .mode)
    }

    /// "  Chelsea. " and "chelsea" are the same question.
    static func key(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
    }
}

extension Array where Element == SavedPlace {
    func place(for locationText: String?) -> SavedPlace? {
        guard let locationText else { return nil }
        let key = SavedPlace.key(locationText)
        return first { $0.query == key }
    }

    /// Adds or replaces the answer for `place.query`.
    mutating func remember(_ place: SavedPlace) {
        removeAll { $0.query == place.query }
        append(place)
    }
}

/// How sure Banana is about where a trip goes — shown, so a wrong guess can't hide.
enum PlaceConfidence: String, Codable, Hashable {
    /// The event carries coordinates.
    case exact
    /// You picked it.
    case saved
    /// A street address, which the geocoder resolves to one spot.
    case address
    /// A name that could be several places. The trip is timed to a best guess and the place
    /// asks to be confirmed.
    case guessed
}

enum PlaceQuery {
    /// Whether a location reads as a street address (a house number, a postcode) rather than a
    /// name. An address geocodes to one spot; a name — "Chelsea", "Equinox" — can be many
    /// places, so it's timed to a guess and flagged for confirming.
    static func looksLikeAddress(_ text: String) -> Bool {
        text.contains { $0.isNumber }
    }

    /// Stricter than `looksLikeAddress`: a house number and street ("32 W 20th St") or a postcode
    /// ("NY 10011", "EC1A 1BB") — not just any digit, as "Office-10th Floor-CR B (6)" is a meeting
    /// room. Decides whether an event with a video link is still somewhere you go
    /// (`GoogleEventWindow`): Google adds a Meet link to any event you invite someone to.
    static func isStreetAddress(_ text: String) -> Bool {
        let patterns = [
            #"(^|[,\n])\s*\d+[A-Za-z]?(-\d+)?\s+[A-Za-z]"#,   // a part that starts with a house number
            #"\b[A-Z]{2}\s+\d{5}(-\d{4})?\b"#,                // US state and ZIP
            #"\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b"#,         // UK postcode
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// The part of a location worth showing on a block: "Chelsea Piers Fitness, 62 Chelsea
    /// Piers, New York…" → "Chelsea Piers Fitness". Calendar locations also come as lines
    /// ("Bluestone Lane\n62 Chelsea Piers"), so a line break ends the name too.
    static func shortName(_ text: String) -> String {
        let first = text.split(whereSeparator: { $0 == "," || $0.isNewline }).first.map(String.init) ?? text
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One answer to "where is this?", for the place picker.
struct PlaceCandidate: Identifiable, Hashable {
    let name: String
    let subtitle: String?
    let latitude: Double
    let longitude: Double
    let distanceMeters: Double
    /// A business or landmark, as opposed to a bare address or an area.
    var isPointOfInterest = true
    var id: String { "\(name)|\(latitude),\(longitude)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// Most likely first: a place whose name contains the location ("Chelsea Piers Fitness" for
    /// "Chelsea"), then other businesses, then addresses and areas — each nearest first. MapKit
    /// doesn't give every gym a category (Chelsea Recreation Center has none), so the name is
    /// what counts. The bare neighbourhood — named exactly "Chelsea" — is what the old lookup
    /// silently routed to; it stays on the list, but last.
    static func ranked(_ candidates: [PlaceCandidate], for locationText: String) -> [PlaceCandidate] {
        let needle = SavedPlace.key(locationText)
        func tier(_ c: PlaceCandidate) -> Int {
            let name = SavedPlace.key(c.name)
            if !needle.isEmpty && name.contains(needle) && name != needle { return 0 }
            if c.isPointOfInterest && name != needle { return 1 }
            return 2
        }
        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.id).inserted }
            .sorted { (tier($0), $0.distanceMeters) < (tier($1), $1.distanceMeters) }
    }
}

extension PlaceQuery {
    /// What kind of place an event is probably at, from its title — "Lap Swim" → "pool" — so a
    /// search for "Chelsea" can also try "Chelsea pool". A neighbourhood name alone finds only
    /// the neighbourhood; with the hint it finds the gyms in it.
    static func activityHints(forTitle title: String) -> [String] {
        let t = title.lowercased()
        let table: [(words: [String], hints: [String])] = [
            (["swim", "pool", "aqua", "lap "], ["pool"]),
            (["gym", "lift", "strength", "workout", "training", "crossfit", "boxing", "spin", "hiit"], ["gym", "fitness"]),
            (["yoga"], ["yoga"]),
            (["pilates"], ["pilates"]),
            (["climb", "boulder"], ["climbing"]),
            (["tennis"], ["tennis"]),
            (["coffee"], ["coffee"]),
            (["lunch", "dinner", "breakfast", "brunch"], ["restaurant"]),
            (["drinks", "happy hour"], ["bar"]),
            (["doctor", "dr.", "dentist", "physio", "therapy", "appointment"], ["clinic"]),
            (["haircut", "barber", "salon"], ["salon"]),
        ]
        var hints: [String] = []
        for row in table where row.words.contains(where: { t.contains($0) }) {
            for hint in row.hints where !hints.contains(hint) { hints.append(hint) }
        }
        return hints
    }
}

/// "0.3 mi", "1.2 km": one decimal, in the unit the person uses — never "1,698 ft".
enum PlaceDistance {
    static func text(_ meters: Double, locale: Locale = .current) -> String {
        // Road distances are miles in the UK too, though it's otherwise metric.
        let miles = locale.measurementSystem == .us || locale.measurementSystem == .uk
        let value = miles ? meters / 1609.344 : meters / 1000
        let number = value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)).locale(locale))
        return "\(number) \(miles ? "mi" : "km")"
    }
}

/// The kinds of place to search for alongside a location — "pool", "recreation center" — so
/// "Chelsea" finds the gyms in it rather than only the neighbourhood. They come from Apple
/// Intelligence reading the event (`PlaceHintModel`), which understands any wording and any
/// language; the keyword table (`PlaceQuery.activityHints`) is the fallback where it isn't
/// available. Pure, so what reaches the map search is pinned by tests.
enum PlaceSearchHints {
    static let maxTerms = 3

    /// Keeps what a map search can use: short (one to three words), letters and spaces, no
    /// repeat of the location itself, no business names passed off as a kind of place.
    static func sanitize(_ raw: [String], location: String) -> [String] {
        let place = SavedPlace.key(location)
        var out: [String] = []
        for term in raw {
            let cleaned = SavedPlace.key(term.filter { $0.isLetter || $0 == " " || $0 == "-" })
            let words = cleaned.split(separator: " ")
            guard !cleaned.isEmpty, (1...3).contains(words.count), cleaned.count <= 30,
                  cleaned != place, !place.contains(cleaned), !out.contains(cleaned) else { continue }
            out.append(cleaned)
        }
        return Array(out.prefix(maxTerms))
    }

    /// The model's terms first (it read the whole event), then the keyword table's, deduplicated.
    static func merge(model: [String]?, keywords: [String], location: String) -> [String] {
        sanitize((model ?? []) + keywords, location: location)
    }
}

/// Which way you travel on a given trip.
enum TravelModePolicy {
    /// A place you set a mode for keeps it. Otherwise a short hop is a walk — nobody takes a
    /// train or a car 800 m — and anything longer uses your default.
    static func mode(savedMode: TransitMode?, distanceMeters: Double?,
                     settings: SmartScheduleSettings) -> TransitMode {
        if let savedMode { return savedMode }
        if settings.walkShortTrips, let distanceMeters,
           distanceMeters <= Double(settings.walkShortTripMeters) {
            return .walk
        }
        return settings.transitMode
    }
}

/// What a travel block says about itself: "🚶 24 min · Chelsea Piers". Display only — the
/// block's title and identity (which the calendar write-back keys on) never carry it, so a
/// better answer here never renames or recreates an event on anyone's calendar.
struct TravelLegDetail: Codable, Equatable, Hashable {
    var mode: TransitMode
    var minutes: Int
    /// Where the trip goes: the place's name, or "Home".
    var placeName: String?
    /// The calendar location text the place was resolved from — what "Not this place?" asks
    /// about. nil for trips home and for events that carry coordinates.
    var query: String?
    var confidence: PlaceConfidence
    /// Where the trip was timed to, so a mode chosen for an address can be saved against it.
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// Where the minutes come from, when it isn't Apple Maps alone: "Usually 22 min (4 trips)",
    /// "Your walking pace". Shown in Getting there.
    var basis: String? = nil

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }

    var needsConfirming: Bool { confidence == .guessed && query != nil }

    /// "24 min · Chelsea Piers", "10 min · Chelsea?" when it's a guess.
    var summary: String {
        guard let placeName, !placeName.isEmpty else { return "\(minutes) min" }
        return "\(minutes) min · \(placeName)\(needsConfirming ? "?" : "")"
    }
}
