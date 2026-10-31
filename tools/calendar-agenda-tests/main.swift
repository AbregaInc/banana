import Foundation

var checks = 0
func check(_ condition: Bool, _ message: String) {
    precondition(condition, message); checks += 1
}
func calendar(_ zone: String) -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: zone)!
    return value
}
let utc = calendar("UTC")
let day = utc.date(from: DateComponents(year: 2026, month: 10, day: 10))!
let geometry = CalendarAgendaGeometry(day: day, calendar: utc, hourHeight: 30)
func interval(_ start: Double, _ end: Double) -> DateInterval {
    DateInterval(start: day.addingTimeInterval(start * 60), end: day.addingTimeInterval(end * 60))
}
check(geometry.height == 720 && geometry.ticks.count == 25, "Full civil day")
let night = geometry.frames([interval(10, 40), interval(310, 340)], minimum: 21)
check(night[0].y == 5 && night[1].y == 155, "Early events must not collapse at 6 AM")
let clipped = geometry.frames([interval(-60, 60), interval(1380, 1500), interval(-1440, 2880)], minimum: 21)
check(clipped[0] == .init(y: 0, height: 30), "Incoming overnight clip")
check(clipped[1] == .init(y: 690, height: 30), "Outgoing overnight clip")
check(clipped[2] == .init(y: 0, height: 720), "Multi-day item stays inside its day")
let adjacent = geometry.frames([interval(0, 10), interval(10, 20), interval(1439, 1440)], minimum: 21)
check(adjacent[0] == .init(y: 0, height: 5), "Minimum cannot cover next start")
check(adjacent[1] == .init(y: 5, height: 21), "Readable extension into free time")
check(adjacent[2] == .init(y: 719.5, height: 0.5), "Minimum cannot cover next day")
let boundary = geometry.frames([interval(-10, 0), interval(1440, 1450), interval(0, 0)], minimum: 21)
check(boundary[0].height == 0 && boundary[1].height == 0, "Outside half-open day")
check(boundary[2].height == 21, "Zero-duration cue inside day")
check(geometry.frames([], minimum: 21).isEmpty, "Empty day")
for (month, date, hours) in [(3, 8, 23.0), (11, 1, 25.0)] {
    let ny = calendar("America/New_York")
    let d = ny.date(from: DateComponents(year: 2026, month: month, day: date))!
    let g = CalendarAgendaGeometry(day: d, calendar: ny, hourHeight: 30)
    check(g.height == hours * 30 && g.ticks.last == g.end, "DST day bounds")
    check(Set(g.ticks).count == g.ticks.count, "Repeated wall-clock hour has distinct instants")
    if hours == 25 {
        let a = d.addingTimeInterval(5400), b = d.addingTimeInterval(9000)
        check(ny.component(.hour, from: a) == ny.component(.hour, from: b) && g.y(b) - g.y(a) == 30,
              "Repeated hour has distinct geometry")
    }
}
let lh = calendar("Australia/Lord_Howe")
let halfDay = lh.date(from: DateComponents(year: 2026, month: 10, day: 4))!
let half = CalendarAgendaGeometry(day: halfDay, calendar: lh, hourHeight: 30)
check(half.height == 23.5 * 30 && half.ticks.last == half.end, "Half-hour DST boundary")

// Invariants and measured preparation cost at adversarial densities. These are geometry API
// costs, not renderer or input-to-visible evidence. Do not compare corrected pixels to the bug.
var metrics: [[String: Any]] = []
for count in [100, 300, 1000, 5000] {
    let values = (0..<count).map { i in interval(Double(i % 1440), Double(i % 1440 + (i % 8 + 1) * 15)) }
    let result = geometry.frames(values, minimum: 21)
    check(result.count == count, "No discarded events")
    check(result.allSatisfy { $0.y >= 0 && $0.height >= 0 && $0.y + $0.height <= geometry.height }, "All frames bounded")
    var samples: [Double] = []; var checksum = 0.0
    for _ in 0..<201 {
        let start = ProcessInfo.processInfo.systemUptime
        let frames = geometry.frames(values, minimum: 21)
        samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        checksum += frames.reduce(0) { $0 + Double($1.y + $1.height) }
    }
    let sorted = samples.sorted()
    metrics.append(["events": count, "samplesMS": samples, "medianMS": sorted[100],
                    "p95MS": sorted[190], "maximumMS": sorted.last!, "checksum": checksum])
}
let report: [String: Any] = ["checks": checks, "metrics": metrics,
    "scope": "Corrected day geometry API cost only; not frames, input latency or pixel equivalence with the old broken layout."]
precondition(CommandLine.arguments.count == 2)
let path = CommandLine.arguments[1]
precondition(!FileManager.default.fileExists(atPath: path))
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
print("PASS: \(checks) Agenda geometry checks")
