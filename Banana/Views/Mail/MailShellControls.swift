#if !BANANA_PUBLIC
import SwiftUI

// Mail's part of the wide shell's one toolbar (docs/design/BOTTOM-BAR-SHELL.md): "Inbox ⌄" with
// the places and the accounts under it, and "…" with what can be done to the conversation. The
// keys (MailKeymap) and the swipes do the same things.

/// The place showing, large, with every place and the accounts under its chevron.
struct MailPlaceTitleMenu: View {
    let session: MailSession
    @ObservedObject var navigation: MailNavigation

    init(session: MailSession) {
        self.session = session
        _navigation = ObservedObject(wrappedValue: session.navigation)
    }

    var body: some View {
        PageTitleMenu(title: MailPlacesModel.title(of: navigation.scope), identifier: MailID.placeMenu) {
            ForEach(MailPlacesModel.all) { place in
                Button { session.show(place.mailbox) } label: {
                    Label(place.title, systemImage: place.mailbox == navigation.scope.mailbox ? "checkmark" : place.symbol)
                }
            }
            if let source = session.source as? MailLiveSource {
                Menu {
                    MailAccountsMenuItems(source: source, accounts: source.accounts)
                } label: {
                    Label("Accounts", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("mail.accounts")
            }
        }
    }
}

/// "…": the conversation open or under the cursor — reply, archive, star, unread, older and newer.
struct MailActionsMenu: View {
    let session: MailSession

    var body: some View {
        Menu {
            Section {
                Button { session.reply(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { session.reply(.replyAll) } label: { Label("Reply to all", systemImage: "arrowshape.turn.up.left.2") }
                Button { session.reply(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            }
            .disabled(!session.allowsComposing)
            Section {
                Button { session.act(.done) } label: { Label("Archive", systemImage: "checkmark") }
                    .disabled(!session.canPerform(.done))
                Button { session.act(.toggleStar) } label: { Label("Star", systemImage: "star") }
                    .disabled(!session.canPerform(.toggleStar))
                Button { session.act(.toggleRead) } label: { Label("Mark unread", systemImage: "envelope.badge") }
                    .disabled(!session.canPerform(.toggleRead))
            }
            Section {
                Button { session.askForDetails(toggles: true) } label: { Label("Details", systemImage: "info.circle") }
                    .accessibilityIdentifier("mail.more.details")
                Button { session.compose() } label: { Label("New message", systemImage: "square.and.pencil") }
                    .disabled(!session.allowsComposing)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
        .accessibilityIdentifier("mail.more")
    }
}

#if os(iOS)
/// An upright iPad's one top row for Mail, over the list and the reader: the place and its count,
/// and "…" (the field and the assistant are on the bar at the bottom).
struct MailShellTopRow: View {
    let session: MailSession

    var body: some View {
        HStack(spacing: DS.Space.s) {
            MailPlaceTitleMenu(session: session)
            MailFeedCount(feed: session.feed)
            Spacer(minLength: DS.Space.m)
            MailActionsMenu(session: session)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .padding(.leading, DS.Space.m)
        .padding(.trailing, DS.Space.xs)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.xs)
    }
}

/// How many the place holds, beside its name; it watches the feed and nothing else.
private struct MailFeedCount: View {
    @ObservedObject var feed: MailListFeed

    var body: some View {
        if feed.shown.hasDelivered {
            Text(MailToastText.number(feed.shown.total.value) + (feed.shown.total.isAtLeast ? "+" : ""))
                .font(.title3).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// The wide shell's toolbar for Mail on an iPad, which draws its own: the place's title menu,
/// "Search or ask", the assistant and "…".
struct MailWideTopRow: View {
    let session: MailSession

    var body: some View {
        HStack(spacing: DS.Space.m) {
            MailPlaceTitleMenu(session: session)
                .padding(.horizontal, DS.Space.s)
                .frame(minHeight: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
            Spacer(minLength: DS.Space.m)
            ShellToolbarField()
            Spacer(minLength: DS.Space.m)
            if ShellAssistant.isAvailable {
                ShellAIButton()
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            MailActionsMenu(session: session)
                .font(.title3)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }
}
#endif
#endif
