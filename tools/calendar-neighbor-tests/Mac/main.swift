import Foundation

typealias Input = CalendarMacLaneNeighbors.Input
typealias Neighbor = CalendarMacLaneNeighbors.Result

/// Frozen rules from the AppKit viewport before it prepared neighbors per day.
@inline(never) func reference(_ inputs: [Input]) -> [Neighbor] {
    inputs.map { item in
        let following = inputs.filter { $0.lane == item.lane && $0.start >= item.end }
            .min { $0.start < $1.start }
        let end = following.flatMap { $0.start.timeIntervalSince(item.end) <= 300 ? $0.start : nil } ?? item.end
        let next = inputs.filter { $0.lane == item.lane && $0.start > item.start }.map(\.displayedStart).min()
        return Neighbor(visualEnd: end, nextDisplayedStart: next)
    }
}

@main struct Checks {
    @MainActor static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(!FileManager.default.fileExists(atPath: destination.path))
        var checks = 0
        func check(_ items: [Input]) {
            precondition(CalendarMacLaneNeighbors.make(items) == reference(items))
            checks += 1
        }
        check([])
        var seed: UInt64 = 20261126
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 16) % UInt64(bound))
        }
        for count in [1, 2, 7, 24, 120, 512] {
            for _ in 0..<24 {
                let items = (0..<count).map { _ -> Input in
                    let start = Date(timeIntervalSince1970: Double(random(72) * 300))
                    return Input(lane: random(4), start: start, end: start.addingTimeInterval(Double(random(3601) - 1)),
                                 displayedStart: start.addingTimeInterval(Double(random(18) - 9) * 900))
                }
                check(items)
            }
        }
        for gap in [-1, 0, 1, 299, 300, 301] {
            let start = Date(timeIntervalSince1970: 0)
            let next = start.addingTimeInterval(900 + Double(gap))
            check([Input(lane: 0, start: start, end: start.addingTimeInterval(900), displayedStart: start),
                   Input(lane: 0, start: next, end: next, displayedStart: start.addingTimeInterval(-1200)),
                   Input(lane: 1, start: next, end: next, displayedStart: start.addingTimeInterval(-2200))])
        }

        var samples: [[String: Any]] = []
        for density in [10, 100, 300, 1000] {
            let config = CalendarFixtureConfiguration(args: ["--fixture", "varied-v1", "--density", String(density),
                                                            "--days", "7", "--seed", "20261009"])
            let store = FixtureStore(config, leadingDays: 0)
            let date = store.byDay.max { $0.value.count < $1.value.count }!.key
            let events = store.day(date)
            let plan = CalendarLanePlan.make(events.map { .init(id: $0.id, start: $0.start, end: $0.end) })
            let items = plan.filter { $0.lane < 3 }.map { placement -> Input in
                let event = events[placement.index]
                return Input(lane: placement.lane, start: event.start, end: event.end, displayedStart: event.start)
            }
            let expected = reference(items)
            for trial in 0..<13 {
                for optimized in trial.isMultiple(of: 2) ? [false, true] : [true, false] {
                    let start = ProcessInfo.processInfo.systemUptime
                    let value = optimized ? CalendarMacLaneNeighbors.make(items) : reference(items)
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    precondition(value == expected)
                    samples.append(["trial": trial, "optimized": optimized, "density": density,
                                    "events": events.count, "visiblePlacements": items.count, "ms": ms])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["parityCases": checks, "samples": samples],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination)
        print("Passed \(checks) Mac neighbor parity cases and \(samples.count) measured comparisons")
    }
}
