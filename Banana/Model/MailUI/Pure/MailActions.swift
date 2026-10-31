#if !BANANA_PUBLIC
import Foundation

/// What an action means for the cursor (MAIL-UX T14).
enum MailActionKind: Equatable, Sendable {
    /// "I am finished with this one, here." The cursor advances (T16).
    case disposing
    /// "Note this about it." Nothing moves (T17).
    case marking
    /// Done by another feature, which confirms and undoes it in its own words. Nothing in
    /// Mail moves and nothing goes on Mail's undo stack.
    case anotherFeatures
}

/// Everything a key, a swipe or a menu can ask of a conversation, as one value.
///
/// This is the table of MAIL-UX T14, and the model reads its kind from here rather than from a
/// list of its own, so a row of the table and the way the cursor behaves cannot drift apart.
/// It holds no rule about where a row ends up — that is `MailRowRules` — and no word the person
/// reads — that is `MailToastText`.
///
/// `⇧E` is one key with three meanings, named for where it is pressed (4.2.4): `notDone(in:)`
/// picks the case. In Done, Spam and Trash it brings the conversation back and is disposing;
/// anywhere else it only marks it as not done, and nothing moves.
enum MailAction: Equatable, Sendable {

    // MARK: Disposing

    case done
    case trash
    case spam
    /// `V` and a label: add it and leave the inbox. A label's ids are one account's, so the
    /// account travels with the label.
    case move(account: String, to: MailLabelRef)
    /// `Y`, in a label's list: take the label being viewed off.
    case removeLabel(account: String, label: MailLabelRef)
    /// Send and Done: the send carries the Done (`MailSendOptions.thenDone`), so the model only
    /// moves the cursor and the screen; it asks the source for nothing.
    case sendAndDone
    /// `H` and a time (with package U8).
    case snooze(until: Date, ifNoReply: Bool)
    /// `⇧E` in Done: Back to the inbox.
    case backToInbox
    /// `⇧E` in Spam: Not spam.
    case notSpam
    /// `⇧E` in Trash: Restore.
    case restore
    /// After the first release.
    case mute
    case addToPlan
    case unsubscribe

    // MARK: Marking

    /// `U`. All of the target become unread if all are read, otherwise all read (T17).
    case toggleRead
    /// `S`. All of the target are starred if any is not, otherwise all are unstarred (T17).
    case toggleStar
    /// `L`.
    case label(account: String, add: [MailLabelRef], remove: [MailLabelRef])
    /// `⇧E` anywhere but Done, Spam and Trash.
    case notDone

    // MARK: Another feature's

    /// Answering an invitation (9.1).
    case answerInvitation

    /// Live Gmail capability, shared by menus and keyboard dispatch until the remaining
    /// scheduler, composing and cross-feature paths are integrated.
    var isIntegratedGmailAction: Bool {
        switch self {
        case .done, .trash, .spam, .move, .removeLabel, .backToInbox, .notSpam,
             .restore, .toggleRead, .toggleStar, .label, .notDone: return true
        case .sendAndDone, .snooze, .mute, .addToPlan, .unsubscribe, .answerInvitation: return false
        }
    }

    var kind: MailActionKind {
        switch self {
        case .done, .trash, .spam, .move, .removeLabel, .sendAndDone, .snooze, .backToInbox,
             .notSpam, .restore, .mute, .addToPlan, .unsubscribe:
            return .disposing
        case .toggleRead, .toggleStar, .label, .notDone:
            return .marking
        case .answerInvitation:
            return .anotherFeatures
        }
    }

    /// The key as 4.2 spells it, for the table and for a menu's hint.
    var key: String {
        switch self {
        case .done: return "E"
        case .trash: return "#"
        case .spam: return "!"
        case .move: return "V"
        case .removeLabel: return "Y"
        case .sendAndDone: return "⌘⇧↩"
        case .snooze: return "H"
        case .backToInbox, .notSpam, .restore, .notDone: return "⇧E"
        case .mute: return "⇧M"
        case .addToPlan: return "A"
        case .unsubscribe: return "⌘U"
        case .toggleRead: return "U"
        case .toggleStar: return "S"
        case .label: return "L"
        case .answerInvitation: return "I"
        }
    }

    /// Whether the model decides this action yet. Add to plan and Unsubscribe are after the
    /// first release and ask something of other features (a task; a confirmation) that no
    /// document says how to hand over, so the model leaves them alone.
    var isDecidedByTheModel: Bool {
        switch self {
        case .addToPlan, .unsubscribe, .answerInvitation: return false
        default: return true
        }
    }

    /// Whether Mail's undo stack remembers it. An unsubscribe cannot be taken back (T28), and
    /// another feature's action is undone by that feature (T14).
    var isUndoable: Bool {
        switch self {
        case .unsubscribe, .answerInvitation: return false
        default: return true
        }
    }

