#if !BANANA_PUBLIC
import SwiftUI

/// The open conversation, full width over the columns: a header with Back and the actions, then
/// the conversation. Everything it says it has been given by `MailReaderModel`; everything it
/// does it asks the session to do.
struct MailConversationScreen: View {
    let session: MailSession
    @ObservedObject var reader: MailReaderModel
    /// A reply is written under the last message; false at a phone's width, where it is a sheet.
    let inlineComposer: Bool

    var body: some View {
        VStack(spacing: 0) {
            MailConversationHeader(session: session)
            MailDivider(axis: .horizontal)
            MailConversationContent(session: session, reader: reader, inlineComposer: inlineComposer)
        }
        // A container of its own, so that its identifier is its own: set on a bare stack it is
        // handed down to every control in it, and Back, Done and the rest lose theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.conversation)
    }
}

/// The subject and each message, scrolling: what the full-width screen and the reading pane both
/// show. It is made again for each conversation (`.id`), so a new one opens at its top.
struct MailConversationContent: View {
    /// Where a reply is written: under the last message.
    private static let foot = "mail.conversation.foot"

    let session: MailSession
    @ObservedObject var reader: MailReaderModel
    let inlineComposer: Bool
    @State private var position: ScrollPosition

    init(session: MailSession, reader: MailReaderModel, inlineComposer: Bool) {
        self.session = session
        self.reader = reader
        self.inlineComposer = inlineComposer
        _position = State(initialValue: ScrollPosition(y: reader.scrollOffset))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if reader.conversation != nil {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                            Text(reader.title)
                                .font(.title3.weight(.semibold))
                                .padding(.bottom, DS.Space.xs)
                                .accessibilityIdentifier(MailID.conversationTitle)
                            ForEach(reader.messages) { message in
                                MailMessageCard(message: message, text: reader.bodies[message.id], opener: reader.opener,
                                                load: { reader.fetchBody(message.id) })
                            }
                        }
                        // Not in the lazy stack: it must exist to be scrolled to, however far down.
                        MailReplySlot(session: session, navigation: session.navigation,
                                      conversation: reader.id, draft: reader.conversation?.draft,
                                      inline: inlineComposer) {
                            proxy.scrollTo(Self.foot, anchor: .bottom)
                        }
                        .id(Self.foot)
                    }
                    .frame(maxWidth: DS.Mail.readingMeasure, alignment: .leading)
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity)
                } else if !reader.isLoading {
                    Text("This conversation is no longer here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(DS.Space.xl)
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) {
                max(0, $0.contentOffset.y + $0.contentInsets.top).rounded()
            } action: { _, offset in
                reader.scrollOffset = offset
            }
        }
        .modifier(MailAttachmentPreviewHost(opener: reader.opener))
    }
}

/// Reply, reply to all and forward: the same three the keys open, from a menu, for a hand that has
/// no keyboard. They answer the conversation open, or the one the pane shows.
struct MailReplyMenu: View {
    let session: MailSession

    var body: some View {
        Menu {
            Button("Reply") { session.reply(.reply) }
            Button("Reply to all") { session.reply(.replyAll) }
            Button("Forward") { session.reply(.forward) }
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!session.allowsComposing)
        .accessibilityLabel("Reply")
        .accessibilityIdentifier(MailID.replyMenu)
        .help("Reply (R), reply to all (Return), forward (F)")
    }
}

/// Back, and what can be done to the conversation: older and newer, Done, star, unread. They are
/// the same actions the keys and the swipes ask for, with the open conversation as the target
/// (T15).
private struct MailConversationHeader: View {
    let session: MailSession

    var body: some View {
        // No spacing of its own: each action is already a 44-point target, and at a phone's width
        // the six of them with gaps between left Back no room for the place's name, which wrapped
        // to "In-/…". The name is one line, and truncates before it wraps.
        HStack(spacing: 0) {
            Button { session.close() } label: {
                Label(MailPlacesModel.title(of: session.scope), systemImage: "chevron.backward")
                    .lineLimit(1)
            }
            .accessibilityIdentifier(MailID.back)
            .help("Back (Esc)")
            Spacer(minLength: DS.Space.s)
            button("chevron.up", "Newer (K)", MailID.newer, enabled: session.model.canStep(.newer)) {
                session.step(.newer)
            }
            button("chevron.down", "Older (J)", MailID.older, enabled: session.model.canStep(.older)) {
                session.step(.older)
            }
            MailReplyMenu(session: session)
            button("checkmark", "Done (E)", MailID.done, enabled: session.canPerform(.done)) { session.act(.done) }
            button("star", "Star (S)", MailID.star, enabled: session.canPerform(.toggleStar)) { session.act(.toggleStar) }
            button("envelope.badge", "Mark unread (U)", MailID.unread, enabled: session.canPerform(.toggleRead)) { session.act(.toggleRead) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, DS.Space.l)
        .frame(height: DS.Mail.header)
    }

    private func button(_ symbol: String, _ label: String, _ identifier: String, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: DS.Row.minHeight, height: DS.Mail.header)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .help(label)
    }
}

/// One message: who, to whom, when, its attachments by name, and its text.
struct MailMessageCard: View {

    let message: MailMessageDisplay
    /// Nil until the body has arrived.
    let text: MailBody?
    let opener: MailAttachmentOpener

    var load: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.sender)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Text(message.date)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
            }
            Text(message.recipients)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let note = message.sampleNote {
                MailSampleChip(text: note)
            }
            if let scheduled = message.scheduled {
                MailScheduledBanner(scheduled: scheduled)
            }
            if !message.files.isEmpty {
                MailReceivedAttachments(files: message.files, opener: opener)
            }
            content
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(DS.Tint.wash),
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        switch text {
        case .text(let content, _, _)?:
            MailTextView(text: content)
        case .designed(_, _, _, let plain, _)?:
            MailTextView(text: plain)
        case .notOnDevice?, nil:
            // Never a spinner: what the row said, until the body is here.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(message.firstLine).font(.body).foregroundStyle(.secondary)
                Button("Load message", action: load)
                    .accessibilityIdentifier("mail.body.load." + message.id.message)
            }
        }
    }
}

#endif
