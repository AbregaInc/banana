#if !BANANA_PUBLIC
import SwiftUI

/// The open conversation, full width over the columns: a header with Back and the actions, then
/// the conversation. Everything it says it has been given by `MailReaderModel`; everything it
/// does it asks the session to do.
struct MailConversationScreen: View {
    let session: MailSession
    @ObservedObject var reader: MailReaderModel
    /// A reply is written above the newest message; false at a phone's width, where it is a sheet.
    let inlineComposer: Bool
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell
    @ObservedObject private var navigation: MailNavigation

    init(session: MailSession, reader: MailReaderModel, inlineComposer: Bool) {
        self.session = session
        self.reader = reader
        self.inlineComposer = inlineComposer
        _navigation = ObservedObject(wrappedValue: session.navigation)
    }

    var body: some View {
        VStack(spacing: 0) {
            MailConversationHeader(session: session)
            // The shells' top row floats on glass with no rule under it (the approved images).
            if !bottomBarShell && !wideShell { MailDivider(axis: .horizontal) }
            if wideShell, let composer = navigation.composer, composer.answers == reader.id {
                // The box at the foot of the conversation (direction A), or over it at full height.
                if navigation.dock?.mode != .full {
                    MailConversationContent(session: session, reader: reader, inlineComposer: inlineComposer)
                }
                Group {
                    if navigation.dock?.isFolded == true {
                        MailComposerFoldedField(session: session, model: composer)
                    } else {
                        MailComposerBox(session: session, model: composer, navigation: navigation)
                    }
                }
                .id(ObjectIdentifier(composer))
                .padding(.horizontal, DS.Space.m)
                .padding(.bottom, DS.Space.m)
            } else {
                MailConversationContent(session: session, reader: reader, inlineComposer: inlineComposer)
            }
        }
        // A container of its own, so that its identifier is its own: set on a bare stack it is
        // handed down to every control in it, and Back, Done and the rest lose theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.conversation)
    }
}

/// The subject and each message, newest first (`MailReadingOrder`), scrolling: what the
/// full-width screen and the reading pane both show. It is made again for each conversation
/// (`.id`), so a new one opens at its top, on the newest message.
struct MailConversationContent: View {
    /// Where a reply is written: under the subject, above the newest message it answers.
    private static let replySlot = "mail.conversation.replySlot"

    let session: MailSession
    @ObservedObject var reader: MailReaderModel
    let inlineComposer: Bool
    /// "…" beside the subject, in place of the pane's row of icons (an upright iPad's reader).
    var titleMenu = false
    @State private var position: ScrollPosition
    /// Where the thread was when his finger went down on it, while it is down.
    @State private var pullStart: CGFloat?
    /// He moved the thread himself while the box was open: it stays where he put it.
    @State private var movedWhileAnswering = false
    /// In the bar's shells, pulling the thread down to read folds the composer's box into the field.
    @Environment(\.bottomBarShell) private var bottomBarShell

