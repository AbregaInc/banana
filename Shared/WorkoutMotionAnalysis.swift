import Foundation
import Accelerate

/// Pure-Swift analysis of one workout's raw accelerometer stream: cycle (stride/stroke) detection
/// and a frequency-content spectrogram. No SwiftUI/AppKit/UIKit — this operates on `[FitnessSample]`
/// already decoded by `FitnessSample.decodeBinary(_:kinds:)` and never touches a file itself, so it
/// can run identically inside a `Task.detached` off the main actor.
///
/// Pipeline (matches the design report's V3/V4 pipeline):
/// 1. Sort by `t`; resample x/y/z onto a uniform 25 Hz grid (linear interpolation) in contiguous
///    runs. A gap between adjacent raw samples greater than 200 ms ends a run rather than being
///    bridged by interpolation — the run boundary becomes a hole recorded in `warnings`, and no
///    detected cycle can straddle it because cycle detection operates one run at a time.
/// 2. Band-pass magnitude 0.3–4 Hz, zero-phase 2nd-order Butterworth (`vDSP_deq22`, forward then
///    reverse, so the filter introduces no phase lag).
/// 3. Sliding-window autocorrelation (10 s windows) confirms a window is periodic at all inside
///    the activity hint's search band — how strong "periodic at all" has to be is itself
///    hint-dependent (`ActivityHint.correlationFloor`; see `dominantPeriodSamples`) — then
///    peak-picks cycle boundaries with a minimum spacing of 0.7× the winning period. For
///    `.runOrWalk`, that raw winning period is a real, well-known trap: `searchBandHz` has to span
///    both the step rate and its exact half — the arm swing that repeats once per left-right pair
///    of footstrikes — and autocorrelation's normalized dot product is *structurally* biased
///    toward the longer, whole-gait-cycle period even when the shorter, per-step period carries
///    far more spectral energy (validated against the owner's real running data: FFT puts the true
///    step-rate peak ~7× stronger than the arm-swing secondary peak, while raw autocorrelation
///    still locks onto the arm-swing lag — see `refinedPeriodSamples`'s doc comment for why). So
///    once a window is confirmed periodic, `.runOrWalk` REFINES which period inside the band is
///    used for peak-spacing: prefer the measured step rate from `speed ÷ strideLength` samples
///    when the workout carries them (recorded since 17 Aug), else fall back to a small in-band
///    spectral scan (`spectralDominantHz`) — both pick by *power at a frequency*, not by
///    self-similarity at a lag, so neither shares autocorrelation's sub-harmonic bias. `.swim` and
///    `.other` are untouched here: once a window clears their gate, they still use the raw
///    autocorrelation winner exactly as before — only `.other`'s gate itself (step 3 above) is
///    now stricter, not its choice of period.
/// 4. A cycle whose period is more than 30% off the global median period is flagged (not dropped)
///    via `Cycle.offBaseline` so a caller can render it desaturated instead of either hiding a
///    real stroke or drawing a corrupted loop as if it were clean.
/// 5. Each accepted cycle's (x, y, z) is resampled to 100 phase samples.
/// 6. Cycles are grouped by lap using `lapBoundaries` (pool swims only); everything else gets
///    `lap = nil`.
/// 7. A short-time Fourier transform of magnitude (Hann window, 50% overlap, `vDSP_fft_zip`)
///    produces the spectrogram and its dominant-frequency trace, in Hz — never bpm/rpm, since
///    this is derived from raw motion, not the (cycling-only) recorded cadence kind. The window
///    length and the displayed frequency ceiling are both picked per `ActivityHint` — see
///    `ActivityHint.spectrogramWindowSamples`/`spectrogramMaxHz` — instead of one shared window
///    and axis for every activity, which used to leave a swim's slow, narrow-band stroke rate
///    both too coarsely binned to show drift and squashed into the bottom of a too-tall axis.
/// 8. Cycles are grouped into pages (lap, or 60 s window) the same way
///    `WorkoutMotionSection.MotionSignatureCard` pages them, and each page with at least two
///    usable cycles gets a `pageConsistency` ratio — see `Result.pageConsistency` and
///    `WorkoutMotionConsistency` for what it measures and why.
enum WorkoutMotionAnalysis {

    enum ActivityHint: Sendable {
        case swim, runOrWalk, other

        /// Autocorrelation search band, in Hz, for locating the dominant cycle period.
        var searchBandHz: ClosedRange<Double> {
            switch self {
            case .swim: 0.4...1.2          // per-arm stroke rate
            // Deliberately still spans both the step rate and the arm-swing sub-harmonic at half
            // of it — this range is also the envelope `refinedPeriodSamples` searches inside once
            // a window is confirmed periodic, so it needs to comfortably cover a slow walk (~72
            // spm) through a fast run (~198 spm), not just a run. See the file doc comment's step
            // 3 for how the two frequencies inside it are actually disambiguated.
            case .runOrWalk: 1.2...3.3
            // Full band. Covers cycling (pedal cadence, though a wrist-worn watch has no reliable
            // line of sight to it), rowing (stroke rate), strength, yoga, and anything unrecognized
            // — none of which has footstep periodicity (see `WorkoutActivityKind
            // .hasFootstepPeriodicity`), so none gets `.runOrWalk`'s narrower band or anchor
            // refinement. Whether any cycle actually surfaces for these is now almost entirely
            // `correlationFloor`'s job, below — see its doc comment.
            case .other: 0.3...4.0
            }
        }

