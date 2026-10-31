#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation

/// What writing mail needs beyond a draft and a send, in memory, for the sample mailbox: who he can
/// send as and what each signs with, the Drafts and Scheduled places, and **send later**.
///
/// **A scheduled message is a message in its conversation** (`delivery: .scheduled(at)`, and its
/// `draft` while it can be reopened), as the contract says, so the conversation shows it and a row
/// says so. It is held like a send inside its hold, until a time he chose and not for ten seconds:
/// at that time, while the app is running, it is "sent" and looks like any sent sample message
/// (`wakeClock` is what it waits on, so a test moves time by hand). If it wakes more than
/// `lateAfter` after its time, or the app is opened after its time has passed, it is **late**: it
/// asks, in the contract's own words (`delivery: .asking(…, .sendLate)`), and is never sent unasked.
///
/// Scheduled messages are kept in `defaults` so that a relaunch can find one late; everything else
/// in the sample mailbox is gone when Banana relaunches.
extension MailFixtureSource {

    /// How long after its time a woken scheduled message is still sent, rather than asked about.
    nonisolated static let lateAfter: TimeInterval = 300
    nonisolated static let scheduleKey = "mailSampleScheduled"

    // MARK: - Who he can send as

    nonisolated static let identities: [MailIdentity] = [
        MailIdentity(account: MailFixtureConversations.account, address: MailFixtureConversations.account,
                     name: "Noor", isDefault: true, hasSignature: true),
        MailIdentity(account: MailFixtureConversations.account, address: MailFixtureConversations.alias,
                     name: "Noor at work", isDefault: false, hasSignature: true),
        // Nothing signs this one, to show a draft with no signature.
        MailIdentity(account: MailFixtureConversations.secondAccount,
                     address: MailFixtureConversations.secondAccount,
                     name: "Noor", isDefault: true, hasSignature: false),
    ]

    nonisolated static func identity(address: String) -> MailIdentity? {
        identities.first { $0.address.lowercased() == address.lowercased() }
    }

    /// Plain text, as a person's signature is.
    nonisolated static let signatures: [String: [String]] = [
        MailFixtureConversations.account: ["Noor", "Abrega Inc. \u{00B7} plan.example"],
        MailFixtureConversations.alias: ["Noor at work", "hello@plan.example", "I read this address every morning."],
    ]

    func signature(for identity: MailIdentity) -> MailDraftPart? {
        guard identity.hasSignature, let lines = Self.signatures[identity.address.lowercased()] else { return nil }
        let blocks = lines.map { MailTextBlock(kind: .paragraph, runs: [MailTextRun(text: $0)]) }
        let html = lines.map { "<div>" + Self.escaped($0) + "</div>" }.joined()
        return MailDraftPart(fragment: MailFragment(html: "<div class=\"signature\">" + html + "</div>"),
                             body: .text(MailText(blocks: blocks), quoteStartsAt: nil, notices: []))
    }

    /// From and the signature are replaced together; the text, the people and the quote are not
    /// touched (MAIL-ENGINE 7: `changeIdentity`).
    func changeIdentity(of id: MailDraftID, to address: String) async -> MailDraft? {
        guard var draft = drafts[id], held[id] == nil, let identity = Self.identity(address: address) else {
            return nil
        }
        draft.from = identity
        draft.signature = signature(for: identity)
        drafts[id] = draft
        return draft
    }

    // MARK: - Drafts and Scheduled, as places

    /// A draft is a row of the Drafts place once something has been written into it.
    func draftRows() -> [MailRow] {
        // One row for each conversation, as a place counts conversations: the draft written last.
        var seen = Set<MailConversationID>()
        return drafts.values.filter { kept.contains($0.id) && held[$0.id] == nil }
            .sorted { $0.editedAt > $1.editedAt }
            .filter { seen.insert($0.conversation).inserted }
            .map(draftRow).sorted { $0.key > $1.key }
    }

    func draftRow(_ draft: MailDraft) -> MailRow {
        let first = MailPlainText.firstLine(MailPlainText.string(draft.body))
        return MailRow(
            id: draft.conversation,
            key: MailOrderKey(group: 0, sortKey: Int64(draft.editedAt.timeIntervalSince1970 * 1_000),
                              tie: Self.stableHash(draft.id.raw)),
            date: draft.editedAt, people: draft.to, peopleTotal: draft.to.count, messageCount: 1,
            subject: draft.subject, snippet: first, isUnread: false, isStarred: false, isImportant: false,
            hasAttachment: !draft.attachments.isEmpty, isInvitation: false, inInbox: false, isMuted: false,
            hasPendingChange: false, fromGmailSearch: false, labels: [], reason: .draft(firstLine: first))
    }

