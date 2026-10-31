import XCTest

/// Synthetic-fixture coverage for `HandPathScene`'s pure geometry — no `WorkoutHandPath.analyze`
/// call, no binary sample fixture, matching `WorkoutMotionAnalysisTests`'s "build everything
/// directly in Swift" pattern. `HandPathScene` never recomputes anything from raw samples, so
/// every fixture here is a hand-built `WorkoutHandPath.Lap`.
final class HandPathSceneTests: XCTestCase {

    // MARK: - Fixtures

    private func point(t: Float, angle: Float, axial: Float, effort: Float = 0.5) -> WorkoutHandPath.Point {
        WorkoutHandPath.Point(t: t, angle: angle, axial: axial, effort: effort)
    }

    private func lap(points: [WorkoutHandPath.Point], lengthMeters: Double = 25,
                      strokeCount: Int = 10, planarity: Float = 3.0, syntheticBoundaryCount: Int = 0) -> WorkoutHandPath.Lap {
        WorkoutHandPath.Lap(id: 0, lengthMeters: lengthMeters, startT: 0, duration: 20,
                            strokeCount: strokeCount, distancePerStroke: lengthMeters / Double(max(strokeCount, 1)),
                            points: points, strokeBoundaries: [], syntheticBoundaryCount: syntheticBoundaryCount,
                            planarity: planarity, warnings: [])
    }

    // MARK: - A known point projects where expected

    func testKnownPointProjectsSideOn() {
        // Side-on camera (azimuth 0, elevation 0): world (axial, r·cosθ, r·sinθ) passes through
        // unrotated, so x == axial, y == r·cosθ, depth == r·sinθ exactly.
        let p = point(t: 0, angle: 0, axial: 5)
        let projected = HandPathScene.project(p, radiusMeters: 1, camera: HandPathScene.Camera(azimuth: 0, elevation: 0, zoom: 1, radiusExaggeration: 1))
        XCTAssertEqual(projected.x, 5, accuracy: 1e-9)
        XCTAssertEqual(projected.y, 1, accuracy: 1e-9)   // cos(0) = 1
        XCTAssertEqual(projected.depth, 0, accuracy: 1e-9)   // sin(0) = 0
    }

    func testKnownPointProjectsDownTheLane() {
        // Down-the-lane camera (azimuth π/2, elevation 0): axial rotates entirely into depth, and
        // the radial (y, z) pair rotates entirely into (x, unchanged-through-elevation y). Builds
        // its own camera (rather than `.downLane`, whose preset radiusExaggeration is 4×) so the
        // expected numbers stay in terms of the unscaled radius.
        let camera = HandPathScene.Camera(azimuth: .pi / 2, elevation: 0, zoom: 1, radiusExaggeration: 1)
        let p = point(t: 0, angle: 0, axial: 5)
        let projected = HandPathScene.project(p, radiusMeters: 1, camera: camera)
        XCTAssertEqual(projected.x, 0, accuracy: 1e-9)
        XCTAssertEqual(projected.y, 1, accuracy: 1e-9)
        XCTAssertEqual(projected.depth, 5, accuracy: 1e-9)
    }

    // MARK: - Default camera is tilted off dead side-on (not `.side` itself)

    func testDefaultCameraIsTiltedOffDeadSideOn() {
        // Dead side-on (azimuth 0, elevation 0) projects a helix to a pure sinusoid -- the near
        // and far halves of every coil land on exactly the same screen position, which is
        // precisely the "reads as flat, not 3D" defect. The default must be a genuinely different,
        // tilted camera, not merely an alias for `.side`.
        XCTAssertNotEqual(HandPathScene.Camera.default.azimuth, 0)
        XCTAssertNotEqual(HandPathScene.Camera.default.elevation, 0)
        XCTAssertNotEqual(HandPathScene.Camera.default, HandPathScene.Camera.side)
    }

