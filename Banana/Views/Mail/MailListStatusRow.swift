#if !BANANA_PUBLIC
import SwiftUI

/// The row after the last conversation (`MailPaging.Status`): a spinner only while a remote
/// page request is pending, "No more" after all pages, and Retry after a failure. The mere
/// availability of more mail, or a local index reading, must not look like an active transfer.
/// Both list hosts show it at the end of their content, at a fixed height, so it never changes
/// the layout of the rows above it. It observes the feed, which publishes once per applied
/// change and never for a cursor move.
struct MailListStatusRow: View {
    @ObservedObject var feed: MailListFeed
    var retry: () -> Void

    var body: some View {
        Group {
            switch feed.shown.paging {
            case .hidden where feed.shown.remote == .offline, .end where feed.shown.remote == .offline:
                // A search the device answered alone: said once, small, at the end.
                HStack(spacing: DS.Space.s) {
                    Text("Gmail couldn’t be reached").foregroundStyle(.secondary)
                    retryButton
                }
                .font(.footnote)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(MailID.searchOffline)
            case .hidden:
                Color.clear
                    .accessibilityHidden(true)
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading more mail")
            case .end:
                Text("No more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No more mail")
            case .failed:
                HStack(spacing: DS.Space.s) {
                    Text("Couldn’t load").foregroundStyle(.secondary)
                    retryButton
                }
                .font(.footnote)
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: DS.Row.minHeight, maxHeight: DS.Row.minHeight)
        .accessibilityIdentifier(MailID.listStatus)
        .onAppear { recordStatus() }
        .onChange(of: feed.shown.paging) { _, _ in recordStatus() }
    }

    private var retryButton: some View {
        Button(action: retry) {
            Text("Retry")
                .frame(minWidth: DS.Row.minHeight, minHeight: DS.Row.minHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(MailID.listRetry)
    }

    /// State changes only: no account, subject, identifier, query or provider error text.
    private func recordStatus() {
        let state: String
        switch feed.shown.paging {
        case .hidden: state = "idle"
        case .loading: state = "loading"
        case .end: state = "end"
        case .failed: state = "failed"
        }
        PlaybackDiagnostics.shared.log("mail footer",
            "state=\(state) more=\(feed.shown.hasMore ? 1 : 0) remotePending=\(feed.shown.remote == .pending ? 1 : 0)")
    }
}

#endif
