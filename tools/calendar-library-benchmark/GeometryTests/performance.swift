import Foundation

@main
struct CorePerformance {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        var results: [[String: Any]] = []
        var checksum = 0
        func measure(_ name: String, _ density: Int, _ body: () -> Int) {
            for _ in 0..<20 { checksum &+= body() }
            var samples: [Double] = []
            for _ in 0..<200 {
                let start = DispatchTime.now().uptimeNanoseconds
                checksum &+= body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let sorted = samples.sorted()
            results.append(["name": name, "density": density, "samplesMS": samples,
                            "p50MS": sorted[99], "p95MS": sorted[189], "p99MS": sorted[197], "maxMS": sorted.last!])
        }
        for density in [100, 300, 1000, 2000, 4000, 10000] {
            let events = (0..<density).map { index -> Fixture in
                let start = day.addingTimeInterval(Double(index % 100) * 600)
                return Fixture(id: "\(index)", start: start, end: start.addingTimeInterval(index.isMultiple(of: 10) ? 86400 : 1800))
            }
            let geometry = DayGeometry(date: day, calendar: calendar, events: events)
            measure("layout-heap", density) { DayGeometry(date: day, calendar: calendar, events: events, useHeap: true).placements.count }
            measure("layout-linear", density) { DayGeometry(date: day, calendar: calendar, events: events, useHeap: false).placements.count }
            measure("layout-heap-no-index", density) { DayGeometry(date: day, calendar: calendar, events: events, useHeap: true, buildIndex: false).placements.count }
            measure("layout-linear-no-index", density) { DayGeometry(date: day, calendar: calendar, events: events, useHeap: false, buildIndex: false).placements.count }
            for span in [0.05, 0.4] {
                measure("indexed-query-\(span)", density) { geometry.visible(from: 0.3, to: 0.3 + span).count }
                measure("scan-query-\(span)", density) { geometry.placements.filter { $0.end > 0.3 && $0.start < 0.3 + span }.count }
            }
            let cache = GeometryCache(); cache.put(geometry)
            measure("cached-layout", density) { cache.get(day)!.placements.count }
        }
        let report: [String: Any] = ["scope": "Release pure geometry/query/cache microbenchmarks; not UI timings", "checksum": checksum, "results": results]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
