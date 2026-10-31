import XCTest
import Combine

/// A mailbox, a source that behaves as the contract says one does, and the screen's loop around
/// the model — enough to press keys and read what the screen would show.
///
/// The source is the part the model must be able to trust, so it is written to the contract and
/// to nothing the model does: a command is applied to the one mailbox, every observed list is
/// handed a reading that carries it before the command returns (promise 2), and a change from
/// "elsewhere" is a reading with the same `appliedThrough` as the last. A list is observed with a
/// limit, as `observeList` is: the reading holds the first `limit` rows and says whether there
/// are more, and the model's `growTo` is answered by a larger one. Membership of a list is
/// decided here from the row's flags, not through `MailRowRules`, so that a row the model drew
/// as changed and a row the source holds can disagree and the model be made to cope.
///
/// The loop is what `MailSession` and `MailTriage` will be: it carries out the model's effects
/// in order, hands receipts back, keeps the undo stack, and shows a toast.
@MainActor
final class TriageHarness {

    nonisolated static let account = "me@example.com"
    nonisolated static let otherAccount = "you@example.com"
    /// An arbitrary fixed moment: nothing here reads a clock.
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    let important = MailScope(place: .split(MailSplit.importantID))
    let other = MailScope(place: .split(MailSplit.otherID))
    let inbox = MailScope(place: .mailbox(.inbox))

    // MARK: The source

    /// Every conversation, newest first.
    var mailbox: [MailRow] = []
    private(set) var sequence: UInt64 = 0
    /// Whether a row still matches a search, which is the one place the rules cannot say.
    var searchMatches: (MailRow) -> Bool = { _ in true }
    /// Conversations with a reply the reader has not shown (T45): a message-level change leaves
    /// them in the inbox, unread.
    var unseenReply: Set<String> = []
    /// What each command did to the conversations it touched, as they were.
    private var before: [UInt64: [MailRow]] = [:]
    /// Every message-level change asked for.
    private(set) var messageChanges: [(MailChange, MailMessageID)] = []
    var offline = false
    /// How many rows an observation is given: the first `limit` of the place. A longer place has
    /// `hasMore`. The model's `growTo` raises it for that place, as observing again with a larger
    /// limit does; this is what a place is given before it has asked for more.
    var limit = Int.max
    private var limits: [MailScope: Int] = [:]

    func limit(for scope: MailScope) -> Int { limits[scope] ?? limit }
    /// Whether a model that is not in front is handed readings (the session may observe six
    /// lists, or one).
    var observesWhileAway = true
    /// Whether the reading that carries an undo reaches the model before `undo` returns. A model
    /// that was not observing when Undo was pressed is given none.
    var deliversOnUndo = true
    /// Whether `show` starts an observation, as the session does (MAIL-UX 3.11): the first value
    /// it delivers is marked as the answer to the entry.
    var observesOnEntry = false
    /// What the run has reached, for a seeded run to say it reached it.
    private(set) var growthsWithAChip = 0
    private(set) var checksFinished = 0
    private(set) var entriesAnswered = 0

    // MARK: The screen

    private(set) var models: [MailScope: MailListModel] = [:]
    private(set) var showing: MailScope
    var stack = MailUndoStack()
    private(set) var toasts: [MailToast] = []
    /// Everything the models asked for, in order.
    private(set) var effects: [MailListEffect] = []
    /// What was asked of the source.
    private(set) var performed: [MailPerformRequest] = []
    /// The screen half of every Send and Done entry, as the model handed it over.
    private(set) var settled: [MailUndoEntry] = []
    var now = TriageHarness.now

    var model: MailListModel { models[showing]! }

    init(scope: MailScope? = nil, rows: Int = 10, limit: Int = .max, otherAccountRows: Set<Int> = []) {
        showing = scope ?? MailScope(place: .split(MailSplit.importantID))
        mailbox = (0..<rows).map {
            Self.row(Self.letter($0), rank: $0,
                     account: otherAccountRows.contains($0) ? Self.otherAccount : Self.account)
        }
        self.limit = limit
        show(showing)
    }

    // MARK: Building rows

    /// A to Z, then R26, R27 and so on for a longer list.
    static func letter(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "R\(index)"
    }

    static func id(_ letter: String, account: String = TriageHarness.account) -> MailConversationID {
        MailConversationID(account: account, thread: letter)
    }

    func id(_ letter: String) -> MailConversationID {
        mailbox.first { $0.id.thread == letter }?.id ?? Self.id(letter)
    }

    /// Rank 0 is the newest; a negative rank is newer than anything in the mailbox.
    static func row(_ letter: String, rank: Int, inInbox: Bool = true, unread: Bool = true,
                    important: Bool = true, starred: Bool = false,
                    subject: String? = nil, snippet: String? = nil,
                    account: String = TriageHarness.account) -> MailRow {
        MailRow(id: id(letter, account: account),
                key: MailOrderKey(group: 0, sortKey: Int64(100_000 - rank * 100), tie: Int64(rank)),
                date: now.addingTimeInterval(TimeInterval(-rank * 3_600)),
                people: [], peopleTotal: 0, messageCount: 1,
                subject: subject ?? "Subject \(letter)", snippet: snippet ?? "Snippet \(letter)",
                isUnread: unread, isStarred: starred, isImportant: important, hasAttachment: false,
                isInvitation: false, inInbox: inInbox, isMuted: false, hasPendingChange: false,
                fromGmailSearch: false, labels: [], reason: nil)
    }

    /// A position as the host reports it: the row's key as the list holds it, and points.
    func viewport(_ letter: String, offset: Int = 0) -> MailViewport {
        let row = model.rows.first { $0.id.thread == letter }!
        return MailViewport(firstRow: row.id, key: row.key, offset: offset)
    }

    // MARK: Lists, readings

    func belongs(_ row: MailRow, to scope: MailScope) -> Bool {
        let inPlace: Bool
        switch scope.place {
        case .split(let id):
            inPlace = row.inInbox && (id == MailSplit.importantID ? row.isImportant : !row.isImportant)
        case .mailbox(.inbox): inPlace = row.inInbox
        case .mailbox(.done): inPlace = !row.inInbox
        case .mailbox(.starred): inPlace = row.isStarred
        case .search: inPlace = searchMatches(row)
        default: inPlace = true
        }
        guard inPlace else { return false }
        if scope.filters.contains(.unread), !row.isUnread { return false }
        if scope.filters.contains(.starred), !row.isStarred { return false }
        if scope.filters.contains(.important), !row.isImportant { return false }
        return true
    }

    func members(of scope: MailScope) -> [MailRow] {
        mailbox.filter { belongs($0, to: scope) }.sorted { $0.key > $1.key }
    }

    func snapshot(for scope: MailScope, appliedThrough: UInt64? = nil) -> MailListSnapshot {
        let all = members(of: scope)
        let rows = Array(all.prefix(limit(for: scope)))
        return MailListSnapshot(scope: scope, rows: rows,
                                total: MailCount(value: all.count, isAtLeast: false),
                                hasMore: all.count > rows.count, stillLoading: 0,
                                isRebuilding: false, remote: nil, coverage: nil,
                                appliedThrough: appliedThrough ?? sequence)
    }

    /// Hands every observed list a reading that carries the mailbox as it is.
    func deliver() {
        for (scope, model) in models where observesWhileAway || scope == showing {
            model.handle(.snapshot(snapshot(for: scope)))
        }
    }

    // MARK: Commands, as the source takes them

    func apply(_ change: MailChange, to target: MailTarget) -> MailReceipt {
        var ids: [MailConversationID] = []
        var count: Int?
        switch target {
        case .reading(let readings):
            ids = readings.map(\.id)
            count = ids.count
        case .conversations(let list):
            ids = list
            count = list.count
        case .scope(let scope, let from):
            ids = members(of: scope).filter { from == nil || $0.key <= from! }.map(\.id)
        case .message(let message):
            ids = [MailConversationID(account: message.account,
                                      thread: String(message.message.prefix { $0 != "-" }))]
            messageChanges.append((change, message))
            count = 1
        }
        sequence += 1
        before[sequence] = mailbox.filter { ids.contains($0.id) }
        for index in mailbox.indices where ids.contains(mailbox[index].id) {
            if case .message = target, unseenReply.contains(mailbox[index].id.thread) {
                // The earlier messages are dealt with; the reply is not, so it is still here.
                mailbox[index].hasPendingChange = true
                continue
            }
            switch MailRowRules.apply(change, to: mailbox[index], in: inbox) {
            case .stays(let row), .leaves(let row), .unknown(let row): mailbox[index] = row
            }
        }
        deliver()
        return MailReceipt(sequence: sequence, count: count ?? ids.count)
    }

    /// Puts back exactly what that command changed.
    func undo(_ receipt: MailReceipt) -> MailReceipt {
        let rows = before[receipt.sequence] ?? []
        for row in rows {
            if let index = mailbox.firstIndex(where: { $0.id == row.id }) { mailbox[index] = row }
        }
        sequence += 1
        if deliversOnUndo { deliver() }
        return MailReceipt(sequence: sequence, count: rows.count)
    }

    /// Gmail will never accept it: the source shows the conversations as Gmail has them, with the
    /// reason on the row, and says so. `eventFirst` is which of the two the screen hears first.
    func refuse(_ receipt: MailReceipt, _ failure: MailFailure, eventFirst: Bool = false) {
        let rows = before[receipt.sequence] ?? []
        let entry = stack.remove(receipt: receipt)
        func revert() {
            for var row in rows {
                row.reason = .changeRefused(failure)
                if let index = mailbox.firstIndex(where: { $0.id == row.id }) { mailbox[index] = row }
            }
        }
        func tell() {
            guard let entry else { return }
            for effect in models[entry.scope]?.handle(.reverted(entry, .refused(failure))) ?? [] {
                carry(effect)
            }
        }
        if eventFirst {
            tell()
            revert()
            deliver()
        } else {
            revert()
            deliver()
            tell()
        }
    }

    /// A change that did not come from this device's hands: a reading with the same
    /// `appliedThrough` as before.
    func outside(_ change: (inout [MailRow]) -> Void) {
        change(&mailbox)
        deliver()
    }

    func arrive(_ letter: String, rank: Int = -1, important: Bool = true) {
        outside { $0.append(Self.row(letter, rank: rank, important: important)) }
    }

    private var restocked = 0

    /// Older mail still being downloaded: enough of it that the place in front has more than the
    /// window holds, so that `hasMore` is true.
    func restock(extra: Int = 60) {
        // Only while the window is small: a seeded run is thousands of inputs, and each is
        // delivered whole to every place observed.
        let current = limit(for: showing)
        let wanted = current >= 400 ? 0 : current + extra - members(of: showing).count
        guard wanted > 0 else { return }
        let important = showing == self.important
        outside { rows in
            for _ in 0..<wanted {
                restocked += 1
                rows.append(Self.row("X\(restocked)", rank: 100_000 + restocked, important: important))
            }
        }
    }

    func outsideDone(_ letter: String) {
        outside { rows in
            if let index = rows.firstIndex(where: { $0.id.thread == letter }) {
                rows[index].inInbox = false
                rows[index].isUnread = false
            }
        }
    }

    /// New mail in a conversation: it sorts above everything, and says so. Two of them never
    /// share a key.
    func newMail(in letter: String, snippet: String = "New mail") {
        newMailTick += 1
        let tick = newMailTick
        outside { rows in
            if let index = rows.firstIndex(where: { $0.id.thread == letter }) {
                rows[index].isUnread = true
                rows[index].snippet = snippet
                rows[index].key = MailOrderKey(group: 0, sortKey: 200_000 + Int64(tick) * 10, tie: Int64(tick))
            }
        }
    }
    private var newMailTick = 0

    // MARK: Showing a place

    /// What the session does on a tab: leave the one in front, make the model if there is none,
    /// give it its first reading, and enter it.
    func show(_ scope: MailScope, carrying hint: MailCursorHint? = nil) {
        if let current = models[showing], showing != scope { current.handle(.leave) }
        showing = scope
        if models[scope] == nil {
            let new = MailListModel(scope: scope, carrying: hint, deviceName: "iPhone",
                                    timePhrase: { _ in "Thu 8 AM" })
            models[scope] = new
            new.handle(.snapshot(snapshot(for: scope)))
        }
        send(.enter)
        if observesOnEntry { answerEntry() }
    }

    /// The session's mark: the first value the observation started for an entry delivers is the
    /// answer to that entry, and the model takes it whole.
    func answerEntry() {
        entriesAnswered += 1
        model.handle(.snapshot(snapshot(for: showing), answersEntry: true))
    }

    /// The session's other fact: the check he asked for has answered.
    func finishCheck() {
        checksFinished += 1
        send(.checkFinished)
    }

    // MARK: Pressing keys

    /// Gives the model an input and carries out what it asks, in order, the way the screen
    /// will: a change goes to the source and the receipt comes back.
    @discardableResult
    func send(_ input: MailListInput) -> [MailListEffect] {
        var all: [MailListEffect] = []
        var queue = model.handle(input)
        while !queue.isEmpty {
            let effect = queue.removeFirst()
            all.append(effect)
            queue.append(contentsOf: carry(effect))
        }
        return all
    }

    /// Carries one effect out; the model's answer to it, if any, is what comes back.
    @discardableResult
    private func carry(_ effect: MailListEffect) -> [MailListEffect] {
        effects.append(effect)
        switch effect {
        case .perform(let request):
            performed.append(request)
            let receipt = apply(request.change, to: request.target)
            return model.handle(.performed(token: request.token, receipt))
        case .pushUndo(let entry):
            stack.push(entry, at: now)
        case .settled(let entry):
            settled.append(entry)
        case .toast(let toast):
            toasts.append(toast)
        case .growTo(let newLimit):
            // Observing again with a larger limit: the first value arrives at once.
            if model.arrivals > 0 { growthsWithAChip += 1 }
            limits[showing] = newLimit
            deliver()
        default:
            break
        }
        return []
    }

    @discardableResult
    func press(_ action: MailAction, on row: String? = nil) -> [MailListEffect] {
        send(.act(action, on: row.map(id)))
    }

    func done() { press(.done) }

    private(set) var completedSettled = 0
    /// How often an undo was asked for in a place that was not in front, and how many were undone:
    /// what a seeded run says it reached.
    private(set) var undoneAcrossPlaces = 0
    private(set) var undone = 0

    /// The composer finishes the oldest Send and Done it has not yet finished.
    func completePendingSend() {
        guard completedSettled < settled.count else { return }
        let entry = settled[completedSettled]
        completedSettled += 1
        completeSend(entry)
    }

    /// The composer's half of Send and Done: its send carries the Done, so the source applies it
    /// and answers with the one receipt, and the composer completes the model's entry with it
    /// and pushes it (T38).
    @discardableResult
    func completeSend(_ entry: MailUndoEntry, holdEnds: TimeInterval = 10) -> MailUndoEntry {
        var entry = entry
        let receipt = apply(.done, to: .conversations(entry.rowsBefore.map(\.id)))
        entry.receipt = receipt
        entry.kind = .send(MailDraftID(raw: "draft-1"), holdEnds: now.addingTimeInterval(holdEnds),
                           doneSubject: entry.subjects.first)
        stack.push(entry, at: now)
        return entry
    }

