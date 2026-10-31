import XCTest

/// Synthetic-fixture coverage for `MotionSignatureScene`'s pure geometry — the `Canvas`-based
/// replacement for the stroke-signature card's old `Chart3D` point cloud (see
/// `WorkoutMotionSection.MotionSignatureCard`'s doc comment for the measured before/after). Same
/// "build everything directly in Swift" pattern as `HandPathSceneTests`/`WorkoutMotionAnalysisTests`
/// — no `WorkoutMotionAnalysis.analyze` call, no binary sample fixture.
final class MotionSignatureSceneTests: XCTestCase {

    private func point(x: Float, y: Float, z: Float, phase: Int = 0, dim: Bool = false) -> MotionSignatureScene.Point {
        MotionSignatureScene.Point(x: x, y: y, z: z, phase: phase, dim: dim)
    }

    // MARK: - A known point projects where expected

    func testKnownPointProjectsUnrotatedAtZeroCamera() {
        // azimuth 0, elevation 0: both rotations are identity, so (x, y, depth) == (x, y, z).
        let p = point(x: 3, y: -2, z: 5)
        let projected = MotionSignatureScene.build(points: [p], camera: MotionSignatureScene.Camera(azimuth: 0, elevation: 0)).points[0]
        XCTAssertEqual(projected.x, 3, accuracy: 1e-9)
        XCTAssertEqual(projected.y, -2, accuracy: 1e-9)
        XCTAssertEqual(projected.depth, 5, accuracy: 1e-9)
    }

    func testNinetyDegreeAzimuthSwapsXAndDepth() {
        // Yaw 90° about Y: world +X rotates entirely into +depth, world +Z rotates entirely into -X.
        let p = point(x: 1, y: 0, z: 0)
        let projected = MotionSignatureScene.build(points: [p], camera: MotionSignatureScene.Camera(azimuth: .pi / 2, elevation: 0)).points[0]
        XCTAssertEqual(projected.x, 0, accuracy: 1e-6)
        XCTAssertEqual(projected.depth, 1, accuracy: 1e-6)
    }

    // MARK: - Default camera is tilted, not dead-on (same reasoning as `HandPathScene.Camera.default`)

    func testDefaultCameraIsTiltedOffZero() {
        XCTAssertNotEqual(MotionSignatureScene.Camera.default.azimuth, 0)
        XCTAssertNotEqual(MotionSignatureScene.Camera.default.elevation, 0)
    }

    // MARK: - Depth falloff actually varies with depth, not just gets computed to a constant

    func testNearPointsHaveGreaterFalloffThanFarPoints() {
        // Straight down the Z axis at the default camera's azimuth/elevation isn't needed here —
        // any camera separates these three colinear-in-Z points by depth.
        let points = [point(x: 0, y: 0, z: -5), point(x: 0, y: 0, z: 0), point(x: 0, y: 0, z: 5)]
        let drawing = MotionSignatureScene.build(points: points, camera: .default)
        guard let nearest = drawing.points.min(by: { $0.depth < $1.depth }),
              let farthest = drawing.points.max(by: { $0.depth < $1.depth }) else {
            return XCTFail("expected points")
        }
        XCTAssertGreaterThan(nearest.falloff, farthest.falloff)
        for p in drawing.points {
            XCTAssertGreaterThanOrEqual(p.falloff, 0)
            XCTAssertLessThanOrEqual(p.falloff, 1)
        }
    }

    /// All points at the same depth: `span` is 0, and the falloff calculation must fall back to
    /// the documented midpoint (0.5 normalized) rather than divide by zero into NaN.
    func testEqualDepthPointsGetTheMidpointFalloffNotNaN() {
        let points = [point(x: -3, y: 0, z: 0), point(x: 3, y: 0, z: 0)]
        // Side-on (elevation 0, azimuth 0): both points have depth 0 — identical depth.
        let drawing = MotionSignatureScene.build(points: points, camera: MotionSignatureScene.Camera(azimuth: 0, elevation: 0))
        for p in drawing.points {
            XCTAssertTrue(p.falloff.isFinite)
            XCTAssertEqual(p.falloff, 0.75, accuracy: 1e-9)   // near(1.0) + (far(0.5) - near(1.0)) * 0.5
        }
    }

    // MARK: - Depth sorting orders back to front

    func testPointsAreDepthSortedFarthestFirst() {
        let points = stride(from: Float(-5), to: 5, by: 0.7).map { point(x: $0, y: $0 * 0.3, z: $0 * -0.5) }
        let drawing = MotionSignatureScene.build(points: points, camera: .default)
        XCTAssertFalse(drawing.points.isEmpty)
        for i in 0..<max(drawing.points.count - 1, 0) {
            XCTAssertGreaterThanOrEqual(drawing.points[i].depth, drawing.points[i + 1].depth,
                                        "point \(i) should not be nearer than point \(i + 1) in a back-to-front list")
        }
    }

