import XCTest

/// Coverage for the 2026-09 explicit-collection pass: the eight new `FitnessSample.Kind` cases
/// (step count, physical effort, effort score, perfusion index, underwater depth, water
/// temperature, barometric altitude, swim stroke style) appended after `.orientation`, and the
/// running-cadence derivation (`FitnessSessionSummary.derivedCadenceSeries`) computed from
/// measured speed × stride length.
final class FitnessSampleCodingTests: XCTestCase {

    // MARK: - Kind codes: new cases correct, existing cases unchanged

    /// Locks in every on-disk byte. These are load-bearing: `Kind.code` values are read back by
    /// `init?(code:)` for every previously-recorded workout on disk, so a changed value here
    /// would silently reinterpret old recordings as the wrong signal.
    func testExistingKindCodesAreUnchanged() {
        let expected: [FitnessSample.Kind: UInt8] = [
            .heartRate: 0, .energy: 1, .distance: 2, .accel: 3, .gyro: 4, .location: 5,
            .altitude: 6, .cadence: 7, .power: 8, .strideLength: 9, .verticalOscillation: 10,
            .groundContactTime: 11, .strokeCount: 12, .speed: 13, .orientation: 14,
        ]
        for (kind, code) in expected {
            XCTAssertEqual(kind.code, code, "\(kind) changed on-disk code")
        }
    }

    func testNewKindCodesAreAppendedAfterOrientation() {
        let expected: [FitnessSample.Kind: UInt8] = [
            .stepCount: 15, .physicalEffort: 16, .effortScore: 17, .perfusionIndex: 18,
            .underwaterDepth: 19, .waterTemperature: 20, .barometricAltitude: 21,
            .strokeStyle: 22,
        ]
        for (kind, code) in expected {
            XCTAssertEqual(kind.code, code, "\(kind) has an unexpected on-disk code")
        }
    }

    /// `code` and `init?(code:)` must stay exact inverses for every case — the compiler enforces
    /// this for `code` (exhaustive switch over `Kind`) but NOT for `init?(code:)` (a switch over
    /// `UInt8` with a `default: return nil`), so a case added to one and forgotten in the other
    /// would only ever surface as a silently-dropped signal on device.
    func testEveryKindRoundTripsThroughItsCode() {
        let allKinds: [FitnessSample.Kind] = [
            .heartRate, .energy, .distance, .accel, .gyro, .location, .altitude, .cadence,
            .power, .strideLength, .verticalOscillation, .groundContactTime, .strokeCount,
            .speed, .orientation, .stepCount, .physicalEffort, .effortScore, .perfusionIndex,
            .underwaterDepth, .waterTemperature, .barometricAltitude, .strokeStyle,
        ]
        for kind in allKinds {
            XCTAssertEqual(FitnessSample.Kind(code: kind.code), kind)
        }
    }

    // MARK: - Binary encode/decode round trip

    /// A sample carrying one of the brand-new kinds survives `encodeBinary`/`decodeBinary`
    /// unchanged, including its optional v2/v3 fields.
    func testNewKindSampleRoundTripsThroughBinaryEncoding() {
        let samples: [FitnessSample] = [
            FitnessSample(t: 12.5, kind: .stepCount, v1: 1_204, v2: nil, v3: nil),
            FitnessSample(t: 40.0, kind: .barometricAltitude, v1: 88.3, v2: nil, v3: nil),
            FitnessSample(t: 41.0, kind: .strokeStyle, v1: 2, v2: nil, v3: nil),   // freestyle
        ]
        let data = FitnessSample.encodeBinary(samples)
        let decoded = FitnessSample.decodeBinary(data)
        XCTAssertEqual(decoded.count, samples.count)
        for (original, roundTripped) in zip(samples, decoded) {
            XCTAssertEqual(roundTripped.kind, original.kind)
            XCTAssertEqual(roundTripped.t, original.t)
            XCTAssertEqual(roundTripped.v1, original.v1)
            XCTAssertNil(roundTripped.v2)
            XCTAssertNil(roundTripped.v3)
        }
    }

