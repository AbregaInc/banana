import XCTest

/// Security audit run-1 (26 Oct 2026): a feed's episode ids are the keys of the shared per-episode
/// stores, so a second show cannot bring an id another show already holds.
final class EpisodeOwnershipTests: XCTestCase {
    private func show(_ feed: String, ids: [String]) -> Podcast {
        var podcast = Podcast(feedURL: URL(string: feed)!, title: feed)
        podcast.episodes = ids.map { Episode(id: $0, title: $0, audioURL: URL(string: "https://cdn.example/\($0).mp3")!) }
        return podcast
    }

    func testAnotherShowsIdsAreLeftOut() {
        let others = [show("https://a.example/feed", ids: ["shared-guid", "a-2"]), show("https://b.example/feed", ids: ["b-1"])]
        let incoming = show("https://c.example/feed", ids: ["shared-guid", "c-2", "b-1", "c-4"]).episodes
        let owned = EpisodeOwnership.unclaimed(incoming, feedURL: URL(string: "https://c.example/feed")!, among: others)
        XCTAssertEqual(owned.kept.map(\.id), ["c-2", "c-4"])
        XCTAssertEqual(owned.dropped, 2)
    }

    func testAShowKeepsItsOwnIdsOnRefresh() {
        let mine = show("https://a.example/feed", ids: ["a-1", "a-2"])
        let others = [mine, show("https://b.example/feed", ids: ["b-1"])]
        let refreshed = show("https://a.example/feed", ids: ["a-1", "a-2", "a-3"]).episodes
        let owned = EpisodeOwnership.unclaimed(refreshed, feedURL: mine.feedURL, among: others)
        XCTAssertEqual(owned.kept.map(\.id), ["a-1", "a-2", "a-3"])
        XCTAssertEqual(owned.dropped, 0)
    }

    func testAnIdHeldOnlyInAnotherShowsProgressIsStillTheirs() {
        var a = show("https://a.example/feed", ids: ["a-1"])
        a.positions["aged-out"] = 120
        a.completed.insert("finished-long-ago")
        let incoming = show("https://c.example/feed", ids: ["aged-out", "finished-long-ago", "c-1"]).episodes
        let owned = EpisodeOwnership.unclaimed(incoming, feedURL: URL(string: "https://c.example/feed")!, among: [a])
        XCTAssertEqual(owned.kept.map(\.id), ["c-1"])
        XCTAssertEqual(owned.dropped, 2)
    }

    func testNoOtherShowsMeansNothingIsDropped() {
        let incoming = show("https://a.example/feed", ids: ["a-1"]).episodes
        let owned = EpisodeOwnership.unclaimed(incoming, feedURL: URL(string: "https://a.example/feed")!, among: [])
        XCTAssertEqual(owned.kept.count, 1)
        XCTAssertEqual(owned.dropped, 0)
    }
}
