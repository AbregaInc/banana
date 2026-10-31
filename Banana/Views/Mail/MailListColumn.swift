#if !BANANA_PUBLIC
import SwiftUI

/// The list column: its header, and the list under it. The list host is made again when the
/// place changes, because it is built on that place's feed (`.id(scope)`).
struct MailListColumn: View {
    let session: MailSession
    let arrangement: MailArrangement
    let scope: MailScope

    var body: some View {
        VStack(spacing: 0) {
            MailSearchField(session: session, scope: scope)
            MailListHeader(session: session, feed: session.feed, arrangement: arrangement, scope: scope)
            MailListHost(session: session, style: MailRowStyle(arrangement),
                         opensOnTap: arrangement.tapOpens)
                .id(scope)
                .accessibilityIdentifier(MailID.list)
                .overlay {
                    MailEmptyState(feed: session.feed, scope: scope, isSample: session.isSample) {
                        if case .search = scope.place { session.retrySearch() }
                        else { session.source.checkNow() }
                    }.id(scope)
                }
            MailHistoryNavigation(session: session, feed: session.feed, scope: scope)
        }
    }
}

private struct MailHistoryNavigation: View {
    let session: MailSession
    @ObservedObject var feed: MailListFeed
    let scope: MailScope

    var body: some View {
        if !scope.isWriting && (scope.before != nil || feed.shown.hasMore) {
            Divider()
            HStack {
                Button { session.showNewerHistory() } label: {
                    Label(session.historyBackTitle, systemImage: "chevron.left")
                        .frame(minHeight: DS.Row.minHeight)
                }
                .disabled(scope.before == nil)
                .accessibilityIdentifier("mail.history.newer")
                Spacer()
                Button { session.showOlderHistory() } label: {
                    Label("Older", systemImage: "chevron.right")
                        .frame(minHeight: DS.Row.minHeight)
                }
                .disabled(!session.canShowOlderHistory)
                .accessibilityIdentifier("mail.history.older")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, DS.Space.l)
        }
    }
}

/// The place, how many it holds, and the reading pane's toggle. With no control column the
/// place's name is a menu of places, which is how a phone changes place. It watches the feed
/// for the count: that publishes once per action, never for a cursor move.
private struct MailListHeader: View {
    let session: MailSession
    @ObservedObject var feed: MailListFeed
    let arrangement: MailArrangement
    let scope: MailScope

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            title
            if feed.shown.hasDelivered {
                Text(MailToastText.number(feed.shown.total.value) + (feed.shown.total.isAtLeast ? "+" : ""))
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { session.compose() } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New message")
            .disabled(!session.allowsComposing)
            .accessibilityIdentifier(MailID.compose)
            .help("New message (C)")
            if arrangement.canShowPane {
                Button { session.togglePane() } label: {
                    Image(systemName: arrangement.showsPane ? "rectangle.righthalf.inset.filled" : "rectangle.split.2x1")
                        .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(arrangement.showsPane ? "Hide reading pane" : "Show reading pane")
                .accessibilityIdentifier(MailID.togglePane)
                .help(arrangement.showsPane ? "Hide the reading pane (\\)" : "Show the reading pane (\\)")
            }
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.xs)
        .frame(height: DS.Mail.header)
    }

    @ViewBuilder private var title: some View {
        let name = Text(MailPlacesModel.title(of: scope)).font(.title3.weight(.semibold))
        if arrangement.showsControl {
            name
        } else {
            Menu {
                ForEach(MailPlacesModel.all) { place in
                    Button {
                        session.show(place.mailbox)
                    } label: {
                        Label(place.title, systemImage: place.mailbox == scope.mailbox ? "checkmark" : place.symbol)
                    }
                }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    name
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(MailID.placeMenu)
        }
    }
}

/// An emptied list (MAIL-UX 7.8): the place stays in front and says so.
private struct MailEmptyState: View {
    @ObservedObject var feed: MailListFeed
    let scope: MailScope
    let isSample: Bool
    var retry: () -> Void

    var body: some View {
        if case .search = scope.place {
            if !feed.shown.hasDelivered {
                ProgressView("Searching downloaded mail…")
            } else if feed.shown.remote == .failed {
                VStack { Text("Mail search couldn’t finish."); Button("Retry", action: retry) }
            } else if feed.shown.rows.isEmpty {
                ContentUnavailableView(scope.before == nil ? "No matches" : "No older matches", systemImage: "magnifyingglass",
                    description: Text("Try another word. Only downloaded headers and snippets are searched."))
            }
        } else if feed.shown.hasDelivered, feed.shown.rows.isEmpty, !isSample {
            if feed.shown.remote == .pending {
                ProgressView("Downloading mail…")
            } else if feed.shown.remote == .failed {
                VStack { Text("Mail couldn’t download."); Button("Retry", action: retry) }
            } else if scope.before != nil {
                ContentUnavailableView("No older downloaded mail", systemImage: "tray",
                    description: Text("Return to newer messages or check mail for updates."))
            } else {
                ContentUnavailableView("No downloaded mail", systemImage: "tray",
                    description: Text("Connect Google and allow Mail above. Downloaded messages will appear here."))
            }
        } else if feed.shown.hasDelivered, feed.shown.rows.isEmpty {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(DS.Palette.success)
                Text(scope.mailbox == .inbox ? "Inbox clear" : "Nothing in \(MailPlacesModel.title(of: scope))")
                    .font(.headline)
                if scope.mailbox == .inbox {
                    Text("Relaunch for a fresh sample mailbox.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// The same live filter control as Calendar, Notes and Workouts. Search scopes keep
/// the existing account and mailbox flags and continue using bounded disk-index pages.
private struct MailSearchField: View {
    let session: MailSession
    let scope: MailScope
    @State private var filter = LiveFilter(scope: "mail")
    @State private var returnScope: MailScope?

    var body: some View {
        LiveFilterSearch(scope: "mail", filter: $filter)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
            .onChange(of: filter) { _, value in
                if value.isEmpty {
                    if case .search = scope.place { session.switchTo(returnScope ?? MailSession.inbox) }
                } else {
                    if case .search = scope.place {} else { returnScope = scope }
                    session.switchTo(MailScope(place: .search(value.searchExpression), filters: scope.filters, account: scope.account))
                }
            }
            .onChange(of: scope, initial: true) { _, value in
                if case .search(let expression) = value.place {
                    let next = LiveFilter.fromSearchExpression(expression, scope: "mail") ?? LiveFilter(scope: "mail", terms: [.init(field: "text", op: "contains", value: expression)])
                    if filter != next { filter = next }
                } else if !filter.isEmpty { filter = LiveFilter(scope: "mail") }
            }
    }
}

#endif
