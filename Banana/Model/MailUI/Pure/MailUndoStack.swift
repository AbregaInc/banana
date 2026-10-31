#if !BANANA_PUBLIC
import Foundation

/// One thing Undo can take back, with everything the screen needs to return to (MAIL-UX T25).
///
/// The engine owns the reverse of a change (the contract's promise 3): `receipt` is what asks it
/// to. The rest is the screen half — which list was showing, where the cursor was, what was
/// selected, which conversation was open and how far it was read, how the list was scrolled —
/// and the rows of the conversations the change touched, as they were, so that they come back to
/// their places in the same turn without waiting for a reading.
struct MailUndoEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A disposing or marking action, with the change it handed to the source.
        case change(MailAction, MailChange)
        /// A send, held until `holdEnds`. For Send and Done, `doneSubject` is the conversation
        /// that was marked Done, which is what "Already sent" says came back.
        case send(MailDraftID, holdEnds: Date, doneSubject: String?)
        /// A discarded draft.
        case discard(MailDraftID)
        /// A schedule that was cancelled or changed: Undo puts the time it had back.
        case schedule(MailDraftID, restoreTo: Date)
    }

    var kind: Kind
    var receipt: MailReceipt
    /// One line, as the stack and More › Undo name it: "Marked Done", "3 marked Done".
    var description: String
    /// The subjects of what it was about, as many as are known, for the words of a refusal.
    var subjects: [String]
    /// Conversations. Nil for a scope the engine has not counted yet.
    var count: Int?
    /// Set by the stack when the entry is pushed.
    var pushedAt: Date

    // What was showing.
    var scope: MailScope
    var cursor: MailConversationID?
    var cursorKey: MailOrderKey?
    var direction: MailDirection
    var selection: MailSelection
    var open: MailOpenConversation?
    var viewport: MailViewport?
    /// The rows of the targets that the screen had, as they were before the change, in the
    /// order of the list.
    var rowsBefore: [MailRow]

    init(kind: Kind, receipt: MailReceipt, description: String, subjects: [String] = [],
         count: Int? = nil, pushedAt: Date = .distantPast, scope: MailScope,
         cursor: MailConversationID? = nil, cursorKey: MailOrderKey? = nil,
         direction: MailDirection = .older, selection: MailSelection = .none,
         open: MailOpenConversation? = nil, viewport: MailViewport? = nil,
         rowsBefore: [MailRow] = []) {
        self.kind = kind
        self.receipt = receipt
        self.description = description
        self.subjects = subjects
        self.count = count
        self.pushedAt = pushedAt
        self.scope = scope
        self.cursor = cursor
        self.cursorKey = cursorKey
        self.direction = direction
        self.selection = selection
        self.open = open
        self.viewport = viewport
        self.rowsBefore = rowsBefore
    }
}

/// What the screen is to do when Undo is asked for.
enum MailUndoStep: Equatable, Sendable {
    /// The stack is empty.
    case nothingToUndo
    /// Call `undo(entry.receipt)` and hand its answer to `outcome(reversing:answer:)`. The entry
    /// has left the stack.
    case reverse(MailUndoEntry)
    /// A send still inside its hold: `await cancelSend(draft)` — a few milliseconds — then
    /// `outcome(cancelling:succeeded:)`. The one undo that waits (T26).
    case cancelSend(MailUndoEntry)
    /// A send whose hold has ended. Nothing is unsent (T28). For a Send and Done the Done is
    /// undone: call `undo(entry.receipt)`, which reverses the Done and no more.
    case alreadySent(MailUndoEntry)
}

enum MailUndoOutcome: Equatable, Sendable {
    case undone(MailToast)
    case cannotBeUndone(MailToast)
    case alreadySent(MailToast)

    var toast: MailToast {
        switch self {
        case .undone(let toast), .cannotBeUndone(let toast), .alreadySent(let toast): return toast
        }
    }
}

/// Mail's undo history: the screen half of undo, T25 to T30.
///
/// It is a value and has no clock and no source: what time it is, and what the source answered,
/// are handed in, so that every rule here is a test that sets two numbers and reads one answer.
/// Which of the toast's Undo and the stack `Z` means (T26) is not decided here — that needs to
/// know what the shared toast is showing, which only the screen does.
///
/// There is no redo (T29): an entry that has been undone is gone, and nothing puts it back.
struct MailUndoStack: Equatable, Sendable {

    /// How many entries are kept: the same fifty the engine can still reverse (T27).
    static let depth = 50

