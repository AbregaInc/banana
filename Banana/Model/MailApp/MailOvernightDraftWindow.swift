#if !BANANA_PUBLIC
import Foundation

/// A local calendar night spans midnight. The start date is also the durable scan window key.
struct MailDraftNight {
    let start: Date
    let end: Date

    static func current(at date: Date, calendar: Calendar = .current) -> Self? {
        let hour = calendar.component(.hour, from: date)
        guard hour >= 22 || hour < 6 else { return nil }
        let day = calendar.startOfDay(for: date)
        guard let evening = calendar.date(byAdding: .day, value: hour < 6 ? -1 : 0, to: day),
              let start = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: evening),
              let morning = calendar.date(byAdding: .day, value: 1, to: evening),
              let end = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: morning) else { return nil }
        return Self(start: start, end: end)
    }
}

/// One account's progress. Exhausting a page restarts at the inbox head on the next
/// pass so an arrival after the first bedtime pass is considered in the same night.
struct MailOvernightScan: Codable {
    let nightStart: Date
    var before: MailOrderKey?
    var notBefore: Date?
    var processed = Set<MailMessageID>()

    static func resume(_ data: Data?, night: MailDraftNight) -> Self {
        guard let data, let saved = try? JSONDecoder().decode(Self.self, from: data),
              saved.nightStart == night.start else { return Self(nightStart: night.start) }
        return saved
    }
}
#endif
