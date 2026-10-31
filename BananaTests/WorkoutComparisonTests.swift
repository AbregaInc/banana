import XCTest
import SwiftUI

/// Synthetic-fixture coverage for `WorkoutComparisons.compute` and `WorkoutSplits`
/// (`Banana/Model/WorkoutComparison.swift`), matching `WorkoutMotionAnalysisTests`'s "no binary
/// fixture file, build everything directly in Swift" pattern. `WorkoutComparisons.compute` is a
/// pure extraction of `PostWorkoutReviewView`'s former private `comparisons` property — these
/// tests exercise the same arithmetic the phone's post-workout review always has, so a numeric
/// regression here would also be a phone-visible regression.
final class WorkoutComparisonTests: XCTestCase {

    // MARK: - Fixtures

    private func subject(durationSeconds: TimeInterval, distanceMeters: Double? = nil,
                          avgHeartRate: Double? = nil, activity: String = "Running") -> WorkoutReviewSubject {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let session = FitnessSession(id: UUID(), start: start, end: start.addingTimeInterval(durationSeconds),
                                      activity: activity, avgHeartRate: avgHeartRate, totalEnergy: nil,
                                      totalDistance: distanceMeters, samples: [])
        return WorkoutReviewSubject(summary: FitnessSessionSummary(session: session), health: nil)
    }

    // MARK: - No peers → no comparisons

    func testNoPeersProducesNoComparisons() {
        let now = subject(durationSeconds: 1_500, distanceMeters: 5_000, avgHeartRate: 140)
        let result = WorkoutComparisons.compute(subject: now, peers: [], distanceUnit: .kilometers, usesPace: true)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Duration, Distance, Pace, Avg heart rate — full set, exact numbers

    func testRunningComparisonProducesDurationDistancePaceAndHeartRateInOrder() {
        // Now: 25:00 over 5.00 km (5:00/km), avg HR 140.
        let now = subject(durationSeconds: 1_500, distanceMeters: 5_000, avgHeartRate: 140)
        // Usual (one peer): 30:00 over 5.00 km (6:00/km), avg HR 150 — a slower, easier run.
        let peer = subject(durationSeconds: 1_800, distanceMeters: 5_000, avgHeartRate: 150)

        let result = WorkoutComparisons.compute(subject: now, peers: [peer], distanceUnit: .kilometers, usesPace: true)

        XCTAssertEqual(result.map(\.title), ["Duration", "Distance", "Pace", "Avg heart rate"])

        let duration = result[0]
        XCTAssertEqual(duration.now, "25:00")
        XCTAssertEqual(duration.usual, "30:00")
        XCTAssertEqual(duration.deltaPercent, -17)   // (1500-1800)/1800 * 100, rounded
        XCTAssertEqual(duration.tone, WorkoutPalette.neutral)

        let distance = result[1]
        XCTAssertEqual(distance.now, "5.00 km")
        XCTAssertEqual(distance.usual, "5.00 km")
        XCTAssertEqual(distance.deltaPercent, 0)
        XCTAssertEqual(distance.tone, WorkoutPalette.neutral)

        let pace = result[2]
        XCTAssertEqual(pace.now, "5:00 /km")
        XCTAssertEqual(pace.usual, "6:00 /km")
        XCTAssertEqual(pace.deltaPercent, -17)        // faster pace → negative delta
        XCTAssertEqual(pace.tone, WorkoutPalette.good) // faster is good, colored green

        let heartRate = result[3]
        XCTAssertEqual(heartRate.now, "140 bpm")
        XCTAssertEqual(heartRate.usual, "150 bpm")
        XCTAssertEqual(heartRate.deltaPercent, -7)
        XCTAssertEqual(heartRate.tone, WorkoutPalette.neutral)
    }

    /// A slower-than-usual pace must flip the tone to `.bad` (orange), not stay green.
    func testSlowerPaceIsToneBad() {
        let now = subject(durationSeconds: 1_800, distanceMeters: 5_000)     // 6:00/km
        let peer = subject(durationSeconds: 1_500, distanceMeters: 5_000)    // 5:00/km, faster usual
        let result = WorkoutComparisons.compute(subject: now, peers: [peer], distanceUnit: .kilometers, usesPace: true)
        let pace = result.first { $0.title == "Pace" }
        XCTAssertEqual(pace?.deltaPercent, 20)   // slower → positive delta
        XCTAssertEqual(pace?.tone, WorkoutPalette.bad)
    }

    // MARK: - Speed (usesPace == false): title flips, delta sign flips, tone still faster-is-good

    func testCyclingComparisonUsesSpeedTitleWithFlippedDeltaSign() {
        // Now: 36 km/h (10 m/s over 1 hour); usual: 18 km/h (5 m/s over 1 hour) — twice as fast.
        let now = subject(durationSeconds: 3_600, distanceMeters: 36_000, activity: "Cycling")
        let peer = subject(durationSeconds: 3_600, distanceMeters: 18_000, activity: "Cycling")

        let result = WorkoutComparisons.compute(subject: now, peers: [peer], distanceUnit: .kilometers, usesPace: false)
        let speed = result.first { $0.title == "Speed" }
        XCTAssertNotNil(speed)
        XCTAssertNil(result.first { $0.title == "Pace" })
        XCTAssertEqual(speed?.now, "36.0 km/h")
        XCTAssertEqual(speed?.usual, "18.0 km/h")
        XCTAssertEqual(speed?.deltaPercent, 50)        // faster shown as a positive delta for speed
        XCTAssertEqual(speed?.tone, WorkoutPalette.good)
    }

    // MARK: - Partial data: no distance on the subject skips Distance/Pace, keeps Duration/HR

    func testMissingDistanceOnSubjectSkipsDistanceAndPaceComparisons() {
        let now = subject(durationSeconds: 1_200, avgHeartRate: 130)
        let peer = subject(durationSeconds: 1_200, distanceMeters: 4_000, avgHeartRate: 130)
        let result = WorkoutComparisons.compute(subject: now, peers: [peer], distanceUnit: .kilometers, usesPace: true)
        XCTAssertEqual(result.map(\.title), ["Duration", "Avg heart rate"])
    }

    // MARK: - Miles formatting

    func testMilesUnitFormatsDistanceAndPaceInMiles() {
        let now = subject(durationSeconds: 1_609, distanceMeters: 1_609.344)   // ~1 mile in ~26:49
        let peer = subject(durationSeconds: 1_609, distanceMeters: 1_609.344)
        let result = WorkoutComparisons.compute(subject: now, peers: [peer], distanceUnit: .miles, usesPace: true)
        let distance = result.first { $0.title == "Distance" }
        XCTAssertEqual(distance?.now, "1.00 mi")
        let pace = result.first { $0.title == "Pace" }
        XCTAssertEqual(pace?.now.hasSuffix("/mi"), true)
    }
}

// MARK: - WorkoutSplits

final class WorkoutSplitsTests: XCTestCase {

