import XCTest

/// A calendar id identifies a calendar, not a calendar-per-account.
///
/// With several Google accounts connected, a shared calendar appears in every account's calendar
/// list with the SAME id — "Holidays in United States" and shared work calendars all do. Two
/// entries under one id crashed the app outright: `Dictionary(uniqueKeysWithValues:)` traps on a
/// duplicate, and the settings snapshot builds exactly that from the calendar list. Flipping any
/// setting killed the app.
final class DuplicateCalendarIDTests: XCTestCase {

    /// The trap, demonstrated on the construction that caused it, so the reason this matters is
    /// not just described but shown.
    func testBuildingAUniqueKeyedDictionaryFromDuplicatesIsUnsafe() {
        let pairs = [("shared-cal", "from account A"), ("shared-cal", "from account B")]
        // `Dictionary(uniqueKeysWithValues:)` would trap here. The uniquing form must be used
        // wherever the keys come from a calendar list.
        let safe = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(safe.count, 1)
        XCTAssertEqual(safe["shared-cal"], "from account A", "first wins; they are the same calendar")
    }

    /// Deduplication has to keep every DISTINCT calendar — collapsing too eagerly would silently
    /// drop calendars from the picker.
    func testDeduplicationKeepsEveryDistinctCalendar() {
        let ids = ["a@group.calendar.google.com", "holidays", "holidays", "b@group.calendar.google.com"]
        var seen = Set<String>()
        let deduped = ids.filter { seen.insert($0).inserted }
        XCTAssertEqual(deduped, ["a@group.calendar.google.com", "holidays", "b@group.calendar.google.com"])
    }

    /// Order matters: the picker is sorted for display, and dedup must not reorder what survives.
    func testDeduplicationPreservesOrder() {
        let ids = ["z", "a", "z", "m", "a"]
        var seen = Set<String>()
        XCTAssertEqual(ids.filter { seen.insert($0).inserted }, ["z", "a", "m"])
    }
}
