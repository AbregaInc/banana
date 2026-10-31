import SwiftUI

/// The mark on an event that has not reached a calendar yet.
///
/// Deliberately small and unobtrusive while a write is in flight — that is the common case and it
/// usually resolves in under a second, so anything louder would make the ordinary path feel
/// broken. A failure is the opposite: it stays until the user deals with it, and it has to be
/// obvious, because the event is not saved anywhere a calendar app would show it.
struct EventSyncBadge: View {
    let state: OccurrenceSyncState

    var body: some View {
        Image(systemName: state.symbolName)
            .font(.system(size: state == .failed ? 11 : 9, weight: .bold))
            .foregroundStyle(state == .failed ? Color.white : Color.secondary)
            .padding(state == .failed ? 3 : 2)
            .background {
                if state == .failed {
                    Circle().fill(DS.Palette.danger)
                }
            }
            .padding(2)
            .accessibilityLabel(state == .failed ? "Not saved" : "Saving")
            .accessibilityIdentifier("event.sync.\(state.rawValue)")
    }
}