        /// Minimum autocorrelation strength (0...1) a 10 s window must clear inside `searchBandHz`
        /// before `dominantPeriodSamples` calls it periodic at all. `.swim` and `.runOrWalk` use the
        /// shared `minCorrelation` default (0.25) — the same value `WorkoutHandPath` relies on for
        /// its own direct calls into `dominantPeriodSamples` (it never passes `correlationFloor`),
        /// so this had to be layered in as a per-hint override rather than by raising the shared
        /// default: doing that would have silently tightened swim stroke detection too, which the
        /// hand-path feature depends on.
        ///
        /// `.other` gets a much stricter floor instead. At the shared default, ordinary strength
        /// motion clears the gate on most 10 s windows — measured on the owner's real 77-minute
        /// strength recording (id 32D848BF…, ~115k accel samples), the full 0.3-4 Hz band at 0.25
        /// detects 2,096 fabricated "cycles" with no basis in the recording. Raising the floor to
        /// 0.9 erases every one of them (0 cycles) and does the same on a real 78-minute yoga
        /// session (also 0, though that one was already near-zero well below 0.9). A genuinely
        /// periodic `.other` signal still clears 0.9 easily — a clean synthetic tone still detects
        /// 448 of 450 expected cycles, and a realistically noisy-but-periodic one (roughly 2:1
        /// signal:noise) still partially detects — so this isn't "strength/yoga never get a cycle
        /// count" as a special case, it's "prove it first," applied to the whole general-case
        /// bucket. See `WorkoutMotionCache.result(for:fitness:)`'s doc comment for the full
        /// before/after and `WorkoutMotionAnalysisTests` for the synthetic coverage.
        var correlationFloor: Float {
            self == .other ? 0.9 : WorkoutMotionAnalysis.minCorrelation
        }

        /// STFT window length in samples at `targetHz` (25 Hz) for the spectrogram — chosen per
        /// activity, not one shared constant, because the frequency resolution a window buys
        /// (`binHz = targetHz / windowSamples`) has to be weighed against the time resolution it
        /// costs (`computeSpectrogram` hops by half a window, so a new column only appears every
        /// `windowSamples / 2` samples).
        ///
        /// This is half of the "frequency chart is always a flat line" bug (`spectrogramMaxHz`
        /// below is the other half): a swim's whole useful range (roughly 0.2–1.5 Hz) is narrow
        /// enough that the OLD shared 128-sample window (0.1945 Hz bins) gave only about six
        /// usable bins across it — nowhere near enough resolution to show a stroke rate drifting
        /// within a length, and the very reason a real swim's dominant-frequency trace looked
        /// like a flat line even once it was correctly detected. 512 samples (20 s @ 25 Hz,
        /// 0.049 Hz bins — the owner's own numbers) fixes that. The accepted trade-off: a coarser
        /// ~10 s time step (half the window), so a rate change faster than that gets smoothed
        /// together — acceptable for a stroke rate that drifts over tens of seconds, not one that
        /// needs to be resolved sub-second. `.runOrWalk`'s 1.2–3.3 Hz band is both wider in
        /// absolute Hz and more likely to shift stride to stride, so it keeps a shorter
        /// 256-sample window (10.24 s, 0.098 Hz bins) — still double the old resolution, at half
        /// the time-smoothing cost. `.other` is a broad catch-all with no single expected rate
        /// (cycling/rowing/strength/yoga/unrecognized), and its resolution problem was never as
        /// acute — 128 samples already gives ~19 usable bins across its wide 0.3–4.0 Hz band,
        /// versus swim's 6 — so it keeps the original window.
        var spectrogramWindowSamples: Int {
            switch self {
            case .swim: return 512
            case .runOrWalk: return 256
            case .other: return 128
            }
        }

        /// Displayed frequency-axis ceiling, in Hz — scaled to THIS activity's own plausible band
        /// (`searchBandHz`) instead of one fixed 6 Hz axis for every activity. That fixed axis was
        /// the other half of the flat-line bug: a swim's stroke rate (0.4–1.2 Hz; the owner's own
        /// real stroke rate is close to 0.5 Hz) sits in the bottom ~20% of a 6 Hz axis, reading as
        /// a line hugging the floor even once the bin-resolution fix above makes the trace itself
        /// meaningful. 40% headroom above the band's own top keeps the WHOLE plausible range (not
        /// just the owner's personal rate) comfortably inside the chart instead of pinned to one
        /// edge, while leaving room to show a genuinely fast outlier without wasting most of the
        /// axis on frequencies nothing plausible reaches. The axis still starts at 0 Hz, not at
        /// the band's own lower bound — for a rate near the low end of its band (like the owner's
        /// swim), starting the axis at 0 actually places it FARTHER from the bottom than cropping
        /// the axis up to the band's lower edge would (cropping shrinks the whole span, which
        /// moves content near that edge closer to 0%, not away from it).
        var spectrogramMaxHz: Float {
            Float(searchBandHz.upperBound) * 1.4
        }
    }

    /// Struct-of-arrays view over one signal, Float32 (not Float64 — halves the retained size for
    /// a long session), monotonic in `t`.
    struct Series: Sendable, Codable {
        var t: [Float]
        var x: [Float]
        var y: [Float]
        var z: [Float]
        var magnitude: [Float]   // sqrt(x²+y²+z²), precomputed once
    }

    /// One detected accelerometer cycle (a stride or a stroke), resampled to a fixed phase length
    /// so cycles of different real duration can be overlaid/compared.
    struct Cycle: Sendable, Identifiable, Codable {
        let id: Int
        var lap: Int?              // nil outside pool swims
        var startT: Float
        var periodSeconds: Float
        var phaseX: [Float]        // 100 samples, phase-resampled
        var phaseY: [Float]
        var phaseZ: [Float]
        /// > 30% off the local median period, or spans a data hole — flagged, not dropped, so
        /// callers can grey it out rather than silently lose a count.
        var offBaseline: Bool
    }

    struct SpectrogramFrame: Sendable, Codable { var t: Float; var dominantHz: Float; var bins: [Float] }
    struct Spectrogram: Sendable, Codable { var frames: [SpectrogramFrame]; var binHz: Float; var maxHz: Float }