    /// `Z` with no toast to answer: the top of the stack.
    @discardableResult
    func undoTop() -> MailUndoOutcome? {
        switch stack.beginUndo(now: now) {
        case .nothingToUndo:
            return nil
        case .reverse(let entry):
            let answer = reverse(entry)
            let outcome = stack.outcome(reversing: entry, answer: answer)
            toasts.append(outcome.toast)
            if case .undone = outcome {
                for effect in models[entry.scope]?.handle(.restore(entry, through: answer.sequence)) ?? [] {
                    carry(effect)
                }
            }
            return outcome
        case .cancelSend(let entry):
            // The send is cancelled (the composer's) and the Done reversed: `undo(receipt)`.
            let outcome = stack.outcome(cancelling: entry, succeeded: true)
            toasts.append(outcome.toast)
            restoreAfterSend(entry)
            return outcome
        case .alreadySent(let entry):
            // Nothing is unsent; `undo(receipt)` reverses the Done alone.
            let outcome = stack.outcome(forAlreadySent: entry)
            toasts.append(outcome.toast)
            restoreAfterSend(entry)
            return outcome
        }
    }

    /// Shows the entry's place, as the session does, and has the source undo it.
    private func reverse(_ entry: MailUndoEntry) -> MailReceipt {
        undone += 1
        if showing != entry.scope {
            undoneAcrossPlaces += 1
            show(entry.scope)
        }
        return undo(entry.receipt)
    }

    private func restoreAfterSend(_ entry: MailUndoEntry) {
        guard !entry.rowsBefore.isEmpty else { return }
        let answer = reverse(entry)
        for effect in models[entry.scope]?.handle(.restore(entry, through: answer.sequence)) ?? [] {
            carry(effect)
        }
    }

    // MARK: Reading the screen

    static func letters(_ ids: some Sequence<MailConversationID>) -> String {
        ids.map(\.thread).sorted().joined()
    }

    /// The rows shown, as letters, in order.
    var shown: String { model.rows.map(\.id.thread).joined() }
    var cursor: String? { model.cursor?.thread }
    var selected: String { Self.letters(model.selectedIDs) }
    var openLetter: String? { model.open?.id.thread }

    func row(_ letter: String) -> MailRow? { model.rows.first { $0.id.thread == letter } }

    func has(_ effect: MailListEffect) -> Bool { effects.contains(effect) }

    /// The growth the model has asked for so far, in order.
    var growths: [Int] {
        effects.compactMap { if case .growTo(let limit) = $0 { return limit } else { return nil } }
    }
}

// MARK: - The rules

/// One test for each of the triage rules T0 to T45 that the model decides, named for the rule
/// (MAIL-UX section 3). The forty worked cases are in `MailTriageCasesTests`; the undo stack's
/// rules, T25 to T30 and T44, are in `MailUndoStackTests`.
///
/// Not tested here, because the model does not decide them: T35 (offline is not a mode — the
/// model has no word for the network, so there is nothing to test; the status line is U15b's),
/// T41 (the action bar's fixed positions — a view), and the parts of T2, T10, T18, T26, T39 and
/// T43 that are drawing, a timer, a gesture, a held key or the toast's own state.
@MainActor
final class MailListModelTests: XCTestCase {

    func testActionCarriesTheDisplayedRowsArrivalBoundary() {
        let h = TriageHarness()
        h.mailbox[0].actionBoundary = 41
        h.send(.snapshot(h.snapshot(for: h.important), answersEntry: true))
        let shownDate = h.model.rows[0].date
        // The source can know newer mail while the displayed reading is unchanged.
        h.mailbox[0].actionBoundary = 99
        let effects = h.model.handle(.act(.done, on: h.id("A")))
        guard case .perform(let request)? = effects.first,
              case .reading(let readings) = request.target else { return XCTFail("Missing displayed reading") }
        XCTAssertEqual(readings, [MailActionReading(id: h.id("A"), asOf: Int64(shownDate.timeIntervalSince1970 * 1000), arrivalSequence: 41)])
    }

    // MARK: T0 to T2: one model, one cursor

    func testT0_anActionAppliesRemembersAndSettlesInOneTurn() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        let effects = h.model.handle(.act(.done, on: nil))

