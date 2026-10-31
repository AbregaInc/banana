import Foundation
enum Behavior { case event, block }
struct Occurrence: Equatable {
    let id: String
    let start: Date
    let resolvedEnd: Date
    var hasScheduledTime = true
    var behavior = Behavior.event
}
enum CalendarLaneAllocator {
    struct Placement: Equatable, Identifiable {
        var id: String { occurrence.id }
        let occurrence: Occurrence
        let lane: Int
        let laneCount: Int
    }

    static func placements(_ occurrences: [Occurrence]) -> [Placement] {
        let plan = CalendarLanePlan.make(occurrences.map {
            .init(id: $0.id, start: $0.start, end: $0.resolvedEnd)
        })
        return plan.map {
            Placement(occurrence: occurrences[$0.index], lane: $0.lane, laneCount: $0.laneCount)
        }
    }

}


struct WeekView { static let reuseGridLayouts = true
    struct DayData: Identifiable, Equatable {
        let id: Int
        let date: Date
        let weekday: String
        let dayNum: String
        let letter: String
        let isToday: Bool
        let items: [Occurrence]
        let committed: Double
        /// `items.hashValue`, computed once here at construction (items is immutable), for
        /// views that key on a day's contents.
        let itemsToken: Int
        let preparedPlacements: [CalendarLaneAllocator.Placement]

        init(id: Int, date: Date, weekday: String, dayNum: String, letter: String,
             isToday: Bool, items: [Occurrence], committed: Double, itemsToken: Int,
             calendarGrid: Bool = false) {
            self.id = id; self.date = date; self.weekday = weekday; self.dayNum = dayNum
            self.letter = letter; self.isToday = isToday; self.items = items
            self.committed = committed; self.itemsToken = itemsToken
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: date)
            // Match the grid's existing 24-hour offset even on a DST transition. Changing
            // wall-clock axis semantics is separate from preparing the existing layout.
            let end = calendar.date(byAdding: .hour, value: 24, to: start) ?? start
            preparedPlacements = WeekView.reuseGridLayouts
                ? CalendarLaneAllocator.placements(items.filter {
                    $0.hasScheduledTime && (!calendarGrid ||
                        ($0.behavior != .block && $0.start < end && $0.resolvedEnd > start))
                }) : []
        }
        var load: Double { min(1, committed / 16) }
        var free: Int { Int(max(0, 16 - committed).rounded()) }
    }

}
// Appended to the production snapshot initializer by run.py.
var failures: [String] = []
var checks = 0
var samples: [[String: Any]] = []
var sink = 0
let formatter = ISO8601DateFormatter()
for (zone, dateString, dayHours) in [
    ("UTC", "2026-10-10T00:00:00Z", 24.0),
    ("America/New_York", "2026-03-08T00:00:00-05:00", 23.0),
    ("America/New_York", "2026-11-01T00:00:00-04:00", 25.0),
    ("Australia/Lord_Howe", "2026-04-05T00:00:00+11:00", 24.5),
    ("Australia/Lord_Howe", "2026-10-04T00:00:00+10:30", 23.5)
] {
    let previous = NSTimeZone.default
    NSTimeZone.default = TimeZone(identifier: zone)!
    defer { NSTimeZone.default = previous }
    let day = formatter.date(from: dateString)!
    // Independent expected boundary, not CalendarDayRange's implementation.
    let end = day.addingTimeInterval(dayHours * 3600)
    let rows = [
        Occurrence(id: "ended-before", start: day.addingTimeInterval(-600), resolvedEnd: day),
        Occurrence(id: "carry-in", start: day.addingTimeInterval(-600), resolvedEnd: day.addingTimeInterval(600)),
        Occurrence(id: "first", start: day, resolvedEnd: day.addingTimeInterval(600)),
        Occurrence(id: "last-quarter-hour", start: end.addingTimeInterval(-900), resolvedEnd: end),
        Occurrence(id: "next-midnight", start: end, resolvedEnd: end.addingTimeInterval(600)),
        Occurrence(id: "next-quarter-hour", start: end.addingTimeInterval(900), resolvedEnd: end.addingTimeInterval(1800)),
        Occurrence(id: "untimed", start: day, resolvedEnd: end, hasScheduledTime: false),
        Occurrence(id: "block", start: day, resolvedEnd: end, behavior: .block)
    ]
    func snapshot(_ items: [Occurrence], grid: Bool) -> WeekView.DayData {
        WeekView.DayData(id: 0, date: day, weekday: "", dayNum: "", letter: "", isToday: false,
                         items: items, committed: 0, itemsToken: 0, calendarGrid: grid)
    }
    for grid in [false, true] {
        let expected = Set(grid ? ["carry-in", "first", "last-quarter-hour"]
                               : rows.filter(\.hasScheduledTime).map(\.id))
        let actual = Set(snapshot(rows, grid: grid).preparedPlacements.map(\.id))
        checks += 1
        if expected != actual {
            failures.append("\(zone) \(dateString) grid=\(grid): expected \(expected.sorted()), got \(actual.sorted())")
        }
    }
    // A changed immutable snapshot must replace values even when IDs remain the same.
    let old = snapshot(rows, grid: true)
    let changed = Occurrence(id: "first", start: day.addingTimeInterval(3600), resolvedEnd: end)
    let updated = snapshot([changed], grid: true)
    checks += 1
    if updated.preparedPlacements.map(\.occurrence) != [changed] || old.items != rows {
        failures.append("snapshot replacement retained stale occurrence data")
    }
    for density in [100, 1000] {
        let workload = (0..<density).map { i in
            let start = day.addingTimeInterval(Double(i) / Double(density) * dayHours * 3600)
            return Occurrence(id: "event-\(i)", start: start, resolvedEnd: start.addingTimeInterval(1800))
        }
        var timings: [Double] = []
        for _ in 0..<21 {
            let start = ContinuousClock.now
            let value = snapshot(workload, grid: true)
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            sink += value.preparedPlacements.count
        }
        samples.append(["zone": zone, "date": dateString, "density": density, "samplesMS": timings])
    }
}
let report: [String: Any] = ["checks": checks, "failures": failures, "samples": samples, "sink": sink,
    "scope": "Extracted production snapshot initializer and allocator with minimal occurrence values; no UI or physical frame acceptance. Each sample builds a new snapshot; no retained cache."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("\(checks) checks, \(failures.count) failures")
if !failures.isEmpty { exit(1) }
