#if !BANANA_PUBLIC
import SwiftUI

/// The row after the last conversation (`MailPaging.Status`): a spinner while more is on its
/// way, "No more" at the end of a list scrolled through pages, and Retry only after a failure.
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
                    Button("Retry", action: retry)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier(MailID.listRetry)
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
                    Button("Retry", action: retry)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier(MailID.listRetry)
                }
                .font(.footnote)
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: DS.Row.minHeight, maxHeight: DS.Row.minHeight)
        .accessibilityIdentifier(MailID.listStatus)
    }
}

#endif