        // Apply: what the screen shows has changed before anything else happens, and the source
        // is the first thing asked.
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
        guard case .perform(let request)? = effects.first else { return XCTFail("no perform") }
        XCTAssertEqual(request.change, .done)
        XCTAssertEqual(request.target, .conversations([h.id("C")]))
        // Settle: the cursor has moved to the nearest conversation left.
        XCTAssertEqual(h.cursor, "D")
        // Remember: the entry comes with the receipt, and holds what was showing.
        let after = h.model.handle(.performed(token: request.token, MailReceipt(sequence: 1, count: 1)))
        guard case .pushUndo(let entry)? = after.first else { return XCTFail("no entry") }
        XCTAssertEqual(entry.cursor, h.id("C"))
        XCTAssertEqual(entry.scope, h.important)
        XCTAssertEqual(entry.rowsBefore.map(\.id), [h.id("C")])
    }

    func testT0_aMarkingActionMovesNothing() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.press(.toggleStar)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.stack.count, 1)
    }

    func testT1_rowsAreInTheOrderTheSourceDeliveredAndAreNeverSorted() {
        let h = TriageHarness()
        // A reading in an order that is not by key. The model draws it as given.
        var rows = h.members(of: h.important)
        rows.swapAt(0, 9)
        let snapshot = MailListSnapshot(scope: h.important, rows: rows, total: .init(value: 10, isAtLeast: false),
                                        hasMore: false, stillLoading: 0, isRebuilding: false,
                                        remote: nil, coverage: nil, appliedThrough: 0)
        h.model.handle(.idle)
        h.model.handle(.snapshot(snapshot))
        XCTAssertEqual(h.shown, "JBCDEFGHIA")
    }

    func testT1_anOutsideReorderingIsFollowedAsDelivered() {
        let h = TriageHarness()
        h.model.handle(.idle)
        h.newMail(in: "F")
        XCTAssertEqual(h.shown, "FABCDEGHIJ")
    }

    func testT2_aListWithAConversationHasExactlyOneCursorAndAnEmptyOneHasNone() {
        let h = TriageHarness()
        XCTAssertEqual(h.cursor, "A")
        var marks: [MailMarkChange] = []
        let watch = h.model.markChanges.sink { marks.append($0) }
        h.send(.move(.older))
        XCTAssertEqual(marks, [.cursor(from: h.id("A"), to: h.id("B"))])
        withExtendedLifetime(watch) {}

        let empty = TriageHarness(rows: 0)
        XCTAssertNil(empty.cursor)
        XCTAssertEqual(empty.shown, "")
    }

    func testT2_theCursorIsPlacedByAClickOrATapAndIsTheRowLastTapped() {
        let h = TriageHarness()
        h.send(.place(h.id("G")))
        XCTAssertEqual(h.cursor, "G")
    }

    // MARK: T3: entering a place

    func testT3_aFirstVisitPutsTheCursorOnTheFirstConversationAtTheTopTravellingOlder() {
        let h = TriageHarness()
        XCTAssertEqual(h.cursor, "A")
        XCTAssertEqual(h.model.direction, .older)
        XCTAssertTrue(h.has(.scrollToTop))
    }

    func testT3_aFirstVisitDoesNotDependOnWhetherTheReadingOrTheVisitComesFirst() {
        let h = TriageHarness()
        let model = MailListModel(scope: h.other, deviceName: "iPhone", timePhrase: { _ in "" })
        model.handle(.enter)
        model.handle(.snapshot(h.snapshot(for: h.other)))   // an empty place: nothing is Other
        XCTAssertNil(model.cursor)
        h.mailbox[3].isImportant = false
        h.mailbox[4].isImportant = false
        model.handle(.idle)                                  // entering did not make it rest
        model.handle(.snapshot(h.snapshot(for: h.other)))
        XCTAssertEqual(model.cursor?.thread, "D")
    }

    func testT3_aReturnPutsTheCursorBackAndTheListWhereItWas() {
        let h = TriageHarness()
        h.send(.place(h.id("F")))
        let viewport = h.viewport("D", offset: 12)
        h.send(.scrolled(viewport))
        h.send(.move(.newer))                      // cursor on E, direction newer
        h.show(h.other)
        h.show(h.important)
        XCTAssertEqual(h.cursor, "E")
        XCTAssertEqual(h.model.direction, .older)
        XCTAssertTrue(h.has(.restoreViewport(viewport)))
    }

    func testT3_aReturnPutsTheCursorOnItsSuccessorWhenItsConversationHasLeft() {
        let h = TriageHarness()
        h.send(.place(h.id("E")))
        h.show(h.other)
        h.outsideDone("E")
        h.show(h.important)
        XCTAssertEqual(h.shown, "ABCDFGHIJ")
        XCTAssertEqual(h.cursor, "F")
    }

    func testT3_aReturnDropsTheRowsThatWereBeingKept() {
        let h = TriageHarness(scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        h.send(.place(h.id("C")))
        h.press(.toggleRead)
        XCTAssertNotNil(h.row("C"))
        h.show(h.other)
        h.show(MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        XCTAssertNil(h.row("C"))
    }

    // MARK: T4, T5: moving

    func testT4_jAndKMoveTheCursorAndSetTheDirection() {
        let h = TriageHarness()
        h.send(.move(.older))
        h.send(.move(.older))
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.model.direction, .older)
        h.send(.move(.newer))
        XCTAssertEqual(h.cursor, "B")
        XCTAssertEqual(h.model.direction, .newer)
    }

    func testT4_atEitherEndNothingHappens() {
        let h = TriageHarness()
        let before = h.effects.count
        h.send(.move(.newer))
        XCTAssertEqual(h.cursor, "A")
        XCTAssertEqual(h.effects.count, before, "not even a scroll")
        h.send(.jumpToOldest)
        h.send(.move(.older))
        XCTAssertEqual(h.cursor, "J")
    }

    func testT4_theViewIsAskedToShowTheCursorRowWithOneMoreBeyondItInTheDirectionOfTravel() {
        let h = TriageHarness()
        let older = h.send(.move(.older))
        XCTAssertEqual(older, [.reveal(h.id("B"), beyond: .older)])
        let newer = h.send(.move(.newer))
        XCTAssertEqual(newer, [.reveal(h.id("A"), beyond: .newer)])
    }

    func testT4_commandDownAndUpGoToTheOldestRowLoadedAndTheFirstBothTravellingOlder() {
        let h = TriageHarness()
        h.send(.move(.newer))
        h.send(.jumpToOldest)
        XCTAssertEqual(h.cursor, "J")
        XCTAssertEqual(h.model.direction, .older)
        h.send(.move(.newer))
        h.send(.jumpToNewest)
        XCTAssertEqual(h.cursor, "A")
        XCTAssertEqual(h.model.direction, .older)
    }

    func testT4_aPageMovesTheCursorToTheFirstRowWhollyOnScreenIfItLeftTheScreen() {
        let h = TriageHarness()
        XCTAssertEqual(h.send(.page(.older)), [.scrollPage(.older)])
        h.send(.pagedTo(MailVisibleRows(first: h.id("D"), last: h.id("H"))))
        XCTAssertEqual(h.cursor, "D")
        // A page after which the cursor is still on screen leaves it.
        h.send(.place(h.id("F")))
        h.send(.pagedTo(MailVisibleRows(first: h.id("D"), last: h.id("H"))))
        XCTAssertEqual(h.cursor, "F")
    }

    func testT5_movingTheCursorMarksNothingReadAndIsNeverAnUndoStep() {
        let h = TriageHarness()
        h.send(.move(.older))
        h.send(.move(.older))
        h.send(.jumpToOldest)
        XCTAssertTrue(h.performed.isEmpty)
        XCTAssertTrue(h.stack.isEmpty)
        XCTAssertTrue(h.model.rows.allSatisfy(\.isUnread))
    }

    // MARK: T6: successor

    func testT6_theSuccessorIsTheNearestAtOrBeyondInTheDirectionOfTravelThatIsNotATarget() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        // Done on C and D together: E is the nearest older that is not a target.
        h.send(.toggleSelected(h.id("C")))
        h.send(.toggleSelected(h.id("D")))
        h.done()
        XCTAssertEqual(h.cursor, "E")
    }

    func testT6_failingThatTheNearestTheOtherWay() {
        let h = TriageHarness()
        h.send(.place(h.id("I")))
        h.send(.toggleSelected(h.id("I")))
        h.send(.toggleSelected(h.id("J")))
        h.done()
        XCTAssertEqual(h.cursor, "H")
    }

    func testT6_aCursorConversationThatWasNotATargetIsItsOwnSuccessor() {
        let h = TriageHarness()
        h.send(.place(h.id("H")))
        h.send(.toggleSelected(h.id("B")))
        h.done()
        XCTAssertEqual(h.cursor, "H")
    }

    func testT6_ifEveryConversationWasATargetTheCursorStaysIfItsRowStaysAndOtherwiseThereIsNone() {
        // Done in All mail: the rows stay, and are all targets.
        let h = TriageHarness(scope: MailScope(place: .mailbox(.all)), rows: 4)
        h.send(.place(h.id("B")))
        h.send(.selectAll)
        h.done()
        XCTAssertEqual(h.cursor, "B", "its row is still in the list")

        // Done in the inbox: the rows leave, and with them the cursor.
        let g = TriageHarness(scope: MailScope(place: .mailbox(.inbox)), rows: 4)
        g.send(.selectAll)
        g.done()
        XCTAssertNil(g.cursor)
        XCTAssertEqual(g.shown, "")
    }

    // MARK: T7: what a row says is current; where rows are changes when idle

    func testT7_whatARowSaysIsRedrawnAtOnceWhereTheRowIs() {
        let h = TriageHarness()
        h.send(.move(.older))                    // not idle
        h.outside { $0[5].snippet = "A new snippet"; $0[5].isStarred = true; $0[5].isUnread = false }
        XCTAssertEqual(h.row("F")?.snippet, "A new snippet")
        XCTAssertEqual(h.row("F")?.isStarred, true)
        XCTAssertEqual(h.row("F")?.isUnread, false)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
    }

    func testT7_rowsAreAddedRemovedAndMovedOnlyWhenTheListIsIdleAndThenAllAtOnce() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.outsideDone("G")
        h.arrive("N")
        h.newMail(in: "I")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "nothing moves under the hand")
        h.send(.idle)
        XCTAssertEqual(h.shown, "INABCDEFHJ", "I has the newest mail, then N, then the rest without G")
    }

    func testT7_aPersonsOwnActionIsNeverDelayedByIt() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.arrive("N")
        h.done()
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
    }

    // MARK: T8: what an outside change does when it is applied

    func testT8a_aConversationThatLeftTheListDisappearsAndTheCursorGoesToItsSuccessor() {
        let h = TriageHarness()
        h.send(.place(h.id("D")))
        h.outsideDone("D")
        h.send(.idle)
        XCTAssertEqual(h.shown, "ABCEFGHIJ")
        XCTAssertEqual(h.cursor, "E")
    }

    func testT8a_theSuccessorOfARemovedCursorFollowsTheDirectionOfTravel() {
        let h = TriageHarness()
        h.send(.place(h.id("D")))
        h.send(.move(.newer))                     // C, travelling newer
        h.outsideDone("C")
        h.send(.idle)
        XCTAssertEqual(h.cursor, "B")
    }

    func testT8b_aConversationWithNewMailTakesItsPlaceInTheOrder() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.newMail(in: "H")
        h.send(.idle)
        XCTAssertEqual(h.shown, "HABCDEFGIJ")
    }

    func testT8b_theConversationUnderTheCursorDoesNotMoveUntilTheCursorHasLeftIt() {
        let h = TriageHarness()
        h.send(.place(h.id("E")))
        h.newMail(in: "E")
        h.send(.idle)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.row("E")?.snippet, "New mail")
        h.send(.move(.older))
        h.send(.idle)
        XCTAssertEqual(h.shown, "EABCDFGHIJ")
        XCTAssertEqual(h.cursor, "F")
    }

    // MARK: T9: arrivals at the top

    func testT9_arrivalsJoinTheTopOfAListThatIsAtItsTopAndIdle() {
        let h = TriageHarness()
        h.send(.idle)
        h.arrive("N")
        XCTAssertEqual(h.shown, "NABCDEFGHIJ")
        XCTAssertEqual(h.cursor, "A")
        XCTAssertEqual(h.model.arrivals, 0)
    }

    func testT9_otherwiseTheyWaitInTheChip() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.arrive("N")
        h.arrive("M", rank: -2)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.model.arrivals, 2)
        XCTAssertEqual(h.model.list.shown.arrivals, 2)
    }

    func testT9_theyJoinWhenTheTopIsNextOnScreenAndTheListIsIdle() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.arrive("N")
        h.send(.idle)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "at rest, but the top is not showing")
        h.send(.firstRowOnScreen(true))
        XCTAssertEqual(h.shown, "NABCDEFGHIJ")
        XCTAssertEqual(h.model.arrivals, 0)
    }

    func testT9_theyJoinWhenTheChipIsUsedAndTheViewGoesToTheTop() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.send(.place(h.id("D")))
        h.arrive("N")
        let effects = h.send(.chipUsed)
        XCTAssertEqual(h.shown, "NABCDEFGHIJ")
        XCTAssertEqual(effects, [.scrollToTop])
        XCTAssertEqual(h.cursor, "D", "the chip does not move the cursor")
    }

    func testT9_commandUpJoinsThemAndPutsTheCursorOnTheFirstRow() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.send(.place(h.id("D")))
        h.arrive("N")
        h.send(.jumpToNewest)
        XCTAssertEqual(h.shown, "NABCDEFGHIJ")
        XCTAssertEqual(h.cursor, "N")
    }

    func testT9_noRowIsEverInsertedAboveAListThatIsNotShowingItsTopEvenWhenIdle() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.send(.idle)
        h.arrive("N")
        h.outsideDone("H")                         // not above the top: it is applied
        XCTAssertEqual(h.shown, "ABCDEFGIJ")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    func testT9_aConversationWithNewMailThatWouldMoveAboveTheFirstRowIsHeldToo() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.newMail(in: "H")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.model.arrivals, 1)
        XCTAssertEqual(h.row("H")?.snippet, "New mail", "what it says is current")
    }

    // MARK: T10 to T13: opening and closing

    func testT10_openShowsTheConversationAndMarksItReadOnlyOnceItHasBeenShowingFor400ms() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        let effects = h.send(.open(nil))
        XCTAssertTrue(effects.contains(.open(h.id("C"), composer: nil, at: nil)))
        XCTAssertTrue(effects.contains(.markReadAfter(h.id("C"), delay: 0.4)))
        XCTAssertEqual(h.row("C")?.isUnread, true, "not yet")
        let after = h.send(.readDelayElapsed(h.id("C")))
        XCTAssertEqual(h.row("C")?.isUnread, false)
        XCTAssertTrue(after.contains { if case .perform(let r) = $0 { return r.change == .read(true) } else { return false } })
    }

    func testT10_beingMarkedReadByOpeningIsNotAnUndoStep() {
        let h = TriageHarness()
        h.send(.open(nil))
        h.send(.readDelayElapsed(h.id("A")))
        XCTAssertEqual(h.performed.last?.isUndoable, false)
        XCTAssertTrue(h.stack.isEmpty)
        XCTAssertTrue(h.toasts.isEmpty)
    }

    func testT10_aConversationPassedThroughSoonerIsNotMarkedRead() {
        let h = TriageHarness()
        h.send(.open(nil))
        h.send(.step(.older))                      // B
        h.send(.step(.older))                      // C
        h.send(.readDelayElapsed(h.id("A")))
        h.send(.readDelayElapsed(h.id("B")))
        XCTAssertEqual(h.row("A")?.isUnread, true)
        XCTAssertEqual(h.row("B")?.isUnread, true)
        XCTAssertTrue(h.performed.isEmpty)
    }

    func testT10_aClickOnARowOpensItAndPutsTheCursorThere() {
        let h = TriageHarness()
        h.send(.open(h.id("E")))
        XCTAssertEqual(h.cursor, "E")
        XCTAssertEqual(h.openLetter, "E")
    }

    func testT11_closeLeavesTheCursorOnThatConversationIfItIsStillInTheList() {
        let h = TriageHarness()
        h.send(.open(h.id("D")))
        let effects = h.send(.close)
        XCTAssertEqual(effects.first, .close)
        XCTAssertNil(h.openLetter)
        XCTAssertEqual(h.cursor, "D")
    }

    func testT11_otherwiseOnItsSuccessor() {
        let h = TriageHarness()
        h.send(.open(h.id("D")))
        h.outsideDone("D")                         // at rest while covered: applied at once
        XCTAssertEqual(h.shown, "ABCEFGHIJ")
        h.send(.close)
        XCTAssertEqual(h.cursor, "E")
    }

    func testT12_jAndKOpenTheNextOlderAndNewerConversationInItsPlace() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let older = h.send(.step(.older))
        XCTAssertTrue(older.contains(.open(h.id("D"), composer: nil, at: nil)))
        XCTAssertEqual(h.openLetter, "D")
        XCTAssertEqual(h.model.direction, .older)
        h.send(.step(.newer))
        h.send(.step(.newer))
        XCTAssertEqual(h.openLetter, "B")
        XCTAssertEqual(h.model.direction, .newer)
    }

    func testT12_atTheEndOfTheListNothingHappensAndTheButtonIsDisabled() {
        let h = TriageHarness()
        h.send(.open(h.id("J")))
        XCTAssertFalse(h.model.canStep(.older))
        XCTAssertTrue(h.model.canStep(.newer))
        XCTAssertEqual(h.send(.step(.older)), [])
        XCTAssertEqual(h.openLetter, "J")
        h.send(.open(h.id("A")))
        XCTAssertFalse(h.model.canStep(.newer))
    }

    func testT13_anOutsideChangeThatRemovesTheOpenConversationLeavesItOpen() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.outsideDone("C")
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
        XCTAssertEqual(h.openLetter, "C")
        XCTAssertNil(h.cursor, "on no row: the open conversation has left the list")
    }

    func testT13_theNextJKOrCloseIsWorkedOutAgainstTheListAsItThenIs() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.outsideDone("C")
        h.send(.step(.older))
        XCTAssertEqual(h.openLetter, "D")

        let g = TriageHarness()
        g.send(.open(g.id("C")))
        g.outsideDone("C")
        g.send(.step(.newer))
        XCTAssertEqual(g.openLetter, "B")
    }

    func testT13_aNewMessageInTheOpenConversationMovesNothingInTheList() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.send(.reader(MailReaderFacts(topMessage: nil, offset: 40, newestSeen: nil, hasUnseen: true)))
        XCTAssertEqual(h.model.open?.facts.hasUnseen, true)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.cursor, "C")
    }

    // MARK: T14: the table of actions

    func testT14_theTableIsTheDocumentsTable() {
        let kinds = Dictionary(uniqueKeysWithValues: MailActions.table.map { ($0.name, $0.kind) })
        for name in ["Done", "Trash", "Spam", "Move", "Remove this label", "Send and Done",
                     "Back to the inbox", "Not spam", "Restore", "Snooze", "Mute", "Add to plan",
                     "Unsubscribe"] {
            XCTAssertEqual(kinds[name], .disposing, name)
        }
        for name in ["Read or unread", "Star", "Label", "Not done"] {
            XCTAssertEqual(kinds[name], .marking, name)
        }
        XCTAssertEqual(kinds["Answer an invitation"], .anotherFeatures)
        XCTAssertEqual(MailActions.table.count, 18)
    }

    func testT14_theKeysAre4_2_4s() {
        let keys = Dictionary(uniqueKeysWithValues: MailActions.table.map { ($0.name, $0.key) })
        XCTAssertEqual(keys["Done"], "E")
        XCTAssertEqual(keys["Trash"], "#")
        XCTAssertEqual(keys["Spam"], "!")
        XCTAssertEqual(keys["Move"], "V")
        XCTAssertEqual(keys["Remove this label"], "Y")
        XCTAssertEqual(keys["Snooze"], "H")
        XCTAssertEqual(keys["Mute"], "⇧M")
        XCTAssertEqual(keys["Unsubscribe"], "⌘U")
        XCTAssertEqual(keys["Read or unread"], "U")
        XCTAssertEqual(keys["Star"], "S")
        XCTAssertEqual(keys["Label"], "L")
        XCTAssertEqual(keys["Not done"], "⇧E")
    }

    func testT14_shiftEIsNamedForWhereItIsPressedAndIsDisposingOnlyInDoneSpamAndTrash() {
        XCTAssertEqual(MailAction.notDone(in: .mailbox(.done)), .backToInbox)
        XCTAssertEqual(MailAction.notDone(in: .mailbox(.spam)), .notSpam)
        XCTAssertEqual(MailAction.notDone(in: .mailbox(.trash)), .restore)
        XCTAssertEqual(MailAction.notDone(in: .mailbox(.all)), .notDone)
        XCTAssertEqual(MailAction.notDone(in: .search("q3")), .notDone)
        XCTAssertEqual(MailAction.backToInbox.kind, .disposing)
        XCTAssertEqual(MailAction.notDone.kind, .marking)
    }

    func testT14_anotherFeaturesActionMovesNothingAndPutsNothingOnTheStack() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        let effects = h.press(.answerInvitation)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.cursor, "C")
        XCTAssertTrue(h.stack.isEmpty)
        XCTAssertTrue(h.performed.isEmpty)
    }

    func testT14_aMoveLeavesTheLabelBeingViewedAndAUnsubscribeCannotBeUndone() {
        let invoices = MailLabelRef(id: "L1", name: "Invoices", colorHex: nil)
        let viewing = MailScope(place: .label(account: TriageHarness.account, id: "L7"))
        XCTAssertEqual(MailAction.move(account: TriageHarness.account, to: invoices)
            .change(for: [], in: viewing),
                       .move(account: TriageHarness.account, to: "L1", from: "L7"))
        XCTAssertEqual(MailAction.move(account: TriageHarness.account, to: invoices)
            .change(for: [], in: MailScope(place: .mailbox(.inbox))),
                       .move(account: TriageHarness.account, to: "L1", from: nil))
        XCTAssertFalse(MailAction.unsubscribe.isUndoable)
        XCTAssertTrue(MailAction.done.isUndoable)
    }

    // MARK: T15: the target

    func testT15_theTargetIsTheOpenConversationOtherwiseTheSelectionOtherwiseTheCursor() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.press(.toggleStar)
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("C")]), "the cursor")

        h.send(.toggleSelected(h.id("E")))
        h.send(.toggleSelected(h.id("F")))
        h.press(.toggleStar)
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("E"), h.id("F")]), "the selection")

        h.send(.open(h.id("H")))
        h.press(.toggleStar)
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("H")]), "the open conversation")
    }

    func testT15_rAndFWithASelectionDoNothing() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("C")))
        XCTAssertEqual(h.send(.openAndReply(.reply)), [])
        XCTAssertEqual(h.send(.openAndReply(.forward)), [])
        XCTAssertNil(h.openLetter)
    }

    // MARK: T16: a disposing action

    func testT16_aTargetThePlaceNoLongerHoldsLeavesTheList() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.done()
        XCTAssertNil(h.row("C"))
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
    }

    func testT16_aTargetThatStaysShowsWhatChanged() {
        let h = TriageHarness(scope: MailScope(place: .mailbox(.all)))
        h.send(.place(h.id("C")))
        h.done()
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.row("C")?.inInbox, false)
        XCTAssertEqual(h.row("C")?.isUnread, false, "Done also marks it read")
    }

    func testT16_whereTheRuleCannotSayTheRowIsDrawnAsChangedWhereItIsAndTheNextReadingDecides() {
        let h = TriageHarness(scope: MailScope(place: .search("q3")))
        h.send(.place(h.id("C")))
        // The rule says unknown for Done in a search: the row is shown as changed, not removed.
        let effects = h.model.handle(.act(.done, on: nil))
        XCTAssertEqual(h.model.rows.map(\.id.thread).joined(), "ABCDEFGHIJ")
        XCTAssertEqual(h.model.rows[2].inInbox, false)
        XCTAssertEqual(h.model.cursor?.thread, "D", "it advances even though its row stays")
        // Then the reading says it no longer matches: it goes.
        h.searchMatches = { $0.inInbox || $0.id.thread != "C" }
        guard case .perform(let request)? = effects.first else { return XCTFail() }
        let receipt = h.apply(request.change, to: request.target)
        _ = h.model.handle(.performed(token: request.token, receipt))
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
    }

    func testT16_theSelectionIsClearedWhenItWasTheTarget() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("C")))
        h.send(.toggleSelected(h.id("D")))
        h.done()
        XCTAssertEqual(h.model.selection, .none)
    }

    func testT16_theCursorAdvancesEvenWhenItsRowStays() {
        let h = TriageHarness(scope: MailScope(place: .mailbox(.all)))
        h.send(.place(h.id("C")))
        h.done()
        XCTAssertEqual(h.cursor, "D")
    }

    func testT16_aConversationThatWasOpenFollowsTheCursorInTheDirectionOfTravelOtherwiseTheViewReturnsToTheList() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let effects = h.press(.done)
        XCTAssertTrue(effects.contains(.open(h.id("D"), composer: nil, at: nil)))
        XCTAssertEqual(h.openLetter, "D")

        let g = TriageHarness()
        g.send(.open(g.id("J")))
        let back = g.press(.done)
        XCTAssertTrue(back.contains(.close))
        XCTAssertNil(g.openLetter)
        XCTAssertEqual(g.cursor, "I")
    }

    func testT16_anUndoEntryIsPushedAndTheToastShows() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.done()
        XCTAssertEqual(h.stack.count, 1)
        XCTAssertEqual(h.toasts, [MailToast(text: "Marked \u{201C}Subject C\u{201D} Done", action: .undo)])
    }

    func testT16_anActionThatWouldChangeNothingSendsNothingShowsNothingAndStillAdvancesTheCursor() {
        let h = TriageHarness(scope: MailScope(place: .search("q3")))
        h.mailbox[2].inInbox = false
        h.mailbox[2].isUnread = false              // Done also marks read: this row has nothing left to change
        h.deliver()
        h.send(.place(h.id("C")))
        let effects = h.press(.done)
        XCTAssertFalse(effects.contains { if case .perform = $0 { return true } else { return false } })
        XCTAssertTrue(h.toasts.isEmpty)
        XCTAssertTrue(h.stack.isEmpty)
        XCTAssertEqual(h.cursor, "D")
    }

    func testT16_aReceiptThatSaysNothingChangedShowsNothingAndOffersNoUndo() {
        let h = TriageHarness()
        let effects = h.model.handle(.act(.done, on: nil))
        guard case .perform(let request)? = effects.first else { return XCTFail() }
        XCTAssertEqual(h.model.handle(.performed(token: request.token, MailReceipt(sequence: 1, count: 0))), [])
        XCTAssertEqual(h.model.handle(.performed(token: 99, MailReceipt(sequence: 0, count: 0))), [])
    }

    // MARK: T17: a marking action

    func testT17_theTargetsUpdateWhereTheyAreAndNothingElseChanges() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.send(.toggleSelected(h.id("E")))
        h.press(.toggleStar)
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.selected, "E", "the selection is not cleared")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.row("E")?.isStarred, true)
    }

    func testT17_aRowThatNoLongerMatchesTheFilterIsKeptDimmedUntilTheScopeChanges() {
        let h = TriageHarness(scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        h.send(.place(h.id("C")))
        h.press(.toggleRead)
        XCTAssertNotNil(h.row("C"))
        XCTAssertTrue(h.model.isDimmed(h.id("C")))
        XCTAssertTrue(h.model.list.shown.dimmed.contains(h.id("C")))
        // Whatever the next reading says, and after the background.
        h.model.handle(.snapshot(h.snapshot(for: h.model.scope)))
        h.send(.idle)
        XCTAssertNotNil(h.row("C"))
    }

    func testT17_aMarkedRowIsKeptWhateverTheNextReadingSaysEvenWhenTheRuleAnsweredStays() {
        // A custom split claims the row the rule said stays: the reading omits it.
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.model.handle(.act(.toggleStar, on: nil))
        h.mailbox.removeAll { $0.id.thread == "C" }     // the very next reading omits it
        h.deliver()
        h.send(.idle)
        XCTAssertNotNil(h.row("C"), "kept by the action")
        XCTAssertTrue(h.model.isDimmed(h.id("C")), "and dimmed, from the reading that omitted it")
    }

    func testT17_aRefreshDropsKeptRowsAndAsksToCheckForMail() {
        let h = TriageHarness(scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        h.send(.place(h.id("C")))
        h.press(.toggleRead)
        let effects = h.send(.refresh)
        XCTAssertNil(h.row("C"))
        XCTAssertTrue(effects.contains(.checkNow))
    }

    func testT17_uMakesAllUnreadIfAllAreReadOtherwiseAllRead() {
        let read = [TriageHarness.row("A", rank: 0, unread: false), TriageHarness.row("B", rank: 1, unread: false)]
        let mixed = [TriageHarness.row("A", rank: 0, unread: false), TriageHarness.row("B", rank: 1, unread: true)]
        let scope = MailScope(place: .mailbox(.inbox))
        XCTAssertEqual(MailAction.toggleRead.change(for: read, in: scope), .read(false))
        XCTAssertEqual(MailAction.toggleRead.change(for: mixed, in: scope), .read(true))
    }

    func testT17_sStarsAllIfAnyIsUnstarredOtherwiseUnstarsAll() {
        let scope = MailScope(place: .mailbox(.inbox))
        let some = [TriageHarness.row("A", rank: 0, starred: true), TriageHarness.row("B", rank: 1)]
        let all = [TriageHarness.row("A", rank: 0, starred: true), TriageHarness.row("B", rank: 1, starred: true)]
        XCTAssertEqual(MailAction.toggleStar.change(for: some, in: scope), .star(true))
        XCTAssertEqual(MailAction.toggleStar.change(for: all, in: scope), .star(false))
    }

    func testT17_uOnAnOpenConversationThatMakesItUnreadReturnsToTheList() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.send(.readDelayElapsed(h.id("C")))       // now read
        let effects = h.press(.toggleRead)         // makes it unread
        XCTAssertTrue(effects.contains(.close))
        XCTAssertNil(h.openLetter)
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.row("C")?.isUnread, true)
    }

    func testT17_uOnAnOpenConversationStillUnreadSendsNothingAndGoesBack() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))                   // unread, and the 400 ms have not passed
        let effects = h.press(.toggleRead)
        XCTAssertTrue(effects.contains(.close))
        XCTAssertNil(h.openLetter)
        XCTAssertTrue(h.performed.isEmpty)
        XCTAssertEqual(h.row("C")?.isUnread, true)
        XCTAssertTrue(h.stack.isEmpty)
        // The pending read is dropped: when its timer runs out nothing is open to be read.
        XCTAssertEqual(h.send(.readDelayElapsed(h.id("C"))), [])
        XCTAssertEqual(h.row("C")?.isUnread, true)
    }

    // MARK: T18: keys are never dropped

    func testT18_tenPressesOfEMarkTenConversationsDoneInOrderEachActingOnTheCursorTheLastLeft() {
        let h = TriageHarness(rows: 12)
        for _ in 0..<10 { h.done() }
        XCTAssertEqual(h.performed.count, 10)
        XCTAssertEqual(h.performed.map(\.target),
                       "ABCDEFGHIJ".map { MailTarget.conversations([h.id(String($0))]) })
        XCTAssertEqual(h.shown, "KL")
        XCTAssertEqual(h.cursor, "K")
        XCTAssertEqual(h.stack.count, 10)
    }

    // MARK: T19: emptying a list

    func testT19_anActionThatRemovesTheLastConversationLeavesAnEmptyListAndThePlaceInFront() {
        let h = TriageHarness(rows: 1)
        let effects = h.press(.done)
        XCTAssertEqual(h.shown, "")
        XCTAssertNil(h.cursor)
        XCTAssertTrue(h.model.list.shown.hasDelivered)
        XCTAssertEqual(h.model.list.shown.stillLoading, 0)
        XCTAssertFalse(effects.contains { if case .leaveSearch = $0 { return true } else { return false } })
        XCTAssertEqual(h.showing, h.important)
    }

    // MARK: T20 to T24: selection

    func testT20_xAddsTheCursorConversationOrTakesItOffAndTheCursorDoesNotMove() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.send(.toggleSelected(nil))
        XCTAssertEqual(h.selected, "C")
        XCTAssertEqual(h.cursor, "C")
        h.send(.toggleSelected(nil))
        XCTAssertEqual(h.selected, "")
    }

    func testT20_aTapWhileSelectingTogglesThatRowWithoutMovingTheCursor() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("F")))
        XCTAssertEqual(h.selected, "F")
        XCTAssertEqual(h.cursor, "A")
    }

    func testT21_aRunIsEveryConversationFromTheAnchorToTheCursorAndReversingShrinksIt() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.send(.extendSelection(.older))         // sets the anchor at C and moves to D
        XCTAssertEqual(h.selected, "CD")
        XCTAssertEqual(h.cursor, "D")
        h.send(.extendSelection(.older))
        h.send(.extendSelection(.older))
        XCTAssertEqual(h.selected, "CDEF")
        XCTAssertEqual(h.cursor, "F")
        h.send(.extendSelection(.newer))
        XCTAssertEqual(h.selected, "CDE")
        h.send(.extendSelection(.newer))
        h.send(.extendSelection(.newer))
        XCTAssertEqual(h.selected, "C", "reversing shrinks it to the anchor alone")
        h.send(.extendSelection(.newer))
        XCTAssertEqual(h.selected, "BC", "and then grows it the other way")
    }

    func testT21_anyOtherKeyEndsTheRunAndItsRowsStaySelectedAndTheNextRunStartsFromWhereTheCursorThenIs() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.send(.extendSelection(.older))
        h.send(.extendSelection(.older))
        XCTAssertEqual(h.selected, "BCD")
        h.send(.move(.older))                    // another key: E
        XCTAssertEqual(h.selected, "BCD")
        h.send(.move(.older))                    // F
        h.send(.extendSelection(.older))         // a new run, anchored at F: F and G
        XCTAssertEqual(h.selected, "BCDFG")
    }

    func testT21_conversationsSelectedWithXOutsideTheRunStaySelected() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("I")))
        h.send(.place(h.id("B")))
        h.send(.extendSelection(.older))
        h.send(.extendSelection(.older))
        h.send(.extendSelection(.older))
        XCTAssertEqual(h.selected, "BCDEI")
        h.send(.extendSelection(.newer))
        XCTAssertEqual(h.selected, "BCDI")
    }

    func testT22_commandASelectsFromTheCursorDownAndCommandShiftAWholeListBothByTheKeyAtThatMoment() {
        let h = TriageHarness()
        h.send(.place(h.id("D")))
        h.send(.selectFromHere)
        XCTAssertEqual(h.selected, "DEFGHIJ")
        guard case .scope(_, let from, let count) = h.model.selection else { return XCTFail() }
        XCTAssertEqual(from, h.row("D")?.key)
        XCTAssertEqual(count, MailCount(value: 7, isAtLeast: false))

        h.send(.selectAll)
        XCTAssertEqual(h.selected, "ABCDEFGHIJ")
    }

    func testT22_itIncludesRowsNotLoadedAndExcludesWhatArrivesAfterwards() {
        let h = TriageHarness()
        // The list says there are 1,204 of them; ten are loaded.
        var snapshot = h.snapshot(for: h.important)
        snapshot.total = MailCount(value: 1_204, isAtLeast: false)
        snapshot.hasMore = true
        h.model.handle(.snapshot(snapshot))
        h.send(.selectAll)
        guard case .scope(_, _, let count) = h.model.selection else { return XCTFail() }
        XCTAssertEqual(count, MailCount(value: 1_204, isAtLeast: false))
        h.arrive("N")
        let firstKey = h.row("A")?.key
        h.done()
        XCTAssertEqual(h.performed.last?.target, .scope(h.important, from: firstKey))
        XCTAssertEqual(h.members(of: h.important).map(\.id.thread), ["N"], "the arrival is not swept up")
    }

    func testT22_aSelectionByScopeIsAllOrNothingSoXInsideItDoesNothing() {
        let h = TriageHarness()
        h.send(.selectAll)
        h.send(.toggleSelected(h.id("C")))
        h.send(.extendSelection(.older))
        XCTAssertEqual(h.selected, "ABCDEFGHIJ")
        h.send(.clearSelection)
        XCTAssertEqual(h.selected, "")
    }

    func testT23_leavingThePlaceClearsASelectionAndOpeningAConversationKeepsIt() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("C")))
        h.send(.open(h.id("D")))
        XCTAssertEqual(h.selected, "C")
        h.send(.close)
        h.show(h.other)
        XCTAssertEqual(h.models[h.important]?.selection, MailSelection.none)
    }

    func testT23_actionsInsideTheOpenConversationActOnThatConversationOnlyAndLeaveTheSelection() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("C")))
        h.send(.toggleSelected(h.id("E")))
        h.send(.open(h.id("D")))
        h.done()
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("D")]))
        XCTAssertEqual(h.selected, "CE")
    }

    func testT24_anOutsideChangeNeverAltersARowByRowSelectionExceptToDropWhatLeft() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("C")))
        h.send(.toggleSelected(h.id("E")))
        h.newMail(in: "C")
        h.arrive("N")
        h.outsideDone("E")
        h.send(.idle)
        XCTAssertEqual(h.selected, "C")
    }

    // MARK: T31 to T34: places, filters, search

    func testT31_tabShowsTheNextSplitAndShiftTabThePreviousWrappingWithoutSkippingAnEmptyOne() {
        let splits = [MailSplit(id: MailSplit.importantID, name: "Important", query: nil),
                      MailSplit(id: MailSplit.calendarID, name: "Calendar", query: nil),
                      MailSplit(id: "vip", name: "VIP", query: "from:vip"),
                      MailSplit(id: MailSplit.otherID, name: "Other", query: nil)]
        func next(_ id: String, back: Bool = false) -> MailPlace? {
            MailListModel.splitAfter(.split(id), in: splits, backwards: back)
        }
        XCTAssertEqual(next("important"), .split("calendar"))
        XCTAssertEqual(next("vip"), .split("other"))
        XCTAssertEqual(next("other"), .split("important"), "wraps")
        XCTAssertEqual(next("important", back: true), .split("other"), "wraps")
        XCTAssertEqual(next("calendar", back: true), .split("important"))
    }

    func testT31_fromAPlaceThatIsNotASplitTabShowsTheFirstAndShiftTabTheLast() {
        let splits = [MailSplit(id: "important", name: "Important", query: nil),
                      MailSplit(id: "other", name: "Other", query: nil)]
        XCTAssertEqual(MailListModel.splitAfter(.mailbox(.starred), in: splits, backwards: false), .split("important"))
        XCTAssertEqual(MailListModel.splitAfter(.mailbox(.starred), in: splits, backwards: true), .split("other"))
        XCTAssertNil(MailListModel.splitAfter(.mailbox(.starred), in: [], backwards: false))
    }

    func testT31_eachPlaceKeepsItsOwnCursorAndPosition() {
        let h = TriageHarness()
        h.mailbox[7].isImportant = false
        h.mailbox[8].isImportant = false
        h.deliver()
        h.send(.place(h.id("F")))
        h.show(h.other)
        h.send(.move(.older))
        XCTAssertEqual(h.cursor, "I")
        h.show(h.important)
        XCTAssertEqual(h.cursor, "F")
    }

    func testT32_aFilterIsAScopeWithTheFilterToggledAndTheCursorStaysOnItsConversationIfItIsInIt() {
        let h = TriageHarness()
        h.mailbox[2].isUnread = false
        h.mailbox[4].isUnread = false
        h.deliver()
        h.send(.place(h.id("D")))
        let hint = h.model.cursorHint
        let filtered = MailListModel.scope(toggling: .unread, in: h.important)
        XCTAssertEqual(filtered.filters, [.unread])
        XCTAssertEqual(MailListModel.scope(toggling: .unread, in: filtered), h.important)
        h.show(filtered, carrying: hint)
        XCTAssertEqual(h.cursor, "D")
    }

    func testT32_otherwiseOnItsSuccessorByKey() {
        let h = TriageHarness()
        h.mailbox[2].isUnread = false           // C is read
        h.mailbox[3].isUnread = false           // D is read
        h.deliver()
        h.send(.place(h.id("C")))
        let hint = h.model.cursorHint
        h.show(MailListModel.scope(toggling: .unread, in: h.important), carrying: hint)
        XCTAssertEqual(h.cursor, "E", "older than C, and unread")
        XCTAssertEqual(h.shown, "ABEFGHIJ")
    }

    func testT32_theSuccessorByKeyFollowsTheDirectionTravelled() {
        let h = TriageHarness()
        h.mailbox[2].isUnread = false
        h.mailbox[3].isUnread = false
        h.deliver()
        h.send(.place(h.id("D")))
        h.send(.move(.newer))                    // C, travelling newer
        let hint = h.model.cursorHint
        h.show(MailListModel.scope(toggling: .unread, in: h.important), carrying: hint)
        XCTAssertEqual(h.cursor, "B")
    }

    func testT33_searchResultsAreAListWithTheSameKeysActionsAndRules() {
        let h = TriageHarness(scope: MailScope(place: .search("subject")))
        h.send(.move(.older))
        h.send(.move(.older))
        XCTAssertEqual(h.cursor, "C")
        h.press(.toggleStar)
        XCTAssertEqual(h.row("C")?.isStarred, true)
        h.send(.open(nil))
        XCTAssertEqual(h.openLetter, "C")
        h.send(.close)
        XCTAssertEqual(h.cursor, "C")
    }

    func testT34_narrowingToAnAccountIsAFilterAndCarriesTheCursorTheSameWay() {
        let h = TriageHarness()
        h.mailbox[3].isImportant = true
        h.send(.place(h.id("E")))
        let hint = h.model.cursorHint
        var narrowed = h.important
        narrowed.account = TriageHarness.account
        h.show(narrowed, carrying: hint)
        XCTAssertEqual(h.cursor, "E")
    }

    // MARK: T37, T38: reading back, replying from the list

    func testT37_aReadingThatCarriesAChangeThisDeviceMadeChangesNothingOnScreenAndRaisesNoChip() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.done()
        let published = h.model.list.shown.generation
        h.send(.idle)
        h.send(.firstRowOnScreen(true))
        h.deliver()
        XCTAssertEqual(h.model.list.shown.generation, published)
        XCTAssertEqual(h.model.arrivals, 0)
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
    }

    func testT37_aSecondActionAfterTheFirstsReadingFindsNothingToAddEither() {
        let h = TriageHarness()
        h.done()
        h.done()
        h.deliver()
        XCTAssertEqual(h.model.arrivals, 0)
        XCTAssertEqual(h.shown, "CDEFGHIJ")
    }

    func testT38_rAndFOpenTheConversationWithTheComposerOpenInOneStep() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        let reply = h.send(.openAndReply(.reply))
        XCTAssertTrue(reply.contains(.open(h.id("C"), composer: .reply, at: nil)))
        XCTAssertEqual(h.openLetter, "C")
        h.send(.close)
        let forward = h.send(.openAndReply(.forward))
        XCTAssertTrue(forward.contains(.open(h.id("C"), composer: .forward, at: nil)))
    }

    func testT38_sendAndDoneMovesTheScreenLikeDoneAndAsksTheSourceForNothingBecauseTheSendCarriesIt() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let effects = h.press(.sendAndDone)
        XCTAssertFalse(effects.contains { if case .perform = $0 { return true } else { return false } })
        XCTAssertEqual(h.openLetter, "D")
        XCTAssertEqual(h.shown, "ABDEFGHIJ")
        XCTAssertTrue(h.stack.isEmpty, "the composer pushes the one entry")
        // It is handed what was showing, without a receipt (P-4).
        guard let entry = h.settled.first else { return XCTFail("no screen half") }
        XCTAssertEqual(entry.receipt.sequence, 0)
        XCTAssertEqual(entry.cursor, h.id("C"))
        XCTAssertEqual(entry.open?.id, h.id("C"))
        XCTAssertEqual(entry.scope, h.important)
        XCTAssertEqual(entry.rowsBefore.map(\.id), [h.id("C")])
        XCTAssertEqual(entry.subjects, ["Subject C"])
    }

    // MARK: T39, T40, T42, T43: touch

    func testT39_aLongPressSelectsThatRowAndTapsThenToggleRowsWithoutOpeningAnything() {
        // The gesture, the check circles and the bottom slot are the screen's; what the model
        // holds is that the pressed row is selected, the cursor stays, and a tap after it
        // toggles another row rather than opening it.
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.send(.toggleSelected(h.id("F")))
        XCTAssertEqual(h.selected, "F")
        XCTAssertEqual(h.cursor, "B")
        h.send(.toggleSelected(h.id("H")))
        h.send(.toggleSelected(h.id("F")))
        XCTAssertEqual(h.selected, "H")
        XCTAssertNil(h.openLetter)
        // Acting ends it, as T16 says: the selection was the target.
        h.press(.toggleStar)
        XCTAssertEqual(h.selected, "H", "a marking action leaves the selection (T17)")
        h.press(.done)
        XCTAssertEqual(h.selected, "")
    }

    func testT40_aSwipeIsADisposingActionOnThatRowAndTheCursorStaysWhereItIs() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.press(.done, on: "F")
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("F")]))
        XCTAssertEqual(h.shown, "ABCDEGHIJ")
        XCTAssertEqual(h.cursor, "B", "a cursor that was not a target is its own successor")
    }

    func testT40_aSwipeOnTheCursorRowAdvancesIt() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.press(.done, on: "B")
        XCTAssertEqual(h.cursor, "C")
    }

    func testT42_theOlderAndNewerButtonsAreDisabledAtTheEndsOfTheListAndActOnNothing() {
        let h = TriageHarness()
        h.send(.open(h.id("A")))
        XCTAssertFalse(h.model.canStep(.newer))
        XCTAssertTrue(h.model.canStep(.older))
        h.send(.step(.older))
        XCTAssertTrue(h.performed.isEmpty)
        XCTAssertTrue(h.stack.isEmpty)
    }

    func testT43_pullingTheListDownChecksForMail() {
        let h = TriageHarness()
        XCTAssertTrue(h.send(.refresh).contains(.checkNow))
    }

    // MARK: T45: an action acts on what was shown

    func testT45_anActionOnAnOpenConversationWithAMessageNotYetOnScreenActsOnTheMessagesThatWere() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let seen = MailMessageID(account: TriageHarness.account, message: "C-m3")
        h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0, newestSeen: seen, hasUnseen: true)))
        h.unseenReply = ["C"]
        h.done()
        XCTAssertEqual(h.performed.last?.target, .message(seen))
        XCTAssertEqual(h.row("C")?.inInbox, true, "it stays in the inbox, unread, with the new message")
        XCTAssertEqual(h.row("C")?.isUnread, true)
    }

    func testT45_readIsHeldToTheSameRule() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let seen = MailMessageID(account: TriageHarness.account, message: "C-m2")
        h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0, newestSeen: seen, hasUnseen: true)))
        h.press(.toggleRead)
        XCTAssertEqual(h.performed.last?.target, .message(seen))
        // A star is a property of the conversation, so it is not.
        h.press(.toggleStar)
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("C")]))
    }

    func testT45_withNothingUnseenItActsOnTheConversation() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0,
                                       newestSeen: MailMessageID(account: TriageHarness.account, message: "C-m3"),
                                       hasUnseen: false)))
        h.done()
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("C")]))
    }

    // MARK: T36: a change that cannot stand

    func testT36_aRefusedChangeComesBackAtOnceWhereTheOrderPutsItWithTheReasonOnItsRow() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.done()
        let receipt = h.stack.top!.receipt
        h.refuse(receipt, .labelMissing)
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.row("C")?.reason, .changeRefused(.labelMissing))
        XCTAssertEqual(h.cursor, "D", "the cursor stays where it went")
        XCTAssertTrue(h.stack.isEmpty, "its undo entry is removed")
    }

    func testT36_theToastSaysWhatAndWhyWithRetry() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.done()
        h.refuse(h.stack.top!.receipt, .labelMissing)
        XCTAssertEqual(h.toasts.last, MailToast(
            text: "Couldn't mark \u{201C}Subject C\u{201D} Done: that label no longer exists.",
            action: .retry))
    }

    func testT36_itDoesNotMatterWhichOfTheEventAndTheReadingTheScreenHearsFirst() {
        for eventFirst in [false, true] {
            let h = TriageHarness()
            h.send(.place(h.id("C")))
            h.done()
            h.refuse(h.stack.top!.receipt, .labelMissing, eventFirst: eventFirst)
            XCTAssertEqual(h.shown, "ABCDEFGHIJ", "eventFirst \(eventFirst)")
            XCTAssertEqual(h.row("C")?.reason, .changeRefused(.labelMissing), "eventFirst \(eventFirst)")
        }
    }

    func testT36_aChangeTheDeviceCouldNotSaveIsPutBackAndSaysSo() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.done()
        let entry = h.stack.remove(receipt: h.stack.top!.receipt)!
        h.mailbox[2].inInbox = true
        let effects = h.model.handle(.reverted(entry, .notSaved(.diskFull)))
        XCTAssertEqual(effects, [.toast(MailToast(text: "Couldn't save that: this iPhone is full.", action: nil))])
        XCTAssertNotNil(h.row("C"))
    }
}


