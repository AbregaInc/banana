import SwiftUI

/// The view owns presentation only; leaving Plan or dismissing an alert cannot drop a move.
struct CalendarMoveRecoveryModifier: ViewModifier {
    let smart: SmartScheduleStore
    @ObservedObject private var recovery = CalendarMoveRecoveryStore.shared
    @State private var showing = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if !recovery.pending.isEmpty || recovery.loadError != nil {
                Button { showing = true } label: {
                    Label(recovery.loadError == nil
                          ? "Calendar moves (\(recovery.pending.count))" : "Calendar move recovery needs attention",
                          systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity).padding(8)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial)
                .accessibilityIdentifier("calendar.moveRecovery")
            }
        }
        .sheet(isPresented: $showing) {
            CalendarMoveRecoveryView(smart: smart)
        }
    }
}

private struct CalendarMoveRecoveryView: View {
    let smart: SmartScheduleStore
    @ObservedObject private var recovery = CalendarMoveRecoveryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var discarding: CalendarMoveIntent?

    var body: some View {
        NavigationStack {
            List {
                if let error = recovery.loadError {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(recovery.pending) { intent in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(intent.title).font(.headline)
                        Text("Move to \(intent.destination.formatted(date: .abbreviated, time: .shortened))")
                        if recovery.active.contains(intent.id) {
                            ProgressView("Saving…")
                        } else {
                            Text(recovery.errors[intent.id] ?? "Not yet confirmed. Retry checks the calendar before sending again.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Retry") { Task { await smart.retryMoveIntent(intent) } }
                                    .accessibilityIdentifier("calendar.moveRetry.\(intent.id)")
                                Button("Discard", role: .destructive) { discarding = intent }
                                    .accessibilityIdentifier("calendar.moveDiscard.\(intent.id)")
                            }.buttonStyle(.bordered)
                        }
                    }.padding(.vertical, 4)
                }
                if recovery.pending.isEmpty && recovery.loadError == nil {
                    Text("No pending calendar moves.")
                }
            }
            .navigationTitle("Calendar Moves")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Discard this pending move?", isPresented: Binding(
                get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
                Button("Discard move", role: .destructive) {
                    if let intent = discarding { Task { await recovery.discard(intent.id) } }
                    discarding = nil
                }
                Button("Cancel", role: .cancel) { discarding = nil }
            } message: {
                Text("This removes the saved retry. It does not undo a change already accepted by the calendar.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }
}
