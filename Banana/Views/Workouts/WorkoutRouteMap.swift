import SwiftUI
import MapKit

/// One full-rate GPS sample: a position and the time it was recorded at, decoupled from any
/// particular series (speed/heart rate are matched to it by nearest time, not carried inline,
/// since they're independently downsampled streams with their own cadence).
///
/// A plain nested struct rather than the tuple shape sketched in the spec prose, so it has a
/// real, dot-able type to pass around.
///
/// Not OS-gated: both `WideWorkoutDetailView` and `WorkoutDetailScreen` (iOS) build and consume
/// this same payload.
struct FullRateRoutePayload: Sendable {
    struct Point: Sendable {
        var t: TimeInterval
        var coordinate: (lat: Double, lon: Double)
    }

    var points: [Point]
    var speedByT: [WorkoutMetricPoint]
    var heartRateByT: [HRPoint]
}

/// Pure, `Sendable`-safe conversion from raw decoded samples to the map's payload shape — a free
/// static builder (not a composing view's member) so it carries no accidental main-actor affinity
/// when called from inside a `Task.detached`. Shared by `WideWorkoutDetailView` and
/// `WorkoutDetailScreen` (moved out of `WideWorkoutDetailView.swift`, where it started as a
/// Mac-only free function, once the iOS detail screen needed the identical conversion).
///
/// `.altitude` is included in the fetched kinds (spec §7) but not carried into the payload:
/// `WorkoutRouteMap`'s `.mapStyle(.hybrid(elevation: .realistic))` already supplies real terrain
/// height for the Replay map, so the recorded (noisy, wrist-worn) altitude stream isn't needed
/// here — it's fetched anyway only because `FitnessSample.decodeBinary(_:kinds:)` decodes by kind
/// set in one pass and a future consumer of this same payload may want it.
extension FullRateRoutePayload {
    static func build(from samples: [FitnessSample]) -> FullRateRoutePayload {
        var points: [FullRateRoutePayload.Point] = []
        var speedByT: [WorkoutMetricPoint] = []
        var heartRateByT: [HRPoint] = []
        points.reserveCapacity(samples.count)

        for sample in samples {
            switch sample.kind {
            case .location:
                guard let lon = sample.v2 else { continue }
                points.append(.init(t: sample.t, coordinate: (lat: sample.v1, lon: lon)))
            case .speed:
                speedByT.append(.init(t: sample.t, value: sample.v1))
            case .heartRate:
                heartRateByT.append(.init(t: sample.t, bpm: sample.v1))
            default:
                break
            }
        }

        points.sort { $0.t < $1.t }
        speedByT.sort { $0.t < $1.t }
        heartRateByT.sort { $0.t < $1.t }
        return FullRateRoutePayload(points: points, speedByT: speedByT, heartRateByT: heartRateByT)
    }
}

/// Which measurement buckets the full-rate route's color into (spec §4.2 state 1).
enum RouteColorMode {
    case speed
    case heartRate
}

/// The detail view's Replay map (report V1). Three real, distinct states — never a silent gap:
///
/// 1. **Full-rate** (`fullRate` non-nil, `>1` point): a multi-segment colored polyline over
///    realistic 3D terrain, with a scrub marker — plus pitch/zoom controls on the Mac, where a
///    mouse/trackpad has no pinch-to-zoom or two-finger pitch of its own; iOS gets those for free
///    from `Map` itself, so it skips that control strip (see `fullRateMap` below).
/// 2. **Coarse** (`fullRate` nil, but the synced ~40-point `workout.route` has `>1` point): the
///    existing single-polyline map, captioned as coarse.
/// 3. **Absent** (`workout.route.count <= 1`): a one-line note when GPS was expected but missing
///    (outdoor activity with no track — a real gap worth flagging), or literally nothing when GPS
///    was never applicable (strength, yoga, pool swim).
///
/// This view has no `FitnessStore` and no opinion on *why* `fullRate` is `nil` — the composing
/// view (`WideWorkoutDetailView` on the Mac, `WorkoutDetailScreen` on iOS) only ever populates
/// `fullRate` after confirming `fitness.hasLocalSamples(workout.id)`, so from here `fullRate ==
/// nil` covers both "will never have one" and the brief "still loading" window; state 2's coarse
/// map is exactly the right thing to show meanwhile; the view swaps to state 1 the moment the
/// payload arrives.
struct WorkoutRouteMap: View {
    let workout: FitnessSessionSummary
    /// `nil` until loaded, or `nil` forever if this workout has no raw `.samples` file — see the
    /// type doc above for how the three states read `nil`.
    let fullRate: FullRateRoutePayload?
    @Binding var cursorT: TimeInterval?
    var colorBy: RouteColorMode = .speed

