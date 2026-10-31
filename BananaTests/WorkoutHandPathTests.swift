import XCTest

/// Synthetic-fixture coverage for `WorkoutHandPath`, matching `WorkoutMotionAnalysisTests`'
/// approach: every fixture is a `[FitnessSample]` array built directly in Swift, no binary
/// `.samples` file involved. `WorkoutHandPath.analyze` takes raw samples and a pool length
/// directly (not a `FitnessSessionSummary`), so these tests need no `FitnessSession` fixture.
final class WorkoutHandPathTests: XCTestCase {

    // MARK: - Fixtures

    /// One lap's worth of accelerometer samples: a clean periodic magnitude, dominated by a
    /// cosine on `z` (mirrors gravity riding on the wrist through a stroke cycle) at `strokeHz`,
    /// with `x`/`y` components so the signal isn't degenerate for the planarity computation.
    /// Deliberately clean — the peak detector should find exactly one boundary per stroke period
    /// with no reconciliation needed, so tests built on this fixture isolate the geometry
    /// (angle/axial/pitch) from the reconciliation logic (covered separately, directly).
    private func periodicAccelSamples(duration: TimeInterval, strokeHz: Double, hz: Double = 50) -> [FitnessSample] {
        var samples: [FitnessSample] = []
        let dt = 1.0 / hz
        var t = 0.0
        while t < duration {
            let angle = 2 * Double.pi * strokeHz * t
            let x = 0.10 * sin(angle)
            let y = 0.05 * sin(angle * 2 + 0.3)
            let z = 1.0 + 0.30 * cos(angle)
            samples.append(FitnessSample(t: t, kind: .accel, v1: x, v2: y, v3: z))
            t += dt
        }
        return samples
    }

    /// The pair of samples the watch stamps at every lap turn: cumulative distance and cumulative
    /// stroke count, at the same timestamp.
    private func turnMark(t: TimeInterval, cumulativeMeters: Double, cumulativeStrokes: Int) -> [FitnessSample] {
        [FitnessSample(t: t, kind: .distance, v1: cumulativeMeters, v2: nil, v3: nil),
         FitnessSample(t: t, kind: .strokeCount, v1: Double(cumulativeStrokes), v2: nil, v3: nil)]
    }

    // MARK: - lapMarks

    func testLapMarksMergeDistanceAndStrokeCountAtTheSameTurnAndIgnoreOtherKinds() {
        let samples: [FitnessSample] = [
            FitnessSample(t: 20.0, kind: .distance, v1: 25, v2: nil, v3: nil),
            FitnessSample(t: 20.05, kind: .strokeCount, v1: 10, v2: nil, v3: nil),   // same turn as above
            FitnessSample(t: 40.0, kind: .strokeCount, v1: 21, v2: nil, v3: nil),
            FitnessSample(t: 40.04, kind: .distance, v1: 50, v2: nil, v3: nil),      // same turn as above
            FitnessSample(t: 5.0, kind: .heartRate, v1: 120, v2: nil, v3: nil),      // not a turn mark
        ]
        let marks = WorkoutHandPath.lapMarks(from: samples)
        XCTAssertEqual(marks.count, 2, "the two same-turn pairs should merge into one mark each")
        XCTAssertEqual(marks[0], 20.0, accuracy: 0.001)
        XCTAssertEqual(marks[1], 40.0, accuracy: 0.001)
    }

    func testLapMarksEmptyWithNoDistanceOrStrokeCountSamples() {
        let samples = (0..<10).map { FitnessSample(t: Double($0), kind: .heartRate, v1: 120, v2: nil, v3: nil) }
        XCTAssertTrue(WorkoutHandPath.lapMarks(from: samples).isEmpty)
    }

    // MARK: - Full pipeline: one clean lap, no reconciliation needed

    func testOneTurnPerStrokeWithMonotonicAngleAndCorrectTotals() {
        let lapDuration = 20.0
        let strokeHz = 0.5           // period 2 s -> exactly 10 strokes over 20 s
        let strokeCount = 10
        let lengthMeters = 25.0

        var samples = periodicAccelSamples(duration: lapDuration, strokeHz: strokeHz)
        samples += turnMark(t: lapDuration, cumulativeMeters: lengthMeters, cumulativeStrokes: strokeCount)

        guard let analysis = WorkoutHandPath.analyze(samples: samples, poolLengthMeters: lengthMeters) else {
            return XCTFail("expected a hand-path analysis for a well-formed single-lap swim")
        }
        XCTAssertEqual(analysis.laps.count, 1)
        let lap = analysis.laps[0]

        XCTAssertEqual(lap.strokeCount, strokeCount)
        XCTAssertEqual(lap.strokeBoundaries.count, strokeCount + 1,
                       "strokeBoundaries must include both the lap start and end")
        // A clean, strongly periodic 10-stroke signal should detect most boundaries for real —
        // reconciliation-count coverage (over-counting and under-counting, including the
        // synthetic count) lives in the direct `reconcileBoundaryCount` tests below, so this only
        // sanity-checks that the peak detector isn't degenerate on an easy signal.
        XCTAssertLessThan(lap.syntheticBoundaryCount, strokeCount)

        // Angle always increases, point to point, across the whole lap (never integrated, never
        // ambiguous in sign).
        for i in 1..<lap.points.count {
            XCTAssertGreaterThan(lap.points[i].angle, lap.points[i - 1].angle,
                                 "angle must be strictly increasing at point \(i)")
        }

        // Exactly one 2*pi turn per known stroke — not per detected peak.
        let totalTurns = Double(lap.points.last!.angle) / (2 * Double.pi)
        XCTAssertEqual(totalTurns, Double(strokeCount), accuracy: 1e-4)

        // Axial spans exactly the lap length, start to finish.
        XCTAssertEqual(lap.points.first!.axial, 0, accuracy: 1e-4)
        XCTAssertEqual(Double(lap.points.last!.axial), lengthMeters, accuracy: 1e-3)

        // Pitch (axial advance per turn) equals distance per stroke — exactly true here because
        // the fixture's strokes are evenly spaced in time.
        XCTAssertEqual(lap.distancePerStroke, lengthMeters / Double(strokeCount), accuracy: 1e-9)
        let perTurn = (lap.points.count - 1) / lap.strokeCount
        var axialAtBoundary: [Float] = stride(from: 0, to: lap.points.count - 1, by: perTurn).map { lap.points[$0].axial }
        axialAtBoundary.append(lap.points.last!.axial)
        for i in 1..<axialAtBoundary.count {
            let pitch = Double(axialAtBoundary[i] - axialAtBoundary[i - 1])
            XCTAssertEqual(pitch, lap.distancePerStroke, accuracy: 0.15,
                           "turn \(i) pitch should match distance-per-stroke within a small tolerance")
        }
    }

