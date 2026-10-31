#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation

/// Drafts and sending, in memory, for the sample mailbox: what the contract's "Drafts and sending"
/// members say, kept as small as a screen that writes mail needs.
///
/// **Nothing is ever sent.** A send adds the message to its conversation, marked as a sample
/// (`MailFixtureSource.sampleMark` in its id, which the card turns into words), holds it for the
/// undo hold as the contract says, and then lets it go: nowhere. A draft is a value in a
/// dictionary, and resets with the rest of the sample mail when Banana relaunches.
///
/// The marker a kept reply leaves — the conversation's `draft` and its row's reason line — is
/// published when what it says changes, and not on a save that changes nothing it says.
extension MailFixtureSource {

    /// The undo hold until Settings says otherwise (MAIL-UX 6.3.7), which is what `hold: nil` means.
    nonisolated static let defaultHold: TimeInterval = 10

    /// In the id of every message this source "sends", between the thread and its number.
    nonisolated static let sampleMark = MailMessageDisplay.sampleMark

    /// What a send did, until its hold ends: enough to take it back, and to say when it is over.
    struct HeldSend {
        var draft: MailDraft
        var receipt: MailReceipt
        var message: MailMessageID
        /// Where the sent message is: the conversation it answers, or one of its own.
        var target: MailConversationID
        /// The message made a conversation of its own: a new message, or a forward.
        var ownsConversation: Bool
        /// The conversation the draft was written in, and as it was before the send, or nil for a
        /// new message, which was written in none.
        var touched: MailConversationID?
        var previous: Stored?
        /// That conversation once the message has gone and before any Done: what Undo puts back
        /// when only the Done is left to undo.
        var afterSend: Stored?
        var until: Date
        var thenDone: Bool
        /// Waiting for a time he chose (`MailFixtureSource+Schedule.swift`): `until` is that time.
        var isScheduled = false
        /// A scheduled message whose time passed unsent: it asks, and is never sent unasked.
        var isLate = false
    }

    // MARK: - Making and keeping a draft

    func newDraft(_ kind: MailDraftKind) async -> MailDraft {
        draftNumber += 1
        let id = MailDraftID(raw: "draft-\(draftNumber)")
        var identity = accounts[0].identities[0]
        let mine = Set(accounts.flatMap(\.identities).map { $0.address.lowercased() })
        var draft = MailDraft(
            id: id, conversation: MailConversationID(account: identity.account, thread: "local:" + id.raw),
            account: identity.account, isReply: false, isForward: false, from: identity,
            to: [], cc: [], bcc: [], subject: "", body: MailText(blocks: []), signature: nil, quote: nil,
            attachments: [], format: .banana, schedule: nil, remindIfNoReply: nil, delivery: nil,
            encodedBytes: 0, editedAt: clock())
        defer { drafts[id] = draft }
        switch kind {
        case .new:
            break
        case .toAddress(let addresses, let subject):
            draft.to = addresses.map { Self.person(address: $0) }
            draft.subject = subject ?? ""
        case .reply(let message), .replyAll(let message), .forward(let message):
            guard let found = original(message) else { break }
            // An answer is from the address the message was sent to (MAIL-UX 6.3.3).
            if let sentTo = found.message.deliveredTo?.lowercased(), let match = Self.identity(address: sentTo) {
                identity = match
                draft.from = match
            }
            let isForward: Bool
            if case .forward = kind { isForward = true } else { isForward = false }
            let recipients = MailReplyRules.recipients(for: kind, original: found.message, myAddresses: mine)
            // A forward is a conversation of its own once it is sent, but it is written where the
            // original is, and so it is that conversation's draft.
            draft.conversation = found.stored.conversation.id
            draft.isReply = !isForward
            draft.isForward = isForward
            draft.to = recipients.to
            draft.cc = recipients.cc
            draft.subject = MailReplyRules.subject(for: kind, original: found.stored.conversation.subject)
            draft.quote = quote(of: found.message, forward: isForward, subject: found.stored.conversation.subject)
            // A forward carries what the message had; a reply carries nothing (MailFixtureSource+Attachments).
            if isForward {
                draft.attachments = await forwardedAttachments(of: found.message, in: id)
                draft.encodedBytes = Self.encodedBytes(of: draft)
            }
        }
        draft.signature = signature(for: identity)
        return draft
    }

    func draft(_ id: MailDraftID) async -> MailDraft? {
        drafts[id]
    }

