import Foundation

@main
struct FixtureChecks {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        func store(_ profile: String, _ seed: String = "20261009", hidden: String = "") -> FixtureStore {
            FixtureStore(CalendarFixtureConfiguration(args: ["fixture-test", "--fixture", profile, "--seed", seed,
                "--days", "35", "--density", "100", "--hidden-calendars", hidden]))
        }
        let original = store("uniform-v1"), varied = store("varied-v1"), repeated = store("varied-v1")
        let differentSeed = store("varied-v1", "20261010")
        check(original.fixtureSummary["distinctDailyPatterns"] as? Int == 1, "Frozen control changed shape")
        check(original.fixtureSummary["calendarCount"] as? Int == 1, "Frozen control changed calendars")
        for (date, events) in original.byDay {
            check(events.count == 100, "Frozen daily volume changed")
            for (index, event) in events.enumerated() {
                check(event.start == date.addingTimeInterval(Double(index % 100) * 600), "Frozen start changed")
                check(event.end.timeIntervalSince(event.start) == (index.isMultiple(of: 10) ? 86400 : 1800), "Frozen duration changed")
            }
        }
        check(varied.fixtureSummary["contentChecksum"] as? String == repeated.fixtureSummary["contentChecksum"] as? String,
              "Same seed did not reproduce the identical fixture")
        check(varied.fixtureSummary["contentChecksum"] as? String != differentSeed.fixtureSummary["contentChecksum"] as? String,
              "Seed was ignored")
        check(varied.fixtureSummary["distinctDailyPatterns"] as? Int == 35, "Days repeat their geometry")
        check(varied.fixtureSummary["distinctWeeklyPatterns"] as? Int == 5, "Weeks repeat their geometry")
        check(varied.fixtureSummary["distinctDurations"] as? Int == 12, "Duration diversity missing")
        // The app uses the same generator anchored to today, without the prototype's
        // fifteen-day lookback. Defaults above must remain the frozen prototype workload.
        let appAnchor = varied.calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        for density in [1, 10, 100, 300] {
            let app = FixtureStore(CalendarFixtureConfiguration(args: ["--fixture", "varied-v1", "--days", "30",
                "--density", String(density)]), anchor: appAnchor, leadingDays: 0)
            let dates = app.byDay.keys.sorted()
            check(dates.first == appAnchor, "App anchor ignored")
            check(dates.count == 30, "App history length changed")
            check(app.byDay.values.reduce(0) { $0 + $1.count } == 30 * density, "App retained volume changed")
            check(Set(app.byDay.values.flatMap { $0 }.map(\.calendarIndex)).count == 12, "App calendars lost")
            for first in stride(from: 0, to: 30, by: 7) {
                let count = min(7, 30 - first)
                check(dates[first..<first+count].reduce(0) { $0 + app.byDay[$1]!.count } == count * density,
                      "App weekly volume changed")
            }
        }
        let all = varied.byDay.values.flatMap { $0 }
        check(Set(varied.byDay.values.map(\.count)).count > 10, "Daily load does not vary")
        let dates = varied.byDay.keys.sorted()
        for first in stride(from: 0, to: 35, by: 7) {
            check(dates[first..<first+7].reduce(0) { $0 + varied.byDay[$1]!.count } == 700, "Weekly volume changed")
        }
        check(all.count == 3500 && Set(all.map(\.id)).count == 3500, "Volume or stable identity lost")
        check(Set(all.map(\.calendarIndex)).count == 12, "Calendar IDs missing")
        check(all.contains { $0.title!.unicodeScalars.contains { !$0.isASCII } }, "Fallback font workload missing")
        let hidden = store("varied-v1", hidden: "1,3,5")
        for date in varied.byDay.keys.sorted() {
            let next = varied.calendar.date(byAdding: .day, value: 1, to: date)!
            let expected = Set(all.filter { $0.start < next && $0.end > date }.map(\.id))
            check(Set(varied.day(date).map(\.id)) == expected, "Cross-midnight/multiday coverage wrong")
            let filtered = Set(all.filter { $0.start < next && $0.end > date && ![1,3,5].contains($0.calendarIndex) }.map(\.id))
            check(Set(hidden.day(date).map(\.id)) == filtered, "Calendar visibility ignored")
            let geometry = DayGeometry(date: date, calendar: varied.calendar, events: varied.day(date))
            check(Set(geometry.placements.map(\.id)) == expected, "Geometry dropped events")
            for item in geometry.placements {
                let event = all.first { $0.id == item.id }!
                check(item.title == event.title && item.calendarIndex == event.calendarIndex, "Geometry dropped title/calendar identity")
            }
        }
        print("Passed \(checks) fixture assertions; uniform preserved, varied deterministic, multiday and calendar coverage verified")
    }
}
