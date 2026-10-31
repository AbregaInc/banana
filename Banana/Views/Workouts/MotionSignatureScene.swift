import Foundation

/// Pure 3D→2D geometry for the stroke/stride-signature point cloud, drawn by a depth-sorted
/// `Canvas` instead of `Chart3D` — the same shape of fix `HandPathScene`/`HandPathView` already
/// made for the hand path, and for the same reason: Swift Charts could not draw this fast enough.
///
/// Measured, not guessed (see `WorkoutMotionSection.MotionSignatureCard`'s doc comment for the
/// full numbers): on the owner's real BFCCD614… swim, opening the `Chart3D` signature stalled the
/// UI to ~3.5 fps for roughly 12.5 SECONDS rendering one lap's ~2,900 points — measured with a
/// WARM derived-analysis disk cache already in place, so the stall was rendering, not
/// recomputation. The `Canvas` hand path, same app, same launch, same real data, settled to a
/// steady 59 fps within about 1.5 seconds. This file is what replaces `Chart3D` with that same
/// approach for the signature.
///
/// No SwiftUI/AppKit/UIKit import — every function here is a deterministic transform over plain
/// point data, so `BananaTests` can exercise it directly without a host view, matching
/// `HandPathScene`'s own contract.
enum MotionSignatureScene {

    // MARK: - Camera

    /// Simpler than `HandPathScene.Camera`: a point cloud has no lane radius to exaggerate and no
    /// separate zoom control here (the view fits the cloud to its canvas via `aspectRatio(for:)`
    /// the same way `HandPathScene`'s consumer does) — just the two orbit angles.
    struct Camera: Sendable, Equatable {
        /// Radians. 0 faces the cloud straight on; increasing it orbits around its own Y axis.
        var azimuth: Double
        /// Radians.
        var elevation: Double

        /// A modest off-axis default, not dead-on — the same reasoning as `HandPathScene.Camera
        /// .default`'s doc comment: viewed exactly face-on, a roughly-symmetric point cloud's near
        /// and far halves can overlap in screen space with nothing to separate them. A small tilt
        /// gives the depth falloff below something to show.
        static let `default` = Camera(azimuth: 0.55, elevation: 0.32)
    }

    // MARK: - Input / output point shapes

    /// One acceleration sample, already phase-resampled — mirrors
    /// `WorkoutMotionSection.MotionSignatureCard.SignaturePoint`'s fields exactly; kept as a
    /// separate type here (rather than importing that private view type) so this file stays
    /// SwiftUI-free.
    struct Point: Sendable, Equatable {
        var x: Float
        var y: Float
        var z: Float
        /// 0..<100 — position within its cycle's phase-resampled arc. Drives the hue for a
        /// non-`dim` point (see `WorkoutMotionSection.MotionSignatureCard.phaseColor(_:)`).
        var phase: Int
        /// `Cycle.offBaseline` — drawn faded and uncolored rather than phase-ramped, same meaning
        /// as the flagged/dim split the old `Chart3D` version drew as two separate `ForEach`s.
        var dim: Bool
    }

    struct ProjectedPoint: Sendable, Equatable {
        var x: Double
        var y: Double
        /// Camera-space depth; larger = farther from the viewer. Used only for painter's-algorithm
        /// sorting and `falloff` below — never drawn directly.
        var depth: Double
        var phase: Int
        var dim: Bool
        /// 0...1, nearer points closer to 1 — the caller scales both dot radius and opacity by
        /// this so the near half of the cloud reads as solid/large and the far half recedes,
        /// matching `HandPathScene.Segment`'s width/opacity falloff.
        var falloff: Double
    }

    /// Depth-sorted back → front, ready for a painter's-algorithm `Canvas` renderer.
    struct Drawing: Sendable {
        var points: [ProjectedPoint]
    }

    // MARK: - Tunables (same near/far falloff shape as `HandPathScene`'s tube)

    private static let nearFalloff = 1.0
    private static let farFalloff = 0.5

    // MARK: - Entry point

    /// Builds the full depth-sorted point cloud for one page's cycles. Empty input yields an
    /// empty `Drawing` — never a crash, never a fabricated point.
    static func build(points: [Point], camera: Camera) -> Drawing {
        guard !points.isEmpty else { return Drawing(points: []) }
        let rotation = Rotation(camera: camera)

        var projected: [(point: ProjectedPoint, depth: Double)] = points.map { p in
            let r = rotation.project(x: Double(p.x), y: Double(p.y), z: Double(p.z))
            return (ProjectedPoint(x: r.x, y: r.y, depth: r.depth, phase: p.phase, dim: p.dim, falloff: 0), r.depth)
        }

        let depths = projected.map(\.depth)
        let minDepth = depths.min() ?? 0
        let maxDepth = depths.max() ?? 0
        let span = maxDepth - minDepth
        for i in projected.indices {
            let normalized = span > 1e-9 ? (projected[i].depth - minDepth) / span : 0.5
            projected[i].point.falloff = nearFalloff + (farFalloff - nearFalloff) * normalized
        }

        // Painter's algorithm: farthest (largest depth) first, nearest last.
        let sorted = projected.map(\.point).sorted { $0.depth > $1.depth }
        return Drawing(points: sorted)
    }

    // MARK: - Sizing (bounding box + content aspect ratio, same role as `HandPathScene`'s)

    static func boundingBox(drawing: Drawing) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        guard !drawing.points.isEmpty else { return nil }
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for p in drawing.points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return (minX, maxX, minY, maxY)
    }

    /// A point cloud reads reasonably close to square from most angles (unlike the hand path's
    /// long, shallow tube), so this stays tighter than `HandPathScene`'s much wider clamp range.
    static let minContentAspectRatio = 0.6
    static let maxContentAspectRatio = 2.2
    /// Only reachable when `drawing` has no points at all — `MotionSignatureCard` already gates
    /// on `!pageCycles.isEmpty` before calling into this file, so this is a safety net, not a
    /// value expected to show up in the running app.
    static let fallbackContentAspectRatio = 1.2

    static func aspectRatio(for drawing: Drawing) -> Double {
        guard let box = boundingBox(drawing: drawing) else { return fallbackContentAspectRatio }
        let spanX = max(box.maxX - box.minX, 0.001)
        let spanY = max(box.maxY - box.minY, 0.001)
        return min(max(spanX / spanY, minContentAspectRatio), maxContentAspectRatio)
    }

    // MARK: - Rotation

    /// Same convention as `HandPathScene.Rotation`: yaw about world Y by azimuth, then pitch about
    /// the yawed X axis by elevation — the mental model transfers between the two 3D views.
    private struct Rotation {
        let cosAz: Double, sinAz: Double, cosEl: Double, sinEl: Double

        init(camera: Camera) {
            cosAz = cos(camera.azimuth); sinAz = sin(camera.azimuth)
            cosEl = cos(camera.elevation); sinEl = sin(camera.elevation)
        }

        func project(x: Double, y: Double, z: Double) -> (x: Double, y: Double, depth: Double) {
            let x1 = x * cosAz - z * sinAz
            let z1 = x * sinAz + z * cosAz
            let y1 = y
            let y2 = y1 * cosEl - z1 * sinEl
            let z2 = y1 * sinEl + z1 * cosEl
            return (x1, y2, z2)
        }
    }
}