    /// The soonest first: the key is the time, reversed (a list is in descending key order).
    func scheduledRows() -> [MailRow] {
        // One row for each conversation, whichever of its scheduled messages goes first.
        var seen = Set<MailConversationID>()
        return held.values.filter(\.isScheduled).sorted { $0.until < $1.until }
            .filter { seen.insert($0.target).inserted }
            .map(scheduledRow).sorted { $0.key > $1.key }
    }

    func scheduledRow(_ sent: HeldSend) -> MailRow {
        let draft = sent.draft
        let first = MailPlainText.firstLine(MailPlainText.string(draft.body))
        return MailRow(
            id: sent.target,
            key: MailOrderKey(group: 0, sortKey: -Int64(sent.until.timeIntervalSince1970 * 1_000),
                              tie: Self.stableHash(draft.id.raw)),
            date: sent.until, people: draft.to, peopleTotal: draft.to.count, messageCount: 1,
            subject: draft.subject, snippet: first, isUnread: false, isStarred: false, isImportant: false,
            hasAttachment: !draft.attachments.isEmpty, isInvitation: false, inInbox: false, isMuted: false,
            hasPendingChange: false, fromGmailSearch: false, labels: [],
            reason: .scheduled(sent.until, onThisDevice: true, isLate: sent.isLate))
    }

    /// A conversation as it is read: a stored one, or the one a new message's draft is the only
    /// message of, so choosing it in Drafts has something to open.
    func conversationValue(_ id: MailConversationID) -> MailConversation? {
        if let stored = threads[id] { return stored.conversation }
        guard id.thread.hasPrefix("local:"),
              let draft = drafts.values.first(where: {
                  $0.conversation == id && kept.contains($0.id) && held[$0.id] == nil
              }) else { return nil }
        return draftConversation(draft)
    }

    private func draftConversation(_ draft: MailDraft) -> MailConversation {
        let me = MailPerson(name: draft.from.name, address: draft.from.address, isMe: true, isKnown: true,
                            fromTheirMail: false)
        let message = MailMessage(
            id: Self.draftMessageID(draft), from: me, to: draft.to, cc: draft.cc, bcc: draft.bcc, replyTo: [],
            deliveredTo: nil, listName: nil, date: draft.editedAt, isUnread: false, isMine: true,
            firstLine: MailPlainText.firstLine(MailPlainText.string(draft.body)), body: .text,
            attachments: [], delivery: nil, draft: draft.id)
        return MailConversation(
            id: draft.conversation, subject: draft.subject, labels: [], inInbox: false, isStarred: false,
            isImportant: false, isMuted: false, snoozedUntil: nil, system: nil, messages: [message],
            invite: nil, unsubscribe: nil, draft: draft.id, newestIsMine: true, appliedThrough: sequence)
    }

    nonisolated private static func draftMessageID(_ draft: MailDraft) -> MailMessageID {
        MailMessageID(account: draft.account, message: draft.conversation.thread + "~draft")
    }

    func draftBody(_ id: MailMessageID) -> MailBody? {
        guard let draft = drafts.values.first(where: { Self.draftMessageID($0) == id }) else { return nil }
        return .text(draft.body, quoteStartsAt: nil, notices: [])
    }

    /// A conversation of his own that holds nothing but what he has not sent: it belongs to no
    /// triage place until it has gone.
    static func isUnsent(_ stored: Stored) -> Bool {
        stored.conversation.id.thread.hasPrefix("local:")
            && stored.conversation.messages.allSatisfy { $0.draft != nil }
    }

    /// What a Drafts row says, to be told only when it changes: a save that changes nothing it says
    /// tells no list anything, so typing does not move a list that is on screen.
    func publishDraftsIfChanged(_ draft: MailDraft, alreadyTold: Bool) {
        let line = draft.to.map(\.address) + [draft.subject, MailPlainText.firstLine(MailPlainText.string(draft.body))]
        guard draftLines[draft.id] != line else { return }
        draftLines[draft.id] = line
        if !alreadyTold { publish() }
    }

