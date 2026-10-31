import XCTest

/// Synthetic-fixture coverage for `WorkoutMotionAnalysis`. No binary `.samples` file is read here
/// — every fixture is a `[FitnessSample]` array built directly in Swift, matching the 33-byte
/// binary record's logical shape (kind + t + v1/v2/v3) without touching the encoder/decoder.
final class WorkoutMotionAnalysisTests: XCTestCase {

    // MARK: - Fixtures

    /// A stroke/stride-like accelerometer stream: a clean sinusoid at `freqHz` riding on a
    /// constant-gravity axis, sampled at `hz`. When `gapEvery` is set, a `gapDuration`-long span
    /// of samples is dropped once per `gapEvery` seconds, producing a real (> 200 ms) recording
    /// gap in `t` rather than a synthetic flat spot.
    private func sineAccelSamples(duration: TimeInterval, hz: Double, freqHz: Double,
                                   gapEvery: TimeInterval? = nil, gapDuration: TimeInterval = 0.3) -> [FitnessSample] {
        var samples: [FitnessSample] = []
        let dt = 1.0 / hz
        var t = 0.0
        while t < duration {
            if let gapEvery {
                let phase = t.truncatingRemainder(dividingBy: gapEvery)
                if phase < gapDuration {
                    t += dt
                    continue
                }
            }
            let angle = 2 * Double.pi * freqHz * t
            let x = 0.3 * sin(angle)
            let y = 0.15 * sin(angle * 2 + 0.3)
            let z = 1.0 + 0.2 * cos(angle)
            samples.append(FitnessSample(t: t, kind: .accel, v1: x, v2: y, v3: z))
            t += dt
        }
        return samples
    }

    /// Two superposed tones riding on a gravity axis — `z = 1 + amp1·cos(2π·f1·t) + amp2·cos(2π·f2·t)`,
    /// `x = y = 0` so `magnitude == z` exactly (no cross-axis coupling to reason about). Models the
    /// real running defect directly: `f2 = 2·f1` (the true step rate is exactly double the arm-swing
    /// rate), and whichever of `amp1`/`amp2` is larger controls which frequency actually carries
    /// more spectral power — independent of which one raw autocorrelation prefers. Raw
    /// autocorrelation ALWAYS prefers the longer period (`1/f1`) here regardless of amplitude: at
    /// lag `1/f1` both tones return to their starting phase exactly (constructive), but at lag
    /// `1/f2` only the `f2` tone completes a full cycle — the `f1` tone is exactly half-way through
    /// its own cycle (phase-inverted, destructive). That asymmetry is the mechanism behind the real
    /// bug (see `WorkoutMotionAnalysis`'s file doc comment): it holds for any `amp1 > 0`, which is
    /// exactly why narrowing the search band alone can't fix it — the true fundamental's exact
    /// self-repeat at the sub-harmonic lag wins the autocorrelation regardless of amplitude.
    private func twoToneAccelSamples(duration: TimeInterval, hz: Double, f1: Double, amp1: Double,
                                      f2: Double, amp2: Double) -> [FitnessSample] {
        var samples: [FitnessSample] = []
        let dt = 1.0 / hz
        var t = 0.0
        while t < duration {
            let z = 1.0 + amp1 * cos(2 * Double.pi * f1 * t) + amp2 * cos(2 * Double.pi * f2 * t)
            samples.append(FitnessSample(t: t, kind: .accel, v1: 0, v2: 0, v3: z))
            t += dt
        }
        return samples
    }

