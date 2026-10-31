import XCTest

/// Coverage for `WorkoutMotionDiskCache` (`WorkoutMotionDiskCache.swift`) and the packed-`Data`
/// `Codable` conformances it depends on (`WorkoutMotionAnalysis.Cycle`/`SpectrogramFrame`,
/// `WorkoutHandPath.Lap`) — see that cache's doc comment for the measured cost this exists to
/// avoid. Every test here operates on a throwaway temp directory, never the real Fitness
/// directory `FitnessStore` owns.
final class WorkoutMotionDiskCacheTests: XCTestCase {

    private func tempURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("motion-cache-tests-\(name).json")
    }

    // MARK: - `[Float].packedData` round trip

    /// The fast-path this whole cache depends on: a `[Float]` must survive `packedData`/
    /// `init(packedData:)` bit-for-bit, including edge cases a naive implementation could get
    /// wrong (empty array, single element, NaN/negative/very small magnitudes).
    func testFloatArrayPackedDataRoundTrips() {
        let cases: [[Float]] = [
            [],
            [0],
            [1, 2, 3, 4, 5],
            [-1.5, 0.0, 3.14159, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude],
            [Float.leastNonzeroMagnitude, -0.0],
            (0..<1000).map { Float($0) * 0.001 - 0.5 },
        ]
        for original in cases {
            let packed = original.packedData
            let restored = [Float](packedData: packed)
            XCTAssertEqual(restored, original)
        }
    }

    /// NaN doesn't compare equal to itself, so it needs its own assertion — this is exactly the
    /// bit pattern `WorkoutMotionAnalysis.Cycle`'s phase arrays could plausibly carry from an
    /// upstream computation, so the packing must preserve it exactly, not just "a" float.
    func testFloatArrayPackedDataPreservesNaN() {
        let original: [Float] = [1.0, .nan, -2.5]
        let restored = [Float](packedData: original.packedData)
        XCTAssertEqual(restored?.count, 3)
        XCTAssertEqual(restored?[0], 1.0)
        XCTAssertTrue(restored?[1].isNaN ?? false)
        XCTAssertEqual(restored?[2], -2.5)
    }

    /// A byte count that isn't a whole number of `Float`s (4 bytes) must fail cleanly, not crash
    /// or silently truncate — this is the guard a corrupted or truncated cache file relies on.
    func testFloatArrayPackedDataRejectsMisalignedByteCount() {
        let malformed = Data([0x00, 0x01, 0x02])   // 3 bytes: not a multiple of 4
        XCTAssertNil([Float](packedData: malformed))
    }

    // MARK: - `Cycle`/`SpectrogramFrame`/`Lap` custom `Codable`

    private func cycle(id: Int, lap: Int?) -> WorkoutMotionAnalysis.Cycle {
        WorkoutMotionAnalysis.Cycle(id: id, lap: lap, startT: Float(id) * 1.5, periodSeconds: 0.9,
                                     phaseX: (0..<100).map { Float($0) }, phaseY: (0..<100).map { Float($0) * 2 },
                                     phaseZ: (0..<100).map { Float($0) * -1 }, offBaseline: id % 2 == 0)
    }

    func testCycleCodableRoundTrips() throws {
        let original = cycle(id: 7, lap: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutMotionAnalysis.Cycle.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.lap, original.lap)
        XCTAssertEqual(decoded.startT, original.startT)
        XCTAssertEqual(decoded.periodSeconds, original.periodSeconds)
        XCTAssertEqual(decoded.phaseX, original.phaseX)
        XCTAssertEqual(decoded.phaseY, original.phaseY)
        XCTAssertEqual(decoded.phaseZ, original.phaseZ)
        XCTAssertEqual(decoded.offBaseline, original.offBaseline)
    }

    /// `lap` is `nil` outside pool swims — must round-trip as absent, not as some sentinel int.
    func testCycleCodableRoundTripsNilLap() throws {
        let original = cycle(id: 1, lap: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutMotionAnalysis.Cycle.self, from: data)
        XCTAssertNil(decoded.lap)
    }

    func testSpectrogramFrameCodableRoundTrips() throws {
        let original = WorkoutMotionAnalysis.SpectrogramFrame(t: 12.5, dominantHz: 1.8, bins: (0..<31).map { Float($0) * 0.1 })
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutMotionAnalysis.SpectrogramFrame.self, from: data)
        XCTAssertEqual(decoded.t, original.t)
        XCTAssertEqual(decoded.dominantHz, original.dominantHz)
        XCTAssertEqual(decoded.bins, original.bins)
    }

    private func lap(id: Int, pointCount: Int) -> WorkoutHandPath.Lap {
        let points = (0..<pointCount).map {
            WorkoutHandPath.Point(t: Float($0) * 0.04, angle: Float($0) * 0.3, axial: Float($0) * 0.6, effort: Float($0 % 10) / 10)
        }
        return WorkoutHandPath.Lap(id: id, lengthMeters: 22.86, startT: Double(id) * 40, duration: 38.4,
                                    strokeCount: pointCount / 24, distancePerStroke: 1.9, points: points,
                                    strokeBoundaries: [0, 10, 20, 30], syntheticBoundaryCount: 1,
                                    planarity: 2.4, warnings: ["1 of 3 stroke boundaries are synthetic"])
    }

    func testLapCodableRoundTrips() throws {
        let original = lap(id: 5, pointCount: 337)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutHandPath.Lap.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.lengthMeters, original.lengthMeters)
        XCTAssertEqual(decoded.startT, original.startT)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.strokeCount, original.strokeCount)
        XCTAssertEqual(decoded.distancePerStroke, original.distancePerStroke)
        XCTAssertEqual(decoded.points, original.points)
        XCTAssertEqual(decoded.strokeBoundaries, original.strokeBoundaries)
        XCTAssertEqual(decoded.syntheticBoundaryCount, original.syntheticBoundaryCount)
        XCTAssertEqual(decoded.planarity, original.planarity)
        XCTAssertEqual(decoded.warnings, original.warnings)
    }

    /// Zero points is the shape a rest-length lap (no strokes detected) produces — must not crash
    /// the flatten/unflatten round trip.
    func testLapCodableRoundTripsWithNoPoints() throws {
        let original = lap(id: 0, pointCount: 0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutHandPath.Lap.self, from: data)
        XCTAssertTrue(decoded.points.isEmpty)
    }

    // MARK: - `WorkoutMotionCacheEntry.isFresh` — the pure freshness check

    func testIsFreshRequiresMatchingVersionAndSampleFileSize() {
        let entry = WorkoutMotionCacheEntry(version: 3, sampleFileSize: 4_359_663, result: nil, handPath: nil)
        XCTAssertTrue(entry.isFresh(version: 3, sampleFileSize: 4_359_663))
        XCTAssertFalse(entry.isFresh(version: 4, sampleFileSize: 4_359_663), "a code-version bump must invalidate the cache")
        XCTAssertFalse(entry.isFresh(version: 3, sampleFileSize: 4_359_664),
                        "a different sample file size — e.g. a re-trimmed recording — must invalidate the cache")
        XCTAssertFalse(entry.isFresh(version: 4, sampleFileSize: 999),
                        "both stale is still stale, not accidentally fresh")
    }

    // MARK: - `WorkoutMotionDiskCache.load`/`.save`

    func testSaveThenLoadRoundTripsAFullEntry() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = WorkoutMotionAnalysis.Result(accel: nil, cycles: [cycle(id: 0, lap: 1), cycle(id: 1, lap: 1)],
                                                   spectrogram: nil, cadenceHzTrace: [], warnings: ["1 gap > 200 ms skipped"],
                                                   pageConsistency: [0: 0.42])
        let handPath = WorkoutHandPath.Analysis(laps: [lap(id: 0, pointCount: 40)], radiusMeters: 0.6, warnings: [])
        let entry = WorkoutMotionCacheEntry(version: WorkoutMotionDiskCache.version, sampleFileSize: 1_234, result: result, handPath: handPath)

        WorkoutMotionDiskCache.save(entry, to: url)
        let loaded = WorkoutMotionDiskCache.load(from: url, sampleFileSize: 1_234)

        XCTAssertEqual(loaded?.result?.cycles.count, 2)
        XCTAssertEqual(loaded?.result?.cycles.first?.phaseX, cycle(id: 0, lap: 1).phaseX)
        XCTAssertEqual(loaded?.handPath?.laps.first?.points.count, 40)
        XCTAssertEqual(loaded?.result?.warnings, ["1 gap > 200 ms skipped"])
        XCTAssertEqual(loaded?.result?.pageConsistency, [0: 0.42], "pageConsistency must round-trip with the rest of the per-lap analysis")
    }

    /// Both `result` and `handPath` can legitimately be `nil` (an unusable recording, or a
    /// non-swim workout) — that must still round-trip as a HIT, not be indistinguishable from a
    /// miss.
    func testSaveThenLoadRoundTripsNilFields() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = WorkoutMotionCacheEntry(version: WorkoutMotionDiskCache.version, sampleFileSize: 500, result: nil, handPath: nil)
        WorkoutMotionDiskCache.save(entry, to: url)
        let loaded = WorkoutMotionDiskCache.load(from: url, sampleFileSize: 500)
        XCTAssertNotNil(loaded, "a cached negative result must still be a cache hit")
        XCTAssertNil(loaded?.result)
        XCTAssertNil(loaded?.handPath)
    }

    /// A mismatched sample file size — the CloudKit-re-download-survival mechanism this whole
    /// cache is keyed on — must miss, exactly the way a real edited/re-trimmed recording should.
    func testLoadMissesOnSampleFileSizeMismatch() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = WorkoutMotionCacheEntry(version: WorkoutMotionDiskCache.version, sampleFileSize: 1_000, result: nil, handPath: nil)
        WorkoutMotionDiskCache.save(entry, to: url)
        XCTAssertNil(WorkoutMotionDiskCache.load(from: url, sampleFileSize: 1_001))
    }

    /// A future cache format (a newer build wrote it, this build's `version` is older) must miss
    /// cleanly rather than decode into a wrong or partially-populated entry.
    func testLoadMissesOnVersionMismatch() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let futureEntry = WorkoutMotionCacheEntry(version: WorkoutMotionDiskCache.version + 1, sampleFileSize: 1_000, result: nil, handPath: nil)
        WorkoutMotionDiskCache.save(futureEntry, to: url)
        XCTAssertNil(WorkoutMotionDiskCache.load(from: url, sampleFileSize: 1_000))
    }

    /// No file at all — the ordinary first-open case — must miss silently, not throw or crash.
    func testLoadMissesWhenFileAbsent() {
        let url = tempURL("absent")
        XCTAssertNil(WorkoutMotionDiskCache.load(from: url, sampleFileSize: 1_000))
    }

    /// Garbage bytes at the URL (a torn write, a foreign file) must miss cleanly — this cache is
    /// regenerable derived data, so a decode failure is just another kind of miss, never a crash.
    func testLoadMissesOnCorruptFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(WorkoutMotionDiskCache.load(from: url, sampleFileSize: 1_000))
    }
}
