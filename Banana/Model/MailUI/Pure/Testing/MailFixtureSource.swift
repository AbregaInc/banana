#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation
import Combine

/// `MailSource` in memory, over the sample mailbox (`MailFixtureConversations`): no Gmail, no
/// network, no database. A change is applied the way the contract says one is — to the one
/// mailbox, shown in every observed list and conversation before the call returns, answered
/// with a receipt — and Undo puts back exactly what that change changed.
///
/// It implements what the screens use: the list reads, one conversation and its bodies,
/// `apply` and `undo`, the places' counts and the badge, and drafts and sending
/// (`MailFixtureSource+Drafts.swift`). Every other member is answered by
/// `MailSource+NotYet.swift` until a later package declares it. A row's membership is decided
/// by `MailRowRules`, the engine's own pure rule, so the row shown at the key press is the row
/// a reading finds (MAIL-ENGINE invariant 32).
///
/// State lives as long as the object: a relaunch is a fresh mailbox.
@MainActor
final class MailFixtureSource: MailSource {
    private var eventObservers: [UUID: @MainActor (MailEvent) -> Void] = [:]
    var nextApplyFailure: MailStoreProblem?
    var nextUndoFailure: MailStoreProblem?

    func observeEvents(_ onEvent: @escaping @MainActor (MailEvent) -> Void) -> MailObservation {
        let id = UUID()
        eventObservers[id] = onEvent
        return MailObservation { [weak self] in
            Task { @MainActor in self?.eventObservers[id] = nil }
        }
    }

    /// Controlled provider/store failures for session integration tests.
    func emit(_ event: MailEvent) {
        for observer in Array(eventObservers.values) { observer(event) }
    }

    /// Everything about one conversation that a change can touch, and so what Undo puts back.
    struct Stored: Equatable {
        var row: MailRow
        var conversation: MailConversation
    }

    // Not `private`: the draft and send members are in a file of their own, and they change what
    // these hold.
    var threads: [MailConversationID: Stored] = [:] {
        didSet {
            if !maintainingThreadCaches {
                memberCache.removeAll(keepingCapacity: true)
                pageCache.removeAll(keepingCapacity: true)
                placeTotals = nil
            }
        }
    }
    // The fixture remains in-memory; this is not a substitute for the production SQL engine.
    // Bound retained scopes so repeated filter combinations cannot retain the whole mailbox
    // indefinitely. Every thread mutation invalidates before observers receive their next read.
    private var maintainingThreadCaches = false
    private var placeTotals: (total: [MailMailbox: Int], unread: [MailMailbox: Int])?
    private var memberCache: [MailScope: [MailRow]] = [:]
    private struct PageKey: Hashable { let scope: MailScope; let limit: Int }
    private var pageCache: [PageKey: (rows: [MailRow], total: Int)] = [:]
    var bodies: [MailMessageID: MailBody] = [:]
    /// Every conversation, as a change last left it.
    var sequence: UInt64 = 0
    /// What each command changed, as it was, for Undo.
    var before: [UInt64: [Stored]] = [:]

    /// The drafts he has not sent, and a draft inside its undo hold: it is a draft again until
    /// the hold ends.
    var drafts: [MailDraftID: MailDraft] = [:]
    /// A discarded draft, by the receipt that discarded it, so Undo can bring it back.
    var discarded: [UInt64: MailDraft] = [:]
    /// What a send did, until its hold ends.
    var held: [MailDraftID: HeldSend] = [:]
    var releases: [MailDraftID: Task<Void, Never>] = [:]
    /// What each message this source "sent" would have gone out as: its HTML and its plain text.
    var sentParts: [MailMessageID: (html: String, plain: String)] = [:]
    /// A file taken off a draft, until the launch ends, so that Undo can put it back as it was.
    var removedFiles: [MailDraftID: [MailDraftAttachment]] = [:]
    var draftNumber = 0
    /// What time it is, for the undo hold. Not the sample mail's clock, which stands still.
    let clock: () -> Date
    /// What a scheduled message sleeps on until its time (`MailFixtureSource+Schedule.swift`): the
    /// system's, and a test's own.
    let wakeClock: MailClock
    /// Where scheduled messages are kept, so that one whose time passes while the app is not
    /// running is still there to be shown late. Nil keeps nothing, as for every other sample change.
    let defaults: UserDefaults?
    /// The drafts he has written something into: only these are a Drafts place's.
    var kept: Set<MailDraftID> = []
    /// What a draft's row says, as last told, so a save that changes nothing it says tells no one.
    var draftLines: [MailDraftID: [String]] = [:]
    /// The tasks that wake a scheduled message at its time.
    var wakers: [MailDraftID: Task<Void, Never>] = [:]

