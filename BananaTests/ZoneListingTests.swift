import XCTest

/// The zone listing the move's drain and a big zone's first poll use (`ResumableZoneListing`),
/// against a fake zone: interrupted, it picks up where it stopped; only a finished listing comes
/// back; one begun more than a day ago starts over.
@MainActor
final class ZoneListingTests: XCTestCase {
    /// A zone of pages: page i's token is "i+1"; the last page says no more.
    private final class FakeZone {
        var pages: [ZoneListingPage] = []
        /// The tokens each fetch started from (nil: the start).
        private(set) var asked: [String?] = []

        func fetch(_ token: Data?) async throws -> ZoneListingPage {
            let from = token.map { String(decoding: $0, as: UTF8.self) }
            asked.append(from)
            let index = from.flatMap(Int.init) ?? 0
            var page = index < pages.count ? pages[index] : ZoneListingPage()
            page.token = Data(String(min(index + 1, pages.count)).utf8)
            page.moreComing = index + 1 < pages.count
            return page
        }
    }

    private var file: URL!
    private var now = Date()

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("zone-listing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("zonePoll.fitness.json")
        now = Date()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func listing() -> ResumableZoneListing {
        ResumableZoneListing(file: file, now: { [unowned self] in self.now })
    }

    private func zone(_ pages: [[String]]) -> FakeZone {
        let zone = FakeZone()
        zone.pages = pages.map { ZoneListingPage(listed: $0) }
        return zone
    }

    func testAnInterruptedListingResumesWhereItStoppedAndCompletes() async throws {
        let zone = zone([["a", "b"], ["c"], ["d"], ["e"]])
        do {
            // Background time runs out after three pages.
            _ = try await listing().run(fetch: zone.fetch, stop: { zone.asked.count == 3 })
            XCTFail("a partial listing is never returned")
        } catch ZoneListingError.interrupted {
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(listing().saved?.names, ["a", "b", "c", "d"], "what was read is kept")
        XCTAssertEqual(listing().saved?.complete, false)

        // The next step, after a relaunch: from the last page, not from the start.
        let done = try await listing().run(fetch: zone.fetch, stop: { false })
        XCTAssertEqual(done.names, ["a", "b", "c", "d", "e"])
        XCTAssertTrue(done.complete)
        XCTAssertEqual(zone.asked, [nil, "1", "2", "3"], "each page read once: the next run starts at the last")
    }

    func testDeletesOnLaterPagesTakeNamesOutAgain() async throws {
        let zone = FakeZone()
        zone.pages = [ZoneListingPage(listed: ["a", "b"], stale: ["b"]),
                      ZoneListingPage(listed: ["c"], deleted: ["b"])]
        let done = try await listing().run(fetch: zone.fetch, stop: { false })
        XCTAssertEqual(done.names, ["a", "c"])
        XCTAssertEqual(done.stale, [], "a deleted record isn't owed either")
    }

    func testAListingBegunMoreThanADayAgoStartsOver() async throws {
        let zone = zone([["a"], ["b"], ["c"]])
        var pages = 0
        _ = try? await listing().run(fetch: { pages += 1; return try await zone.fetch($0) }, stop: { pages == 1 })
        XCTAssertEqual(listing().saved?.names, ["a"])

        now = now.addingTimeInterval(25 * 3_600)
        zone.pages = [ZoneListingPage(listed: ["x"]), ZoneListingPage(listed: ["y"])]   // the zone moved on
        let done = try await listing().run(fetch: zone.fetch, stop: { false })
        XCTAssertEqual(done.names, ["x", "y"], "nothing of the old listing is kept")
        XCTAssertEqual(zone.asked.dropFirst(), [nil, "1"], "listed from the start again")
        XCTAssertEqual(try XCTUnwrap(listing().saved?.startedAt).timeIntervalSince(now), 0, accuracy: 0.001)
    }

    func testAFinishedListingOnlyCatchesUpWhatChanged() async throws {
        let zone = zone([["a"], ["b"]])
        _ = try await listing().run(fetch: zone.fetch, stop: { false })
        // The second fitness channel drains the same zone: one page from where the first stopped.
        zone.pages.append(ZoneListingPage(listed: ["c"], deleted: ["a"]))
        let again = try await listing().run(fetch: zone.fetch, stop: { false })
        XCTAssertEqual(again.names, ["b", "c"])
        XCTAssertEqual(zone.asked, [nil, "1", "2"])
    }

    func testNoZoneKeepsNothing() async throws {
        let listing = listing()
        do {
            _ = try await listing.run(fetch: { _ in ZoneListingPage(token: nil) }, stop: { false })
            XCTFail("no zone, nothing can be said")
        } catch ZoneListingError.noZone {}
        XCTAssertNil(listing.saved)
    }

    func testAPageThatDoesNotMoveOnStopsWithoutLosingWhatWasRead() async throws {
        let zone = zone([["a"], ["b"]])
        var stuck = false
        let fetch: (Data?) async throws -> ZoneListingPage = { token in
            var page = try await zone.fetch(token)
            if stuck { page.token = token; page.moreComing = true }
            stuck = true
            return page
        }
        do {
            _ = try await listing().run(fetch: fetch, stop: { false })
            XCTFail("a stalled listing isn't returned")
        } catch ZoneListingError.stalled {}
        XCTAssertEqual(listing().saved?.names, ["a"])
    }

    func testStaleRecordsFetchedAreNoLongerOwed() async throws {
        let zone = FakeZone()
        zone.pages = [ZoneListingPage(listed: ["a", "b", "c"], stale: ["a", "c"])]
        let listing = listing()
        let done = try await listing.run(fetch: zone.fetch, stop: { false })
        XCTAssertEqual(done.stale, ["a", "c"])
        listing.fetched(["a"])
        XCTAssertEqual(listing.saved?.stale, ["c"], "an interrupted bootstrap fetches only what's left")
        XCTAssertEqual(listing.saved?.names, ["a", "b", "c"])
    }
}