// MARK: - A seeded run, and the performance line

/// A generator that gives the same numbers for the same seed, so that a failure is a seed and a
/// step number and can be run again.
struct MailSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension MailListModelTests {

    /// What must be true after every input, whatever the input was.
    private func invariantsHold(_ h: TriageHarness) -> String? {
        let model = h.model
        let rows = model.rows
        let ids = rows.map(\.id)
        if Set(ids).count != ids.count { return "a conversation is on two rows" }
        for (newer, older) in zip(rows, rows.dropFirst()) where !(newer.key > older.key) {
            return "rows are not in descending key order at \(newer.id.thread), \(older.id.thread)"
        }
        if let cursor = model.cursor, !ids.contains(cursor) {
            return "the cursor is on \(cursor.thread), which is not shown"
        }
        if let open = model.open {
            if model.cursor == nil, ids.contains(open.id) {
                return "the open conversation is shown but has no cursor"
            }
        } else if rows.isEmpty != (model.cursor == nil) {
            return rows.isEmpty ? "an empty list has a cursor" : "a list with rows has no cursor"
        }
        let shown = Set(ids)
        if !model.selectedIDs.isSubset(of: shown) {
            return "the selection holds a row that is not in the list"
        }
        if case .rows(let selected) = model.selection, !selected.isSubset(of: shown) {
            return "the row selection holds a row outside the list: \(selected.subtracting(shown))"
        }
        if model.list.shown.rows != rows { return "what the list shows is not what the model holds" }
        if model.arrivals < 0 { return "a negative chip" }
        // An open conversation is always the cursor (section 0).
        if let open = model.open, model.cursorID != open.id {
            return "the open conversation \(open.id.thread) is not the cursor (\(model.cursorID?.thread ?? "none"))"
        }
        // A kept row is a row.
        if !model.keptIDs.isSubset(of: shown) { return "a kept row is not in the list: \(model.keptIDs.subtracting(shown))" }
        // The chip counts what is waiting, and only what is waiting.
        if model.arrivals > 0, !model.hasWaitingReading { return "the chip counts \(model.arrivals) but nothing is waiting" }
        // Growth is bounded, and a window never holds more than it asked for plus what is kept.
        if model.limit > MailTuning.listCap { return "asked for more than the cap" }
        // Growth is never stuck: with more to load, the reading for the limit asked for here, and
        // the cursor near the last row, the next step has been asked for — whatever is in the chip
        // (MAIL-UX 6.1.7).
        if model.list.shown.hasMore, model.rowsInNewestReading >= model.limit,
           model.limit < MailTuning.listCap, let at = rows.firstIndex(where: { $0.id == model.cursor }),
           rows.count - at <= MailListModel.growMargin {
            return "the cursor is at row \(at) of \(rows.count), the reading holds \(model.rowsInNewestReading) "
                + "and the limit is \(model.limit), but the next step was not asked for"
        }
        return nil
    }

