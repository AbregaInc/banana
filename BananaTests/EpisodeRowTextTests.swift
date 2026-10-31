import XCTest

/// What an episode row says about when it came out and how much is left.
final class EpisodeRowTextTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 18))!

    private func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: now)! }

    func testRecentEpisodesReadAsDaysNotDates() {
        XCTAssertEqual(EpisodeRowText.dateLine(daysAgo(0), now: now, calendar: calendar, locale: locale), "Today")
        XCTAssertEqual(EpisodeRowText.dateLine(daysAgo(1), now: now, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(EpisodeRowText.dateLine(daysAgo(3), now: now, calendar: calendar, locale: locale), "Thursday")
        XCTAssertEqual(EpisodeRowText.dateLine(daysAgo(20), now: now, calendar: calendar, locale: locale), "Sep 7")
        XCTAssertEqual(EpisodeRowText.dateLine(daysAgo(400), now: now, calendar: calendar, locale: locale), "Aug 23, 2025")
    }

    func testTheCapsuleSaysWhatIsLeft() {
        XCTAssertEqual(EpisodeRowText.capsule(duration: 3_600, progress: 0.5, completed: false), "30m left")
        XCTAssertEqual(EpisodeRowText.capsule(duration: 3_900, progress: nil, completed: false), "1h 5m")
        XCTAssertEqual(EpisodeRowText.capsule(duration: 3_600, progress: 0.995, completed: true), "Played")
        XCTAssertNil(EpisodeRowText.capsule(duration: nil, progress: 0.3, completed: false),
                     "no duration, no made-up time")
        XCTAssertEqual(EpisodeRowText.length(20), "1m", "never 0m")
    }
}