    // MARK: - swolfRows

    func testSwolfRowsComputesPerLapStrokesFromCumulativeDeltas() {
        let laps = [
            FitnessLap(number: 1, duration: 60),
            FitnessLap(number: 2, duration: 65),
            FitnessLap(number: 3, duration: 70),
        ]
        // Cumulative strokeCount samples spanning lap windows [0,60) [60,125) [125,195).
        let strokes = [
            WorkoutMetricPoint(t: 30, value: 10),
            WorkoutMetricPoint(t: 59, value: 20),
            WorkoutMetricPoint(t: 90, value: 35),
            WorkoutMetricPoint(t: 124, value: 50),
            WorkoutMetricPoint(t: 150, value: 70),
            WorkoutMetricPoint(t: 194, value: 90),
        ]

        let rows = WorkoutSplits.swolfRows(laps: laps, strokeSeries: strokes)

        XCTAssertEqual(rows.map(\.lapNumber), [1, 2, 3])
        XCTAssertEqual(rows[0].strokes, 20)     // 20 - 0 (implicit zero before the first sample)
        XCTAssertEqual(rows[0].swolf, 80)       // 20 + 60
        XCTAssertEqual(rows[1].strokes, 30)     // 50 - 20
        XCTAssertEqual(rows[1].swolf, 95)       // 30 + 65
        XCTAssertEqual(rows[2].strokes, 40)     // 90 - 50
        XCTAssertEqual(rows[2].swolf, 110)      // 40 + 70
    }

    func testSwolfRowsWithNoStrokeDataYieldsNilStrokesAndSwolf() {
        let laps = [FitnessLap(number: 1, duration: 60), FitnessLap(number: 2, duration: 60)]
        let rows = WorkoutSplits.swolfRows(laps: laps, strokeSeries: [])
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNil(row.strokes)
            XCTAssertNil(row.swolf)
        }
    }

