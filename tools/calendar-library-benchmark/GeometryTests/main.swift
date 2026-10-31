import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/New_York")!
let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
func event(_ id: String, _ start: Double, _ end: Double) -> Fixture {
    Fixture(id: id, start: day.addingTimeInterval(start), end: day.addingTimeInterval(end))
}
let boundaries = DayGeometry(date: day, calendar: calendar, events: [
    event("ends-midnight", -200, 0), event("spill", -100, 100),
    event("zero", 100, 100), event("start", 100, 200), event("next-day", 86400, 86500)])
check(Set(boundaries.placements.map(\.id)) == ["spill", "start"], "midnight clipping or empty interval incorrect")
check(boundaries.placements.allSatisfy { $0.lanes == 1 }, "touching intervals needlessly overlap")
let nested = DayGeometry(date: day, calendar: calendar, events: [event("long",0,1000),event("a",10,100),event("b",100,200)])
check(nested.placements.allSatisfy { $0.lanes == 2 }, "lane reuse must use simultaneous concurrency, not group size")
// Deterministic randomized density; compare indexed lookup with an independent full scan.
var seed: UInt64 = 1907
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed }
let events = (0..<2000).map { index -> Fixture in
    let start = Double(next() % 100000) - 8000
    let length = Double(next() % 12000) + 1
    return event(String(index), start, start + length)
}
let geometry = DayGeometry(date: day, calendar: calendar, events: events, useHeap: true)
let linear = DayGeometry(date: day, calendar: calendar, events: events, useHeap: false)
check(zip(geometry.placements, linear.placements).allSatisfy { $0.id == $1.id && $0.lane == $1.lane && $0.lanes == $1.lanes && $0.start == $1.start && $0.end == $1.end }, "heap placement differs from independent linear allocator")
check(Set(geometry.placements.map(\.id)).count == geometry.placements.count, "duplicate event placements")
for i in 0..<200 {
    let lower = Double(i) / 200
    let upper = lower + 0.071
    let expected = Set(geometry.placements.filter { $0.end > lower && $0.start < upper }.map(\.id))
    let visible = geometry.visible(from: lower, to: upper)
    check(Set(visible.map(\.id)) == expected && visible.count == expected.count, "viewport query omitted or duplicated an event")
    let preloaded = Set(events.filter { $0.intersects(dayStart: day, duration: geometry.duration, from: lower, to: upper) }.map(\.id))
    check(preloaded == expected, "viewport text preloading differs from clipped geometry")
}
for lane in Set(geometry.placements.map(\.lane)) {
    let entries = geometry.placements.filter { $0.lane == lane }.sorted { $0.start < $1.start }
    for pair in zip(entries, entries.dropFirst()) { check(pair.0.end <= pair.1.start, "overlapping events occupy same lane") }
}
for (month, date, duration) in [(3,8,82800.0), (11,1,90000.0)] {
    let start = calendar.date(from: DateComponents(year: 2026, month: month, day: date))!
    let next = calendar.date(byAdding: .day, value: 1, to: start)!
    let layout = DayGeometry(date: start, calendar: calendar, events: [Fixture(id:"whole-day",start:start,end:next)])
    check(layout.duration == duration, "DST day duration incorrect")
    check(layout.placements.first?.end == 1, "DST event truncated")
    check(Fixture(id: "whole-day", start: start, end: next).intersects(dayStart: start, duration: duration, from: 0.9, to: 1), "DST preloading omitted end of day")
}
let cache = GeometryCache(capacity: 2)
cache.put(boundaries); cache.put(nested)
check(cache.count == 1, "same date must replace geometry")
let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
cache.put(DayGeometry(date: tomorrow, calendar: calendar, events: []))
_ = cache.get(day)
let third = calendar.date(byAdding: .day, value: 2, to: day)!
cache.put(DayGeometry(date: third, calendar: calendar, events: []))
check(cache.count == 2 && cache.get(tomorrow) == nil && cache.get(day) != nil, "LRU eviction incorrect")
cache.invalidate([day])
check(cache.get(day) == nil && cache.get(third) != nil, "invalidation evicted unaffected date")
cache.clear(); check(cache.count == 0, "memory pressure did not evict cache")
print("PASS: \(checks) geometry/cache checks (viewport oracle, overlap, midnight, DST duration, bounded LRU)")
