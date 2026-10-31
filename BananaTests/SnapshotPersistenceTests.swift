import XCTest

/// Covers the generic decode-and-quarantine loader (`Shared/SnapshotPersistence.swift`) against
/// the two highest-value stores in the data-safety sweep — `ListenHistoryStore` (unbounded,
/// GPS-tagged listen history) and `PodcastLibrary` (subscriptions + the catalog that
/// `saveProgress()` derives from). Both stores themselves pull in `CloudBackup`'s CloudKit/
/// `FitnessStore`/`ImageCache`/`TranscriptStore` dependency chain via their own `save()` methods,
/// which would touch the owner's real Application Support directory on first singleton touch —
/// so these exercise the pure model types (`ListenEvent.swift`, `Podcast.swift`) and the shared
/// `SnapshotLoader`/`LossyArray` directly, entirely against throwaway temp files. Never touches
/// the real `listen_history.json` or `podcasts.json`.
final class SnapshotPersistenceTests: XCTestCase {
    private func makeTempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - ListenHistoryStore (listen_history.json)

    func testListenHistory_oneCorruptEventAmongSeveralLoadsTheGoodOnesAndReportsDroppedCount() throws {
        let dir = try makeTempDirectory("ListenHistory")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("listen_history.json")
        // The middle event's "lat" is a string where a Double is expected — a type mismatch
        // (key present, wrong shape), which fails exactly like a corrupted on-disk value would,
        // as opposed to a missing key (which every field here already tolerates).
        let json = """
        [
            {"id":"11111111-1111-1111-1111-111111111111","podcastTitle":"Acquired"},
            {"id":"22222222-2222-2222-2222-222222222222","podcastTitle":"Corrupt","lat":"oops"},
            {"id":"33333333-3333-3333-3333-333333333333","podcastTitle":"Complex Systems"}
        ]
        """
        try Data(json.utf8).write(to: url)

        guard case let .loaded(lossy) = SnapshotLoader.load(from: url, as: LossyArray<ListenEvent>.self) else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(lossy.elements.map(\.podcastTitle).sorted(), ["Acquired", "Complex Systems"])
        XCTAssertEqual(lossy.droppedCount, 1)
    }

    func testListenHistory_completelyUnparseableFileIsQuarantinedAndLeftIntact() throws {
        let dir = try makeTempDirectory("ListenHistory")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("listen_history.json")
        let garbage = Data("definitely not { valid json [".utf8)
        try garbage.write(to: url)

        let result = SnapshotLoader.load(from: url, as: LossyArray<ListenEvent>.self)
        guard case let .corrupt(_, quarantinedTo) = result else {
            return XCTFail("expected .corrupt, got \(result)")
        }
        let quarantineURL = try XCTUnwrap(quarantinedTo, "a writable temp dir must produce a quarantine copy")
        XCTAssertNotEqual(quarantineURL, url)
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the original file must be left untouched")
        XCTAssertEqual(try Data(contentsOf: quarantineURL), garbage, "the quarantine copy must match byte-for-byte")
    }

    func testListenHistory_eventMissingANewlyAddedKeyStillLoads() throws {
        // Only "id" present — every other field, including routePointCount (added after the
        // route-sidecar migration, per its doc comment), absent entirely, as a listen recorded
        // before those fields existed would be.
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111"}]
        """
        let lossy = try JSONDecoder().decode(LossyArray<ListenEvent>.self, from: Data(json.utf8))

        XCTAssertEqual(lossy.elements.count, 1)
        XCTAssertEqual(lossy.droppedCount, 0)
        XCTAssertEqual(lossy.elements.first?.routePointCount, 0)
        XCTAssertEqual(lossy.elements.first?.podcastTitle, "")
    }

    func testListenHistory_missingFileIsEmptyNotAnError() throws {
        let dir = try makeTempDirectory("ListenHistory")
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = SnapshotLoader.load(from: dir.appendingPathComponent("listen_history.json"),
                                          as: LossyArray<ListenEvent>.self)
        guard case .empty = result else {
            return XCTFail("expected .empty for a brand-new install, got \(result)")
        }
    }

    // MARK: - PodcastLibrary (podcasts.json)

    func testPodcastLibrary_oneCorruptPodcastAmongSeveralLoadsTheGoodOnesAndReportsDroppedCount() throws {
        let dir = try makeTempDirectory("PodcastLibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("podcasts.json")
        // "feedURL" is Podcast's one required field (see its init(from:) doc comment in
        // Podcast.swift) — a podcast missing it looks exactly like a corrupt record.
        let json = """
        [
            {"id":"11111111-1111-1111-1111-111111111111","feedURL":"https://example.com/a.xml","title":"Acquired"},
            {"id":"22222222-2222-2222-2222-222222222222","title":"Corrupt, no feed URL"},
            {"id":"33333333-3333-3333-3333-333333333333","feedURL":"https://example.com/c.xml","title":"Complex Systems"}
        ]
        """
        try Data(json.utf8).write(to: url)

        guard case let .loaded(lossy) = SnapshotLoader.load(from: url, as: LossyArray<Podcast>.self) else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(lossy.elements.map(\.title).sorted(), ["Acquired", "Complex Systems"])
        XCTAssertEqual(lossy.droppedCount, 1)
    }

    func testPodcastLibrary_completelyUnparseableFileIsQuarantinedAndLeftIntact() throws {
        let dir = try makeTempDirectory("PodcastLibrary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("podcasts.json")
        let garbage = Data("{not valid json at all".utf8)
        try garbage.write(to: url)

        let result = SnapshotLoader.load(from: url, as: LossyArray<Podcast>.self)
        guard case let .corrupt(_, quarantinedTo) = result else {
            return XCTFail("expected .corrupt, got \(result)")
        }
        let quarantineURL = try XCTUnwrap(quarantinedTo, "a writable temp dir must produce a quarantine copy")
        XCTAssertNotEqual(quarantineURL, url)
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the original file must be left untouched")
        XCTAssertEqual(try Data(contentsOf: quarantineURL), garbage, "the quarantine copy must match byte-for-byte")
    }

    func testPodcastLibrary_podcastMissingANewlyAddedKeyStillLoads() throws {
        // watchAudioQuality ("nil = use the global default", per its doc comment) added after
        // initial release; a podcast subscribed to before it existed has no such key at all —
        // same for every other field besides the three below.
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","feedURL":"https://example.com/a.xml","title":"Acquired"}]
        """
        let lossy = try JSONDecoder().decode(LossyArray<Podcast>.self, from: Data(json.utf8))

        XCTAssertEqual(lossy.elements.count, 1)
        XCTAssertEqual(lossy.droppedCount, 0)
        XCTAssertNil(lossy.elements.first?.watchAudioQuality)
        XCTAssertEqual(lossy.elements.first?.direction, .newestFirst)
        XCTAssertEqual(lossy.elements.first?.episodes, [])
    }

    func testPodcastLibrary_missingFileIsEmptyNotAnError() throws {
        let dir = try makeTempDirectory("PodcastLibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = SnapshotLoader.load(from: dir.appendingPathComponent("podcasts.json"),
                                          as: LossyArray<Podcast>.self)
        guard case .empty = result else {
            return XCTFail("expected .empty for a brand-new install, got \(result)")
        }
    }
}
