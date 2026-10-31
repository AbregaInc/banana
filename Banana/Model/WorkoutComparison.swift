import SwiftUI

/// One line of the "compared with your last 90 days" card: a metric's value for this workout,
/// its recent baseline, and the percent delta between them. Exact port of
/// `PostWorkoutReviewView`'s former private `Comparison` struct, promoted here so the Mac detail
/// view's comparison card (spec §4.6) computes byte-identical numbers to the phone's post-workout
/// review instead of re-deriving the same logic a second time.
struct WorkoutComparison: Identifiable {
    let title: String
    let now: String
    let usual: String
    let deltaPercent: Int
    /// Whether a positive delta reads as good news, bad news, or neither for this metric —
    /// `WorkoutPalette.good`/`.bad`/`.neutral`.
    let tone: Color
    var id: String { title }
}

/// Pure, cross-platform computation lifted out of `PostWorkoutReviewView.comparisons`
/// (spec §2.4) so it can be reused by the Mac detail view and unit-tested without any app state.
enum WorkoutComparisons {
    /// Exact port of `PostWorkoutReviewView.comparisons`: Duration, Distance, Pace-or-Speed
    /// (pooled over distance, not averaged per-workout, so a short fast outlier doesn't skew the
    /// baseline), and Avg heart rate — same tone rules as before (pace/speed colored by
    /// faster-is-good, everything else neutral). `distanceUnit` and `usesPace` take the place of
    /// the view's own `settings.distanceUnit`/`usesPace` so this stays a pure function of its
    /// inputs.
    static func compute(subject: WorkoutReviewSubject, peers: [WorkoutReviewSubject],
                         distanceUnit: DistanceUnit, usesPace: Bool) -> [WorkoutComparison] {
        guard !peers.isEmpty else { return [] }
        var out: [WorkoutComparison] = []
        func percent(_ now: Double, _ usual: Double) -> Int {
            usual > 0 ? Int(((now - usual) / usual * 100).rounded()) : 0
        }

        let durations = peers.map(\.duration).filter { $0 > 0 }
        if !durations.isEmpty, subject.duration > 0 {
            let usual = durations.reduce(0, +) / Double(durations.count)
            out.append(WorkoutComparison(title: "Duration", now: durationText(subject.duration), usual: durationText(usual),
                                          deltaPercent: percent(subject.duration, usual), tone: WorkoutPalette.neutral))
        }

        let distances = peers.compactMap(\.distanceMeters)
        if !distances.isEmpty, let d = subject.distanceMeters {
            let usual = distances.reduce(0, +) / Double(distances.count)
            out.append(WorkoutComparison(title: "Distance", now: distanceUnit.format(meters: d),
                                          usual: distanceUnit.format(meters: usual),
                                          deltaPercent: percent(d, usual), tone: WorkoutPalette.neutral))
        }

        // Pace over the pooled distance, so a short fast workout does not skew the baseline.
        let paced = peers.filter { ($0.distanceMeters ?? 0) > 0 && $0.duration > 0 }
        if !paced.isEmpty, let d = subject.distanceMeters, subject.duration > 0 {
            let totalMeters = paced.compactMap(\.distanceMeters).reduce(0, +)
            let totalSeconds = paced.map(\.duration).reduce(0, +)
            let usualSecondsPerMeter = totalSeconds / totalMeters
            let nowSecondsPerMeter = subject.duration / d
            let delta = percent(nowSecondsPerMeter, usualSecondsPerMeter)
            let tone: Color = delta < 0 ? WorkoutPalette.good : (delta > 0 ? WorkoutPalette.bad : WorkoutPalette.neutral)
            if usesPace {
                out.append(WorkoutComparison(title: "Pace", now: paceText(distance: d, seconds: subject.duration, unit: distanceUnit),
                                              usual: paceText(distance: totalMeters, seconds: totalSeconds, unit: distanceUnit),
                                              deltaPercent: delta, tone: tone))
            } else {
                out.append(WorkoutComparison(title: "Speed", now: speedText(distance: d, seconds: subject.duration, unit: distanceUnit),
                                              usual: speedText(distance: totalMeters, seconds: totalSeconds, unit: distanceUnit),
                                              deltaPercent: -delta, tone: tone))
            }
        }

        let rates = peers.compactMap(\.avgHeartRate)
        if !rates.isEmpty, let hr = subject.avgHeartRate {
            let usual = rates.reduce(0, +) / Double(rates.count)
            out.append(WorkoutComparison(title: "Avg heart rate", now: "\(Int(hr)) bpm", usual: "\(Int(usual)) bpm",
                                          deltaPercent: percent(hr, usual), tone: WorkoutPalette.neutral))
        }

        return out
    }