    /// A near-motionless stream (gravity on one axis plus tiny noise, no periodic component) —
    /// stands in for a strength session, which should never report a stride/stroke rate.
    private func flatAccelSamples(duration: TimeInterval, hz: Double) -> [FitnessSample] {
        var samples: [FitnessSample] = []
        let dt = 1.0 / hz
        var t = 0.0
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1_442_695_040_888_963_407
            let unit = Double(seed >> 40) / Double(1 << 24)   // [0, 1)
            return (unit - 0.5) * 2e-4                         // far below the periodicity threshold
        }
        while t < duration {
            samples.append(FitnessSample(t: t, kind: .accel, v1: noise(), v2: noise(), v3: 1.0 + noise()))
            t += dt
        }
        return samples
    }

    // MARK: - Clean signal: expected cycle count, no outliers

    func testCleanSineDetectsExpectedCycleCount() {
        let samples = sineAccelSamples(duration: 300, hz: 50, freqHz: 1.5)   // 5 min, 450 expected cycles
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .runOrWalk)

        XCTAssertNotNil(result.accel)
        XCTAssertTrue(result.warnings.isEmpty, "clean, gap-free input should not warn: \(result.warnings)")
        XCTAssertEqual(result.cycles.count, 450, accuracy: 25)
        XCTAssertTrue(result.cycles.allSatisfy { !$0.offBaseline },
                      "a clean, uniformly-sampled sine should never flag an outlier cycle")
        for cycle in result.cycles {
            XCTAssertEqual(cycle.phaseX.count, 100)
            XCTAssertEqual(cycle.phaseY.count, 100)
            XCTAssertEqual(cycle.phaseZ.count, 100)
            XCTAssertNil(cycle.lap, "no lap boundaries were supplied")
        }
        XCTAssertNotNil(result.spectrogram)
        XCTAssertFalse(result.cadenceHzTrace.isEmpty)
    }

    // MARK: - Gap handling

    func testRecordingGapSuppressesCycleDetectionAcrossItAndWarns() {
        let samples = sineAccelSamples(duration: 300, hz: 50, freqHz: 1.5, gapEvery: 30, gapDuration: 0.3)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .runOrWalk)

        XCTAssertFalse(result.warnings.isEmpty, "gaps > 200 ms must be surfaced")
        XCTAssertTrue(result.warnings.contains { $0.contains("gap") && $0.contains("200 ms") })
        // Every 300 ms gap costs at most the cycle that would have spanned it — nowhere near
        // enough to erase the signal, but the count should still land under the gap-free baseline.
        XCTAssertGreaterThan(result.cycles.count, 300)
        XCTAssertLessThan(result.cycles.count, 450)
    }

    // MARK: - Non-periodic (strength) signal

    func testFlatSignalHasNoCyclesButStillProducesASpectrogram() {
        let samples = flatAccelSamples(duration: 120, hz: 50)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .other)

        XCTAssertTrue(result.cycles.isEmpty, "near-flat motion has no stride/stroke to detect")
        XCTAssertNotNil(result.spectrogram, "every raw session gets a spectrogram, cyclic or not")
        XCTAssertFalse(result.spectrogram?.frames.isEmpty ?? true)
    }

    // MARK: - `.other`'s stricter correlationFloor (the strength/yoga invented-cycle fix)
    //
    // `flatAccelSamples` above is near-flat and never reaches the correlation gate at all — it's
    // rejected earlier by `minVariance`. Real strength/yoga motion isn't flat; it has plenty of
    // variance, just none of it repeating. These two tests exercise the gate that fixture can't:
    // validated against the fixed `WorkoutMotionAnalysis` compiled standalone and run against the
    // owner's real 77-minute strength recording (id 32D848BF…, ~115k accel samples) — 1,526
    // fabricated cycles at the old shared floor (0.25), 0 at `.other`'s new floor (0.9), with a real
    // 78-minute yoga session also landing at 0. A real run and a real pool swim, analyzed the same
    // way before and after, produced byte-identical cycle counts and median rates — `.runOrWalk`
    // and `.swim` are untouched by this fix.

    /// Same PRNG shape as `flatAccelSamples` above, but at strength-training-scale amplitude — real
    /// motion, none of it periodic. Standing in for the owner's real strength recording without
    /// reading a fixture file from disk.
    private func aperiodicAccelSamples(duration: TimeInterval, hz: Double, amplitude: Double) -> [FitnessSample] {
        var samples: [FitnessSample] = []
        let dt = 1.0 / hz
        var t = 0.0
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1_442_695_040_888_963_407
            let unit = Double(seed >> 40) / Double(1 << 24)   // [0, 1)
            return (unit - 0.5) * 2 * amplitude
        }
        while t < duration {
            samples.append(FitnessSample(t: t, kind: .accel, v1: noise(), v2: noise(), v3: 1.0 + noise()))
            t += dt
        }
        return samples
    }

    func testAperiodicMotionYieldsNoCyclesUnderTheOtherHintsStricterGate() {
        let samples = aperiodicAccelSamples(duration: 300, hz: 50, amplitude: 0.3)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .other)

        XCTAssertTrue(result.cycles.isEmpty, "energetic but non-periodic motion must not fabricate a cycle rate")
        XCTAssertNotNil(result.spectrogram, "the spectrogram stays meaningful — only cycle detection is gated")

        // Sanity check that this fixture actually exercises the STRICTER gate, not one so mild any
        // gate would reject it: the identical signal at the shared, more permissive floor
        // `.runOrWalk`/`.swim` still use finds spurious "periodic" windows by chance — the same
        // mechanism that produced the real 1,526-cycle strength false positive this fix erases.
        let atSharedFloor = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .runOrWalk)
        XCTAssertFalse(atSharedFloor.cycles.isEmpty,
                        "sanity check: this fixture should still trip the OLD, more permissive floor")
    }

    func testGenuinelyPeriodicOtherHintSignalStillDetectsCycles() {
        // The stricter floor isn't "strength/yoga never get a cycle count" as a hardcoded special
        // case — it's "prove it first". The same clean sine `testCleanSineDetectsExpectedCycleCount`
        // uses, run through `.other` instead of `.runOrWalk`, still detects the expected cycles.
        let samples = sineAccelSamples(duration: 300, hz: 50, freqHz: 1.5)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .other)

        XCTAssertEqual(result.cycles.count, 450, accuracy: 25)
    }

    // MARK: - Activity kind → motion hint (the strength/yoga mis-hint fix)

    /// Mirrors `WorkoutMotionCache.result(for:fitness:)`'s hint-selection line exactly:
    /// `kind.isSwim ? .swim : kind.hasFootstepPeriodicity ? .runOrWalk : .other`. Not testable
    /// through `WorkoutMotionCache` directly — it's `@MainActor` and reads raw samples from
    /// `FitnessStore` — so this exercises the two properties the ternary is built from for every
    /// `WorkoutActivityKind` case. Before the fix, `hasFootstepPeriodicity` was `usesPace`, a
    /// DISPLAY property true for anything that isn't a swim or a ride — which put strength and yoga
    /// through the footstep band/gate alongside running/walking/hiking.
    func testEveryActivityKindMapsToItsIntendedMotionHint() {
        func hint(for kind: WorkoutActivityKind) -> WorkoutMotionAnalysis.ActivityHint {
            kind.isSwim ? .swim : kind.hasFootstepPeriodicity ? .runOrWalk : .other
        }

        let expected: [WorkoutActivityKind: WorkoutMotionAnalysis.ActivityHint] = [
            .running: .runOrWalk,
            .walking: .runOrWalk,
            .hiking: .runOrWalk,
            .cycling: .other,
            .rowing: .other,
            .poolSwim: .swim,
            .openWaterSwim: .swim,
            .strength: .other,
            .yoga: .other,
            .other: .other,
        ]
        for (kind, expectedHint) in expected {
            XCTAssertEqual(hint(for: kind), expectedHint, "\(kind) should map to \(expectedHint), not \(hint(for: kind))")
        }
    }

    // MARK: - Pool swim: per-lap grouping

    func testPoolSwimCyclesGroupByLapWithinTolerance() {
        let lapDuration: TimeInterval = 20
        let lapCount = 3
        let strokeHz = 0.8
        let samples = sineAccelSamples(duration: lapDuration * Double(lapCount), hz: 50, freqHz: strokeHz)
        let boundaries = (0..<lapCount).map { Double($0) * lapDuration }

        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: boundaries, hint: .swim)

        XCTAssertFalse(result.cycles.isEmpty)
        XCTAssertTrue(result.cycles.allSatisfy { $0.lap != nil }, "every cycle should land in a lap")

        let expectedPerLap = lapDuration * strokeHz   // 16
        for lap in 1...lapCount {
            let count = result.cycles.filter { $0.lap == lap }.count
            XCTAssertEqual(Double(count), expectedPerLap, accuracy: expectedPerLap * 0.2,
                            "lap \(lap) cycle count \(count) outside ±20% of \(expectedPerLap)")
        }
    }

    // MARK: - `.runOrWalk` arm-swing / step-rate fix
    //
    // These four tests were validated against the fixed `WorkoutMotionAnalysis` compiled standalone
    // and run against the owner's real running data (three long runs, 28 Aug / 31 Jul / 3 Aug) —
    // the corrected cadence landed within 0.6% of both the independent FFT peak and Apple's own
    // speed÷strideLength figure for every run. The synthetic fixtures below reproduce the same
    // fundamental/sub-harmonic relationship (`f2 = 2·f1`) that made autocorrelation lock onto the
    // arm swing on the real recording, at frequencies chosen purely for test clarity.

    /// Median cycle period across `result.cycles`, in seconds — used below instead of a raw cycle
    /// count because peak-picking on a real (or two-tone synthetic) signal has some per-cycle
    /// jitter; the median is a robust single number to compare against `1/f1` vs `1/f2`.
    private func medianPeriodSeconds(_ result: WorkoutMotionAnalysis.Result) -> Double? {
        let periods = result.cycles.map { Double($0.periodSeconds) }.filter { $0 > 0 }.sorted()
        guard !periods.isEmpty else { return nil }
        return periods[periods.count / 2]
    }

    func testRunOrWalkWithStrongFundamentalAndStrongHalfFrequencyResolvesToTheFundamentalNotTheSubharmonic() {
        // True step rate (3.0 Hz, the "fundamental" from a step-detection point of view) carries
        // MORE spectral power than the arm-swing sub-harmonic at half of it (1.5 Hz) — matching the
        // real recording, where FFT put the true step-rate peak ~7× stronger than the arm-swing
        // secondary peak. No cadence anchor is supplied, so this exercises the spectral fallback.
        let samples = twoToneAccelSamples(duration: 120, hz: 50, f1: 1.5, amp1: 0.15, f2: 3.0, amp2: 0.35)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .runOrWalk)

        guard let median = medianPeriodSeconds(result) else { return XCTFail("expected cycles") }
        XCTAssertLessThan(median, 0.5, "should resolve to the 3.0 Hz fundamental (period 0.33s), " +
                           "not the 1.5 Hz arm-swing sub-harmonic (period 0.67s) that raw autocorrelation prefers")
    }

    func testRunOrWalkFallsBackToSpectralEstimateWhenNoAnchorIsProvided() {
        // The mirror image of the test above: here the arm-swing tone (1.5 Hz) is the spectrally
        // STRONGER one and the true step rate (3.0 Hz) is weaker — with no anchor to correct it,
        // the spectral fallback picks whichever frequency actually carries the power, same as it
        // would for the real recording if footstrike impact weren't the dominant spectral feature.
        // This is the fallback path actually running, not a fixed answer independent of the signal.
        let samples = twoToneAccelSamples(duration: 120, hz: 50, f1: 1.5, amp1: 0.35, f2: 3.0, amp2: 0.15)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .runOrWalk)

        guard let median = medianPeriodSeconds(result) else { return XCTFail("expected cycles") }
        XCTAssertGreaterThan(median, 0.5, "with no anchor, the fallback should follow the spectrally " +
                              "dominant 1.5 Hz tone (period 0.67s), confirming it's driven by signal power")
    }

    func testRunOrWalkPrefersTheCadenceAnchorOverTheSpectralEstimateWhenBothAreAvailable() {
        // Identical signal to the fallback test above (spectrally, 1.5 Hz would win) — but this
        // time a cadence anchor says the true rate is 3.0 Hz throughout, exactly like a run's
        // measured `speed ÷ strideLength`. The anchor must win.
        let samples = twoToneAccelSamples(duration: 120, hz: 50, f1: 1.5, amp1: 0.35, f2: 3.0, amp2: 0.15)
        let anchor = stride(from: 0.0, to: 120.0, by: 5.0).map { WorkoutMetricPoint(t: $0, value: 3.0) }
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .runOrWalk,
                                                     cadenceAnchorHz: anchor)

        guard let median = medianPeriodSeconds(result) else { return XCTFail("expected cycles") }
        XCTAssertLessThan(median, 0.5, "a present cadence anchor (3.0 Hz) must win over the spectral " +
                           "estimate, which alone would have followed the stronger 1.5 Hz tone")
    }

    func testSwimBehaviorIsUnchangedByTheRunOrWalkFix() {
        // Same fundamental/sub-harmonic shape as the tests above, transposed into the swim search
        // band (0.4...1.2 Hz): a spectrally weaker 0.5 Hz tone and a spectrally stronger 1.0 Hz
        // tone. `.swim` never calls into the anchor/spectral refinement added for `.runOrWalk` — it
        // still resolves to raw autocorrelation's winner, which (per this file's `twoToneAccelSamples`
        // doc comment) is always the longer period regardless of amplitude. Pinning this proves the
        // fix is scoped to `.runOrWalk` only, matching the hand-path work's reliance on `.swim`
        // (and the shared `dominantPeriodSamples` it calls directly) staying byte-for-byte unchanged.
        let samples = twoToneAccelSamples(duration: 120, hz: 50, f1: 0.5, amp1: 0.1, f2: 1.0, amp2: 0.3)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .swim)

        guard let median = medianPeriodSeconds(result) else { return XCTFail("expected cycles") }
        XCTAssertGreaterThan(median, 1.5, "swim must still resolve to the 0.5 Hz sub-harmonic " +
                              "(period 2.0s) exactly as before — it never gets the .runOrWalk refinement")
    }

    // MARK: - Degenerate input

    func testEmptyInputReturnsAnEmptyResultWithoutCrashing() {
        let result = WorkoutMotionAnalysis.analyze(accelSamples: [], lapBoundaries: [], hint: .other)
        XCTAssertNil(result.accel)
        XCTAssertTrue(result.cycles.isEmpty)
        XCTAssertNil(result.spectrogram)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testNonAccelSamplesAreIgnored() {
        let heartRateOnly = (0..<10).map { FitnessSample(t: Double($0), kind: .heartRate, v1: 120, v2: nil, v3: nil) }
        let result = WorkoutMotionAnalysis.analyze(accelSamples: heartRateOnly, lapBoundaries: [], hint: .other)
        XCTAssertNil(result.accel)
        XCTAssertTrue(result.cycles.isEmpty)
    }

    // MARK: - Frequency chart fix: per-activity spectrogram window and axis range
    //
    // The bug (see this file's own analysis and `ActivityHint.spectrogramWindowSamples`'s doc
    // comment): a real swim's stroke rate (~0.5 Hz) landed in the bottom ~6% of a fixed 6 Hz axis,
    // with only ~6 usable bins across the whole useful 0.2–1.5 Hz range — a flat line at the
    // bottom of the chart regardless of how much the rate actually varied.

    /// The window/axis choice itself, per activity — pure, no signal needed.
    func testSpectrogramWindowAndAxisArePickedPerActivity() {
        XCTAssertEqual(WorkoutMotionAnalysis.ActivityHint.swim.spectrogramWindowSamples, 512,
                        "the owner's own numbers: 512 samples @ 25 Hz = 20 s window, 0.049 Hz bins")
        XCTAssertEqual(WorkoutMotionAnalysis.ActivityHint.runOrWalk.spectrogramWindowSamples, 256)
        XCTAssertEqual(WorkoutMotionAnalysis.ActivityHint.other.spectrogramWindowSamples, 128)

        // Every window is a power of two — `vDSP_create_fftsetup` requires it.
        for hint: WorkoutMotionAnalysis.ActivityHint in [.swim, .runOrWalk, .other] {
            let n = hint.spectrogramWindowSamples
            XCTAssertEqual(n & (n - 1), 0, "\(hint): \(n) is not a power of two")
        }

        // Axis ceiling scales with each activity's OWN plausible band, not one shared constant —
        // and must clear the top of that band (never crop off real content), with headroom.
        for hint: WorkoutMotionAnalysis.ActivityHint in [.swim, .runOrWalk, .other] {
            XCTAssertGreaterThan(hint.spectrogramMaxHz, Float(hint.searchBandHz.upperBound),
                                  "\(hint): axis ceiling must clear the top of the plausible band")
        }
        XCTAssertLessThan(WorkoutMotionAnalysis.ActivityHint.swim.spectrogramMaxHz, 3,
                           "swim's old fixed 6 Hz axis squashed a ~0.5 Hz stroke rate into the bottom ~8%; " +
                           "the new axis must be scaled down to the swim band, not still a wide, mostly-empty range")
    }

    /// Resolution: a swim's bin spacing must be fine enough to show a rate DRIFTING within the
    /// 0.2–1.5 Hz useful range the owner measured — not the old ~6-bin resolution across that span.
    func testSwimSpectrogramHasFineEnoughBinsToShowADriftingRate() {
        let samples = sineAccelSamples(duration: 120, hz: 25, freqHz: 0.5)   // his real stroke rate
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .swim)
        guard let spectrogram = result.spectrogram else { return XCTFail("expected a spectrogram") }

        XCTAssertLessThan(spectrogram.binHz, 0.06, "512-sample window @ 25 Hz should give ~0.049 Hz bins")
        let usableRangeHz: Float = 1.5 - 0.2
        let usableBinCount = usableRangeHz / spectrogram.binHz
        XCTAssertGreaterThan(usableBinCount, 20,
                              "the old 128-sample window gave only ~6 usable bins across this range — " +
                              "the fix must give meaningfully more, not a marginal improvement")
    }

    /// Range: the dominant trace for a realistic swim stroke rate must land in a READABLE part of
    /// the axis, not hugging the very bottom — this is the other half of the fix, independent of
    /// bin resolution (a fine-grained trace that's still squashed to the bottom 6% of a tall axis
    /// is still unreadable).
    func testSwimDominantFrequencyLandsInAReadablePortionOfTheAxis() {
        let samples = sineAccelSamples(duration: 120, hz: 25, freqHz: 0.5)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .swim)
        guard let spectrogram = result.spectrogram, let frame = spectrogram.frames.first(where: { $0.dominantHz > 0 }) else {
            return XCTFail("expected a spectrogram with a detected dominant frequency")
        }
        let fraction = frame.dominantHz / spectrogram.maxHz
        XCTAssertGreaterThan(fraction, 0.2,
                              "the real bug: a ~0.5 Hz stroke rate on the OLD fixed 6 Hz axis landed at ~8% up the chart")
    }

    /// A sine riding on a slow LINEAR DRIFT, not just a constant gravity offset — a swimmer's
    /// effort easing in or out across one FFT window, or the wrist re-orienting through a turn.
    /// Models the real bug de-meaning alone did not catch: verified against the owner's real
    /// BFCCD614… swim, every one of 254 spectrogram frames locked onto the lowest bin with ZERO
    /// variation once mean-removal alone was in place — the trend's own ~1/f spectrum still beat
    /// the real stroke-rate tone at the lowest bins. `driftPerSecond` is deliberately large enough
    /// (over a 20 s window, a swing comparable to the tone's own 0.2 amplitude) that a detector
    /// only removing the frame's mean, not its trend, would still fail this test.
    private func sineWithLinearDriftAccelSamples(duration: TimeInterval, hz: Double, freqHz: Double,
                                                   driftPerSecond: Double) -> [FitnessSample] {
        var samples: [FitnessSample] = []
        let dt = 1.0 / hz
        var t = 0.0
        while t < duration {
            let angle = 2 * Double.pi * freqHz * t
            let x = 0.3 * sin(angle)
            let y = 0.15 * sin(angle * 2 + 0.3)
            let z = 1.0 + driftPerSecond * t + 0.2 * cos(angle)
            samples.append(FitnessSample(t: t, kind: .accel, v1: x, v2: y, v3: z))
            t += dt
        }
        return samples
    }

    func testSwimDominantFrequencyIsNotFooledByASlowLinearDriftWithinAWindow() {
        let samples = sineWithLinearDriftAccelSamples(duration: 120, hz: 25, freqHz: 0.5, driftPerSecond: 0.01)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .swim)
        guard let spectrogram = result.spectrogram else { return XCTFail("expected a spectrogram") }
        let nonZero = spectrogram.frames.filter { $0.dominantHz > 0 }
        XCTAssertFalse(nonZero.isEmpty, "expected at least one frame with a detected dominant frequency")
        for frame in nonZero {
            let fraction = frame.dominantHz / spectrogram.maxHz
            XCTAssertGreaterThan(fraction, 0.2,
                                  "a slow trend within the window must not out-leak the real ~0.5 Hz stroke tone " +
                                  "into the lowest bin — de-meaning alone does not catch this, only a full linear detrend does")
        }
    }

    /// A short recording (well under the 20 s ideal swim window) must still produce a spectrogram,
    /// not silently nothing — `effectiveSpectrogramWindow` shrinking the FFT to fit is what this
    /// exercises; without it, `computeSpectrogram`'s frame loop never runs once and the whole card
    /// would have reported no data for a workout that genuinely had motion to show.
    func testShortSwimStillProducesASpectrogram() {
        let samples = sineAccelSamples(duration: 6, hz: 25, freqHz: 0.6)   // well under the 20.48 s ideal swim window
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .swim)
        XCTAssertNotNil(result.spectrogram, "a short workout must still produce SOMETHING, not an empty spectrogram")
        XCTAssertFalse(result.spectrogram?.frames.isEmpty ?? true)
    }

    /// A near-instant recording (far too little data for even the smallest sane FFT) must still
    /// fail SAFELY — nil, not a crash or a division-by-zero bin count.
    func testExtremelyShortRecordingProducesNoSpectrogramWithoutCrashing() {
        let samples = sineAccelSamples(duration: 0.15, hz: 25, freqHz: 0.6)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .swim)
        // Either nil, or (if just barely enough samples for the 8-sample floor) a valid non-empty
        // spectrogram — never a crash, and never an empty non-nil spectrogram.
        if let spectrogram = result.spectrogram {
            XCTAssertFalse(spectrogram.frames.isEmpty)
        }
    }

    // MARK: - Per-page technique-consistency (`pageConsistency`)

    /// A page with a real, repeated periodic signal must report a LOW consistency ratio — the
    /// cycles genuinely do overlay tightly once phase-resampled, since they're all the same clean
    /// sine. End-to-end coverage of `WorkoutMotionAnalysis.computePageConsistency` on top of
    /// `WorkoutMotionConsistencyTests`' direct unit coverage of the underlying math.
    func testCleanPeriodicSignalReportsALowConsistencyRatio() {
        let samples = sineAccelSamples(duration: 60, hz: 50, freqHz: 1.5)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .runOrWalk)
        XCTAssertFalse(result.pageConsistency.isEmpty, "a clean 60 s recording should have at least one windowed page")
        for (_, ratio) in result.pageConsistency {
            XCTAssertLessThan(ratio, 0.5, "a clean, repeating sine's cycles should overlay tightly after alignment")
        }
    }

    /// A page with fewer than two cycles has nothing to compare — must be absent, not a fabricated
    /// 0 or some other placeholder. Reuses `flatAccelSamples`, already proven elsewhere in this
    /// file (`testFlatSignalHasNoCyclesButStillProducesASpectrogram`) to detect zero cycles, so
    /// this is a hard guarantee rather than a conditional one.
    func testPageWithFewerThanTwoCyclesHasNoConsistencyEntry() {
        let samples = flatAccelSamples(duration: 120, hz: 50)
        let result = WorkoutMotionAnalysis.analyze(accelSamples: samples, lapBoundaries: [], hint: .other)
        XCTAssertTrue(result.cycles.isEmpty, "sanity check — this fixture must produce zero cycles")
        XCTAssertTrue(result.pageConsistency.isEmpty)
    }
}
