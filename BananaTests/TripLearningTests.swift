import CoreLocation
import XCTest

/// Learning how long your trips really take.
final class TripLearningTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let home = CLLocationCoordinate2D(latitude: 40.7438, longitude: -75.1988)
    private let gym = CLLocationCoordinate2D(latitude: 40.7465, longitude: -75.2086)   // ~870 m away

    private func visit(_ c: CLLocationCoordinate2D, arrive: Double, leave: Double?) -> VisitRecord {
        VisitRecord(latitude: c.latitude, longitude: c.longitude,
                    arrival: t0.addingTimeInterval(arrive * 60), departure: leave.map { t0.addingTimeInterval($0 * 60) })
    }

    func testConsecutiveVisitsBecomeTrips() {
        let visits = [visit(home, arrive: 0, leave: 60), visit(gym, arrive: 82, leave: 150), visit(home, arrive: 170, leave: nil)]
        let trips = TripLearning.trips(from: visits) { _, _ in .walk }
        XCTAssertEqual(trips.count, 2)
        XCTAssertEqual(trips[0].seconds, 22 * 60)
        XCTAssertEqual(trips[1].seconds, 20 * 60)
    }

    func testShortHopsLongGapsAndUnknownModesAreNotTrips() {
        let nextDoor = CLLocationCoordinate2D(latitude: 40.7439, longitude: -75.1989)
        XCTAssertTrue(TripLearning.trips(from: [visit(home, arrive: 0, leave: 10), visit(nextDoor, arrive: 12, leave: nil)]) { _, _ in .walk }.isEmpty)
        XCTAssertTrue(TripLearning.trips(from: [visit(home, arrive: 0, leave: 10), visit(gym, arrive: 300, leave: nil)]) { _, _ in .walk }.isEmpty)
        XCTAssertTrue(TripLearning.trips(from: [visit(home, arrive: 0, leave: 10), visit(gym, arrive: 30, leave: nil)]) { _, _ in nil }.isEmpty)
    }

    func testTheMotionSaysHowYouWent() {
        XCTAssertEqual(TripLearning.mode(from: [.walking: 900, .automotive: 60], defaultMode: .transit), .walk)
        XCTAssertEqual(TripLearning.mode(from: [.automotive: 900], defaultMode: .transit), .transit)
        XCTAssertEqual(TripLearning.mode(from: [.automotive: 900], defaultMode: .walk), .drive)
        XCTAssertNil(TripLearning.mode(from: [.walking: 20], defaultMode: .transit), "too little signal")
        XCTAssertNil(TripLearning.mode(from: [.cycling: 900], defaultMode: .transit))
    }

    func testYourUsualTimeBeatsTheEstimateOnceThereIsEnough() {
        var learned = LearnedTravel()
        var ratios: [String: [Double]] = [:]
        let key = TripLearning.placeKey(gym)
        for minutes in [22.0, 25, 24] {
            let trip = ObservedTrip(from: home, to: gym, departure: t0, arrival: t0.addingTimeInterval(minutes * 60), mode: .walk)
            TripLearning.learn(trip, estimate: 20 * 60, destinationKey: key, into: &learned, recentRatios: &ratios)
        }
        let adjusted = TripLearning.adjusted(10 * 60, mode: .walk, placeKey: key, learned: learned)
        XCTAssertEqual(adjusted.seconds, 24 * 60, "the median of what you actually took")
        XCTAssertEqual(adjusted.source, .observed(3))
        // Elsewhere, the estimate at your pace: 24/20 = 1.2× Apple Maps.
        let elsewhere = TripLearning.adjusted(10 * 60, mode: .walk, placeKey: nil, learned: learned)
        XCTAssertEqual(elsewhere.seconds, 12 * 60, accuracy: 1)
        // And nothing learned for driving yet.
        XCTAssertEqual(TripLearning.adjusted(600, mode: .drive, placeKey: nil, learned: learned).source, .estimate)
    }

    func testATripWithAStopInItDoesNotSetThePace() {
        var learned = LearnedTravel()
        var ratios: [String: [Double]] = [:]
        let trip = ObservedTrip(from: home, to: gym, departure: t0, arrival: t0.addingTimeInterval(90 * 60), mode: .walk)
        TripLearning.learn(trip, estimate: 20 * 60, destinationKey: nil, into: &learned, recentRatios: &ratios)
        XCTAssertNil(learned.factors["walk"])
    }

    func testANearbyArrivalFindsTheSamePlace() {
        var learned = LearnedTravel()
        learned.placeMinutes[TripLearning.placeKey(gym)] = ["walk": [22, 24]]
        let sameDoor = CLLocationCoordinate2D(latitude: gym.latitude + 0.0004, longitude: gym.longitude)   // ~45 m
        XCTAssertEqual(TripLearning.nearestPlaceKey(to: sameDoor, in: learned), TripLearning.placeKey(gym))
        XCTAssertNil(TripLearning.nearestPlaceKey(to: home, in: learned))
    }

    func testLearnedTravelSurvivesSyncAndGarbage() throws {
        var learned = LearnedTravel()
        learned.factors["walk"] = 1.1
        learned.factorSamples["walk"] = 4
        var settings = SmartScheduleSettings()
        settings.learnedTravel = learned
        let back = try JSONDecoder().decode(SmartScheduleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.learnedTravel, learned)
        let broken = Data(#"{"learnedTravel":{"factors":"nonsense"},"enabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SmartScheduleSettings.self, from: broken)
        XCTAssertTrue(decoded.enabled, "a bad summary never costs the rest of the settings")
        XCTAssertEqual(decoded.learnedTravel.factors, [:])
    }
}
