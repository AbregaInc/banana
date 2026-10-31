import XCTest

/// Coverage for `WorkoutMotionConsistency` — the scale-invariant "technique consistency" measure
/// behind `WorkoutMotionAnalysis.Result.pageConsistency` and `MotionSignatureCard.consistencyText`.
/// Every fixture here is a small, hand-built synthetic point cloud, matching this repo's
/// "build everything directly in Swift" pattern (`WorkoutMotionAnalysisTests`,
/// `HandPathSceneTests`) rather than reading a fixture file.
final class WorkoutMotionConsistencyTests: XCTestCase {

    // MARK: - Fixtures

    /// A closed loop on the unit circle in the XY plane, `count` points, optionally rotated about
    /// Z by `rotationRadians` and scaled uniformly by `scale` — enough to build both "identical
    /// technique" and "rotated/scaled technique" cycles from one shape.
    private func circleLoop(count: Int = 40, radius: Double = 1, rotationRadians: Double = 0,
                             scale: Double = 1, noise: Double = 0, seed: UInt64 = 1) -> WorkoutMotionConsistency.Loop {
        var rngState = seed
        func nextNoise() -> Double {
            rngState = rngState &* 6364136223846793005 &+ 1_442_695_040_888_963_407
            let unit = Double(rngState >> 40) / Double(1 << 24)   // [0, 1)
            return (unit - 0.5) * 2 * noise
        }
        var points: [WorkoutMotionConsistency.Point3] = []
        points.reserveCapacity(count)
        for i in 0..<count {
            let theta = 2 * Double.pi * Double(i) / Double(count)
            let x0 = radius * cos(theta)
            let y0 = radius * sin(theta)
            let x = (x0 * cos(rotationRadians) - y0 * sin(rotationRadians)) * scale + nextNoise()
            let y = (x0 * sin(rotationRadians) + y0 * cos(rotationRadians)) * scale + nextNoise()
            let z = 0.3 * sin(theta * 2) * scale + nextNoise()   // a little out-of-plane wobble so alignment isn't degenerate
            points.append(WorkoutMotionConsistency.Point3(x: x, y: y, z: z))
        }
        return WorkoutMotionConsistency.Loop(points: points)
    }

    // MARK: - Degenerate input

    func testFewerThanTwoLoopsReturnsNil() {
        XCTAssertNil(WorkoutMotionConsistency.consistencyRatio(loops: []))
        XCTAssertNil(WorkoutMotionConsistency.consistencyRatio(loops: [circleLoop()]))
    }

    func testMismatchedPointCountsReturnsNil() {
        let a = circleLoop(count: 40)
        let b = circleLoop(count: 30)
        XCTAssertNil(WorkoutMotionConsistency.consistencyRatio(loops: [a, b]))
    }

    func testDegenerateZeroSizeLoopsReturnNil() {
        let point = WorkoutMotionConsistency.Point3(x: 1, y: 1, z: 1)
        let flat = WorkoutMotionConsistency.Loop(points: [WorkoutMotionConsistency.Point3](repeating: point, count: 10))
        XCTAssertNil(WorkoutMotionConsistency.consistencyRatio(loops: [flat, flat]))
    }

    // MARK: - Identical shape, rotated only, is (near) perfectly consistent

    /// Cycles that are the SAME shape but arbitrarily rotated relative to one another — the exact
    /// case Procrustes alignment exists to see through — must report a ratio close to zero:
    /// nothing "inconsistent" about a wrist that rotates the same stroke a different amount each
    /// time the watch happens to be turned.
    func testIdenticalRotatedShapesReportNearZeroRatio() {
        let loops = [
            circleLoop(rotationRadians: 0),
            circleLoop(rotationRadians: 0.7),
            circleLoop(rotationRadians: 2.1),
            circleLoop(rotationRadians: -1.4),
        ]
        guard let ratio = WorkoutMotionConsistency.consistencyRatio(loops: loops) else {
            return XCTFail("expected a ratio")
        }
        XCTAssertEqual(ratio, 0, accuracy: 0.01, "identical shapes differing only by rotation should align to ~0 spread")
    }

    // MARK: - THE central property: scale invariance (the owner's own correction)
    //
    // "Wouldn't a diffuse cloud actually be correct assuming you move with a certain amount of
    // force? The tightest cloud would be caused by extremely consistently low-G movement?" —
    // multiplying every cycle's acceleration by the same constant (a harder push, not a less
    // consistent one) must leave the ratio unchanged, because both the spread and the loop's own
    // size scale together.

    func testConsistencyRatioIsInvariantToUniformlyScalingEveryCycle() {
        let baseLoops = [
            circleLoop(rotationRadians: 0.1, noise: 0.05, seed: 1),
            circleLoop(rotationRadians: 0.9, noise: 0.05, seed: 2),
            circleLoop(rotationRadians: 1.6, noise: 0.05, seed: 3),
            circleLoop(rotationRadians: -0.5, noise: 0.05, seed: 4),
        ]
        guard let baseRatio = WorkoutMotionConsistency.consistencyRatio(loops: baseLoops) else {
            return XCTFail("expected a ratio")
        }

        for factor in [0.1, 2.0, 10.0, 50.0] {
            // `scale`, not `radius` — `scale` multiplies x, y, AND z (including the z-wobble
            // term) together, which is what a real "every cycle's acceleration × constant" scale
            // means. `radius` alone only stretches the x/y circle, leaving z's amplitude fixed —
            // that's a DIFFERENT (non-uniform) distortion, not the property under test here.
            let scaledLoops = [
                circleLoop(rotationRadians: 0.1, scale: factor, noise: 0.05 * factor, seed: 1),
                circleLoop(rotationRadians: 0.9, scale: factor, noise: 0.05 * factor, seed: 2),
                circleLoop(rotationRadians: 1.6, scale: factor, noise: 0.05 * factor, seed: 3),
                circleLoop(rotationRadians: -0.5, scale: factor, noise: 0.05 * factor, seed: 4),
            ]
            guard let scaledRatio = WorkoutMotionConsistency.consistencyRatio(loops: scaledLoops) else {
                XCTFail("expected a ratio at scale factor \(factor)"); continue
            }
            XCTAssertEqual(scaledRatio, baseRatio, accuracy: 0.01,
                            "scaling every cycle by \(factor)x (a harder push, same technique) must not change the reported consistency")
        }
    }

