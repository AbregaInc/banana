import XCTest

/// A show can opt out of ad skipping on its own, the way it can already set its own opening skip.
///
/// Distinct from the automatic retirement in `SkipCorrectionBook`: that decides a DETECTOR got it
/// wrong on this show. This is the listener saying "leave this show alone", which no amount of
/// measurement can infer — a show whose ads you actually want to hear is not a detector failure.
final class PerShowAdSkipTests: XCTestCase {

    private func show(_ choice: Bool?) -> Podcast {
        var podcast = Podcast(feedURL: URL(string: "https://example.com/feed")!, title: "Test")
        podcast.skipsAdsAutomatically = choice
        return podcast
    }

    func testAShowWithNoChoiceFollowsTheGlobalSetting() {
        XCTAssertTrue(show(nil).skipsAds(defaultingTo: true))
        XCTAssertFalse(show(nil).skipsAds(defaultingTo: false))
    }

    /// The case the feature exists for: one show you want left alone, everything else still skipped.
    func testAShowTurnedOffStaysOffWithTheMasterSwitchOn() {
        XCTAssertFalse(show(false).skipsAds(defaultingTo: true))
    }

    /// And the reverse: a show explicitly turned on keeps skipping even when the global switch is
    /// off, so "on for this one show" is expressible.
    func testAShowTurnedOnStaysOnWithTheMasterSwitchOff() {
        XCTAssertTrue(show(true).skipsAds(defaultingTo: false))
    }

    /// Catalogues saved before this existed have no key, which is exactly "follow the global
    /// setting" — so the absent key needs no migration.
    func testACatalogueSavedBeforeThisFeatureDecodesAsFollowingTheDefault() throws {
        let json = """
        {"id":"\(UUID().uuidString)","feedURL":"https://example.com/feed","title":"Old","episodes":[]}
        """
        let decoded = try JSONDecoder().decode(Podcast.self, from: Data(json.utf8))
        XCTAssertNil(decoded.skipsAdsAutomatically)
        XCTAssertTrue(decoded.skipsAds(defaultingTo: true))
        XCTAssertFalse(decoded.skipsAds(defaultingTo: false))
    }

    func testTheChoiceSurvivesARoundTrip() throws {
        for choice in [nil, true, false] as [Bool?] {
            let data = try JSONEncoder().encode(show(choice))
            let back = try JSONDecoder().decode(Podcast.self, from: data)
            XCTAssertEqual(back.skipsAdsAutomatically, choice)
        }
    }
}
