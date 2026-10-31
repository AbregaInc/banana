import Foundation

struct Fixture {
    let id: String
    let start: Date
    let end: Date
    var title: String? = nil
    var calendarIndex: Int = 0

    func intersects(dayStart: Date, duration: Double, from: Double, to: Double) -> Bool {
        guard duration > 0, to > from else { return false }
        let lower = max(0, start.timeIntervalSince(dayStart) / duration)
        let upper = min(1, end.timeIntervalSince(dayStart) / duration)
        return upper > lower && upper > from && lower < to
    }
}

struct CalendarFixtureConfiguration {
    let args: [String]
    init(args: [String] = ProcessInfo.processInfo.arguments) { self.args = args }
    func value(_ flag: String, _ fallback: String) -> String {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
        return args[i + 1]
    }
    var candidate: String { value("--candidate", "ck") }
    var days: Int { Int(value("--days", "365"))! }
    var density: Int { Int(value("--density", "100"))! }
    var mode: String { value("--mode", "day") }
    var feed: String { value("--feed", "bounded") }
    var fixture: String { value("--fixture", "uniform-v1") }
    var seed: UInt64 { UInt64(value("--seed", "20261009"))! }
    var calendarCount: Int { fixture == "uniform-v1" ? 1 : 12 }
    var hiddenCalendars: Set<Int> {
        Set(value("--hidden-calendars", "").split(separator: ",").map { Int($0)! })
    }
}

