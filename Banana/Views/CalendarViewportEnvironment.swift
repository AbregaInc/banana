import SwiftUI

private struct CalendarNativeCellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Native reusable cells have no SwiftUI scroll ancestor to report visibility.
    var calendarNativeCell: Bool {
        get { self[CalendarNativeCellKey.self] }
        set { self[CalendarNativeCellKey.self] = newValue }
    }
}