    func save(_ draft: MailDraft) {
        guard drafts[draft.id] != nil, held[draft.id] == nil else { return }
        drafts[draft.id] = draft
        kept.insert(draft.id)
        let told = mark(draft, shown: true)
        publishDraftsIfChanged(draft, alreadyTold: told)
    }

    /// Puts the draft's mark on its conversation, or takes it off, and says so to whoever is
    /// watching only when the words it makes have changed.
    @discardableResult
    func mark(_ draft: MailDraft, shown: Bool) -> Bool {
        guard var stored = threads[draft.conversation] else { return false }
        let id: MailDraftID? = shown ? draft.id : nil
        let reason: MailRowReason? = shown
            ? .draft(firstLine: MailPlainText.firstLine(MailPlainText.string(draft.body))) : nil
        var changed = false
        if stored.conversation.draft != id {
            stored.conversation.draft = id
            changed = true
        }
        // A row's reason line is one thing at a time: only a draft's is this one's to change.
        let isDraftReason: Bool
        switch stored.row.reason {
        case nil, .draft?: isDraftReason = true
        default: isDraftReason = false
        }
        if isDraftReason, stored.row.reason != reason {
            stored.row.reason = reason
            changed = true
        }
        guard changed else { return false }
        threads[draft.conversation] = stored
        publish()
        return true
    }

    @discardableResult
    func discard(_ id: MailDraftID) -> MailReceipt {
        sequence += 1
        guard let draft = drafts[id], held[id] == nil else {
            return MailReceipt(sequence: sequence, count: 0)
        }
        if let stored = threads[draft.conversation] { before[sequence] = [stored] }
        discarded[sequence] = draft
        drafts[id] = nil
        let wasListed = kept.remove(id) != nil
        draftLines[id] = nil
        mark(draft, shown: false)
        if wasListed { publish() }
        return MailReceipt(sequence: sequence, count: 1)
    }

    // MARK: - People