@MainActor
final class FixtureStore {
    var calendar = Calendar(identifier: .gregorian)
    let anchor: Date
    let byDay: [Date: [Fixture]]
    let config: CalendarFixtureConfiguration
    init(_ config: CalendarFixtureConfiguration, anchor requestedAnchor: Date? = nil, leadingDays: Int = 15) {
        self.config = config
        precondition(["uniform-v1", "varied-v1"].contains(config.fixture))
        precondition(config.days > 0 && config.density > 0)
        precondition(config.hiddenCalendars.allSatisfy { (0..<config.calendarCount).contains($0) })
        calendar.timeZone = .current
        anchor = requestedAnchor ?? calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        var rows: [Date: [Fixture]] = [:]
        var volumes = Array(repeating: config.density, count: config.days)
        if config.fixture == "varied-v1" {
            // Preserve total retained volume and each seven-day block's volume,
            // while varying busy/quiet days and the concentration of weekly work.
            var volumeRandom = FixtureRandom(state: config.seed ^ 0x564f4c554d45)
            for first in stride(from: 0, to: config.days, by: 7) {
                let count = min(7, config.days - first), total = count * config.density
                let weights = (0..<count).map { offset in
                    Double([8, 12, 10, 14, 9, 3, 2][offset] + Int(volumeRandom.next() % 7))
                }
                let sum = weights.reduce(0, +)
                let exact = weights.map { Double(total) * $0 / sum }
                var allocated = exact.map { Int($0.rounded(.down)) }
                let order = (0..<count).sorted {
                    let lhs = exact[$0] - Double(allocated[$0]), rhs = exact[$1] - Double(allocated[$1])
                    return lhs == rhs ? $0 < $1 : lhs > rhs
                }
                for offset in order.prefix(total - allocated.reduce(0, +)) { allocated[offset] += 1 }
                for offset in 0..<count { volumes[first + offset] = allocated[offset] }
            }
        }
        for day in 0..<config.days {
            let date = calendar.date(byAdding: .day, value: day - leadingDays, to: anchor)!
            var random = FixtureRandom(state: config.seed &+ UInt64(day) &* 0x9e3779b97f4a7c15)
            rows[date] = (0..<volumes[day]).map { index in
                if config.fixture == "varied-v1" {
                    let calendarIndex = (index + day) % config.calendarCount
                    // Different overlap topology daily: broad, office-hour, clustered,
                    // overnight and long-duration cases. Keep total history volume unchanged.
                    let minute: Int
                    switch day % 4 {
                    case 0: minute = Int(random.next() % 1440)
                    case 1: minute = 7 * 60 + Int(random.next() % 660)
                    case 2: minute = [8 * 60, 12 * 60, 17 * 60][Int(random.next() % 3)] + Int(random.next() % 90)
                    default: minute = Int(random.next() % 1440)
                    }
                    let durations = [5, 15, 25, 30, 45, 60, 90, 120, 180, 480, 1440, 2160]
                    let duration = durations[Int(random.next() % UInt64(durations.count))]
                    let titles = ["Design review", "Planning: next release and dependencies", "Café with Renée",
                        "顧客との打ち合わせ", "Project retrospective — decisions and follow-up owners",
                        "Family appointment", "مراجعة المشروع", "Travel and connections", "Focus time",
                        "Release readiness: testing, rollout, support and incident response"]
                    let base = titles[Int(random.next() % UInt64(titles.count))]
                    let title = "\(FixtureCalendar.names[calendarIndex]): \(base) · \(day)-\(index)"
                    let start = date.addingTimeInterval(Double(minute * 60))
                    return Fixture(id: "\(day)-\(index)", start: start,
                        end: start.addingTimeInterval(Double(duration * 60)), title: title, calendarIndex: calendarIndex)
                }
                // Same daily density across histories. Spread over 24h, with overlapping events
                // and 24h events every tenth item, matching the app's stress fixture pattern.
                let start = date.addingTimeInterval(Double(index % 100) * 600)
                return Fixture(id: "\(day)-\(index)", start: start,
                               end: start.addingTimeInterval(index.isMultiple(of: 10) ? 86400 : 1800))
            }
        }
        byDay = rows
    }
    func day(_ date: Date) -> [Fixture] {
        let start = calendar.startOfDay(for: date)
        // Varied timed events may span up to 36 hours; preserve the original one-day
        // lookback for the frozen uniform workload.
        let lookback = config.fixture == "varied-v1" ? 2 : 1
        let prior = (1...lookback).reversed().flatMap { offset in
            (byDay[calendar.date(byAdding: .day, value: -offset, to: start)!] ?? []).filter { $0.end > start }
        }
        let rows = prior + (byDay[start] ?? [])
        let hidden = config.hiddenCalendars
        return hidden.isEmpty ? rows : rows.filter { !hidden.contains($0.calendarIndex) }
    }
    func window(_ date: Date) -> [Fixture] {
        (-7...7).flatMap { day(calendar.date(byAdding: .day, value: $0, to: date)!) }
            .reduce(into: [String: Fixture]()) { $0[$1.id] = $1 }.values.sorted { $0.id < $1.id }
    }
    var fixtureSummary: [String: Any] {
        var checksum = FixtureDigest(), patterns: [UInt64] = []
        var calendarCounts: [String: Int] = [:], durationKinds = Set<Int>()
        var titles = Set<String>()
        for date in byDay.keys.sorted() {
            var shape = FixtureDigest()
            for event in byDay[date]! {
                let start = Int(event.start.timeIntervalSince(date))
                let duration = Int(event.end.timeIntervalSince(event.start))
                shape.add("\(start)/\(duration)/\(event.calendarIndex)")
                checksum.add("\(event.id)/\(event.start.timeIntervalSince1970)/\(duration)/\(event.calendarIndex)/\(event.title ?? "")")
                calendarCounts[String(event.calendarIndex), default: 0] += 1
                durationKinds.insert(duration); titles.insert(event.title ?? "Event \(event.id)")
            }
            patterns.append(shape.value)
        }
        var weekPatterns = Set<UInt64>()
        for start in stride(from: 0, to: max(0, patterns.count - 6), by: 7) {
            var digest = FixtureDigest()
            for value in patterns[start..<start+7] { digest.add(String(value)) }
            weekPatterns.insert(digest.value)
        }
        return ["profile": config.fixture, "seed": String(config.seed),
            "calendarCount": config.calendarCount, "calendarEventCounts": calendarCounts,
            "hiddenCalendars": config.hiddenCalendars.sorted(), "retainedEvents": config.days * config.density,
            "minimumDailyEvents": byDay.values.map(\.count).min() ?? 0,
            "maximumDailyEvents": byDay.values.map(\.count).max() ?? 0,
            "meanDailyEvents": config.density, "sevenDayBlockEvents": config.density * 7,
            "distinctDailyPatterns": Set(patterns).count, "distinctWeeklyPatterns": weekPatterns.count,
            "distinctDurations": durationKinds.count, "distinctTitles": titles.count,
            "contentChecksum": String(checksum.value, radix: 16),
            "scope": "Immutable timed-event fixture; no recurrence expansion, provider sync or dynamic edit/filter invalidation"]
    }
}

// Fixed PRNG, independent of Swift's randomized Hasher and generation order.
struct FixtureRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

enum FixtureCalendar {
    static let names = ["Work", "Personal", "Family", "Engineering", "Design", "Customers",
                        "Travel", "Community", "Health", "Learning", "Operations", "Projects"]
}

struct FixtureDigest {
    private(set) var value: UInt64 = 14695981039346656037
    mutating func add(_ text: String) {
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        value = (value ^ 255) &* 1099511628211
    }
}
