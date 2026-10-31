import SwiftUI

/// One actionable element per rendered event, with explicit state instead of merged child labels.
/// The default semantics remain stable when narrow columns hide their decorative icons.
struct CalendarEventAccessibility: ViewModifier {
    let occurrence: Occurrence
    let timeRange: String
    let activate: () -> Void

    static let enabled: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-reference-mac-event-accessibility")
        #else
        true
        #endif
    }()

    private var state: String {
        var parts: [String] = []
        if occurrence.completed { parts.append("Completed") }
        else if occurrence.behavior == .task { parts.append("Incomplete") }
        if occurrence.skipped { parts.append("Skipped") }
        if occurrence.isOverdueReminder { parts.append("Overdue") }
        if occurrence.showsAsFree { parts.append("Free") }
        switch occurrence.meeting?.myResponse {
        case .tentative?: parts.append("Tentative")
        case .needsAction?: parts.append("Reply needed")
        default: break
        }
        if occurrence.meeting?.othersAllDeclined == true { parts.append("Everyone else declined") }
        switch occurrence.syncState {
        case .syncing?: parts.append("Saving")
        case .failed?: parts.append("Save failed, retry available")
        case nil: break
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder func body(content: Content) -> some View {
        if Self.enabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(occurrence.title), \(timeRange)")
                .accessibilityValue(state)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate() }
                .accessibilityIdentifier("mac.week.occurrence.\(occurrence.id)")
        } else {
            content
                .accessibilityLabel("\(occurrence.title), \(timeRange)")
                .accessibilityIdentifier("mac.week.occurrence.\(occurrence.id)")
        }
    }
}
