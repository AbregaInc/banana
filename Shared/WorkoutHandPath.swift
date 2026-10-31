import Foundation

/// Pure, no-SwiftUI construction of a "hand path" — one pool-swim lap's stroke rotation rendered
/// as a stroke-locked helix instead of an untrustworthy dead-reckoned trajectory. Runs off the
/// main actor exactly like `WorkoutMotionAnalysis`; the renderer (`HandPathScene`/`HandPathView`,
/// a separate package) consumes `Analysis`/`Lap`/`Point` and never recomputes anything from raw
/// samples.
///
/// This file exists because a read-only prototype (`scratchpad/handpath/`, numbers in
/// `scratchpad/handpath/run_output.txt`) validated against the owner's real swim data that the
/// obvious approach — integrate the wrist's rotation angle and dead-reckon a path — does NOT
/// work on this sensor:
///
/// - Raw unwrapped rotation totals only 0.88 turns/stroke on median (IQR 0.57–0.99), and the
///   **sign** of the rotation flips depending on band-pass parameters (47% sign agreement between
///   two reasonable filter choices on the same lap). Never integrate it, never derive winding
///   direction from it.
/// - Peak-picking the stroke rate alone over- or under-counts against the lap's own recorded
///   stroke count (one real lap gave 24 candidate peaks against 11 known strokes). The known
///   count is authoritative; peaks are reconciled against it, never trusted alone.
/// - Radius is not recoverable from a wrist accelerometer (estimated radius has the wrong sign
///   77% of the time). A constant default is used and reported as an assumption, never a measurement.
///
/// So the model built here allocates **exactly one 2π turn per known stroke**, with the angle
/// advancing linearly with elapsed time inside each stroke (no integration, no sign ambiguity),
/// while axial position advances linearly with real elapsed time across the whole lap — so a
/// stroke that took longer in real time naturally covers more axial distance. That is the
/// coaching signal this view exists to show: pitch of the helix is distance per stroke.
enum WorkoutHandPath {

    // MARK: - Shared type contract (also depended on by the renderer package)

    struct Point: Sendable, Equatable, Codable {
        var t: Float        // seconds since the start of this lap
        var angle: Float    // radians; 0 at lap start, +2*pi per stroke, always increasing
        var axial: Float    // metres from the wall this lap started at
        var effort: Float   // 0...1, normalised dynamic |accel| with gravity removed
    }

    struct Lap: Sendable, Identifiable, Codable {
        var id: Int                     // 0-based lap index within the workout
        var lengthMeters: Double
        var startT: TimeInterval        // seconds since workout start
        var duration: TimeInterval
        var strokeCount: Int
        var distancePerStroke: Double
        var points: [Point]             // ~24 per turn, ordered by t
        var strokeBoundaries: [Float]   // seconds since lap start; count == strokeCount + 1
        var syntheticBoundaryCount: Int
        var planarity: Float            // second/third singular value ratio; confidence signal
        var warnings: [String]
    }

    /// `Codable` so `WorkoutMotionDiskCache` (`WorkoutMotionCache.swift`) can persist it — see
    /// that cache's doc comment.
    struct Analysis: Sendable, Codable {
        var laps: [Lap]
        var radiusMeters: Double
        var warnings: [String]
    }

    // MARK: - Tunables

    /// Not recoverable from a wrist accelerometer (see the file doc comment) — a fixed assumed
    /// shoulder-to-wrist length. The renderer shows this number on screen so it reads as an
    /// assumption, not a measurement.
    static let defaultRadiusMeters: Double = 0.60