    // MARK: - Scheduling

    @discardableResult
    func schedule(_ id: MailDraftID, at: Date, restored: Bool = false) -> MailReceipt {
        sequence += 1
        guard var draft = drafts[id], held[id] == nil else {
            return MailReceipt(sequence: sequence, count: 0)
        }
        let late = restored && at <= clock()
        let message = MailMessageID(account: draft.account,
                                    message: draft.conversation.thread + Self.sampleMark + String(sequence))
        var sent = sentMessage(from: draft, id: message, hold: nil)
        sent.date = at
        sent.draft = id
        sent.delivery = Self.delivery(of: id, at: at, late: late)
        bodies[message] = .text(draft.body, quoteStartsAt: nil, notices: [])

        let touched = threads[draft.conversation]
        let ownsConversation = touched == nil || draft.isForward
        let target = ownsConversation
            ? MailConversationID(account: draft.account, thread: "local:" + id.raw) : draft.conversation
        let reason = MailRowReason.scheduled(at, onThisDevice: true, isLate: late)
        if ownsConversation {
            var stored = newConversation(for: draft, target: target, message: sent, hold: nil)
            stored.row.reason = reason
            threads[target] = stored
            if var original = touched {
                // A forward is written where the original is; the draft leaves it.
                original.conversation.draft = nil
                if case .draft? = original.row.reason { original.row.reason = nil }
                threads[draft.conversation] = original
            }
        } else if var stored = touched {
            stored.conversation.messages.append(sent)
            stored.conversation.draft = nil
            stored.conversation.newestIsMine = true
            stored.row.messageCount = stored.conversation.messages.count
            stored.row.reason = reason
            threads[target] = stored
        }

        draft.delivery = sent.delivery
        draft.schedule = MailSchedule(at: at, onThisDevice: true, isLate: late)
        drafts[id] = draft
        kept.remove(id)
        draftLines[id] = nil
        let receipt = MailReceipt(sequence: sequence, count: 1)
        held[id] = HeldSend(draft: draft, receipt: receipt, message: message, target: target,
                            ownsConversation: ownsConversation,
                            touched: touched == nil ? nil : draft.conversation, previous: touched,
                            afterSend: nil, until: at, thenDone: false, isScheduled: true, isLate: late)
        if !late { wake(id, at: at) }
        persistSchedules()
        publish()
        return receipt
    }

    nonisolated private static func delivery(of id: MailDraftID, at: Date, late: Bool) -> MailDelivery {
        late ? .asking(MailQuestion.ID(raw: "late-" + id.raw), .sendLate(id, since: at)) : .scheduled(at)
    }

    /// Sleeps until its time on the wake clock, then sends it, or says it is late.
    private func wake(_ id: MailDraftID, at: Date) {
        wakers[id]?.cancel()
        let clock = wakeClock
        wakers[id] = Task { [weak self] in
            do { try await clock.sleep(until: at) } catch { return }
            self?.timeCame(id)
        }
    }

    /// Finishes when the wake-up of a scheduled message has been dealt with. For tests.
    func settleWake(of id: MailDraftID) async {
        await wakers[id]?.value
    }

    private func timeCame(_ id: MailDraftID) {
        guard let sent = held[id], sent.isScheduled, !sent.isLate else { return }
        if clock() >= sent.until.addingTimeInterval(Self.lateAfter) {
            markLate(id)
        } else {
            releaseScheduled(id)
        }
    }

    /// The time passed and nobody was there: it asks, and waits to be told.
    func markLate(_ id: MailDraftID) {
        guard var sent = held[id], sent.isScheduled else { return }
        sent.isLate = true
        sent.draft.schedule?.isLate = true
        held[id] = sent
        wakers[id]?.cancel()
        wakers[id] = nil
        update(sent, delivery: Self.delivery(of: id, at: sent.until, late: true),
               reason: .scheduled(sent.until, onThisDevice: true, isLate: true))
        publish()
    }

    /// Its time has come, and the app was running: it is sent, and nothing is left to take back.
    func releaseScheduled(_ id: MailDraftID) {
        guard let sent = held.removeValue(forKey: id), sent.isScheduled else { return }
        wakers[id]?.cancel()
        wakers[id] = nil
        drafts[id] = nil
        update(sent, delivery: nil, reopenable: false, reason: nil)
        persistSchedules()
        publish()
    }