    /// One random input, through the loop. Returns its name, for the failure message.
    private func randomInput(_ h: TriageHarness, _ rng: inout MailSeededGenerator, step: Int) -> String {
        let rows = h.model.rows
        func anyRow() -> MailConversationID? { rows.randomElement(using: &rng)?.id }
        func older() -> MailDirection { Bool.random(using: &rng) ? .older : .newer }
        let pick = Int.random(in: 0..<100, using: &rng)
        let invoices = MailLabelRef(id: "L1", name: "Invoices", colorHex: nil)
        switch pick {
        case 0..<20:
            let direction = older()
            h.send(.move(direction))
            return "move \(direction)"
        case 20..<34:
            let actions: [MailAction] = [.done, .done, .toggleStar, .toggleRead, .trash, .spam,
                                         .notDone, .move(account: TriageHarness.account, to: invoices),
                                         .snooze(until: h.now, ifNoReply: false), .sendAndDone]
            let action = actions.randomElement(using: &rng)!
            let row = Int.random(in: 0..<5, using: &rng) == 0 ? anyRow() : nil
            h.send(.act(action, on: row))
            return "act \(action) on \(row?.thread ?? "target")"
        case 34..<38:
            let row = anyRow()
            h.send(.open(Bool.random(using: &rng) ? nil : row))
            return "open \(row?.thread ?? "nil")"
        case 38..<42:
            h.send(.close)
            return "close"
        case 42..<46:
            let direction = older()
            h.send(.step(direction))
            return "step \(direction)"
        case 46..<54:
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: h.send(.toggleSelected(nil)); return "X"
            case 1: let d = older(); h.send(.extendSelection(d)); return "extend \(d)"
            case 2: h.send(.selectFromHere); return "selectFromHere"
            case 3: h.send(.selectAll); return "selectAll"
            default: h.send(.clearSelection); return "clearSelection"
            }
        case 54..<59:
            h.undoTop()
            return "undo"
        case 59..<71:
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: h.arrive("N\(step)", rank: -step - 1); return "arrive"
            case 1: let r = anyRow(); if let r { h.outsideDone(r.thread) }; return "outsideDone \(r?.thread ?? "-")"
            case 2: let r = anyRow(); if let r { h.newMail(in: r.thread) }; return "newMail \(r?.thread ?? "-")"
            case 3:
                let r = anyRow()
                if let r { h.outside { m in if let i = m.firstIndex(where: { $0.id == r }) { m[i].isStarred.toggle() } } }
                return "outsideStar \(r?.thread ?? "-")"
            default:
                let r = anyRow()
                if let r { h.outside { m in if let i = m.firstIndex(where: { $0.id == r }) { m[i].snippet = "s\(step)" } } }
                return "outsideSnippet \(r?.thread ?? "-")"
            }
        case 71..<77:
            h.send(.idle)
            return "idle"
        case 77..<80:
            let on = Bool.random(using: &rng)
            h.send(.firstRowOnScreen(on))
            return "firstRowOnScreen \(on)"
        case 80..<83:
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: h.send(.chipUsed); return "chipUsed"
            case 1: h.send(.jumpToNewest); return "jumpToNewest"
            case 2: h.send(.jumpToOldest); return "jumpToOldest"
            default:
                // Scrolled deep, near the last row loaded, with mail waiting: the chip shows, `J` is
                // held, and the list has to go on growing.
                h.send(.close)
                h.finishCheck()                          // no check is out: the chip can show
                h.restock()                              // and there is more to load than is loaded
                h.send(.firstRowOnScreen(false))
                if let deep = h.model.rows.suffix(35).randomElement(using: &rng) { h.send(.place(deep.id)) }
                // The newest mail there is, so that it belongs above the first row and the chip counts it.
                h.arrive("D\(step)", rank: -5_000 - step, important: h.showing == h.important)
                for _ in 0..<4 { h.send(.move(.older)) }
                return "scrolled deep with a chip"
            }
        case 83..<86:
            h.send(.back)
            return "back"
        case 86..<88:
            h.send(.refresh)
            return "refresh"
        case 88..<91:
            let row = anyRow()
            if let row { h.send(.place(row)) }
            return "place \(row?.thread ?? "-")"
        case 91..<93:
            if let open = h.model.open { h.send(.readDelayElapsed(open.id)) }
            return "readDelayElapsed"
        case 93..<95:
            let unseen = Bool.random(using: &rng)
            h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0, newestSeen: nil, hasUnseen: unseen)))
            return "reader unseen \(unseen)"
        case 95..<97:
            // Whether the places not in front are observed, and whether an undo reaches them, vary.
            h.observesWhileAway = Bool.random(using: &rng)
            h.deliversOnUndo = Bool.random(using: &rng)
            h.observesOnEntry = Bool.random(using: &rng)     // the session marks the answer, or not
            h.show(h.showing == h.important ? h.other : h.important)
            return "tab"
        case 97..<98:
            switch Int.random(in: 0..<5, using: &rng) {
            case 3:
                h.finishCheck()
                return "checkFinished"
            case 4:
                h.send(.refresh)
                return "refresh"
            case 0:
                if let receipt = h.stack.top?.receipt {
                    h.refuse(receipt, .labelMissing, eventFirst: Bool.random(using: &rng))
                }
                return "refuse"
            case 1:
                h.completePendingSend()
                return "completeSend"
            default:
                h.now = h.now.addingTimeInterval(Double.random(in: 0..<20, using: &rng))
                return "time passes"
            }
        default:
            if let first = rows.randomElement(using: &rng) {
                h.send(.scrolled(MailViewport(firstRow: first.id, key: first.key,
                                              offset: Int.random(in: 0..<40, using: &rng))))
            }
            return "scrolled"
        }
    }

    @discardableResult
    private func runSeeded(seed: UInt64, inputs: Int) -> TriageHarness? {
        var rng = MailSeededGenerator(seed: seed)
        // 240 conversations and an observation of 100: the window has to grow, and the places
        // are left and come back with readings that were and were not delivered meanwhile. Older
        // mail keeps arriving (`restock`), so there is always more to load for it to grow into.
        let h = TriageHarness(rows: 240, limit: 100)
        for index in stride(from: 4, to: 240, by: 5) { h.mailbox[index].isImportant = false }
        h.deliver()
        for step in 0..<inputs {
            // What stands under his hand before an input from elsewhere: it is not at rest, no
            // conversation covers the list, and no check is out.
            let firstBefore = h.model.rows.first?.id
            let idsBefore = Set(h.model.rows.map(\.id))
            let underHisHand = !h.model.isIdle && h.model.open == nil && !h.model.isAwaitingCheck
            let name = randomInput(h, &rng, step: step)
            if let broken = invariantsHold(h) {
                XCTFail("seed \(seed), input \(step) (\(name)): \(broken)")
                return nil
            }
            let fromElsewhere = name.hasPrefix("arrive") || name.hasPrefix("newMail")
            if fromElsewhere, underHisHand {
                // No row that was not there before is above the row that was first, whether or
                // not that row is still there.
                let shown = h.model.rows
                let aboveTheOldFirst: ArraySlice<MailRow>
                if let firstBefore, let at = shown.firstIndex(where: { $0.id == firstBefore }) {
                    aboveTheOldFirst = shown[..<at]
                } else {
                    aboveTheOldFirst = shown.prefix(0)
                }
                if let new = aboveTheOldFirst.first(where: { !idsBefore.contains($0.id) }) {
                    XCTFail("seed \(seed), input \(step) (\(name)): \(new.id.thread) went above the first under his hand")
                    return nil
                }
                if firstBefore == nil, !shown.isEmpty, !h.model.rows.allSatisfy({ idsBefore.contains($0.id) }) {
                    XCTFail("seed \(seed), input \(step) (\(name)): a row joined an empty list under his hand")
                    return nil
                }
            }
        }

        // Then let everything settle, and the list must be the source's list — as much of it as
        // has been asked for — but for the row the cursor is keeping still (T8b).
        h.observesWhileAway = true
        h.deliversOnUndo = true
        h.show(h.important)
        h.send(.close)
        h.send(.clearSelection)
        h.deliver()
        h.send(.refresh)
        h.send(.firstRowOnScreen(true))
        h.send(.idle)
        h.send(.chipUsed)
        h.deliver()
        let held = h.model.cursor
        let source = h.members(of: h.important).prefix(h.limit(for: h.important)).map(\.id).filter { $0 != held }
        let shown = h.model.rows.map(\.id).filter { $0 != held }
        XCTAssertEqual(shown, source, "seed \(seed): the list did not converge on the source's")
        XCTAssertEqual(h.model.arrivals, 0, "seed \(seed)")
        return h
    }

    /// 2,000 random inputs — keys, actions, selections, opening, undo, mail from elsewhere, idle,
    /// the refusal of a change — and after every one the cursor is on a row that is shown and
    /// the selection holds no row that is not in the list. The seed is in the message.
    func testASeededRunOf2000InputsNeverLeavesTheCursorOnARowThatIsNotShownNorTheSelectionOutsideTheScope() {
        guard let h = runSeeded(seed: 0x5EED_0FBA_2026_1006, inputs: 2_000) else { return }
        // The run reached what it is for: the window grew, undo was asked for in places that were
        // not in front, and a Send and Done was settled and finished.
        XCTAssertGreaterThan(h.growths.count, 0, "the window never grew")
        XCTAssertGreaterThan(h.undone, 0)
        XCTAssertGreaterThan(h.undoneAcrossPlaces, 0, "no undo across a place change")
        XCTAssertGreaterThan(h.completedSettled, 0, "no Send and Done was finished")
        XCTAssertGreaterThan(h.growthsWithAChip, 0, "the list never grew with a chip waiting")
        XCTAssertGreaterThan(h.checksFinished, 0, "no check finished")
        XCTAssertGreaterThan(h.entriesAnswered, 0, "no entry was answered")
    }

    func testTheSameRunFromMoreSeeds() {
        for seed in UInt64(1)...4 { runSeeded(seed: seed &* 7_919, inputs: 1_000) }
    }

    func testTheSameSeedGivesTheSameRun() {
        func shownAfter(_ seed: UInt64) -> String {
            var rng = MailSeededGenerator(seed: seed)
            let h = TriageHarness(rows: 40)
            for step in 0..<300 { _ = randomInput(h, &rng, step: step) }
            return h.shown + "|" + (h.cursor ?? "-") + "|" + h.selected
        }
        XCTAssertEqual(shownAfter(42), shownAfter(42))
    }

    // MARK: Performance: shape and ratio

    private func nanoseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start)
    }

    private func median(_ samples: [Double]) -> Double {
        samples.sorted()[samples.count / 2]
    }

    /// What the work costs when nothing else is in the way: a busy machine, or a sanitizer,
    /// slows the longer list's samples more than the shorter one's, and the fastest sample is
    /// the one neither can spoil. The ratio that is asserted is taken from these.
    private struct Timing {
        var median: Double
        var fastest: Double
    }

    private func timing(_ samples: [Double]) -> Timing {
        Timing(median: median(samples), fastest: samples.min() ?? 0)
    }

    private func listRows(_ count: Int) -> [MailRow] {
        (0..<count).map { TriageHarness.row("R\($0)", rank: $0) }
    }

    private func reading(_ rows: [MailRow], scope: MailScope) -> MailListSnapshot {
        MailListSnapshot(scope: scope, rows: rows, total: MailCount(value: rows.count, isAtLeast: false),
                         hasMore: false, stillLoading: 0, isRebuilding: false, remote: nil,
                         coverage: nil, appliedThrough: 0)
    }

    /// Takes readings that each add or take away one row at the top, which is the model's
    /// whole path, and returns the median of the time each took.
    private func timeToTakeAReading(rows count: Int, repeats: Int = 120) -> Timing {
        let scope = MailScope(place: .mailbox(.inbox))
        let model = MailListModel(scope: scope, deviceName: "iPhone", timePhrase: { _ in "" })
        let base = listRows(count)
        var withArrival = base
        withArrival.insert(TriageHarness.row("N", rank: -1), at: 0)
        model.handle(.snapshot(reading(base, scope: scope)))
        var samples: [Double] = []
        for round in 0..<repeats {
            let next = reading(round % 2 == 0 ? withArrival : base, scope: scope)
            samples.append(nanoseconds { model.handle(.snapshot(next)) })
        }
        return timing(samples)
    }

    /// Takes readings that change what a row says and nothing else: the common one.
    private func timeToTakeAChangeOfWords(rows count: Int, repeats: Int = 120) -> Timing {
        let scope = MailScope(place: .mailbox(.inbox))
        let model = MailListModel(scope: scope, deviceName: "iPhone", timePhrase: { _ in "" })
        let base = listRows(count)
        var edited = base
        edited[count / 2].snippet = "Edited"
        model.handle(.snapshot(reading(base, scope: scope)))
        var samples: [Double] = []
        for round in 0..<repeats {
            let next = reading(round % 2 == 0 ? edited : base, scope: scope)
            samples.append(nanoseconds { model.handle(.snapshot(next)) })
        }
        return timing(samples)
    }

    func testPerformanceShape_aReadingIsTakenInTimeProportionalToItsRows() {
        _ = timeToTakeAReading(rows: 400, repeats: 20)       // warm up
        let at400 = timeToTakeAReading(rows: 400)
        let at2000 = timeToTakeAReading(rows: 2_000)
        let words400 = timeToTakeAChangeOfWords(rows: 400)
        let words2000 = timeToTakeAChangeOfWords(rows: 2_000)
        func ratio(_ long: Timing, _ short: Timing) -> String {
            String(format: "median %.1f, fastest %.1f", long.median / short.median, long.fastest / short.fastest)
        }
        print("U3 PERF (\(Self.build)) reading with an arrival: 400 rows \(Int(at400.median / 1_000)) µs, "
              + "2,000 rows \(Int(at2000.median / 1_000)) µs, ratio \(ratio(at2000, at400))")
        print("U3 PERF (\(Self.build)) reading that changes words: 400 rows \(Int(words400.median / 1_000)) µs, "
              + "2,000 rows \(Int(words2000.median / 1_000)) µs, ratio \(ratio(words2000, words400))")
        // Linear is 5 times; "about six" leaves room for the cache.
        XCTAssertLessThanOrEqual(at2000.fastest / at400.fastest, 6.5, "taking a reading is not linear in its rows")
        XCTAssertLessThanOrEqual(words2000.fastest / words400.fastest, 6.5, "taking a change of words is not linear")
    }

    /// Which build the numbers came from, for the line that reports them.
    private static var build: String {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if targetEnvironment(simulator)
        return configuration + ", Simulator"
        #else
        return configuration
        #endif
    }

    func testPerformanceShape_aCursorMoveCopiesNoArrayAndPublishesNothingTheListReads() {
        var perMove: [Int: Double] = [:]
        var perRun: [Int: Double] = [:]
        for count in [400, 2_000] {
            let scope = MailScope(place: .mailbox(.inbox))
            let model = MailListModel(scope: scope, deviceName: "iPhone", timePhrase: { _ in "" })
            var first = reading(listRows(count), scope: scope)
            first.hasMore = true                          // so the growth check has work to do
            first.total = MailCount(value: count * 3, isAtLeast: false)
            model.handle(.snapshot(first))
            // The first row on screen is deep in the list, where a scan for it would be long, and
            // far enough from the end that nothing more is asked for.
            let top = model.rows[count - 200]
            model.handle(.scrolled(MailViewport(firstRow: top.id, key: top.key, offset: 0)))
            let moveFrom = model.rows[count - 300]
            model.handle(.place(moveFrom.id))
            var listPublications = 0
            var markPublications = 0
            let listWatch = model.list.objectWillChange.sink { listPublications += 1 }
            let markWatch = model.markChanges.sink { _ in markPublications += 1 }

            // The rows live in one buffer, and a move does not make another.
            let before = model.rows.withUnsafeBufferPointer { $0.baseAddress }
            let moves = 600
            var samples: [Double] = []
            for index in 0..<moves {
                let direction: MailDirection = (index / 100) % 2 == 0 ? .older : .newer
                samples.append(nanoseconds { model.handle(.move(direction)) })
            }
            let after = model.rows.withUnsafeBufferPointer { $0.baseAddress }
            XCTAssertEqual(before, after, "a cursor move copied the rows (\(count))")
            XCTAssertEqual(listPublications, 0, "the list was told something on a cursor move (\(count))")
            XCTAssertEqual(markPublications, moves, "one mark change per move (\(count))")
            perMove[count] = median(samples)

            // A held ⇧J does no more: it touches the rows the run gained or lost, and no others.
            var runSamples: [Double] = []
            for index in 0..<200 {
                let direction: MailDirection = (index / 50) % 2 == 0 ? .older : .newer
                runSamples.append(nanoseconds { model.handle(.extendSelection(direction)) })
            }
            XCTAssertEqual(before, model.rows.withUnsafeBufferPointer { $0.baseAddress }, "a run copied the rows (\(count))")
            XCTAssertEqual(listPublications, 0, "the list was told something on a run (\(count))")
            perRun[count] = median(runSamples)
            withExtendedLifetime((listWatch, markWatch)) {}
        }
        print("U3 PERF (\(Self.build)) cursor move: 400 rows \(Int(perMove[400]! / 1_000)) µs, "
              + "2,000 rows \(Int(perMove[2_000]! / 1_000)) µs")
        // Constant, not proportional: five times the rows must not be five times the time. (A
        // floor keeps a clock's granularity from deciding it.)
        XCTAssertLessThanOrEqual(perMove[2_000]!, max(perMove[400]! * 3, 50_000),
                                 "a cursor move costs more the longer the list")
        print("U3 PERF (\(Self.build)) held shift-J: 400 rows \(Int(perRun[400]! / 1_000)) µs, "
              + "2,000 rows \(Int(perRun[2_000]! / 1_000)) µs")
        XCTAssertLessThanOrEqual(perRun[2_000]!, max(perRun[400]! * 3, 50_000),
                                 "a held shift-J costs more the longer the list")
    }
}