    /// A stack still reserves its `spacing` around an embedded view even when that view draws
    /// nothing (`EmptyView()` isn't the same as "not present" from the parent's point of view) —
    /// so the composing view should call this before deciding whether to place `WorkoutRouteMap`
    /// in its `VStack` at all, rather than always placing it and letting state 3b's "nothing"
    /// leave a stray gap. Mirrors exactly the three-way gate `body` itself uses below.
    static func hasContent(for workout: FitnessSessionSummary, fullRate: FullRateRoutePayload?) -> Bool {
        if let fullRate, fullRate.points.count > 1 { return true }
        if workout.route.count > 1 { return true }
        return WorkoutActivityKind(activity: workout.activity).routeIsExpected
    }

    private var activityKind: WorkoutActivityKind { WorkoutActivityKind(activity: workout.activity) }

    /// Where a workout that never left one place (a gym, a studio) was: its GPS is jitter, so it
    /// gets a dot, not a line. Decided on the synced ~40-point route, which every device has and
    /// which is cheap to check on each scrub; the full-rate track only when there's no route.
    static func place(for workout: FitnessSessionSummary, fullRate: FullRateRoutePayload?) -> RoutePoint? {
        let track = workout.route.count > 1 ? workout.route
            : (fullRate?.points ?? []).map { RoutePoint(lat: $0.coordinate.lat, lon: $0.coordinate.lon) }
        return track.isOnePlace ? track.center : nil
    }

    @ViewBuilder
    var body: some View {
        if let place = Self.place(for: workout, fullRate: fullRate) {
            WorkoutPlaceMap(center: place, activity: workout.activity)
        } else if let fullRate, fullRate.points.count > 1 {
            fullRateSection(fullRate)
        } else if workout.route.count > 1 {
            coarseSection
        } else if activityKind.routeIsExpected {
            WorkoutSectionNote(text: "Indoor workout — no GPS recorded.")
        }
        // else: state 3b — genuinely nothing. No note, no placeholder frame.
    }

    // MARK: State 1 — full-rate replay