    /// `Codable` so `WorkoutMotionDiskCache` (`WorkoutMotionCache.swift`) can persist it verbatim
    /// instead of re-running `analyze` on every launch — see that cache's doc comment for the
    /// measured cost this avoids. `accel` is deliberately excluded from what gets cached (see
    /// `WorkoutMotionCacheEntry`), not from `Result` itself: nothing downstream of `analyze` reads
    /// `Result.accel` today (the views only ever consult `cycles`/`spectrogram`/`cadenceHzTrace`/
    /// `warnings`), but it stays part of the live, in-memory `Result` in case a future caller needs
    /// the resampled series without the cache format having to change shape around it.
    struct Result: Sendable, Codable {
        var accel: Series?
        var cycles: [Cycle]
        var spectrogram: Spectrogram?
        var cadenceHzTrace: [WorkoutMetricPoint]   // dominant spectrogram frequency over time, Hz
        var warnings: [String]                     // e.g. "3 gaps > 200 ms skipped"
        /// Per-page ("lap" for a pool swim, 60 s window otherwise — the exact same key
        /// `WorkoutMotionSection.MotionSignatureCard.page` already pages by, see
        /// `pageIndex(for:)`) technique-consistency ratio: `WorkoutMotionConsistency
        /// .consistencyRatio` over that page's non-`offBaseline` cycles. See that type's doc
        /// comment for the full definition and why dividing by the aligned loop's own size makes
        /// it scale-invariant — the fix for a real mistake in how this chart used to be described
        /// (a "tight cloud" caption that conflated gentle movement with consistent technique; see
        /// `MotionSignatureCard`'s doc comment). Absent for a page with fewer than two usable
        /// cycles (nothing to compare) or a degenerate near-zero loop.
        ///
        /// Computed once here, off the main actor exactly like every other field on `Result`, and
        /// persisted by `WorkoutMotionDiskCache` alongside `cycles` — paging through a workout's
        /// signature (including the auto-play in `MotionSignatureCard`) never recomputes it.
        var pageConsistency: [Int: Float]
    }

    // MARK: - Tunables

    private static let targetHz: Double = 25
    private static let gapThreshold: TimeInterval = 0.2      // > this between raw samples = a hole
    private static let bandLow: Double = 0.3
    private static let bandHigh: Double = 4.0
    private static let windowSeconds: Double = 10             // autocorrelation window
    private static let minCorrelation: Float = 0.25           // shared floor; `.other` overrides — see `ActivityHint.correlationFloor`
    private static let minVariance: Float = 1e-6               // near-flat signal guard (a held pose, rest between sets)
    private static let outlierFraction: Float = 0.3            // > 30% off median period => offBaseline
    // Spectrogram window length and displayed frequency ceiling are per-activity now, not shared
    // constants — see `ActivityHint.spectrogramWindowSamples`/`spectrogramMaxHz`.
    /// Floor below which `computeSpectrogram` never reports a bin as "dominant" — see its own
    /// linear-detrend comment for why. Below every activity's own search-band floor (swim's, the
    /// lowest, is 0.4 Hz), so this only ever excludes leakage, never a genuine reading.
    private static let minDominantSearchHz: Float = 0.15

    // MARK: - Entry point

    /// - Parameters:
    ///   - accelSamples: `.accel` kind samples for one workout, any order (sorted internally).
    ///   - lapBoundaries: cumulative-seconds-since-start marks (from the workout's lap-turn
    ///     sample timestamps — see `WorkoutMotionCache.lapBoundaries`/`WorkoutHandPath.lapMarks`)
    ///     used only to group cycles into `Cycle.lap` for pool swims; empty for everything else.
    ///   - hint: selects the autocorrelation search band.
    ///   - cadenceAnchorHz: ground-truth step-rate points (seconds since workout start → Hz),
    ///     normally `stepRateAnchorHz(from:)` run on the same workout's raw samples. Only consulted
    ///     for `.runOrWalk`; ignored entirely for `.swim`/`.other`. Empty (the default) for a
    ///     workout with no `.speed`/`.strideLength` samples — pre-17-Aug recordings, or any
    ///     activity that never carries them — which is exactly when `.runOrWalk` falls back to
    ///     `spectralDominantHz` instead.
    static func analyze(accelSamples: [FitnessSample], lapBoundaries: [TimeInterval], hint: ActivityHint,
                         cadenceAnchorHz: [WorkoutMetricPoint] = []) -> Result {
        let sorted = accelSamples.filter { $0.kind == .accel }.sorted { $0.t < $1.t }
        guard sorted.count > 1 else {
            return Result(accel: nil, cycles: [], spectrogram: nil, cadenceHzTrace: [], warnings: [], pageConsistency: [:])
        }

        let (chunks, warnings) = resampleIntoChunks(sorted)
        guard !chunks.isEmpty else {
            return Result(accel: nil, cycles: [], spectrogram: nil, cadenceHzTrace: [], warnings: warnings, pageConsistency: [:])
        }

        var cycles: [Cycle] = []
        var nextID = 0
        let searchBand = hint.searchBandHz
        for chunk in chunks {
            let bandpassed = bandpassFilter(chunk.magnitude, hz: targetHz, low: bandLow, high: bandHigh)
            for detected in detectCycles(chunk: chunk, bandpassed: bandpassed, hz: targetHz, searchBand: searchBand,
                                          hint: hint, cadenceAnchorHz: cadenceAnchorHz) {
                cycles.append(Cycle(id: nextID, lap: nil, startT: detected.startT, periodSeconds: detected.periodSeconds,
                                     phaseX: detected.phaseX, phaseY: detected.phaseY, phaseZ: detected.phaseZ,
                                     offBaseline: detected.offBaseline))
                nextID += 1
            }
        }

        flagOutliers(&cycles)

        if !lapBoundaries.isEmpty {
            let bounds = lapBoundaries.map { Float($0) }.sorted()
            for i in cycles.indices {
                cycles[i].lap = lapNumber(for: cycles[i].startT, boundaries: bounds)
            }
        }

        let accel = concatenate(chunks)
        let spectrogram = computeSpectrogram(chunks: chunks, hz: targetHz, hint: hint)
        let cadenceTrace = (spectrogram?.frames ?? []).map {
            WorkoutMetricPoint(t: TimeInterval($0.t), value: Double($0.dominantHz))
        }
        let pageConsistency = computePageConsistency(cycles: cycles)

        return Result(accel: accel, cycles: cycles, spectrogram: spectrogram,
                      cadenceHzTrace: cadenceTrace, warnings: warnings, pageConsistency: pageConsistency)
    }