// MARK: - The review of U3 (mail-working/review/pkg-U3.md)

/// One test for each finding, written to fail without its fix, and for the rules the review's
/// rulings wrote into MAIL-UX: T7's readings he asked for, T46's positions, T2's nearest row.
extension MailListModelTests {

    private func marks(_ h: TriageHarness, _ body: () -> Void) -> [MailMarkChange] {
        var seen: [MailMarkChange] = []
        let watch = h.model.markChanges.sink { seen.append($0) }
        body()
        withExtendedLifetime(watch) {}
        return seen
    }

    // MARK: P-1: a reading he asked for is not an outside change

    func testP1_aReadingForRowsHeAskedForIsTakenInAtOnceWhileHeIsStillMoving() {
        let h = TriageHarness(rows: 1_000, limit: 100)
        XCTAssertTrue(h.model.list.shown.hasMore, "a place longer than its limit says there is more")
        for _ in 0..<75 { h.send(.move(.older)) }        // moving, so never at rest
        XCTAssertFalse(h.model.isIdle)
        XCTAssertEqual(h.growths, [200])
        XCTAssertEqual(h.model.rows.count, 200)
        XCTAssertEqual(h.model.limit, 200)
        XCTAssertFalse(h.model.hasWaitingReading)
    }

    func testP1_oneStepIsAskedForOnceUpToTheCapAndNoFurther() {
        let h = TriageHarness(rows: 2_500, limit: 100)
        for _ in 0..<40 { h.send(.jumpToOldest) }
        XCTAssertEqual(h.growths, Array(stride(from: 200, through: 2_000, by: 100)))
        XCTAssertEqual(h.model.rows.count, 2_000)
        XCTAssertEqual(h.model.limit, MailTuning.listCap)
    }

