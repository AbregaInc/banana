import XCTest

final class WorkoutCleanupTests: XCTestCase {
    private let own = "com.boris.banana"
    private let t0 = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private func workout(_ source: String, bundle: String? = nil, start: TimeInterval = 0, minutes: Double = 40,
                         activity: String = "Running", distance: Double? = nil, hr: Double? = nil,
                         energy: Double? = 300) -> HealthWorkout {
        var w = HealthWorkout()
        w.activity = activity
        w.start = t0.addingTimeInterval(start)
        w.end = w.start.addingTimeInterval(minutes * 60)
        w.duration = minutes * 60
        w.source = source
        w.sourceBundleID = bundle
        w.distanceMeters = distance
        w.avgHeartRate = hr
        w.energyKcal = energy
        return w
    }

    // MARK: Which copy to show

    func testTheRecorderBeatsTheAppsThatCopyIt() {
        let watch = workout("Sam’s Apple\u{00A0}Watch", distance: 8000, hr: 150)
        let whoop = workout("WHOOP")
        let strava = workout("Strava", distance: 8000, hr: 150)
        XCTAssertTrue(WorkoutSourcePreference.prefers(watch, over: whoop, ownBundleID: own))
        XCTAssertTrue(WorkoutSourcePreference.prefers(watch, over: strava, ownBundleID: own))
        XCTAssertTrue(WorkoutSourcePreference.prefers(strava, over: whoop, ownBundleID: own))
        XCTAssertTrue(WorkoutSourcePreference.prefers(workout("Banana", bundle: own), over: watch, ownBundleID: own))
    }

    func testWithinOneSourceTheCompleteCopyWins() {
        let withDistance = workout("Banana", bundle: own, distance: 2150, hr: 129)
        let without = workout("Banana", bundle: own, hr: 129)
        XCTAssertTrue(WorkoutSourcePreference.prefers(withDistance, over: without, ownBundleID: own))
        XCTAssertFalse(WorkoutSourcePreference.prefers(without, over: withDistance, ownBundleID: own))
    }

    func testTheMergedRowShowsThePreferredCopyWhateverOrderTheyArrive() {
        let whoop = workout("WHOOP")
        let watch = workout("Sam’s Apple\u{00A0}Watch", distance: 8000, hr: 150)
        for order in [[whoop, watch], [watch, whoop]] {
            let rows = WorkoutEntry.merge(summaries: [], health: order, ownBundleID: own)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.health?.source, watch.source)
            XCTAssertEqual(rows.first?.distanceMeters, 8000)
        }
    }

    // MARK: Banana's own duplicate saves

    func testOwnDoubleSavesAreFoundAndTheCompleteOneKept() {
        let a = workout("Banana", bundle: own, activity: "Swimming", distance: 2150, hr: 129)
        let b = workout("Banana", bundle: own, activity: "Swimming", hr: 129)
        let groups = OwnWorkoutDuplicates.groups(in: [b, a, workout("WHOOP", activity: "Swimming")], ownBundleID: own)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.keep.id, a.id)
        XCTAssertEqual(groups.first?.remove.map(\.id), [b.id])
    }

    func testOnlyBananasOwnCopiesAreEverOfferedForDeletion() {
        let groups = OwnWorkoutDuplicates.groups(in: [
            workout("Banana", bundle: "com.boris.banana.watchkitapp"),
            workout("Banana", bundle: "com.boris.banana.watchkitapp"),
            workout("WHOOP", bundle: "com.whoop.iphone"),
            workout("Strava"),
        ], ownBundleID: own)
        XCTAssertTrue(groups.isEmpty)
    }

    func testBackToBackWorkoutsAreNotDuplicates() {
        let groups = OwnWorkoutDuplicates.groups(in: [
            workout("Banana", bundle: own, start: 0, minutes: 30),
            workout("Banana", bundle: own, start: 1, minutes: 45),          // different end
            workout("Banana", bundle: own, start: 0, minutes: 30, activity: "Walking"),
        ], ownBundleID: own)
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: Pool length

    private func swim(pool: Double?, distance: Double, laps: [TimeInterval] = []) -> FitnessSessionSummary {
        FitnessSessionSummary(session: FitnessSession(
            id: UUID(), start: t0, end: t0.addingTimeInterval(2400), activity: "Pool Swim",
            totalDistance: distance, poolLengthMeters: pool,
            laps: laps.enumerated().map { FitnessLap(number: $0.offset + 1, duration: $0.element) },
            samples: []))
    }

    func testFiftyMetreSwimsAreCandidatesAndTwentyFiveYardSwimsAreNot() {
        let candidates = PoolLengthCorrection.candidates([
            swim(pool: 50, distance: 3300, laps: Array(repeating: 39, count: 66)),
            swim(pool: 22.86, distance: 1646),
            swim(pool: nil, distance: 2150),          // old build, whole 50 m lengths
            swim(pool: nil, distance: 1234.44),       // old build, not 50 m lengths
        ])
        XCTAssertEqual(candidates.count, 2)
        let first = try! XCTUnwrap(candidates.first { $0.recordedLength == 50 })
        XCTAssertEqual(first.lapCount, 66)
        XCTAssertEqual(first.medianLap, 39)
        XCTAssertEqual(first.correctedDistance, 66 * 22.86, accuracy: 0.01)
    }

    func testCorrectionScalesEveryDistanceAndKeepsTheLaps() {
        let session = FitnessSession(
            id: UUID(), start: t0, end: t0.addingTimeInterval(2400), activity: "Pool Swim",
            totalDistance: 3300, poolLengthMeters: 50,
            laps: [FitnessLap(number: 1, duration: 39)],
            samples: [FitnessSample(t: 10, kind: .distance, v1: 50),
                      FitnessSample(t: 20, kind: .distance, v1: 3300),
                      FitnessSample(t: 20, kind: .heartRate, v1: 130)])
        let fixed = PoolLengthCorrection.corrected(session)
        XCTAssertEqual(fixed.poolLengthMeters, 22.86)
        XCTAssertEqual(fixed.totalDistance!, 1508.76, accuracy: 0.01)
        XCTAssertEqual(fixed.samples.map(\.v1), [22.86, 1508.76, 130].map { $0 }, accuracy: 0.01)
        XCTAssertEqual(fixed.laps, session.laps)
        XCTAssertEqual(FitnessSessionSummary(session: fixed).poolLengthMeters, 22.86)
    }

    // MARK: Trimming keeps laps

    func testTrimKeepsTheLapsInsideTheWindow() {
        let laps = [30, 30, 30, 30].enumerated().map { FitnessLap(number: $0.offset + 1, duration: TimeInterval($0.element)) }
        let kept = TrimmedLaps.kept(laps, startOffset: 30, endOffset: 90)
        XCTAssertEqual(kept, [FitnessLap(number: 1, duration: 30), FitnessLap(number: 2, duration: 30)])
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