    private static let targetHz: Double = 25
    private static let pointsPerTurn = 24
    /// Search band for the per-lap autocorrelation fundamental, in Hz — matches the prototype's
    /// `estimate_stroke_freq_autocorr` default (`fmin=0.25, fmax=2.2`), wider than
    /// `WorkoutMotionAnalysis.ActivityHint.swim`'s 0.4...1.2 search band because this runs once
    /// per lap (a few dozen strokes) rather than in a 10 s sliding window, so it can afford to
    /// look further before committing to a rate.
    private static let fundamentalSearchBandHz: ClosedRange<Double> = 0.25...2.2
    /// `.distance` and `.strokeCount` are stamped at the same lap-turn instant, so a merge within
    /// this tolerance treats them as one turn instead of two nearby marks.
    private static let markMergeTolerance: TimeInterval = 0.25
    /// How close a `.strokeCount` sample's timestamp must be to a lap-turn mark to be trusted as
    /// that turn's cumulative count, rather than treated as missing for that lap.
    private static let strokeMatchTolerance: TimeInterval = 0.5
    /// A gap between consecutive raw accel samples wider than this, inside a single lap's window,
    /// is flagged rather than silently smoothed over by `resampleUniform`'s linear interpolation.
    /// `WorkoutMotionAnalysis.gapThreshold` (0.2 s) splits the whole-workout stream into separate
    /// chunks at this kind of hole; a single lap is too short a window to split into chunks the
    /// same way, but a hole this wide (a real BLE dropout or lost wrist contact) still means the
    /// interpolated stretch is fabricated, not measured, so it must not pass as silent as every
    /// other stretch of the lap.
    private static let gapWarningThreshold: TimeInterval = 0.75

    // MARK: - Lap marks (also used by `WorkoutMotionCache.lapBoundaries`)

    /// Lap-turn timestamps (seconds since workout start), read from the raw sample stream. The
    /// watch stamps one `.distance` sample and one `.strokeCount` sample — both cumulative-since-
    /// start — at every lap turn, so their timestamps are the real, measured turn times. This is
    /// deliberately NOT derived from summing `FitnessLap.duration`: that field is computed
    /// independently on-device and drifts roughly 50 s over a long swim (see
    /// `scratchpad/handpath/run_output.txt`), while these sample timestamps are the actual events.
    ///
    /// `.distance` and `.strokeCount` fire together at each turn, so their timestamps are merged
    /// (de-duplicated) within `markMergeTolerance` rather than double-counted as two turns.
    static func lapMarks(from samples: [FitnessSample], tolerance: TimeInterval = markMergeTolerance) -> [TimeInterval] {
        let marks = samples.compactMap { sample -> TimeInterval? in
            (sample.kind == .distance || sample.kind == .strokeCount) ? sample.t : nil
        }.sorted()
        guard var last = marks.first else { return [] }
        var merged = [last]
        for t in marks.dropFirst() where t - last > tolerance {
            merged.append(t)
            last = t
        }
        return merged
    }

    // MARK: - Entry point

    /// Builds the full hand-path model for a workout, or `nil` when the inputs don't support it:
    /// no pool length (not a pool swim, or an unmeasured one), no lap-turn marks at all, or not a
    /// single lap with a resolvable stroke count. This is the "gate on the inputs, not on how the
    /// output looks" rule from the prototype report — a swim missing this data would otherwise
    /// silently render a plausible-looking helix built from nothing real.
    static func analyze(samples: [FitnessSample], poolLengthMeters: Double?,
                         radiusMeters: Double = defaultRadiusMeters) -> Analysis? {
        guard let poolLengthMeters, poolLengthMeters > 0 else { return nil }
        let marks = lapMarks(from: samples)
        guard !marks.isEmpty else { return nil }
        let edges = [0.0] + marks
        guard edges.count > 1 else { return nil }

        let accel = samples.filter { $0.kind == .accel }.sorted { $0.t < $1.t }
        let strokeCounts = perLapStrokeCounts(samples: samples, edges: edges)

        var laps: [Lap] = []
        var warnings: [String] = []
        for i in 0..<(edges.count - 1) {
            let t0 = edges[i], t1 = edges[i + 1]
            guard let strokeCount = strokeCounts[i], strokeCount > 0 else {
                warnings.append("lap \(i + 1): no stroke count, skipped")
                continue
            }
            let windowAccel = accel.filter { $0.t >= t0 && $0.t < t1 }
            guard let lap = buildLap(index: i, t0: t0, t1: t1, lengthMeters: poolLengthMeters,
                                      strokeCount: strokeCount, accel: windowAccel) else {
                warnings.append("lap \(i + 1): too few accelerometer samples, skipped")
                continue
            }
            laps.append(lap)
        }
        guard !laps.isEmpty else { return nil }
        return Analysis(laps: laps, radiusMeters: radiusMeters, warnings: warnings)
    }

