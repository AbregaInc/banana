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
        if bodies != retained { bodies = retained }
        self.conversation = conversation
        facts = conversation.map(MailConversationFacts.init)
        messages = conversation?.messages.map { MailMessageDisplay($0) } ?? []
        opener.update(messages)
        title = conversation.map { MailToastText.cleanSubject($0.subject) } ?? ""
        isLoading = false
        guard let conversation else { return }
        let missing = conversation.messages.map(\.id).filter { bodies[$0] == nil || bodies[$0] == .notOnDevice }
        guard !missing.isEmpty else { return }
        let source = self.source
        loading = Task { @MainActor [weak self] in
            var arrived: [MailMessageID: MailBody] = [:]
            for message in missing {
                guard !Task.isCancelled else { return }
                arrived[message] = await source.body(message)
            }
            guard !Task.isCancelled, let self, self.bodyGeneration == generation else { return }
            let updated = self.bodies.merging(arrived) { _, new in new }
            if self.bodies != updated { self.bodies = updated }
        }
    }
}

#endif