    /// Direct restatement using `scale`, not `radius`+`noise` recombined — belt and suspenders on
    /// the same property, exercising the `scale` parameter's own multiplicative path (which also
    /// scales the z-wobble term) rather than re-deriving radius/noise by hand at each call site.
    func testConsistencyRatioIsInvariantToUniformScaleParameter() {
        let unscaled = [
            circleLoop(rotationRadians: 0.2, noise: 0.04, seed: 11),
            circleLoop(rotationRadians: 1.1, noise: 0.04, seed: 12),
            circleLoop(rotationRadians: 2.4, noise: 0.04, seed: 13),
        ]
        let scaled = [
            circleLoop(rotationRadians: 0.2, scale: 25, noise: 1.0, seed: 11),
            circleLoop(rotationRadians: 1.1, scale: 25, noise: 1.0, seed: 12),
            circleLoop(rotationRadians: 2.4, scale: 25, noise: 1.0, seed: 13),
        ]
        guard let unscaledRatio = WorkoutMotionConsistency.consistencyRatio(loops: unscaled),
              let scaledRatio = WorkoutMotionConsistency.consistencyRatio(loops: scaled) else {
            return XCTFail("expected both ratios")
        }
        XCTAssertEqual(scaledRatio, unscaledRatio, accuracy: 0.01)
    }

    // MARK: - Genuinely inconsistent shapes report a larger ratio than consistent ones

    /// Not just "doesn't crash" — the number must actually separate a well-drilled repeat from a
    /// varying one, at the SAME absolute scale (so this isn't just re-testing scale invariance).
    func testVaryingShapesReportALargerRatioThanConsistentOnesAtTheSameScale() {
        let consistent = [
            circleLoop(rotationRadians: 0.1),
            circleLoop(rotationRadians: 0.8),
            circleLoop(rotationRadians: 1.5),
            circleLoop(rotationRadians: 2.3),
        ]
        // Same nominal radius/scale, but each cycle's actual SHAPE differs (different radius per
        // cycle before the shared rotation) — an inconsistency no rotation can align away.
        let inconsistent = [
            circleLoop(radius: 1.0, rotationRadians: 0.1),
            circleLoop(radius: 1.6, rotationRadians: 0.8),
            circleLoop(radius: 0.5, rotationRadians: 1.5),
            circleLoop(radius: 1.9, rotationRadians: 2.3),
        ]
        guard let consistentRatio = WorkoutMotionConsistency.consistencyRatio(loops: consistent),
              let inconsistentRatio = WorkoutMotionConsistency.consistencyRatio(loops: inconsistent) else {
            return XCTFail("expected both ratios")
        }
        XCTAssertLessThan(consistentRatio, inconsistentRatio)
    }

    /// The owner's exact scenario, stated as one test: a GENTLE but perfectly repeatable stroke
    /// (small absolute cloud) must NOT report a better (lower) consistency ratio than a HARD but
    /// equally repeatable stroke (large absolute cloud) just because its cloud is smaller — this is
    /// precisely the confound "a tight cloud means consistent" got backwards.
    func testGentleAndForcefulEquallyConsistentStrokesReportTheSameRatio() {
        // `scale`, not `radius` — see the identical note in
        // `testConsistencyRatioIsInvariantToUniformlyScalingEveryCycle`: `scale` stretches x, y,
        // AND z together (a real "harder push"), while `radius` alone only stretches x/y.
        let gentle = [
            circleLoop(rotationRadians: 0.1, scale: 0.2, noise: 0.01, seed: 21),
            circleLoop(rotationRadians: 0.6, scale: 0.2, noise: 0.01, seed: 22),
            circleLoop(rotationRadians: 1.3, scale: 0.2, noise: 0.01, seed: 23),
        ]
        let forceful = [
            circleLoop(rotationRadians: 0.1, scale: 8.0, noise: 0.4, seed: 21),
            circleLoop(rotationRadians: 0.6, scale: 8.0, noise: 0.4, seed: 22),
            circleLoop(rotationRadians: 1.3, scale: 8.0, noise: 0.4, seed: 23),
        ]
        guard let gentleRatio = WorkoutMotionConsistency.consistencyRatio(loops: gentle),
              let forcefulRatio = WorkoutMotionConsistency.consistencyRatio(loops: forceful) else {
            return XCTFail("expected both ratios")
        }
        XCTAssertEqual(gentleRatio, forcefulRatio, accuracy: 0.02,
                        "a gentle stroke must not read as more 'consistent' than an equally-repeatable forceful one")
    }
}
