import Foundation

struct Fixture {
    let id: String
    let start: Date
    let end: Date

    func intersects(dayStart: Date, duration: Double, from: Double, to: Double) -> Bool {
        guard duration > 0, to > from else { return false }
        let lower = max(0, start.timeIntervalSince(dayStart) / duration)
        let upper = min(1, end.timeIntervalSince(dayStart) / duration)
        return upper > lower && upper > from && lower < to
    }
}

struct Configuration {
    let args = ProcessInfo.processInfo.arguments
    func value(_ flag: String, _ fallback: String) -> String {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
        return args[i + 1]
    }
    var candidate: String { value("--candidate", "ck") }
    var days: Int { Int(value("--days", "365"))! }
    var density: Int { Int(value("--density", "100"))! }
    var mode: String { value("--mode", "day") }
    var feed: String { value("--feed", "bounded") }
}

@MainActor
final class FixtureStore {
    var calendar = Calendar(identifier: .gregorian)
    let anchor: Date
    let byDay: [Date: [Fixture]]
    let config: Configuration
    init(_ config: Configuration) {
        self.config = config
        calendar.timeZone = .current
        anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        var rows: [Date: [Fixture]] = [:]
        for day in 0..<config.days {
            let date = calendar.date(byAdding: .day, value: day - 15, to: anchor)!
            rows[date] = (0..<config.density).map { index in
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
        let previous = calendar.date(byAdding: .day, value: -1, to: start)!
        return (byDay[previous] ?? []).filter { $0.end > start } + (byDay[start] ?? [])
    }
    func window(_ date: Date) -> [Fixture] {
        (-7...7).flatMap { day(calendar.date(byAdding: .day, value: $0, to: date)!) }
            .reduce(into: [String: Fixture]()) { $0[$1.id] = $1 }.values.sorted { $0.id < $1.id }
    }
}
