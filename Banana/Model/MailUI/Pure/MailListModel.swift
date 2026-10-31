#if !BANANA_PUBLIC
import Foundation
import Combine

// MARK: - The words the model speaks in

/// Which way the person is travelling through a list: toward older mail (down) or newer (up).
enum MailDirection: Equatable, Sendable {
    case older, newer

    var reversed: MailDirection { self == .older ? .newer : .older }
}

/// How a list was scrolled: the row that was first on screen, by id and by key, and how far it was
/// from the top edge in whole points. Whole points because a fractional offset in anything the
/// list reads once ran a render loop (MAIL-UX G5). The key is what finds the place again after the
/// row has left the list (T3, T26): the model then puts the view on the first row at or after it.
struct MailViewport: Equatable, Sendable {
    var firstRow: MailConversationID
    var key: MailOrderKey
    var offset: Int
}

/// The rows wholly on screen, first and last, after the host has scrolled a page.
struct MailVisibleRows: Equatable, Sendable {
    var first: MailConversationID
    var last: MailConversationID
}

/// What the reader tells the model about the conversation it is showing.
struct MailReaderFacts: Equatable, Sendable {
    /// The message at the top of the reader, and how far it is scrolled, in whole points.
    var topMessage: MailMessageID?
    var offset: Int
    /// The newest message that has been on screen. A message that arrived after it and has not
    /// been drawn is not covered by an action (T45).
    var newestSeen: MailMessageID?
    /// A message is waiting that has not been on screen: the reader's "1 new message" chip is
    /// showing (T13).
    var hasUnseen: Bool

    static let fresh = MailReaderFacts(topMessage: nil, offset: 0, newestSeen: nil, hasUnseen: false)
}

struct MailOpenConversation: Equatable, Sendable {
    var id: MailConversationID
    var facts: MailReaderFacts
}

/// What is selected (T20 to T24).
enum MailSelection: Equatable, Sendable {
    case none
    /// Chosen row by row: `X`, `⇧J`, `⇧K`, a tap while selecting.
    case rows(Set<MailConversationID>)
    /// "The list as it stood when the key was pressed": the scope and the key of its first
    /// selected row, so it includes rows that are not loaded and excludes anything that arrives
    /// after (T22, T45). `count` is what the header reads back, taken at that moment.
    case scope(MailScope, from: MailOrderKey, count: MailCount)

    var isEmpty: Bool {
        switch self {
        case .none: return true
        case .rows(let ids): return ids.isEmpty
        case .scope: return false
        }
    }
}

/// Which key opens a conversation with its composer open (T38).
enum MailComposerStart: Equatable, Sendable {
    case reply, forward
}

/// Where a cursor was when the list it was in was replaced by a filtered one (T32): the new list
/// puts it on the same conversation if it is in it, and otherwise on its successor by key.
struct MailCursorHint: Equatable, Sendable {
    var id: MailConversationID
    var key: MailOrderKey
    var direction: MailDirection
}

/// Why a change that looked done is not (T36).
enum MailReversal: Equatable, Sendable {
    /// Gmail refused it for good.
    case refused(MailFailure)
    /// The device could not save it.
    case notSaved(MailStoreProblem)
}

// MARK: - What the model publishes

/// What the list draws: which rows, and what is true of the list as a whole. Nothing here
/// changes when the cursor or the selection does — those are `MailListModel.markChanges` — so a
/// list that observes `MailListFeed` is not re-evaluated by a held `J` (MAIL-UX G2).
struct MailListShown {
    /// In the order the source delivered them. The rows are the source's own values, except
    /// that a row's `key` is the key it is *placed* by, which differs from the source's for a
    /// moment where the rule of T8 holds a row still.
    var rows: [MailRow]
    /// Rows kept on show though they no longer belong (T17): drawn dimmed.
    var dimmed: Set<MailConversationID>
    /// The chip at the top edge: how many conversations wait above the first row (T9). With no
    /// row at all it is how many wait to join, and the empty state yields to it.
    var arrivals: Int
    var total: MailCount
    var hasMore: Bool
    var stillLoading: Int
    var isRebuilding: Bool
    var remote: MailRemoteSearch?
    var coverage: MailCoverage?
    /// False until the source has delivered a first reading: an empty `rows` before that is
    /// "not read yet", never "nothing here".
    var hasDelivered: Bool
    /// One more for every publication.
    var generation: Int
}

/// The one thing the list observes. It publishes once per applied change — the person's own
/// action, or one application when the list has been idle — and never for a cursor move.
@MainActor
final class MailListFeed: ObservableObject {
    @Published fileprivate(set) var shown: MailListShown

    fileprivate init(_ shown: MailListShown) {
        self.shown = shown
    }
}

/// What moved, for the leaf that draws each row's cursor and selection (`MailRowMark`). A cursor
/// move is one of these, never a new list.
enum MailMarkChange: Equatable, Sendable {
    case cursor(from: MailConversationID?, to: MailConversationID?)
    case selection(added: Set<MailConversationID>, removed: Set<MailConversationID>)
}

// MARK: - What the model asks to have done

/// A change for the source, with the token that the answer comes back under.
struct MailPerformRequest: Equatable, Sendable {
    var token: UInt64
    /// Nil for the read that opening makes after 400 ms.
    var action: MailAction?
    var change: MailChange
    var target: MailTarget
    /// Whether it is an undo step. Being marked read by opening is not (T10).
    var isUndoable: Bool
}

/// Output of the model that someone else carries out: the screen, the host, the source, the
/// toast. The model touches none of them; it is handed the answer back as an input.
enum MailListEffect: Equatable, Sendable {
    /// Hand the change to the source, then give the receipt back as
    /// `MailListInput.performed(token:_:)`.
    case perform(MailPerformRequest)
    /// Remember it, once the receipt says it did something.
    case pushUndo(MailUndoEntry)
    /// Send and Done moved the screen, and asked the source for nothing: the send carries the
    /// Done. This is what was showing before, as an entry with no receipt and a placeholder
    /// kind. The composer completes it — its send receipt, `.send(…)` for the kind, the
    /// subject in `subjects` for "…is back in the inbox" — and pushes the one entry (T38).
    case settled(MailUndoEntry)
    case toast(MailToast)
    /// Show the conversation over the list (regular) or push it (compact); with its composer
    /// open when `composer` says so; at a reading position when `at` says so (an undo).
    case open(MailConversationID, composer: MailComposerStart?, at: MailReaderFacts?)
    /// Back to the list.
    case close
    /// Scroll only as far as needed to show the row whole, and one more row beyond it in
    /// `beyond` when there is one (T4).
    case reveal(MailConversationID, beyond: MailDirection?)
    case scrollToTop
    /// A page, by `Space` or `⇧Space`. The host reports the rows then on screen as
    /// `MailListInput.pagedTo`.
    case scrollPage(MailDirection)
    /// Put this row first at this offset (T3, T26). The row is one the list has: a row that
    /// has left is replaced by the first row at or after its key, at offset 0.
    case restoreViewport(MailViewport)
    /// Mark the conversation read if it is still the open one after `delay` seconds (T10); give
    /// the timer's end back as `MailListInput.readDelayElapsed`.
    case markReadAfter(MailConversationID, delay: TimeInterval)
    /// Observe the list again with a larger limit (6.1.7).
    case growTo(limit: Int)
    /// Check for mail now (a pull, ⌘R).
    case checkNow
    /// `Esc` in a search: leave it for the place it was started from (K9).
    case leaveSearch
    /// `Esc` with filters on and nothing else to undo (K9).
    case clearFilters
}

// MARK: - What the model is told

/// Every input of the model. The first group is facts — what the source delivered, what the host
/// saw, what a timer did — and never counts as the person's hands. The second is the person.
enum MailListInput {

    // MARK: Facts