    func testDefaultCameraSeparatesNearAndFarHalvesOfARing() {
        // angle π/2 and 3π/2 are a ring's own near/far extremes (radius·sin(angle) = ±radius,
        // i.e. the pre-rotation depth extrema) -- under dead side-on these differ only in the
        // SIGN of depth, with identical x (both equal the shared axial position: sin(angle)'s
        // magnitude is the same at both, and side-on's x doesn't depend on it at all). Under the
        // tilted default, azimuth mixes that radial component into x too, so the near half of a
        // coil visibly separates on screen from the far half instead of drawing on top of it.
        let near = HandPathScene.project(point(t: 0, angle: .pi / 2, axial: 5), radiusMeters: 0.6, camera: .default)
        let far = HandPathScene.project(point(t: 0, angle: 3 * .pi / 2, axial: 5), radiusMeters: 0.6, camera: .default)
        XCTAssertGreaterThan(abs(near.x - far.x), 0.05, "near/far halves of a coil should visibly separate on screen under the default camera")
        XCTAssertGreaterThan(abs(near.depth - far.depth), 0.5)

        // Under dead side-on the same two points land at the identical x -- confirms the
        // comparison above is actually exercising the tilt, not some property true of any camera.
        let sideNear = HandPathScene.project(point(t: 0, angle: .pi / 2, axial: 5), radiusMeters: 0.6, camera: .side)
        let sideFar = HandPathScene.project(point(t: 0, angle: 3 * .pi / 2, axial: 5), radiusMeters: 0.6, camera: .side)
        XCTAssertEqual(sideNear.x, sideFar.x, accuracy: 1e-9)
    }

    // MARK: - Depth cues (width + opacity) actually vary with depth, not just get computed

    func testNearSegmentsAreWiderAndMoreOpaqueThanFarSegments() {
        let points = stride(from: 0, to: 4 * Double.pi, by: 0.2).map {
            point(t: Float($0), angle: Float($0), axial: Float($0))
        }
        let drawing = HandPathScene.build(lap: lap(points: points), radiusMeters: 0.6, camera: .default)
        guard let nearest = drawing.segments.min(by: { $0.depth < $1.depth }),
              let farthest = drawing.segments.max(by: { $0.depth < $1.depth }) else {
            return XCTFail("expected segments")
        }
        XCTAssertGreaterThan(nearest.width, farthest.width)
        XCTAssertGreaterThan(nearest.opacity, farthest.opacity)
        for segment in drawing.segments {
            XCTAssertGreaterThanOrEqual(segment.opacity, 0)
            XCTAssertLessThanOrEqual(segment.opacity, 1)
        }
    }

    func testRadiusExaggerationScalesTheRadialComponentsOnly() {
        let p = point(t: 0, angle: .pi / 2, axial: 3)   // cos = 0, sin = 1
        let projected = HandPathScene.project(p, radiusMeters: 0.6,
                                               camera: HandPathScene.Camera(azimuth: 0, elevation: 0, zoom: 1, radiusExaggeration: 4))
        XCTAssertEqual(projected.x, 3, accuracy: 1e-9)          // axial untouched by exaggeration
        XCTAssertEqual(projected.y, 0, accuracy: 1e-6)          // 0.6 * 4 * cos(pi/2) ≈ 0
        XCTAssertEqual(projected.depth, 2.4, accuracy: 1e-6)    // 0.6 * 4 * sin(pi/2)
    }

    // MARK: - Depth sorting orders back to front

    func testSegmentsAreDepthSortedFarthestFirst() {
        let points = stride(from: 0, to: 4 * Double.pi, by: 0.3).map {
            point(t: Float($0), angle: Float($0), axial: Float($0))
        }
        let drawing = HandPathScene.build(lap: lap(points: points), radiusMeters: 0.6, camera: .side)
        XCTAssertFalse(drawing.segments.isEmpty)
        for i in 0..<max(drawing.segments.count - 1, 0) {
            XCTAssertGreaterThanOrEqual(drawing.segments[i].depth, drawing.segments[i + 1].depth,
                                        "segment \(i) should not be nearer than segment \(i + 1) in a back-to-front list")
        }
    }

