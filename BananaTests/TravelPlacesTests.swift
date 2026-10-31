import XCTest

/// Where a trip goes and how you get there.
///
/// A swim at "Chelsea" was timed to the neighbourhood's centre a few hundred metres from home — 10 minutes each
/// way for what is really a 25-minute walk — and nothing on screen said where it had gone. These
/// pin the pieces that fix it: a name is a guess until you confirm it, a confirmed place is
/// remembered, short hops are walks, and the block says all of that.
final class TravelPlacesTests: XCTestCase {

    private func settings(_ change: (inout SmartScheduleSettings) -> Void = { _ in }) -> SmartScheduleSettings {
        var s = SmartScheduleSettings()
        s.transitMode = .transit
        change(&s)
        return s
    }

    func testANameIsAGuessAndAnAddressIsNot() {
        XCTAssertFalse(PlaceQuery.looksLikeAddress("Chelsea"))
        XCTAssertFalse(PlaceQuery.looksLikeAddress("Equinox Hudson Yards"))
        XCTAssertTrue(PlaceQuery.looksLikeAddress("62 Chelsea Piers, New York, NY 10011"))
        XCTAssertEqual(PlaceQuery.shortName("Chelsea Piers Fitness, 62 Chelsea Piers, New York"), "Chelsea Piers Fitness")
    }

    func testAStreetAddressNeedsAHouseNumberOrPostcodeNotJustADigit() {
        for address in ["Main Street Dental, 12 Main St, Springfield, IL 62701, USA", "1221 Lexington Ave",
                        "Bluestone Lane\n62 Chelsea Piers", "Somewhere, London EC1A 1BB", "Office, NY 10011"] {
            XCTAssertTrue(PlaceQuery.isStreetAddress(address), address)
        }
        for name in ["Office-10th Floor-CR B (6)", "Google Meet (instructions in description)",
                     "Microsoft Teams Meeting", "Chelsea", "Room 4B", ""] {
            XCTAssertFalse(PlaceQuery.isStreetAddress(name), name)
        }
    }

    func testAConfirmedPlaceAnswersTheSameTextHoweverItIsTyped() {
        var places: [SavedPlace] = []
        places.remember(SavedPlace(query: "Chelsea", name: "Chelsea Piers Fitness", latitude: 40.74, longitude: -74.01))
        XCTAssertEqual(places.place(for: "  chelsea. ")?.name, "Chelsea Piers Fitness")
        XCTAssertNil(places.place(for: "Chelsea Market"))

        places.remember(SavedPlace(query: "CHELSEA", name: "Chelsea Recreation Center", latitude: 40.75, longitude: -74.0))
        XCTAssertEqual(places.count, 1, "a new answer replaces the old one")
        XCTAssertEqual(places.place(for: "Chelsea")?.name, "Chelsea Recreation Center")
    }

    func testShortHopsAreWalksUnlessThePlaceSaysOtherwise() {
        let s = settings()
        XCTAssertEqual(TravelModePolicy.mode(savedMode: nil, distanceMeters: 800, settings: s), .walk)
        XCTAssertEqual(TravelModePolicy.mode(savedMode: nil, distanceMeters: 4_000, settings: s), .transit)
        XCTAssertEqual(TravelModePolicy.mode(savedMode: .drive, distanceMeters: 800, settings: s), .drive)
        XCTAssertEqual(TravelModePolicy.mode(savedMode: .walk, distanceMeters: 4_000, settings: s), .walk)
        let off = settings { $0.walkShortTrips = false }
        XCTAssertEqual(TravelModePolicy.mode(savedMode: nil, distanceMeters: 800, settings: off), .transit)
    }

    func testTheBlockSaysWhereAndAsksWhenItIsAGuess() {
        let guess = TravelLegDetail(mode: .walk, minutes: 7, placeName: "Chelsea", query: "Chelsea", confidence: .guessed)
        XCTAssertTrue(guess.needsConfirming)
        XCTAssertEqual(guess.summary, "7 min · Chelsea?")
        let sure = TravelLegDetail(mode: .walk, minutes: 24, placeName: "Chelsea Piers Fitness", query: "Chelsea", confidence: .saved)
        XCTAssertFalse(sure.needsConfirming)
        XCTAssertEqual(sure.summary, "24 min · Chelsea Piers Fitness")
        XCTAssertEqual(TravelLegDetail(mode: .transit, minutes: 12, placeName: nil, query: nil, confidence: .exact).summary, "12 min")
    }