    /// `⇧E` for the place it is pressed in.
    static func notDone(in place: MailPlace) -> MailAction {
        switch place {
        case .mailbox(.done): return .backToInbox
        case .mailbox(.spam): return .notSpam
        case .mailbox(.trash): return .restore
        default: return .notDone
        }
    }

    // MARK: What it asks of the source

    /// The change to hand to the source, or nil for an action that is not a change to a
    /// conversation. A toggle is decided against what the target's rows say now (T17); `rows`
    /// are the target's rows that the screen has, which for a selection by scope is only the
    /// ones loaded.
    func change(for rows: [MailRow], in scope: MailScope) -> MailChange? {
        switch self {
        case .done, .sendAndDone:
            return .done
        case .trash:
            return .trash
        case .spam:
            return .spam
        case .move(let account, let label):
            return .move(account: account, to: label.id, from: Self.viewedLabel(of: account, in: scope))
        case .removeLabel(let account, let label):
            return .label(account: account, add: [], remove: [label.id])
        case .snooze(let until, let ifNoReply):
            return .snooze(until: until, ifNoReply: ifNoReply)
        case .backToInbox, .notDone:
            return .notDone
        case .notSpam:
            return .notSpam
        case .restore:
            return .restore
        case .mute:
            return .mute(true)
        case .toggleRead:
            let allRead = !rows.isEmpty && rows.allSatisfy { !$0.isUnread }
            return .read(!allRead)
        case .toggleStar:
            let anyUnstarred = rows.isEmpty || rows.contains { !$0.isStarred }
            return .star(anyUnstarred)
        case .label(let account, let add, let remove):
            return .label(account: account, add: add.map(\.id), remove: remove.map(\.id))
        case .addToPlan, .unsubscribe, .answerInvitation:
            return nil
        }
    }

    /// The label whose list is being looked at, when it is `account`'s: what a Move leaves.
    private static func viewedLabel(of account: String, in scope: MailScope) -> String? {
        if case .label(let owner, let id) = scope.place, owner == account { return id }
        return nil
    }

    /// Whether the action would change nothing about this row (T16), read from `MailRowRules`'
    /// answer: the row it hands back is the row it was given (its "not yet at Gmail" mark aside),
    /// and it does not leave the list. Then nothing is sent, no toast shows and no undo entry is
    /// made — and the cursor still advances.
    ///
    /// It is a question about what the row says, so it is asked only of an action whose whole
    /// effect the row carries. A move, a label put on, a snooze and a send are never "nothing":
    /// the row does not carry the label or the time that would show it. Done on a snoozed
    /// conversation is not nothing either: the rule says it ends the snooze, so the row it hands
    /// back differs. And it is never asked of a selection by scope, which includes rows that are
    /// not loaded: the model does not call this for one.
    func wouldChangeNothing(on row: MailRow, in scope: MailScope) -> Bool {
        switch self {
        case .move, .snooze, .sendAndDone, .toggleRead, .toggleStar, .addToPlan, .unsubscribe,
             .answerInvitation:
            return false
        case .label(_, let add, _) where !add.isEmpty:
            return false
        default:
            break
        }
        guard let change = change(for: [row], in: scope) else { return false }
        switch MailRowRules.apply(change, to: row, in: scope) {
        case .leaves:
            return false
        case .stays(var changed), .unknown(var changed):
            changed.hasPendingChange = row.hasPendingChange
            return changed == row
        }
    }
}

/// One line of the table in MAIL-UX T14, as data, so a test can hold it against the document.
enum MailActions {
    struct Entry: Equatable, Sendable {
        var name: String
        var key: String
        var kind: MailActionKind
        /// Built after the first release (section 11).
        var afterFirstRelease: Bool
    }

    private static let invoices = MailLabelRef(id: "", name: "", colorHex: nil)

    /// Every action there is, once, in the order of T14's table.
    static let table: [Entry] = [
        entry("Done", .done),
        entry("Trash", .trash),
        entry("Spam", .spam),
        entry("Move", .move(account: "", to: invoices)),
        entry("Remove this label", .removeLabel(account: "", label: invoices)),
        entry("Send and Done", .sendAndDone),
        entry("Back to the inbox", .backToInbox),
        entry("Not spam", .notSpam),
        entry("Restore", .restore),
        entry("Snooze", .snooze(until: .distantFuture, ifNoReply: false)),
        entry("Mute", .mute, later: true),
        entry("Add to plan", .addToPlan, later: true),
        entry("Unsubscribe", .unsubscribe, later: true),
        entry("Read or unread", .toggleRead),
        entry("Star", .toggleStar),
        entry("Label", .label(account: "", add: [], remove: [])),
        entry("Not done", .notDone),
        entry("Answer an invitation", .answerInvitation, later: true),
    ]

    private static func entry(_ name: String, _ action: MailAction, later: Bool = false) -> Entry {
        Entry(name: name, key: action.key, kind: action.kind, afterFirstRelease: later)
    }
}

#endif
