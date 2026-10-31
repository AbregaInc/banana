import XCTest

/// Coverage for the "record orientation again" fix: the pure rotation-vector encoding
/// (`RotationVector`) that lets `FitnessSample`'s three-double record carry a full attitude, and
/// the new `.orientation` `Kind` — its on-disk code, and that older decoders tolerate it.
final class RotationVectorTests: XCTestCase {

    private let tolerance = 1e-9

    /// Builds a unit quaternion from an axis (need not be pre-normalized) and an angle in
    /// radians, matching the convention `CMAttitude.quaternion` uses.
    private func quaternion(axis: (Double, Double, Double), angleRadians: Double)
        -> (x: Double, y: Double, z: Double, w: Double) {
        let length = (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).squareRoot()
        let n = (axis.0 / length, axis.1 / length, axis.2 / length)
        let half = angleRadians / 2
        let s = sin(half)
        return (n.0 * s, n.1 * s, n.2 * s, cos(half))
    }

    // MARK: - RotationVector round trip

    func testIdentityEncodesToZeroVector() {
        let v = RotationVector.encode(x: 0, y: 0, z: 0, w: 1)
        XCTAssertEqual(v.x, 0, accuracy: tolerance)
        XCTAssertEqual(v.y, 0, accuracy: tolerance)
        XCTAssertEqual(v.z, 0, accuracy: tolerance)

        let q = RotationVector.decode(x: 0, y: 0, z: 0)
        XCTAssertEqual(q.x, 0, accuracy: tolerance)
        XCTAssertEqual(q.y, 0, accuracy: tolerance)
        XCTAssertEqual(q.z, 0, accuracy: tolerance)
        XCTAssertEqual(q.w, 1, accuracy: tolerance)
    }

    /// A 180° turn about X is the sharpest case for the `acos`/`sqrt` branch (w == 0): the
    /// vector's magnitude should land exactly on the rotation angle, π radians.
    func testHalfTurnAboutXEncodesToExpectedMagnitudeAndAxis() {
        let q = quaternion(axis: (1, 0, 0), angleRadians: .pi)
        let v = RotationVector.encode(x: q.x, y: q.y, z: q.z, w: q.w)
        XCTAssertEqual(v.x, .pi, accuracy: tolerance)
        XCTAssertEqual(v.y, 0, accuracy: tolerance)
        XCTAssertEqual(v.z, 0, accuracy: tolerance)

        let roundTripped = RotationVector.decode(x: v.x, y: v.y, z: v.z)
        XCTAssertEqual(roundTripped.x, q.x, accuracy: tolerance)
        XCTAssertEqual(roundTripped.y, q.y, accuracy: tolerance)
        XCTAssertEqual(roundTripped.z, q.z, accuracy: tolerance)
        XCTAssertEqual(roundTripped.w, q.w, accuracy: tolerance)
    }

    /// A quarter turn about Z, and about an arbitrary non-axis-aligned direction — the ordinary
    /// case a wrist in motion actually produces.
    func testQuarterTurnAboutZRoundTrips() {
        let q = quaternion(axis: (0, 0, 1), angleRadians: .pi / 2)
        let v = RotationVector.encode(x: q.x, y: q.y, z: q.z, w: q.w)
        XCTAssertEqual(v.x, 0, accuracy: tolerance)
        XCTAssertEqual(v.y, 0, accuracy: tolerance)
        XCTAssertEqual(v.z, .pi / 2, accuracy: tolerance)

        let roundTripped = RotationVector.decode(x: v.x, y: v.y, z: v.z)
        XCTAssertEqual(roundTripped.x, q.x, accuracy: tolerance)
        XCTAssertEqual(roundTripped.y, q.y, accuracy: tolerance)
        XCTAssertEqual(roundTripped.z, q.z, accuracy: tolerance)
        XCTAssertEqual(roundTripped.w, q.w, accuracy: tolerance)
    }