    private var listObservers: [UUID: (scope: MailScope, limit: Int,
                                       onChange: @MainActor (MailListSnapshot) -> Void)] = [:]
    private var conversationObservers: [UUID: (id: MailConversationID,
                                               onChange: @MainActor (MailConversation?) -> Void)] = [:]
    private var placeObservers: [UUID: @MainActor (MailPlaces) -> Void] = [:]
    private var accountObservers: [UUID: @MainActor ([MailAccount]) -> Void] = [:]

    let status = MailStatus(MailNotYet.emptyStatus)
    let badges = MailBadges(MailBadgeCounts(unreadInFirstSplit: 0, needsAnswer: 0))

    /// Where the sample mail's clock stands.
    var now: Date { MailFixtureConversations.now }

    init(samples: [MailFixtureConversations.Sample] = MailFixtureConversations.threads(),
         clock: @escaping () -> Date = Date.init, wakeClock: MailClock = SystemMailClock(),
         defaults: UserDefaults? = nil) {
        self.clock = clock
        self.wakeClock = wakeClock
        self.defaults = defaults
        // Files the last launch left are gone with it: the sample's staging is this launch's own.
        Task { await MailSampleFiles.sweepPreviousLaunches() }
        for sample in samples {
            let built = Self.build(sample)
            threads[built.stored.row.id] = built.stored
            for (id, body) in built.bodies { bodies[id] = body }
        }
        restoreSchedules()
        publishCounts()
    }

    // MARK: - Life

    func activate() {}
    func setVisible(_ visible: Bool) {}

    // MARK: - Reads

    /// Two accounts, and a second "send as" address on the first (`MailFixtureSource+Schedule.swift`).
    var accounts: [MailAccount] {
        [MailAccount(id: MailFixtureConversations.account, shortName: "z0", wantsMail: true,
                     state: .connected, health: .live, lastSyncAt: MailFixtureConversations.now,
                     identities: Self.identities.filter { $0.account == MailFixtureConversations.account },
                     keptAfterRemoval: 0),
         MailAccount(id: MailFixtureConversations.secondAccount, shortName: "abrega", wantsMail: true,
                     state: .connected, health: .live, lastSyncAt: MailFixtureConversations.now,
                     identities: Self.identities.filter { $0.account == MailFixtureConversations.secondAccount },
                     keptAfterRemoval: 0)]
    }

    func observeAccounts(_ onChange: @escaping @MainActor ([MailAccount]) -> Void) -> MailObservation {
        let token = UUID()
        accountObservers[token] = onChange
        onChange(accounts)
        return forgetting { $0.accountObservers[token] = nil }
    }

    func observePlaces(_ onChange: @escaping @MainActor (MailPlaces) -> Void) -> MailObservation {
        let token = UUID()
        placeObservers[token] = onChange
        onChange(places())
        return forgetting { $0.placeObservers[token] = nil }
    }

    func cachedFirstPage(_ scope: MailScope) -> MailListSnapshot? {
        snapshot(for: scope, limit: MailTuning.firstPageRows)
    }

    func observeList(_ scope: MailScope, limit: Int,
                     _ onChange: @escaping @MainActor (MailListSnapshot) -> Void) -> MailObservation {
        let token = UUID()
        listObservers[token] = (scope, limit, onChange)
        onChange(snapshot(for: scope, limit: limit))
        return forgetting { $0.listObservers[token] = nil }
    }

    func observeConversation(_ id: MailConversationID,
                             _ onChange: @escaping @MainActor (MailConversation?) -> Void) -> MailObservation {
        let token = UUID()
        conversationObservers[token] = (id, onChange)
        onChange(conversationValue(id))
        return forgetting { $0.conversationObservers[token] = nil }
    }

