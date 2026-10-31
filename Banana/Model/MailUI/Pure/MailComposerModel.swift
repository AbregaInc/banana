#if !BANANA_PUBLIC
import Foundation
import Combine

/// What a composer is started from: a new message, an answer to a conversation, or a draft he
/// already has.
enum MailComposeStart: Equatable, Sendable {
    case new
    case reply(MailConversationID)
    case replyAll(MailConversationID)
    case forward(MailConversationID)
    case continuing(MailDraftID)
}

/// One open composer: the text of one draft, as he is writing it (MAIL-UX 6.3.9).
///
/// **It belongs to the session, never to a view.** Its text is here, written into the draft the
/// source keeps 300 ms after the last edit, when it closes, when the app goes to the background and
/// before a send; so a view tree thrown away behind a backgrounded phone loses nothing, and the
/// composer is still open when the tree comes back.
///
/// **It is its own small observable.** The card observes it and nothing else does: a keystroke
/// changes `body` and re-evaluates the card, and nothing the list or the reading pane reads.
///
/// **It is drawn before it is ready** (6.3.9): it exists in the frame after the key, and the draft —
/// recipients, subject, quote — arrives from the source a moment later without disturbing what has
/// been typed meanwhile. Keys typed before the caret is there are queued here and put into the
/// field the caret lands in (K12), so a reply that begins "Each" is a reply that begins "Each".
@MainActor
final class MailComposerModel: ObservableObject {

    enum Field: Hashable, Sendable { case to, cc, bcc, subject, body }

    /// A request for the caret. The token makes a second request for the same field a change.
    struct FocusRequest: Equatable, Sendable {
        var field: Field
        var token: Int
    }

    /// Why a message cannot be sent yet.
    enum SendProblem: Equatable, Sendable {
        /// Something written and nobody to send it to.
        case nobody
        /// Nothing written and nobody addressed.
        case nothing
        /// Text in the To field that is not an address.
        case notAnAddress(String)
        /// The files on it weigh more than Gmail takes.
        case attachmentsTooLarge
    }

    /// What became of the draft when the composer was closed.
    enum Outcome: Equatable, Sendable {
        /// There was something in it: it is kept.
        case kept(MailDraftID)
        /// There was nothing in it, and nothing is left behind.
        case dropped
        /// The draft had not arrived: whatever it turns out to be is dealt with when it does.
        case pending
    }

    /// How long after the last edit the draft is handed to the source (6.3.9).
    static let saveAfter: TimeInterval = 0.3
    /// How long keys are queued for a caret that has not come (K12).
    static let caretWithin: TimeInterval = 1
    /// How many people are offered under the To field (6.3.3).
    static let suggestionLimit = 6

    let start: MailComposeStart

    @Published private(set) var title: String
    /// True once the draft has arrived and its recipients, subject and quote are filled in.
    @Published private(set) var isReady = false
    /// The conversation to answer was not there: there is no draft to write.
    @Published private(set) var failed = false