    /// For two minutes after the newest entry the phone's bottom slot shows an Undo button
    /// (T44).
    static let buttonWindow: TimeInterval = 120

    /// Oldest first.
    private(set) var entries: [MailUndoEntry] = []

    init() {}

    var top: MailUndoEntry? { entries.last }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Remembers a change. The oldest entry goes when there are more than `depth` (T27).
    mutating func push(_ entry: MailUndoEntry, at now: Date) {
        var entry = entry
        entry.pushedAt = now
        entries.append(entry)
        if entries.count > Self.depth { entries.removeFirst(entries.count - Self.depth) }
    }

    /// A failed inverse was never saved. Restore the original history position,
    /// behind actions the user made while that inverse was being written.
    mutating func restoreFailedUndo(_ entry: MailUndoEntry) {
        guard !entries.contains(where: { $0.receipt == entry.receipt }) else { return }
        entries.append(entry)
        entries.sort {
            if $0.pushedAt != $1.pushedAt { return $0.pushedAt < $1.pushedAt }
            return $0.receipt.sequence < $1.receipt.sequence
        }
        if entries.count > Self.depth { entries.removeFirst(entries.count - Self.depth) }
    }

    /// Takes an entry out because its change cannot stand (T36): the source refused it for good,
    /// or the device could not save it. There is nothing left to undo.
    @discardableResult
    mutating func remove(receipt: MailReceipt) -> MailUndoEntry? {
        guard let index = entries.lastIndex(where: { $0.receipt == receipt }) else { return nil }
        return entries.remove(at: index)
    }

    /// The count a scope target turned out to have (`MailEvent.applied`). A count of zero means
    /// the change did nothing, so there is nothing to undo: the entry goes, and is returned so
    /// the toast that offered it can be withdrawn. Otherwise the entry is updated and nil is
    /// returned.
    @discardableResult
    mutating func setCount(_ count: Int, for receipt: MailReceipt) -> MailUndoEntry? {
        guard let index = entries.lastIndex(where: { $0.receipt == receipt }) else { return nil }
        if count == 0 { return entries.remove(at: index) }
        entries[index].count = count
        entries[index].description = Self.redescribe(entries[index], count: count)
        return nil
    }

    /// `Z`, with no toast to answer: takes the top entry off and says what to do with it.
    mutating func beginUndo(now: Date) -> MailUndoStep {
        guard let entry = entries.popLast() else { return .nothingToUndo }
        guard case .send(_, let holdEnds, _) = entry.kind else { return .reverse(entry) }
        // The hold is the engine's, and so is the last word: if it had already left when the
        // press arrives, `cancelSend` answers false and `outcome(cancelling:)` says so too.
        return now >= holdEnds ? .alreadySent(entry) : .cancelSend(entry)
    }

    /// The source answered `undo`. A count of zero is every target gone, or a change the engine
    /// can no longer reverse — one line for both (T30). A receipt of no sequence is the source's
    /// default for a member nobody has built, and is the same answer.
    func outcome(reversing entry: MailUndoEntry, answer: MailReceipt) -> MailUndoOutcome {
        if answer.sequence == 0 || answer.count == 0 {
            return .cannotBeUndone(MailToastText.cannotBeUndone)
        }
        return .undone(MailToastText.undone(previous: top?.description))
    }

    /// `cancelSend` answered. False: the message had left, whatever the clock said.
    func outcome(cancelling entry: MailUndoEntry, succeeded: Bool) -> MailUndoOutcome {
        guard succeeded else { return outcome(forAlreadySent: entry) }
        return .undone(MailToastText.undone(previous: top?.description))
    }

    /// The toast after `.alreadySent`.
    func outcome(forAlreadySent entry: MailUndoEntry) -> MailUndoOutcome {
        if case .send(_, _, let doneSubject) = entry.kind {
            return .alreadySent(MailToastText.alreadySent(backInInbox: doneSubject))
        }
        return .alreadySent(MailToastText.alreadySent())
    }

    /// Whether the phone's bottom slot shows an Undo button now (T44).
    func showsUndoButton(now: Date) -> Bool {
        guard let newest = entries.last else { return false }
        return now.timeIntervalSince(newest.pushedAt) <= Self.buttonWindow
    }

    private static func redescribe(_ entry: MailUndoEntry, count: Int) -> String {
        guard case .change(let action, let change) = entry.kind else { return entry.description }
        return MailToastText.description(for: action, change: change, count: count)
    }
}

#endif