    // MARK: - Per-lap stroke counts (from the SAME turn marks lapMarks derives boundaries from)

    /// `strokeCounts[i]` is the number of strokes in the lap spanning `edges[i]..<edges[i+1]`, or
    /// `nil` when no `.strokeCount` sample lands near `edges[i+1]` (that lap's turn was recorded
    /// by `.distance` alone, or not recorded at all). The cumulative count at `edges[0]` (the
    /// workout start) is always taken as 0.
    private static func perLapStrokeCounts(samples: [FitnessSample], edges: [TimeInterval]) -> [Int?] {
        let strokeSamples = samples.filter { $0.kind == .strokeCount }.sorted { $0.t < $1.t }
        var cumulative: [Double?] = [0.0]
        for edge in edges.dropFirst() {
            let nearest = strokeSamples.min { abs($0.t - edge) < abs($1.t - edge) }
            if let nearest, abs(nearest.t - edge) <= strokeMatchTolerance {
                cumulative.append(nearest.v1)
            } else {
                cumulative.append(nil)
            }
        }
        var deltas: [Int?] = []
        for i in 0..<(cumulative.count - 1) {
            guard let a = cumulative[i], let b = cumulative[i + 1], b > a else { deltas.append(nil); continue }
            deltas.append(Int((b - a).rounded()))
        }
        return deltas
    }

    // MARK: - Per-lap builder

    private static func buildLap(index: Int, t0: TimeInterval, t1: TimeInterval, lengthMeters: Double,
                                  strokeCount: Int, accel: [FitnessSample]) -> Lap? {
        guard t1 > t0 else { return nil }
        let duration = t1 - t0
        let distancePerStroke = lengthMeters / Double(strokeCount)

        let (t, x, y, z, maxGap) = resampleUniform(accel, lapStart: t0, fs: targetHz)
        guard t.count > 4 else { return nil }

        let rawMagnitude = zip(zip(x, y), z).map { xy, zz in (xy.0 * xy.0 + xy.1 * xy.1 + zz * zz).squareRoot() }

        // Per-lap autocorrelation fundamental, falling back to the recorded rate (strokes / real
        // duration) when the signal isn't periodic enough for autocorrelation to find a peak —
        // e.g. a short or noisy lap. Never fabricated as zero.
        let f0: Float
        if let periodSamples = WorkoutMotionAnalysis.dominantPeriodSamples(rawMagnitude[...], hz: targetHz,
                                                                            band: fundamentalSearchBandHz),
           periodSamples > 0 {
            f0 = Float(targetHz) / periodSamples
        } else {
            f0 = Float(Double(strokeCount) / duration)
        }
        let lo = max(Double(f0) * 0.65, 0.1)
        let hi = min(max(Double(f0) * 1.5, lo + 0.05), 4.0)

        let bx = WorkoutMotionAnalysis.bandpassFilter(x, hz: targetHz, low: lo, high: hi)
        let by = WorkoutMotionAnalysis.bandpassFilter(y, hz: targetHz, low: lo, high: hi)
        let bz = WorkoutMotionAnalysis.bandpassFilter(z, hz: targetHz, low: lo, high: hi)
        let bandpassedMagnitude = zip(zip(bx, by), bz).map { xy, zz in (xy.0 * xy.0 + xy.1 * xy.1 + zz * zz).squareRoot() }

        let (candidateTimes, candidateProminences) = detectPeaks(t: t, magnitude: bandpassedMagnitude,
                                                                   fs: targetHz, f0: f0)
        let (interiorBoundaries, syntheticCount) = reconcileBoundaryCount(
            times: candidateTimes, prominences: candidateProminences,
            lapStart: 0, lapEnd: Float(duration), targetStrokes: strokeCount)

        let fullBoundaries = [Float(0)] + interiorBoundaries + [Float(duration)]
        let points = buildPoints(boundaries: fullBoundaries, duration: duration, lengthMeters: lengthMeters,
                                  effortTimes: t, effortMagnitude: bandpassedMagnitude)

        let planarity = planarityRatio(bx: bx, by: by, bz: bz)

        var warnings: [String] = []
        if maxGap > gapWarningThreshold {
            warnings.append("accelerometer gap of \(String(format: "%.1f", maxGap))s was interpolated over — part of this lap's shape is fabricated, not measured")
        }
        if syntheticCount > 0 {
            warnings.append("\(syntheticCount) of \(strokeCount) stroke boundar\(syntheticCount == 1 ? "y is" : "ies are") synthetic (interpolated, not detected)")
        }
        if planarity < 2.0 {
            warnings.append("rotation plane is unstable this lap — treat the shape with caution")
        }

        return Lap(id: index, lengthMeters: lengthMeters, startT: t0, duration: duration,
                   strokeCount: strokeCount, distancePerStroke: distancePerStroke, points: points,
                   strokeBoundaries: fullBoundaries, syntheticBoundaryCount: syntheticCount,
                   planarity: planarity, warnings: warnings)
    }