    func testSwolfRowsWithNoLapsIsEmpty() {
        let rows = WorkoutSplits.swolfRows(laps: [], strokeSeries: [WorkoutMetricPoint(t: 10, value: 5)])
        XCTAssertTrue(rows.isEmpty)
    }

    /// Real fixture from the owner's pool swim (id begins B10C281F, 70 laps, 22.86 m): one
    /// cumulative `.strokeCount` sample per lap, each mark stamped slightly AFTER the boundary
    /// built by summing `FitnessLap.duration` (lap 1's mark at 71.4 s vs. a summed boundary of
    /// 71.1 s; lap 2's at 101.4 s vs. 101.0 s) — the drift that made every lap show its
    /// PREVIOUS lap's stroke count before this fix. Exactly one sample per lap takes the exact,
    /// index-paired path, which never compares timestamps at all.
    func testSwolfRowsExactPathPairsSamplesByIndexDespiteBoundaryDrift() {
        let laps = [
            FitnessLap(number: 1, duration: 71.1),
            FitnessLap(number: 2, duration: 29.9),   // boundary 101.0
            FitnessLap(number: 3, duration: 30.0),   // boundary 131.0
            FitnessLap(number: 4, duration: 30.0),   // boundary 161.0
            FitnessLap(number: 5, duration: 30.0),   // boundary 191.0
            FitnessLap(number: 6, duration: 30.0),   // boundary 221.0
            FitnessLap(number: 7, duration: 30.0),   // boundary 251.0
            FitnessLap(number: 8, duration: 30.0),   // boundary 281.0
        ]
        // Marks land ~0.3-0.4s after each summed boundary, matching the real drift, and carry the
        // real cumulative stroke values recorded at the first eight marks.
        let strokes = [
            WorkoutMetricPoint(t: 71.4, value: 11),
            WorkoutMetricPoint(t: 101.4, value: 24),
            WorkoutMetricPoint(t: 131.3, value: 36),
            WorkoutMetricPoint(t: 161.3, value: 50),
            WorkoutMetricPoint(t: 191.3, value: 63),
            WorkoutMetricPoint(t: 221.3, value: 79),
            WorkoutMetricPoint(t: 251.3, value: 91),
            WorkoutMetricPoint(t: 281.3, value: 106),
        ]

        let rows = WorkoutSplits.swolfRows(laps: laps, strokeSeries: strokes)

        XCTAssertEqual(rows.map(\.strokes), [11, 13, 12, 14, 13, 16, 12, 15])
        XCTAssertEqual(rows[0].strokes, 11)   // not 0 — the pre-fix bug
        XCTAssertEqual(rows[1].strokes, 13)   // not 11 — lap 2 must not inherit lap 1's count
    }

    /// A lap that never gets a `.strokeCount` mark of its own (none of the fallback path's marks
    /// land inside its window, even with drift tolerance) must report `nil`, not the `0` the old
    /// `cumulative(at:)` comparison would have silently produced (both boundary lookups would have
    /// returned the same carried-forward value, and `endValue >= startValue` would have accepted
    /// the resulting zero as a real answer).
    func testSwolfRowsLapWithoutOwnMarkReportsNilNotZero() {
        let laps = [FitnessLap(number: 1, duration: 30), FitnessLap(number: 2, duration: 30)]
        // Only sample is long after both laps' (drift-tolerant) windows have closed.
        let strokes = [WorkoutMetricPoint(t: 100, value: 20)]

        let rows = WorkoutSplits.swolfRows(laps: laps, strokeSeries: strokes)

        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].strokes)
        XCTAssertNil(rows[0].swolf)
        XCTAssertNil(rows[1].strokes)
        XCTAssertNil(rows[1].swolf)
    }

    /// Fewer stroke samples than laps (the watch missed a turn mark, e.g. the very last one) still
    /// exercises the fallback path — laps with a mark compute normally, the lap left without one
    /// reports nil instead of crashing or guessing.
    func testSwolfRowsFallbackHandlesFewerSamplesThanLaps() {
        let laps = [
            FitnessLap(number: 1, duration: 30),
            FitnessLap(number: 2, duration: 30),
            FitnessLap(number: 3, duration: 30),   // never gets a mark
        ]
        let strokes = [
            WorkoutMetricPoint(t: 31, value: 5),    // lap 1's mark, +1s drift
            WorkoutMetricPoint(t: 61, value: 13),   // lap 2's mark, +1s drift
        ]

        let rows = WorkoutSplits.swolfRows(laps: laps, strokeSeries: strokes)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].strokes, 5)     // 5 - 0
        XCTAssertEqual(rows[1].strokes, 8)     // 13 - 5
        XCTAssertNil(rows[2].strokes)
        XCTAssertNil(rows[2].swolf)
    }

    // MARK: - fastestIndex

    func testFastestIndexReturnsIndexOfMinimumDuration() {
        struct Item { let duration: TimeInterval }
        let items = [Item(duration: 80), Item(duration: 65), Item(duration: 95)]
        XCTAssertEqual(WorkoutSplits.fastestIndex(items, duration: { $0.duration }), 1)
    }

    func testFastestIndexOnEmptyCollectionIsNil() {
        struct Item { let duration: TimeInterval }
        let items: [Item] = []
        XCTAssertNil(WorkoutSplits.fastestIndex(items, duration: { $0.duration }))
    }

    func testFastestIndexPicksFirstOnTie() {
        struct Item { let duration: TimeInterval }
        let items = [Item(duration: 60), Item(duration: 60)]
        XCTAssertEqual(WorkoutSplits.fastestIndex(items, duration: { $0.duration }), 0)
    }
}

