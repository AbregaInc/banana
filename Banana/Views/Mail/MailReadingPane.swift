#if !BANANA_PUBLIC
import SwiftUI

/// The reading pane: the conversation under the cursor, so `J` and `K` read through mail without
/// opening and closing anything. What it shows is `MailPaneModel`'s, which follows the cursor
/// once it has rested; nothing in the list reads it.
struct MailReadingPane: View {
    let session: MailSession
    @ObservedObject var pane: MailPaneModel
    @ObservedObject var navigation: MailNavigation
    let arrangement: MailArrangement
    /// An upright iPad: the subject and one "…" (`MailPaneMoreMenu`), not the row of icons.
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell

    var body: some View {
        VStack(spacing: 0) {
            if !bottomBarShell {
                MailPaneHeader(session: session, arrangement: arrangement, hasConversation: pane.reader != nil)
                // No rule under it in the shells: the approved images have none.
                if !wideShell { MailDivider(axis: .horizontal) }
            }
            if let composer = navigation.composer, composer.host == nil, !bottomBarShell, !wideShell {
                // A new message is written here, alone, with the list beside it.
                ScrollView {
                    MailComposerView(session: session, model: composer, frame: .card)
                        .id(ObjectIdentifier(composer))
                        .frame(maxWidth: DS.Mail.readingMeasure, alignment: .leading)
                        .padding(DS.Space.l)
                        .frame(maxWidth: .infinity)
                }
            } else if let composer = boxComposer, navigation.dock?.mode == .full {
                // The box at full height: the editor over the conversation.
                box(composer)
            } else {
                if let reader = pane.reader {
                    // A reply is written in the pane — unless a conversation is open full width over
                    // it, which then holds the one composer: two editors on one draft, one of them
                    // covered, were found doubling the work and taking the caret.
                    MailConversationContent(session: session, reader: reader, inlineComposer: navigation.reader == nil,
                                            titleMenu: bottomBarShell)
                        .id(reader.id)
                } else {
                    MailPaneEmpty()
                }
                if let composer = boxComposer { box(composer) }
            }
        }
        // A container, so the header's buttons keep their own identifiers under this one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.pane)
    }

    /// On an iPad on its side and the Mac the box docks at the foot of the reader (direction A): a
    /// new message, or a reply to the conversation shown, unless one is open full width over it.
    private var boxComposer: MailComposerModel? {
        guard wideShell, navigation.reader == nil, let composer = navigation.composer else { return nil }
        return composer.host == nil || composer.host == pane.reader?.id ? composer : nil
    }

    @ViewBuilder private func box(_ composer: MailComposerModel) -> some View {
        Group {
            if navigation.dock?.isFolded == true {
                MailComposerFoldedField(session: session, model: composer)
            } else {
                MailComposerBox(session: session, model: composer, navigation: navigation)
                    .frame(maxWidth: DS.Mail.readingMeasure + 2 * DS.Space.l)
            }
        }
        .id(ObjectIdentifier(composer))
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.m)
    }
}

/// What can be done to the conversation in the pane: the same actions as the keys, with the
/// cursor's conversation as the target, and the way to open it full width. With a conversation
/// open the pane is covered, so nothing here needs a Back.
private struct MailPaneHeader: View {
    let session: MailSession
    let arrangement: MailArrangement
    let hasConversation: Bool