    func people(matching text: String, limit: Int) async -> [MailPerson] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var found: [String: MailPerson] = [:]
        var order: [String] = []
        for stored in threads.values.sorted(by: { $0.row.key > $1.row.key }) {
            for message in stored.conversation.messages {
                for person in [message.from] + message.to + message.cc where !person.isMe {
                    let key = person.address.lowercased()
                    guard found[key] == nil, Self.matches(person, needle) else { continue }
                    var offered = person
                    // He has written to this one, or has only had mail from them: the last are
                    // offered by address and marked (MAIL-UX 6.3.3).
                    offered.fromTheirMail = !person.isKnown
                    found[key] = offered
                    order.append(key)
                }
            }
        }
        let people = order.compactMap { found[$0] }
        let known = people.filter(\.isKnown)
        let others = people.filter { !$0.isKnown }
        return Array((known + others).prefix(limit))
    }

    /// The typed text starts a word of the name, or the address.
    private static func matches(_ person: MailPerson, _ needle: String) -> Bool {
        if person.address.lowercased().hasPrefix(needle) { return true }
        guard let name = person.name?.lowercased() else { return false }
        return name.split(separator: " ").contains { $0.hasPrefix(needle) } || name.hasPrefix(needle)
    }

    // MARK: - Sending

    @discardableResult
    func send(_ id: MailDraftID, _ options: MailSendOptions) -> MailReceipt {
        // Send later: held until a time he chose, which is not an undo hold (the schedule file).
        if let at = options.at, at > clock() { return schedule(id, at: at) }
        sequence += 1
        guard var draft = drafts[id], held[id] == nil else {
            return MailReceipt(sequence: sequence, count: 0)
        }
        let hold = options.hold ?? Self.defaultHold
        let until = clock().addingTimeInterval(hold)
        let message = MailMessageID(account: draft.account,
                                    message: draft.conversation.thread + Self.sampleMark + String(sequence))
        let sent = sentMessage(from: draft, id: message, hold: hold > 0 ? until : nil)
        // What he wrote is the message's body; the quote is not carried into a sample message.
        bodies[message] = .text(draft.body, quoteStartsAt: nil, notices: [])
        // The two forms it would be sent in, kept so that they can be looked at (MailBodyHTML).
        sentParts[message] = MailBodyHTML.message(body: draft.body, signature: draft.signature, quote: draft.quote)

        // A reply joins the conversation it answers. A new message, and a forward, are
        // conversations of their own: a forward is written in the original and goes elsewhere.
        let touched = threads[draft.conversation]
        let ownsConversation = touched == nil || draft.isForward
        let target = ownsConversation
            ? MailConversationID(account: draft.account, thread: "local:" + id.raw) : draft.conversation

        var stored: Stored
        var afterSend: Stored?
        if ownsConversation {
            stored = newConversation(for: draft, target: target, message: sent, hold: hold > 0 ? until : nil)
            if var original = touched {
                original.conversation.draft = nil
                if case .draft? = original.row.reason { original.row.reason = nil }
                afterSend = original
            }
        } else {
            stored = touched!
            stored.conversation.messages.append(sent)
            stored.conversation.draft = nil
            stored.conversation.newestIsMine = true
            stored.row.messageCount = stored.conversation.messages.count
            stored.row.reason = hold > 0 ? .held(until: until) : nil
            afterSend = stored
        }
        // Send and Done marks done the conversation it was written in.
        if options.thenDone {
            if ownsConversation, var original = afterSend {
                original = Self.changed(original, by: .done, at: sequence)
                threads[draft.conversation] = original
            } else if !ownsConversation {
                stored = Self.changed(stored, by: .done, at: sequence)
            }
        } else if ownsConversation, let original = afterSend {
            threads[draft.conversation] = original
        }
        before[sequence] = touched.map { [$0] } ?? []
        threads[target] = stored

        draft.delivery = hold > 0 ? .held(until: until) : nil
        drafts[id] = draft
        let receipt = MailReceipt(sequence: sequence, count: 1)
        held[id] = HeldSend(draft: draft, receipt: receipt, message: message, target: target,
                            ownsConversation: ownsConversation,
                            touched: touched == nil ? nil : draft.conversation, previous: touched,
                            afterSend: afterSend, until: until, thenDone: options.thenDone)
        publish()
        if hold > 0 {
            releases[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hold))
                guard !Task.isCancelled else { return }
                self?.release(id)
            }
        } else {
            release(id)
        }
        return receipt
    }

    /// True: it is a draft again. False: it has left, or was never sent.
    func cancelSend(_ id: MailDraftID) async -> Bool {
        if held[id]?.isScheduled == true { return cancelScheduled(id) }
        guard let sent = held[id] else { return false }
        // The hold is over whether or not the timer that ends it has run yet.
        guard clock() < sent.until else {
            release(id)
            return false
        }
        releases[id]?.cancel()
        releases[id] = nil
        held[id] = nil
        var draft = sent.draft
        draft.delivery = nil
        drafts[id] = draft
        kept.insert(id)
        if sent.ownsConversation {
            threads[sent.target] = nil
            bodies[sent.message] = nil
        }
        // What it touched is as it was, with the draft's mark: the message, and a Done, are gone.
        if let touched = sent.touched, let previous = sent.previous {
            threads[touched] = previous
            if !sent.ownsConversation { bodies[sent.message] = nil }
        }
        if !sent.thenDone { before[sent.receipt.sequence] = nil }
        mark(draft, shown: true)
        publish()
        return true
    }

    /// The hold is over: it is sent, and nothing is left to take back except a Done.
    func release(_ id: MailDraftID) {
        guard let sent = held.removeValue(forKey: id) else { return }
        releases[id]?.cancel()
        releases[id] = nil
        drafts[id] = nil
        func released(_ stored: Stored) -> Stored {
            var stored = stored
            for index in stored.conversation.messages.indices
            where stored.conversation.messages[index].id == sent.message {
                stored.conversation.messages[index].delivery = nil
            }
            if case .held? = stored.row.reason { stored.row.reason = nil }
            return stored
        }
        if let stored = threads[sent.target] { threads[sent.target] = released(stored) }
        // After the hold, Undo reverses the Done alone (T28): the conversation as it was once the
        // message had gone.
        if sent.thenDone, let afterSend = sent.afterSend {
            before[sent.receipt.sequence] = [released(afterSend)]
        } else {
            before[sent.receipt.sequence] = nil
        }
        publish()
    }

    /// A scheduled message is waiting for its time, not for a hold: leaving does not send it.
    var hasUnfinishedSends: Bool {
        held.values.contains { !$0.isScheduled }
    }

    func finishSends(within limit: TimeInterval) async {
        for (id, sent) in held where !sent.isScheduled { release(id) }
    }

    // MARK: - What a send makes

    func sentMessage(from draft: MailDraft, id: MailMessageID, hold: Date?) -> MailMessage {
        let text = MailPlainText.string(draft.body)
        return MailMessage(
            id: id, from: MailPerson(name: draft.from.name, address: draft.from.address, isMe: true,
                                     isKnown: true, fromTheirMail: false),
            to: draft.to, cc: draft.cc, bcc: draft.bcc, replyTo: [], deliveredTo: nil, listName: nil,
            date: MailFixtureConversations.now.addingTimeInterval(TimeInterval(sequence)),
            isUnread: false, isMine: true, firstLine: MailPlainText.firstLine(text), body: .text,
            attachments: Self.sentAttachments(of: draft, message: id), delivery: hold.map { .held(until: $0) },
            draft: nil)
    }

    /// A message that is the first of a conversation of its own: a new message, or a forward.
    func newConversation(for draft: MailDraft, target: MailConversationID, message: MailMessage,
                         hold: Date?) -> Stored {
        let subject = draft.subject
        let me = message.from
        let row = MailRow(
            id: target,
            key: MailOrderKey(group: 0, sortKey: Int64(message.date.timeIntervalSince1970),
                              tie: Self.stableHash(target.thread)),
            date: message.date, people: draft.to.isEmpty ? [me] : draft.to, peopleTotal: max(draft.to.count, 1),
            messageCount: 1, subject: subject, snippet: message.firstLine, isUnread: false,
            isStarred: false, isImportant: false, hasAttachment: !draft.attachments.isEmpty, isInvitation: false,
            inInbox: false, isMuted: false, hasPendingChange: false, fromGmailSearch: false, labels: [],
            reason: hold.map { .held(until: $0) })
        let conversation = MailConversation(
            id: target, subject: subject, labels: [], inInbox: false, isStarred: false, isImportant: false,
            isMuted: false, snoozedUntil: nil, system: nil, messages: [message], invite: nil,
            unsubscribe: nil, draft: nil, newestIsMine: true, appliedThrough: sequence)
        return Stored(row: row, conversation: conversation)
    }

    // MARK: - Reading what a reply answers

    func original(_ id: MailMessageID) -> (stored: Stored, message: MailMessage)? {
        let thread = MailConversationID(account: id.account, thread: String(id.message.prefix { $0 != "~" }))
        guard let stored = threads[thread],
              let message = stored.conversation.messages.first(where: { $0.id == id }) else { return nil }
        return (stored, message)
    }

    /// The quoted original as a draft's part: what it is called, then its text one quote deeper.
    /// A forward carries the message's own header lines and its text as it was.
    func quote(of message: MailMessage, forward: Bool, subject: String) -> MailDraftPart {
        let text: MailText
        switch bodies[message.id] {
        case .text(let content, _, _)?: text = content
        case .designed(_, _, _, let plain, _)?: text = plain
        default: text = MailText(blocks: [])
        }
        let who = message.from.name ?? message.from.address
        let when = MailDateText.full(message.date)
        var blocks: [MailTextBlock] = []
        func paragraph(_ line: String) -> MailTextBlock {
            MailTextBlock(kind: .paragraph, runs: [MailTextRun(text: line)])
        }
        if forward {
            blocks.append(paragraph("---------- Forwarded message ----------"))
            blocks.append(paragraph("From: \(who) <\(message.from.address)>"))
            blocks.append(paragraph("Date: \(when)"))
            blocks.append(paragraph("Subject: \(subject)"))
            blocks.append(paragraph("To: " + message.to.map { $0.name ?? $0.address }.joined(separator: ", ")))
            blocks.append(contentsOf: text.blocks)
        } else {
            blocks.append(paragraph("On \(when), \(who) wrote:"))
            for block in text.blocks {
                var quoted = block
                if case .quote(let depth) = block.kind {
                    quoted.kind = .quote(depth: depth + 1)
                } else {
                    quoted.kind = .quote(depth: 1)
                }
                blocks.append(quoted)
            }
        }
        let html = blocks.map { "<div>" + Self.escaped(MailAttributedText.plain($0.runs)) + "</div>" }
            .joined()
        return MailDraftPart(fragment: MailFragment(html: "<blockquote>" + html + "</blockquote>"),
                             body: .text(MailText(blocks: blocks), quoteStartsAt: nil, notices: []))
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A person typed as an address, with no name.
    nonisolated static func person(address: String) -> MailPerson {
        MailPerson(name: nil, address: address, isMe: false, isKnown: false, fromTheirMail: false)
    }
}
#endif

#endif