    /// A reading from the source. Every change this device made was applied to the model's rows
    /// by the action that made it, so a reading that carries the change finds nothing to add.
    /// What the person asked for is taken in at once; changes from elsewhere wait for the list to
    /// be at rest (T7). The model works out for itself what it caused — its own command, a
    /// growth, an undo — and while a conversation covers the list everything is taken in. Of the
    /// two things only the session knows, this carries the first (MAIL-UX 3.11):
    ///
    /// **`answersEntry`.** The session observes the list in front and no other: entering a place
    /// starts an observation, and the first value it delivers is the answer to the entry. Mark
    /// that one reading `answersEntry: true`, and no other; the model takes it whole. A cached
    /// page shown first, on a cold launch, is not the answer and is not marked: the
    /// observation's first value is, and replaces it.
    case snapshot(MailListSnapshot, answersEntry: Bool = false)
    /// **Check finished** — the second thing only the session knows. When he asked for a check
    /// (`refresh`: ⌘R, a pull, "Check mail now") what it finds is his to have at once. Send this,
    /// once, when the check has answered: when `status.asked` becomes `.finished` — at once if it
    /// found nothing new, otherwise after the next reading for the list in front, or after a
    /// second if none comes, since the new mail may belong to another place. From then a change
    /// from elsewhere waits again. The list coming to rest ends the allowance too; nothing else
    /// does — not his next input, because the scroll that ends a pull is one.
    case checkFinished
    /// The source's receipt for `MailListEffect.perform`.
    case performed(token: UInt64, MailReceipt)
    /// A change that cannot stand (T36). The entry has been taken off the stack.
    case reverted(MailUndoEntry, MailReversal)
    /// Three seconds without a key, touch, scroll or pointer movement over the list (section 0).
    /// A list covered by an open conversation is idle without it (T7): the session sends it
    /// all the same, once the person has stopped.
    case idle
    /// Whether the list's first row is on screen (T9).
    case firstRowOnScreen(Bool)
    /// Scrolling has stopped here.
    case scrolled(MailViewport)
    /// A page has been scrolled; these are the rows now wholly on screen (T4).
    case pagedTo(MailVisibleRows)
    /// What the open conversation's reader says about itself.
    case reader(MailReaderFacts)
    /// The 400 ms timer of `markReadAfter` has run out.
    case readDelayElapsed(MailConversationID)

    // MARK: The person

    /// The place is shown. A first visit puts the cursor on the first conversation at the top; a
    /// return puts it back (T3).
    case enter
    /// The place is left. A selection does not survive it (T23).
    case leave
    /// ⌘R or a pull: kept rows go, what has been waiting joins, and what the check finds is
    /// taken in at once (T17, T43).
    case refresh
    /// `J` / `↓`, `K` / `↑` in the list (T4).
    case move(MailDirection)
    /// ⌘↓ (the oldest row loaded) and ⌘↑ (the first row, and whatever waits above it).
    case jumpToOldest, jumpToNewest
    /// `Space` and `⇧Space` (T4).
    case page(MailDirection)
    /// A click or tap that only places the cursor.
    case place(MailConversationID)
    /// `Enter`, `→`, a click on a row: open the cursor's conversation, or this one (T10).
    case open(MailConversationID?)
    /// `R` or `F` in the list (T38).
    case openAndReply(MailComposerStart)
    /// Esc, `←` or Back with a conversation open (T11).
    case close
    /// `J` / `K` or the older and newer buttons with a conversation open (T12).
    case step(MailDirection)
    /// `X` (T20), or a tap on a row while selecting.
    case toggleSelected(MailConversationID?)
    /// `⇧J` / `⇧K` (T21).
    case extendSelection(MailDirection)
    /// ⌘A and ⌘⇧A (T22).
    case selectFromHere, selectAll
    case clearSelection
    /// `Esc`, with nothing of the overlay's to close (K9).
    case back
    /// An action, on the target of T15, or on this row alone (a swipe, a row's own button, a
    /// picker for the conversation it was opened for).
    case act(MailAction, on: MailConversationID?)
    /// The "N new" chip (T9).
    case chipUsed
    /// Undo has taken this entry off the stack and the source has answered with a receipt of
    /// sequence `through`: put the screen back (T26). Give it after `undo` returns.
    case restore(MailUndoEntry, through: UInt64)

    fileprivate var isThePersons: Bool {
        switch self {
        case .snapshot, .checkFinished, .performed, .reverted, .idle, .firstRowOnScreen, .reader,
             .readDelayElapsed:
            return false
        default:
            return true
        }
    }

    /// Any other key ends a run of `⇧J`s (T21). Scrolling is not a key.
    fileprivate var endsARun: Bool {
        switch self {
        case .extendSelection, .scrolled, .pagedTo: return false
        default: return isThePersons
        }
    }
}

// MARK: - The model

/// The triage loop of MAIL-UX section 3 for one scope, with no view in it.
///
/// It holds the rows as the source last delivered them; the cursor, the direction, the selection
/// and the open conversation; what is waiting for the list to be idle; and the rows that are kept
/// on show. Its inputs are a reading from the source, a key or a tap, and the facts the host
/// reports; its output is the rows to show and a list of effects for someone else to carry out.
/// It asks the source for nothing and knows no network, so every rule is a test that gives it
/// rows and presses keys.
///
/// **What it publishes, and what it does not.** `list` holds the rows and publishes once per
/// applied change. The cursor and the selection are not in it: they are read from the model, and
/// move through `markChanges`, which a row's own leaf observes. A held `J` therefore changes no
/// state that the list reads (G2), copies no array of rows, and does no work in proportion to
/// them.
///
/// **It keeps no overlay of pending changes.** The source has shown a command in every list
/// before it returns (the contract's promise 2), so the reading that follows an action finds the
/// model's rows already as they should be. The model still edits its own rows through
/// `MailRowRules` in the turn of the action, because the cursor has to move in that turn and
/// must know which rows left.
///
/// **Which readings wait.** Rows are added, removed or moved under the person's hand only when
/// the list has been idle (T7). A reading is not that when he asked for it — the rows beyond the
/// last one he has (growing the window, filling the end after an action), the answer to
/// entering a place, the result of a check — or when a conversation covers the list.
@MainActor
final class MailListModel {

    /// A conversation must have been showing this long before it is read (T10).
    static let readDelay: TimeInterval = 0.4
    /// The model asks for a step more when the cursor is this close to the last row (6.1.7).
    static let growMargin = 30

    let scope: MailScope
    /// The rows, for the list to observe.
    let list: MailListFeed

    /// Moves of the cursor and changes of the selection, for each row's own leaf.
    var markChanges: AnyPublisher<MailMarkChange, Never> { marks.eraseToAnyPublisher() }

    // MARK: State, readable

    /// The rows as shown: in the delivered order, a kept row where it was.
    private(set) var rows: [MailRow] = []
    /// The direction of travel (section 0). Older until a key says otherwise.
    private(set) var direction: MailDirection = .older
    /// The conversation open over the list, if any. It is always the cursor.
    private(set) var open: MailOpenConversation?
    /// The "N new" chip (T9).
    private(set) var arrivals = 0
    private(set) var isIdle = true
    private(set) var firstRowIsOnScreen = true
    private(set) var viewport: MailViewport?
    private(set) var appliedThrough: UInt64 = 0
    /// How many rows the model has asked the source for.
    private(set) var limit = MailTuning.listStep
    /// The conversation that has the cursor, even when it is the open one and has left the list
    /// (T13). `cursor` is the same, for a row that is shown.
    private(set) var cursorID: MailConversationID?

    /// The row that has the cursor (T2), or nil when there is none: an empty list, or a
    /// conversation open that has left the list and so is on no row (T13).
    var cursor: MailConversationID? {
        cursorIndex() == nil ? nil : cursorID
    }

    var selection: MailSelection {
        if let scopeSelection {
            return .scope(scope, from: scopeSelection.from, count: scopeSelection.count)
        }
        let ids = selectedRowIDs()
        return ids.isEmpty ? .none : .rows(ids)
    }

    /// Every shown row that is selected.
    var selectedIDs: Set<MailConversationID> {
        guard let scopeSelection else { return selectedRowIDs() }
        return Set(rows.lazy.filter { $0.key <= scopeSelection.from }.map(\.id))
    }

    /// Whether a row is selected, from the row alone and in no time: its key against the
    /// selection's. This is what a row's leaf asks when it is made.
    func isSelected(_ row: MailRow) -> Bool {
        if let scopeSelection { return row.key <= scopeSelection.from }
        if selectionBase.contains(row.id) { return true }
        guard runAnchor != nil, let anchor = runAnchorIndex() else { return false }
        let other = cursorIndex() ?? anchor
        let low = min(rows[anchor].key, rows[other].key)
        let high = max(rows[anchor].key, rows[other].key)
        return row.key >= low && row.key <= high
    }

