import Foundation

func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
func calendar(_ zone: String) -> Calendar {
    var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: zone)!; return result
}
// Frozen drag calculation from both mobile and Mac WeekView before this correction.
func reference(original: Date, visibleDay: Date, shift: Int, minutes: Double, cal: Calendar) -> Date? {
    guard let target = cal.date(byAdding: .day, value: shift, to: visibleDay) else { return nil }
    let parts = cal.dateComponents([.hour, .minute], from: original)
    guard let base = cal.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0,
                             second: 0, of: target) else { return nil }
    return base.addingTimeInterval((minutes / 5).rounded() * 5 * 60)
}
let old = CommandLine.arguments.contains("--reference")
var failures: [String] = []; var checks = 0
func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures.append(label) } }
let utc = calendar("UTC"), ny = calendar("America/New_York")
let original = date("2026-10-10T01:40:00Z")
for offset in [0, 1, 2, 7] {
    for shift in [-2, -1, 0, 1, 2] {
        for minutes in [-65.0, -2.0, 0, 2, 60, 122] {
            let visibleDay = utc.date(byAdding: .day, value: offset, to: original)!
            let expected = utc.date(byAdding: .day, value: shift, to: original)!
                .addingTimeInterval((minutes / 5).rounded() * 300)
            let actual = old ? reference(original: original, visibleDay: visibleDay, shift: shift, minutes: minutes, cal: utc)
                : CalendarMoveGeometry.start(original: original, dayShift: shift, minutes: minutes, calendar: utc)
            check(actual == expected, "continuation=\(offset) days=\(shift) minutes=\(minutes)")
        }
    }
}
for value in ["2026-11-01T01:30:00-04:00", "2026-11-01T01:30:00-05:00", "2026-10-10T11:15:37Z"] {
    let original = date(value)
    let actual = old ? reference(original: original, visibleDay: original, shift: 0, minutes: 0, cal: ny)
        : CalendarMoveGeometry.start(original: original, dayShift: 0, minutes: 0, calendar: ny)
    check(actual == original, "no-op preserves instant \(value)")
}
for (start, expected) in [("2026-03-07T10:00:00-05:00", "2026-03-08T10:00:00-04:00"),
                          ("2026-10-31T10:00:00-04:00", "2026-11-01T10:00:00-05:00")] {
    check(CalendarMoveGeometry.start(original: date(start), dayShift: 1, minutes: 0, calendar: ny) == date(expected),
          "horizontal day step preserves clock across DST")
}
for duration in [0.0, 1800, 86400, 172800] {
    for delta in [-90000.0, -3600, 0, 3600, 90000] {
        let displayed = original.addingTimeInterval(delta), end = original.addingTimeInterval(duration)
        let actual = old ? end : CalendarMoveGeometry.end(originalStart: original, originalEnd: end, displayedStart: displayed)
        check(actual.timeIntervalSince(displayed) == duration, "duration=\(duration) delta=\(delta)")
    }
}
check(CalendarMoveGeometry.start(original: original, dayShift: 0, minutes: .nan, calendar: utc) == nil, "nonfinite rejected")
var samples: [[String: Any]] = []
for policy in ["reference", "relative", "relative", "reference"] {
    for _ in 0..<7 {
        let start = ContinuousClock.now; var sum = 0.0
        for i in 0..<1000 {
            let result = policy == "reference"
                ? reference(original: original, visibleDay: original, shift: i % 3 - 1, minutes: Double(i % 60), cal: utc)!
                : CalendarMoveGeometry.start(original: original, dayShift: i % 3 - 1, minutes: Double(i % 60), calendar: utc)!
            sum += result.timeIntervalSince1970
        }
        let elapsed = start.duration(to: .now).components
        samples.append(["policy": policy, "operations": 1000, "checksum": sum,
                        "ms": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15])
    }
}
check(Set(samples.map { $0["checksum"] as! Double }).count == 1, "ordinary move parity")
let report: [String: Any] = ["checks": checks, "failures": failures, "referenceControl": old, "samples": samples,
    "scope": "date arithmetic and optimistic duration components; not UI, frame or input latency"]
if let index = CommandLine.arguments.firstIndex(of: "--out") {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
}
print("\(checks) checks; \(failures.count) failures; \(samples.count) component samples")
if !failures.isEmpty { exit(1) }