    private func fullRateSection(_ payload: FullRateRoutePayload) -> some View {
        fullRateMap(payload)
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: WorkoutMetrics.cardRadius, style: .continuous))
    }

    private func fullRateMap(_ payload: FullRateRoutePayload) -> some View {
        let segments = colorSegments(payload)
        return Map(initialPosition: .automatic) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(WorkoutPalette.routeGradient[segment.bucket],
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = payload.points.first {
                Marker("Start", systemImage: "flag.fill", coordinate: coordinate(start)).tint(DS.Palette.success)
            }
            if let finish = payload.points.last {
                Marker("Finish", systemImage: "flag.checkered", coordinate: coordinate(finish)).tint(DS.Palette.danger)
            }
            if let cursorT, let nearest = Self.nearestPoint(to: cursorT, in: payload.points) {
                Marker("Now", systemImage: "circle.fill", coordinate: coordinate(nearest)).tint(WorkoutPalette.accent)
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        // Pointer-only chrome: `MapPitchSlider`/`MapZoomStepper` are `@available(macOS, ...)` /
        // explicitly `unavailable` on iOS — confirmed by typechecking against the iOS 26 MapKit
        // `_MapKit_SwiftUI` module (not guessed) — a touch-first map already gets pinch-to-zoom
        // and two-finger pitch for free from `Map` itself, so iOS simply omits this
        // trackpad/mouse-oriented control strip.
        #if os(macOS)
        .mapControls {
            MapPitchSlider()
            MapZoomStepper()
        }
        #endif
    }

    /// Caps the number of drawn vertices — an hour-long run recorded near 1 Hz would otherwise
    /// hand SwiftUI several thousand tiny `MapPolyline` segments (a new one on every bucket
    /// change), which is the same per-frame rendering cost the app's performance rules ask charts
    /// to avoid by downsampling. Mirrors `FitnessView.derivedLocationPoints`'s existing
    /// `step = max(1, count / target)` convention rather than inventing a new scheme. Only the
    /// polyline geometry is downsampled — start/finish/scrub markers use the full-resolution
    /// `payload.points` so the scrubber stays precise.
    private static let maxPolylineVertices = 400

    /// One coordinate + its discretized color bucket, downsampled to `maxPolylineVertices`.
    private func bucketedCoordinates(_ payload: FullRateRoutePayload) -> [(coordinate: CLLocationCoordinate2D, bucket: Int)] {
        let step = max(1, payload.points.count / Self.maxPolylineVertices)
        let sampled = payload.points.enumerated().compactMap { i, point in i % step == 0 ? point : nil }
        guard !sampled.isEmpty else { return [] }

        let values: [Double] = sampled.map { point in
            switch colorBy {
            case .speed: return Self.nearestSpeed(at: point.t, in: payload.speedByT) ?? 0
            case .heartRate: return Self.nearestHeartRate(at: point.t, in: payload.heartRateByT) ?? 0
            }
        }
        let lo = values.min() ?? 0
        let hi = max(values.max() ?? 0, lo + 0.0001)   // avoid a zero-width range when the series is flat
        let range = lo...hi

        return zip(sampled, values).map { point, value in
            (coordinate(point), Self.colorBucket(value, range: range))
        }
    }

    /// Groups consecutive same-bucket coordinates into one `MapPolyline` each — the exact
    /// "contiguous run of one category, new polyline on change" pattern the app already uses for
    /// run/podcast segments (`FitnessView.routeSegments`), with the same continuity trick: each
    /// new segment starts by repeating the previous segment's last point so the polylines join
    /// with no visible gap at the bucket boundary.
    private func colorSegments(_ payload: FullRateRoutePayload) -> [(bucket: Int, coordinates: [CLLocationCoordinate2D])] {
        var segments: [(bucket: Int, coordinates: [CLLocationCoordinate2D])] = []
        for (coord, bucket) in bucketedCoordinates(payload) {
            if let last = segments.indices.last, segments[last].bucket == bucket {
                segments[last].coordinates.append(coord)
            } else {
                var coords: [CLLocationCoordinate2D] = []
                if let prev = segments.last?.coordinates.last { coords.append(prev) }
                coords.append(coord)
                segments.append((bucket, coords))
            }
        }
        return segments
    }

    private static func colorBucket(_ value: Double, range: ClosedRange<Double>) -> Int {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(4, max(0, Int((fraction * 5).rounded(.down))))
    }

    private func coordinate(_ point: FullRateRoutePayload.Point) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.coordinate.lat, longitude: point.coordinate.lon)
    }

    /// Nearest-in-time lookup, binary search — `points`/`series` are each built time-ordered by
    /// the composing view's `.task(id:)` off the raw sample stream, so this assumes ascending `t`.
    private static func nearestPoint(to t: TimeInterval, in points: [FullRateRoutePayload.Point]) -> FullRateRoutePayload.Point? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(points[lo - 1].t - t) < abs(points[lo].t - t) { return points[lo - 1] }
        return points[lo]
    }

    private static func nearestSpeed(at t: TimeInterval, in series: [WorkoutMetricPoint]) -> Double? {
        guard !series.isEmpty else { return nil }
        var lo = 0, hi = series.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if series[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(series[lo - 1].t - t) < abs(series[lo].t - t) { return series[lo - 1].value }
        return series[lo].value
    }

    private static func nearestHeartRate(at t: TimeInterval, in series: [HRPoint]) -> Double? {
        guard !series.isEmpty else { return nil }
        var lo = 0, hi = series.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if series[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(series[lo - 1].t - t) < abs(series[lo].t - t) { return series[lo - 1].bpm }
        return series[lo].bpm
    }

    // MARK: State 2 — coarse (synced summary route only)

    private var coarseSection: some View {
        coarseMap
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: WorkoutMetrics.cardRadius, style: .continuous))
    }

    private var coarseMap: some View {
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: coarseCoordinates)
                .stroke(WorkoutPalette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = coarseCoordinates.first {
                Marker("Start", systemImage: "flag.fill", coordinate: start).tint(DS.Palette.success)
            }
            if let finish = coarseCoordinates.last {
                Marker("Finish", systemImage: "flag.checkered", coordinate: finish).tint(DS.Palette.danger)
            }
        }
        // Standard, not hybrid — hybrid's satellite imagery at ~40-point density can look worse,
        // not better (spec §4.2 state 2).
        .mapStyle(.standard(elevation: .realistic))
    }

    private var coarseCoordinates: [CLLocationCoordinate2D] {
        workout.route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
}