    init(session: MailSession, reader: MailReaderModel, inlineComposer: Bool, titleMenu: Bool = false) {
        self.session = session
        self.reader = reader
        self.inlineComposer = inlineComposer
        self.titleMenu = titleMenu
        _position = State(initialValue: ScrollPosition(y: reader.scrollOffset))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if reader.conversation != nil {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                            Text(reader.title)
                                .font(.title3.weight(.semibold))
                                .accessibilityIdentifier(MailID.conversationTitle)
                            if titleMenu {
                                Spacer(minLength: DS.Space.s)
                                MailPaneMoreMenu(session: session)
                            }
                        }
                        .padding(.bottom, DS.Space.xs)
                        if let invite = reader.conversation?.invite, invite.method == .request {
                            MailInviteCard(account: reader.id.account, invite: invite,
                                           calendar: session.isSample ? .sample : .live)
                        }
                        // A reply (or the draft left here) above the newest message, which it
                        // answers and which is read first.
                        MailReplySlot(session: session, navigation: session.navigation,
                                      conversation: reader.id, draft: reader.conversation?.draft,
                                      inline: inlineComposer) {
                            proxy.scrollTo(Self.replySlot, anchor: .top)
                        }
                        .id(Self.replySlot)
                        LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                            ForEach(reader.messages) { message in
                                MailMessageCard(message: message, text: reader.bodies[message.id], styled: reader.styled[message.id], opener: reader.opener,
                                                load: { reader.fetchBody(message.id) })
                                    .onAppear { reader.revealBody(message.id) }
                                    .id(message.id)
                            }
                        }
                    }
                    // Message text fills the pane, as in Apple Mail and Gmail: no reading-measure cap.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.l)
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
            // The box answering this conversation takes the foot of the pane (and the keyboard
            // more of it): the thread is inset by both, and the message answered — the newest, at
            // the top — is brought up to show as much of itself as fits above the box, its top first.
            .onScrollGeometryChange(for: CGFloat.self) {
                ($0.containerSize.height - $0.contentInsets.top - $0.contentInsets.bottom).rounded()
            } action: { _, _ in
                showAnswered(proxy)
            }
            .onAppear { DispatchQueue.main.async { showAnswered(proxy) } }
            .onScrollPhaseChange { _, phase, context in
                if phase == .interacting, answering { movedWhileAnswering = true }
                #if os(iOS)
                pullStart = phase == .interacting ? context.geometry.contentOffset.y : nil
                #endif
            }
            #if os(iOS)
            .scrollDismissesKeyboard(bottomBarShell ? .interactively : .automatic)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                // His finger pulled the thread down (towards its top, or past it): the box folds.
                // Reading on, up the thread, leaves it where it is.
                guard bottomBarShell, let start = pullStart, start - y > 24 else { return }
                pullStart = nil
                session.dock(.threadDraggedDown)
            }
            #endif
        }
        .modifier(MailAttachmentPreviewHost(opener: reader.opener))
        .modifier(ProvidesMailReport(reader: reader, source: session.source))
    }

    /// Whether the composer's box is open, not folded, on an answer to this conversation. Read when
    /// the room changes, not observed: the thread does not redraw for the composer.
    private var answering: Bool {
        let navigation = session.navigation
        guard let dock = navigation.dock, !dock.isFolded, let composer = navigation.composer else { return false }
        return composer.answers == reader.id
    }

    private func showAnswered(_ proxy: ScrollViewProxy) {
        guard answering else {
            movedWhileAnswering = false
            return
        }
        guard !movedWhileAnswering, let newest = reader.messages.first?.id else { return }
        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(newest, anchor: .top) }
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
    /// The bottom-bar shell: Back, and the rest under one "…"; Archive and Reply are on the bar.
    @Environment(\.bottomBarShell) private var bottomBarShell

    var body: some View {
        if bottomBarShell { shellRow } else { classicRow }
    }

    /// Back with the place's name, and "…": older and newer, reply, star, unread, archive.
    private var shellRow: some View {
        HStack(spacing: 0) {
            Button { session.close() } label: {
                Label(MailPlacesModel.title(of: session.scope), systemImage: "chevron.backward")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: DS.Row.minHeight)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.accent)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityIdentifier(MailID.back)
            Spacer(minLength: DS.Space.s)
            Menu {
                Section {
                    Button { session.step(.newer) } label: { Label("Newer", systemImage: "chevron.up") }
                        .disabled(!session.model.canStep(.newer))
                        .accessibilityIdentifier(MailID.newer)
                    Button { session.step(.older) } label: { Label("Older", systemImage: "chevron.down") }
                        .disabled(!session.model.canStep(.older))
                        .accessibilityIdentifier(MailID.older)
                }
                Section {
                    Button { session.reply(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    Button { session.reply(.replyAll) } label: { Label("Reply to all", systemImage: "arrowshape.turn.up.left.2") }
                    Button { session.reply(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                }
                .disabled(!session.allowsComposing)
                Section {
                    Button { session.act(.toggleStar) } label: { Label("Star", systemImage: "star") }
                        .disabled(!session.canPerform(.toggleStar))
                        .accessibilityIdentifier(MailID.star)
                    Button { session.act(.toggleRead) } label: { Label("Mark unread", systemImage: "envelope.badge") }
                        .disabled(!session.canPerform(.toggleRead))
                        .accessibilityIdentifier(MailID.unread)
                    Button { session.act(.done) } label: { Label("Archive", systemImage: "checkmark") }
                        .disabled(!session.canPerform(.done))
                        .accessibilityIdentifier(MailID.done)
                    MailSnoozeMenu(session: session)
                }
                MailDiscardDraftItem(session: session)
                Button { session.askForDetails(toggles: true) } label: { Label("Details", systemImage: "info.circle") }
                    .accessibilityIdentifier("mail.more.details")
                Divider()
                ReportProblemMenuItem()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: DS.Row.minHeight, height: DS.Row.minHeight)
                    .contentShape(Circle())
            }
            .menuIndicator(.hidden)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("More")
            .accessibilityIdentifier("mail.reader.more")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.xs)
    }

    private var classicRow: some View {
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
    var styled: [AttributedString]? = nil
    let opener: MailAttachmentOpener

    var load: () -> Void = {}
    @Environment(\.mailSession) private var session
    @State private var showsOriginal = false

    private var hasOriginal: Bool {
        switch text {
        case .text(_, _, let notices)?: return notices.contains(.shownAsText)
        case .designed?: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                MailFaceView(face: message.face, size: DS.Mail.face)
                header
            }
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
        .sheet(isPresented: $showsOriginal) {
            MailOriginalSheet {
                try await session?.source.originalHTML(message.id)
            }
        }
    }

    /// Who and when, then to whom and Original: two lines beside the face.
    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            HStack(alignment: .firstTextBaseline) {
                // The sender opens the conversation's Details, as "…" › Details does.
                Button { session?.askForDetails(toggles: false) } label: {
                    Text(message.sender)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(session == nil)
                .accessibilityHint("Shows the details")
                .accessibilityIdentifier("mail.sender." + message.id.message)
                Spacer(minLength: DS.Space.s)
                Text(message.date)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
            }
            HStack {
                Text(message.recipients)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if hasOriginal {
                    Button("Original") { showsOriginal = true }
                        .font(.caption)
                        .accessibilityIdentifier("mail.body.original." + message.id.message)
                }
            }
        }
    }

    /// A picture that is a part of this message loads from the stored parts.
    private var pictureContext: MailPictureContext {
        let source = session?.source, id = message.id
        return MailPictureContext(account: id.account) { part in
            let safe = part.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.-_+=")))
            guard let safe, let url = URL(string: "cid:" + safe), let source else { return nil }
            return await source.resource(url, for: id, presentation: .onScreen)?.data
        }
    }

    @ViewBuilder private var content: some View {
        switch text {
        case .text(let content, let quoteStart, _)?:
            MailTextView(text: content, styled: styled, foldFrom: quoteStart)
                .environment(\.mailPictureContext, pictureContext)
        case .designed(_, _, _, let plain, _)?:
            MailTextView(text: plain, styled: styled)
        case .notOnDevice?, nil:
            // Never a spinner: what the row said, until the body is here.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(message.firstLine).font(.body).foregroundStyle(.secondary)
                Button("Retry loading", action: load)
                    .accessibilityIdentifier("mail.body.load." + message.id.message)
            }
        }
    }
}

#endif
