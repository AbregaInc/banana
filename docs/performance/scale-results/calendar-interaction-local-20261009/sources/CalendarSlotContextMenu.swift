import SwiftUI

/// Keep pointer-only state within the grid background instead of invalidating the whole week.
/// The week view preserves its original inline implementation as the matched control.
struct CalendarSlotContextMenu: ViewModifier {
    let day: Date
    let hourHeight: CGFloat
    let createEvent: (Date) -> Void
    let createReminder: (Date) -> Void
    @State private var localY: CGFloat?

    static let localObservation: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-local-hover")
        #else
        false
        #endif
    }()

    private var slot: Date? {
        localY.map { BookingGrid.snappedStart(on: day, atY: $0,
            hourHeight: hourHeight, rounding: .nearest) }
    }

    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard case .active(let point) = phase else { return }
                let snapped = BookingGrid.snappedStart(on: day, atY: point.y,
                    hourHeight: hourHeight, rounding: .nearest)
                if slot != snapped { localY = point.y }
            }
            .contextMenu {
                if let slot {
                    Button { createEvent(slot) } label: {
                        Label("New event at \(slot.formatted(.dateTime.hour().minute()))",
                              systemImage: "calendar.badge.plus")
                    }
                    Button { createReminder(slot) } label: {
                        Label("New reminder at \(slot.formatted(.dateTime.hour().minute()))",
                              systemImage: "checklist")
                    }
                }
            }
    }
}
