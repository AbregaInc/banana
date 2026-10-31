import Foundation

typealias Interval = CalendarLanePlan.Interval
typealias Placement = CalendarLanePlan.Placement
let anchor = Date(timeIntervalSince1970: 0)
func interval(_ id: String, _ start: Double, _ end: Double) -> Interval {
    Interval(id: id, start: anchor.addingTimeInterval(start), end: anchor.addingTimeInterval(end))
}
// Frozen production algorithm from WeekView.swift, before prepared-layout integration.
// Deliberately keep its separate cluster/assignment arrays as the independent oracle.
func reference(_ items: [Interval]) -> [Placement] {
    let sorted = items.indices.sorted {
        let a = items[$0], b = items[$1]
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.id < b.id
    }
    var result: [Placement] = [], cluster: [Int] = []
    var clusterEnd = Date.distantPast
    func appendCluster() {
        var ends: [Date] = [], assigned: [(Int, Int)] = []
        for index in cluster {
            let item = items[index]
            if let lane = ends.firstIndex(where: { $0.timeIntervalSince(item.start) < 60 }) {
                ends[lane] = item.end; assigned.append((index, lane))
            } else { ends.append(item.end); assigned.append((index, ends.count - 1)) }
        }
        result += assigned.map { Placement(index: $0.0, lane: $0.1, laneCount: max(1, ends.count)) }
    }
    for index in sorted {
        if !cluster.isEmpty, clusterEnd.timeIntervalSince(items[index].start) < 60 {
            appendCluster(); cluster.removeAll(keepingCapacity: true); clusterEnd = .distantPast
        }
        cluster.append(index); clusterEnd = max(clusterEnd, items[index].end)
    }
    appendCluster(); return result
}
var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    precondition(condition, message)
}
let boundary = [interval("a", 0, 120), interval("b", 60, 180), interval("c", 121, 240)]
check(CalendarLanePlan.make(boundary).map(\.lane) == [0, 1, 0], "strict 60-second boundary")
check(CalendarLanePlan.make([]).isEmpty, "empty")
check(CalendarLanePlan.make([interval("z", 0, 100), interval("a", 0, 100)]).map(\.index) == [1, 0], "stable ID tie break")
let stretched = CalendarLanePlan.make([interval("all-day", 0, 86400), interval("morning", 3600, 7200), interval("collision", 3600, 7200), interval("later", 14400, 18000)])
check(stretched.first { $0.index == 3 }?.laneSpan == 2, "later event fills the remaining two thirds")
check(stretched.first { $0.index == 1 }?.laneSpan == 1, "simultaneous event keeps its own third")
check(stretched.first { $0.index == 0 }?.laneSpan == 1, "all-day block cannot cover shorter events")
let blocked = CalendarLanePlan.make([interval("long", 0, 86400), interval("a", 3600, 7200), interval("b", 3600, 7200), interval("c", 3600, 7200), interval("wide", 14400, 25200), interval("inside", 18000, 21600)])
check(blocked.first { $0.index == 4 }?.laneSpan == 1, "expansion stops at an overlapping event")
check(blocked.first { $0.index == 5 }?.laneSpan == 2, "an event farther right can still use its own empty neighbour")
var seed: UInt64 = 0xCA1E2026
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed }
for count in [0, 1, 2, 10, 100, 300, 1000, 4000] {
    for trial in 0..<30 {
        let items = (0..<count).map { i -> Interval in
            let start = Double(next() % 180000) - 86000
            // Includes zero-length, negative, nested, overnight and sub-minute intervals.
            return interval("\(trial)-\(i)", start, start + Double(next() % 10000) - 100)
        }
        let actual = CalendarLanePlan.make(items)
        check(zip(actual, reference(items)).allSatisfy { $0.index == $1.index && $0.lane == $1.lane && $0.laneCount == $1.laneCount }, "oracle mismatch at \(count), \(trial)")
        let reversed = Array(items.reversed())
        let other = CalendarLanePlan.make(reversed)
        check(zip(actual, other).allSatisfy {
            items[$0.index].id == reversed[$1.index].id && $0.lane == $1.lane && $0.laneCount == $1.laneCount && $0.laneSpan == $1.laneSpan
        }, "source ordering changed lanes")
    }
}
if let path = CommandLine.arguments.dropFirst().first {
    var reports: [[String: Any]] = []
    var checksum = 0
    for count in [100, 300, 1000, 4000] {
        let items = (0..<count).map { i -> Interval in
            let start = Double(next() % 86400)
            return interval("event-\(i)", start, start + Double(next() % 7200) + 60)
        }
        let prepared = CalendarLanePlan.make(items)
        let variants: [(String, () -> [Placement])] = [
            ("old-cold-or-rebuild", { reference(items) }),
            ("prepared-cold-or-rebuild", { CalendarLanePlan.make(items) }),
            ("prepared-warm", { prepared })
        ]
        var samples = Array(repeating: [Double](), count: variants.count)
        // Interleave all policies, retain first/cold call and every tail. Eviction is a rebuild:
        // there is no global cache; releasing the day releases its prepared value.
        for trial in 0..<201 {
            for offset in variants.indices {
                let index = (trial + offset) % variants.count
                let start = DispatchTime.now().uptimeNanoseconds
                let result = variants[index].1()
                checksum &+= result.reduce(0) { $0 &+ $1.index &+ $1.lane &+ $1.laneCount }
                samples[index].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
        }
        for index in variants.indices {
            let sorted = samples[index].sorted()
            reports.append(["count": count, "policy": variants[index].0, "samplesMS": samples[index],
                "p50MS": sorted[100], "p95MS": sorted[190], "maxMS": sorted.last!,
                "retainedPlanBytes": prepared.count * MemoryLayout<Placement>.stride])
        }
    }
    let data = try JSONSerialization.data(withJSONObject: ["checks": checks, "checksum": checksum,
        "scope": "Release macOS pure lane layout; excludes views, input, compositor and Occurrence adaptation",
        "reports": reports], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}
print("PASS: \(checks) lane layout parity and ordering checks")
