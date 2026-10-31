import Foundation
import CoreGraphics

struct Source {
    let id: String
    let start: Date
    let end: Date
    let shift: Double
    let lane: Int
    let lanes: Int
    var shown: Date { start.addingTimeInterval(shift) }
    func span(_ width: CGFloat) -> Range<CGFloat> {
        let w = max(24, (width - 6 - CGFloat(lanes - 1) * 2) / CGFloat(lanes))
        let x = 3 + CGFloat(lane) * (w + 2)
        return x..<(x + w)
    }
}
// Frozen independent production scans. Keep the filtered arrays and date projection here.
@inline(never) func reference(_ rows: [Source], width: CGFloat, clock: CalendarDayClockGeometry) -> [CalendarMobileNeighbors.Result] {
    let visibleStart = clock.boundary(clock.startHour)
    return rows.map { row in
        let end = row.end.addingTimeInterval(row.shown.timeIntervalSince(row.start))
        let next = rows.filter { $0.id != row.id && $0.lane == row.lane && $0.shown >= end }
            .min { $0.shown < $1.shown }
        let visualEnd = next.flatMap { $0.shown.timeIntervalSince(end) <= 300 ? $0.shown : nil } ?? end
        let top = rows.filter { $0.id != row.id && $0.shown > row.shown }
            .filter { $0.span(width).overlaps(row.span(width)) }
            .map { clock.y(max($0.shown, visibleStart)) }.min()
        return .init(visualEnd: visualEnd, nextTop: top)
    }
}
@inline(never) func prepared(_ rows: [Source], width: CGFloat, clock: CalendarDayClockGeometry) -> [CalendarMobileNeighbors.Result] {
    let visibleStart = clock.boundary(clock.startHour)
    let inputs = rows.map { row in
        CalendarMobileNeighbors.Input(id: row.id, start: row.shown,
            end: row.end.addingTimeInterval(row.shown.timeIntervalSince(row.start)), lane: row.lane,
            span: row.span(width), top: clock.y(max(row.shown, visibleStart)))
    }
    // Include the production ID index and lookups, not just the arithmetic kernel.
    guard let index = CalendarMobileNeighbors.indexed(inputs) else {
        return reference(rows, width: width, clock: clock)
    }
    return rows.map { index[$0.id]! }
}
@main struct Checks {
    @MainActor static func main() throws {
        precondition([2,4].contains(CommandLine.arguments.count))
        let path = CommandLine.arguments[1]
        precondition(!FileManager.default.fileExists(atPath: path))
        if CommandLine.arguments.count == 4 {
            let policy = CommandLine.arguments[2]
            precondition(["reference", "prepared"].contains(policy))
            let config = CalendarFixtureConfiguration(args: ["--fixture","varied-v1","--density",CommandLine.arguments[3],"--days","7","--seed","20261009"])
            let store = FixtureStore(config, leadingDays: 0)
            let date = store.byDay.max { $0.value.count < $1.value.count }!.key
            let events = store.day(date)
            let plan = CalendarLanePlan.make(events.map { .init(id: $0.id, start: $0.start, end: $0.end) })
            let rows = plan.map { p in Source(id: events[p.index].id, start: events[p.index].start,
                end: events[p.index].end, shift: 0, lane: p.lane, lanes: p.laneCount) }
            let clock = CalendarDayClockGeometry(day: date, calendar: store.calendar, startHour: 0, hourHeight: 56)
            var samples: [Double] = [], sink = 0.0
            for _ in 0..<13 {
                let start = ContinuousClock.now
                let value = policy == "prepared" ? prepared(rows,width:390,clock:clock) : reference(rows,width:390,clock:clock)
                let elapsed = start.duration(to: .now)
                samples.append(Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15)
                sink += value.reduce(0) { $0 + ($1.nextTop ?? 0) + $1.visualEnd.timeIntervalSince1970 }
            }
            try JSONSerialization.data(withJSONObject: ["policy":policy,"densityMean":config.density,
                "visibleCountIncludingCarryIn":rows.count,"samplesMS":samples,"sink":sink,
                "scope":"First component invocation in a fresh process then 12 repeats; fixture/lane construction excluded; no persistent cache to evict."], options:[.prettyPrinted,.sortedKeys])
                .write(to: URL(fileURLWithPath:path))
            return
        }
        var checks = 0, state: UInt64 = 20261010
        func random() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
        func check(_ rows: [Source], _ width: CGFloat, _ clock: CalendarDayClockGeometry) {
            precondition(reference(rows, width: width, clock: clock) == prepared(rows, width: width, clock: clock))
            checks += 1
        }
        for zone in ["UTC", "America/New_York", "Australia/Lord_Howe"] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
            for (month, day) in [(3,8),(11,1),(4,5),(10,4)] {
                let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
                for n in [0,1,2,10,100,300] {
                    let rows = (0..<n).map { i -> Source in
                        let start = date.addingTimeInterval(Double(random() % 110000) - 10000)
                        return Source(id: "\(i)", start: start,
                            end: start.addingTimeInterval(Double(random() % 90000) - 100),
                            shift: Double(Int(random() % 31) - 15) * 300,
                            lane: Int(random() % 8), lanes: 8 + Int(random() % 4))
                    }
                    for width: CGFloat in [100,390,1024] {
                        for startHour in [0,8] {
                            check(rows, width, CalendarDayClockGeometry(day: date, calendar: calendar,
                                startHour: startHour, hourHeight: 28 + CGFloat(random() % 100)))
                        }
                    }
                }
            }
        }
        // Strict starts, five-minute joining boundary, touching spans, repeated wall-clock hour.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let clock = CalendarDayClockGeometry(day: day, calendar: calendar, startHour: 0, hourHeight: 56)
        for gap in [0.0,299,300,301] {
            let a = Source(id: "a", start: day, end: day.addingTimeInterval(3600), shift: 0, lane: 0, lanes: 1)
            let b = Source(id: "b", start: a.end.addingTimeInterval(gap), end: a.end.addingTimeInterval(gap+600), shift: 0, lane: 0, lanes: 1)
            check([a,b],390,clock)
        }
        // A shared source ID can have distinct placement geometry. Never trap or use the
        // first placement's result for both; the production caller retains its reference scans.
        let duplicateStart = day.addingTimeInterval(9 * 3600)
        let duplicates: [CalendarMobileNeighbors.Input] = [
            .init(id: "same-source", start: duplicateStart, end: duplicateStart.addingTimeInterval(900),
                  lane: 0, span: 0..<100, top: 100),
            .init(id: "same-source", start: duplicateStart.addingTimeInterval(1800),
                  end: duplicateStart.addingTimeInterval(3600), lane: 1, span: 100..<200, top: 200)
        ]
        precondition(CalendarMobileNeighbors.indexed(duplicates) == nil)
        precondition(CalendarMobileNeighbors.indexed([duplicates[0], duplicates[0]]) == nil)
        precondition(CalendarMobileNeighbors.indexed([])?.isEmpty == true)
        precondition(CalendarMobileNeighbors.indexed([duplicates[0]])?["same-source"] ==
                     CalendarMobileNeighbors.make([duplicates[0]])[0])
        checks += 4
        var matrices: [[String: Any]] = []
        for fixture in ["uniform-v1","varied-v1"] {
            for density in [10,100,300,1000] {
                let config = CalendarFixtureConfiguration(args: ["--fixture",fixture,"--density",String(density),"--days","7","--seed","20261009"])
                let store = FixtureStore(config, leadingDays: 0)
                let date = store.byDay.max { $0.value.count < $1.value.count }!.key
                let events = store.day(date)
                let plan = CalendarLanePlan.make(events.map { .init(id: $0.id, start: $0.start, end: $0.end) })
                let rows = plan.map { p in Source(id: events[p.index].id, start: events[p.index].start,
                    end: events[p.index].end, shift: 0, lane: p.lane, lanes: p.laneCount) }
                let clock = CalendarDayClockGeometry(day: date, calendar: store.calendar, startHour: 0, hourHeight: 56)
                check(rows,390,clock)
                var old: [Double] = [], new: [Double] = []
                var sink = 0.0
                for trial in 0..<12 {
                    for optimized in trial.isMultiple(of: 2) ? [false,true] : [true,false] {
                        let start = ContinuousClock.now
                        let value = optimized ? prepared(rows,width:390,clock:clock) : reference(rows,width:390,clock:clock)
                        let elapsed = start.duration(to: .now)
                        let ms = Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15
                        if optimized { new.append(ms) } else { old.append(ms) }
                        sink += value.reduce(0) { $0 + ($1.nextTop ?? 0) + $1.visualEnd.timeIntervalSince1970 }
                    }
                }
                matrices.append(["fixture":fixture,"densityMean":density,"visibleCountIncludingCarryIn":rows.count,
                    "referenceMS":old,"preparedMS":new,"sink":sink,
                    "inputStrideBytes":MemoryLayout<CalendarMobileNeighbors.Input>.stride,
                    "resultStrideBytes":MemoryLayout<CalendarMobileNeighbors.Result>.stride])
            }
        }
        try JSONSerialization.data(withJSONObject: ["checks":checks,"matrices":matrices,
            "scope":"Layout-neighbor component only. Fresh snapshot each call; no warm or cross-update cache. First samples retained. Not app frame or input latency."], options:[.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath:path))
        print("Passed \(checks) parity checks; retained 12 alternating samples per policy/workload")
    }
}