/// A workout that stayed in one place, as a dot on the map where it was: GPS indoors wanders by
/// tens of metres, and a scribble of that says nothing.
struct WorkoutPlaceMap: View {
    let center: RoutePoint
    let activity: String
    var height: CGFloat = 180

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon)
        Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 1_200)), interactionModes: []) {
            Annotation("", coordinate: coordinate) {
                Circle()
                    .fill(WorkoutPalette.accent)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(radius: 2)
            }
        }
        .mapControlVisibility(.hidden)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: WorkoutMetrics.cardRadius, style: .continuous))
        .accessibilityLabel("Where this \(activity.lowercased()) was")
    }
}

// MARK: - Previews

private extension FitnessSessionSummary {
    /// Previews-only fixture. Routes it through `FitnessSessionSummary.init(session:)` exactly
    /// like a real recording would, so `route` comes out downsampled the same way production data
    /// is — this never touches `FitnessStore` or disk.
    static func previewSummary(activity: String, withRoute: Bool) -> FitnessSessionSummary {
        var samples: [FitnessSample] = []
        if withRoute {
            for i in 0..<40 {
                let t = Double(i) / 40 * 2 * .pi
                samples.append(FitnessSample(t: Double(i) * 5, kind: .location,
                                              v1: 37.8199 + 0.01 * cos(t), v2: -122.4783 + 0.01 * sin(t), v3: 3.0))
            }
        }
        let session = FitnessSession(id: UUID(), start: Date().addingTimeInterval(-1_800), end: Date(),
                                      activity: activity, avgHeartRate: nil, totalEnergy: nil,
                                      totalDistance: nil, samples: samples)
        return FitnessSessionSummary(session: session)
    }
}

private extension FullRateRoutePayload {
    static func previewFullRatePayload() -> FullRateRoutePayload {
        let points: [FullRateRoutePayload.Point] = (0..<160).map { i in
            let t = Double(i) / 160 * 2 * .pi
            return .init(t: Double(i) * 2, coordinate: (lat: 37.8199 + 0.01 * cos(t), lon: -122.4783 + 0.01 * sin(t)))
        }
        let speed = points.map { WorkoutMetricPoint(t: $0.t, value: 2.5 + 1.5 * sin($0.t / 20)) }
        let hr = points.map { HRPoint(t: $0.t, bpm: 130 + 25 * sin($0.t / 15)) }
        return FullRateRoutePayload(points: points, speedByT: speed, heartRateByT: hr)
    }
}

// State 2: the injected preview cycling fixture has an in-memory route but no `.samples` file, so
// `hasLocalSamples` is false on a real run — exercised here directly via `fullRate: nil`.
#Preview("Coarse route") {
    WorkoutRouteMap(workout: .previewSummary(activity: "Cycling", withRoute: true),
                     fullRate: nil, cursorT: .constant(nil))
        .frame(width: 520, height: 380)
}

// State 1: stubbed payload — a real end-to-end check needs one of the owner's raw-backed
// sessions and is deferred to Package 7 (`--mac-workout-id`).
#Preview("Full-rate replay (stubbed)") {
    WorkoutRouteMap(workout: .previewSummary(activity: "Running", withRoute: true),
                     fullRate: .previewFullRatePayload(), cursorT: .constant(160))
        .frame(width: 520, height: 380)
}

// State 3a: GPS expected (running) but the route is empty — "Indoor workout" note.
#Preview("Indoor — GPS expected but missing") {
    WorkoutRouteMap(workout: .previewSummary(activity: "Running", withRoute: false),
                     fullRate: nil, cursorT: .constant(nil))
        .frame(width: 520, height: 120)
        .background(previewWindowBackground)
}

// State 3b: GPS never applicable (strength) — nothing rendered at all.
#Preview("Strength — no route section at all") {
    WorkoutRouteMap(workout: .previewSummary(activity: "Strength Training", withRoute: false),
                     fullRate: nil, cursorT: .constant(nil))
        .frame(width: 520, height: 120)
        .background(previewWindowBackground)
}

/// The Mac's window chrome behind the two "no map drawn" previews above, so they read against a
/// realistic backdrop instead of the artifact-only default white; iOS has no equivalent concept; a
/// plain system background stands in.
private var previewWindowBackground: Color {
    #if os(macOS)
    Color(nsColor: .windowBackgroundColor)
    #else
    Color(.systemBackground)
    #endif
}