    // MARK: - Per-page technique-consistency (the "tight cloud" caption fix)

    /// The page a cycle belongs to in `WorkoutMotionSection.MotionSignatureCard` — lap number
    /// minus one for a lap-grouped (pool swim) cycle, or its 60 s window index otherwise. Kept in
    /// exact sync with that view's own `cyclesForPage` (`cycle.lap == p + 1` / `startT` inside
    /// `[p*60, p*60+60)`) so `pageConsistency` is keyed by precisely the pages the view pages
    /// through — `cycle.lap` is non-nil if and only if the workout is lap-grouped, matching that
    /// view's own `usesLapPaging` gate one-for-one (see `WorkoutMotionCache`'s doc comment).
    private static func pageIndex(for cycle: Cycle) -> Int {
        if let lap = cycle.lap { return lap - 1 }
        return Int(cycle.startT / 60)
    }

    /// `offBaseline` cycles are excluded — a flagged cycle is already known to be corrupted (a
    /// period wildly off the local median, or spanning a data hole), so folding it into a
    /// consistency comparison would blame "inconsistent technique" on damaged data instead.
    private static func computePageConsistency(cycles: [Cycle]) -> [Int: Float] {
        var byPage: [Int: [Cycle]] = [:]
        for cycle in cycles where !cycle.offBaseline {
            byPage[pageIndex(for: cycle), default: []].append(cycle)
        }
        var result: [Int: Float] = [:]
        for (page, pageCycles) in byPage {
            let loops = pageCycles.map { cycle -> WorkoutMotionConsistency.Loop in
                let count = min(cycle.phaseX.count, cycle.phaseY.count, cycle.phaseZ.count)
                let points = (0..<count).map {
                    WorkoutMotionConsistency.Point3(x: Double(cycle.phaseX[$0]), y: Double(cycle.phaseY[$0]), z: Double(cycle.phaseZ[$0]))
                }
                return WorkoutMotionConsistency.Loop(points: points)
            }
            if let ratio = WorkoutMotionConsistency.consistencyRatio(loops: loops) {
                result[page] = ratio
            }
        }
        return result
    }

    // MARK: - Step 1: resample into contiguous, hole-free runs

    private static func resampleIntoChunks(_ sorted: [FitnessSample]) -> (chunks: [Series], warnings: [String]) {
        var runs: [[FitnessSample]] = [[sorted[0]]]
        var gapCount = 0
        for i in 1..<sorted.count {
            if sorted[i].t - sorted[i - 1].t > gapThreshold {
                gapCount += 1
                runs.append([sorted[i]])
            } else {
                runs[runs.count - 1].append(sorted[i])
            }
        }

        let chunks = runs.compactMap { run -> Series? in
            guard run.count > 1 else { return nil }
            return resampleRun(run)
        }

        var warnings: [String] = []
        if gapCount > 0 {
            warnings.append("\(gapCount) gap\(gapCount == 1 ? "" : "s") > \(Int(gapThreshold * 1_000)) ms skipped")
        }
        return (chunks, warnings)
    }

    /// Linear-interpolates one contiguous run of raw samples onto a uniform `targetHz` grid.
    private static func resampleRun(_ run: [FitnessSample]) -> Series? {
        let tStart = run.first!.t
        let tEnd = run.last!.t
        guard tEnd > tStart else { return nil }
        let step = 1.0 / targetHz

        var gridT: [Float] = []
        var gridX: [Float] = []
        var gridY: [Float] = []
        var gridZ: [Float] = []
        var gridMag: [Float] = []
        let sampleCount = Int((tEnd - tStart) / step) + 1
        gridT.reserveCapacity(sampleCount); gridX.reserveCapacity(sampleCount)
        gridY.reserveCapacity(sampleCount); gridZ.reserveCapacity(sampleCount)
        gridMag.reserveCapacity(sampleCount)

        var srcIndex = 0
        var t = tStart
        while t <= tEnd {
            while srcIndex < run.count - 2, run[srcIndex + 1].t < t { srcIndex += 1 }
            let a = run[srcIndex]
            let b = run[min(srcIndex + 1, run.count - 1)]
            let span = b.t - a.t
            let frac = span > 0 ? (t - a.t) / span : 0
            let ax = a.v1, ay = a.v2 ?? 0, az = a.v3 ?? 0
            let bx = b.v1, by = b.v2 ?? 0, bz = b.v3 ?? 0
            let x = Float(ax + (bx - ax) * frac)
            let y = Float(ay + (by - ay) * frac)
            let z = Float(az + (bz - az) * frac)
            gridT.append(Float(t)); gridX.append(x); gridY.append(y); gridZ.append(z)
            gridMag.append((x * x + y * y + z * z).squareRoot())
            t += step
        }
        guard gridT.count > 4 else { return nil }
        return Series(t: gridT, x: gridX, y: gridY, z: gridZ, magnitude: gridMag)
    }

    private static func concatenate(_ chunks: [Series]) -> Series? {
        guard !chunks.isEmpty else { return nil }
        var t: [Float] = []; var x: [Float] = []; var y: [Float] = []; var z: [Float] = []; var m: [Float] = []
        for chunk in chunks {
            t += chunk.t; x += chunk.x; y += chunk.y; z += chunk.z; m += chunk.magnitude
        }
        return Series(t: t, x: x, y: y, z: z, magnitude: m)
    }

    // MARK: - Step 2: zero-phase band-pass (vDSP_deq22)

