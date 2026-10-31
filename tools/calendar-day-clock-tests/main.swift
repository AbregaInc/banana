import Foundation
import CoreGraphics

func instant(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
var checks = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
for (zone, start, end, hours) in [
    ("UTC", "2026-10-10T00:00:00Z", "2026-10-11T00:00:00Z", 24.0),
    ("America/New_York", "2026-03-08T00:00:00-05:00", "2026-03-09T00:00:00-04:00", 23.0),
    ("America/New_York", "2026-11-01T00:00:00-04:00", "2026-11-02T00:00:00-05:00", 25.0),
    ("Australia/Lord_Howe", "2026-10-04T00:00:00+10:30", "2026-10-05T00:00:00+11:00", 23.5)
] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    let first = instant(start), last = instant(end)
    for hourHeight in [44.0, 56.0, 160.0] {
        let clock = CalendarDayClockGeometry(day: first, calendar: calendar, startHour: 0, hourHeight: hourHeight)
        check(clock.start == first && clock.end == last, "local calendar boundaries")
        check(last.timeIntervalSince(first) == hours * 3600, "fixture elapsed duration")
        check(clock.y(first) == 0 && clock.y(last) == 24 * hourHeight, "midnight belongs at the bottom")
        check(clock.y(first.addingTimeInterval(-3600)) == 0, "clip before day")
        check(clock.y(last.addingTimeInterval(3600)) == 24 * hourHeight, "clip after day")
        check(clock.boundary(24) == last, "do not use 24 elapsed hours for day end")
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: first)!
        check(clock.y(noon) == 12 * hourHeight, "preserve wall-clock ruler")
        let window = CalendarDayClockGeometry(day: first, calendar: calendar, startHour: 6, hourHeight: hourHeight)
        check(window.y(noon) == 6 * hourHeight && window.y(last) == 18 * hourHeight, "window offset")
    }
}
var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
let fall = CalendarDayClockGeometry(day: instant("2026-11-01T00:00:00-04:00"), calendar: ny, startHour: 0, hourHeight: 56)
check(fall.y(instant("2026-11-01T01:30:00-04:00")) == 84, "first repeated hour")
check(fall.y(instant("2026-11-01T01:30:00-05:00")) == 84, "fixed wall-clock policy retained; Agenda uses elapsed time")

// Matched in-day work only: the old projection is incorrect for midnight boundaries.
@inline(never) func reference(_ date: Date) -> CGFloat {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60) * 56
}
let day = Calendar.current.startOfDay(for: Date())
let dates = (0..<200).map { day.addingTimeInterval(Double($0) * 300) }
var samples: [[String: Any]] = []
for policy in ["reference", "anchored", "anchored", "reference"] {
    for _ in 0..<7 {
        let start = ContinuousClock.now
        var sum: CGFloat = 0
        if policy == "reference" {
            for _ in 0..<10 { for date in dates { sum += reference(date) } }
        } else {
            let clock = CalendarDayClockGeometry(day: day, calendar: .current, startHour: 0, hourHeight: 56)
            for _ in 0..<10 { for date in dates { sum += clock.y(date) } }
        }
        let duration = start.duration(to: .now).components
        samples.append(["policy": policy, "ms": Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                        "checksum": Double(sum), "points": 2000])
    }
}
check(Set(samples.map { $0["checksum"] as! Double }).count == 1, "matched in-day results")
let report: [String: Any] = ["checks": checks, "samples": samples,
    "scope": "projection component work; correctness changes midnight extent; not UI/frame latency"]
if CommandLine.arguments.count > 1 {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print("Passed \(checks) checks; retained \(samples.count) component samples")