    var body: some View {
        HStack(spacing: DS.Space.hair) {
            Spacer(minLength: 0)
            MailReplyMenu(session: session)
                .disabled(!hasConversation)
            button("checkmark", "Done (E)", MailID.done) { session.act(.done) }
                .disabled(!session.canPerform(.done))
            button("star", "Star (S)", MailID.star) { session.act(.toggleStar) }
                .disabled(!session.canPerform(.toggleStar))
            button("envelope.badge", "Mark unread (U)", MailID.unread) { session.act(.toggleRead) }
                .disabled(!session.canPerform(.toggleRead))
            button("arrow.up.left.and.arrow.down.right", "Open full width (Return)", MailID.expand) {
                if let id = session.model.cursor { session.open(id) }
            }
            if arrangement.canShowDetails {
                MailDivider(axis: .vertical).frame(height: DS.Space.l)
                Button { session.toggleDetails() } label: {
                    Image(systemName: arrangement.showsDetails ? "sidebar.trailing" : "info.circle")
                        .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(arrangement.showsDetails ? "Hide details" : "Show details")
                .accessibilityIdentifier(MailID.toggleDetails)
                .help(arrangement.showsDetails ? "Hide the details column (])" : "Show the details column (])")
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .frame(height: DS.Mail.header)
    }

    private func button(_ symbol: String, _ label: String, _ identifier: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!hasConversation)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .help(label)
    }
}

/// The reader's "…" beside the subject, on an upright iPad: what the pane's icons do (the keys do
/// the same), with the details column's toggle where there is room for it.
struct MailPaneMoreMenu: View {
    let session: MailSession
    @ObservedObject private var navigation: MailNavigation

    init(session: MailSession) {
        self.session = session
        _navigation = ObservedObject(wrappedValue: session.navigation)
    }

    var body: some View {
        Menu {
            Section {
                Button { session.reply(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { session.reply(.replyAll) } label: { Label("Reply to all", systemImage: "arrowshape.turn.up.left.2") }
                Button { session.reply(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            }
            .disabled(!session.allowsComposing)
            Section { MailSpamItems(session: session) }
            Section {
                Button { session.act(.done) } label: { Label("Archive", systemImage: "checkmark") }
                    .disabled(!session.canPerform(.done))
                    .accessibilityIdentifier(MailID.done)
                Button { session.act(.toggleStar) } label: { Label("Star", systemImage: "star") }
                    .disabled(!session.canPerform(.toggleStar))
                    .accessibilityIdentifier(MailID.star)
                Button { session.act(.toggleRead) } label: { Label("Mark unread", systemImage: "envelope.badge") }
                    .disabled(!session.canPerform(.toggleRead))
                    .accessibilityIdentifier(MailID.unread)
                MailSnoozeMenu(session: session)
            }
            Section {
                Button {
                    if let id = session.model.cursor { session.open(id) }
                } label: { Label("Open full width", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityIdentifier(MailID.expand)
                Button { session.askForDetails(toggles: true) } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .accessibilityIdentifier("mail.more.details")
                MailDiscardDraftItem(session: session)
            }
            ReportProblemMenuItem()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: DS.Row.minHeight, height: DS.Row.minHeight)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
        .accessibilityIdentifier("mail.pane.more")
    }
}

/// Every reader exposes the same durable disposal actions, including touch-only layouts.
struct MailSpamItems: View {
    let session: MailSession
    private var inSpam: Bool { session.scope.place == .mailbox(.spam) }
    private var inTrash: Bool { session.scope.place == .mailbox(.trash) }
    var body: some View {
        Button {
            session.act(inSpam ? .notSpam : .spam)
        } label: {
            Label(inSpam ? "Not spam" : "Mark as spam", systemImage: inSpam ? "tray" : "exclamationmark.shield")
        }
        .disabled(!session.canPerform(inSpam ? .notSpam : .spam))
        .accessibilityIdentifier(inSpam ? "mail.action.notSpam" : "mail.action.spam")
        Button {
            session.act(inTrash ? .restore : .trash)
        } label: {
            Label(inTrash ? "Restore" : "Move to Trash", systemImage: inTrash ? "arrow.uturn.backward" : "trash")
        }
        .disabled(!session.canPerform(inTrash ? .restore : .trash))
        .accessibilityIdentifier(inTrash ? "mail.action.restore" : "mail.action.trash")
        MailCurrentSenderBlockItem(session: session)
    }
}

struct MailCurrentSenderBlockItem: View {
    let session: MailSession
    @ObservedObject private var navigation: MailNavigation
    @ObservedObject private var pane: MailPaneModel
    init(session: MailSession) {
        self.session = session
        _navigation = ObservedObject(wrappedValue: session.navigation)
        _pane = ObservedObject(wrappedValue: session.pane)
    }
    var body: some View {
        if session.source.supportsSenderBlocking,
           let message = (navigation.reader ?? pane.reader)?.messages.first(where: { !$0.senderIsMe }),
           MailAddressRules.isValid(message.senderAddress) {
            MailBlockSenderItem(session: session, message: message)
        }
    }
}

struct MailBlockSenderItem: View {
    let session: MailSession
    let message: MailMessageDisplay
    @ObservedObject private var status: MailSenderPolicyStatus
    init(session: MailSession, message: MailMessageDisplay) {
        self.session = session; self.message = message
        _status = ObservedObject(wrappedValue: session.source.senderPolicyStatus(account: message.id.account, sender: message.senderAddress))
    }
    private var want: Bool { status.failed ? status.desiredBlocked : !(status.pending ? status.desiredBlocked : status.blocked) }
    private var title: String {
        if status.pending { return status.desiredBlocked ? "Cancel blocking" : "Cancel unblocking" }
        if status.failed { return status.desiredBlocked ? "Retry blocking sender" : "Retry unblocking sender" }
        return status.blocked ? "Unblock sender" : "Block sender"
    }
    var body: some View {
        Button {
            if want && !status.pending { session.askToBlockSender(message) } else { session.changeSenderBlock(want, message: message) }
        } label: { Label(title, systemImage: status.blocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark") }
        .disabled(status.loading || !session.canPerform(.spam))
        .accessibilityIdentifier(status.blocked ? "mail.sender.unblock" : "mail.sender.block")
    }
}

/// Dialogs belong to the persistent screen, not a menu item removed on dismissal.
struct MailSenderBlockHost: ViewModifier {
    let session: MailSession
    @ObservedObject var navigation: MailNavigation
    func body(content: Content) -> some View {
        content.confirmationDialog("Block sender?", isPresented: Binding(
            get: { navigation.senderBlockAsk != nil },
            set: { if !$0 { session.closeSenderBlockConfirmation() } }),
            titleVisibility: .visible, presenting: navigation.senderBlockAsk) { message in
                Button("Block sender", role: .destructive) { session.changeSenderBlock(true, message: message) }
                Button("Cancel", role: .cancel) {}
            } message: { message in
                Text("Future messages from \(message.senderAddress) will go to Spam. This message will also move to Spam.")
            }
            .alert("Couldn’t save sender settings", isPresented: Binding(
                get: { navigation.senderBlockFailed },
                set: { if !$0 { session.closeSenderBlockFailure() } })) {
                    Button("OK", role: .cancel) {}
                }
    }
}

/// Nothing is under the cursor: an empty place, or a place emptied.
private struct MailPaneEmpty: View {
    var body: some View {
        VStack(spacing: DS.Space.xs) {
            Image(systemName: "envelope.open")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No conversation selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