    /// A single 2nd-order Butterworth-style band-pass biquad (RBJ cookbook "constant 0 dB peak
    /// gain" form), run forward then reverse over the reversed output so the net response has
    /// zero phase (a basic filtfilt).
    /// Widened from `private` so `WorkoutHandPath` can reuse the exact same zero-phase filter for
    /// its per-lap stroke-boundary band-pass rather than re-implementing it — see that file's doc
    /// comment. Behavior is unchanged.
    static func bandpassFilter(_ input: [Float], hz: Double, low: Double, high: Double) -> [Float] {
        guard input.count > 4 else { return input }
        let coefficients = biquadBandpassCoefficients(low: low, high: high, hz: hz)
        let forward = applyBiquad(input, coefficients: coefficients)
        let backward = applyBiquad(Array(forward.reversed()), coefficients: coefficients)
        return Array(backward.reversed())
    }

    private static func biquadBandpassCoefficients(low: Double, high: Double, hz: Double) -> [Float] {
        let f0 = (low * high).squareRoot()
        let bandwidth = max(high - low, 0.01)
        let q = max(f0 / bandwidth, 0.1)
        let w0 = 2 * Double.pi * f0 / hz
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let a0 = 1 + alpha
        // vDSP_deq22's coefficient array is [b0, b1, b2, a1, a2] with a0 already normalized to 1:
        // y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2].
        return [Float(alpha / a0), 0, Float(-alpha / a0), Float(-2 * cosw0 / a0), Float((1 - alpha) / a0)]
    }

