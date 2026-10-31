import XCTest

final class PodcastCatalogTests: XCTestCase {
    private func fixture(_ count: Int = 1_003) -> Podcast {
        Podcast(feedURL: URL(string: "https://example.invalid/feed")!, title: "Paged", episodes: (0..<count).map { i in
            Episode(id: "e\(i)", title: "Episode \(i)", audioURL: URL(string: "https://example.invalid/\(i)")!,
                    pubDate: i % 19 == 0 ? nil : Date(timeIntervalSince1970: Double((i * 7919) % 91)),
                    summary: String(repeating: "Metadata ", count: 50))
        })
    }
    private func paths() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PodcastCatalogTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory.appendingPathComponent("catalog.sqlite"), directory.appendingPathComponent("podcasts.json"))
    }

    func testMigrationPagesPlaybackOrderAndPortableBackup() throws {
        let (url, legacy) = try paths()
        let original = fixture()
        let data = try JSONEncoder().encode([original])
        try data.write(to: legacy)
        let store = try PodcastCatalog.open(at: url)
        var loaded = try XCTUnwrap(store.load(legacyURL: legacy).first)
        XCTAssertNotNil(loaded.episodeSnapshot)
        XCTAssertEqual(loaded.episodeCount, original.episodes.count)
        XCTAssertEqual(try Data(contentsOf: legacy), data, "Migration preserves the original")
        for direction in PlayDirection.allCases {
            loaded.direction = direction
            var expected = original; expected.direction = direction
            for offset in [0, 100, 1_000, 1_003] {
                XCTAssertEqual(try loaded.episodePage(offset: offset).map(\.id),
                               Array(expected.ordered().dropFirst(offset).prefix(100)).map(\.id))
            }
            loaded.completed = ["e1", "e2", "e3"]
            expected.completed = loaded.completed
            XCTAssertEqual(loaded.nextUnplayed(3), expected.nextUnplayed(3))
            XCTAssertEqual(loaded.nextEpisode(), expected.nextEpisode())
        }
        XCTAssertEqual(loaded.episode("e501"), original.episodes[501])
        XCTAssertNil(loaded.episode("missing"))
        let restored = try JSONDecoder().decode([Podcast].self, from: store.backupJSON(legacyURL: legacy))
        XCTAssertEqual(restored.first?.episodes, original.episodes)
    }

    func testRefreshKeepsOldSnapshotReadableAndSettingsDoNotRewriteEpisodes() throws {
        let (url, legacy) = try paths()
        let store = try PodcastCatalog.open(at: url)
        _ = try store.load(legacyURL: legacy)
        let original = fixture(20)
        var saved = try XCTUnwrap(store.save([original]).first)
        let revision = saved.episodeRevision
        saved.speed = 1.5
        saved = try XCTUnwrap(store.save([saved]).first)
        XCTAssertEqual(saved.episodeRevision, revision)
        var refreshed = saved
        refreshed.episodes = Array(original.episodes.prefix(3))
        let fresh = try XCTUnwrap(store.save([refreshed]).first)
        try store.reclaimRetiredSnapshots()
        XCTAssertEqual(try saved.episodeSnapshot?.all(), original.episodes)
        XCTAssertEqual(fresh.episodeCount, 3)
        XCTAssertEqual(try store.load(legacyURL: legacy).first?.episodeCount, 3)
    }

    func testFailedCommitAndCorruptRestorePreserveWorkingCatalog() throws {
        let (url, legacy) = try paths()
        let store = try PodcastCatalog.open(at: url)
        _ = try store.load(legacyURL: legacy)
        let saved = try XCTUnwrap(store.save([fixture(12)]).first)
        XCTAssertThrowsError(try store.save([saved, saved]))
        XCTAssertEqual(try store.load(legacyURL: legacy).first?.episodeCount, 12)
        let corrupt = Data("[{broken]".utf8)
        try corrupt.write(to: legacy)
        XCTAssertThrowsError(try store.load(legacyURL: legacy, forceImport: true))
        XCTAssertEqual(try Data(contentsOf: legacy), corrupt)
        XCTAssertEqual(try saved.episodeSnapshot?.all().count, 12)
    }
}