    // MARK: - Segment count matches point count

    func testSegmentCountIsOneLessThanPointCount() {
        for n in [0, 1, 2, 5, 24] {
            let points = (0..<n).map { point(t: Float($0), angle: Float($0) * 0.5, axial: Float($0)) }
            let drawing = HandPathScene.build(lap: lap(points: points), radiusMeters: 0.6, camera: .side)
            let expected = max(n - 1, 0)
            XCTAssertEqual(drawing.segments.count, expected, "n=\(n) points should yield \(expected) segments")
        }
    }

    // MARK: - An empty lap yields no segments and no crash

    func testZeroPointLapYieldsNoSegments() {
        let drawing = HandPathScene.build(lap: lap(points: []), radiusMeters: 0.6, camera: .side)
        XCTAssertTrue(drawing.segments.isEmpty)
        // Lane geometry depends only on lengthMeters, not on point count, so it's still expected.
        XCTAssertFalse(drawing.laneBehind.isEmpty && drawing.laneFront.isEmpty)
    }

    func testSinglePointLapYieldsNoSegments() {
        let drawing = HandPathScene.build(lap: lap(points: [point(t: 0, angle: 0, axial: 0)]), radiusMeters: 0.6, camera: .side)
        XCTAssertTrue(drawing.segments.isEmpty)
    }

    func testZeroLengthLapYieldsAnEntirelyEmptyDrawing() {
        // Gate-on-the-inputs: a degenerate lap (no pool length) must never fabricate a
        // plausible-looking picture, not even a bare reference lane.
        let points = [point(t: 0, angle: 0, axial: 0), point(t: 1, angle: 1, axial: 1)]
        let drawing = HandPathScene.build(lap: lap(points: points, lengthMeters: 0), radiusMeters: 0.6, camera: .side)
        XCTAssertTrue(drawing.segments.isEmpty)
        XCTAssertTrue(drawing.laneBehind.isEmpty)
        XCTAssertTrue(drawing.laneFront.isEmpty)
        XCTAssertTrue(drawing.markers.isEmpty)
    }

    func testNegativeOrNonFiniteRadiusYieldsAnEmptyDrawingWithoutCrashing() {
        let points = [point(t: 0, angle: 0, axial: 0), point(t: 1, angle: 1, axial: 1)]
        let negative = HandPathScene.build(lap: lap(points: points), radiusMeters: -1, camera: .side)
        XCTAssertTrue(negative.segments.isEmpty)
        let nan = HandPathScene.build(lap: lap(points: points), radiusMeters: .nan, camera: .side)
        XCTAssertTrue(nan.segments.isEmpty)
    }

    // MARK: - Reference lane behind/front split

    func testEveryLaneMarkIsClassifiedBehindOrFront() {
        let points = stride(from: 0, to: 2 * Double.pi, by: 0.4).map {
            point(t: Float($0), angle: Float($0), axial: Float($0) * 2)
        }
        let drawing = HandPathScene.build(lap: lap(points: points, lengthMeters: 12), radiusMeters: 0.6, camera: .above)
        XCTAssertFalse(drawing.laneBehind.isEmpty)
        XCTAssertFalse(drawing.laneFront.isEmpty)
        // Both lists are individually back-to-front sorted.
        for marks in [drawing.laneBehind, drawing.laneFront] {
            for i in 0..<max(marks.count - 1, 0) {
                XCTAssertGreaterThanOrEqual(marks[i].depth, marks[i + 1].depth)
            }
        }
    }

    // MARK: - Start/end cap markers (item 2: direction must be readable from any rotation)

