import XCTest

/// Covers the data-safety fix for `FitnessStore`'s `summaries.json` — the workout index sitting
/// on top of years of the owner's recorded workouts. Exercises the pure model types
/// (`FitnessIndexSnapshot`/`FitnessIndexLoader`/`FitnessSessionSummary`, all in
/// `Shared/FitnessModels.swift`) and the shared `SnapshotLoader`/`LossyArray` directly, entirely
/// against throwaway temp files — never `FitnessStore` itself, which would pull in
/// `CloudFitnessSync`/`CloudBackup`/`AppSupport`'s real Application Support directory on first
/// singleton touch (see `SnapshotPersistenceTests`'s doc comment for the same reasoning applied to
/// `ListenHistoryStore`/`PodcastLibrary`). Never touches the real `summaries.json`.
final class FitnessIndexPersistenceTests: XCTestCase {
    private func makeTempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Fixture helpers

    private func makeSession(id: UUID = UUID(), start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FitnessSession {
        var samples: [FitnessSample] = []
        for i in 0..<5 {
            let t = Double(i) * 10
            samples.append(FitnessSample(t: t, kind: .heartRate, v1: 140 + Double(i), v2: nil, v3: nil))
            samples.append(FitnessSample(t: t, kind: .location, v1: 37.0 + Double(i) * 0.01,
                                         v2: -122.0 - Double(i) * 0.01, v3: 3.0))
            samples.append(FitnessSample(t: t, kind: .distance, v1: Double(i) * 50, v2: nil, v3: nil))
        }
        return FitnessSession(id: id, start: start, end: start.addingTimeInterval(300), activity: "Running",
                              avgHeartRate: 142, totalEnergy: 300, totalDistance: 2_000, samples: samples)
    }

    private func makeSummary(id: UUID = UUID(), start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FitnessSessionSummary {
        FitnessSessionSummary(session: makeSession(id: id, start: start))
    }

    /// Round-trips a summary through the real encoder so date/UUID fields land in their actual
    /// on-disk shape, then hands back a mutable JSON object a test can selectively corrupt —
    /// avoids hand-guessing Foundation's default `Date` encoding (a raw `timeIntervalSinceReferenceDate`
    /// double, not an ISO string, since neither `FitnessStore` nor this test configures a custom
    /// `dateEncodingStrategy`).
    private func jsonObject(from summary: FitnessSessionSummary) throws -> [String: Any] {
        let data = try JSONEncoder().encode(summary)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Index level: FitnessIndexLoader / FitnessIndexSnapshot

    func testIndex_oneCorruptSummaryAmongSeveralLoadsTheGoodOnesAndReportsDroppedCount() throws {
        let dir = try makeTempDirectory("FitnessIndex")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("summaries.json")

        let good1 = makeSummary()
        let good2 = makeSummary()
        // `id` is FitnessSessionSummary's one hard requirement besides `start` — a non-UUID string
        // fails exactly like a corrupted on-disk value would.
        var corrupt = try jsonObject(from: makeSummary())
        corrupt["id"] = "not-a-uuid"

        let array: [Any] = [try jsonObject(from: good1), corrupt, try jsonObject(from: good2)]
        try data(from: array).write(to: url)

        guard case let .loaded(snapshot) = FitnessIndexLoader.load(from: url) else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(Set(snapshot.summaries.map(\.id)), Set([good1.id, good2.id]))
        XCTAssertEqual(snapshot.droppedCount, 1)
    }

    func testIndex_whollyUnparseableFileIsQuarantinedWithOriginalBytesIntact() throws {
        let dir = try makeTempDirectory("FitnessIndex")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("summaries.json")
        let garbage = Data("definitely not valid json [{".utf8)
        try garbage.write(to: url)

        let result = FitnessIndexLoader.load(from: url)
        guard case let .corrupt(_, quarantinedTo) = result else {
            return XCTFail("expected .corrupt, got \(result)")
        }
        let quarantineURL = try XCTUnwrap(quarantinedTo, "a writable temp dir must produce a quarantine copy")
        XCTAssertNotEqual(quarantineURL, url)
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the original summaries.json must be left untouched")
        XCTAssertEqual(try Data(contentsOf: quarantineURL), garbage, "the quarantine copy must match byte-for-byte")
    }

    func testIndex_missingFileIsEmptyNotAnError() throws {
        let dir = try makeTempDirectory("FitnessIndex")
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = FitnessIndexLoader.load(from: dir.appendingPathComponent("summaries.json"))
        guard case .empty = result else {
            return XCTFail("expected .empty for a brand-new install, got \(result)")
        }
    }

    // MARK: - Summary level: FitnessSessionSummary.init(from:)

    func testSummary_missingNewlyAddedKeysStillLoads() throws {
        // Only the two required fields present — every other key, including series added this
        // session (speedSeries, derivedCadenceSeries, …), absent entirely, as a summary saved
        // before those fields existed would be.
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","start":0}"#
        let decoded = try JSONDecoder().decode(FitnessSessionSummary.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.start, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(decoded.activity, "Workout")
        XCTAssertEqual(decoded.sampleCount, 0)
        XCTAssertEqual(decoded.signalCounts, [:])
        XCTAssertEqual(decoded.route, [])
        XCTAssertEqual(decoded.speedSeries, [])
        XCTAssertEqual(decoded.derivedCadenceSeries, [])
        XCTAssertEqual(decoded.laps, [])
        XCTAssertNil(decoded.insights)
        XCTAssertNil(decoded.outdoorConditions)
        XCTAssertNil(decoded.end)
    }

    /// `id` is the identity `FitnessStore` uses to find this session's raw `<id>.samples` file — a
    /// summary that can't produce one must be dropped (by the enclosing `LossyArray`), never kept
    /// under a fabricated fresh id that would silently orphan the real file forever.
    func testSummary_missingRequiredIDFailsToDecode() {
        let json = #"{"start":0}"#
        XCTAssertThrowsError(try JSONDecoder().decode(FitnessSessionSummary.self, from: Data(json.utf8)))
    }

    /// `start` is the workout's place in every chronological list and chart — defaulting it (the
    /// old behavior defaulted to `.distantPast`) would misplace a real workout at the dawn of time
    /// rather than dropping the unreadable record.
    func testSummary_missingRequiredStartFailsToDecode() {
        let json = #"{"id":"\#(UUID().uuidString)"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(FitnessSessionSummary.self, from: Data(json.utf8)))
    }

    /// A round trip of a realistic summary — populated `route`/`heartRateSeries`/`speedSeries`/
    /// `insights`/etc. from `FitnessSessionSummary(session:)`, the same path `FitnessStore.install`
    /// uses — must be byte-for-byte unchanged, not just individually-tolerant of missing keys.
    func testSummary_roundTripOfARealisticSummaryIsUnchanged() throws {
        let original = makeSummary()
        XCTAssertFalse(original.route.isEmpty)
        XCTAssertFalse(original.heartRateSeries.isEmpty)
        XCTAssertNotNil(original.insights)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FitnessSessionSummary.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    /// One malformed point inside a downsampled series (here `route`, missing `lon`) costs that
    /// one point, not the whole summary — and, at the index level, not the whole workout's
    /// multi-megabyte `.samples` companion file's only reference. Before wrapping these series in
    /// `LossyArray`, this exact JSON would have failed `FitnessSessionSummary.init(from:)`
    /// entirely.
    func testSummary_corruptPointWithinNestedSeriesIsDroppedNotFatal() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "start": 0,
            "route": [
                {"lat": 37.0, "lon": -122.0},
                {"lat": 37.1},
                {"lat": 37.2, "lon": -122.2}
            ]
        }
        """
        let decoded = try JSONDecoder().decode(FitnessSessionSummary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.route.map(\.lat), [37.0, 37.2])
    }

    /// A malformed VALUE at a present key (as opposed to an absent key, which plain
    /// `decodeIfPresent` already tolerates) must also not sink the whole summary —
    /// `FailableDecodable` is what closes that gap for single-value optional fields like
    /// `insights`/`outdoorConditions`.
    func testSummary_malformedInsightsValueIsDroppedNotFatal() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","start":0,"insights":"not an object"}"#
        let decoded = try JSONDecoder().decode(FitnessSessionSummary.self, from: Data(json.utf8))
        XCTAssertNil(decoded.insights)
    }

    // MARK: - Plausibility guard: FitnessSessionSummary.hasPlausibleStart
    //
    // Covers the second hole in the CloudFitnessSync routing-guard fix: a record named
    // `workout-<uuid>` whose payload decodes cleanly (a syntactically valid `Date`) but whose
    // `start` is `.distantPast` — the sentinel value a corrupt/misrouted payload falls back to.
    // `CloudFitnessSync.apply` isn't reachable from this test target (see this file's own doc
    // comment), so these tests exercise the shared, pure rule the cloud-adopt path calls
    // (`hasPlausibleStart`) directly, plus its enforcement at the local-disk load path
    // (`FitnessIndexSnapshot`/`FitnessIndexLoader`), which IS reachable here.

    func testPlausibility_distantPastStartIsNotPlausible() {
        var summary = makeSummary()
        summary.start = .distantPast
        XCTAssertFalse(summary.hasPlausibleStart)
    }

    /// A real, old-but-genuine workout — e.g. one HealthKit backfill imports from years before
    /// this app existed — must not be caught by the same guard that rejects the sentinel. The
    /// floor sits years before this fixture's date, comfortably below any real workout, but the
    /// rejection is on `start` alone, so age by itself is never disqualifying.
    func testPlausibility_legitimatelyOldStartIsPlausible() {
        var summary = makeSummary()
        summary.start = Date(timeIntervalSince1970: 1_420_070_400)   // 2015-01-01 UTC
        XCTAssertTrue(summary.hasPlausibleStart)
    }

    /// Zero samples and empty series must not, by themselves, make an otherwise-plausible record
    /// look corrupt — see `hasPlausibleStart`'s doc comment for why a real but sparse record (a
    /// manual Health app entry, a summary-only third-party import) can legitimately look like
    /// this. The guard is `start`-only, so a recent-but-empty record stays plausible.
    func testPlausibility_emptyButPlausibleRecordIsNotRejected() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","start":1700000000}"#
        let summary = try JSONDecoder().decode(FitnessSessionSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.sampleCount, 0)
        XCTAssertTrue(summary.route.isEmpty)
        XCTAssertTrue(summary.heartRateSeries.isEmpty)
        XCTAssertTrue(summary.hasPlausibleStart)
    }

    func testPlausibility_exactlyAtTheFloorIsPlausible() {
        var summary = makeSummary()
        summary.start = FitnessSessionSummary.earliestPlausibleStart
        XCTAssertTrue(summary.hasPlausibleStart)
    }

    /// The index-load half of the guard: a distant-past summary reaching `summaries.json` (e.g.
    /// adopted by a build that predates this fix, or restored from an old backup) must not
    /// repopulate the in-memory index, and must be reported separately from a genuine decode
    /// failure so a caller can log it with its id.
    func testIndex_distantPastSummaryIsRejectedAndReportedSeparatelyFromDecodeFailures() throws {
        let dir = try makeTempDirectory("FitnessIndex")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("summaries.json")

        let good = makeSummary()
        var phantom = makeSummary()
        phantom.start = .distantPast

        let array: [Any] = [try jsonObject(from: good), try jsonObject(from: phantom)]
        try data(from: array).write(to: url)

        guard case let .loaded(snapshot) = FitnessIndexLoader.load(from: url) else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(snapshot.summaries.map(\.id), [good.id])
        XCTAssertEqual(snapshot.droppedCount, 0, "the phantom decoded fine — it must not be counted as a decode failure")
        XCTAssertEqual(snapshot.rejectedImplausibleIDs, [phantom.id])
    }

    /// A legitimately old-but-plausible summary on disk must load normally — the guard must never
    /// cost a real workout its place in the index.
    func testIndex_legitimatelyOldSummaryOnDiskLoadsNormally() throws {
        let dir = try makeTempDirectory("FitnessIndex")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("summaries.json")

        var old = makeSummary()
        old.start = Date(timeIntervalSince1970: 1_420_070_400)   // 2015-01-01 UTC
        let array: [Any] = [try jsonObject(from: old)]
        try data(from: array).write(to: url)

        guard case let .loaded(snapshot) = FitnessIndexLoader.load(from: url) else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(snapshot.summaries.map(\.id), [old.id])
        XCTAssertEqual(snapshot.rejectedImplausibleIDs, [])
    }
}
