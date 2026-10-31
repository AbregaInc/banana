import SwiftUI

/// Keep the environment Calendar stable through unrelated Smart Schedule publications. Creating
/// a fresh Foundation Calendar in App.body invalidated the entire clock grid on every status tick.
struct SyncedCalendarWeekStart: ViewModifier {
    let store: SmartScheduleStore
    @State private var calendar: Calendar

    init(store: SmartScheduleStore) {
        self.store = store
        var calendar = Calendar.current
        calendar.firstWeekday = store.settings.weekStartWeekday
        _calendar = State(initialValue: calendar)
    }

    func body(content: Content) -> some View {
        content.environment(\.calendar, calendar)
            .onReceive(store.$settings.map(\.weekStartWeekday).removeDuplicates()) { day in
                guard calendar.firstWeekday != day else { return }
                var next = calendar; next.firstWeekday = day; calendar = next
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refreshLocale() }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in refreshLocale() }
    }

    private func refreshLocale() {
        var next = Calendar.current
        next.firstWeekday = calendar.firstWeekday
        if next != calendar { calendar = next }
    }
}
