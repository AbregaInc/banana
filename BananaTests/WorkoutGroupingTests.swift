import XCTest

/// Boundary coverage for `WorkoutGrouping.grouped` across every granularity, against
/// `Calendar.app` (the app's calendar with the configured week start applied — see
/// `Calendar.app` in `SmartSchedule.swift`). No binary fixture file is read here: every
/// `WorkoutEntry` is built directly from a `FitnessSession` with only `id`/`start`/`activity`
/// set, matching `WorkoutMotionAnalysisTests`'s "synthetic fixtures built in Swift" pattern.
final class WorkoutGroupingTests: XCTestCase {

    private let calendar = Calendar.app

    private func entry(_ date: Date, activity: String = "Running") -> WorkoutEntry {
        let session = FitnessSession(id: UUID(), start: date, end: date.addingTimeInterval(1_800),
                                      activity: activity, avgHeartRate: nil, totalEnergy: nil,
                                      totalDistance: nil, samples: [])
        return WorkoutEntry(health: nil, summary: FitnessSessionSummary(session: session))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        return calendar.date(from: c)!
    }

    // MARK: - Empty input

    func testEmptyEntriesProduceNoGroups() {
        XCTAssertTrue(WorkoutGrouping.grouped([], granularity: .week).isEmpty)
    }

    // MARK: - Week granularity: day buckets, "Today"/"Yesterday"/weekday name

    func testWeekGranularityGroupsByDayWithTodayYesterdayLabels() {
        let now = date(2026, 8, 27, 9)              // Thursday
        let today = date(2026, 8, 27, 18)            // same day, later — must bucket with `now`
        let yesterday = date(2026, 8, 26, 8)
        let twoDaysAgo = date(2026, 8, 25, 8)        // Tuesday

        let entries = [entry(today), entry(yesterday), entry(twoDaysAgo)]
            .sorted { $0.start > $1.start }          // WorkoutEntry.merge's own newest-first order

        let groups = WorkoutGrouping.grouped(entries, granularity: .week, calendar: calendar, now: now)

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Tuesday"])
        XCTAssertEqual(groups.map(\.entries.count), [1, 1, 1])
        // Groups newest-first.
        XCTAssertTrue(groups[0].key > groups[1].key)
        XCTAssertTrue(groups[1].key > groups[2].key)
    }

    func testWeekGranularityBucketsSameDayEntriesTogetherRegardlessOfTime() {
        let now = date(2026, 8, 27, 9)
        let morning = date(2026, 8, 27, 6)
        let evening = date(2026, 8, 27, 22)

        let groups = WorkoutGrouping.grouped([entry(evening), entry(morning)], granularity: .week,
                                              calendar: calendar, now: now)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "Today")
        XCTAssertEqual(groups[0].entries.count, 2)
    }

    /// Midnight is a day boundary even though the two entries are only seconds apart.
    func testWeekGranularitySeparatesEntriesAcrossMidnight() {
        let now = date(2026, 8, 27, 12)
        let justBeforeMidnight = date(2026, 8, 26, 23).addingTimeInterval(59 * 60 + 59)
        let justAfterMidnight = date(2026, 8, 27, 0).addingTimeInterval(1)

        let groups = WorkoutGrouping.grouped([entry(justAfterMidnight), entry(justBeforeMidnight)],
                                              granularity: .week, calendar: calendar, now: now)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "Today")     // Aug 27
        XCTAssertEqual(groups[1].title, "Yesterday")  // Aug 26 — exactly one day before `now`,
        // so the Yesterday branch wins over the weekday-name fallback (see `WorkoutGrouping.title`).
    }

    // MARK: - Month/quarter granularity: week buckets

    func testMonthGranularityGroupsByCalendarWeek() {
        // Aug 24 2026 is a Monday (Calendar.app's configured first weekday). Aug 23 is the
        // preceding Sunday — the last day of the *previous* calendar week.
        let sameWeekA = date(2026, 8, 24, 8)   // Monday, start of the week
        let sameWeekB = date(2026, 8, 27, 8)   // Thursday, same week
        let previousWeek = date(2026, 8, 23, 8) // Sunday, previous week

        let groups = WorkoutGrouping.grouped([entry(sameWeekB), entry(sameWeekA), entry(previousWeek)],
                                              granularity: .month, calendar: calendar, now: date(2026, 8, 27))

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].entries.count, 2)   // the two same-week entries
        XCTAssertEqual(groups[1].entries.count, 1)
        XCTAssertTrue(groups[0].title.hasPrefix("Week of"))
        // The later week sorts first.
        XCTAssertTrue(groups[0].key > groups[1].key)
    }

    func testQuarterGranularityAlsoGroupsByCalendarWeek() {
        let a = date(2026, 7, 6, 8)
        let b = date(2026, 7, 9, 8)   // same week as `a`
        let groups = WorkoutGrouping.grouped([entry(b), entry(a)], granularity: .quarter,
                                              calendar: calendar, now: date(2026, 9, 1))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.count, 2)
        XCTAssertTrue(groups[0].title.hasPrefix("Week of"))
    }

    // MARK: - Year granularity: month buckets

    func testYearGranularityGroupsByMonth() {
        let augEarly = date(2026, 8, 3, 8)
        let augLate = date(2026, 8, 30, 8)
        let july = date(2026, 7, 15, 8)

        let groups = WorkoutGrouping.grouped([entry(augLate), entry(augEarly), entry(july)],
                                              granularity: .year, calendar: calendar, now: date(2026, 8, 30))

        XCTAssertEqual(groups.map(\.title), ["August", "July"])
        XCTAssertEqual(groups[0].entries.count, 2)
        XCTAssertEqual(groups[1].entries.count, 1)
    }

    /// The turn of the year (Dec 31 → Jan 1) is a month boundary like any other; the two
    /// buckets must not collapse into one just because "December" and "January" don't share a
    /// numeric distance the way weeks/days might be compared naively.
    func testYearGranularitySeparatesDecemberFromJanuary() {
        let dec31 = date(2026, 12, 31, 12)
        let jan1 = date(2027, 1, 1, 12)

        let groups = WorkoutGrouping.grouped([entry(jan1), entry(dec31)], granularity: .year,
                                              calendar: calendar, now: date(2027, 1, 1))

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "January")
        XCTAssertEqual(groups[1].title, "December")
    }

    // MARK: - Ordering within a group is preserved (not re-sorted)

    func testEntryOrderWithinGroupIsPreservedNotResorted() {
        let now = date(2026, 8, 27, 20)
        let later = entry(date(2026, 8, 27, 18))
        let earlier = entry(date(2026, 8, 27, 7))
        // Deliberately pass newest-first, as WorkoutEntry.merge always returns.
        let groups = WorkoutGrouping.grouped([later, earlier], granularity: .week, calendar: calendar, now: now)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.map(\.start), [later.start, earlier.start])
    }
}