    /// The same by id, which has to look the row up: for tests, and for what has no row to hand.
    func isSelected(_ id: MailConversationID) -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else { return false }
        return isSelected(row)
    }

    func isDimmed(_ id: MailConversationID) -> Bool { kept[id] == true }

    /// The rows kept on show after a marking action (T17), dimmed or not yet.
    var keptIDs: Set<MailConversationID> { Set(kept.keys) }

    /// Whether a reading is waiting for rest, or for the top to show (T7, T9).
    var hasWaitingReading: Bool { pending != nil }

    /// Whether a check he asked for is still out, so that what it finds is his to have at once.
    var isAwaitingCheck: Bool { awaitingCheck }

    /// How many rows the newest reading holds, which is what growing is decided from.
    var rowsInNewestReading: Int { readingCount }

    /// Whether the open conversation can go to the next older or newer one (T12, T42).
    func canStep(_ direction: MailDirection) -> Bool {
        open != nil && neighbour(of: cursorKey, in: direction) != nil
    }

    // MARK: State, private

    private let marks = PassthroughSubject<MailMarkChange, Never>()
    private let deviceName: String
    private let timePhrase: (Date) -> String

    private struct Meta: Equatable {
        var total = MailCount(value: 0, isAtLeast: false)
        var hasMore = false
        var stillLoading = 0
        var isRebuilding = false
        var remote: MailRemoteSearch?
        var coverage: MailCoverage?
        var delivered = false
    }
    private var meta = Meta()
    private var hasHadAReading = false

    /// The newest reading, whether or not it has all been taken in.
    private var latest: MailListSnapshot?
    /// How many rows the newest reading holds: what growing is decided from. A row held back in
    /// the chip is in the reading and not on screen, so counting the rows shown would stop a list
    /// that is scrolled deep, with a chip waiting, from ever growing again.
    private var readingCount: Int { latest?.rows.count ?? 0 }
    /// A reading that has not been taken in fully yet (T7, T9).
    private var pending: MailListSnapshot?
    /// Rows kept on show after a marking action. They are drawn like any other until a reading
    /// omits them; from then the value is true, and they are drawn dimmed (T17).
    private var kept: [MailConversationID: Bool] = [:]
    /// Rows drawn as changed, or put back, whose place the next reading decides (T16, T26).
    private var unresolved: Set<MailConversationID> = []

    /// Where the cursor's row is placed. Kept when the row leaves, so that the successor of its
    /// place can still be found.
    private var cursorKey: MailOrderKey?
    private var cursorIndexCache: Int?
    private var hint: MailCursorHint?
    /// The cursor came from another list's (T32), so a first visit does not reset it.
    private let cursorWasCarried: Bool
    private var visited = false
    /// The subject of the open conversation, for a toast about it once it has left the list.
    private var openSubject: String?

    /// A check he asked for is out, and what it finds is taken in until the session says it has
    /// finished (`checkFinished`) or the list next rests.
    private var awaitingCheck = false

    private var selectionBase: Set<MailConversationID> = []
    private var runAnchor: MailConversationID?
    private var runAnchorKey: MailOrderKey?
    private var scopeSelection: (from: MailOrderKey, count: MailCount)?

    private struct InFlight {
        var entry: MailUndoEntry?
        var action: MailAction?
        var change: MailChange
        /// It acted on the messages that had been on screen, and a reply has not (T45).
        var viaMessage = false
    }
    private var inFlight: [UInt64: InFlight] = [:]
    private var nextToken: UInt64 = 1

    private var dirty = false
    private var generation = 0

    /// `deviceName` is how the screens call this device ("iPhone", "iPad", "Mac"), for "this
    /// iPhone is full"; `timePhrase` words a snooze's time for its toast ("Thu 8 AM"). Neither
    /// has a default: a default would say the wrong thing on another device, in another
    /// language, and nobody would be told.
    init(scope: MailScope, carrying hint: MailCursorHint? = nil, deviceName: String,
         timePhrase: @escaping (Date) -> String) {
        self.scope = scope
        self.hint = hint
        self.cursorWasCarried = hint != nil
        self.deviceName = deviceName
        self.timePhrase = timePhrase
        self.list = MailListFeed(MailListShown(
            rows: [], dimmed: [], arrivals: 0, total: MailCount(value: 0, isAtLeast: false),
            hasMore: false, stillLoading: 0, isRebuilding: false, remote: nil, coverage: nil,
            hasDelivered: false, generation: 0))
    }

    // MARK: - The one entry point

    /// Takes one input and says what to do about it. At most one publication of `list` follows,
    /// and none for a cursor move.
    @discardableResult
    func handle(_ input: MailListInput) -> [MailListEffect] {
        var fx: [MailListEffect] = []
        if input.isThePersons { isIdle = false }
        if input.endsARun { endRun() }

        switch input {
        case .snapshot(let snapshot, let answersEntry): receive(snapshot, answersEntry: answersEntry)
        case .checkFinished: awaitingCheck = false
        case .performed(let token, let receipt): performed(token, receipt, &fx)
        case .reverted(let entry, let why): reverted(entry, why, &fx)
        case .idle: becameIdle()
        case .firstRowOnScreen(let on): firstRowOnScreenChanged(on)
        case .scrolled(let viewport): self.viewport = viewport
        case .pagedTo(let visible): pagedTo(visible)
        case .reader(let facts): readerSaid(facts, &fx)
        case .readDelayElapsed(let id): readDelayElapsed(id, &fx)

        case .enter: enter(&fx)
        case .leave: leave()
        case .refresh: refresh(&fx)
        case .move(let direction): move(direction, &fx)
        case .jumpToOldest: jumpToOldest(&fx)
        case .jumpToNewest: jumpToNewest(&fx)
        case .page(let direction): fx.append(.scrollPage(direction))
        case .place(let id): place(id)
        case .open(let id): openConversation(id, composer: nil, &fx)
        case .openAndReply(let start): openAndReply(start, &fx)
        case .close: closeConversation(&fx)
        case .step(let direction): step(direction, &fx)
        case .toggleSelected(let id): toggleSelected(id)
        case .extendSelection(let direction): extendSelection(direction, &fx)
        case .selectFromHere: selectByScope(fromCursor: true)
        case .selectAll: selectByScope(fromCursor: false)
        case .clearSelection: clearSelection()
        case .back: back(&fx)
        case .act(let action, let id): act(action, on: id, &fx)
        case .chipUsed: chipUsed(&fx)
        case .restore(let entry, let through): restore(entry, through: through, &fx)
        }

        ensureACursor()
        growIfNeeded(&fx)
        commit()
        return fx
    }

    /// T2: a list with a conversation in it has exactly one cursor, and an empty one has none.
    /// Every path above puts it right; this is the one place that says so, so that no sequence
    /// of inputs leaves it on a row that is not shown (the open conversation, which may have
    /// left the list, is the one thing the cursor may be on that is not). When a row is wanted
    /// and its place is known, it is the nearest row to that place; otherwise the first.
    private func ensureACursor() {
        guard open == nil else { return }
        if rows.isEmpty {
            if cursorID != nil { moveCursor(to: nil) }
            cursorKey = nil
            return
        }
        guard cursorID == nil || cursorIndex() == nil else { return }
        let nearest = cursorKey.flatMap { successor(of: $0, presentAt: nil, excluding: [])?.id }
        moveCursor(to: nearest ?? rows[0].id)
    }

    // MARK: - Readings (T7, T8, T9)

    private func receive(_ snapshot: MailListSnapshot, answersEntry: Bool) {
        guard snapshot.scope == scope, snapshot.appliedThrough >= appliedThrough else { return }
        appliedThrough = snapshot.appliedThrough
        latest = snapshot
        updateMeta(snapshot)
        guard hasHadAReading else {
            firstReading(snapshot)
            return
        }
        // Only a change from elsewhere waits for rest. This is not one when the session says it
        // answers entering the place, or the check he asked for is still out, or when a
        // conversation covers the list: nothing can move under a hand that cannot reach it.
        let free = isIdle || open != nil || awaitingCheck || answersEntry
        let topShowing = answersEntry ? viewportIsAtTop : firstRowIsOnScreen
        merge(snapshot, structure: free, top: free && topShowing)
    }

    private func updateMeta(_ snapshot: MailListSnapshot) {
        let new = Meta(total: snapshot.total, hasMore: snapshot.hasMore,
                       stillLoading: snapshot.stillLoading, isRebuilding: snapshot.isRebuilding,
                       remote: snapshot.remote, coverage: snapshot.coverage, delivered: true)
        if new != meta {
            meta = new
            dirty = true
        }
    }

    /// The first reading is the list. Nothing is under anyone's hand yet.
    private func firstReading(_ snapshot: MailListSnapshot) {
        hasHadAReading = true
        rows = snapshot.rows
        dirty = true
        if let hint {
            self.hint = nil
            direction = hint.direction
            if let index = indexOf(hint.id) {
                moveCursor(to: rows[index].id, at: index)
            } else if let successor = successor(of: hint.key, presentAt: nil, excluding: []) {
                moveCursor(to: successor.id)
            }
        }
        if cursorID == nil, let first = rows.first { moveCursor(to: first.id, at: 0) }
    }

    /// Takes a reading into the rows.
    ///
    /// What a row *says* is taken at once, wherever the row is, and so are the rows beyond the
    /// last one the model has: adding below the last row moves nothing. Where rows *are* —
    /// added above, removed, moved — changes only when `structure` allows, and a row that would
    /// join above the first one only when `top` allows as well (the first row is on screen):
    /// until then the reading waits, and the arrivals are counted for the chip. The row with the
    /// cursor does not move, and a kept row stays (T8, T9, T17).
    private func merge(_ snapshot: MailListSnapshot, structure: Bool, top: Bool) {
        // The common case: the same conversations in the same order, with perhaps new words.
        if kept.isEmpty, unresolved.isEmpty, snapshot.rows.count == rows.count,
           sameOrder(snapshot.rows) {
            if snapshot.rows != rows {
                rows = snapshot.rows
                dirty = true
                refreshCursorKey()
            }
            pending = nil
            setArrivals(0)
            return
        }

        var indexInReading = [MailConversationID: Int](minimumCapacity: snapshot.rows.count)
        for (index, row) in snapshot.rows.enumerated() where indexInReading[row.id] == nil {
            indexInReading[row.id] = index
        }

        // A kept row the reading confirms is an ordinary row again. One it omits is known, from
        // now, no longer to belong, and is drawn dimmed (T17).
        if !kept.isEmpty {
            for (id, dimmed) in Array(kept) {
                if indexInReading[id] != nil {
                    kept[id] = nil
                    if dimmed { dirty = true }
                } else if !dimmed {
                    kept[id] = true
                    dirty = true
                }
            }
        }

        // A row drawn as changed was waiting for this reading to say whether it still belongs.
        if !unresolved.isEmpty {
            endRun()
            let before = rows.count
            rows.removeAll { unresolved.contains($0.id) && indexInReading[$0.id] == nil }
            unresolved.removeAll()
            if rows.count != before {
                dirty = true
                rowsLeft()
            }
        }

        let above = arrivalIDs(in: snapshot)
        let hold = top ? [] : above
        let (candidate, cursorHeld) = makeCandidate(snapshot, indexInReading, hold: hold)

        if sameIDs(candidate) || structure {
            let same = sameIDs(candidate)
            if !same { endRun() }
            if !same || candidate != rows {
                rows = candidate
                dirty = true
            }
            if !same { rowsLeft() } else { refreshCursorKey() }
            // What was held back — arrivals above, a row the cursor is keeping still — is still
            // to come: the reading waits for the next time changes are applied.
            pending = (hold.isEmpty && !cursorHeld) ? nil : snapshot
            setArrivals(hold.count)
        } else {
            // Not allowed to move anything: say what the rows say, where they are, and take in
            // what lies below the last row, which moves nothing.
            for index in rows.indices {
                guard let at = indexInReading[rows[index].id] else { continue }
                var row = snapshot.rows[at]
                row.key = rows[index].key
                if row != rows[index] {
                    rows[index] = row
                    dirty = true
                }
            }
            appendRowsBelowTheLast(of: candidate)
            let everythingIsIn = sameIDs(candidate) && !cursorHeld && hold.isEmpty
            pending = everythingIsIn ? nil : snapshot
            setArrivals(above.count)
        }
    }

    private func sameOrder(_ other: [MailRow]) -> Bool {
        for index in rows.indices where rows[index].id != other[index].id { return false }
        return true
    }

    private func sameIDs(_ other: [MailRow]) -> Bool {
        other.count == rows.count && sameOrder(other)
    }

    /// Rows of the reading that sort after the model's last row and that it does not hold are
    /// added at once, idle or not (T7): the next page he scrolled towards, and the row that
    /// fills the end of the window after his own Done, arrive this way.
    private func appendRowsBelowTheLast(of candidate: [MailRow]) {
        guard let lastKey = rows.last?.key else { return }
        var start = candidate.count
        while start > 0, candidate[start - 1].key < lastKey { start -= 1 }
        guard start < candidate.count else { return }
        let present = Set(rows.lazy.map(\.id))
        let tail = candidate[start...].filter { !present.contains($0.id) }
        guard !tail.isEmpty else { return }
        rows.append(contentsOf: tail)
        dirty = true
    }

    /// The conversations of the reading that sort above the first shown row: the ones T9 holds
    /// back unless the top is showing. A conversation already in the list that new mail has
    /// moved above it counts the same. With no row shown, every row of the reading waits, and is
    /// counted: the place must not say it is clear over mail that is there (T9, promise 8).
    private func arrivalIDs(in snapshot: MailListSnapshot) -> Set<MailConversationID> {
        guard let first = rows.first else { return Set(snapshot.rows.lazy.map(\.id)) }
        var ids = Set<MailConversationID>()
        for row in snapshot.rows {
            guard row.key > first.key else { break }
            if row.id != first.id { ids.insert(row.id) }
        }
        return ids
    }

    /// What the rows would be if the whole reading were taken in, with the exceptions that never
    /// wait for the list to be idle: the row with the cursor keeps its place (T8b), kept rows
    /// stay (T17), and rows in `hold` are not added, or, if already in the list, stay where they
    /// are (T9).
    private func makeCandidate(_ snapshot: MailListSnapshot,
                               _ indexInReading: [MailConversationID: Int],
                               hold: Set<MailConversationID>) -> (rows: [MailRow], cursorHeld: Bool) {
        var frozen: [MailConversationID: MailOrderKey] = [:]
        var cursorHeld = false
        if let id = cursorID, let current = cursorIndex(), let at = indexInReading[id],
           snapshot.rows[at].key != rows[current].key {
            frozen[id] = rows[current].key
            cursorHeld = true
        }
        if !hold.isEmpty {
            for row in rows where hold.contains(row.id) { frozen[row.id] = row.key }
        }

        var base: [MailRow] = []
        base.reserveCapacity(snapshot.rows.count)
        for row in snapshot.rows where frozen[row.id] == nil && !hold.contains(row.id) {
            base.append(row)
        }

        var extras: [MailRow] = []
        for (id, key) in frozen {
            guard let at = indexInReading[id] else { continue }
            var row = snapshot.rows[at]
            row.key = key
            extras.append(row)
        }
        if !kept.isEmpty {
            for row in rows where kept[row.id] != nil && indexInReading[row.id] == nil {
                extras.append(row)
            }
        }
        guard !extras.isEmpty else { return (base, cursorHeld) }
        extras.sort { $0.key > $1.key }
        return (Self.merged(base, extras), cursorHeld)
    }

    /// `extras`, sorted, placed among `base` by key. Neither is sorted here: both arrive in order.
    private static func merged(_ base: [MailRow], _ extras: [MailRow]) -> [MailRow] {
        var out: [MailRow] = []
        out.reserveCapacity(base.count + extras.count)
        var next = 0
        for row in base {
            while next < extras.count, extras[next].key > row.key {
                out.append(extras[next])
                next += 1
            }
            out.append(row)
        }
        out.append(contentsOf: extras[next...])
        return out
    }

    private func setArrivals(_ count: Int) {
        if arrivals != count {
            arrivals = count
            dirty = true
        }
    }

    // MARK: Idle and the first row (T7, T9)

    private func becameIdle() {
        isIdle = true
        awaitingCheck = false
        if let pending { merge(pending, structure: true, top: firstRowIsOnScreen) }
    }

    private func firstRowOnScreenChanged(_ on: Bool) {
        firstRowIsOnScreen = on
        if on, isIdle, let pending { merge(pending, structure: true, top: true) }
    }

    /// The chip, or ⌘↑: what waits above the first row joins.
    private func chipUsed(_ fx: inout [MailListEffect]) {
        if let pending { merge(pending, structure: true, top: true) }
        fx.append(.scrollToTop)
    }

    /// A conversation has been opened over the list: nothing can move under a hand that cannot
    /// reach it, so what was waiting is taken in (T7).
    private func takeInWhatWaited() {
        if let pending { merge(pending, structure: true, top: firstRowIsOnScreen) }
    }

    // MARK: - Where the cursor is

    private func indexOf(_ id: MailConversationID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    /// A row found by its key: O(log n), for the places that must cost nothing on a held key.
    private func indexByKey(_ key: MailOrderKey) -> Int? {
        let older = firstIndexOlder(than: key)
        return older > 0 && rows[older - 1].key == key ? older - 1 : nil
    }

    private func cursorIndex() -> Int? {
        guard let id = cursorID else { return nil }
        if let cached = cursorIndexCache, cached < rows.count, rows[cached].id == id { return cached }
        guard let found = indexOf(id) else { return nil }
        cursorIndexCache = found
        return found
    }

    private func refreshCursorKey() {
        if let index = cursorIndex() { cursorKey = rows[index].key }
    }

    /// Puts the cursor on a row, or on none. Publishes a mark change and nothing else. With
    /// `keepingPlace` the cursor's place is remembered though it has no row: where it was is
    /// what the nearest row is chosen by (T2).
    private func moveCursor(to id: MailConversationID?, at index: Int? = nil, keepingPlace: Bool = false) {
        let old = cursorID
        cursorID = id
        if let id {
            let found = index ?? indexOf(id)
            cursorIndexCache = found
            if let found { cursorKey = rows[found].key }
        } else {
            if !keepingPlace { cursorKey = nil }
            cursorIndexCache = nil
        }
        if old != id { marks.send(.cursor(from: old, to: id)) }
    }

    /// After rows have been added, removed or moved: the cursor has to be somewhere sensible,
    /// and a selection can only hold rows that are there.
    private func rowsLeft() {
        if let id = cursorID {
            if let index = indexOf(id) {
                cursorIndexCache = index
                cursorKey = rows[index].key
            } else if open?.id == id {
                // The open conversation left the list. It stays open and the cursor keeps its
                // place; the next step, close or action is worked out against the list as it
                // is (T13).
            } else if let place = cursorKey {
                // T8a: its successor, with no targets.
                moveCursor(to: successor(of: place, presentAt: nil, excluding: [])?.id)
            } else {
                moveCursor(to: nil)
            }
        }
        // T2: a list with a conversation has a cursor.
        if cursorID == nil, open == nil, let first = rows.first { moveCursor(to: first.id, at: 0) }

        pruneSelection()
        pruneKept()
    }

    /// A row that is no longer in the list is no longer kept in it.
    private func pruneKept() {
        guard !kept.isEmpty else { return }
        let present = Set(rows.lazy.map(\.id))
        for id in Array(kept.keys) where !present.contains(id) { kept[id] = nil }
    }

    /// A selection made row by row holds only rows that are in the list: one that has left is
    /// dropped from it, whoever took it away (T24).
    private func pruneSelection() {
        if !selectionBase.isEmpty {
            let present = Set(rows.lazy.map(\.id))
            let gone = selectionBase.subtracting(present)
            if !gone.isEmpty {
                selectionBase.subtract(gone)
                marks.send(.selection(added: [], removed: gone))
            }
        }
        if let anchor = runAnchor, indexOf(anchor) == nil {
            runAnchor = nil
            runAnchorKey = nil
        }
    }

    // MARK: Order, by key (T1, T6)

    /// The first index whose row is older than `key`.
    private func firstIndexOlder(than key: MailOrderKey) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].key < key { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// The row next to a place in one direction: the next older or newer conversation, by key.
    private func neighbour(of place: MailOrderKey?, in direction: MailDirection) -> Int? {
        guard let place else { return nil }
        let index: Int
        if let current = cursorIndex(), rows[current].key == place {
            index = direction == .older ? current + 1 : current - 1
        } else {
            let older = firstIndexOlder(than: place)
            index = direction == .older ? older : older - 1
        }
        return rows.indices.contains(index) ? index : nil
    }

    private struct Successor {
        var id: MailConversationID
        /// It lies in the direction of travel (the first choice of T6), not the other way.
        var inTravelDirection: Bool
    }

    /// T6. The nearest conversation at or beyond a place in the direction of travel that is in
    /// the list and is not a target; failing that, the nearest the other way; failing that,
    /// none. `presentAt` is the place's row when it is still in the list.
    private func successor(of place: MailOrderKey, presentAt: Int?,
                           excluding targets: Set<MailConversationID>) -> Successor? {
        let olderFrom: Int
        let newerFrom: Int
        if let presentAt {
            olderFrom = presentAt
            newerFrom = presentAt
        } else {
            olderFrom = firstIndexOlder(than: place)
            newerFrom = olderFrom - 1
        }
        func nearest(older: Bool) -> Int? {
            if older {
                var index = olderFrom
                while index < rows.count {
                    if !targets.contains(rows[index].id) { return index }
                    index += 1
                }
            } else {
                var index = newerFrom
                while index >= 0 {
                    if !targets.contains(rows[index].id) { return index }
                    index -= 1
                }
            }
            return nil
        }
        if let index = nearest(older: direction == .older) {
            return Successor(id: rows[index].id, inTravelDirection: true)
        }
        if let index = nearest(older: direction != .older) {
            return Successor(id: rows[index].id, inTravelDirection: false)
        }
        return nil
    }

    // MARK: - Moving (T4, T5)

    private func move(_ direction: MailDirection, _ fx: inout [MailListEffect]) {
        if open != nil { return step(direction, &fx) }
        guard let current = cursorIndex() else { return }
        let target = direction == .older ? current + 1 : current - 1
        // At either end nothing happens: no wrap, no beep.
        guard rows.indices.contains(target) else { return }
        self.direction = direction
        moveCursor(to: rows[target].id, at: target)
        fx.append(.reveal(rows[target].id, beyond: direction))
    }

    /// The keys that move the cursor about the list act in the list only (K3): with a conversation
    /// open the cursor is that conversation (section 0), and they do nothing.
    private func jumpToOldest(_ fx: inout [MailListEffect]) {
        guard open == nil, let last = rows.last else { return }
        direction = .older
        moveCursor(to: last.id, at: rows.count - 1)
        fx.append(.reveal(last.id, beyond: nil))
    }

    /// ⌘↑: the top, what waits above it, and the cursor on the first row (T9).
    private func jumpToNewest(_ fx: inout [MailListEffect]) {
        guard open == nil else { return }
        if let pending { merge(pending, structure: true, top: true) }
        direction = .older
        if let first = rows.first { moveCursor(to: first.id, at: 0) }
        fx.append(.scrollToTop)
    }

    private func pagedTo(_ visible: MailVisibleRows) {
        guard open == nil, let firstIndex = indexOf(visible.first), let lastIndex = indexOf(visible.last),
              let current = cursorIndex(), current < firstIndex || current > lastIndex
        else { return }
        moveCursor(to: visible.first, at: firstIndex)
    }

    private func place(_ id: MailConversationID) {
        guard open == nil, let index = indexOf(id) else { return }
        moveCursor(to: id, at: index)
    }

    // MARK: - Opening and closing (T10 to T13, T38)

    private func openConversation(_ id: MailConversationID?, composer: MailComposerStart?,
                                  _ fx: inout [MailListEffect]) {
        guard let target = id ?? cursorID, let index = indexOf(target) else { return }
        if cursorID != target { moveCursor(to: target, at: index) }
        open = MailOpenConversation(id: target, facts: .fresh)
        openSubject = rows[index].subject
        fx.append(.open(target, composer: composer, at: nil))
        if rows[index].isUnread { fx.append(.markReadAfter(target, delay: Self.readDelay)) }
        takeInWhatWaited()
    }

    /// `R` or `F` in the list. With a selection they do nothing (T15).
    private func openAndReply(_ start: MailComposerStart, _ fx: inout [MailListEffect]) {
        guard open == nil, selection.isEmpty else { return }
        openConversation(nil, composer: start, &fx)
    }

    private func closeConversation(_ fx: inout [MailListEffect]) {
        guard open != nil else { return }
        open = nil
        openSubject = nil
        fx.append(.close)
        // The cursor is on that conversation if it is still in the list, otherwise on its
        // successor (T11); and the list is where it was (T46).
        if cursorIndex() == nil, let place = cursorKey {
            moveCursor(to: successor(of: place, presentAt: nil, excluding: [])?.id)
        }
        if let viewport { fx.append(.restoreViewport(resolved(viewport))) }
        if let id = cursorID { fx.append(.reveal(id, beyond: nil)) }
    }

    /// J or K with a conversation open: the next older or newer one opens in its place (T12).
    private func step(_ direction: MailDirection, _ fx: inout [MailListEffect]) {
        guard open != nil, let index = neighbour(of: cursorKey, in: direction) else { return }
        self.direction = direction
        let id = rows[index].id
        moveCursor(to: id, at: index)
        open = MailOpenConversation(id: id, facts: .fresh)
        openSubject = rows[index].subject
        fx.append(.open(id, composer: nil, at: nil))
        if rows[index].isUnread { fx.append(.markReadAfter(id, delay: Self.readDelay)) }
        fx.append(.reveal(id, beyond: direction))
        takeInWhatWaited()
    }

    /// What the reader says. A message that was below the fold and has now been on screen is
    /// marked read in its turn, after its own 400 ms (T10).
    private func readerSaid(_ facts: MailReaderFacts, _ fx: inout [MailListEffect]) {
        guard let current = open else { return }
        open?.facts = facts
        if current.facts.hasUnseen, !facts.hasUnseen, let index = indexOf(current.id),
           rows[index].isUnread {
            fx.append(.markReadAfter(current.id, delay: Self.readDelay))
        }
    }

    /// A conversation passed through with J or K sooner than 400 ms is not marked read; one that
    /// is still open when the timer runs out is, and that is not an undo step (T10). A message
    /// that has not been on screen is not read by it (T45): the change is as of the ones that
    /// have been.
    private func readDelayElapsed(_ id: MailConversationID, _ fx: inout [MailListEffect]) {
        guard let open, open.id == id, let index = indexOf(id), rows[index].isUnread else { return }
        let change = MailChange.read(true)
        var target = MailTarget.asShown([rows[index]])
        if open.facts.hasUnseen, let seen = open.facts.newestSeen {
            target = .message(seen)
        } else {
            applyToRows(change, ids: [id], disposing: false)
        }
        let token = nextToken
        nextToken += 1
        inFlight[token] = InFlight(entry: nil, action: nil, change: change)
        fx.append(.perform(MailPerformRequest(token: token, action: nil, change: change,
                                              target: target, isUndoable: false)))
    }

    // MARK: - Entering and leaving a place (T3, T17, T23)

    /// Entering is a key press or a touch, so the list is not idle: what arrives in the next
    /// three seconds waits, and what was waiting joins now, because the person is looking at
    /// the list as it is shown to him and not at one he has been moving through (T7, T9).
    private func enter(_ fx: inout [MailListEffect]) {
        let returning = visited
        visited = true
        direction = .older
        dropKeptRows()
        if let pending { merge(pending, structure: true, top: viewportIsAtTop) }
        if returning {
            if let viewport {
                fx.append(.restoreViewport(resolved(viewport)))
            } else if let id = cursorID, cursorIndex() != nil {
                fx.append(.reveal(id, beyond: nil))
            }
        } else if cursorWasCarried {
            // T32: the cursor came with the filter, and may be anywhere in the list.
            if let id = cursorID, cursorIndex() != nil { fx.append(.reveal(id, beyond: nil)) }
        } else {
            if let first = rows.first { moveCursor(to: first.id, at: 0) }
            // A cold launch brings a stored position, as a key and points (T46); otherwise the top.
            if let viewport { fx.append(.restoreViewport(resolved(viewport))) } else { fx.append(.scrollToTop) }
        }
    }

    private var viewportIsAtTop: Bool {
        guard let viewport, let first = rows.first else { return true }
        return viewport.firstRow == first.id || viewport.key >= first.key
    }

    /// A position the list has: the row itself, or if it has left, the first row at or after its
    /// key, from the top of it (T3, T26, P-7).
    private func resolved(_ viewport: MailViewport) -> MailViewport {
        if let index = indexByKey(viewport.key), rows[index].id == viewport.firstRow { return viewport }
        if let index = indexOf(viewport.firstRow) {
            return MailViewport(firstRow: viewport.firstRow, key: rows[index].key, offset: viewport.offset)
        }
        guard !rows.isEmpty else { return viewport }
        let row = rows[min(firstIndexOlder(than: viewport.key), rows.count - 1)]
        return MailViewport(firstRow: row.id, key: row.key, offset: 0)
    }

    private func leave() {
        changeSelection {
            selectionBase = []
            scopeSelection = nil
            runAnchor = nil
            runAnchorKey = nil
        }
    }

    /// ⌘R and a pull: the rows that were being kept go, what was waiting joins, and what the
    /// check finds is taken in at once until the next rest: he asked for it.
    private func refresh(_ fx: inout [MailListEffect]) {
        awaitingCheck = true
        dropKeptRows()
        if let pending { merge(pending, structure: true, top: firstRowIsOnScreen) }
        fx.append(.checkNow)
    }

    private func dropKeptRows() {
        guard !kept.isEmpty else { return }
        endRun()
        let before = rows.count
        rows.removeAll { kept[$0.id] != nil }
        kept = [:]
        if rows.count != before {
            dirty = true
            rowsLeft()
        }
    }

    // MARK: - Selection (T20 to T24)

    private func selectedRowIDs() -> Set<MailConversationID> {
        var ids = selectionBase
        if let range = runRange() { ids.formUnion(range) }
        return ids
    }

    /// The anchor's row: found by its key, so a held `⇧J` does not scan the list.
    private func runAnchorIndex() -> Int? {
        guard let anchor = runAnchor else { return nil }
        if let key = runAnchorKey, let index = indexByKey(key), rows[index].id == anchor { return index }
        return indexOf(anchor)
    }

    /// Every conversation from the anchor to the cursor, whichever way round.
    private func runRange() -> [MailConversationID]? {
        guard let from = runAnchorIndex() else { return nil }
        let to = cursorIndex() ?? from
        return rows[min(from, to)...max(from, to)].map(\.id)
    }

    /// Any other key ends the run: its rows stay selected (T21). So does anything that adds
    /// rows to the list or takes them away while a run is live: the run is what was selected,
    /// and is not to change with the rows (T24).
    private func endRun() {
        guard runAnchor != nil else { return }
        if let range = runRange() { selectionBase.formUnion(range) }
        runAnchor = nil
        runAnchorKey = nil
    }

    private func changeSelection(_ body: () -> Void) {
        let before = selectedIDs
        body()
        let after = selectedIDs
        if before != after {
            marks.send(.selection(added: after.subtracting(before), removed: before.subtracting(after)))
        }
    }

    /// `X`: adds the conversation to the selection or takes it off; the cursor does not move.
    /// A selection by scope is all or nothing, so `X` inside it does nothing (T22).
    private func toggleSelected(_ id: MailConversationID?) {
        guard scopeSelection == nil, let target = id ?? cursor, indexOf(target) != nil else { return }
        if selectionBase.remove(target) != nil {
            marks.send(.selection(added: [], removed: [target]))
        } else {
            selectionBase.insert(target)
            marks.send(.selection(added: [target], removed: []))
        }
    }

    /// `⇧J` and `⇧K`. The first after any other key sets the anchor at the cursor and, like
    /// each further one, moves the cursor a row; the run is every conversation from the anchor
    /// to the cursor, so reversing shrinks it (T21). It touches only the rows the run gained or
    /// lost, so it costs nothing when it repeats.
    private func extendSelection(_ direction: MailDirection, _ fx: inout [MailListEffect]) {
        guard open == nil, scopeSelection == nil, let current = cursorIndex() else { return }
        let hadARun = runAnchor != nil
        if !hadARun {
            runAnchor = rows[current].id
            runAnchorKey = rows[current].key
        }
        guard let anchor = runAnchorIndex() else { return }
        let before: ClosedRange<Int>? = hadARun ? min(anchor, current)...max(anchor, current) : nil

        var now = current
        let target = direction == .older ? current + 1 : current - 1
        if rows.indices.contains(target) {
            self.direction = direction
            moveCursor(to: rows[target].id, at: target)
            fx.append(.reveal(rows[target].id, beyond: direction))
            now = target
        }
        let after = min(anchor, now)...max(anchor, now)

        var added = Set<MailConversationID>()
        var removed = Set<MailConversationID>()
        for index in after where !(before?.contains(index) ?? false) {
            if !selectionBase.contains(rows[index].id) { added.insert(rows[index].id) }
        }
        if let before {
            for index in before where !after.contains(index) {
                if !selectionBase.contains(rows[index].id) { removed.insert(rows[index].id) }
            }
        }
        if !added.isEmpty || !removed.isEmpty { marks.send(.selection(added: added, removed: removed)) }
    }

    /// ⌘A from the cursor down, ⌘⇧A the whole list: the list as it stood when the key was
    /// pressed, by the key of its first selected row (T22). What waits above the first row is
    /// not in it, and is not counted.
    private func selectByScope(fromCursor: Bool) {
        let start: Int
        if fromCursor {
            guard let current = cursorIndex() else { return }
            start = current
        } else {
            guard !rows.isEmpty else { return }
            start = 0
        }
        let key = rows[start].key
        let known = max(meta.total.value - arrivals, rows.count) - start
        changeSelection {
            selectionBase = []
            runAnchor = nil
            runAnchorKey = nil
            scopeSelection = (key, MailCount(value: max(known, rows.count - start),
                                             isAtLeast: meta.total.isAtLeast))
        }
    }

    private func clearSelection() {
        changeSelection {
            selectionBase = []
            runAnchor = nil
            runAnchorKey = nil
            scopeSelection = nil
        }
    }

    /// `Esc` goes back one level: the open conversation, then the selection, then search, then
    /// filters, then nothing (K9).
    private func back(_ fx: inout [MailListEffect]) {
        if open != nil {
            closeConversation(&fx)
        } else if !selection.isEmpty {
            clearSelection()
        } else if case .search = scope.place {
            fx.append(.leaveSearch)
        } else if !scope.filters.isEmpty {
            fx.append(.clearFilters)
        }
    }

    // MARK: - Actions (T0, T14 to T18, T45)

    /// What an action acts on (T15).
    private struct Resolved {
        var target: MailTarget
        var ids: Set<MailConversationID>
        var rows: [MailRow]
        var count: Int
        var subjects: [String]
        var fromSelection = false
        /// As of the messages that have been on screen (T45).
        var viaMessage = false
        var isTheOpenConversation = false
        /// A selection by scope: rows that are not loaded are in it, so "nothing would change"
        /// cannot be decided from the ones that are.
        var isAScope = false
    }

    /// Capability checks use the same resolution as the action, before optimistic changes.
    func actionTarget(for action: MailAction, explicit: MailConversationID?) -> MailTarget? {
        resolveTarget(for: action, explicit: explicit)?.target
    }

    private func resolveTarget(for action: MailAction, explicit: MailConversationID?) -> Resolved? {
        if let id = explicit {
            // The row may have left the list since the picker was opened for it: the change is
            // still the one he asked for.
            let row = indexOf(id).map { [rows[$0]] } ?? []
            return Resolved(target: row.isEmpty ? .conversations([id]) : .asShown(row), ids: [id], rows: row, count: 1,
                            subjects: row.map(\.subject))
        }
        if let open {
            let row = indexOf(open.id).map { [rows[$0]] } ?? []
            let subjects = row.isEmpty ? (openSubject.map { [$0] } ?? []) : row.map(\.subject)
            let actsOnWhatWasSeen = action.kind == .disposing || action == .toggleRead
            if open.facts.hasUnseen, actsOnWhatWasSeen, let message = open.facts.newestSeen {
                return Resolved(target: .message(message), ids: [open.id], rows: row, count: 1,
                                subjects: subjects, viaMessage: true, isTheOpenConversation: true)
            }
            return Resolved(target: row.isEmpty ? .conversations([open.id]) : .asShown(row), ids: [open.id], rows: row, count: 1,
                            subjects: subjects, isTheOpenConversation: true)
        }
        if let scopeSelection {
            var targets = rows.filter { $0.key <= scopeSelection.from }
            if let waiting = pending {
                // A row held where it was is placed by an old key: the source's decides whether
                // it is in the selection, and a row that has since moved above it is not (T45).
                var readingKeys: [MailConversationID: MailOrderKey] = [:]
                for row in waiting.rows where readingKeys[row.id] == nil { readingKeys[row.id] = row.key }
                targets = targets.filter { (readingKeys[$0.id] ?? $0.key) <= scopeSelection.from }
            }
            return Resolved(target: .scope(scope, from: scopeSelection.from),
                            ids: Set(targets.map(\.id)), rows: targets,
                            count: scopeSelection.count.value, subjects: targets.prefix(1).map(\.subject),
                            fromSelection: true, isAScope: true)
        }
        let selected = selectedRowIDs()
        if !selected.isEmpty {
            let targets = rows.filter { selected.contains($0.id) }
            guard !targets.isEmpty else { return nil }
            return Resolved(target: .asShown(targets), ids: selected, rows: targets,
                            count: targets.count, subjects: targets.prefix(1).map(\.subject),
                            fromSelection: true)
        }
        guard let id = cursorID, let index = indexOf(id) else { return nil }
        return Resolved(target: .asShown([rows[index]]), ids: [id], rows: [rows[index]], count: 1,
                        subjects: [rows[index].subject])
    }

    /// One action. Everything the screen shows changes in this turn: the rows, the cursor, the
    /// selection, the open conversation. What the source is to do is an effect; what Undo will
    /// restore is the entry that comes back with the receipt (T0).
    private func act(_ action: MailAction, on explicit: MailConversationID?,
                     _ fx: inout [MailListEffect]) {
        guard action.isDecidedByTheModel,
              let resolved = resolveTarget(for: action, explicit: explicit),
              var change = action.change(for: resolved.rows, in: scope)
        else { return }

        // `U` in an open conversation always means "leave it unread and go back", whatever the
        // toggle would say of a row that is unread because he has only just opened it (T17).
        if action == .toggleRead, resolved.isTheOpenConversation {
            if !resolved.viaMessage, resolved.rows.first?.isUnread == true {
                open = nil
                openSubject = nil
                fx.append(.close)
                if let id = cursorID { fx.append(.reveal(id, beyond: nil)) }
                return
            }
            change = .read(false)
        }

        let disposing = action.kind == .disposing
        let changesNothing = !resolved.isAScope && !resolved.rows.isEmpty
            && resolved.rows.allSatisfy { action.wouldChangeNothing(on: $0, in: scope) }
        if changesNothing {
            // T16: nothing is sent, no toast, no undo entry — and the cursor still advances.
            if disposing { settle(excluding: resolved.ids, &fx) }
            return
        }

        // T25: what was showing, before anything below changes it.
        let before = MailUndoEntry(
            kind: .change(action, change), receipt: MailReceipt(sequence: 0, count: nil),
            description: MailToastText.description(for: action, change: change,
                                                   count: resolved.count),
            subjects: resolved.subjects, count: resolved.count, scope: scope,
            cursor: cursorID, cursorKey: cursorKey, direction: direction, selection: selection,
            open: open, viewport: viewport, rowsBefore: resolved.rows)

        // 1. Apply, in what the screen shows. A message-level target leaves the conversation
        //    where it is: the reading brings back what stayed (T45).
        if !resolved.viaMessage {
            applyToRows(change, ids: resolved.ids, disposing: disposing)
        }

        if disposing {
            // 2. The selection is cleared, when it was the target.
            if resolved.fromSelection { clearSelection() }
            // 3 and 4. The cursor advances; a conversation that was open follows it.
            settle(excluding: resolved.ids, &fx)
        } else if resolved.isTheOpenConversation, case .read(false) = change {
            // T17's one exception: staying would be reading it.
            open = nil
            openSubject = nil
            fx.append(.close)
            if let id = cursorID { fx.append(.reveal(id, beyond: nil)) }
        }

        // 5. Remember it, and ask the source. Send and Done is the composer's send, which carries
        //    the Done: the screen moves, and the composer is handed what was showing, to put on
        //    the stack with its receipt as the one entry (T38).
        guard action != .sendAndDone else {
            fx.append(.settled(before))
            return
        }
        let token = nextToken
        nextToken += 1
        inFlight[token] = InFlight(entry: action.isUndoable ? before : nil, action: action,
                                   change: change, viaMessage: resolved.viaMessage)
        fx.insert(.perform(MailPerformRequest(token: token, action: action, change: change,
                                              target: resolved.target,
                                              isUndoable: action.isUndoable)), at: 0)
    }

    /// Edits the rows through `MailRowRules`, in the turn of the action: a row that no longer
    /// belongs leaves (a disposing action) or is kept dimmed (a marking one, T17); one that
    /// cannot be told is drawn as changed and left to the next reading (T16).
    private func applyToRows(_ change: MailChange, ids: Set<MailConversationID>, disposing: Bool) {
        var out: [MailRow] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard ids.contains(row.id) else {
                out.append(row)
                continue
            }
            switch MailRowRules.apply(change, to: row, in: scope) {
            case .stays(let changed):
                out.append(changed)
                if !disposing { kept[row.id] = false }
            case .leaves(let changed):
                if disposing {
                    unresolved.remove(row.id)
                } else {
                    // Kept, and drawn like any other until a reading omits it (T17).
                    out.append(changed)
                    kept[row.id] = false
                }
            case .unknown(let changed):
                out.append(changed)
                if disposing { unresolved.insert(row.id) } else { kept[row.id] = false }
            }
        }
        let removed = out.count != rows.count
        if removed { endRun() }
        let goneCount = rows.count - out.count
        rows = out
        dirty = true
        if removed {
            pruneSelection()
            pruneKept()
            // The reading that follows will say how many are left. It says what the model has
            // already worked out, so the action is one publication and the reading none (G4).
            meta.total.value = max(0, meta.total.value - goneCount)
        }

        // The reading that is waiting for its turn is older than this action.
        if var waiting = pending {
            waiting.rows = waiting.rows.compactMap { row in
                guard ids.contains(row.id) else { return row }
                switch MailRowRules.apply(change, to: row, in: scope) {
                case .stays(let changed), .unknown(let changed): return changed
                case .leaves: return nil
                }
            }
            pending = waiting
        }
    }

    /// T16, steps 3 and 4: the cursor moves to the successor of its place with the targets as
    /// targets — so it advances even when its row stays — and a conversation that was open
    /// follows it when it lies in the direction of travel, otherwise the view returns to the
    /// list.
    private func settle(excluding targets: Set<MailConversationID>, _ fx: inout [MailListEffect]) {
        let wasOpen = open != nil
        guard let place = cursorKey else {
            if wasOpen {
                open = nil
                openSubject = nil
                fx.append(.close)
            }
            return
        }
        if let next = successor(of: place, presentAt: cursorIndex(), excluding: targets) {
            moveCursor(to: next.id)
            if wasOpen {
                if next.inTravelDirection, let index = indexOf(next.id) {
                    open = MailOpenConversation(id: next.id, facts: .fresh)
                    openSubject = rows[index].subject
                    fx.append(.open(next.id, composer: nil, at: nil))
                    if rows[index].isUnread { fx.append(.markReadAfter(next.id, delay: Self.readDelay)) }
                    takeInWhatWaited()
                } else {
                    open = nil
                    openSubject = nil
                    fx.append(.close)
                }
            }
            fx.append(.reveal(next.id, beyond: direction))
        } else {
            // Every conversation was a target. The cursor stays where it is if its row is still
            // in the list; otherwise it has no row, and T2 gives it the nearest one to its place
            // when there is one (T6, T2).
            if cursorIndex() == nil { moveCursor(to: nil, keepingPlace: true) }
            if wasOpen {
                open = nil
                openSubject = nil
                fx.append(.close)
            }
        }
    }

    /// The source's receipt. A count of zero, or no sequence, is a change that did nothing: the
    /// screen has already moved, and shows nothing and offers no undo. A receipt raises what the
    /// model knows the source has applied, so that a reading older than the command cannot
    /// resolve a row against a world without it.
    private func performed(_ token: UInt64, _ receipt: MailReceipt, _ fx: inout [MailListEffect]) {
        appliedThrough = max(appliedThrough, receipt.sequence)
        guard let flight = inFlight.removeValue(forKey: token), var entry = flight.entry,
              let action = flight.action, receipt.sequence != 0, receipt.count != 0
        else { return }
        entry.receipt = receipt
        if let count = receipt.count {
            entry.count = count
            entry.description = MailToastText.description(for: action, change: flight.change,
                                                          count: count)
        }
        fx.append(.pushUndo(entry))
        var time: String?
        if case .snooze(let until, _) = action { time = timePhrase(until) }
        if let toast = MailToastText.toast(for: action, change: flight.change,
                                           subjects: entry.subjects, count: entry.count ?? 1,
                                           time: time, keepsInInbox: flight.viaMessage) {
            fx.append(.toast(toast))
        }
    }

    // MARK: - Undo (T26) and a change that cannot stand (T36)

    /// Puts the screen back as the entry recorded it: the rows where they were, the cursor, the
    /// selection, the open conversation and the scroll. Undo is the person's own action, so none
    /// of it waits for the list to be idle (T7), and none of it waits for a reading.
    ///
    /// Give the model `restore` after `undo` has returned, with the receipt's sequence. Every
    /// row of the entry is put back at once and left for the next reading to settle, which takes
    /// away the ones the source no longer has (T30). When the reading that carries the undo has
    /// already arrived it says which those are, and they are not put back; a reading older than
    /// the undo is refused from here on, so it cannot take the rows away again.
    private func restore(_ entry: MailUndoEntry, through: UInt64, _ fx: inout [MailListEffect]) {
        var existing: Set<MailConversationID>?
        if let latest, through > 0, latest.appliedThrough >= through {
            existing = Set(latest.rows.lazy.map(\.id))
        }
        appliedThrough = max(appliedThrough, through)
        putBack(entry.rowsBefore.filter { existing?.contains($0.id) ?? true }, reason: nil)
        direction = entry.direction

        if let id = entry.cursor, let index = indexOf(id) {
            moveCursor(to: id, at: index)
        } else if let place = entry.cursorKey {
            moveCursor(to: successor(of: place, presentAt: nil, excluding: [])?.id)
        }

        changeSelection {
            selectionBase = []
            runAnchor = nil
            runAnchorKey = nil
            scopeSelection = nil
            switch entry.selection {
            case .none: break
            case .rows(let ids): selectionBase = ids.intersection(rows.lazy.map(\.id))
            case .scope(_, let key, let count): scopeSelection = (key, count)
            }
        }

        if let reading = entry.open {
            open = reading
            openSubject = entry.subjects.first
            if let index = indexOf(reading.id) {
                moveCursor(to: reading.id, at: index)
                if rows[index].isUnread { fx.append(.markReadAfter(reading.id, delay: Self.readDelay)) }
            } else {
                // Open again, though the list no longer has it: the cursor keeps its place (T13).
                if cursorID != nil { marks.send(.cursor(from: cursorID, to: nil)) }
                cursorID = reading.id
                cursorKey = entry.cursorKey ?? cursorKey
                cursorIndexCache = nil
            }
            fx.append(.open(reading.id, composer: nil, at: reading.facts))
            takeInWhatWaited()
        } else if open != nil {
            // A conversation was opened since: the screen is the list's again, with the cursor
            // as recorded, and not a conversation it has moved away from.
            open = nil
            openSubject = nil
            fx.append(.close)
        }
        if let viewport = entry.viewport { fx.append(.restoreViewport(resolved(viewport))) }
        if let id = cursorID, cursorIndex() != nil { fx.append(.reveal(id, beyond: nil)) }
    }

    /// T36: the conversations are shown as Gmail has them, back where the order puts them, at
    /// once — this is the answer to his own action — and, for a refusal, with the reason on the
    /// row. The cursor, the selection and the scroll are left where they are.
    private func reverted(_ entry: MailUndoEntry, _ why: MailReversal, _ fx: inout [MailListEffect]) {
        var reason: MailRowReason?
        if case .refused(let failure) = why { reason = .changeRefused(failure) }
        putBack(entry.rowsBefore, reason: reason)

        switch (why, entry.kind) {
        case (.refused(let failure), .change(let action, let change)):
            fx.append(.toast(MailToastText.refused(action, change: change, subjects: entry.subjects,
                                                   count: entry.count ?? entry.rowsBefore.count,
                                                   failure: failure)))
        case (.notSaved(let problem), _):
            fx.append(.toast(MailToastText.notSaved(on: deviceName, problem: problem)))
        default:
            break
        }
    }

    /// Rows come back to their places by key; ones already there are replaced by what they were.
    /// Either way the next reading has the last word on whether they belong.
    private func putBack(_ before: [MailRow], reason: MailRowReason?) {
        guard !before.isEmpty else { return }
        endRun()
        for original in before {
            var row = original
            if let reason { row.reason = reason }
            if let index = indexOf(row.id) {
                row.key = rows[index].key
                rows[index] = row
            } else {
                rows.insert(row, at: firstIndexOlder(than: row.key))
            }
            kept[row.id] = nil
            unresolved.insert(row.id)
        }
        dirty = true
        if var waiting = pending {
            for original in before where !waiting.rows.contains(where: { $0.id == original.id }) {
                waiting.rows.insert(original, at: waiting.rows.firstIndex { $0.key < original.key }
                    ?? waiting.rows.count)
            }
            pending = waiting
        }
        rowsLeft()
    }

    // MARK: - Asking for more (6.1.7)

    /// The model asks for a step more rows when the cursor, or the first row on screen, comes
    /// within `growMargin` rows of the last one it has, up to the cap — and only once the reading
    /// for the limit it last asked for has arrived, so one step is asked for once. That is the
    /// reading's count, not the rows shown: a row held back in the chip is in the reading and
    /// not on screen (MAIL-UX 6.1.7). The first row on screen is found
    /// by its key: this runs on every input, and a held `J` must not scan the list.
    private func growIfNeeded(_ fx: inout [MailListEffect]) {
        guard meta.hasMore, readingCount >= limit, limit < MailTuning.listCap else { return }
        var nearest = cursorIndex()
        if let viewport, let top = indexByKey(viewport.key) { nearest = max(nearest ?? 0, top) }
        guard let nearest, rows.count - nearest <= Self.growMargin else { return }
        limit = min(MailTuning.listCap, limit + MailTuning.listStep)
        fx.append(.growTo(limit: limit))
    }

    // MARK: - Publishing

    private func commit() {
        guard dirty else { return }
        dirty = false
        generation += 1
        list.shown = MailListShown(
            rows: rows, dimmed: Set(kept.filter { $0.value }.map { $0.key }), arrivals: arrivals,
            total: meta.total, hasMore: meta.hasMore, stillLoading: meta.stillLoading,
            isRebuilding: meta.isRebuilding, remote: meta.remote, coverage: meta.coverage,
            hasDelivered: meta.delivered, generation: generation)
    }
}