/// The post-workout summary once read "0.62, 2.49, 5.59 … 50.33 mi" for a 5.9-mile run: it
/// labelled each stored kilometre split with split number × the running total where it ended.
/// Splits now come from the distance track in the reader's unit, from one place, labelled by count.
final class DistanceSplitDisplayTests: XCTestCase {
    /// The 28 Sep 2026 run's shape: 9,549 m, steady, over 62 minutes.
    private func fiveMileRun(meters: Double = 9_549, seconds: TimeInterval = 3_722, points: Int = 254) -> FitnessSessionSummary {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let session = FitnessSession(id: UUID(), start: start, end: start.addingTimeInterval(seconds),
                                     activity: "Running", avgHeartRate: nil, totalEnergy: nil,
                                     totalDistance: meters, samples: [])
        var summary = FitnessSessionSummary(session: session)
        summary.distanceSeries = (0..<points).map { i in
            let f = Double(i) / Double(points - 1)
            return DistancePoint(t: f * seconds, meters: f * meters)
        }
        summary.distanceSplits = FitnessSessionSummary.distanceSplits(from: summary.distanceSeries, interval: 1_000)
        return summary
    }

    func testAMilesReaderGetsMileSplits() {
        let splits = WorkoutSplits.distanceSplits(for: fiveMileRun(), unit: .miles)
        XCTAssertEqual(splits.count, 5, "5.93 mi has five whole miles")
        XCTAssertEqual(splits.map { WorkoutSplits.label($0, unit: .miles) },
                       ["Mile 1", "Mile 2", "Mile 3", "Mile 4", "Mile 5"])
        // Steady pace: each mile takes the same share of the run.
        let perMile = 3_722 * 1_609.344 / 9_549
        for split in splits { XCTAssertEqual(split.duration, perMile, accuracy: 20) }
    }

    func testAKilometreReaderGetsKilometreSplits() {
        let splits = WorkoutSplits.distanceSplits(for: fiveMileRun(), unit: .kilometers)
        XCTAssertEqual(splits.count, 9)
        XCTAssertEqual(WorkoutSplits.label(splits[8], unit: .kilometers), "Kilometer 9")
    }

    func testTheRestOfTheRunIsItsOwnRow() throws {
        let partial = try XCTUnwrap(WorkoutSplits.finalPartial(for: fiveMileRun(), unit: .miles))
        XCTAssertEqual(partial.meters, 9_549 - 5 * 1_609.344, accuracy: 1)
        XCTAssertEqual(partial.duration, 3_722 * partial.meters / 9_549, accuracy: 20)
        XCTAssertNil(WorkoutSplits.finalPartial(for: fiveMileRun(meters: 8_060), unit: .miles),
                     "a few metres past a whole split isn't a row")
    }

    func testTheLabelIsACountNotADistance() {
        let ninth = DistanceSplit(number: 9, distanceMeters: 9_000, duration: 447)
        XCTAssertEqual(WorkoutSplits.label(ninth, unit: .miles), "Mile 9")
    }

    func testWithoutATrackOnlyStoredKilometresAreUsed() {
        var summary = fiveMileRun()
        summary.distanceSeries = []
        XCTAssertEqual(WorkoutSplits.distanceSplits(for: summary, unit: .kilometers).count, 9)
        XCTAssertTrue(WorkoutSplits.distanceSplits(for: summary, unit: .miles).isEmpty,
                      "kilometre splits must not be shown as miles")
    }
}