    // MARK: - Resample (lap-scoped; times returned relative to lapStart)

    /// Linear-interpolates one lap's accel samples onto a uniform `fs` grid, with `t` measured
    /// from `lapStart` (so `t[0] ≈ 0`). A lap-scoped sibling of
    /// `WorkoutMotionAnalysis.resampleRun` — that one is keyed to workout-wide chunk boundaries
    /// and gap-splitting, which don't apply to a single short lap window; instead this reports the
    /// widest gap it interpolated across so the caller can flag a lap that hid a real data hole
    /// behind a smooth-looking interpolated stretch.
    private static func resampleUniform(_ samples: [FitnessSample], lapStart: TimeInterval,
                                         fs: Double) -> (t: [Float], x: [Float], y: [Float], z: [Float], maxGap: TimeInterval) {
        guard let first = samples.first, let last = samples.last, last.t > first.t else { return ([], [], [], [], 0) }
        var maxGap: TimeInterval = 0
        for i in 1..<samples.count {
            maxGap = max(maxGap, samples[i].t - samples[i - 1].t)
        }
        let step = 1.0 / fs
        var t: [Float] = []; var x: [Float] = []; var y: [Float] = []; var z: [Float] = []
        var srcIndex = 0
        var cur = first.t
        while cur <= last.t {
            while srcIndex < samples.count - 2, samples[srcIndex + 1].t < cur { srcIndex += 1 }
            let a = samples[srcIndex]
            let b = samples[min(srcIndex + 1, samples.count - 1)]
            let span = b.t - a.t
            let frac = span > 0 ? (cur - a.t) / span : 0
            let ax = a.v1, ay = a.v2 ?? 0, az = a.v3 ?? 0
            let bx = b.v1, by = b.v2 ?? 0, bz = b.v3 ?? 0
            x.append(Float(ax + (bx - ax) * frac))
            y.append(Float(ay + (by - ay) * frac))
            z.append(Float(az + (bz - az) * frac))
            t.append(Float(cur - lapStart))
            cur += step
        }
        return (t, x, y, z, maxGap)
    }

    // MARK: - Stroke-boundary peak detection (prominence-ranked, so reconciliation has something
    // principled to drop or keep)

    /// Local maxima of `magnitude`, each carrying a topographic prominence (height above the
    /// higher of its two nearest bounding troughs — the same notion scipy's `find_peaks` uses),
    /// filtered to a minimum prominence and thinned to a minimum spacing derived from `f0` by
    /// greedy non-max suppression (accept the tallest remaining candidate, then discard any other
    /// candidate within `minDistance` samples of it — repeat). Returns times and prominences for
    /// the SURVIVING peaks only, both in `magnitude`'s index order.
    private static func detectPeaks(t: [Float], magnitude: [Float], fs: Double,
                                      f0: Float) -> (times: [Float], prominences: [Float]) {
        guard magnitude.count > 4 else { return ([], []) }

        var candidates: [Int] = []
        for i in 1..<(magnitude.count - 1) where magnitude[i] > magnitude[i - 1] && magnitude[i] >= magnitude[i + 1] {
            candidates.append(i)
        }
        guard !candidates.isEmpty else { return ([], []) }

        let sortedMagnitude = magnitude.sorted()
        func percentile(_ p: Double) -> Float {
            let idx = min(max(Int((p / 100) * Double(sortedMagnitude.count - 1)), 0), sortedMagnitude.count - 1)
            return sortedMagnitude[idx]
        }
        let minProminence = max(0.25 * (percentile(90) - percentile(10)), 1e-6)

        func prominence(at i: Int) -> Float {
            let height = magnitude[i]
            var leftMin = height
            var j = i - 1
            while j >= 0, magnitude[j] <= height { leftMin = min(leftMin, magnitude[j]); j -= 1 }
            var rightMin = height
            var k = i + 1
            while k < magnitude.count, magnitude[k] <= height { rightMin = min(rightMin, magnitude[k]); k += 1 }
            return height - max(leftMin, rightMin)
        }

        let scored = candidates.map { (index: $0, prominence: prominence(at: $0)) }
            .filter { $0.prominence >= minProminence }
        guard !scored.isEmpty else { return ([], []) }

        let expectedPeriodSamples = f0 > 0 ? fs / Double(f0) : fs / 0.5
        let minDistance = max(1, Int((expectedPeriodSamples * 0.55).rounded()))

        var kept: [(index: Int, prominence: Float)] = []
        for candidate in scored.sorted(by: { magnitude[$0.index] > magnitude[$1.index] }) {
            if kept.allSatisfy({ abs($0.index - candidate.index) >= minDistance }) {
                kept.append(candidate)
            }
        }
        kept.sort { $0.index < $1.index }
        return (kept.map { t[$0.index] }, kept.map { $0.prominence })
    }

