import XCTest

/// What happens to a downloaded file when its episode is finished.
///
/// The rules differ by how the file arrived, and the distinction is deliberate: a rolling window
/// moving past a manual download is not a reason to bin something you asked for, but FINISHING it
/// is — that is the one case where the file has certainly done its job, and these run to hundreds
/// of megabytes each.
final class DownloadRetentionTests: XCTestCase {

    private func show(rule: DownloadRule = .latest(3), completed: Set<String> = []) -> Podcast {
        var podcast = Podcast(feedURL: URL(string: "https://example.com/feed")!, title: "Show")
        podcast.downloadRule = rule
        podcast.completed = completed
        podcast.direction = .newestFirst
        podcast.episodes = (1...6).map { index in
            var ep = Episode(id: "ep\(index)", title: "Episode \(index)",
                             audioURL: URL(string: "https://example.com/\(index).mp3")!)
            ep.pubDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
            return ep
        }
        return podcast
    }

    /// The keep-window is the newest N UNPLAYED episodes, so finishing one drops it out and the
    /// next unplayed one takes its place.
    func testAPlayedEpisodeLeavesTheKeepWindow() {
        let podcast = show(completed: ["ep6"])
        let keep = Set(podcast.nextUnplayed(3).map(\.id))
        XCTAssertFalse(keep.contains("ep6"))
        XCTAssertEqual(keep, ["ep5", "ep4", "ep3"])
    }

    /// The case that protects a manual download the window has simply moved past: still wanted,
    /// because nothing about it says you are done with it.
    func testAnUnplayedEpisodeOutsideTheWindowIsStillUnplayed() {
        let podcast = show()
        let keep = Set(podcast.nextUnplayed(3).map(\.id))
        XCTAssertFalse(keep.contains("ep1"), "ep1 has aged out of the window")
        XCTAssertFalse(podcast.completed.contains("ep1"), "but it has not been played")
    }

    /// A show with nothing newer can legitimately still want a played episode downloaded — and
    /// deleting it would only make the next reconcile fetch it again.
    func testAPlayedEpisodeInsideTheWindowIsKept() {
        var podcast = show(rule: .latest(6), completed: ["ep6"])
        podcast.episodes = Array(podcast.episodes.prefix(6))
        let keep = Set(podcast.nextUnplayed(6).map(\.id))
        XCTAssertFalse(keep.contains("ep6"),
                       "nextUnplayed skips finished episodes even when the window has room")
    }

    func testAShowWithDownloadsOffKeepsEverything() {
        let podcast = show(rule: .off)
        XCTAssertEqual(podcast.downloadRule.count, 0,
                       "reconcile returns early, so nothing this show holds is ever pruned")
    }

    // MARK: - The regression that made opening a show take seconds

    /// `isMuted` used to rebuild the show's narrator roster for EVERY episode, and the roster runs
    /// a regex over every summary in the feed. On a real 799-episode show that measured 64 seconds
    /// against 146 ms with the roster built once — and the podcast detail view called it on open.
    func testFilteringDoesNotRebuildTheRosterPerEpisode() {
        var podcast = show()
        podcast.episodes = (1...400).map { index in
            var ep = Episode(id: "ep\(index)", title: "Episode \(index)",
                             audioURL: URL(string: "https://example.com/\(index).mp3")!)
            ep.summary = "Narrator: Thomas Jones 🇬🇧"
            ep.pubDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
            return ep
        }
        podcast.mutedNarrators = ["Thomas Jones"]
        let started = Date()
        _ = podcast.nextUnplayed(2)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.0,
                          "400 episodes took \(Int(elapsed * 1000)) ms — the roster is being rebuilt per episode again")
    }

    /// The common case — nothing muted — must not parse anything at all.
    func testNothingMutedCostsNothing() {
        var podcast = show()
        podcast.episodes = (1...400).map { index in
            var ep = Episode(id: "ep\(index)", title: "Episode \(index)",
                             audioURL: URL(string: "https://example.com/\(index).mp3")!)
            ep.summary = "Narrator: Thomas Jones 🇬🇧"
            ep.pubDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
            return ep
        }
        let started = Date()
        _ = podcast.nextUnplayed(2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }
}