    func testPlacesSyncWithTheSettingsAndSurviveAnUnknownMode() throws {
        var s = settings()
        s.savedPlaces = [SavedPlace(query: "Chelsea", name: "Chelsea Piers Fitness", latitude: 40.74, longitude: -74.01, mode: .walk)]
        let back = try JSONDecoder().decode(SmartScheduleSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.savedPlaces, s.savedPlaces)

        // A newer build's mode ("cycle") reads as "not set", and nothing else is lost.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        var places = try XCTUnwrap(json["savedPlaces"] as? [[String: Any]])
        places[0]["mode"] = "cycle"
        json["savedPlaces"] = places
        let newer = try JSONDecoder().decode(SmartScheduleSettings.self,
                                             from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(newer.savedPlaces.first?.name, "Chelsea Piers Fitness")
        XCTAssertNil(newer.savedPlaces.first?.mode)
        XCTAssertEqual(newer.transitMode, .transit)
    }

    func testSettingsFromBeforePlacesExistedKeepTheirValues() throws {
        let old = Data(#"{"enabled":true,"transitMode":"transit"}"#.utf8)
        let s = try JSONDecoder().decode(SmartScheduleSettings.self, from: old)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.savedPlaces, [])
        XCTAssertTrue(s.walkShortTrips)
    }

    func testTheEventTitleSaysWhatKindOfPlaceToLookFor() {
        XCTAssertEqual(PlaceQuery.activityHints(forTitle: "Lap Swim: Up to 3 Per Lane (Circle Swimming)"), ["pool"])
        XCTAssertEqual(PlaceQuery.activityHints(forTitle: "Strength training"), ["gym", "fitness"])
        XCTAssertEqual(PlaceQuery.activityHints(forTitle: "Lunch w/ Sam"), ["restaurant"])
        XCTAssertEqual(PlaceQuery.activityHints(forTitle: "Quarterly review"), [])
    }

    /// The kind of answer MapKit gives for "Chelsea" and "Chelsea pool" (distances made up): the
    /// neighbourhood is what the old lookup routed to; the two gyms are what was meant.
    func testBusinessesNamedForThePlaceComeFirstAndTheBareAreaLast() {
        let area = PlaceCandidate(name: "Chelsea", subtitle: "Chelsea, Manhattan", latitude: 40.746, longitude: -74.001,
                                  distanceMeters: 300, isPointOfInterest: false)
        let bar = PlaceCandidate(name: "Somewhere Nowhere", subtitle: "112 W 25th St", latitude: 40.744, longitude: -73.992,
                                 distanceMeters: 450)
        // No category from MapKit: the name still puts it first.
        let rec = PlaceCandidate(name: "Chelsea Recreation Center", subtitle: "430 W 25th St", latitude: 40.748, longitude: -74.003,
                                 distanceMeters: 700, isPointOfInterest: false)
        let piers = PlaceCandidate(name: "Chelsea Piers Fitness", subtitle: "60 Chelsea Piers", latitude: 40.746, longitude: -74.009,
                                   distanceMeters: 1_200)
        let ranked = PlaceCandidate.ranked([area, bar, piers, rec, rec], for: "Chelsea")
        XCTAssertEqual(ranked.map(\.name), ["Chelsea Recreation Center", "Chelsea Piers Fitness", "Somewhere Nowhere", "Chelsea"])
    }

    func testDistancesAreOneDecimalInTheLocalUnit() {
        XCTAssertEqual(PlaceDistance.text(517, locale: Locale(identifier: "en_US")), "0.3 mi")
        XCTAssertEqual(PlaceDistance.text(1_000, locale: Locale(identifier: "en_GB")), "0.6 mi")
        XCTAssertEqual(PlaceDistance.text(1_000, locale: Locale(identifier: "fr_FR")), "1,0 km")
        XCTAssertEqual(PlaceDistance.text(25_000, locale: Locale(identifier: "de_DE")), "25 km")
    }

    func testALineBreakEndsTheShortName() {
        XCTAssertEqual(PlaceQuery.shortName("Bluestone Lane\n62 Chelsea Piers"), "Bluestone Lane")
    }

    /// What reaches the map search from the model: short kinds of place, never the location
    /// itself, never a sentence.
    func testOnlyShortKindsOfPlaceReachTheSearch() {
        XCTAssertEqual(PlaceSearchHints.sanitize(["Swimming pool", "recreation center", "Chelsea",
                                                  "a place where people swim laps every day", "pool!"],
                                                 location: "Chelsea"),
                       ["swimming pool", "recreation center", "pool"])
        XCTAssertEqual(PlaceSearchHints.sanitize(["gym", "GYM", " gym "], location: "Chelsea"), ["gym"])
    }

    func testTheModelLeadsAndTheKeywordsFillIn() {
        XCTAssertEqual(PlaceSearchHints.merge(model: ["recreation center", "swimming pool"], keywords: ["pool"],
                                              location: "Chelsea"),
                       ["recreation center", "swimming pool", "pool"])
        XCTAssertEqual(PlaceSearchHints.merge(model: nil, keywords: ["gym", "fitness"], location: "Chelsea"),
                       ["gym", "fitness"], "no model: the keyword table, as before")
    }
}