    /// An old-style record — a pre-existing `Kind` (here `.heartRate`, code 0, byte-for-byte the
    /// same layout every recording since before this change used) — still decodes correctly once
    /// the new cases exist. Simulates the exact byte layout `appendBinary` has always produced,
    /// built by hand rather than through today's encoder, so this doesn't just test the encoder
    /// against itself.
    func testOlderStyleRecordStillDecodes() {
        var data = Data()
        data.append(0)   // .heartRate's code, unchanged
        func appendBits(_ value: Double) {
            var bits = value.bitPattern
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        appendBits(3.5)     // t
        appendBits(142.0)   // v1 = bpm
        appendBits(.nan)    // v2 absent
        appendBits(.nan)    // v3 absent

        let decoded = FitnessSample.decodeBinary(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.kind, .heartRate)
        XCTAssertEqual(decoded.first?.t, 3.5)
        XCTAssertEqual(decoded.first?.v1, 142.0)
        XCTAssertNil(decoded.first?.v2)
    }

    /// A record whose kind byte this build doesn't recognize (a future kind an older build would
    /// see) is skipped, not crashed on or misinterpreted — the same tolerance that lets an older
    /// phone/Mac build open a workout containing one of today's brand-new kinds.
    func testUnknownKindByteIsSkippedNotCrashed() {
        var data = Data()
        let known = FitnessSample(t: 1, kind: .heartRate, v1: 100, v2: nil, v3: nil)
        FitnessSample.appendBinary(known, to: &data)
        data.append(200)   // an unrecognized future kind byte
        for _ in 0..<4 { var bits = Double(0).bitPattern; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        let known2 = FitnessSample(t: 2, kind: .distance, v1: 50, v2: nil, v3: nil)
        FitnessSample.appendBinary(known2, to: &data)

        let decoded = FitnessSample.decodeBinary(data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].kind, .heartRate)
        XCTAssertEqual(decoded[1].kind, .distance)
    }

    // MARK: - Running cadence derivation

    private func speedSample(_ t: TimeInterval, _ mps: Double) -> FitnessSample {
        FitnessSample(t: t, kind: .speed, v1: mps, v2: nil, v3: nil)
    }
    private func strideSample(_ t: TimeInterval, _ meters: Double) -> FitnessSample {
        FitnessSample(t: t, kind: .strideLength, v1: meters, v2: nil, v3: nil)
    }

    /// Known inputs, exact arithmetic: 3.0 m/s at a 1.0 m stride is 180 steps/min
    /// (3.0 × 60 ÷ 1.0). Speed and stride-length samples land at different timestamps (their
    /// real-world rates never line up), so the stride sample must forward-fill the most recent
    /// speed at or before it.
    func testDerivedCadenceUsesMostRecentSpeedAtOrBeforeStrideSample() {
        let samples = [
            speedSample(0, 2.0),
            strideSample(5, 1.0),     // most recent speed at t=5 is the t=0 sample (2.0 m/s)
            speedSample(10, 3.0),
            strideSample(12, 1.0),    // most recent speed at t=12 is the t=10 sample (3.0 m/s)
        ]
        let cadence = FitnessSessionSummary.derivedCadenceSeries(from: samples)
        XCTAssertEqual(cadence.count, 2)
        XCTAssertEqual(cadence[0].t, 5)
        XCTAssertEqual(cadence[0].value, 2.0 * 60 / 1.0, accuracy: 1e-9)   // 120 spm
        XCTAssertEqual(cadence[1].t, 12)
        XCTAssertEqual(cadence[1].value, 3.0 * 60 / 1.0, accuracy: 1e-9)   // 180 spm
    }

    /// A stride-length sample with no speed sample at or before it yet has nothing to hold —
    /// it's skipped, not paired with a "future" speed reading.
    func testDerivedCadenceSkipsStrideBeforeAnySpeedIsKnown() {
        let samples = [
            strideSample(0, 1.2),     // no speed known yet
            speedSample(5, 3.0),
            strideSample(6, 1.2),
        ]
        let cadence = FitnessSessionSummary.derivedCadenceSeries(from: samples)
        XCTAssertEqual(cadence.count, 1)
        XCTAssertEqual(cadence[0].t, 6)
    }

    /// A zero stride length must never produce `.infinity` (or any value at all) — a fabricated
    /// cadence from a bad denominator is worse than a gap in the chart.
    func testDerivedCadenceProducesNothingForZeroStrideLength() {
        let samples = [
            speedSample(0, 3.0),
            strideSample(1, 0.0),
            strideSample(2, 1.0),
        ]
        let cadence = FitnessSessionSummary.derivedCadenceSeries(from: samples)
        XCTAssertEqual(cadence.count, 1)
        XCTAssertEqual(cadence[0].t, 2)
        XCTAssertTrue(cadence.allSatisfy { $0.value.isFinite })
    }

    /// No stride-length samples at all (cycling, swimming, strength — anything but a run) yields
    /// an empty series, not a crash or a spurious zero-length series.
    func testDerivedCadenceIsEmptyWithoutStrideLengthSamples() {
        let samples = [speedSample(0, 3.0), speedSample(5, 4.0)]
        XCTAssertTrue(FitnessSessionSummary.derivedCadenceSeries(from: samples).isEmpty)
    }
}

/// A track that never left one place (a gym, a studio) is drawn as a dot, not a line.
final class RoutePlaceTests: XCTestCase {
    private func track(_ offsets: [(Double, Double)], at lat: Double = 37.3861, lon: Double = -122.0839) -> [RoutePoint] {
        offsets.map { RoutePoint(lat: lat + $0.0, lon: lon + $0.1) }
    }

    func testGPSJitterInsideABuildingIsOnePlace() {
        // About ±30 m either way.
        let jitter = track([(0.00025, 0), (-0.00025, 0.0003), (0, -0.0003), (0.0001, 0.0001)])
        XCTAssertTrue(jitter.isOnePlace)
        XCTAssertEqual(jitter.center!.lat, 37.3861 + 0.000025, accuracy: 1e-9)
    }

    func testARunAroundTheBlockIsARoute() {
        // ~300 m north, then back.
        let run = track([(0, 0), (0.0027, 0), (0.0027, 0.002), (0, 0)])
        XCTAssertFalse(run.isOnePlace)
    }

    func testTheEdgeIsAHundredMetres() {
        // Two points ~180 m apart: 90 m from their middle, still one place; ~220 m apart is not.
        XCTAssertTrue(track([(0, 0), (0.00162, 0)]).isOnePlace)
        XCTAssertFalse(track([(0, 0), (0.00198, 0)]).isOnePlace)
    }

    func testOnePointOrNoneIsNoPlace() {
        XCTAssertFalse(track([]).isOnePlace)
        XCTAssertFalse(track([(0, 0)]).isOnePlace)
    }
}