    /// `vDSP_deq22` computes `C[n] = A[n]*B0 + A[n-1]*B1 + A[n-2]*B2 - C[n-1]*B3 - C[n-2]*B4` for
    /// `n` in `2..<(N+2)`; `A` must therefore hold `N + 2` samples (two leading history samples)
    /// and `C` is allocated the same length with `C[0] = C[1] = 0` as the zero initial state.
    /// Padding the two history samples with the input's own first value (rather than zero) keeps
    /// the filter from ringing off a fictitious silent start.
    private static func applyBiquad(_ input: [Float], coefficients: [Float]) -> [Float] {
        let n = input.count
        var a = [Float](repeating: input[0], count: n + 2)
        for i in 0..<n { a[i + 2] = input[i] }
        var c = [Float](repeating: 0, count: n + 2)
        coefficients.withUnsafeBufferPointer { bPtr in
            a.withUnsafeBufferPointer { aPtr in
                c.withUnsafeMutableBufferPointer { cPtr in
                    vDSP_deq22(aPtr.baseAddress!, 1, bPtr.baseAddress!, cPtr.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
        return Array(c[2...])
    }

    // MARK: - Step 3/4/5: autocorrelation, peak-picking, phase resampling

    private struct DetectedCycle {
        var startT: Float
        var periodSeconds: Float
        var phaseX: [Float]
        var phaseY: [Float]
        var phaseZ: [Float]
        var offBaseline: Bool
    }

    private static func detectCycles(chunk: Series, bandpassed: [Float], hz: Double,
                                      searchBand: ClosedRange<Double>, hint: ActivityHint,
                                      cadenceAnchorHz: [WorkoutMetricPoint]) -> [DetectedCycle] {
        let n = bandpassed.count
        guard n > 8 else { return [] }
        let windowSamples = max(min(Int(windowSeconds * hz), n), 8)

        var results: [DetectedCycle] = []
        var lastPeakIndex = -1
        var windowStart = 0
        while windowStart < n {
            let windowEnd = min(windowStart + windowSamples, n)
            defer { windowStart = windowEnd }
            let slice = bandpassed[windowStart..<windowEnd]
            // This call is the periodicity GATE: a window with no meaningful energy (`minVariance`)
            // or no lag in `searchBand` that correlates at least `hint.correlationFloor` strongly
            // produces no cycles here. `.swim`/`.runOrWalk` use the original shared floor
            // (`minCorrelation`, unchanged); `.other` uses a much stricter one — see
            // `ActivityHint.correlationFloor`'s doc comment for why and the measurement behind it.
            // Only WHICH period a periodic `.runOrWalk` window then uses for peak-spacing is refined
            // below.
            guard let periodSamples = dominantPeriodSamples(slice, hz: hz, band: searchBand,
                                                              correlationFloor: hint.correlationFloor) else { continue }
            let effectivePeriodSamples: Float
            if hint == .runOrWalk,
               let refined = refinedPeriodSamples(chunk: chunk, windowStart: windowStart, sliceCount: slice.count,
                                                   slice: slice, hz: hz, band: searchBand,
                                                   cadenceAnchorHz: cadenceAnchorHz) {
                effectivePeriodSamples = refined
            } else {
                effectivePeriodSamples = periodSamples
            }
            let minSpacing = max(Int((0.7 * effectivePeriodSamples).rounded()), 2)

            var i = max(windowStart, 1)
            while i < windowEnd - 1 {
                let isPeak = bandpassed[i] > bandpassed[i - 1] && bandpassed[i] >= bandpassed[i + 1]
                if isPeak, i - lastPeakIndex >= minSpacing {
                    if lastPeakIndex >= 0, let cycle = makeCycle(chunk: chunk, startIdx: lastPeakIndex, endIdx: i) {
                        results.append(cycle)
                    }
                    lastPeakIndex = i
                }
                i += 1
            }
        }
        return results
    }

    // MARK: - `.runOrWalk` period refinement (the arm-swing/step-rate fix)

    /// Once a window is confirmed periodic (see the gate above), picks the period peak-spacing
    /// should actually use — preferring a ground-truth anchor, else a spectral scan — instead of
    /// the raw autocorrelation winner, which is structurally biased toward the longer whole-gait-
    /// cycle (arm-swing) period. Returns `nil` (falls back to the raw autocorrelation winner) only
    /// when neither source resolves, which in practice is rare — `spectralDominantHz` almost
    /// always finds *some* peak in-band once `dominantPeriodSamples` has already confirmed the
    /// window is periodic.
    private static func refinedPeriodSamples(chunk: Series, windowStart: Int, sliceCount: Int, slice: ArraySlice<Float>,
                                              hz: Double, band: ClosedRange<Double>,
                                              cadenceAnchorHz: [WorkoutMetricPoint]) -> Float? {
        let endIdx = min(windowStart + sliceCount, chunk.t.count) - 1
        guard endIdx >= windowStart, windowStart < chunk.t.count else { return nil }
        let windowStartT = TimeInterval(chunk.t[windowStart])
        let windowEndT = TimeInterval(chunk.t[endIdx])

        if let anchorHz = matchedAnchorHz(cadenceAnchorHz, from: windowStartT, to: windowEndT), anchorHz > 0 {
            let clamped = min(max(anchorHz, band.lowerBound), band.upperBound)
            return Float(hz / clamped)
        }
        if let spectralHz = spectralDominantHz(Array(slice), hz: hz, band: band), spectralHz > 0 {
            return Float(hz / spectralHz)
        }
        return nil
    }

    /// Averages every `cadenceAnchorHz` point that lands inside `[start, end]`, widened by
    /// `tolerance` on each side so a 10 s analysis window still finds a nearby measurement even
    /// though `.strideLength` samples arrive roughly every 7–8 s and won't always land inside the
    /// window itself. Returns `nil` when nothing is close enough — the caller falls back to the
    /// spectral estimate, not a fabricated anchor.
    private static func matchedAnchorHz(_ points: [WorkoutMetricPoint], from start: TimeInterval, to end: TimeInterval,
                                         tolerance: TimeInterval = 6) -> Double? {
        guard !points.isEmpty else { return nil }
        let matches = points.filter { $0.t >= start - tolerance && $0.t <= end + tolerance }
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0.0) { $0 + $1.value } / Double(matches.count)
    }

    /// Step-rate anchor, in Hz, for `analyze`'s `cadenceAnchorHz`: the exact same measured
    /// `speed ÷ strideLength` computation `FitnessSessionSummary.derivedCadenceSeries` uses for the
    /// running-dynamics chart (steps/min), converted to Hz and kept at full resolution rather than
    /// downsampled to ~120 chart points — see `FitnessSessionSummary.matchedStepRatePoints`'s doc
    /// comment for why full resolution matters here. Empty for any workout without `.strideLength`/
    /// `.speed` samples (recordings before 17 Aug, or an activity that never records them), which
    /// is exactly when `.runOrWalk` cycle detection falls back to `spectralDominantHz` instead.
    static func stepRateAnchorHz(from samples: [FitnessSample]) -> [WorkoutMetricPoint] {
        FitnessSessionSummary.matchedStepRatePoints(from: samples).map {
            WorkoutMetricPoint(t: $0.t, value: $0.value / 60)
        }
    }

    /// Fallback for a `.runOrWalk` window with no nearby cadence anchor: scans `band` directly for
    /// the frequency with the most Goertzel power. This is what actually fixes the arm-swing lock
    /// when no anchor exists — it is immune to the bug by construction, not by tuning: it compares
    /// candidate frequencies by power at that exact frequency, so the (weaker) arm-swing frequency
    /// and the (stronger) true step-rate frequency are scored independently and the stronger one
    /// wins outright. Raw autocorrelation compares candidate LAGS by whole-window self-similarity
    /// instead, where the longer arm-swing lag wins even when it carries less power, because the
    /// signal repeats exactly at the whole gait cycle but only approximately at half of it (left
    /// and right steps are never perfectly identical) — see the file doc comment's step 3.
    /// Validated against the owner's real running data — see `WorkoutMotionAnalysisTests` and the
    /// fix's changelog for the three-run cross-check.
    private static func spectralDominantHz(_ x: [Float], hz: Double, band: ClosedRange<Double>) -> Double? {
        guard x.count > 4, band.upperBound > band.lowerBound else { return nil }
        let steps = 80
        let stepHz = (band.upperBound - band.lowerBound) / Double(steps)
        var bestFreq = band.lowerBound
        var bestPower: Float = -1
        var f = band.lowerBound
        while f <= band.upperBound {
            let power = goertzelPower(x, hz: hz, freq: f)
            if power > bestPower { bestPower = power; bestFreq = f }
            f += stepHz
        }
        return bestPower > 0 ? bestFreq : nil
    }

    /// Signal power at one exact frequency (the single-bin Goertzel algorithm) — cheaper than a
    /// full FFT for the handful of candidate frequencies `spectralDominantHz` scans per 10 s
    /// window, and avoids creating/destroying an FFT setup object on that same cadence.
    private static func goertzelPower(_ x: [Float], hz: Double, freq: Double) -> Float {
        let n = x.count
        guard n > 0 else { return 0 }
        let omega = 2 * Double.pi * freq / hz
        let coeff = Float(2 * cos(omega))
        var s0: Float = 0, s1: Float = 0, s2: Float = 0
        for value in x {
            s0 = value + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * Float(cos(omega))
        let imag = s2 * Float(sin(omega))
        return real * real + imag * imag
    }

    /// Normalized autocorrelation over one window, searching only lags inside `band`. Returns nil
    /// when the window has no meaningful signal energy at all (near-flat — e.g. a held yoga pose or
    /// rest between sets) or no lag in the search band correlates at least `correlationFloor`
    /// strongly — energetic-but-non-repeating motion (e.g. a strength rep) has real variance and so
    /// only the second check catches it.
    /// Widened from `private` so `WorkoutHandPath` can reuse the same autocorrelation-based period
    /// estimate for its per-lap stroke-rate fundamental — it always calls this with the default
    /// `correlationFloor`, so its behavior is unchanged.
    static func dominantPeriodSamples(_ slice: ArraySlice<Float>, hz: Double,
                                       band: ClosedRange<Double>,
                                       correlationFloor: Float = minCorrelation) -> Float? {
        let values = Array(slice)
        guard values.count > 4 else { return nil }
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        var negMean = -mean
        var centered = [Float](repeating: 0, count: values.count)
        vDSP_vsadd(values, 1, &negMean, &centered, 1, vDSP_Length(values.count))

        var variance: Float = 0
        vDSP_measqv(centered, 1, &variance, vDSP_Length(centered.count))
        guard variance > minVariance else { return nil }

        let minLag = max(Int((hz / band.upperBound).rounded(.down)), 1)
        let maxLag = min(Int((hz / band.lowerBound).rounded(.up)), centered.count - 1)
        guard maxLag > minLag else { return nil }

        var bestLag = -1
        var bestCorrelation: Float = -.infinity
        let denominator = variance * Float(centered.count)
        centered.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in minLag...maxLag {
                let count = centered.count - lag
                guard count > 0 else { continue }
                var sum: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &sum, vDSP_Length(count))
                let normalized = sum / denominator
                if normalized > bestCorrelation { bestCorrelation = normalized; bestLag = lag }
            }
        }
        guard bestLag > 0, bestCorrelation > correlationFloor else { return nil }
        return Float(bestLag)
    }

    private static func makeCycle(chunk: Series, startIdx: Int, endIdx: Int) -> DetectedCycle? {
        guard startIdx >= 0, endIdx < chunk.t.count, endIdx > startIdx else { return nil }
        let (px, py, pz) = phaseResample(chunk, startIdx: startIdx, endIdx: endIdx)
        let periodSeconds = chunk.t[endIdx] - chunk.t[startIdx]
        return DetectedCycle(startT: chunk.t[startIdx], periodSeconds: periodSeconds,
                              phaseX: px, phaseY: py, phaseZ: pz, offBaseline: false)
    }

    /// Resamples one cycle's (x, y, z) span to `count` evenly-spaced phase samples via linear
    /// interpolation over the cycle's own time span, so cycles of different real duration can be
    /// overlaid on the same 0...1 phase axis.
    private static func phaseResample(_ chunk: Series, startIdx: Int, endIdx: Int,
                                       count: Int = 100) -> (x: [Float], y: [Float], z: [Float]) {
        let span = Float(endIdx - startIdx)
        var px = [Float](repeating: 0, count: count)
        var py = [Float](repeating: 0, count: count)
        var pz = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let phase = Float(i) / Float(count - 1)
            let pos = Float(startIdx) + phase * span
            let lo = min(Int(pos), endIdx)
            let hi = min(lo + 1, endIdx)
            let frac = pos - Float(lo)
            px[i] = chunk.x[lo] + (chunk.x[hi] - chunk.x[lo]) * frac
            py[i] = chunk.y[lo] + (chunk.y[hi] - chunk.y[lo]) * frac
            pz[i] = chunk.z[lo] + (chunk.z[hi] - chunk.z[lo]) * frac
        }
        return (px, py, pz)
    }

    /// Flags any cycle whose period is more than `outlierFraction` off the global median period.
    /// (A cycle spanning a data hole is structurally impossible here — chunk boundaries are hole
    /// boundaries, and no cycle is ever built across one — but the flag stays general so a future
    /// caller can add other reasons to distrust a cycle without changing `Cycle`'s shape.)
    private static func flagOutliers(_ cycles: inout [Cycle]) {
        guard cycles.count > 2 else { return }
        let sortedPeriods = cycles.map(\.periodSeconds).sorted()
        let median = sortedPeriods[sortedPeriods.count / 2]
        guard median > 0 else { return }
        for i in cycles.indices {
            let deviation = abs(cycles[i].periodSeconds - median) / median
            if deviation > outlierFraction { cycles[i].offBaseline = true }
        }
    }

    private static func lapNumber(for t: Float, boundaries: [Float]) -> Int {
        var lap = 1
        for (index, boundary) in boundaries.enumerated() where boundary <= t {
            lap = index + 1
        }
        return lap
    }

    // MARK: - Step 7: spectrogram (vDSP_fft_zip)

    private static func computeSpectrogram(chunks: [Series], hz: Double, hint: ActivityHint) -> Spectrogram? {
        let fftSize = effectiveSpectrogramWindow(ideal: hint.spectrogramWindowSamples, chunks: chunks)
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(0))

        let binHz = Float(hz) / Float(fftSize)
        let maxHz = min(hint.spectrogramMaxHz, Float(hz) / 2)
        let numBins = max(1, min(fftSize / 2, Int(maxHz / binHz) + 1))
        let hop = fftSize / 2
        let log2n = vDSP_Length(log2(Double(fftSize)))

        var frames: [SpectrogramFrame] = []
        for chunk in chunks {
            var start = 0
            let magnitude = chunk.magnitude
            while start + fftSize <= magnitude.count {
                // Linear-detrend this frame BEFORE windowing: subtract the least-squares line
                // through it, not just its mean. Magnitude carries a large DC offset (~1 g of
                // gravity) AND, on real recordings, a slow drift within any one ~10-20 s window
                // (effort easing in or out, wrist re-orientation through a turn, ordinary human
                // unevenness) — a Hann window's mainlobe is wide enough in BIN units (~4 bins,
                // regardless of window length) that either an unremoved constant OR an unremoved
                // ramp leaks hard into the first few bins, with more magnitude there than a real
                // but modest-amplitude stroke-rate tone has at its OWN bin. Mean-removal alone
                // caught the synthetic case in `WorkoutMotionAnalysisTests
                // .testSwimDominantFrequencyLandsInAReadablePortionOfTheAxis` but NOT the owner's
                // real swim — measured before this fix, literally all 254 frames of his real
                // BFCCD614… spectrogram locked onto bin 1 with zero variation, the same flat-line
                // symptom in a new guise. A trend's own spectrum falls off as ~1/f, i.e. it's
                // still concentrated at the low end even with the constant term gone, which a full
                // linear detrend (not just de-meaning) removes.
                var sumX = 0.0, sumXI = 0.0
                for i in 0..<fftSize { let v = Double(magnitude[start + i]); sumX += v; sumXI += v * Double(i) }
                let n = Double(fftSize)
                let sumI = n * (n - 1) / 2
                let sumI2 = (n - 1) * n * (2 * n - 1) / 6
                let denom = n * sumI2 - sumI * sumI
                let slope = denom > 0 ? (n * sumXI - sumI * sumX) / denom : 0
                let intercept = (sumX - slope * sumI) / n
                var realp = [Float](repeating: 0, count: fftSize)
                for i in 0..<fftSize {
                    let trend = intercept + slope * Double(i)
                    realp[i] = Float(Double(magnitude[start + i]) - trend) * window[i]
                }
                var imagp = [Float](repeating: 0, count: fftSize)
                var bins = [Float](repeating: 0, count: numBins)
                var dominantHz: Float = 0

                realp.withUnsafeMutableBufferPointer { rPtr in
                    imagp.withUnsafeMutableBufferPointer { iPtr in
                        guard let rBase = rPtr.baseAddress, let iBase = iPtr.baseAddress else { return }
                        var split = DSPSplitComplex(realp: rBase, imagp: iBase)
                        vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        var maxMagnitude: Float = -1
                        var maxBin = 0
                        // Belt-and-suspenders on top of the detrend above: never call a bin below
                        // `minDominantSearchHz` "dominant" even if some residual low-end leakage
                        // (a non-linear drift the linear detrend doesn't fully catch) still peaks
                        // there. No real per-arm-stroke/per-step rhythm happens slower than this —
                        // it's below even swim's own 0.4 Hz search-band floor — so this only ever
                        // excludes leakage, never a genuine reading.
                        let minSearchBin = max(Int((minDominantSearchHz / binHz).rounded(.up)), 1)
                        for k in 0..<numBins {
                            let re = rBase[k], im = iBase[k]
                            let m = (re * re + im * im).squareRoot()
                            bins[k] = m
                            if k >= minSearchBin, m > maxMagnitude { maxMagnitude = m; maxBin = k }
                        }
                        dominantHz = maxMagnitude > 0 ? Float(maxBin) * binHz : 0
                    }
                }
                let centerT = chunk.t[start] + Float(fftSize) / Float(2 * hz)
                frames.append(SpectrogramFrame(t: centerT, dominantHz: dominantHz, bins: bins))
                start += hop
            }
        }
        guard !frames.isEmpty else { return nil }
        return Spectrogram(frames: frames, binHz: binHz, maxHz: maxHz)
    }