    func testP1_aStepIsNotAskedForAgainUntilTheLastOneIsTakenIn() {
        let scope = MailScope(place: .mailbox(.inbox))
        let model = MailListModel(scope: scope, deviceName: "iPhone", timePhrase: { _ in "" })
        var first = reading(listRows(100), scope: scope)
        first.hasMore = true
        first.total = MailCount(value: 1_000, isAtLeast: false)
        model.handle(.snapshot(first))
        func asked(_ effects: [MailListEffect]) -> [Int] {
            effects.compactMap { if case .growTo(let limit) = $0 { return limit } else { return nil } }
        }
        var growths: [Int] = []
        for _ in 0..<95 { growths += asked(model.handle(.move(.older))) }
        XCTAssertEqual(growths, [200], "asked once, though the cursor went on and nothing has come")
        var second = reading(listRows(200), scope: scope)
        second.hasMore = true
        second.total = MailCount(value: 1_000, isAtLeast: false)
        model.handle(.snapshot(second))
        XCTAssertEqual(model.rows.count, 200)
        XCTAssertEqual(asked(model.handle(.move(.older))), [], "the cursor is far from the new end")
    }

    func testP1_tenEsInALongPlaceLeaveTheFootFilled() {
        let h = TriageHarness(rows: 300, limit: 100)
        for _ in 0..<10 { h.done() }
        XCTAssertEqual(h.model.rows.count, 100)
        XCTAssertEqual(h.model.rows.first?.id.thread, TriageHarness.letter(10))
        XCTAssertEqual(h.model.rows.last?.id.thread, "R109")
        XCTAssertEqual(h.cursor, TriageHarness.letter(10))
    }

    func testP1_rowsBelowTheLastAreTakenInEvenWhileSomethingElseWaits() {
        let h = TriageHarness(rows: 12, limit: 10)
        h.send(.place(h.id("B")))
        h.outsideDone("C")                               // waits: not at rest
        XCTAssertEqual(h.shown, "ABCDEFGHIJK", "C waits, and the slot it frees at the foot is filled")
        h.limit = 12
        h.deliver()                                      // a larger reading
        XCTAssertEqual(h.shown, "ABCDEFGHIJKL", "L was added below the last row: nothing moved")
        XCTAssertTrue(h.model.hasWaitingReading, "C's removal still waits")
        h.send(.idle)
        XCTAssertEqual(h.shown, "ABDEFGHIJKL")
        XCTAssertFalse(h.model.hasWaitingReading)
    }

    func testP1_aCheckHeAskedForIsTakenInAtOnceUntilTheNextRest() {
        let h = TriageHarness()
        h.send(.refresh)
        h.arrive("N")
        XCTAssertEqual(h.model.rows.first?.id.thread, "N", "he asked for it")
        h.send(.idle)
        h.send(.move(.older))                            // he is at it again
        h.arrive("M", rank: -2)
        XCTAssertEqual(h.model.rows.first?.id.thread, "N")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    // MARK: P-2, P-3, P-4: undo and Send and Done

    func testP2_undoReopensTheConversationThatWasOpenAndReplacesTheOneOpenNow() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.press(.done)                                   // D opens
        h.send(.step(.older))                            // E opens
        XCTAssertEqual(h.openLetter, "E")
        h.undoTop()
        XCTAssertEqual(h.openLetter, "C")
        XCTAssertEqual(h.model.cursorID, h.id("C"))
        XCTAssertEqual(h.cursor, "C")
    }

    func testP3_aTargetTheSourceNoLongerHasIsTakenAwayByTheNextReading() {
        let h = TriageHarness()
        h.deliversOnUndo = false                         // no reading comes with the undo
        h.send(.toggleSelected(h.id("C")))
        h.send(.toggleSelected(h.id("D")))
        h.press(.done)
        h.mailbox.removeAll { $0.id.thread == "D" }      // deleted at Gmail meanwhile
        h.undoTop()
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "put back from the entry, in that turn")
        h.deliver()
        XCTAssertEqual(h.shown, "ABCEFGHIJ", "and D, which the source does not have, goes with the next reading")
    }

    func testP3_aReadingOlderThanTheUndoIsRefusedFromThenOn() {
        let h = TriageHarness()
        h.deliversOnUndo = false
        h.send(.place(h.id("C")))
        h.press(.done)
        let afterDone = h.sequence
        h.undoTop()
        XCTAssertGreaterThan(h.model.appliedThrough, afterDone, "the undo's receipt is the floor")
        var old = h.snapshot(for: h.important, appliedThrough: afterDone)
        old.rows.removeAll { $0.id.thread == "C" }
        h.model.handle(.snapshot(old))
        XCTAssertNotNil(h.row("C"))
    }

    func testP4_undoWithinTheHoldOfASendAndDoneReopensTheConversationAndPutsTheRowBack() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.press(.sendAndDone)
        guard let screenHalf = h.settled.first else { return XCTFail("no screen half") }
        h.completeSend(screenHalf, holdEnds: 10)
        h.now = h.now.addingTimeInterval(3)
        let outcome = h.undoTop()
        XCTAssertEqual(outcome, .undone(MailToast(text: "Undone", action: nil)))
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.openLetter, "C")
        XCTAssertEqual(h.cursor, "C")
    }

    func testP4_theEntryTheComposerPushesHoldsTheSubjectForItsWords() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.press(.sendAndDone)
        guard let screenHalf = h.settled.first else { return XCTFail("no screen half") }
        let entry = h.completeSend(screenHalf)
        guard case .send(_, _, let doneSubject) = entry.kind else { return XCTFail() }
        XCTAssertEqual(doneSubject, "Subject C")
        XCTAssertEqual(entry.description, "Sent and marked Done")
    }

    // MARK: P-5, P-6: rest, and the chip over an empty place

    func testP5_theReadingThatAnswersEnteringAReturnedPlaceIsTakenWhole() {
        let h = TriageHarness()
        h.observesWhileAway = false
        h.send(.idle)
        h.show(h.other)
        h.arrive("N")                                    // Important is away: it is told nothing
        h.show(h.important)                              // returns, with nothing read since it left
        h.answerEntry()                                  // the session marks the reading that answers entering
        XCTAssertEqual(h.model.rows.first?.id.thread, "N", "he asked for it")
        h.arrive("M", rank: -2)                          // from elsewhere, a moment later
        XCTAssertEqual(h.model.rows.first?.id.thread, "N")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    func testP5_whatWasWaitingForAPlaceIsAppliedAsItIsShown() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.show(h.other)
        h.outsideDone("G")                               // Important is told while away: it waits
        XCTAssertNotNil(h.models[h.important]?.rows.first { $0.id.thread == "G" })
        h.show(h.important)
        XCTAssertNil(h.row("G"))
    }

    func testP6_everyRowOfAWaitingReadingCountsWhenNoRowIsShown() {
        let h = TriageHarness(rows: 1)
        h.press(.done)
        h.arrive("N")
        h.arrive("M", rank: -2)
        XCTAssertEqual(h.shown, "")
        XCTAssertEqual(h.model.list.shown.arrivals, 2)
        XCTAssertNil(h.cursor)
        h.send(.idle)
        XCTAssertEqual(h.shown, "MN")
        XCTAssertEqual(h.cursor, "M")
    }

    // MARK: T46 and P-7: a position is a key and points

    func testT46_aPositionIsTheKeyOfTheRowThatWasFirstAndWholePointsIntoIt() {
        let h = TriageHarness()
        let position = h.viewport("D", offset: 12)
        XCTAssertEqual(position.key, TriageHarness.row("D", rank: 3).key)
        XCTAssertEqual(position.firstRow, h.id("D"))
        XCTAssertEqual(position.offset, 12)
    }

    func testT46_whenTheLastRowHasLeftTheLastRowStandsInForIt() {
        let h = TriageHarness()
        h.send(.place(h.id("J")))
        h.send(.scrolled(h.viewport("J", offset: 5)))
        h.press(.done)
        let before = h.effects.count
        h.show(h.other)
        h.show(h.important)
        let expected = MailViewport(firstRow: h.id("I"), key: TriageHarness.row("I", rank: 8).key, offset: 0)
        XCTAssertTrue(h.effects.suffix(from: before).contains(.restoreViewport(expected)))
    }

    func testT46_aColdLaunchFindsTheStoredPositionByItsKeyWhenItsRowHasGone() {
        let h = TriageHarness()
        let model = MailListModel(scope: h.important, deviceName: "iPhone", timePhrase: { _ in "" })
        model.handle(.snapshot(h.snapshot(for: h.important)))
        let gone = MailViewport(firstRow: TriageHarness.id("Z"),
                                key: MailOrderKey(group: 0, sortKey: 99_650, tie: 0), offset: 30)
        model.handle(.scrolled(gone))
        let effects = model.handle(.enter)
        let expected = MailViewport(firstRow: TriageHarness.id("E"), key: TriageHarness.row("E", rank: 4).key, offset: 0)
        XCTAssertTrue(effects.contains(.restoreViewport(expected)))
    }

    func testT46_aPositionThatNamesARowTheListHasIsHandedBackAsItWas() {
        let h = TriageHarness()
        h.send(.scrolled(h.viewport("D", offset: 12)))
        let before = h.effects.count
        h.show(h.other)
        h.show(h.important)
        XCTAssertTrue(h.effects.suffix(from: before).contains(.restoreViewport(h.viewport("D", offset: 12))))
    }

    func testT11_closingPutsTheListWhereItWas() {
        let h = TriageHarness()
        h.send(.scrolled(h.viewport("C", offset: 7)))
        h.send(.open(h.id("E")))
        let effects = h.send(.close)
        XCTAssertTrue(effects.contains(.restoreViewport(h.viewport("C", offset: 7))))
    }

    // MARK: P-8: nothing proportional to the list on a key

    func testP8_aRowKnowsItsOwnSelectionFromItsKeyAlone() {
        let h = TriageHarness()
        h.send(.toggleSelected(h.id("I")))
        h.send(.place(h.id("B")))
        h.send(.extendSelection(.older))
        h.send(.extendSelection(.older))                 // B, C, D live
        let rows = h.model.rows
        XCTAssertEqual(rows.filter { h.model.isSelected($0) }.map(\.id.thread), ["B", "C", "D", "I"])
        h.send(.selectFromHere)                          // from the cursor, D, down
        XCTAssertEqual(h.model.rows.filter { h.model.isSelected($0) }.map(\.id.thread),
                       ["D", "E", "F", "G", "H", "I", "J"])
        XCTAssertTrue(h.model.isSelected(h.id("E")))
        XCTAssertFalse(h.model.isSelected(h.id("B")))
    }

    func testP8_aRunTellsTheRowsOnlyWhatItGainedOrLost() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        let seen = marks(h) {
            h.send(.extendSelection(.older))             // anchor C, move to D
            h.send(.extendSelection(.older))             // E
            h.send(.extendSelection(.newer))             // back to D
        }
        let selections = seen.compactMap { change -> (Set<String>, Set<String>)? in
            if case .selection(let added, let removed) = change {
                return (Set(added.map(\.thread)), Set(removed.map(\.thread)))
            }
            return nil
        }
        XCTAssertEqual(selections.count, 3)
        XCTAssertEqual(selections[0].0, ["C", "D"])
        XCTAssertEqual(selections[1].0, ["E"])
        XCTAssertEqual(selections[2].1, ["E"])
        XCTAssertTrue(selections[1].1.isEmpty && selections[2].0.isEmpty)
    }

    func testXTellsTheRowTheOneItChanged() {
        let h = TriageHarness()
        let seen = marks(h) {
            h.send(.toggleSelected(h.id("C")))
            h.send(.toggleSelected(h.id("C")))
        }
        XCTAssertEqual(seen, [.selection(added: [h.id("C")], removed: []),
                              .selection(added: [], removed: [h.id("C")])])
    }

    func testAnActionPublishesTheListOnceAndAKeyMovePublishesItNever() {
        let h = TriageHarness(rows: 12)
        var publications = 0
        let watch = h.model.list.objectWillChange.sink { publications += 1 }
        for _ in 0..<10 { h.done() }
        XCTAssertEqual(publications, 10, "ten E: ten deliveries of the list")
        publications = 0
        h.send(.move(.older))
        h.send(.extendSelection(.older))
        h.send(.toggleSelected(nil))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(watch) {}
    }

    // MARK: P-10 to P-12: what "nothing" and "selected" mean

    func testP10_doneOnASnoozedConversationIsSentBecauseItEndsTheSnooze() {
        let snoozed = MailRowReason.snoozed(until: TriageHarness.now.addingTimeInterval(3_600), ifNoReply: false)
        for place in [MailPlace.mailbox(.snoozed), .mailbox(.all)] {
            let h = TriageHarness(scope: MailScope(place: place))
            h.mailbox[2].inInbox = false
            h.mailbox[2].isUnread = false
            h.mailbox[2].reason = snoozed
            h.deliver()
            h.send(.place(h.id("C")))
            h.press(.done)
            XCTAssertEqual(h.performed.last?.change, .done, "\(place)")
        }
    }

    func testP11_aSelectionByScopeIsNeverDecidedToChangeNothing() {
        let h = TriageHarness(scope: MailScope(place: .search("subject")))
        for index in h.mailbox.indices {
            h.mailbox[index].inInbox = false
            h.mailbox[index].isUnread = false
        }
        h.deliver()
        h.send(.place(h.id("C")))
        h.press(.done)
        XCTAssertTrue(h.performed.isEmpty, "row by row, every loaded row says nothing would change")
        h.send(.selectAll)
        h.press(.done)
        XCTAssertEqual(h.performed.count, 1, "but a scope has rows that are not loaded: it is sent")
    }

    func testP12_aSelectionByScopeLeavesOutAConversationNewMailHasMovedAboveItsKey() {
        let h = TriageHarness()
        h.send(.selectAll)
        h.newMail(in: "D")                               // above the selection's key in the source
        XCTAssertEqual(h.model.arrivals, 1)
        h.done()
        XCTAssertEqual(h.shown, "D", "the source left D alone, as T45 says, and so does the screen")
        XCTAssertEqual(h.mailbox.first { $0.id.thread == "D" }?.inInbox, true)
        XCTAssertEqual(h.mailbox.filter { !$0.inInbox }.count, 9)
    }

    func testP12_theCountReadBackLeavesOutArrivalsWaitingInTheChip() {
        let h = TriageHarness()
        h.send(.firstRowOnScreen(false))
        h.arrive("N")
        h.arrive("M", rank: -2)
        XCTAssertEqual(h.model.arrivals, 2)
        h.send(.selectAll)
        guard case .scope(_, _, let count) = h.model.selection else { return XCTFail() }
        XCTAssertEqual(count, MailCount(value: 10, isAtLeast: false))
    }

    func testT22_theCountSaysPlusWhileItMayBeShort() {
        let h = TriageHarness()
        var reading = h.snapshot(for: h.important)
        reading.total = MailCount(value: 1_204, isAtLeast: true)
        h.model.handle(.snapshot(reading))
        h.send(.selectAll)
        guard case .scope(_, _, let count) = h.model.selection else { return XCTFail() }
        XCTAssertEqual(count, MailCount(value: 1_204, isAtLeast: true))
    }

    // MARK: P-13, P-14, P-15: read, a run, a kept row

    func testP13_readingByOpeningMarksOnlyWhatHasBeenOnScreenAndAReplyInItsTurn() {
        let h = TriageHarness()
        h.unseenReply = ["C"]
        h.send(.open(h.id("C")))
        let seen = MailMessageID(account: TriageHarness.account, message: "C-m2")
        let reply = MailMessageID(account: TriageHarness.account, message: "C-m3")
        h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0, newestSeen: seen, hasUnseen: true)))
        h.send(.readDelayElapsed(h.id("C")))
        XCTAssertEqual(h.performed.last?.target, .message(seen))
        XCTAssertEqual(h.performed.last?.change, .read(true))
        XCTAssertEqual(h.performed.last?.isUndoable, false)
        // The reply is scrolled into view: its own 400 ms, and then the conversation.
        let effects = h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0, newestSeen: reply, hasUnseen: false)))
        XCTAssertTrue(effects.contains(.markReadAfter(h.id("C"), delay: 0.4)))
        h.send(.readDelayElapsed(h.id("C")))
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("C")]))
    }

    func testP14_aLiveRunIsFixedToItsRowsWhenRowsChangeUnderIt() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.send(.extendSelection(.older))
        h.send(.extendSelection(.older))                 // B, C, D live; cursor on D
        XCTAssertEqual(h.selected, "BCD")
        h.outsideDone("B")                               // the anchor leaves, when it is applied
        let seen = marks(h) { h.send(.idle) }
        XCTAssertEqual(h.selected, "CD")
        XCTAssertTrue(seen.contains(.selection(added: [], removed: [h.id("B")])), "the rows are told")
        XCTAssertTrue(h.model.selectedIDs.isSubset(of: Set(h.model.rows.map(\.id))))
        h.press(.toggleStar)
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("C"), h.id("D")]),
                       "what is selected is what is drawn as selected")
    }

    func testP15_aKeptRowTheReadingConfirmsIsAnOrdinaryRowEvenWhenThatReadingMustWait() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.model.handle(.act(.toggleStar, on: nil))       // kept, and no reading yet
        XCTAssertTrue(h.model.keptIDs.contains(h.id("C")))
        h.outsideDone("H")                               // a reading that includes C, and must wait
        XCTAssertFalse(h.model.keptIDs.contains(h.id("C")))
        XCTAssertNotNil(h.row("H"))
    }

    func testP15_aRowThatRulesSaidStaysAndTheReadingOmitsIsDimmed() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.model.handle(.act(.toggleStar, on: nil))
        XCTAssertFalse(h.model.isDimmed(h.id("C")))
        h.mailbox.removeAll { $0.id.thread == "C" }      // a custom split claims it
        h.deliver()
        XCTAssertTrue(h.model.isDimmed(h.id("C")))
        XCTAssertTrue(h.model.list.shown.dimmed.contains(h.id("C")))
    }

    func testT17_aReadingThatIncludesAKeptRowMakesItAnOrdinaryRowAgain() {
        let h = TriageHarness(scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        h.send(.place(h.id("C")))
        h.press(.toggleRead)
        XCTAssertTrue(h.model.isDimmed(h.id("C")))
        h.mailbox[2].isUnread = true                     // it matches the filter again
        h.deliver()
        XCTAssertFalse(h.model.isDimmed(h.id("C")))
        XCTAssertFalse(h.model.keptIDs.contains(h.id("C")))
        XCTAssertNotNil(h.row("C"))
    }

    func testT17_comingBackFromTheBackgroundDoesNotDropAKeptRow() {
        let h = TriageHarness(scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        h.send(.place(h.id("C")))
        h.press(.toggleRead)
        h.send(.firstRowOnScreen(false))
        h.send(.scrolled(h.viewport("A", offset: 0)))
        h.send(.firstRowOnScreen(true))
        h.send(.idle)
        h.deliver()
        XCTAssertNotNil(h.row("C"))
        XCTAssertTrue(h.model.isDimmed(h.id("C")))
    }

    // MARK: P-16, P-17, P-19

    func testP16_whenEveryRowWasATargetAndSomeStayTheCursorGoesToTheNearestRowNotTheFirst() {
        let invoices = MailLabelRef(id: "Label_12", name: "Invoices", colorHex: nil)
        let h = TriageHarness(scope: MailScope(place: .mailbox(.inbox)), rows: 6, otherAccountRows: [1, 3, 5])
        h.send(.place(h.id("C")))
        h.send(.selectAll)
        h.press(.move(account: TriageHarness.account, to: invoices))
        // The first account's A, C and E are moved; the second's B, D and F are not touched.
        XCTAssertEqual(h.shown, "BDF")
        XCTAssertEqual(h.cursor, "D", "the nearest row to where the cursor was: older than C")
    }

    func testP17_uOnAnOpenConversationThatHasLeftTheListLeavesItUnreadAndGoesBack() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.outsideDone("C")
        XCTAssertNil(h.row("C"))
        let effects = h.press(.toggleRead)
        XCTAssertEqual(h.performed.last?.change, .read(false))
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("C")]))
        XCTAssertTrue(effects.contains(.close))
    }

    func testP19_anActionThatNamesARowThatHasLeftTheListIsStillSent() {
        let h = TriageHarness()
        h.send(.place(h.id("B")))
        h.outsideDone("F")
        h.send(.idle)
        XCTAssertNil(h.row("F"))
        h.press(.done, on: "F")
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("F")]))
        XCTAssertEqual(h.cursor, "B", "the cursor was not a target")
    }

    func testP19_aReceiptRaisesWhatTheModelKnowsSoAStaleReadingCannotResolveARow() {
        let h = TriageHarness(scope: MailScope(place: .search("subject")))
        h.send(.place(h.id("C")))
        let effects = h.model.handle(.act(.done, on: nil))      // C is drawn as changed: unknown
        guard case .perform(let request)? = effects.first else { return XCTFail() }
        h.model.handle(.performed(token: request.token, MailReceipt(sequence: 5, count: 1)))
        var stale = h.snapshot(for: h.model.scope, appliedThrough: 3)
        stale.rows.removeAll { $0.id.thread == "C" }
        h.model.handle(.snapshot(stale))
        XCTAssertNotNil(h.row("C"), "older than the command: it says nothing about C")
        var fresh = h.snapshot(for: h.model.scope, appliedThrough: 5)
        fresh.rows.removeAll { $0.id.thread == "C" }
        h.model.handle(.snapshot(fresh))
        XCTAssertNil(h.row("C"), "a reading that has the command decides")
    }

    func testP19_undoReopeningAnUnreadConversationStartsItsFourHundredMilliseconds() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))                         // unread
        h.press(.done)
        let before = h.effects.count
        h.undoTop()
        XCTAssertTrue(h.effects.suffix(from: before).contains(.markReadAfter(h.id("C"), delay: 0.4)))
    }

    func testP19_aReadingTakenWhileTheFirstRowsAreHeldOnesStillCountsWhatWaitsAbove() {
        let h = TriageHarness(scope: MailScope(place: .split(MailSplit.importantID), filters: [.unread]))
        h.send(.place(h.id("A")))
        h.press(.toggleRead)                             // A is kept, and is the first row
        h.arrive("N")
        XCTAssertEqual(h.model.rows.first?.id.thread, "A")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    // MARK: T13, T33, T36 (the limit), T2

    func testT13_anActionOnAnOpenConversationThatHasLeftTheListStillActsOnIt() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.outsideDone("C")
        XCTAssertNil(h.cursor)
        h.press(.done)
        XCTAssertEqual(h.performed.last?.target, .conversations([h.id("C")]))
        XCTAssertEqual(h.openLetter, "D", "the next opens, worked out from C's place")
        XCTAssertEqual(h.toasts.last?.text, "Marked \u{201C}Subject C\u{201D} Done", "and it is named")
    }

    func testT13_whileItIsOpenAndNoLongerInTheListNoRowHasTheCursorAndItsPlaceIsRemembered() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        h.outsideDone("C")
        XCTAssertNil(h.cursor)
        XCTAssertEqual(h.model.cursorID, h.id("C"))
        XCTAssertEqual(h.model.cursorHint?.key, TriageHarness.row("C", rank: 2).key)
    }

    func testT33_searchResultsTakeDoneAndUndoLikeAnyList() {
        let h = TriageHarness(scope: MailScope(place: .search("subject")))
        h.send(.place(h.id("C")))
        h.press(.done)
        XCTAssertEqual(h.cursor, "D")
        h.undoTop()
        XCTAssertEqual(h.cursor, "C")
        XCTAssertEqual(h.row("C")?.inInbox, true)
    }

    func testT36_noRetryWhenGmailsLimitForTheDayWasReached() {
        let h = TriageHarness()
        h.send(.place(h.id("C")))
        h.done()
        h.refuse(h.stack.top!.receipt, .limitReached)
        XCTAssertEqual(h.toasts.last, MailToast(
            text: "Couldn't mark \u{201C}Subject C\u{201D} Done: Gmail's limit for today was reached.",
            action: nil))
    }

    func testT45_aDoneOnTheMessagesSeenSaysThatAReplyKeepsTheConversationInTheInbox() {
        let h = TriageHarness()
        h.send(.open(h.id("C")))
        let seen = MailMessageID(account: TriageHarness.account, message: "C-m3")
        h.send(.reader(MailReaderFacts(topMessage: nil, offset: 0, newestSeen: seen, hasUnseen: true)))
        h.unseenReply = ["C"]
        h.done()
        XCTAssertEqual(h.toasts.last, MailToast(
            text: "Marked Done \u{00B7} a new reply keeps \u{201C}Subject C\u{201D} in the inbox", action: .undo))
        XCTAssertEqual(h.stack.top?.description, "Marked Done")
    }

    func testT2_aListWithRowsHasACursorOnTheNearestRowNotTheFirst() {
        // Close a conversation that has left the list: its place was between D and E.
        let h = TriageHarness()
        h.send(.place(h.id("D")))
        h.send(.open(nil))
        h.outsideDone("D")
        h.send(.close)
        XCTAssertEqual(h.cursor, "E")
        XCTAssertNotEqual(h.cursor, "A")
    }
}