    // MARK: - Reconciliation (unit-level, matching the prototype's documented cases exactly)

    func testReconciliationDropsLeastProminentPeaksWhenOverCounting() {
        // 5 candidates -> 6 turns; target 3 turns -> drop the 3 least-prominent, keep the rest.
        let times: [Float] = [1, 2, 3, 4, 5]
        let prominences: [Float] = [5, 1, 4, 2, 3]

        let (boundaries, synthetic) = WorkoutHandPath.reconcileBoundaryCount(
            times: times, prominences: prominences, lapStart: 0, lapEnd: 10, targetStrokes: 3)

        XCTAssertEqual(boundaries, [1, 3], "should keep exactly the two highest-prominence candidates")
        XCTAssertEqual(synthetic, 0, "dropping never introduces a synthetic boundary")
    }

    func testReconciliationSynthesizesBoundariesByBisectingTheLargestGapWhenUnderCounting() {
        // 1 candidate -> 2 turns; target 4 turns -> need 2 more, by repeatedly bisecting the
        // widest remaining gap starting from [0, 5, 10].
        let times: [Float] = [5]
        let prominences: [Float] = [1]

        let (boundaries, synthetic) = WorkoutHandPath.reconcileBoundaryCount(
            times: times, prominences: prominences, lapStart: 0, lapEnd: 10, targetStrokes: 4)

        XCTAssertEqual(boundaries, [2.5, 5, 7.5])
        XCTAssertEqual(synthetic, 2, "both inserted boundaries are synthetic")
    }

    func testReconciliationLeavesExactMatchesUntouched() {
        let times: [Float] = [3, 6]
        let (boundaries, synthetic) = WorkoutHandPath.reconcileBoundaryCount(
            times: times, prominences: [1, 1], lapStart: 0, lapEnd: 9, targetStrokes: 3)
        XCTAssertEqual(boundaries, [3, 6])
        XCTAssertEqual(synthetic, 0)
    }

    func testReconciliationForcesNoInteriorBoundariesForASingleStrokeLap() {
        // Guarantees strokeBoundaries.count == strokeCount + 1 even if the detector found stray
        // peaks in a one-stroke lap — see the doc comment on reconcileBoundaryCount.
        let (boundaries, synthetic) = WorkoutHandPath.reconcileBoundaryCount(
            times: [3, 6], prominences: [1, 1], lapStart: 0, lapEnd: 10, targetStrokes: 1)
        XCTAssertTrue(boundaries.isEmpty)
        XCTAssertEqual(synthetic, 0)
    }

    // MARK: - Gating: nil unless the inputs actually support the model

    func testNilWithoutAPoolLength() {
        let lapDuration = 20.0
        var samples = periodicAccelSamples(duration: lapDuration, strokeHz: 0.5)
        samples += turnMark(t: lapDuration, cumulativeMeters: 25, cumulativeStrokes: 10)

        XCTAssertNil(WorkoutHandPath.analyze(samples: samples, poolLengthMeters: nil))
        XCTAssertNil(WorkoutHandPath.analyze(samples: samples, poolLengthMeters: 0))
    }

    func testNilWithoutAnyStrokeCounts() {
        let lapDuration = 20.0
        var samples = periodicAccelSamples(duration: lapDuration, strokeHz: 0.5)
        // Only a distance mark — no .strokeCount sample anywhere in the stream.
        samples.append(FitnessSample(t: lapDuration, kind: .distance, v1: 25, v2: nil, v3: nil))

        XCTAssertNil(WorkoutHandPath.analyze(samples: samples, poolLengthMeters: 25))
    }

    func testNilWithNoLapMarksAtAll() {
        let samples = periodicAccelSamples(duration: 20, strokeHz: 0.5)   // accel only, no turn ever stamped
        XCTAssertNil(WorkoutHandPath.analyze(samples: samples, poolLengthMeters: 25))
    }
}