    /// Shrinks the activity's ideal window (`ActivityHint.spectrogramWindowSamples`) to fit the
    /// longest available contiguous run when the recording — or its longest gap-free chunk — is
    /// shorter than that ideal, so a short workout still produces a spectrogram (just a coarser
    /// one from a smaller FFT) instead of `computeSpectrogram`'s `while start + fftSize <=
    /// magnitude.count` loop never running once, silently returning an empty (and therefore
    /// `nil`) spectrogram for a recording that genuinely had motion to show. Rounds DOWN to a
    /// power of two — `vDSP_create_fftsetup` requires one — with a floor of 8 samples (0.32 s at
    /// 25 Hz): still a real, if coarse, FFT, rather than degenerating toward a single sample.
    private static func effectiveSpectrogramWindow(ideal: Int, chunks: [Series]) -> Int {
        let longestChunk = chunks.map(\.magnitude.count).max() ?? 0
        guard longestChunk > 0, longestChunk < ideal else { return ideal }
        return max(previousPowerOfTwo(longestChunk), 8)
    }

    private static func previousPowerOfTwo(_ n: Int) -> Int {
        guard n >= 1 else { return 1 }
        var p = 1
        while p * 2 <= n { p *= 2 }
        return p
    }
}

// MARK: - `Cycle`/`SpectrogramFrame` custom `Codable`
//
// See `[Float].packedData`'s doc comment (`FitnessModels.swift`) for why `phaseX`/`phaseY`/
// `phaseZ`/`bins` are routed through `Data` instead of their default per-element array coding — a
// real swim's ~1,344 cycles carry ~400,000 combined phase samples, which cost roughly 700 ms of
// the ~920 ms measured JSON round-trip before this change (see `WorkoutMotionDiskCache`'s doc
// comment, `WorkoutMotionCache.swift`). Custom `init(from:)`/`encode(to:)` in extensions (not on
// the struct itself) so the memberwise init stays available, matching `FitnessSample`'s own
// tolerant-decoder convention just above in this file's sibling, `FitnessModels.swift`.

