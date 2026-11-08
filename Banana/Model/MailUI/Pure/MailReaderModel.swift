#if !BANANA_PUBLIC
import Foundation
import Combine

/// The open conversation as the reader draws it: the conversation, kept current, and each
/// message's body as the source made it. Ready bodies are reused; placeholders and changed
/// body states are re-read on notification. Reads never fetch (`MailSource.body`).
///
/// It belongs to the session, not to the reader's view, so a view tree thrown away in the
/// background does not lose the conversation (ShellNavigation's reason).
@MainActor
final class MailReaderModel: ObservableObject {
    let id: MailConversationID
    @Published private(set) var conversation: MailConversation?
    @Published private(set) var bodies: [MailMessageID: MailBody] = [:]
    /// Each body's blocks already styled (`MailAttributedText.blocks`), made off the main thread
    /// as the body arrives and published with it: drawing never styles text.
    private(set) var styled: [MailMessageID: [AttributedString]] = [:]
    /// What the details column says about it, prepared when the conversation arrives.
    @Published private(set) var facts: MailConversationFacts?
    /// What each message's card says above its text, and the subject as a row says it. Prepared
    /// when the conversation arrives, so no view works any of it out.
    @Published private(set) var messages: [MailMessageDisplay] = []
    @Published private(set) var title = ""
    /// True until the source has said whether it holds this conversation.
    @Published private(set) var isLoading = true
    /// Opening an attachment: Quick Look, and nothing else (MAIL-UX 6.2.9).
    let opener: MailAttachmentOpener

    /// Survives the view tree being discarded in the background. Not published: scrolling
    /// must not invalidate the conversation or its message cards.
    var scrollOffset: CGFloat = 0

    private let source: MailSource
    private var observation: MailObservation?
    private var loading: Task<Void, Never>?
    private var bodyGeneration: UInt64 = 0
    private var revealed = Set<MailMessageID>()
    private var automaticallyRequested = Set<MailMessageID>()
    private var bodyStates: [MailMessageID: MailBodyState] = [:]

    init(id: MailConversationID, source: MailSource) {
        self.id = id
        self.source = source
        opener = MailAttachmentOpener(source: source)
        observation = source.observeConversation(id) { [weak self] conversation in
            self?.received(conversation)
        }
    }

    /// Finishes when every body asked for so far has arrived. For tests.
    func waitForBodies() async {
        await loading?.value
    }

    /// A visible card gets one priority fetch automatically. Reappearing does not
    /// retry-loop offline failures; explicit retry remains available.
    func revealBody(_ message: MailMessageID) {
        guard conversation?.messages.contains(where: { $0.id == message }) == true else { return }
        revealed.insert(message)
        requestMissingBody(message)
    }

    private func requestMissingBody(_ message: MailMessageID) {
        guard revealed.contains(message), bodies[message] == .notOnDevice,
              automaticallyRequested.insert(message).inserted else { return }
        source.fetchBody(message)
    }

    func fetchBody(_ message: MailMessageID) {
        guard conversation?.messages.contains(where: { $0.id == message }) == true else { return }
        source.fetchBody(message)
    }

    private func received(_ conversation: MailConversation?) {
        loading?.cancel()
        loading = nil
        bodyGeneration &+= 1
        let generation = bodyGeneration
        let oldStates = bodyStates
        bodyStates.removeAll(keepingCapacity: true)
        for message in conversation?.messages ?? [] { bodyStates[message.id] = message.body }
        let retained = bodies.filter { id, _ in bodyStates[id] != nil && bodyStates[id] == oldStates[id] }
        styled = styled.filter { retained[$0.key] != nil }
        if bodies != retained { bodies = retained }
        self.conversation = conversation
        facts = conversation.map(MailConversationFacts.init)
        messages = MailReadingOrder.newestFirst(conversation?.messages ?? []).map { MailMessageDisplay($0) }
        opener.update(messages)
        title = conversation.map { MailToastText.cleanSubject($0.subject) } ?? ""
        isLoading = false
        guard let conversation else { return }
        // In the order they are read: the newest first.
        let missing = MailReadingOrder.newestFirst(conversation.messages).map(\.id)
            .filter { bodies[$0] == nil || bodies[$0] == .notOnDevice }
        guard !missing.isEmpty else { return }
        let source = self.source
        loading = Task { @MainActor [weak self] in
            var arrived: [MailMessageID: MailBody] = [:]
            for message in missing {
                guard !Task.isCancelled else { return }
                arrived[message] = await source.body(message)
            }
            let ready = arrived
            let styledNow = await Task.detached(priority: .userInitiated) {
                ready.compactMapValues { MailAttributedText.blocks($0) }
            }.value
            guard !Task.isCancelled, let self, self.bodyGeneration == generation else { return }
            self.styled.merge(styledNow) { _, new in new }
            let updated = self.bodies.merging(arrived) { _, new in new }
            if self.bodies != updated { self.bodies = updated }
            for message in arrived.keys { self.requestMissingBody(message) }
        }
    }
}

/// The order an open conversation is read in: the newest message at the top, then the older ones
/// going down (the owner's ruling of 7 Nov 2026). By date, newest first; messages sent at the same
/// moment keep the later-arrived one above.
enum MailReadingOrder {
    static func newestFirst(_ messages: [MailMessage]) -> [MailMessage] {
        messages.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset > $1.offset }
            .map(\.element)
    }
}

#endif
