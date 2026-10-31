import Foundation

/// Pure 3D→2D geometry for the hand-path ("cylinder") view: an orbit camera, a rotation +
/// projection pipeline, and depth-sorted drawable segments for a painter's-algorithm `Canvas`
/// renderer. No SwiftUI/AppKit/UIKit import — every function here is a deterministic transform
/// over `WorkoutHandPath.Lap`, so `BananaTests` can exercise it directly without a host view, and
/// `HandPathView` never recomputes anything from raw samples — it only projects what
/// `WorkoutHandPath` already built.
///
/// Coordinate system, before any camera rotation, one unit = one metre:
///   world X = `point.axial`               — distance along the lane from the wall this lap started at
///   world Y = `radius * cos(point.angle)` — the stroke's rotation, "up" component
///   world Z = `radius * sin(point.angle)` — the stroke's rotation, "depth" component
/// `radius` is the lap's true radius (`Analysis.radiusMeters`) times the camera's
/// `radiusExaggeration` — the exaggeration is applied only in this projection step, never baked
/// back into the model, so a caller that wants the true radius for its caption still has it
/// untouched in `Analysis.radiusMeters`.
///
/// The camera is a two-angle orbit — azimuth: yaw about world Y; elevation: pitch about the
/// yawed X axis — the same shape as `Chart3DPose`, deliberately, so the mental model transfers.
/// Both angles are applied directly as a fixed rotation for a single `build`/`project` call, never
/// accumulated through a running matrix, so there is no gimbal-lock degeneracy to guard against at
/// any azimuth/elevation pair, including the "from above" preset's exact ±90° elevation.
enum HandPathScene {

    // MARK: - Camera

    struct Camera: Sendable, Equatable {
        /// Radians. 0 faces the lane side-on; increasing it orbits around the lane's long axis.
        var azimuth: Double
        /// Radians. `HandPathView` clamps this away from the poles during an interactive drag for
        /// a comfortable orbit feel — the maths below is exact at any value, including ±π/2.
        var elevation: Double
        /// Uniform 2D scale the caller applies on top of this file's scene-unit output, layered
        /// over its own fit-to-canvas scale. Kept on `Camera` so one value fully describes "how
        /// the user last left the view".
        var zoom: Double
        /// Multiplies the lap's true radius before projection. Spec default: 4×.
        var radiusExaggeration: Double

        static let side = Camera(azimuth: 0, elevation: 0, zoom: 1, radiusExaggeration: 4)
        static let above = Camera(azimuth: 0, elevation: .pi / 2, zoom: 1, radiusExaggeration: 4)
        static let downLane = Camera(azimuth: .pi / 2, elevation: 0, zoom: 1, radiusExaggeration: 4)

        /// A modest tilt off dead side-on, not `.side` itself. At azimuth 0 / elevation 0 a helix
        /// viewed exactly perpendicular to its own axis projects to a pure sinusoid: the near and
        /// far halves of every coil land on exactly the same screen position, so none of the depth
        /// cues this file computes (segment width/opacity falloff, the lane's behind/front split)
        /// has anything to show — the tube reads as a flat 2D wave instead of a spiral in space.
        /// ~20° azimuth and ~17° elevation is enough to visibly separate the near half of a coil
        /// from the far half (matching the agreed reference render) while staying small enough
        /// that the view still reads primarily as a side profile — the coaching signal here is
        /// pitch (distance per stroke), which a dead down-the-lane view would destroy outright and
        /// a much steeper tilt would start to obscure. `.side` remains one tap away in
        /// `cameraMenu` for a viewer who explicitly wants the literal flat profile; it just isn't
        /// what a fresh view opens on any more.
        static let `default` = Camera(azimuth: 0.35, elevation: 0.30, zoom: 1, radiusExaggeration: 4)
    }

    // MARK: - Projected geometry

    /// One point after rotation, in metre-scale scene units — same units as the model, not
    /// pixels. The caller applies exactly one final uniform scale + translate to fit its canvas
    /// (never independent X/Y scales, or the circular cross-section would draw as an ellipse
    /// regardless of camera angle).
    struct ProjectedPoint: Sendable, Equatable {
        var x: Double
        var y: Double
        /// Camera-space depth; larger = farther from the viewer. Not itself drawn — used only for
        /// painter's-algorithm sorting and the width falloff below.
        var depth: Double
    }