    // MARK: - Reconciliation against the authoritative stroke count

    /// Forces the drawn boundary count to match `targetStrokes` exactly, using real detected
    /// timing wherever it exists:
    /// - Over-counting (`detected + 1 > target`): drop the least-prominent detected peaks first.
    /// - Under-counting: repeatedly bisect the single largest remaining gap (starting from the
    ///   full `[lapStart, times..., lapEnd]` span) to synthesise an evenly-placed boundary.
    ///
    /// Returns the INTERIOR boundaries only (excluding `lapStart`/`lapEnd`) and how many of them
    /// are synthetic — 0 means every boundary drawn came from an actual detected peak. The
    /// returned count is always exactly `targetStrokes - 1`, so a caller building
    /// `[lapStart] + boundaries + [lapEnd]` always gets exactly `targetStrokes + 1` marks — a
    /// single-stroke lap (`targetStrokes == 1`) always returns no interior boundaries, even if
    /// stray peaks were detected, rather than the prototype's literal edge behavior of leaving
    /// them in (which would silently violate that invariant).
    static func reconcileBoundaryCount(times: [Float], prominences: [Float], lapStart: Float, lapEnd: Float,
                                         targetStrokes: Int) -> (boundaries: [Float], syntheticCount: Int) {
        guard targetStrokes > 1 else { return ([], 0) }
        let current = times.count + 1
        if current == targetStrokes {
            return (times.sorted(), 0)
        }
        if current > targetStrokes {
            let drop = current - targetStrokes
            let weakestFirst = zip(times.indices, prominences).sorted { $0.1 < $1.1 }.map { $0.0 }
            let dropped = Set(weakestFirst.prefix(drop))
            let kept = times.enumerated().compactMap { i, time in dropped.contains(i) ? nil : time }
            return (kept.sorted(), 0)
        }
        let add = targetStrokes - current
        var bounds = [lapStart] + times.sorted() + [lapEnd]
        for _ in 0..<add {
            let gaps = zip(bounds, bounds.dropFirst()).map { $1 - $0 }
            let widest = gaps.indices.max { gaps[$0] < gaps[$1] }!
            bounds.insert(0.5 * (bounds[widest] + bounds[widest + 1]), at: widest + 1)
        }
        return (Array(bounds.dropFirst().dropLast()), add)
    }

    // MARK: - Points