    /// Back to a draft, with the time he had chosen still on it: before its time, or late. True; false
    /// when its time had come and it has gone.
    func cancelScheduled(_ id: MailDraftID) -> Bool {
        guard let sent = held[id], sent.isScheduled else { return false }
        if !sent.isLate, clock() >= sent.until {
            releaseScheduled(id)
            return false
        }
        wakers[id]?.cancel()
        wakers[id] = nil
        held[id] = nil
        var draft = sent.draft
        draft.delivery = nil
        draft.schedule = MailSchedule(at: sent.until, onThisDevice: true, isLate: false)
        drafts[id] = draft
        kept.insert(id)
        if sent.ownsConversation {
            threads[sent.target] = nil
        } else if var stored = threads[sent.target] {
            stored.conversation.messages.removeAll { $0.id == sent.message }
            stored.conversation.newestIsMine = stored.conversation.messages.last?.isMine ?? false
            stored.row.messageCount = stored.conversation.messages.count
            if case .scheduled? = stored.row.reason { stored.row.reason = nil }
            threads[sent.target] = stored
        }
        bodies[sent.message] = nil
        mark(draft, shown: true)
        persistSchedules()
        publish()
        return true
    }

    /// The scheduled message as it stands in its conversation: what it says of its delivery, and
    /// whether it can still be reopened. The row's reason follows only while it is a scheduled one.
    private func update(_ sent: HeldSend, delivery: MailDelivery?, reopenable: Bool = true,
                        reason: MailRowReason?) {
        guard var stored = threads[sent.target] else { return }
        for index in stored.conversation.messages.indices
        where stored.conversation.messages[index].id == sent.message {
            stored.conversation.messages[index].delivery = delivery
            if !reopenable { stored.conversation.messages[index].draft = nil }
        }
        if case .scheduled? = stored.row.reason { stored.row.reason = reason }
        threads[sent.target] = stored
    }

    // MARK: - Kept across a relaunch

    private struct StoredSchedule: Codable {
        var draft: String
        var account: String
        var thread: String
        var isReply: Bool
        var isForward: Bool
        var from: String
        var to: [MailPerson]
        var cc: [MailPerson]
        var bcc: [MailPerson]
        var subject: String
        var body: String
        var at: Date
    }

    private func persistSchedules() {
        guard let defaults else { return }
        let list = held.values.filter(\.isScheduled).map { sent -> StoredSchedule in
            let draft = sent.draft
            return StoredSchedule(
                draft: draft.id.raw, account: draft.conversation.account, thread: draft.conversation.thread,
                isReply: draft.isReply, isForward: draft.isForward, from: draft.from.address, to: draft.to,
                cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
                body: MailPlainText.string(draft.body), at: sent.until)
        }
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.scheduleKey)
    }

    /// A launch: what was scheduled is back, and what was due while the app was not running is late.
    func restoreSchedules() {
        guard let defaults, let data = defaults.data(forKey: Self.scheduleKey),
              let list = try? JSONDecoder().decode([StoredSchedule].self, from: data) else { return }
        for item in list {
            let id = MailDraftID(raw: item.draft)
            draftNumber = max(draftNumber, Int(item.draft.dropFirst("draft-".count)) ?? 0)
            let identity = Self.identity(address: item.from) ?? Self.identities[0]
            let conversation = MailConversationID(account: item.account, thread: item.thread)
            var draft = MailDraft(
                id: id, conversation: conversation, account: item.account, isReply: item.isReply,
                isForward: item.isForward, from: identity, to: item.to, cc: item.cc, bcc: item.bcc,
                subject: item.subject, body: MailPlainText.text(item.body), signature: signature(for: identity),
                quote: nil, attachments: [], format: .banana, schedule: nil, remindIfNoReply: nil,
                delivery: nil, encodedBytes: 0, editedAt: clock())
            if item.isReply || item.isForward, let stored = threads[conversation],
               let newest = stored.conversation.messages.last {
                draft.quote = quote(of: newest, forward: item.isForward, subject: stored.conversation.subject)
            }
            drafts[id] = draft
            schedule(id, at: item.at, restored: true)
        }
    }
}
#endif

#endif