    /// One drawable piece of the tube's centreline.
    struct Segment: Sendable, Equatable {
        var a: ProjectedPoint
        var b: ProjectedPoint
        /// Sort key — the segment's own midpoint depth.
        var depth: Double
        /// 0...1, mean of the two endpoints' `Point.effort` — drives the drawn colour.
        var effort: Float
        /// Scene units; already includes the depth falloff, so the caller draws it as-is.
        var width: Double
        /// 0...1, already includes the same depth falloff as `width` (nearer segments closer to
        /// 1, farther segments dimmer) — the caller multiplies its stroke color's alpha by this
        /// as-is, so the near half of the tube reads as solid and the far half recedes instead of
        /// every segment along the spiral drawing at identical, flat opacity regardless of depth.
        var opacity: Double
    }

    /// One piece of the reference lane: an interval ring, a wall marker (the two end rings at
    /// axial 0 and the lap length), or one of the two longitudinal silhouette lines.
    struct LaneMark: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case ring, wallMarker, silhouette }
        var a: ProjectedPoint
        var b: ProjectedPoint
        var depth: Double
        var kind: Kind
        /// Whether this piece sits behind the lane's own centre axis at this axial position (see
        /// `Drawing` doc comment) — the caller draws `laneBehind`, then the tube, then
        /// `laneFront`, so the tube reads as threading through the guide instead of floating
        /// uniformly in front of or behind it.
        var isBehindAxis: Bool
    }

    /// Marks the wall this lap started at ("S") and the wall it finished at ("F") — unmistakable
    /// from any camera angle, including looking straight back down the lane, which is exactly the
    /// case the owner asked to be able to rotate to and still read: once the view is rotated far
    /// enough, colour alone (already spent on effort) can't carry the distinction, and neither can
    /// screen POSITION if the marker sits on the tube's own literal first/last stroke angle —
    /// every stroke is exactly one full turn (see `WorkoutHandPath`'s file doc comment), so after a
    /// whole number of turns the helix always returns to the SAME angular "clock position" it
    /// started at. Placed at the literal stroke angle, start and end would project to the exact
    /// same screen point in a dead-on down-the-lane view.
    ///
    /// The fix: place these at a FIXED reference angle instead of the lap's actual first/last
    /// stroke angle — 0 for start, the diametrically opposite π for end — rather than tied to the
    /// per-stroke phase (which is itself an even, unmeasured spread within a stroke, not a
    /// measurement; see `WorkoutHandPath.buildPoints`'s doc comment, so no real information is
    /// lost by choosing a legible display angle over the literal one). Placing them a half-turn
    /// apart keeps their screen projections separated at every camera angle except a knife-edge
    /// elevation exactly at the down-the-lane azimuth — not a real preset, and not an angle an
    /// ordinary drag lands on by accident.
    struct CapMarker: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case start, end }
        var point: ProjectedPoint
        var kind: Kind
    }

    /// A camera's-eye view of one lap, ready for a painter's-algorithm `Canvas` renderer. Every
    /// list is already depth-sorted back → front (drawn in list order).
    ///
    /// `laneBehind`/`laneFront` split by comparing each lane-guide point's depth against the
    /// lane's own centre-axis depth (radius 0) at that same axial position, not against the
    /// tube's actual nearby stroke phase — a ring around a cylinder is behind the cylinder's own
    /// axis on exactly the far half of that ring regardless of exactly where the spiral happens to
    /// be at that length, so this gives the correct "tube threads through the ring" read without
    /// needing to interpolate the tube's own path near the point being classified.
    ///
    /// `markers` is NOT depth-sorted into `laneBehind`/`laneFront` like the rest of the lane
    /// geometry — the caller draws it last, always on top, at constant opacity regardless of depth
    /// (see `HandPathView.draw(markers:...)`), because "unmistakable from any angle" means never
    /// fading into the tube or the lane the way ordinary depth-cued geometry is allowed to.
    struct Drawing: Sendable {
        var segments: [Segment]
        var laneBehind: [LaneMark]
        var laneFront: [LaneMark]
        var markers: [CapMarker]
    }

    // MARK: - Tunables

    /// Points per drawn ring — matches `WorkoutHandPath`'s own points-per-turn so a reference ring
    /// reads at the same fidelity as the tube threading through it (the spec's own read on
    /// rendered candidates: 16 facets look faceted, 48 add nothing over 24).
    private static let ringPointsPerTurn = 24
    /// Regular reference rings along the lane, not counting the two wall-marker rings at the ends.
    private static let intervalRingCount = 6
    /// Tube half-width as a fraction of the exaggerated (displayed) radius — reads as a tube, not
    /// a hairline or a solid rod.
    private static let tubeWidthFraction = 0.32
    private static let nearWidthScale = 1.15
    private static let farWidthScale = 0.55
    /// Opacity depth falloff, same normalized-depth curve as the width falloff above — the near
    /// half of the tube draws near-solid, the far half recedes but never disappears entirely (a
    /// fully transparent far side would make the spiral look broken rather than merely distant).
    private static let nearOpacityScale = 1.0
    private static let farOpacityScale = 0.45

    // MARK: - Single-point projection (also the primitive `build` uses internally)

    /// Projects one model point using the given camera and the lap's true radius (the camera's
    /// `radiusExaggeration` is applied internally). Exposed directly, not only via `build`, so a
    /// known point's projection can be asserted on its own.
    static func project(_ point: WorkoutHandPath.Point, radiusMeters: Double, camera: Camera) -> ProjectedPoint {
        let displayRadius = radiusMeters * max(camera.radiusExaggeration, 0)
        return Rotation(camera: camera).project(axial: Double(point.axial), angle: Double(point.angle), radius: displayRadius)
    }

    // MARK: - Entry point

    /// Reference angle `CapMarker`s are drawn at — see `CapMarker`'s doc comment for why this is a
    /// fixed display angle rather than the lap's actual first/last stroke angle.
    private static let startMarkerAngle: Double = 0
    private static let endMarkerAngle: Double = .pi

    /// Builds the full depth-sorted drawing for one lap. Returns an entirely empty `Drawing` —
    /// never a crash, never a fabricated shape — when the lap has no length, or `radiusMeters` is
    /// not a usable number; a lap with zero or one point yields no `segments` (a tube needs at
    /// least two points) but can still yield lane geometry, since that depends only on the lap's
    /// length, not its point count.
    static func build(lap: WorkoutHandPath.Lap, radiusMeters: Double, camera: Camera) -> Drawing {
        guard lap.lengthMeters > 0, radiusMeters.isFinite, radiusMeters >= 0 else {
            return Drawing(segments: [], laneBehind: [], laneFront: [], markers: [])
        }
        let displayRadius = radiusMeters * max(camera.radiusExaggeration, 0)
        let rotation = Rotation(camera: camera)   // hoists cos/sin(azimuth) and cos/sin(elevation) once

        let segments = tubeSegments(points: lap.points, radius: displayRadius, rotation: rotation)

        var behind: [LaneMark] = []
        var front: [LaneMark] = []
        func file(_ marks: [LaneMark]) {
            for mark in marks {
                if mark.isBehindAxis { behind.append(mark) } else { front.append(mark) }
            }
        }
        file(ring(axial: 0, radius: displayRadius, rotation: rotation, kind: .wallMarker))
        file(ring(axial: lap.lengthMeters, radius: displayRadius, rotation: rotation, kind: .wallMarker))
        if intervalRingCount > 0 {
            let step = lap.lengthMeters / Double(intervalRingCount + 1)
            for i in 1...intervalRingCount {
                file(ring(axial: step * Double(i), radius: displayRadius, rotation: rotation, kind: .ring))
            }
        }
        file(silhouetteLines(length: lap.lengthMeters, radius: displayRadius, rotation: rotation, camera: camera))

        behind.sort { $0.depth > $1.depth }
        front.sort { $0.depth > $1.depth }

        let markers = [
            CapMarker(point: rotation.project(axial: 0, angle: startMarkerAngle, radius: displayRadius), kind: .start),
            CapMarker(point: rotation.project(axial: lap.lengthMeters, angle: endMarkerAngle, radius: displayRadius), kind: .end),
        ]

        return Drawing(segments: segments, laneBehind: behind, laneFront: front, markers: markers)
    }

    // MARK: - Sizing (bounding box + content aspect ratio — used by `HandPathView` to size its
    // canvas; kept here, not there, so `BananaTests` can exercise the clamp directly without a
    // host view, same reasoning as every other pure function in this file).

    /// One drawing's bounding box in scene units, or `nil` only when the drawing is entirely empty
    /// (no segments and no lane geometry — a zero-length lap `build` already refuses to produce).
    /// Shared by `HandPathView.fitTransform` (needs the box to compute a fit scale) and
    /// `aspectRatio(for:)` below (needs it to size the canvas to the content) — one bounding-box
    /// pass over the drawing's points instead of walking the same lists twice.
    static func boundingBox(drawing: Drawing) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        func consider(_ p: ProjectedPoint) {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for segment in drawing.segments { consider(segment.a); consider(segment.b) }
        for mark in drawing.laneBehind { consider(mark.a); consider(mark.b) }
        for mark in drawing.laneFront { consider(mark.a); consider(mark.b) }
        for marker in drawing.markers { consider(marker.point) }
        guard minX.isFinite, minY.isFinite else { return nil }
        return (minX, maxX, minY, maxY)
    }

    /// Content's own bounding-box aspect ratio (width / height, in scene units), clamped to a sane
    /// range — never degenerate (a near-zero-height drawing, e.g. a `downLane` view of a lap with
    /// almost no lateral wobble) and never unbounded (a near-zero-width one). `HandPathView` passes
    /// this to `.aspectRatio(_:contentMode:.fit)` so the card's rendered height shrinks to match a
    /// wide, shallow helix instead of sitting inside a fixed tall frame with empty space above and
    /// below it — the defect that fixes is a layout problem, not a drawing one, so it's solved at
    /// the SwiftUI frame level rather than by padding the scene's own coordinates. Recomputed per
    /// camera (a `downLane` view is roughly square; a `side` view is wide and shallow), so the
    /// card's shape tracks whatever the current view actually looks like.
    static let minContentAspectRatio = 0.8
    static let maxContentAspectRatio = 5.5
    /// Only reachable if `drawing` has no geometry at all — every lap `WorkoutHandPath.analyze`
    /// produces has `lengthMeters > 0` and therefore at least lane geometry, so this is a safety
    /// net, not a value expected to show up in the running app.
    static let fallbackContentAspectRatio = 2.2

    static func aspectRatio(for drawing: Drawing) -> Double {
        guard let box = boundingBox(drawing: drawing) else { return fallbackContentAspectRatio }
        let spanX = max(box.maxX - box.minX, 0.001)
        let spanY = max(box.maxY - box.minY, 0.001)
        return min(max(spanX / spanY, minContentAspectRatio), maxContentAspectRatio)
    }

    // MARK: - Tube

    private static func tubeSegments(points: [WorkoutHandPath.Point], radius: Double, rotation: Rotation) -> [Segment] {
        guard points.count > 1 else { return [] }
        let projected = points.map { (point: rotation.project(axial: Double($0.axial), angle: Double($0.angle), radius: radius), effort: $0.effort) }
        let depths = projected.map { $0.point.depth }
        let minDepth = depths.min() ?? 0
        let maxDepth = depths.max() ?? 0
        let depthSpan = maxDepth - minDepth

        var segments: [Segment] = []
        segments.reserveCapacity(projected.count - 1)
        for i in 0..<(projected.count - 1) {
            let a = projected[i]
            let b = projected[i + 1]
            let midDepth = (a.point.depth + b.point.depth) / 2
            let normalized = depthSpan > 1e-9 ? (midDepth - minDepth) / depthSpan : 0.5
            let widthScale = nearWidthScale + (farWidthScale - nearWidthScale) * normalized
            let width = max(radius * tubeWidthFraction * widthScale, 0)
            let opacity = min(max(nearOpacityScale + (farOpacityScale - nearOpacityScale) * normalized, 0), 1)
            let effort = (a.effort + b.effort) / 2
            segments.append(Segment(a: a.point, b: b.point, depth: midDepth, effort: effort, width: width, opacity: opacity))
        }
        // Painter's algorithm: farthest (largest depth) first, nearest last, so the near part of
        // the tube draws on top of the far part where the spiral crosses itself in screen space.
        segments.sort { $0.depth > $1.depth }
        return segments
    }

    // MARK: - Reference lane

    private static func ringMark(axial: Double, angleA: Double, angleB: Double, radius: Double,
                                  rotation: Rotation, kind: LaneMark.Kind) -> LaneMark {
        let a = rotation.project(axial: axial, angle: angleA, radius: radius)
        let b = rotation.project(axial: axial, angle: angleB, radius: radius)
        let depth = (a.depth + b.depth) / 2
        let axisDepth = rotation.axisDepth(axial: axial)
        return LaneMark(a: a, b: b, depth: depth, kind: kind, isBehindAxis: depth > axisDepth)
    }

    private static func ring(axial: Double, radius: Double, rotation: Rotation, kind: LaneMark.Kind) -> [LaneMark] {
        guard radius > 0 else { return [] }
        let n = ringPointsPerTurn
        var marks: [LaneMark] = []
        marks.reserveCapacity(n)
        for k in 0..<n {
            let angleA = 2 * Double.pi * Double(k) / Double(n)
            let angleB = 2 * Double.pi * Double(k + 1) / Double(n)
            marks.append(ringMark(axial: axial, angleA: angleA, angleB: angleB, radius: radius, rotation: rotation, kind: kind))
        }
        return marks
    }

    /// The two long lines that trace the drawn cylinder's outline — the angles where the ring's
    /// depth, as a function of angle, is at an extremum (the two points of a circle nearest and
    /// farthest from the camera under this orthographic-style projection are exactly its
    /// silhouette/tangent generators). Closed form, derived once per call, not swept numerically:
    /// `depth(angle) = axisDepth(axial) + radius·(cos(angle)·sin(elevation) + sin(angle)·cos(azimuth)·cos(elevation))`,
    /// whose angle-dependent part is `radius·(C·cos(angle) + D·sin(angle))` with
    /// `C = sin(elevation)`, `D = cos(azimuth)·cos(elevation)` — extremized at `angle = atan2(D, C)`
    /// and its opposite.
    ///
    /// That angle-dependent part is also independent of `axial`, so a silhouette line's offset
    /// from the lane's own centre axis has the same sign at every point along its length — one
    /// straight `LaneMark` per line is exact, no subdivision needed to track a behind/front
    /// crossing partway along it.
    private static func silhouetteLines(length: Double, radius: Double, rotation: Rotation, camera: Camera) -> [LaneMark] {
        guard radius > 0, length > 0 else { return [] }
        let c = sin(camera.elevation)
        let d = cos(camera.azimuth) * cos(camera.elevation)
        guard c != 0 || d != 0 else { return [] }   // depth has no angle dependence at all here — no outline to draw
        let angle1 = atan2(d, c)
        let angle2 = angle1 + .pi
        return [angle1, angle2].map { angle in
            let a = rotation.project(axial: 0, angle: angle, radius: radius)
            let b = rotation.project(axial: length, angle: angle, radius: radius)
            let depth = (a.depth + b.depth) / 2
            // axisDepth(axial: 0) is 0 for any camera, so `a.depth` alone already is this line's
            // constant offset from the axis (see doc comment above).
            return LaneMark(a: a, b: b, depth: depth, kind: .silhouette, isBehindAxis: a.depth > 0)
        }
    }

    // MARK: - Rotation (hoists the camera's own trig out of every per-point call)

    /// `cos`/`sin` of the camera's azimuth and elevation, computed once and reused for every point
    /// projected under that camera — the only per-point trigonometry left is `cos(angle)`/
    /// `sin(angle)` on the point's own stroke angle, which is genuinely per-point data and cannot
    /// be hoisted.
    private struct Rotation {
        let cosAz: Double
        let sinAz: Double
        let cosEl: Double
        let sinEl: Double

        init(camera: Camera) {
            cosAz = cos(camera.azimuth)
            sinAz = sin(camera.azimuth)
            cosEl = cos(camera.elevation)
            sinEl = sin(camera.elevation)
        }

        /// Rotates one world-space point `(axial, radius·cos(angle), radius·sin(angle))` — yaw
        /// about world Y by azimuth, then pitch about the yawed X axis by elevation.
        func project(axial: Double, angle: Double, radius: Double) -> ProjectedPoint {
            let y = radius * cos(angle)
            let z = radius * sin(angle)
            let x1 = axial * cosAz - z * sinAz
            let z1 = axial * sinAz + z * cosAz
            let y1 = y
            let y2 = y1 * cosEl - z1 * sinEl
            let z2 = y1 * sinEl + z1 * cosEl
            return ProjectedPoint(x: x1, y: y2, depth: z2)
        }

        /// The lane's own centre-axis (radius 0) depth at a given axial position — see `Drawing`'s
        /// doc comment for why every lane-guide point is compared against this rather than the
        /// tube's own nearby path.
        func axisDepth(axial: Double) -> Double {
            axial * sinAz * cosEl
        }
    }
}