    // MARK: - Formatting (exact port of `PostWorkoutReviewView`'s former private formatters)

    static func durationText(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", sec))" }
        return "\(m):\(String(format: "%02d", sec))"
    }

    static func paceText(distance: Double, seconds: TimeInterval, unit: DistanceUnit) -> String {
        let divisor = unit == .miles ? 1609.344 : 1000
        let units = distance / divisor
        guard units > 0.01 else { return "—" }
        let pace = seconds / units
        let suffix = unit == .miles ? "/mi" : "/km"
        return "\(Int(pace) / 60):\(String(format: "%02d", Int(pace) % 60)) \(suffix)"
    }

    static func speedText(distance: Double, seconds: TimeInterval, unit: DistanceUnit) -> String {
        guard seconds > 0 else { return "—" }
        let mps = distance / seconds
        let value = mps * (unit == .miles ? 2.236936 : 3.6)
        return String(format: "%.1f %@", value, unit == .miles ? "mph" : "km/h")
    }
}

// MARK: - Splits / SWOLF

/// One lap's stroke-based efficiency score for the SWOLF table (spec §2.5, §4.5) — strokes plus
/// seconds for that lap, the standard swim-coaching formula. Either input can be nil (a lap
/// without an inferable stroke count still needs a row so the table's lap numbering stays
/// contiguous); `swolf` itself is nil unless `strokes` is available.
struct SWOLFRow: Identifiable {
    let lapNumber: Int
    let duration: TimeInterval
    let strokes: Int?          // nil if strokeCount deltas aren't available for this lap
    var swolf: Int? { strokes.map { $0 + Int(duration.rounded()) } }
    var id: Int { lapNumber }
}

enum WorkoutSplits {
    // MARK: - Distance splits

    /// Meters in one split, in the reader's unit.
    static func interval(for unit: DistanceUnit) -> Double { unit == .miles ? 1_609.344 : 1_000 }

    /// A workout's splits in the reader's unit, worked out from its distance track — the one
    /// source for the post-workout summary and the full analysis, so they can't disagree.
    ///
    /// The summary's stored `distanceSplits` are always whole kilometres, and each one's
    /// `distanceMeters` is the running total where that split ended (1,000, 2,000, …), not the
    /// split's length. The post-workout summary labelled rows with split number × that total —
    /// 9 × 9,000 m read as "50.33 mi" after a 5.9-mile run. They're used here only for a
    /// kilometre reader of a workout with no distance track.
    static func distanceSplits(for summary: FitnessSessionSummary, unit: DistanceUnit) -> [DistanceSplit] {
        if summary.distanceSeries.count > 1 {
            return summary.distanceSplits(interval: interval(for: unit))
        }
        return unit == .kilometers ? summary.distanceSplits : []
    }

    /// "Mile 3" / "Kilometer 3".
    static func label(_ split: DistanceSplit, unit: DistanceUnit) -> String {
        "\(unit == .miles ? "Mile" : "Kilometer") \(split.number)"
    }

    /// What's left after the last whole split — the 0.93 mi at the end of a 5.93-mile run — as its
    /// distance and time, or nil when there's no track or under 50 m remain.
    static func finalPartial(for summary: FitnessSessionSummary, unit: DistanceUnit)
        -> (meters: Double, duration: TimeInterval)? {
        guard summary.distanceSeries.count > 1, let last = summary.distanceSeries.last else { return nil }
        let whole = distanceSplits(for: summary, unit: unit)
        let meters = last.meters - Double(whole.count) * interval(for: unit)
        let duration = last.t - whole.reduce(0) { $0 + $1.duration }
        guard meters >= 50, duration > 0 else { return nil }
        return (meters, duration)
    }

    /// The watch's on-device `FitnessLap.duration` field and its raw `.strokeCount` sample
    /// timestamps are computed independently and drift apart — a lap's stroke-count mark lands
    /// slightly AFTER the boundary built by summing durations, every single lap, in real data (a
    /// lap ending at a summed boundary of 71.1 s had its mark stamped at 71.4 s; see
    /// `WorkoutHandPath.lapMarks`'s doc comment for the same drift on the authoritative-boundary
    /// side). The fallback window search below tolerates a mark landing up to this much after its
    /// boundary — generous relative to the drift actually observed (a few tenths of a second per
    /// lap) while still much narrower than a typical lap duration, so it can't bridge into the
    /// following lap's window.
    private static let boundaryDriftTolerance: TimeInterval = 2.0

