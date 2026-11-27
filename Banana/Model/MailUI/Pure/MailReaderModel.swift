#if !BANANA_PUBLIC
import Foundation
import Combine

/// Fold only the quoted run; a signature picture after it remains visible.
enum MailQuoteFolding {
    static func hiddenRange(in blocks: [MailTextBlock], from start: Int?, expanded: Bool, entireTail: Bool = false) -> Range<Int>? {
        guard !expanded, let start, start > 0, blocks.indices.contains(start) else { return nil }
        // Local outgoing cards append the quote as a separate part with its original block styles.
        if entireTail { return start..<blocks.count }
        guard case .quote = blocks[start].kind else { return nil }
        var end = start
        while end < blocks.count {
            guard case .quote = blocks[end].kind else { break }
            end += 1
        }
        return start..<end
    }
}

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
    /// Index-aligned with each body's blocks. Opening and complex paragraphs are ready
    /// when the body appears. A nil entry is a small paragraph below the opening pages.
    private(set) var styled: [MailMessageID: [AttributedString?]] = [:]
    private(set) var timeNotes: [MailMessageID: [Int: [MailReaderTime.Note]]] = [:]
    /// What the details column says about it, prepared when the conversation arrives.
    @Published private(set) var facts: MailConversationFacts?
    /// What each message's card says above its text, and the subject as a row says it. Prepared
    /// when the conversation arrives, so no view works any of it out.
    @Published private(set) var messages: [MailMessageDisplay] = []
    @Published private(set) var title = ""
    @Published private(set) var verificationCode: MailVerificationCode?
    private struct VerificationBasis: Equatable {
        var message: MailMessageID
        var subject: String
        var body: MailBodyState
        var allowSubjectCode: Bool
    }
    private var verificationBasis: VerificationBasis?
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
        // An unsent draft belongs to the composer or the saved-draft marker, never a
        // delivered-looking message card. Keep outbox states visible for Undo and retry.
        let ordered = MailReadingOrder.newestFirst(conversation?.messages ?? [])
        let visible = ordered.filter { ($0.draft == nil && !$0.isUnsentDraft) || $0.delivery != nil }
        for message in visible { bodyStates[message.id] = message.body }
        let retained = bodies.filter { id, _ in bodyStates[id] != nil && bodyStates[id] == oldStates[id] }
        styled = styled.filter { retained[$0.key] != nil }
        timeNotes = timeNotes.filter { retained[$0.key] != nil }
        if bodies != retained { bodies = retained }
        self.conversation = conversation
        if let conversation {
            let calendar = Calendar.current, locale = Locale.current, now = Date()
            let dates = MailDateText.fullFormatter(calendar: calendar, locale: locale)
            facts = MailConversationFacts(conversation, formatDate: dates.string(from:))
            messages = visible.map {
                MailMessageDisplay($0, now: now, calendar: calendar, locale: locale,
                                   formattedDate: dates.string(from: $0.date))
            }
        } else {
            facts = nil
            messages = []
        }
        opener.update(messages)
        title = conversation.map { MailToastText.cleanSubject($0.subject) } ?? ""
        isLoading = false
        guard let conversation else {
            verificationBasis = nil
            if verificationCode != nil { verificationCode = nil }
            return
        }
        // Only the newest message can supply a code. An outgoing reply or a newer unrelated
        // message must never promote an older code from the conversation.
        let newest = ordered.first
        let eligible = newest.flatMap { message -> MailMessage? in
            guard !message.isMine, !message.from.isMe, message.draft == nil, !message.isUnsentDraft, message.delivery == nil else { return nil }
            return message
        }
        let basis = eligible.map { VerificationBasis(message: $0.id, subject: String(conversation.subject.prefix(512)), body: $0.body, allowSubjectCode: conversation.messages.count == 1) }
        if basis != verificationBasis, verificationCode != nil { verificationCode = nil }
        // In the order they are read: the newest first.
        let firstCard = visible.first?.id
        let missing = visible.map(\.id)
            .filter { bodies[$0] == nil || bodies[$0] == .notOnDevice }
        let needsCode = basis != verificationBasis || basis.map { missing.contains($0.message) } == true
        guard !missing.isEmpty || needsCode else { return }
        let cachedCodeBody = basis.flatMap { bodies[$0.message] } ?? .notOnDevice
        let source = self.source
        let dates = Dictionary(visible.map { ($0.id, $0.date) }, uniquingKeysWith: { first, _ in first })
        let read: @MainActor @Sendable () async -> Void = { [weak self] in
            var arrived: [MailMessageID: MailBody] = [:]
            if needsCode {
                if let basis {
                    let body: MailBody
                    if missing.contains(basis.message) {
                        body = await source.body(basis.message)
                        arrived[basis.message] = body
                    } else { body = cachedCodeBody }
                    let code = await Task.detached(priority: .userInitiated) {
                        MailVerificationCode.extract(subject: basis.subject, body: body, allowSubjectCode: basis.allowSubjectCode)
                            .map { MailVerificationCode(message: basis.message, value: $0) }
                    }.value
                    guard !Task.isCancelled, let self, self.bodyGeneration == generation else { return }
                    self.verificationBasis = basis
                    if self.verificationCode != code { self.verificationCode = code }
                } else { self?.verificationBasis = nil }
            }
            // Make the first card readable before a slow older body. Batch the rest so a
            // long conversation doesn't redraw for every message. The code may already
            // have read the first body; use that same value for the card.
            var remaining = missing[...]
            if missing.count > 1, missing.first == firstCard, let first = remaining.popFirst() {
                guard !Task.isCancelled else { return }
                if arrived[first] == nil { arrived[first] = await source.body(first) }
                await self?.publishBodies(arrived, dates: dates, generation: generation)
                arrived.removeAll()
            }
            for message in remaining where arrived[message] == nil {
                guard !Task.isCancelled else { return }
                arrived[message] = await source.body(message)
            }
            await self?.publishBodies(arrived, dates: dates, generation: generation)
        }
        // Start reading now instead of queueing behind the screen that is opening: the read
        // then overlaps the transition. On a physical iPhone 14 Pro this moved a prepared
        // body's first readable frame from 145 to 91 ms median after the tap (6 runs each).
        // Starting can deliver a newer conversation synchronously; only the current
        // generation keeps its task.
        let started = Task.immediate(operation: read)
        if bodyGeneration == generation { loading = started } else { started.cancel() }
    }

    /// Styles the opening of each arrived body and finds the times its text names, off the main
    /// thread, then publishes the bodies with them.
    private func publishBodies(_ arrived: [MailMessageID: MailBody], dates: [MailMessageID: Date],
                               generation: UInt64) async {
        guard !arrived.isEmpty, !Task.isCancelled, bodyGeneration == generation else { return }
        let (styledNow, notesNow) = await Task.detached(priority: .userInitiated) {
            let styled = arrived.compactMapValues { MailAttributedText.openingBlocks($0) }
            var notes: [MailMessageID: [Int: [MailReaderTime.Note]]] = [:]
            for (id, body) in arrived {
                guard let sent = dates[id] else { continue }
                let text: MailText
                let quoteStart: Int?
                switch body {
                case .text(let content, let start, _):
                    text = content
                    quoteStart = start
                case .designed(_, _, _, let plain, _):
                    text = plain
                    quoteStart = plain.blocks.firstIndex {
                        if case .quote = $0.kind { return true }
                        return false
                    }
                case .notOnDevice: continue
                }
                for (index, block) in text.blocks.prefix(min(100, quoteStart ?? 100)).enumerated()
                    where block.kind == .paragraph {
                    let found = MailReaderTime.notes(in: MailAttributedText.plain(block.runs), sent: sent)
                    if !found.isEmpty { notes[id, default: [:]][index] = found }
                }
            }
            return (styled, notes)
        }.value
        guard !Task.isCancelled, bodyGeneration == generation else { return }
        styled.merge(styledNow) { _, new in new }
        timeNotes.merge(notesNow) { _, new in new }
        let updated = bodies.merging(arrived) { _, new in new }
        if bodies != updated { bodies = updated }
        for message in arrived.keys { requestMissingBody(message) }
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