    /// Real geometry: build with actual stroke points whose first/last angles are congruent
    /// (a whole number of turns apart, as `WorkoutHandPath` always produces — see `CapMarker`'s
    /// doc comment), then check the two markers themselves.
    private func manyStrokeLap(strokeCount: Int = 12, lengthMeters: Double = 25) -> WorkoutHandPath.Lap {
        var points: [WorkoutHandPath.Point] = []
        for k in 0...(strokeCount * 4) {
            let frac = Float(k) / Float(strokeCount * 4)
            points.append(point(t: frac * 20, angle: frac * Float(strokeCount) * 2 * .pi, axial: frac * Float(lengthMeters)))
        }
        return lap(points: points, lengthMeters: lengthMeters, strokeCount: strokeCount)
    }

    func testBuildProducesExactlyOneStartAndOneEndMarker() {
        let drawing = HandPathScene.build(lap: manyStrokeLap(), radiusMeters: 0.6, camera: .default)
        XCTAssertEqual(drawing.markers.count, 2)
        XCTAssertEqual(drawing.markers.filter { $0.kind == .start }.count, 1)
        XCTAssertEqual(drawing.markers.filter { $0.kind == .end }.count, 1)
    }

    /// The exact defect the owner reported: rotated to look straight back down the lane, can the
    /// start still be told apart from the end? Every stroke here is a whole 2π turn (matching the
    /// real model), so the tube's OWN first/last points land at the same clock position — this
    /// test is only meaningful because `CapMarker` deliberately does NOT use those literal angles
    /// (see its doc comment). If it regressed to using them, this test would catch the two markers
    /// collapsing to the same screen point under exactly this camera.
    func testStartAndEndMarkersRemainScreenSeparatedLookingStraightDownTheLane() {
        let drawing = HandPathScene.build(lap: manyStrokeLap(strokeCount: 11), radiusMeters: 0.6, camera: .downLane)
        guard let start = drawing.markers.first(where: { $0.kind == .start }),
              let end = drawing.markers.first(where: { $0.kind == .end }) else {
            return XCTFail("expected both markers")
        }
        let dx = start.point.x - end.point.x
        let dy = start.point.y - end.point.y
        let screenDistance = (dx * dx + dy * dy).squareRoot()
        XCTAssertGreaterThan(screenDistance, 0.1, "start and end must not collapse to the same screen point")
    }

    /// Same check across every offered camera preset, not just `.downLane` — the separation must
    /// hold generally, not only in the one case singled out above.
    func testStartAndEndMarkersRemainScreenSeparatedAcrossEveryCameraPreset() {
        for camera in [HandPathScene.Camera.side, .above, .downLane, .default] {
            let drawing = HandPathScene.build(lap: manyStrokeLap(strokeCount: 9), radiusMeters: 0.6, camera: camera)
            guard let start = drawing.markers.first(where: { $0.kind == .start }),
                  let end = drawing.markers.first(where: { $0.kind == .end }) else {
                return XCTFail("expected both markers for camera \(camera)")
            }
            let dx = start.point.x - end.point.x
            let dy = start.point.y - end.point.y
            let screenDistance = (dx * dx + dy * dy).squareRoot()
            XCTAssertGreaterThan(screenDistance, 0.1, "camera \(camera) collapsed start/end to the same screen point")
        }
    }

    // MARK: - Content aspect ratio (`HandPathView`'s canvas sizing) — never degenerate, never
    // unbounded. Moved here from `HandPathView` (previously untested — nothing under BananaTests
    // exercised that file) specifically so this clamp has real coverage: a swim detail screen's
    // `.aspectRatio(_:contentMode: .fit)` call takes this value directly, and an unclamped 0 or
    // an unbounded ratio there would size the card's frame to zero or absurdly tall/wide.

