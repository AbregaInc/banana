import XCTest

final class PodcastEpisodeBrowserTests: XCTestCase {
    func testSpeakerAndGenderFiltersHideBeforePagingWithoutMarkingPlayed() throws {
        var memory = Podcast(feedURL: URL(string: "https://example.invalid/filtered")!, title: "Filtered", direction: .oldestFirst,
                             episodes: (0..<303).map { i in
            Episode(id: "v\(i)", title: "Episode \(i)", audioURL: URL(string: "https://example.invalid/\(i)")!,
                    pubDate: Date(timeIntervalSince1970: Double(i)),
                    summary: i % 3 == 0 ? "Narrator: Muted Person" : "Narrator: Another Person")
        })
        memory.mutedNarrators = ["muted person"]
        memory.mutedVoiceGenders = [.female]
        memory.completed = ["v302"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBrowser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PodcastCatalog.open(at: root.appendingPathComponent("catalog.sqlite"))
        let disk = try store.stage(memory)
        for source in [memory, disk] {
            for all in [false, true] {
                let query = try PodcastEpisodeQuery(podcast: source, includingListened: all) { id, _ in
                    guard let number = Int(id.dropFirst()) else { return nil }
                    return number % 3 == 1 ? .female : nil
                }
                let expected = (0..<303).filter { $0 % 3 == 2 && (all || $0 != 302) }.map { "v\($0)" }
                XCTAssertEqual(query.count, expected.count)
                let values = try query.page(offset: 0, limit: 100) + query.page(offset: 100, limit: 100)
                XCTAssertEqual(values.map(\.id), expected, "both scopes entirely omit muted and classified episodes")
                XCTAssertEqual(source.completed, ["v302"], "visibility never marks an episode played")
            }
        }
        var unmuted = disk
        unmuted.mutedNarrators = []; unmuted.mutedVoiceGenders = []
        XCTAssertEqual(try PodcastEpisodeQuery(podcast: unmuted, includingListened: true).count, 303,
                       "turning a filter off restores episodes without changing history")
    }

    private func fixture(_ count: Int) throws -> (Podcast, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EpisodeBrowser-\(UUID())")
        let catalog = try PodcastCatalog.open(at: root.appendingPathComponent("catalog.sqlite"))
        var podcast = Podcast(feedURL: URL(string: "https://example.invalid/feed")!, title: "History", direction: .oldestFirst,
                              episodes: (0..<count).map { i in
            Episode(id: "e\(i)", title: "Episode \(i)", audioURL: URL(string: "https://example.invalid/\(i)")!,
                    pubDate: Date(timeIntervalSince1970: Double(i)), summary: String(repeating: "Notes ", count: 50))
        })
        podcast = try catalog.stage(podcast)
        return (podcast, root)
    }

    func testListenedPrefixDoesNotConsumeUnplayedPages() throws {
        var (podcast, root) = try fixture(1_003)
        defer { try? FileManager.default.removeItem(at: root) }
        podcast.completed = Set((0..<850).map { "e\($0)" }).union(["stale-id", "e'quoted"])
        let query = try PodcastEpisodeQuery(podcast: podcast, includingListened: false)
        XCTAssertEqual(query.count, 153)
        XCTAssertEqual(try query.page(offset: 0, limit: 100).first?.id, "e850")
        XCTAssertEqual(try query.page(offset: 100, limit: 100).map(\.id), (950..<1_003).map { "e\($0)" })
        XCTAssertTrue(try query.page(offset: 153, limit: 100).isEmpty)
        podcast.direction = .newestFirst
        let reverse = try PodcastEpisodeQuery(podcast: podcast, includingListened: false)
        XCTAssertEqual(try reverse.page(offset: 0, limit: 100).map(\.id), (903..<1_003).reversed().map { "e\($0)" })
    }

    func testListenedHistoryAndAnEntirelyPlayedFeedRemainReachable() throws {
        var (podcast, root) = try fixture(201)
        defer { try? FileManager.default.removeItem(at: root) }
        podcast.completed = Set((0..<201).map { "e\($0)" })
        XCTAssertEqual(try PodcastEpisodeQuery(podcast: podcast, includingListened: false).count, 0)
        let all = try PodcastEpisodeQuery(podcast: podcast, includingListened: true)
        XCTAssertEqual(all.count, 201)
        XCTAssertEqual(try all.page(offset: 200, limit: 100).first?.id, "e200")
        var memory = podcast
        memory.episodes = try podcast.episodeSnapshot!.all()
        XCTAssertEqual(try PodcastEpisodeQuery(podcast: memory, includingListened: true).page(offset: 100, limit: 100),
                       try all.page(offset: 100, limit: 100))
    }

    @MainActor func testContinuousScrollingEvictsAndReloadsWithoutLosingHistory() async throws {
        let (podcast, root) = try fixture(1_003)
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = PodcastEpisodeBrowser()
        await browser.configure(podcast: podcast, includingListened: false)
        XCTAssertEqual(browser.count, 1_003)
        for index in stride(from: 0, through: 1_000, by: 100) {
            await browser.reveal(index)
            XCTAssertEqual(browser.episode(at: index)?.id, "e\(index)")
            XCTAssertLessThanOrEqual(browser.retainedEpisodeCount, 500)
        }
        XCTAssertNil(browser.episode(at: 0), "earlier decoded pages have been evicted")
        await browser.reveal(0)
        XCTAssertEqual(browser.episode(at: 0)?.id, "e0", "eviction never truncates the retained feed")
        var completed = podcast; completed.completed = Set((0..<900).map { "e\($0)" })
        await browser.configure(podcast: completed, includingListened: false)
        XCTAssertEqual(browser.count, 103)
        XCTAssertEqual(browser.episode(at: 0)?.id, "e900")
        await browser.configure(podcast: completed, includingListened: true)
        XCTAssertEqual(browser.episode(at: 0)?.id, "e0")
        // Jump away and back while reads are in flight. An obsolete request must not
        // remove the replacement request or leave the returned viewport unloaded.
        let jumps = [900, 100, 800, 200, 700, 0].map { index in
            Task { await browser.reveal(index) }
        }
        for task in jumps { await task.value }
        await browser.reveal(0)
        XCTAssertEqual(browser.episode(at: 0)?.id, "e0")
        XCTAssertLessThanOrEqual(browser.retainedEpisodeCount, 500)
    }

    func testLongListenedPrefixComparisonRetainsRawComponentTimings() throws {
        var (podcast, root) = try fixture(10_000)
        defer { try? FileManager.default.removeItem(at: root) }
        podcast.completed = Set((0..<9_000).map { "e\($0)" })
        var before: [Double] = [], after: [Double] = []
        for _ in 0..<7 {
            var start = ContinuousClock.now
            var selected: [Episode] = []
            var offset = 0
            while selected.count < 100 && offset < podcast.episodeCount {
                selected += try podcast.episodePage(offset: offset).filter { !podcast.completed.contains($0.id) }
                offset += 100
            }
            let beforeDuration = start.duration(to: .now).components
            before.append(Double(beforeDuration.seconds) * 1000 + Double(beforeDuration.attoseconds) / 1e15)
            start = .now
            let query = try PodcastEpisodeQuery(podcast: podcast, includingListened: false)
            let page = try query.page(offset: 0, limit: 100)
            let afterDuration = start.duration(to: .now).components
            after.append(Double(afterDuration.seconds) * 1000 + Double(afterDuration.attoseconds) / 1e15)
            XCTAssertEqual(selected.map(\.id), page.map(\.id))
        }
        print("EPISODE_BROWSER_COMPONENT " + String(decoding: try JSONEncoder().encode(["scanPagesMS": before, "filteredQueryMS": after]), as: UTF8.self))
    }
}
