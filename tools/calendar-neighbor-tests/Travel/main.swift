import CoreGraphics
import Foundation

private typealias Event = CalendarMobileNeighbors.Input

private enum Method: String {
    case scan, reuse, floors
}

/// Each sample includes the neighbor plan the grid builds before placing travel bands.
@inline(never)
private func travelTops(_ events: [Event], travelers: [Int], clock: CalendarDayClockGeometry,
                        method: Method) -> [CGFloat] {
    #if MAC_TRAVEL
    let neighbors = CalendarMacLaneNeighbors.make(events.map {
        .init(lane: $0.lane, start: $0.start, end: $0.end, displayedStart: $0.start)
    })
    func bottom(at index: Int) -> CGFloat {
        let row = events[index]
        let joinedEnd: Date
        if method == .scan {
            let next = events.filter { $0.lane == row.lane && $0.start >= row.end }
                .min { $0.start < $1.start }
            joinedEnd = next.flatMap { $0.start.timeIntervalSince(row.end) <= 300 ? $0.start : nil } ?? row.end
        } else {
            joinedEnd = neighbors[index].visualEnd
        }
        let dayStart = clock.calendar.startOfDay(for: clock.start)
        let dayEnd = clock.calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let start = min(max(row.start, dayStart), dayEnd)
        let clippedEnd = max(min(row.end, dayEnd), start)
        let end = max(clippedEnd, min(joinedEnd, clippedEnd.addingTimeInterval(300)))
        let height = max(22, max(900, end.timeIntervalSince(start)) / 3600 * 58)
        return max(0, min(86400, row.start.timeIntervalSince(dayStart))) / 3600 * 58 + height
    }
    #else
    let neighbors = CalendarMobileNeighbors.indexed(events)
    func bottom(at index: Int) -> CGFloat {
        let row = events[index]
        let end: Date
        if method != .scan, let neighbor = neighbors?[row.id] {
            end = neighbor.visualEnd
        } else {
            let next = events.filter { $0.id != row.id && $0.lane == row.lane && $0.start >= row.end }
                .min { $0.start < $1.start }
            end = next.flatMap { $0.start.timeIntervalSince(row.end) <= 300 ? $0.start : nil } ?? row.end
        }
        return max(clock.y(row.start) + 24, clock.y(end))
    }
    #endif

    func preferredTop(_ index: Int) -> CGFloat { clock.y(events[index].start.addingTimeInterval(-1800)) }
    if method == .floors, !travelers.isEmpty {
        let floors = CalendarTravelBandFloors.make(events.enumerated().map { index, row in
            .init(id: row.id, lane: row.lane, start: row.start, bottom: bottom(at: index))
        })
        return travelers.map { index in
            let top = preferredTop(index)
            return max(top, floors[index] ?? top)
        }
    }
    return travelers.map { index in
        let row = events[index]
        var top = preferredTop(index)
        for (otherIndex, other) in events.enumerated()
            where other.lane == row.lane && other.id != row.id && other.start < row.start {
            top = max(top, bottom(at: otherIndex))
        }
        return top
    }
}

@main
private struct TravelBenchmark {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments[1])
        let repeats = Int(arguments.dropFirst(2).first ?? "9")!
        let order: [Method] = arguments.contains("reverse") ? [.floors, .reuse, .scan] : [.scan, .reuse, .floors]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let clock = CalendarDayClockGeometry(day: day, calendar: calendar, startHour: 0, hourHeight: 56)
        var samples: [[String: Any]] = []
        var checks = 0
        for density in [10, 100, 300, 1000] {
            let fixture = CalendarFixtureConfiguration(args: [
                "--fixture", "varied-v1", "--density", String(density), "--days", "7", "--seed", "20261009"
            ])
            let store = FixtureStore(fixture, leadingDays: 0)
            let busiest = store.byDay.max { $0.value.count < $1.value.count }!.key
            let source = store.day(busiest)
            let lanes = CalendarLanePlan.make(source.map { .init(id: $0.id, start: $0.start, end: $0.end) })
            let events: [Event] = lanes.compactMap { row in
                let event = source[row.index]
                let start = day.addingTimeInterval(event.start.timeIntervalSince(busiest))
                let end = start.addingTimeInterval(event.end.timeIntervalSince(event.start))
                #if MAC_TRAVEL
                guard row.lane < 3 else { return nil }
                let span = CGFloat(row.lane)..<CGFloat(row.lane + 1)
                #else
                let width = max(24, (353 - 6 - CGFloat(row.laneCount - 1) * 2) / CGFloat(row.laneCount))
                let x = 3 + CGFloat(row.lane) * (width + 2)
                let span = x..<(x + width * CGFloat(row.laneSpan) + 2 * CGFloat(row.laneSpan - 1))
                #endif
                return Event(id: event.id, start: start, end: end, lane: row.lane, span: span, top: clock.y(start))
            }
            let counts = Set([0, 1, min(4, events.count), min(16, events.count), events.count])
            for count in counts.sorted() {
                let travelers = (0..<count).map { index in
                    min(events.count - 1, Int((Double(index) + 0.5) * Double(events.count) / Double(count)))
                }
                let expected = travelTops(events, travelers: travelers, clock: clock, method: .scan)
                for trial in 0..<repeats {
                    for index in order.indices {
                        let method = order[(trial + index) % order.count]
                        let start = ProcessInfo.processInfo.systemUptime
                        let result = travelTops(events, travelers: travelers, clock: clock, method: method)
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        precondition(result == expected)
                        samples.append(["density": density, "eventsBeforeLaneCap": source.count, "placements": events.count,
                                        "travelers": count, "method": method.rawValue, "trial": trial, "ms": elapsed])
                    }
                }
                checks += 1
            }
        }
        // Repeated identities and equal starts distinguish the greatest eligible bottom
        // from a naive prefix maximum.
        for count in 0..<64 {
            let rows = (0..<count).map { index in
                CalendarTravelBandFloors.Input(id: String((index * index + 3 * index) % 9), lane: index % 3,
                    start: day.addingTimeInterval(Double((index * 7) % 11)), bottom: CGFloat((index * 13 + 17) % 31 - 8))
            }
            let expected = rows.map { row in
                rows.filter { $0.lane == row.lane && $0.id != row.id && $0.start < row.start }.map(\.bottom).max()
            }
            precondition(expected == CalendarTravelBandFloors.make(rows))
            checks += 1
        }
        let data = try JSONSerialization.data(withJSONObject: ["checks": checks, "samples": samples], options: [.sortedKeys])
        try data.write(to: output, options: .atomic)
    }
}