    @Published var to: [MailPerson] = []
    @Published var cc: [MailPerson] = []
    @Published var bcc: [MailPerson] = []
    /// What is typed in the To, Cc and Bcc fields and is not a chip yet.
    @Published var toText = "" { didSet { typedChanged(.to, from: oldValue) } }
    @Published var ccText = "" { didSet { typedChanged(.cc, from: oldValue) } }
    @Published var bccText = "" { didSet { typedChanged(.bcc, from: oldValue) } }
    /// The Cc and Bcc rows he has asked for. A row with someone in it, or text, is shown anyway.
    @Published private(set) var revealed: Set<MailRecipientField> = []
    /// Which row the suggestions under the rows are for.
    @Published private(set) var suggestionField: MailRecipientField = .to
    /// Who it is from; every address he can send as (shown only when there is a choice); what
    /// signs it, nil when nothing does or he has taken it off this message; and the time he has
    /// chosen to send it, when he has. Written by `MailComposerIdentity.swift` and
    /// `MailComposerSchedule.swift`, and by nothing else.
    @Published var from: MailIdentity?
    @Published private(set) var identities: [MailIdentity] = []
    @Published var signature: MailDraftPart?
    @Published var schedule: Date?
    /// The time picker while it is open, and the list of addresses to send as. Open or shut by
    /// the model, so a launch route can show either.
    @Published var timePicker: MailTimePickerModel?
    @Published var isChoosingFrom = false
    @Published var subject = "" { didSet { edited() } }
    /// What the editor holds: the text with its bold, italic, underline, links, lists and quotes
    /// (`MailRichText`). **This is the draft's text**, kept as it is typed; the view's own state is
    /// only where the caret is.
    // NSTextView can call the rich-text binding while SwiftUI holds an exclusive storage
    // mutation. Keep the draft current synchronously (including immediate Save/Send), but
    // notify views after that callback unwinds. Publishing here re-enters the editor and crashes.
    var rich = AttributedString() {
        didSet {
            guard rich != oldValue else { return }
            edited()
            guard !richNotificationPending else { return }
            richNotificationPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.richNotificationPending = false
                self.objectWillChange.send()
            }
        }
    }
    private var richNotificationPending = false
    /// The text without its formatting. Setting it puts plain text in.
    var body: String {
        get { String(rich.characters) }
        set { rich = AttributedString(newValue) }
    }
    /// The files on the draft (`MailComposerFiles`): the chips, and the way in for a new one.
    let files: MailComposerFiles
    /// What the body's keys and the format bar share (`MailComposerFormat`).
    let format = MailComposerFormat()
    /// What the views behind the Mac's chords do (`MailComposerChord`), registered by them.
    let chords = MailComposerChords()
    @Published private(set) var quote: MailDraftPart?
    @Published private(set) var suggestions: [MailPerson] = []
    @Published var highlighted = 0
    @Published private(set) var focusRequest: FocusRequest?
    /// Moves when the caret is to go to the end of what is in the field: after text is put in
    /// for him.
    @Published private(set) var caretToEnd = 0

    private(set) var draftID: MailDraftID?
    /// The conversation it is written in; nil for a new message.
    private(set) var host: MailConversationID?
    /// Whether the caret is asked for and has not come. While it is, the keys are this composer's.
    private(set) var awaitingFocus: Bool
    private var buffer = ""
    /// The field whose text is not an address, after `sendProblem()` found one.
    private(set) var problemField: Field = .to
    /// A change of From, and the signature's coming with it, in flight.
    var identityChange: Task<Void, Never>?

    // Not `private`: the identity and schedule members are in files of their own.
    let source: MailSource
    private let timers: MailTimers
    let clock: () -> Date
    /// How the screens name the device ("Mac"), for what a scheduled message says of who sends it.
    let device: String
    var draft: MailDraft?
    private var baseline = Baseline.blank
    private var isClosed = false
    private var wantsDiscard = false
    private var isSettingText = false
    private var loading: Task<Void, Never>?
    private var suggesting: Task<Void, Never>?
    private var cancelSave: (() -> Void)?
    private var cancelCaretWait: (() -> Void)?
    private var focusTokens = 0
    /// The newest request's token at the moment a caret last landed in any field. A request newer
    /// than this has not had its caret.
    private var landedAt = 0
    private var lastField: Field?

    /// What the draft was made as, so that "nothing was typed into it" can be told from "he
    /// changed the recipients" without the screen knowing a rule.
    private struct Baseline: Equatable {
        var to: [String]
        var cc: [String]
        var bcc: [String]
        var subject: String
        static let blank = Baseline(to: [], cc: [], bcc: [], subject: "")
    }

    init(start: MailComposeStart, source: MailSource, timers: MailTimers, clock: @escaping () -> Date,
         device: String, requestFocus: Bool = true) {
        self.start = start
        self.source = source
        self.timers = timers
        self.clock = clock
        self.device = device
        files = MailComposerFiles(source: source)
        awaitingFocus = requestFocus
        switch start {
        case .new: title = "New message"
        case .reply, .continuing: title = "Reply"
        case .replyAll: title = "Reply to all"
        case .forward: title = "Forward"
        }
        if case .reply(let id) = start { host = id }
        if case .replyAll(let id) = start { host = id }
        if case .forward(let id) = start { host = id }
        identities = source.accounts.flatMap(\.identities)
        files.draftID = { [weak self] in self?.draftID }
        files.whenReady = { [weak self] in await self?.waitForDraft() }
        files.changed = { [weak self] in self?.edited() }
        if requestFocus { askForFocus(initialField) }
    }

    /// Reply, forward and a draft he is coming back to start in the body; a new message in To.
    private var initialField: Field {
        if case .new = start { return .to }
        return .body
    }

    // MARK: Getting the draft

    /// Asks the source for the draft. The card is on screen already; this fills it in.
    func load() {
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            let fetched = await self.fetch()
            guard let fetched else {
                self.failed = true
                return
            }
            self.adopt(fetched.draft, fresh: fetched.fresh)
            // Text typed while it was coming is his, and is kept like any other.
            self.edited()
            if self.isClosed { _ = self.finishClosing() }
        }
    }

    /// Finishes when the draft has arrived. For tests.
    func waitForDraft() async {
        await loading?.value
    }

    private func fetch() async -> (draft: MailDraft, fresh: Bool)? {
        switch start {
        case .new:
            return (await source.newDraft(.new(account: nil)), true)
        case .continuing(let id):
            return await source.draft(id).map { ($0, false) }
        case .reply(let id), .replyAll(let id), .forward(let id):
            guard let conversation = await source.conversation(id) else { return nil }
            // A reply he has begun is the one he comes back to.
            if let kept = conversation.draft, let draft = await source.draft(kept) { return (draft, false) }
            guard let original = MailReplyRules.original(in: conversation) else { return nil }
            let kind: MailDraftKind
            switch start {
            case .replyAll: kind = .replyAll(to: original.id)
            case .forward: kind = .forward(original.id)
            default: kind = .reply(to: original.id)
            }
            return (await source.newDraft(kind), true)
        }
    }

    /// What the source made, in place of what was drawn while it was being made: whatever was
    /// typed meanwhile stays, after the text the draft already has.
    private func adopt(_ draft: MailDraft, fresh: Bool) {
        isSettingText = true
        defer { isSettingText = false }
        self.draft = draft
        draftID = draft.id
        let isOwn = draft.conversation.thread.hasPrefix("local:")
        host = isOwn ? nil : draft.conversation
        let typed = rich
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        from = draft.from
        signature = draft.signature
        // A time that has gone by while the draft waited is not one to send at.
        schedule = draft.schedule.flatMap { $0.at > clock() ? $0.at : nil }
        subject = draft.subject
        rich = MailRichText.attributed(draft.body) + typed
        // The draft's text arrived under a caret already in the body: the caret goes after it.
        if lastField == .body, !rich.characters.isEmpty { caretToEnd += 1 }
        files.adopt(draft.attachments)
        quote = draft.quote
        baseline = fresh ? Baseline(to: draft.to.map(Self.key), cc: draft.cc.map(Self.key),
                                    bcc: draft.bcc.map(Self.key), subject: draft.subject) : .blank
        if !fresh {
            if draft.isForward { title = "Forward" } else if draft.isReply { title = "Reply" } else { title = "New message" }
        }
        isReady = true
    }

    // MARK: Keys typed before the caret

    /// A key arrived that is his typing and not Mail's: it is kept, in order, for the field the
    /// caret lands in.
    func typeAhead(_ text: String) {
        buffer += text
    }

    func typeAheadDelete() {
        if !buffer.isEmpty { buffer.removeLast() }
    }

    /// What is waiting for the caret.
    var typedAhead: String { buffer }

    /// Asks for the caret, and until it comes the keys are queued. The queue is thrown away if
    /// the caret has not come in a second: a fault, and the keys go on being his (K12).
    func askForFocus(_ field: Field? = nil) {
        awaitingFocus = true
        focusTokens += 1
        focusRequest = FocusRequest(field: field ?? lastField ?? initialField, token: focusTokens)
        cancelCaretWait?()
        cancelCaretWait = timers.schedule(Self.caretWithin) { [weak self] in
            guard let self, self.awaitingFocus else { return }
            self.cancelCaretWait = nil
            self.awaitingFocus = false
            self.buffer = ""
        }
    }

    /// Whether the screen still has to put the caret where `request` asks: it is the newest
    /// request, the composer is open, and no caret has landed anywhere since it was made (a tap
    /// into another field is a landing, and is his). Says nothing of the one-second wait: the wait
    /// is for the keys typed meanwhile, and a caret that comes after it still belongs in its field.
    func isAsking(for request: FocusRequest) -> Bool {
        !isClosed && focusRequest == request && landedAt < request.token
    }

    /// The caret is in a field. What was typed on the way there goes into it, and the caret goes
    /// after it. The caret the composer asked for, landing for the first time in a body that
    /// already has text — a draft he is coming back to, a send he took back — goes after that
    /// text, where he left off (6.3.7); the editor would put it in front. A caret he put there
    /// himself, by a tap, stays where he put it.
    func focusLanded(on field: Field) {
        let asked = awaitingFocus, first = lastField == nil
        awaitingFocus = false
        landedAt = focusTokens
        cancelCaretWait?()
        cancelCaretWait = nil
        lastField = field
        guard !buffer.isEmpty else {
            if asked, first, field == .body, !rich.characters.isEmpty { caretToEnd += 1 }
            return
        }
        let queued = buffer
        buffer = ""
        switch field {
        case .body: rich.append(AttributedString(queued))
        case .subject: subject += queued
        case .to: toText += queued
        case .cc: ccText += queued
        case .bcc: bccText += queued
        }
        caretToEnd += 1
    }

    // MARK: Recipients

    /// Whatever is typed in a row that is an address becomes a chip; what is not stays as typed. An
    /// address that matches nobody he knows is a chip all the same, shown by its address.
    func commitTyped(_ field: MailRecipientField = .to) {
        let typed = text(of: field)
        let text = typed.trimmingCharacters(in: CharacterSet(charactersIn: " ,;\n"))
        guard !text.isEmpty else {
            if !typed.isEmpty { setText("", of: field) }
            return
        }
        let list = MailAddressList.parse(text)
        var left: [String] = []
        for item in list.items {
            switch item {
            case .mailbox(let address):
                add(MailPerson(name: address.name, address: address.address, isMe: false, isKnown: false,
                               fromTheirMail: false), to: field)
            case .unreadable(let unread):
                left.append(unread)
            case .emptyGroup:
                break
            }
        }
        setText(left.joined(separator: ", "), of: field)
        suggestions = []
    }

    /// A suggestion taken: the person, as the source knows them, into the row they were offered for.
    func accept(_ person: MailPerson, into field: MailRecipientField? = nil) {
        let field = field ?? suggestionField
        add(person, to: field)
        setText("", of: field)
        suggestions = []
        highlighted = 0
    }

    func moveHighlight(by step: Int) {
        guard !suggestions.isEmpty else { return }
        highlighted = min(max(highlighted + step, 0), suggestions.count - 1)
    }

    /// Return or Tab in a row: the highlighted suggestion if there is a list for it, otherwise what
    /// is typed.
    func acceptHighlightedOrCommit(_ field: MailRecipientField = .to) {
        if suggestionField == field, suggestions.indices.contains(highlighted) {
            accept(suggestions[highlighted], into: field)
        } else {
            commitTyped(field)
        }
    }

    func remove(_ person: MailPerson) {
        let key = person.address.lowercased()
        to.removeAll { $0.address.lowercased() == key }
        cc.removeAll { $0.address.lowercased() == key }
        bcc.removeAll { $0.address.lowercased() == key }
        edited()
    }

    /// Backspace in an empty row takes its last chip off.
    func removeLastRecipient(from field: MailRecipientField = .to) {
        guard text(of: field).isEmpty, let last = people(in: field).last else { return }
        remove(last)
    }

    /// A chip, put back into the text of its row to be changed.
    func edit(_ person: MailPerson) {
        guard let field = self.field(of: person) else { return }
        remove(person)
        setText(person.address, of: field)
        revealed.insert(field)
        askForFocus(field.field)
        caretToEnd += 1
    }

    /// A chip, taken from the row it is in and put in another.
    func move(_ person: MailPerson, to field: MailRecipientField) {
        guard self.field(of: person) != nil else { return }
        let key = person.address.lowercased()
        to.removeAll { $0.address.lowercased() == key }
        cc.removeAll { $0.address.lowercased() == key }
        bcc.removeAll { $0.address.lowercased() == key }
        add(person, to: field)
        revealed.insert(field)
    }

    /// The Cc or Bcc row, asked for: it appears with the caret in it.
    func reveal(_ field: MailRecipientField) {
        revealed.insert(field)
        askForFocus(field.field)
    }

    private func add(_ person: MailPerson, to field: MailRecipientField) {
        guard self.field(of: person) == nil else { return }
        switch field {
        case .to: to.append(person)
        case .cc: cc.append(person)
        case .bcc: bcc.append(person)
        }
        edited()
    }

    private func typedChanged(_ field: MailRecipientField, from old: String) {
        guard !isSettingText else { return }
        let now = text(of: field)
        if let last = now.last, ",;\n".contains(last), now != old {
            commitTyped(field)
            return
        }
        refreshSuggestions(for: field)
    }

    /// Asks per keystroke, and drops an answer that is not for what is typed now (6.3.9).
    private func refreshSuggestions(for field: MailRecipientField) {
        suggesting?.cancel()
        let typed = text(of: field).trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            if !suggestions.isEmpty, suggestionField == field { suggestions = [] }
            return
        }
        let source = self.source
        suggesting = Task { @MainActor [weak self] in
            let found = await source.people(matching: typed, limit: Self.suggestionLimit)
            guard !Task.isCancelled, let self,
                  self.text(of: field).trimmingCharacters(in: .whitespaces) == typed else { return }
            let taken = Set((self.to + self.cc + self.bcc).map { $0.address.lowercased() })
            self.suggestionField = field
            self.suggestions = found.filter { !taken.contains($0.address.lowercased()) }
            self.highlighted = 0
        }
    }

    /// Finishes when the suggestions asked for have arrived. For tests.
    func waitForSuggestions() async {
        await suggesting?.value
    }

    // MARK: What is in it

    /// Anything typed into it: text, or a change to who it goes to or what it is called. A reply
    /// that is only as the rules made it has nothing in it.
    var hasContent: Bool {
        if !MailPlainText.isBlank(body) { return true }
        if files.isChanged { return true }
        for field in MailRecipientField.all where !text(of: field).trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return Baseline(to: to.map(Self.key), cc: cc.map(Self.key), bcc: bcc.map(Self.key),
                        subject: subject) != baseline
    }

    /// Whether Send and Done means anything here: a conversation it is written in to be done.
    var canSendAndDone: Bool { host != nil }

    /// Why it cannot be sent, if it cannot (6.3.3). A typed address that is complete becomes a chip
    /// first.
    func sendProblem() -> SendProblem? {
        problemField = .to
        for field in MailRecipientField.all {
            commitTyped(field)
            let typed = text(of: field).trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty {
                problemField = field.field
                revealed.insert(field)
                return .notAnAddress(typed)
            }
        }
        if to.isEmpty && cc.isEmpty && bcc.isEmpty {
            return MailPlainText.isBlank(body) ? .nothing : .nobody
        }
        if files.isOver { return .attachmentsTooLarge }
        return nil
    }

    // MARK: Keeping it

    func edited() {
        guard !isSettingText else { return }
        cancelSave?()
        cancelSave = timers.schedule(Self.saveAfter) { [weak self] in
            self?.cancelSave = nil
            self?.save()
        }
    }

    /// The draft as he has it now, to hand to the source.
    func currentDraft() -> MailDraft? {
        guard var draft else { return nil }
        draft.to = to
        draft.cc = cc
        draft.bcc = bcc
        if let from { draft.from = from }
        draft.signature = signature
        draft.schedule = schedule.map { MailSchedule(at: $0, onThisDevice: true, isLate: false) }
        draft.subject = subject
        draft.body = MailRichText.text(rich)
        draft.attachments = files.items
        draft.encodedBytes = files.encodedBytes + body.utf8.count
        draft.editedAt = clock()
        return draft
    }

    /// Hands what is written to the source, if there is any.
    private func save() {
        guard isReady, hasContent, let current = currentDraft() else { return }
        source.save(current)
    }

    /// Writes it down now: when the app goes to the background, and before a send.
    func flush() {
        cancelSave?()
        cancelSave = nil
        save()
    }

    /// The composer is closed. A draft with something in it is kept; one nothing was typed into
    /// is discarded, with no undo and no toast (6.3.8).
    func close() -> Outcome {
        stop()
        guard isReady else { return .pending }
        return finishClosing()
    }

    /// The composer is closed to be sent: the draft as it is now, for the source to send. Nothing
    /// is saved or discarded here.
    func handOver() -> MailDraft? {
        stop()
        wantsDiscard = false
        return currentDraft()
    }

    /// The composer is closed and the draft is to go, whatever is in it. Nil when the draft has not
    /// arrived: it is discarded when it does.
    func discardNow() -> MailDraftID? {
        stop()
        wantsDiscard = true
        return draftID
    }

    /// No more saves, no more waiting for a caret, no more suggestions.
    private func stop() {
        isClosed = true
        cancelSave?()
        cancelSave = nil
        cancelCaretWait?()
        cancelCaretWait = nil
        suggesting?.cancel()
        identityChange?.cancel()
        buffer = ""
        awaitingFocus = false
    }

    private func finishClosing() -> Outcome {
        guard let id = draftID else { return .dropped }
        if wantsDiscard {
            source.discard(id)
            return .dropped
        }
        if hasContent, let current = currentDraft() {
            source.save(current)
            return .kept(id)
        }
        source.discard(id)
        return .dropped
    }

    /// The address as two of them are compared.
    private static func key(_ person: MailPerson) -> String {
        person.address.lowercased()
    }
}

extension MailPerson {
    /// A chip says their name when he has written to them before, and their address when he has
    /// not (MAIL-UX 6.3.3), so a look-alike cannot pass for someone he knows.
    var chipLabel: String {
        isKnown ? (name ?? address) : address
    }
}

extension MailDraftPart {
    /// "On Mon 5 Oct, 9:12 AM, Sam Lee wrote:": the quote's first line, which is what it says when it
    /// is folded.
    var attribution: String {
        guard let first = text?.blocks.first else { return "" }
        return MailAttributedText.plain(first.runs)
    }

    /// What the quote says, as text; nil for a part with no body to show.
    var text: MailText? {
        switch body {
        case .text(let text, _, _): return text
        case .designed(_, _, _, let plain, _): return plain
        case .notOnDevice: return nil
        }
    }
}

#endif
