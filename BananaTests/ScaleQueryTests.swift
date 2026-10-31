import XCTest

final class ScaleQueryTests: XCTestCase {
    struct Interval { let id: Int; let start: Date; let end: Date }

    func testIntervalIndexMatchesFullScanIncludingLongAndZeroLengthEvents() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<10_000).map { i in
            let start = base.addingTimeInterval(Double((i * 7919) % 10_000))
            return Interval(id: i, start: start, end: start.addingTimeInterval(Double(i % 11 == 0 ? 20_000 : i % 100)))
        }
        let index = TimeRangeIndex(rows, start: \.start, end: \.end)
        for offset in stride(from: -1_000, through: 21_000, by: 317) {
            let start = base.addingTimeInterval(Double(offset))
            let end = start.addingTimeInterval(100)
            let expected = rows.filter { $0.start < end && $0.end > start }.map(\.id).sorted()
            XCTAssertEqual(index.overlapping(from: start, to: end).map(\.id).sorted(), expected)
        }
        XCTAssertTrue(index.overlapping(from: base, to: base).isEmpty)
        XCTAssertTrue(index.overlapping(from: base, to: base.addingTimeInterval(-1)).isEmpty)
    }

    func testBoundedPodcastSelectionPreservesOrderTiesAndCompletionRules() {
        var podcast = Podcast(feedURL: URL(string: "https://stress.invalid/feed")!, title: "Stress")
        podcast.episodes = (0..<300).map { i in
            Episode(id: "e\(i)", title: "Episode \(i)", audioURL: URL(string: "https://stress.invalid/\(i)")!,
                    pubDate: i % 19 == 0 ? nil : Date(timeIntervalSince1970: Double((i * 7919) % 91)))
        }
        podcast.completed = Set(podcast.episodes.enumerated().filter { $0.offset.isMultiple(of: 3) }.map { $0.element.id })
        for direction in PlayDirection.allCases {
            podcast.direction = direction
            for n in [0, 1, 3, 20, 33, 500] {
                XCTAssertEqual(podcast.nextUnplayed(n).map(\.id),
                               Array(podcast.ordered().filter { !podcast.completed.contains($0.id) }.prefix(n)).map(\.id))
                XCTAssertEqual(podcast.newestEpisodes(n).map(\.id),
                               Array(podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }.prefix(n)).map(\.id))
            }
            XCTAssertEqual(podcast.nextEpisode()?.id, podcast.ordered().first { !podcast.completed.contains($0.id) }?.id)
            podcast.currentEpisodeID = "e2"
            XCTAssertEqual(podcast.nextEpisode()?.id, "e2")
            podcast.currentEpisodeID = nil
        }
        podcast.completed = Set(podcast.episodes.map(\.id))
        XCTAssertEqual(podcast.nextEpisode()?.id, podcast.ordered().first?.id)
        XCTAssertTrue(podcast.nextUnplayed(3).isEmpty)
    }

    func testNoteQueryCacheInvalidationAndArchivedSearch() {
        let active = VoiceNote(audioFilename: "", transcript: "Café NEEDLE", status: .transcribed)
        let archived = VoiceNote(archivedAt: Date(), audioFilename: "", transcript: "Needle archived", status: .transcribed)
        let index = NoteQueryCache()
        let rows = [active, archived]
        XCTAssertEqual(index.matching(rows, search: "needle", archived: false).map(\.id), [active.id])
        XCTAssertEqual(index.matching(rows, search: "needle", archived: true).map(\.id), [archived.id])
        XCTAssertEqual(index.matching(rows, search: "", archived: false).map(\.id), [active.id])
        index.invalidate()
        var edited = active
        edited.transcript = "Changed"
        XCTAssertTrue(index.matching([edited], search: "needle", archived: false).isEmpty)
    }
}

final class CalendarDayRangeTests: XCTestCase {
    func testDSTAndMidnightMatchClippedIntervals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for parts in [DateComponents(year: 2026, month: 3, day: 8),
                      DateComponents(year: 2026, month: 11, day: 1)] {
            let day = calendar.date(from: parts)!
            let range = CalendarDayRange(day: day, calendar: calendar)
            XCTAssertNotEqual(range.end.timeIntervalSince(range.start), 86_400)
            for startOffset in [-86_400.0, -1, 0, 60, 82_800, 86_400, 90_000] {
                let start = range.start.addingTimeInterval(startOffset)
                for duration in [-60.0, 0, 60, 86_400, 172_800] {
                    let end = start.addingTimeInterval(duration)
                    let clippedStart = min(max(start, range.start), range.end)
                    let clippedEnd = max(min(end, range.end), clippedStart)
                    XCTAssertEqual(range.contains(start: start, end: end, timed: true), clippedEnd > clippedStart)
                    XCTAssertEqual(range.contains(start: start, end: end, timed: false),
                                   calendar.isDate(start, inSameDayAs: day))
                }
            }
        }
    }
}

final class MinuteMatchIndexTests: XCTestCase {
    func testPreservesFirstMatchAndStrictToleranceAcrossBucketBoundaries() {
        let values = [(date: Date(timeIntervalSinceReferenceDate: 61), value: "first"),
                      (date: Date(timeIntervalSinceReferenceDate: 1), value: "second"),
                      (date: Date(timeIntervalSinceReferenceDate: -59), value: "negative")]
        let index = MinuteMatchIndex(values)
        for seconds in stride(from: -180.0, through: 180, by: 0.5) {
            let date = Date(timeIntervalSinceReferenceDate: seconds)
            XCTAssertEqual(index.first(near: date),
                           values.first { abs($0.date.timeIntervalSince(date)) < 60 }?.value)
        }
        XCTAssertNil(MinuteMatchIndex<String>().first(near: .now))
    }
}