    // MARK: - Phase and dim carry through the projection unchanged

    func testPhaseAndDimCarryThroughProjectionUnchanged() {
        let points = [point(x: 1, y: 1, z: 1, phase: 42, dim: true), point(x: -1, y: -1, z: -1, phase: 7, dim: false)]
        let drawing = MotionSignatureScene.build(points: points, camera: .default)
        let phases = Set(drawing.points.map(\.phase))
        XCTAssertEqual(phases, [42, 7])
        XCTAssertTrue(drawing.points.contains { $0.phase == 42 && $0.dim })
        XCTAssertTrue(drawing.points.contains { $0.phase == 7 && !$0.dim })
    }

    // MARK: - An empty page yields no points and no crash

    func testEmptyInputYieldsAnEmptyDrawing() {
        let drawing = MotionSignatureScene.build(points: [], camera: .default)
        XCTAssertTrue(drawing.points.isEmpty)
        XCTAssertNil(MotionSignatureScene.boundingBox(drawing: drawing))
    }

    // MARK: - Content aspect ratio — never degenerate, never unbounded (same rationale as
    // `HandPathSceneTests`'s coverage of `HandPathScene.aspectRatio`: `MotionSignatureCard`'s
    // `.aspectRatio(_:contentMode: .fit)` call takes this value directly, and an unclamped 0 or an
    // unbounded ratio there would size the card's frame to zero or absurdly tall/wide)

    private func projected(x: Double, y: Double) -> MotionSignatureScene.ProjectedPoint {
        MotionSignatureScene.ProjectedPoint(x: x, y: y, depth: 0, phase: 0, dim: false, falloff: 1)
    }

    func testAspectRatioOfAnEmptyDrawingIsTheFallback() {
        let empty = MotionSignatureScene.Drawing(points: [])
        XCTAssertEqual(MotionSignatureScene.aspectRatio(for: empty), MotionSignatureScene.fallbackContentAspectRatio)
    }

    func testAspectRatioClampsAVanishinglyNarrowDrawingToTheMinimum() {
        let drawing = MotionSignatureScene.Drawing(points: [projected(x: 0, y: -50), projected(x: 0.0001, y: 50)])
        let ratio = MotionSignatureScene.aspectRatio(for: drawing)
        XCTAssertEqual(ratio, MotionSignatureScene.minContentAspectRatio, accuracy: 0.0001)
    }

    func testAspectRatioClampsAVanishinglyFlatDrawingToTheMaximum() {
        let drawing = MotionSignatureScene.Drawing(points: [projected(x: -50, y: 0), projected(x: 50, y: 0.0001)])
        let ratio = MotionSignatureScene.aspectRatio(for: drawing)
        XCTAssertEqual(ratio, MotionSignatureScene.maxContentAspectRatio, accuracy: 0.0001)
    }

    /// A single degenerate point (zero span in both axes) must still clamp into range rather than
    /// divide 0/0 into NaN.
    func testAspectRatioOfAZeroSpanDrawingIsFiniteAndInRange() {
        let drawing = MotionSignatureScene.Drawing(points: [projected(x: 4, y: 4)])
        let ratio = MotionSignatureScene.aspectRatio(for: drawing)
        XCTAssertTrue(ratio.isFinite)
        XCTAssertGreaterThanOrEqual(ratio, MotionSignatureScene.minContentAspectRatio)
        XCTAssertLessThanOrEqual(ratio, MotionSignatureScene.maxContentAspectRatio)
    }

    /// Real geometry from `build`, not a hand-built degenerate drawing, across a spread of
    /// cameras including the default — every one must produce a bounded, finite ratio.
    func testAspectRatioStaysBoundedAcrossEveryCamera() {
        let points = stride(from: Float(0), to: 4 * Float.pi, by: 0.3).map {
            point(x: sin($0), y: cos($0) * 0.5, z: $0 * 0.1)
        }
        for camera in [MotionSignatureScene.Camera(azimuth: 0, elevation: 0),
                       MotionSignatureScene.Camera(azimuth: .pi / 2, elevation: 0),
                       MotionSignatureScene.Camera(azimuth: 0, elevation: .pi / 2),
                       .default] {
            let drawing = MotionSignatureScene.build(points: points, camera: camera)
            let ratio = MotionSignatureScene.aspectRatio(for: drawing)
            XCTAssertTrue(ratio.isFinite)
            XCTAssertGreaterThanOrEqual(ratio, MotionSignatureScene.minContentAspectRatio)
            XCTAssertLessThanOrEqual(ratio, MotionSignatureScene.maxContentAspectRatio)
        }
    }
}