// MARK: - The second look (mail-working/review/pkg-U3-fixes.md)

/// Which readings count as asked for: growth decided from the reading, a check that has
/// finished, and the reading the session marks as the answer to an entry (MAIL-UX 3.11).
extension MailListModelTests {

    // MARK: M-1: a chip that is waiting does not stop the list growing

    func testM1_aWaitingChipDoesNotStopTheListGrowing() {
        let h = TriageHarness(rows: 1_000, limit: 100)
        for _ in 0..<75 { h.send(.move(.older)) }
        XCTAssertEqual(h.model.rows.count, 200)
        h.send(.firstRowOnScreen(false))
        h.send(.place(h.id("R150")))
        h.arrive("N")
        XCTAssertEqual(h.model.arrivals, 1)
        // The reading for the limit he asked for holds the arrival, so the model has one row fewer.
        for _ in 0..<230 { h.send(.move(.older)) }
        XCTAssertEqual(h.growths, [200, 300, 400, 500])
        XCTAssertEqual(h.model.rows.count, 499)
        XCTAssertEqual(h.model.rowsInNewestReading, 500)
        XCTAssertEqual(h.model.arrivals, 1)
    }

    func testM1_aGrowthIsStillAskedOnceAStep() {
        let h = TriageHarness(rows: 1_000, limit: 100)
        h.send(.firstRowOnScreen(false))
        h.arrive("N")                                    // a chip, before any growth
        for _ in 0..<400 { h.send(.move(.older)) }
        XCTAssertEqual(h.growths, Array(stride(from: 200, through: 500, by: 100)))
        XCTAssertEqual(h.growths.count, Set(h.growths).count, "no step twice")
    }

    // MARK: M-2: a check he asked for

    func testM2_whatACheckFindsIsTakenInAtOnceWhileItIsOut() {
        let h = TriageHarness()
        h.send(.refresh)
        h.send(.move(.older))                            // his next input does not end it
        h.send(.scrolled(h.viewport("B", offset: 3)))    // nor does the scroll that ends a pull
        h.arrive("N")
        XCTAssertEqual(h.model.rows.first?.id.thread, "N", "he asked for it")
        XCTAssertTrue(h.model.isAwaitingCheck)
    }

    func testM2_afterCheckFinishedMailFromElsewhereWaitsAgainWhileHeKeepsMoving() {
        let h = TriageHarness()
        h.send(.refresh)
        h.finishCheck()
        XCTAssertFalse(h.model.isAwaitingCheck)
        h.send(.move(.older))
        h.send(.scrolled(h.viewport("B")))
        h.send(.move(.older))
        h.arrive("N")                                    // no rest in between
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    func testM2_theListComingToRestEndsTheAllowanceToo() {
        let h = TriageHarness()
        h.send(.refresh)
        h.send(.idle)
        h.send(.move(.older))                            // at it again, and no check finished was sent
        XCTAssertFalse(h.model.isAwaitingCheck)
        h.arrive("N")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    func testM2_checkFinishedBeforeAnyCheckChangesNothing() {
        let h = TriageHarness()
        h.finishCheck()
        h.send(.move(.older))
        h.arrive("N")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    // MARK: M-3: the session says which reading answers an entry

    func testM3_aReturnedPlaceThatStayedObservedDoesNotTakeLaterMailForTheAnswer() {
        // Nothing changed while away and nothing was marked: the next reading is mail from
        // elsewhere, however soon it comes, and waits.
        let h = TriageHarness()
        h.send(.idle)
        h.show(h.other)
        h.show(h.important)
        h.arrive("N")
        XCTAssertEqual(h.shown, "ABCDEFGHIJ")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    func testM3_theMarkedReadingIsTakenWholeAndTheOneAfterItIsNot() {
        let h = TriageHarness()
        h.observesOnEntry = true
        h.observesWhileAway = false
        h.send(.idle)
        h.show(h.other)
        h.arrive("N")                                    // Important is away: it is told nothing
        h.show(h.important)                              // starts its observation: the first value is marked
        XCTAssertEqual(h.model.rows.first?.id.thread, "N")
        XCTAssertEqual(h.model.arrivals, 0)
        h.arrive("M", rank: -2)
        XCTAssertEqual(h.model.rows.first?.id.thread, "N")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    func testM3_aMarkedReadingGivenBeforeTheEntryIsAppliedAsItIsToo() {
        let h = TriageHarness()
        h.arrive("N")                                    // the entry left the list not at rest: N waits
        XCTAssertEqual(h.model.arrivals, 1)
        h.answerEntry()
        XCTAssertEqual(h.model.rows.first?.id.thread, "N")
        XCTAssertEqual(h.model.arrivals, 0)
    }

    func testM3_aMarkedReadingStillMayNotPutARowAboveAListNotShowingItsTop() {
        let h = TriageHarness()
        h.send(.scrolled(h.viewport("D", offset: 12)))
        h.show(h.other)
        h.mailbox.append(TriageHarness.row("N", rank: -1))
        h.show(h.important)
        h.answerEntry()
        XCTAssertEqual(h.shown, "ABCDEFGHIJ", "T9: the position restored is not the top")
        XCTAssertEqual(h.model.arrivals, 1)
    }

    // MARK: T16 and the row rules

    func testT16_doneOnASnoozedConversationIsSentWithoutAnySpecialCase() {
        let snoozed = MailRowReason.snoozed(until: TriageHarness.now.addingTimeInterval(3_600), ifNoReply: false)
        var row = TriageHarness.row("C", rank: 2, inInbox: false, unread: false)
        row.reason = snoozed
        let scope = MailScope(place: .mailbox(.all))
        // The row rules end the snooze, so the row Done hands back differs and is not "nothing".
        XCTAssertFalse(MailAction.done.wouldChangeNothing(on: row, in: scope))
        var plain = row
        plain.reason = nil
        XCTAssertTrue(MailAction.done.wouldChangeNothing(on: plain, in: scope),
                      "out of the inbox, read and not snoozed: nothing")
    }
}
