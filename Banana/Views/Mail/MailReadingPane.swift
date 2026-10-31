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

    var body: some View {
        VStack(spacing: 0) {
            MailPaneHeader(session: session, arrangement: arrangement, hasConversation: pane.reader != nil)
            MailDivider(axis: .horizontal)
            if let composer = navigation.composer, composer.host == nil {
                // A new message is written here, alone, with the list beside it.
                ScrollView {
                    MailComposerView(session: session, model: composer, frame: .card)
                        .id(ObjectIdentifier(composer))
                        .frame(maxWidth: DS.Mail.readingMeasure, alignment: .leading)
                        .padding(DS.Space.l)
                        .frame(maxWidth: .infinity)
                }
            } else if let reader = pane.reader {
                // A reply is written in the pane — unless a conversation is open full width over
                // it, which then holds the one composer: two editors on one draft, one of them
                // covered, were found doubling the work and taking the caret.
                MailConversationContent(session: session, reader: reader, inlineComposer: navigation.reader == nil)
                    .id(reader.id)
            } else {
                MailPaneEmpty()
            }
        }
        // A container, so the header's buttons keep their own identifiers under this one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.pane)
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
