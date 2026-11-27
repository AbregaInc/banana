import Foundation

// A value-sized event fixture makes the cost of copying rows visible. Matches are checked
// against an independent scan, including ties and events crossing a query boundary.
struct Item {
    let id: Int
    let start, end: Date
    let payload: (SIMD64<UInt8>, SIMD64<UInt8>, SIMD64<UInt8>, SIMD64<UInt8>)
}
let shuffled = CommandLine.arguments[1] == "shuffled"
let count = 15_292
let values = (0..<count).map { i -> Item in
    let tick = shuffled ? (i * 7919) % count : i
    let start = Date(timeIntervalSinceReferenceDate: Double(tick / 3))
    let payload = SIMD64<UInt8>(repeating: UInt8(truncatingIfNeeded: i))
    return Item(id: i, start: start, end: start.addingTimeInterval(i.isMultiple(of: 17) ? 900 : 2),
                payload: (payload, payload, payload, payload))
}
let since = Date(timeIntervalSinceReferenceDate: 1000), until = since.addingTimeInterval(20)
let expected = values.filter { $0.start < until && $0.end > since }.sorted { $0.start < $1.start }.map(\.id)
var builds = [Double](), queries = [Double]()
for _ in 0..<7 {
    let started = ProcessInfo.processInfo.systemUptime
    let idx = TimeRangeIndex(values, start: \.start, end: \.end)
    let built = ProcessInfo.processInfo.systemUptime
    let matches = idx.overlapping(from: since, to: until)
    let finished = ProcessInfo.processInfo.systemUptime
    precondition(matches.map(\.id) == expected)
    builds.append((built - started) * 1000)
    queries.append((finished - built) * 1000)
}
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
let report: [String: Any] = ["rows": count, "stride": MemoryLayout<Item>.stride,
    "shuffled": shuffled, "rssMiB": Double(usage.ru_maxrss) / 1_048_576,
    "buildMS": builds, "queryMS": queries, "matching": expected.count]
print(String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
