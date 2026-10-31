import XCTest

/// Playback speed across devices (`PlaybackSpeeds`): the list, what the Watch can play, and when
/// an ad's start comes at a faster speed.
final class PlaybackSpeedsTests: XCTestCase {
    func testTheWatchOffersTheSpeedsItCanPlay() {
        XCTAssertEqual(PlaybackSpeeds.watchOptions, [0.8, 1.0, 1.25, 1.5, 1.75, 2.0])
        XCTAssertEqual(PlaybackSpeeds.onWatch(3.0), 2.0, "a show set to 3× on the phone plays at 2× on the Watch")
        XCTAssertEqual(PlaybackSpeeds.onWatch(1.25), 1.25)
        XCTAssertEqual(PlaybackSpeeds.onWatch(0.25), 0.5)
    }

    func testATapGoesToTheNextSpeedAndRound() {
        XCTAssertEqual(PlaybackSpeeds.next(after: 1.0), 1.25)
        XCTAssertEqual(PlaybackSpeeds.next(after: 3.0), 0.8)
        XCTAssertEqual(PlaybackSpeeds.next(after: 2.0, in: PlaybackSpeeds.watchOptions), 0.8)
        XCTAssertEqual(PlaybackSpeeds.next(after: 1.1), 1.25, "a speed that isn't in the list")
    }

    func testLabels() {
        XCTAssertEqual(PlaybackSpeeds.label(1), "1\u{00D7}")
        XCTAssertEqual(PlaybackSpeeds.label(1.5), "1.5\u{00D7}")
        XCTAssertEqual(PlaybackSpeeds.label(1.25), "1.25\u{00D7}")
        XCTAssertEqual(PlaybackSpeeds.label(0.8), "0.8\u{00D7}")
    }

    func testAnAdsStartComesSoonerAtAFasterSpeed() {
        // Thirty seconds of audio away: 30 s by the clock at 1×, 20 s at 1.5×. The Watch timed
        // its ad skips as if it always played at 1×.
        XCTAssertEqual(PlaybackSpeeds.wallClock(from: 100, to: 130, rate: 1), 30)
        XCTAssertEqual(PlaybackSpeeds.wallClock(from: 100, to: 130, rate: 1.5), 20)
        XCTAssertNil(PlaybackSpeeds.wallClock(from: 130, to: 130, rate: 1))
        XCTAssertNil(PlaybackSpeeds.wallClock(from: 100, to: 130, rate: 0))
    }

    func testOnlyShowsOffOneTimesAreSentToTheWatch() {
        XCTAssertEqual(PlaybackSpeeds.nonDefault([("Acquired", 1.5), ("The Daily", 1.0), ("", 2.0), ("Hard Fork", 1.25)]),
                       ["Acquired": 1.5, "Hard Fork": 1.25])
    }
}