    private func segment(ax: Double, ay: Double, bx: Double, by: Double) -> HandPathScene.Segment {
        HandPathScene.Segment(a: HandPathScene.ProjectedPoint(x: ax, y: ay, depth: 0),
                               b: HandPathScene.ProjectedPoint(x: bx, y: by, depth: 0),
                               depth: 0, effort: 0.5, width: 1, opacity: 1)
    }

    func testAspectRatioOfAnEntirelyEmptyDrawingIsTheFallback() {
        let empty = HandPathScene.Drawing(segments: [], laneBehind: [], laneFront: [], markers: [])
        XCTAssertEqual(HandPathScene.aspectRatio(for: empty), HandPathScene.fallbackContentAspectRatio)
        XCTAssertNil(HandPathScene.boundingBox(drawing: empty))
    }

    /// Almost all vertical span, essentially no horizontal span — e.g. a `downLane` view of a lap
    /// with almost no lateral wobble. Without the clamp this would divide toward 0, sizing the
    /// card's frame to a sliver.
    func testAspectRatioClampsAVanishinglyNarrowDrawingToTheMinimum() {
        let drawing = HandPathScene.Drawing(segments: [segment(ax: 0, ay: -50, bx: 0.0001, by: 50)],
                                             laneBehind: [], laneFront: [], markers: [])
        let ratio = HandPathScene.aspectRatio(for: drawing)
        XCTAssertEqual(ratio, HandPathScene.minContentAspectRatio, accuracy: 0.0001)
    }

    /// Almost all horizontal span, essentially no vertical span — e.g. a near-flat `side` view.
    /// Without the clamp this would divide toward infinity, sizing the card's frame absurdly wide
    /// (or, since `.aspectRatio` divides height by it, absurdly short).
    func testAspectRatioClampsAVanishinglyFlatDrawingToTheMaximum() {
        let drawing = HandPathScene.Drawing(segments: [segment(ax: -50, ay: 0, bx: 50, by: 0.0001)],
                                             laneBehind: [], laneFront: [], markers: [])
        let ratio = HandPathScene.aspectRatio(for: drawing)
        XCTAssertEqual(ratio, HandPathScene.maxContentAspectRatio, accuracy: 0.0001)
    }

    /// A single degenerate point (zero span in both axes) must still clamp into range rather than
    /// divide 0/0 into NaN.
    func testAspectRatioOfAZeroSpanDrawingIsFiniteAndInRange() {
        let drawing = HandPathScene.Drawing(segments: [segment(ax: 3, ay: 3, bx: 3, by: 3)],
                                             laneBehind: [], laneFront: [], markers: [])
        let ratio = HandPathScene.aspectRatio(for: drawing)
        XCTAssertTrue(ratio.isFinite)
        XCTAssertGreaterThanOrEqual(ratio, HandPathScene.minContentAspectRatio)
        XCTAssertLessThanOrEqual(ratio, HandPathScene.maxContentAspectRatio)
    }

    /// Real geometry from `build`, not a hand-built degenerate drawing — every camera preset,
    /// including `above` (exactly ±90° elevation, the one place a naive projection could collapse
    /// an axis), must still produce a bounded, finite ratio.
    func testAspectRatioStaysBoundedAcrossEveryCameraPreset() {
        let points = stride(from: Double(0), to: 4 * Double.pi, by: 0.3).map {
            point(t: Float($0), angle: Float($0), axial: Float($0))
        }
        let oneLap = lap(points: points, lengthMeters: 25)
        for camera in [HandPathScene.Camera.side, .above, .downLane, .default] {
            let drawing = HandPathScene.build(lap: oneLap, radiusMeters: 0.6, camera: camera)
            let ratio = HandPathScene.aspectRatio(for: drawing)
            XCTAssertTrue(ratio.isFinite)
            XCTAssertGreaterThanOrEqual(ratio, HandPathScene.minContentAspectRatio)
            XCTAssertLessThanOrEqual(ratio, HandPathScene.maxContentAspectRatio)
        }
    }
}