    /// Per-lap stroke counts from the DIFFERENCE of consecutive cumulative `.strokeCount` samples
    /// (never the raw cumulative value — the cumulative counter charted raw is what §4.4 fixes
    /// for the "Stroke rate" chart; this is the same underlying correctness issue applied to
    /// splits).
    ///
    /// Two paths:
    /// - **Exact** (preferred): the watch stamps exactly one cumulative `.strokeCount` sample at
    ///   every lap turn, so when `strokeSeries` has exactly one sample per lap they pair up by
    ///   index — lap i's strokes are `sample[i] - sample[i-1]`, baseline 0 before the first. This
    ///   needs no time comparison at all, so it is exact and immune to the boundary drift above
    ///   (this is the path the owner's real 70-lap swim takes: 70 samples, 70 laps).
    /// - **Fallback**: when the sample count doesn't match the lap count (a missed turn, extra
    ///   samples, etc.) index-pairing isn't possible, so lap boundaries are built the only other
    ///   way this function can — by summing `FitnessLap.duration` — and each boundary's mark is
    ///   found by walking forward through the time-sorted samples, tolerant of it landing up to
    ///   `boundaryDriftTolerance` after the boundary rather than requiring at-or-before (the bug
    ///   this whole function used to have). A lap that never gets a mark of its own reports `nil`
    ///   rather than reusing a stale cumulative value — and so does the lap right after it, since a
    ///   mark that arrives after a skipped lap covers strokes from BOTH laps and isn't safe to
    ///   attribute to either one alone; the lap after that recovers once a mark lands cleanly on a
    ///   boundary again.
    ///
    /// `WorkoutHandPath.lapMarks(from:)` builds truly authoritative boundaries straight from the
    /// raw `.distance`/`.strokeCount` sample timestamps, which is exact even in the fallback case
    /// above — but it needs the raw `[FitnessSample]` stream, and this function's only callers
    /// (`PostWorkoutReviewView`, `WorkoutSplitsSection`) have just the already-summarized
    /// `strokeSeries`/`laps`: `FitnessSessionSummary`'s doc comment notes its heavy `samples` array
    /// lives in a separate file the summary never carries. So that reuse isn't available here.
    static func swolfRows(laps: [FitnessLap], strokeSeries: [WorkoutMetricPoint]) -> [SWOLFRow] {
        guard !laps.isEmpty else { return [] }
        let sorted = strokeSeries.sorted { $0.t < $1.t }

        if sorted.count == laps.count {
            var rows: [SWOLFRow] = []
            var previous: Double = 0   // before the first stroke, the cumulative count is 0
            for (index, lap) in laps.enumerated() {
                let value = sorted[index].value
                let strokes: Int? = value >= previous ? Int((value - previous).rounded()) : nil
                rows.append(SWOLFRow(lapNumber: lap.number, duration: lap.duration, strokes: strokes))
                previous = value
            }
            return rows
        }

        var rows: [SWOLFRow] = []
        var sampleIndex = 0
        var boundary: TimeInterval = 0
        var priorMark: Double? = 0   // before the first stroke, the cumulative count is 0
        for lap in laps {
            let end = boundary + lap.duration
            boundary = end

            var mark: Double?
            while sampleIndex < sorted.count, sorted[sampleIndex].t <= end + boundaryDriftTolerance {
                mark = sorted[sampleIndex].value
                sampleIndex += 1
            }

            var strokes: Int?
            if let mark, let base = priorMark, mark >= base {
                strokes = Int((mark - base).rounded())
            }
            priorMark = mark
            rows.append(SWOLFRow(lapNumber: lap.number, duration: lap.duration, strokes: strokes))
        }
        return rows
    }

    /// Index of the fastest lap/split by duration, for the bold+green highlight
    /// (`PostWorkoutReviewView`'s splits card treatment, currently absent on Mac).
    static func fastestIndex<D>(_ items: [D], duration: (D) -> TimeInterval) -> Int? {
        guard !items.isEmpty else { return nil }
        var bestIndex = 0
        var bestDuration = duration(items[0])
        for index in items.indices.dropFirst() {
            let d = duration(items[index])
            if d < bestDuration { bestDuration = d; bestIndex = index }
        }
        return bestIndex
    }
}