extension WorkoutMotionAnalysis.Cycle {
    private enum CodingKeys: String, CodingKey { case id, lap, startT, periodSeconds, phaseX, phaseY, phaseZ, offBaseline }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(lap, forKey: .lap)
        try c.encode(startT, forKey: .startT)
        try c.encode(periodSeconds, forKey: .periodSeconds)
        try c.encode(phaseX.packedData, forKey: .phaseX)
        try c.encode(phaseY.packedData, forKey: .phaseY)
        try c.encode(phaseZ.packedData, forKey: .phaseZ)
        try c.encode(offBaseline, forKey: .offBaseline)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        lap = try c.decodeIfPresent(Int.self, forKey: .lap)
        startT = try c.decode(Float.self, forKey: .startT)
        periodSeconds = try c.decode(Float.self, forKey: .periodSeconds)
        phaseX = [Float](packedData: try c.decode(Data.self, forKey: .phaseX)) ?? []
        phaseY = [Float](packedData: try c.decode(Data.self, forKey: .phaseY)) ?? []
        phaseZ = [Float](packedData: try c.decode(Data.self, forKey: .phaseZ)) ?? []
        offBaseline = try c.decode(Bool.self, forKey: .offBaseline)
    }
}

extension WorkoutMotionAnalysis.SpectrogramFrame {
    private enum CodingKeys: String, CodingKey { case t, dominantHz, bins }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(dominantHz, forKey: .dominantHz)
        try c.encode(bins.packedData, forKey: .bins)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Float.self, forKey: .t)
        dominantHz = try c.decode(Float.self, forKey: .dominantHz)
        bins = [Float](packedData: try c.decode(Data.self, forKey: .bins)) ?? []
    }
}