    /// What an observation does when it is cancelled or let go: the observer is dropped. A
    /// cancel may come from any thread (the contract says so); from the main one, which is every
    /// cancel here, it is dropped before `cancel()` returns.
    private func forgetting(_ forget: @escaping @MainActor (MailFixtureSource) -> Void) -> MailObservation {
        MailObservation { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { if let self { forget(self) } }
            } else {
                Task { @MainActor in if let self { forget(self) } }
            }
        }
    }

    func conversation(_ id: MailConversationID) async -> MailConversation? {
        conversationValue(id)
    }

    func body(_ id: MailMessageID) async -> MailBody {
        bodies[id] ?? draftBody(id) ?? .notOnDevice
    }

    // MARK: - Changes

    @discardableResult
    func apply(_ change: MailChange, to target: MailTarget) -> MailReceipt {
        let ids: [MailConversationID]
        switch target {
        case .reading(let readings):
            ids = readings.map(\.id).filter { threads[$0] != nil }
        case .conversations(let list):
            ids = list.filter { threads[$0] != nil }
        case .message(let message):
            let thread = MailConversationID(account: message.account,
                                            thread: String(message.message.prefix { $0 != "~" }))
            ids = threads[thread] == nil ? [] : [thread]
        case .scope(let scope, let from):
            ids = members(of: scope).filter { from == nil || $0.key <= from! }.map(\.id)
        }
        sequence += 1
        guard !ids.isEmpty else { return MailReceipt(sequence: sequence, count: 0) }
        if let failure = nextApplyFailure {
            nextApplyFailure = nil
            let receipt = MailReceipt(sequence: sequence, count: ids.count)
            emit(.notSaved(receipt, failure))
            return receipt
        }
        before[sequence] = ids.compactMap { threads[$0] }
        for id in ids {
            if let stored = threads[id] { updateThread(Self.changed(stored, by: change, at: sequence)) }
        }
        publish()
        return MailReceipt(sequence: sequence, count: ids.count)
    }

    @discardableResult
    func undo(_ receipt: MailReceipt) -> MailReceipt {
        // A send whose hold is over has gone, whether or not the timer that says so has run:
        // what Undo then puts back is the Done alone.
        for (id, sent) in held where sent.receipt == receipt && clock() >= sent.until { release(id) }
        sequence += 1
        if let failure = nextUndoFailure, let saved = before[receipt.sequence], !saved.isEmpty {
            nextUndoFailure = nil
            let answer = MailReceipt(sequence: sequence, count: saved.count)
            publish()
            emit(.notSaved(answer, failure))
            return answer
        }
        let saved = before.removeValue(forKey: receipt.sequence) ?? []
        let draft = discarded.removeValue(forKey: receipt.sequence)
        guard !saved.isEmpty || draft != nil else {
            return MailReceipt(sequence: sequence, count: 0)
        }
        for var stored in saved {
            stored.conversation.appliedThrough = sequence
            updateThread(stored)
        }
        // A discarded draft comes back whole; the conversation it was a reply in has its marker
        // back with the rest of what it was.
        if let draft {
            drafts[draft.id] = draft
            kept.insert(draft.id)
        }
        publish()
        let answer = MailReceipt(sequence: sequence, count: max(saved.count, 1))
        emit(.applied(answer, count: max(saved.count, 1)))
        return answer
    }

    /// A read/star change must not scan all retained messages merely to repaint one row.
    /// Keep pages whose membership/order is unchanged; invalidate only pages needing a refill.
    /// Other fixture mutation paths still use the dictionary's conservative invalidation.
    private func updateThread(_ value: Stored) {
        let old = threads[value.row.id]
        maintainingThreadCaches = true
        threads[value.row.id] = value
        maintainingThreadCaches = false
        memberCache.removeAll(keepingCapacity: true)
        for key in Array(pageCache.keys) {
            let wasMember = old.map { !Self.isUnsent($0) && belongs($0.row, to: key.scope) } ?? false
            let isMember = !Self.isUnsent(value) && belongs(value.row, to: key.scope)
            guard wasMember == isMember, old?.row.key == value.row.key else {
                pageCache[key] = nil
                continue
            }
            if let index = pageCache[key]?.rows.firstIndex(where: { $0.id == value.row.id }) {
                pageCache[key]?.rows[index] = value.row
            }
        }
        if placeTotals != nil {
            if let old, !Self.isUnsent(old) { adjustPlaceTotals(old.row, by: -1) }
            if !Self.isUnsent(value) { adjustPlaceTotals(value.row, by: 1) }
        }
    }

    private func adjustPlaceTotals(_ row: MailRow, by delta: Int) {
        var mailboxes: [MailMailbox] = [row.inInbox ? .inbox : .done]
        if row.isStarred { mailboxes.append(.starred) }
        for mailbox in mailboxes {
            placeTotals?.total[mailbox, default: 0] += delta
            if row.isUnread { placeTotals?.unread[mailbox, default: 0] += delta }
        }
    }

    // MARK: - What a change does

    static let inboxScope = MailScope(place: .mailbox(.inbox))

    /// The row through the engine's own rule; the conversation made to agree with it. This
    /// source is Gmail as well, and Gmail takes a change at once, so nothing is left pending.
    static func changed(_ stored: Stored, by change: MailChange, at sequence: UInt64) -> Stored {
        var stored = stored
        switch MailRowRules.apply(change, to: stored.row, in: inboxScope) {
        case .stays(let row), .leaves(let row), .unknown(let row):
            stored.row = row
        }
        stored.row.hasPendingChange = false

        var conversation = stored.conversation
        conversation.inInbox = stored.row.inInbox
        conversation.isStarred = stored.row.isStarred
        conversation.isImportant = stored.row.isImportant
        conversation.isMuted = stored.row.isMuted
        if stored.row.isUnread {
            // Marked unread: the newest message is the one he has not read.
            if !conversation.messages.contains(where: \.isUnread), !conversation.messages.isEmpty {
                conversation.messages[conversation.messages.count - 1].isUnread = true
            }
        } else {
            for index in conversation.messages.indices { conversation.messages[index].isUnread = false }
        }
        conversation.appliedThrough = sequence
        stored.conversation = conversation
        return stored
    }

    // MARK: - Lists

    private func belongs(_ row: MailRow, to scope: MailScope) -> Bool {
        if let before = scope.before, row.key >= before { return false }
        if let account = scope.account, row.id.account != account.lowercased() { return false }
        let inPlace: Bool
        switch scope.place {
        case .mailbox(.inbox): inPlace = row.inInbox
        case .mailbox(.done): inPlace = !row.inInbox
        case .mailbox(.starred): inPlace = row.isStarred
        case .mailbox(.all): inPlace = true
        case .search(let text):
            let definition = LiveFilter.fromSearchExpression(text, scope: "mail")
            if let definition {
                guard definition.canRun else { return false }
                if let interval = definition.interval(), !(row.date >= interval.start && row.date < interval.end) { return false }
                for term in definition.terms {
                    if term.field == "unread" && row.isUnread != (term.value == "true") { return false }
                    if term.field == "starred" && row.isStarred != (term.value == "true") { return false }
                    if term.field == "important" && row.isImportant != (term.value == "true") { return false }
                    if term.field == "person", !row.people.contains(where: { ($0.name ?? "").localizedCaseInsensitiveContains(term.value) || $0.address.localizedCaseInsensitiveContains(term.value) }) { return false }
                }
            }
            let words = (definition?.text ?? text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let haystack = ([row.subject, row.snippet] + row.people.flatMap { [$0.name ?? "", $0.address] })
                .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
            inPlace = (!words.isEmpty || definition?.isEmpty == false) && words.allSatisfy { term in
                let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                return haystack.contains { $0.hasPrefix(folded) }
            }
        default: inPlace = false
        }
        guard inPlace else { return false }
        if scope.filters.contains(.unread), !row.isUnread { return false }
        if scope.filters.contains(.starred), !row.isStarred { return false }
        if scope.filters.contains(.important), !row.isImportant { return false }
        return true
    }

    private func members(of scope: MailScope) -> [MailRow] {
        switch scope.place {
        case .mailbox(.drafts): return draftRows()
        case .mailbox(.outbox): return scheduledRows()
        default: break
        }
        if let cached = memberCache[scope] { return cached }
        let result = threads.values.filter { !Self.isUnsent($0) && belongs($0.row, to: scope) }
            .map(\.row).sorted { $0.key > $1.key }
        if memberCache.count >= 4 { memberCache.removeAll(keepingCapacity: true) }
        memberCache[scope] = result
        return result
    }

    private func snapshot(for scope: MailScope, limit: Int) -> MailListSnapshot {
        let key = PageKey(scope: scope, limit: max(0, limit))
        let page: (rows: [MailRow], total: Int)
        switch scope.place {
        case .mailbox(.drafts), .mailbox(.outbox):
            // These collections have their own mutation/publication rules.
            let all = members(of: scope)
            page = (Array(all.prefix(key.limit)), all.count)
        default:
            if let cached = pageCache[key] {
                page = cached
            } else {
                var top = MailTopRows(limit: key.limit)
                var total = 0
                for stored in threads.values where !Self.isUnsent(stored) && belongs(stored.row, to: scope) {
                    total += 1
                    top.insert(stored.row)
                }
                page = (top.sorted, total)
                if pageCache.count >= 4 { pageCache.removeAll(keepingCapacity: true) }
                pageCache[key] = page
            }
        }
        return MailListSnapshot(scope: scope, rows: page.rows,
                                total: MailCount(value: page.total, isAtLeast: false),
                                hasMore: page.total > page.rows.count, stillLoading: 0, isRebuilding: false,
                                remote: nil, coverage: nil, appliedThrough: sequence)
    }

    private func places() -> MailPlaces {
        // Counting does not need order. Previously three whole-mailbox sorts ran on every
        // read/star/archive, even with no places observer attached.
        if placeTotals == nil {
            placeTotals = ([:], [:])
            for stored in threads.values where !Self.isUnsent(stored) {
                adjustPlaceTotals(stored.row, by: 1)
            }
        }
        var totals = placeTotals!.total
        var unread = placeTotals!.unread
        func include(_ row: MailRow, in mailbox: MailMailbox) {
            totals[mailbox, default: 0] += 1
            if row.isUnread { unread[mailbox, default: 0] += 1 }
        }
        for row in draftRows() { include(row, in: .drafts) }
        for row in scheduledRows() { include(row, in: .outbox) }
        var counts: [MailMailbox: MailPlaceCount] = [:]
        for mailbox: MailMailbox in [.inbox, .starred, .drafts, .outbox, .done] {
            counts[mailbox] = MailPlaceCount(
                unread: MailCount(value: unread[mailbox, default: 0], isAtLeast: false),
                total: MailCount(value: totals[mailbox, default: 0], isAtLeast: false))
        }
        return MailPlaces(splits: [], splitCounts: [:], mailboxCounts: counts,
                          outboxNeedsAnswer: false, labels: [:])
    }

    /// Every observer hears of a change before the command that made it returns (the contract's
    /// promise 2): the lists, the conversations, the counts.
    func publish() {
        for observer in Array(listObservers.values) {
            observer.onChange(snapshot(for: observer.scope, limit: observer.limit))
        }
        for observer in Array(conversationObservers.values) {
            observer.onChange(conversationValue(observer.id))
        }
        publishCounts()
    }

    private func publishCounts() {
        let current = places()
        let unread = current.mailboxCounts[.inbox]?.unread.value ?? 0
        if badges.value.unreadInFirstSplit != unread { badges.value.unreadInFirstSplit = unread }
        for observer in Array(placeObservers.values) { observer(current) }
    }

    // MARK: - Building the mailbox

    /// A sample as the contract's row, conversation and bodies.
    static func build(_ sample: MailFixtureConversations.Sample)
        -> (stored: Stored, bodies: [MailMessageID: MailBody]) {
        let account = MailFixtureConversations.account
        let id = MailConversationID(account: account, thread: sample.key)

        var messages: [MailMessage] = []
        var bodies: [MailMessageID: MailBody] = [:]
        for (index, source) in sample.messages.enumerated() {
            let messageID = MailMessageID(account: account, message: "\(sample.key)~\(index + 1)")
            let text = Self.text(from: source.body)
            let first = source.body.first { !$0.hasPrefix(">") } ?? ""
            let date = MailFixtureConversations.date(day: source.day, source.hour, source.minute)
            messages.append(MailMessage(
                id: messageID, from: source.from, to: source.to, cc: [], bcc: [],
                replyTo: source.replyTo, deliveredTo: source.deliveredTo ?? account, listName: nil, date: date,
                isUnread: source.unread, isMine: source.from.isMe, firstLine: first,
                body: .text,
                attachments: source.files.enumerated().map { part, file in
                    MailSampleFiles.attachment(id: MailAttachmentID(message: messageID, part: String(part)),
                                               name: file.name, bytes: file.bytes, actually: source.actually[file.name])
                },
                delivery: nil, draft: nil))
            bodies[messageID] = .text(text, quoteStartsAt: nil,
                                      notices: sample.designed ? [.shownAsText] : [])
        }

        let newest = messages.max { $0.date < $1.date } ?? messages[messages.count - 1]
        var people: [MailPerson] = []
        for message in messages where !people.contains(where: { $0.address == message.from.address }) {
            people.append(message.from)
        }
        let row = MailRow(
            id: id,
            key: MailOrderKey(group: 0, sortKey: Int64(newest.date.timeIntervalSince1970),
                              tie: stableHash(sample.key)),
            date: newest.date, people: Array(people.prefix(6)), peopleTotal: people.count,
            messageCount: messages.count, subject: sample.subject,
            snippet: newest.firstLine,
            isUnread: messages.contains(where: \.isUnread), isStarred: sample.starred,
            isImportant: sample.important, hasAttachment: messages.contains { !$0.attachments.isEmpty },
            isInvitation: sample.invite != nil, inInbox: true, isMuted: false,
            hasPendingChange: false, fromGmailSearch: false, labels: sample.labels, reason: nil)
        let conversation = MailConversation(
            id: id, subject: sample.subject, labels: sample.labels, inInbox: true,
            isStarred: sample.starred, isImportant: sample.important, isMuted: false,
            snoozedUntil: nil, system: nil, messages: messages, invite: sample.invite,
            unsubscribe: sample.unsubscribe, draft: nil, newestIsMine: newest.isMine,
            appliedThrough: 0)
        return (Stored(row: row, conversation: conversation), bodies)
    }

    /// A body line starting with ">" is a quote, one level for each; "• " is a list item.
    static func text(from lines: [String]) -> MailText {
        var blocks: [MailTextBlock] = []
        for line in lines {
            if line.hasPrefix(">") {
                let depth = line.prefix { $0 == ">" }.count
                let rest = line.drop { $0 == ">" || $0 == " " }
                blocks.append(MailTextBlock(kind: .quote(depth: depth), runs: [MailTextRun(text: String(rest))]))
            } else if line.hasPrefix("\u{2022} ") {
                blocks.append(MailTextBlock(kind: .item(ordered: false, depth: 0, number: nil),
                                            runs: [MailTextRun(text: String(line.dropFirst(2)))]))
            } else {
                blocks.append(MailTextBlock(kind: .paragraph, runs: [MailTextRun(text: line)]))
            }
        }
        return MailText(blocks: blocks)
    }

    /// The same number in every process, unlike `hashValue`: a row's tie-break is part of its
    /// place in the list.
    static func stableHash(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int64(truncatingIfNeeded: hash >> 1)
    }
}

/// A page-sized min-heap: exact counts still scan the in-memory fixture, but selecting fifty
/// rows must not sort or allocate sixty thousand. The SQL engine will use its own indexed query.
private struct MailTopRows {
    let limit: Int
    private var heap: [MailRow] = []
    init(limit: Int) { self.limit = limit }
    var sorted: [MailRow] { heap.sorted { $0.key > $1.key } }

    mutating func insert(_ row: MailRow) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(row)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[child].key < heap[parent].key else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        } else if row.key > heap[0].key {
            heap[0] = row
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, heap[child + 1].key < heap[child].key { child += 1 }
                guard heap[child].key < heap[parent].key else { break }
                heap.swapAt(child, parent)
                parent = child
            }
        }
    }
}
#endif

#endif