    /// One `2*pi` turn per boundary-to-boundary segment, `pointsPerTurn` points each (angle
    /// advances linearly with elapsed time inside the segment — never integrated from the accel
    /// signal), plus one closing point at the lap end. Axial position advances linearly with real
    /// elapsed time across the WHOLE lap span, so a stroke that took longer in real time naturally
    /// stretches the pitch for exactly that turn.
    private static func buildPoints(boundaries: [Float], duration: TimeInterval, lengthMeters: Double,
                                      effortTimes: [Float], effortMagnitude: [Float]) -> [Point] {
        guard boundaries.count >= 2, duration > 0 else { return [] }
        let minEffort = effortMagnitude.min() ?? 0
        let maxEffort = effortMagnitude.max() ?? 0
        let effortRange = max(maxEffort - minEffort, 1e-6)

        func effort(at query: Float) -> Float {
            guard !effortMagnitude.isEmpty else { return 0 }
            let raw: Float
            if effortTimes.count == 1 || query <= effortTimes[0] {
                raw = effortMagnitude[0]
            } else if query >= effortTimes[effortTimes.count - 1] {
                raw = effortMagnitude[effortMagnitude.count - 1]
            } else {
                var lo = 0, hi = effortTimes.count - 1
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if effortTimes[mid] <= query { lo = mid } else { hi = mid }
                }
                let span = effortTimes[hi] - effortTimes[lo]
                let frac = span > 0 ? (query - effortTimes[lo]) / span : 0
                raw = effortMagnitude[lo] + (effortMagnitude[hi] - effortMagnitude[lo]) * frac
            }
            return min(max((raw - minEffort) / effortRange, 0), 1)
        }

        var points: [Point] = []
        let turnCount = boundaries.count - 1
        for turn in 0..<turnCount {
            let segStart = boundaries[turn], segEnd = boundaries[turn + 1]
            let segDuration = segEnd - segStart
            guard segDuration > 0 else { continue }
            for k in 0..<pointsPerTurn {
                let frac = Float(k) / Float(pointsPerTurn)
                let time = segStart + frac * segDuration
                let angle = Float(2 * Double.pi) * (Float(turn) + frac)
                let axial = Float(lengthMeters * Double(time) / duration)
                points.append(Point(t: time, angle: angle, axial: axial, effort: effort(at: time)))
            }
        }
        let closingAngle = Float(2 * Double.pi) * Float(turnCount)
        let closingTime = boundaries[boundaries.count - 1]
        points.append(Point(t: closingTime, angle: closingAngle, axial: Float(lengthMeters),
                            effort: effort(at: closingTime)))
        return points
    }

    // MARK: - Planarity (largest/smallest non-dominant singular value ratio)

    /// `S2/S3` of the band-passed 3×N signal, computed as the square roots of the 2nd and 3rd
    /// eigenvalues of its 3×3 covariance matrix — equivalent to (but far cheaper than) a full SVD
    /// for a 3-column matrix, using a closed-form symmetric-3×3 eigenvalue solution rather than an
    /// iterative solver. Low values (near 1) mean the rotation isn't confined to one plane, so the
    /// helix's phase is less trustworthy that lap.
    private static func planarityRatio(bx: [Float], by: [Float], bz: [Float]) -> Float {
        guard bx.count > 2 else { return 0 }
        let n = Double(bx.count)
        func mean(_ a: [Float]) -> Double { a.reduce(0.0) { $0 + Double($1) } / n }
        let mx = mean(bx), my = mean(by), mz = mean(bz)

        var cxx = 0.0, cyy = 0.0, czz = 0.0, cxy = 0.0, cxz = 0.0, cyz = 0.0
        for i in 0..<bx.count {
            let dx = Double(bx[i]) - mx, dy = Double(by[i]) - my, dz = Double(bz[i]) - mz
            cxx += dx * dx; cyy += dy * dy; czz += dz * dz
            cxy += dx * dy; cxz += dx * dz; cyz += dy * dz
        }

        let eigenvalues = symmetricEigenvalues3x3(a11: cxx, a22: cyy, a33: czz, a12: cxy, a13: cxz, a23: cyz)
        let descending = [eigenvalues.0, eigenvalues.1, eigenvalues.2].map { max($0, 0) }.sorted(by: >)
        let s2 = descending[1].squareRoot(), s3 = descending[2].squareRoot()
        guard s3 > 1e-9 else { return s2 > 1e-9 ? 50 : 0 }
        return Float(s2 / s3)
    }

    /// Closed-form eigenvalues of a real symmetric 3×3 matrix (the standard trigonometric
    /// solution — see e.g. Smith, "Eigenvalues of a symmetric 3×3 matrix", 1961), returned in no
    /// particular order. Exact for this size, so a full LAPACK/Accelerate eigensolver isn't needed.
    private static func symmetricEigenvalues3x3(a11: Double, a22: Double, a33: Double,
                                                  a12: Double, a13: Double, a23: Double) -> (Double, Double, Double) {
        let offDiagonalSq = a12 * a12 + a13 * a13 + a23 * a23
        guard offDiagonalSq > 0 else { return (a11, a22, a33) }
        let q = (a11 + a22 + a33) / 3
        let p2 = pow(a11 - q, 2) + pow(a22 - q, 2) + pow(a33 - q, 2) + 2 * offDiagonalSq
        let p = (p2 / 6).squareRoot()
        guard p > 0 else { return (q, q, q) }
        let b11 = (a11 - q) / p, b22 = (a22 - q) / p, b33 = (a33 - q) / p
        let b12 = a12 / p, b13 = a13 / p, b23 = a23 / p
        let detB = b11 * (b22 * b33 - b23 * b23) - b12 * (b12 * b33 - b23 * b13) + b13 * (b12 * b23 - b22 * b13)
        let r = min(max(detB / 2, -1), 1)
        let phi = acos(r) / 3
        let eig1 = q + 2 * p * cos(phi)
        let eig3 = q + 2 * p * cos(phi + 2 * Double.pi / 3)
        let eig2 = 3 * q - eig1 - eig3
        return (eig1, eig2, eig3)
    }
}

