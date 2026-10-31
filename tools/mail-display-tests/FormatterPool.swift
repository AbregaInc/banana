import Foundation

/// Experiment: bounded reuse of immutable native formatters. Not yet shipping.
final class MailDateFormatterPool: @unchecked Sendable {
    static let shared = MailDateFormatterPool()
    private struct Key: Hashable {
        let template: String
        let calendar: Calendar
        let locale: Locale
    }
    private let lock = NSLock()
    private var entries: [Key: DateFormatter] = [:]
    private var order: [Key] = []
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    let capacity = 32

    init(center: NotificationCenter = .default) {
        self.center = center
        for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.clear()
            })
        }
    }
    deinit { for observer in observers { center.removeObserver(observer) } }
    func clear() {
        lock.withLock { entries.removeAll(keepingCapacity: true); order.removeAll(keepingCapacity: true) }
    }
    var retainedCount: Int { lock.withLock { entries.count } }

    func string(_ template: String, _ date: Date, _ calendar: Calendar, _ locale: Locale) -> String {
        let key = Key(template: template, calendar: calendar, locale: locale)
        let formatter: DateFormatter = lock.withLock {
            if let existing = entries[key] { return existing }
            let made = DateFormatter()
            made.locale = locale
            made.calendar = calendar
            made.timeZone = calendar.timeZone
            made.setLocalizedDateFormatFromTemplate(template)
            if order.count == capacity { entries.removeValue(forKey: order.removeFirst()) }
            order.append(key)
            entries[key] = made
            return made
        }
        // No settings mutate after insertion. Native formatting is thread-safe on supported
        // iOS/macOS; the bookkeeping lock is not held while a string is generated.
        return formatter.string(from: date)
    }
}