// MARK: - Choices that are not the model's to keep

extension MailListModel {

    /// T31. The split `Tab` shows next, and `⇧Tab` before, wrapping; an empty split is not
    /// skipped. From a place that is not a split, `Tab` shows the first split and `⇧Tab` the
    /// last.
    nonisolated static func splitAfter(_ place: MailPlace, in splits: [MailSplit],
                                       backwards: Bool) -> MailPlace? {
        guard !splits.isEmpty else { return nil }
        if case .split(let id) = place, let index = splits.firstIndex(where: { $0.id == id }) {
            let count = splits.count
            let next = backwards ? (index + count - 1) % count : (index + 1) % count
            return .split(splits[next].id)
        }
        return .split((backwards ? splits.last! : splits.first!).id)
    }

    /// T31. What `Tab` shows: the next split, and nothing else changed. The account and the
    /// filters carry, the header shows them, and `Esc` clears the filters (K9).
    nonisolated static func scopeAfterTab(from scope: MailScope, in splits: [MailSplit],
                                          backwards: Bool) -> MailScope? {
        guard let place = splitAfter(scope.place, in: splits, backwards: backwards) else { return nil }
        var next = scope
        next.place = place
        next.before = nil
        return next
    }

    /// T32 and T34. The scope with a filter turned on or off.
    nonisolated static func scope(toggling filter: MailFilter, in scope: MailScope) -> MailScope {
        var scope = scope
        scope.before = nil
        if scope.filters.contains(filter) { scope.filters.remove(filter) }
        else { scope.filters.insert(filter) }
        return scope
    }

    /// T32. Where the cursor was, to carry into the filtered list's model.
    var cursorHint: MailCursorHint? {
        guard let id = cursorID, let key = cursorKey else { return nil }
        return MailCursorHint(id: id, key: key, direction: direction)
    }
}

#endif