// MARK: - `Lap` custom `Codable`
//
// Same reasoning and technique as `WorkoutMotionAnalysis.Cycle`'s custom `Codable` (see its doc
// comment in `WorkoutMotionAnalysis.swift`): `points` is the one field here large enough to matter
// (~24 samples/turn × strokes/lap; ~337 on average for a real swim, ~97,000 combined across all 72
// laps) — each `Point` is flattened to 4 floats (`t`, `angle`, `axial`, `effort`) and packed as one
// `Data` blob via `[Float].packedData` rather than coded as 337 individually-keyed structs.
// `strokeBoundaries` stays a plain `[Float]` — a few dozen entries per lap, cheap either way.

extension WorkoutHandPath.Lap {
    private enum CodingKeys: String, CodingKey {
        case id, lengthMeters, startT, duration, strokeCount, distancePerStroke, points,
             strokeBoundaries, syntheticBoundaryCount, planarity, warnings
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(lengthMeters, forKey: .lengthMeters)
        try c.encode(startT, forKey: .startT)
        try c.encode(duration, forKey: .duration)
        try c.encode(strokeCount, forKey: .strokeCount)
        try c.encode(distancePerStroke, forKey: .distancePerStroke)
        var flattened: [Float] = []
        flattened.reserveCapacity(points.count * 4)
        for point in points { flattened.append(contentsOf: [point.t, point.angle, point.axial, point.effort]) }
        try c.encode(flattened.packedData, forKey: .points)
        try c.encode(strokeBoundaries, forKey: .strokeBoundaries)
        try c.encode(syntheticBoundaryCount, forKey: .syntheticBoundaryCount)
        try c.encode(planarity, forKey: .planarity)
        try c.encode(warnings, forKey: .warnings)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        lengthMeters = try c.decode(Double.self, forKey: .lengthMeters)
        startT = try c.decode(TimeInterval.self, forKey: .startT)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        strokeCount = try c.decode(Int.self, forKey: .strokeCount)
        distancePerStroke = try c.decode(Double.self, forKey: .distancePerStroke)
        let flattened = [Float](packedData: try c.decode(Data.self, forKey: .points)) ?? []
        var rebuilt: [WorkoutHandPath.Point] = []
        rebuilt.reserveCapacity(flattened.count / 4)
        var i = 0
        while i + 3 < flattened.count {
            rebuilt.append(WorkoutHandPath.Point(t: flattened[i], angle: flattened[i + 1],
                                                   axial: flattened[i + 2], effort: flattened[i + 3]))
            i += 4
        }
        points = rebuilt
        strokeBoundaries = try c.decode([Float].self, forKey: .strokeBoundaries)
        syntheticBoundaryCount = try c.decode(Int.self, forKey: .syntheticBoundaryCount)
        planarity = try c.decode(Float.self, forKey: .planarity)
        warnings = try c.decode([String].self, forKey: .warnings)
    }
}