    func testArbitraryAxisRoundTrips() {
        let angle = 40.0 * .pi / 180
        let q = quaternion(axis: (1, 2, -1.5), angleRadians: angle)
        let v = RotationVector.encode(x: q.x, y: q.y, z: q.z, w: q.w)

        // The vector's magnitude is the rotation angle, regardless of axis direction.
        let magnitude = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        XCTAssertEqual(magnitude, angle, accuracy: tolerance)

        let roundTripped = RotationVector.decode(x: v.x, y: v.y, z: v.z)
        XCTAssertEqual(roundTripped.x, q.x, accuracy: tolerance)
        XCTAssertEqual(roundTripped.y, q.y, accuracy: tolerance)
        XCTAssertEqual(roundTripped.z, q.z, accuracy: tolerance)
        XCTAssertEqual(roundTripped.w, q.w, accuracy: tolerance)
    }

    /// `w` fractionally outside [-1, 1] (floating-point noise on an otherwise-unit quaternion)
    /// must not produce NaN from `acos`.
    func testSlightlyOutOfRangeWDoesNotProduceNaN() {
        let v = RotationVector.encode(x: 0, y: 0, z: 0, w: 1.0000000001)
        XCTAssertFalse(v.x.isNaN)
        XCTAssertFalse(v.y.isNaN)
        XCTAssertFalse(v.z.isNaN)
    }

    // MARK: - `.orientation` sample kind

    func testOrientationKindCodeIsFourteen() {
        XCTAssertEqual(FitnessSample.Kind.orientation.code, 14)
        XCTAssertEqual(FitnessSample.Kind(code: 14), .orientation)
    }

    /// Every other kind's code must stay exactly where it was — the code is the on-disk byte for
    /// every already-recorded workout.
    func testExistingKindCodesAreUnchanged() {
        let expected: [FitnessSample.Kind: UInt8] = [
            .heartRate: 0, .energy: 1, .distance: 2, .accel: 3, .gyro: 4, .location: 5,
            .altitude: 6, .cadence: 7, .power: 8, .strideLength: 9, .verticalOscillation: 10,
            .groundContactTime: 11, .strokeCount: 12, .speed: 13,
        ]
        for (kind, code) in expected {
            XCTAssertEqual(kind.code, code, "\(kind) changed its on-disk code")
            XCTAssertEqual(FitnessSample.Kind(code: code), kind)
        }
    }

    func testDecodeBinaryRoundTripsAnOrientationSample() {
        let sample = FitnessSample(t: 12.5, kind: .orientation, v1: 0.1, v2: -0.2, v3: 0.05)
        let data = FitnessSample.encodeBinary([sample])
        let decoded = FitnessSample.decodeBinary(data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.kind, .orientation)
        XCTAssertEqual(decoded.first?.t, 12.5)
        XCTAssertEqual(decoded.first?.v1, 0.1)
        XCTAssertEqual(decoded.first?.v2, -0.2)
        XCTAssertEqual(decoded.first?.v3, 0.05)
    }

    /// A record whose kind byte no case maps to — what an OLDER build sees when it reads a
    /// `.orientation` record written by this one — must be skipped, not crash or desynchronize
    /// the records around it. `Kind(code:)` returning `nil` plus `decodeBinary`'s
    /// `guard let kind = Kind(code:) else { continue }` is what provides that; this proves it
    /// end-to-end rather than by inspection alone.
    func testDecodeBinaryToleratesAnUnrecognisedKindByte() {
        let before = FitnessSample(t: 1, kind: .heartRate, v1: 70, v2: nil, v3: nil)
        let unknownToOlderBuilds = FitnessSample(t: 2, kind: .orientation, v1: 0.1, v2: 0.2, v3: 0.3)
        let after = FitnessSample(t: 3, kind: .distance, v1: 5, v2: nil, v3: nil)
        var data = Data()
        FitnessSample.appendBinary(before, to: &data)
        FitnessSample.appendBinary(unknownToOlderBuilds, to: &data)
        FitnessSample.appendBinary(after, to: &data)

        // Simulate a build with no `case 255` — overwrite the middle record's leading kind byte
        // with a code nothing maps to.
        data[FitnessSample.recordSize] = 255

        let decoded = FitnessSample.decodeBinary(data)
        XCTAssertEqual(decoded.count, 2, "the unrecognised record should be skipped, not crash or drop its neighbors")
        XCTAssertEqual(decoded.first?.kind, .heartRate)
        XCTAssertEqual(decoded.first?.v1, 70)
        XCTAssertEqual(decoded.last?.kind, .distance)
        XCTAssertEqual(decoded.last?.v1, 5)
    }
}
