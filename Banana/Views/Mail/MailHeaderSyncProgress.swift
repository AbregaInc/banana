#if !BANANA_PUBLIC
#if os(iOS)
import SwiftUI

/// Real content work, beside the list count. Unknown mailbox sizes never become percentages.
struct MailHeaderSyncProgress: View {
    @ObservedObject var progress: MailSyncProgress
    @State private var observation: MailObservation?
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        HStack(spacing: 0) {
            // Keep the observation alive while idle; the status element itself is removed.
            Color.clear.frame(width: 0, height: 22).accessibilityHidden(true)
            if progress.value.isVisible { indicator(progress.value) }
        }
        .onAppear { if observation == nil { observation = progress.observe() } }
        .onDisappear { observation?.cancel(); observation = nil }
    }

    private func indicator(_ value: MailSyncProgress.Value) -> some View {
        HStack(spacing: 4) {
            if value.unavailable {
                Image(systemName: "exclamationmark.circle")
                if !textSize.isAccessibilitySize { Text("Unavailable") }
            } else if value.paused {
                Image(systemName: "pause.circle")
                if !textSize.isAccessibilitySize { Text("Paused") }
            } else if let fraction = value.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
                    .frame(minWidth: 24, maxWidth: 46)
                    .accessibilityIdentifier(MailID.syncFraction)
                if !textSize.isAccessibilitySize {
                    Text("\(Int((fraction * 100).rounded(.down)))%")
                }
            } else {
                Image(systemName: "arrow.down")
                if value.completed > 0 {
                    Text(value.completed.formatted(.number.notation(.compactName)))
                    if !textSize.isAccessibilitySize { Text("loaded") }
                } else if !textSize.isAccessibilitySize { Text("Checking") }
            }
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 96, minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mail sync")
        .accessibilityValue(accessibilityValue(value))
        .accessibilityIdentifier(MailID.syncProgress)
    }

    private func accessibilityValue(_ value: MailSyncProgress.Value) -> String {
        if value.unavailable { return "Progress unavailable" }
        if value.paused { return "Paused; \(value.completed) loaded, \(value.pending)\(value.pendingIsAtLeast ? "+" : "") queued" }
        if value.fraction != nil { return "\(value.completed) loaded, \(value.pending) queued" }
        return value.completed > 0 ? "\(value.completed) loaded; total still being discovered" : "Checking for mail"
    }
}
#endif
#endif
