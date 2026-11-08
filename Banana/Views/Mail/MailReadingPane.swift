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
