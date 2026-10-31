#if !BANANA_PUBLIC
import Foundation

/// What a change does to one row of one list: the row as it now is, and whether it still
/// belongs in the list being looked at.
///
/// This is what lets a change show in the same turn as the key press. The alternative is to
/// wait for the store to commit and read the list again, which is a few milliseconds when all
/// is well and much longer when the disk is busy — and for those milliseconds the row he
/// pressed E on would still be under his cursor. So the list edits its own rows through this
/// rule first, and the store's reading follows and has the last word.
///
/// It answers from the row and the scope alone. It reads nothing, knows no account's labels
/// and no split's query, and has no clock, which is why it can run on the main actor and why
/// every cell of it is tested directly (`MailRowRulesTests`). The engine has a second
/// implementation of the same membership, over the store (`ViewMembershipRules`); one test
/// holds the two together, so the row shown at the key press is never contradicted by the
/// reading that follows.
///
/// The tables are MAIL-ENGINE 13.2. **Every answer carries the row as changed**, so the
/// change itself always shows at once. What may be unknown is only where the row belongs:
/// whether a conversation marked done still matches a search, whether a custom split's query
/// still holds. Then the answer is `unknown`, never a guess — the row is drawn as changed,
/// where it is, and the next reading decides.
extension MailRowRules {

    /// The row after `change`, and whether it still belongs in `scope`.
    static func apply(_ change: MailChange, to row: MailRow, in scope: MailScope) -> Outcome {
        // A label's id is one account's. A change that names another account's labels is not
        // about this row at all: it is untouched, and it is not pending.
        if let account = labelAccount(of: change), account != row.id.account {
            return .stays(row)
        }

        let changed = self.changed(row, by: change)
        // System labels can be entered through the label tree as well as a mailbox.
        // They must predict the same membership on both routes.
        if case .label(_, "UNREAD") = scope.place, !changed.isUnread {
            return .leaves(changed)
        }
        let belongs = self.belongs(after: change, in: scope.place)
        if belongs == false { return .leaves(changed) }
        // The filters come last and only ever take a row away. A row that now fails one has
        // left for certain — whatever is unknown about the place, it is not in a list that
        // shows only what passes. ("No reply" is not asked: no change alters whether anyone
        // has replied, so a row that was in the list still passes it.)
        guard passes(changed, scope.filters) else { return .leaves(changed) }
        return belongs == true ? .stays(changed) : .unknown(changed)
    }

    /// The account whose label ids a change carries; nil for a change that names no label.
    private static func labelAccount(of change: MailChange) -> String? {
        switch change {
        case .label(let account, _, _), .move(let account, _, _):
            return account
        default:
            return nil
        }
    }

    // MARK: - The row as changed

    /// The same in every place. Only what the change itself decides is touched: where a
    /// restored conversation returns to is Gmail's to say, and a label that was added cannot be
    /// drawn from its id alone, so neither appears here and the next reading brings both.
    private static func changed(_ row: MailRow, by change: MailChange) -> MailRow {
        var row = row
        // Every change, including one that alters nothing drawn: it has not reached Gmail.
        row.hasPendingChange = true
        switch change {
        case .done:
            // Done also marks read. A conversation he has dealt with is not one he has not
            // read, and Gmail is told both in one request. It also ends a snooze, as unsnooze does.
            row.inInbox = false
            row.isUnread = false
            if case .snoozed = row.reason { row.reason = nil }
        case .notDone, .notSpam:
            row.inInbox = true
        case .unsnooze:
            row.inInbox = true
            if case .snoozed = row.reason { row.reason = nil }
        case .trash, .spam:
            row.inInbox = false
        case .move(_, _, let from):
            row.inInbox = false
            if let from { row.labels.removeAll { $0.id == from } }
        case .restore:
            break
        case .read(let read):
            row.isUnread = !read
        case .star(let starred):
            row.isStarred = starred
        case .important(let important):
            row.isImportant = important
        case .mute(let muted):
            row.isMuted = muted
            if muted { row.inInbox = false }
        case .snooze(let until, let ifNoReply):
            row.inInbox = false
            if !outranksASnooze(row.reason) {
                row.reason = .snoozed(until: until, ifNoReply: ifNoReply)
            }
        case .label(_, _, let remove):
            row.labels.removeAll { remove.contains($0.id) }
        }
        return row
    }

    /// A row draws one line, the highest-ranking thing there is to say about it, and the cases
    /// of `MailRowReason` are in that order. A question, a send and a draft all outrank a
    /// snooze, so snoozing a conversation that has one of those lines leaves the line alone.
    /// What a snooze replaces is nothing, an earlier snooze, and "back from snooze" — which
    /// stopped being true the moment it was snoozed again.
    private static func outranksASnooze(_ reason: MailRowReason?) -> Bool {
        switch reason {
        case .asking, .failedToSend, .changeRefused, .held, .waitingToSend, .sending,
             .checkingSent, .scheduled, .draft:
            return true
        case nil, .backFromSnooze, .snoozed, .keptAfterRemoval:
            return false
        }
    }

    // MARK: - Whether it still belongs

    /// The kinds of place the membership table has a column for. Two places of one kind answer
    /// alike except where a case below says otherwise by naming the mailbox, the label or the
    /// split.
    private enum PlaceKind {
        /// The inbox and every split of it.
        case inbox
        case done
        case labelLike
        case bin
        case snoozed
        case search
        /// Drafts, the outbox and a held removal: lists of things that are not conversations
        /// in the inbox's sense, where no change to a row can be placed from the row.
        case composed
    }

    private static func kind(of place: MailPlace) -> PlaceKind {
        switch place {
        case .split:
            return .inbox
        case .label:
            return .labelLike
        case .search:
            return .search
        case .heldRemoval:
            return .composed
        case .mailbox(let mailbox):
            switch mailbox {
            case .inbox: return .inbox
            case .done: return .done
            case .all, .sent, .starred, .important, .muted: return .labelLike
            case .trash, .spam: return .bin
            case .snoozed: return .snoozed
            case .drafts, .outbox: return .composed
            }
        }
    }

    /// True: stays. False: leaves. Nil: cannot be known from here.
    private static func belongs(after change: MailChange, in place: MailPlace) -> Bool? {
        if case .label(_, let id) = place {
            // Explicit removal still names this label even when it is a system label.
            if case .label(_, _, let remove) = change, remove.contains(id) { return false }
            if case .move(_, _, let from) = change, from == id { return false }
            let mailbox: MailMailbox?
            switch id {
            case "INBOX": mailbox = .inbox
            case "STARRED": mailbox = .starred
            case "IMPORTANT": mailbox = .important
            case "SENT": mailbox = .sent
            case "TRASH": mailbox = .trash
            case "SPAM": mailbox = .spam
            default: mailbox = nil
            }
            if let mailbox { return belongs(after: change, in: .mailbox(mailbox)) }
        }
        let kind = self.kind(of: place)
        if kind == .composed { return nil }
        let inPlace = belongs(after: change, in: place, of: kind)
        // A split is a part of the inbox. A row that leaves the inbox leaves every split; one
        // that stays in the inbox may still have changed split.
        if case .split(let id) = place, inPlace == true {
            return staysInSplit(id, after: change)
        }
        return inPlace
    }

    /// An inbox conversation is in exactly one split: the first whose rule it satisfies, in
    /// the order custom splits, Calendar, Important, Other (MAIL-ENGINE 9.3). Of those rules
    /// this one has the built-in three — Calendar is "has an invitation", which no change
    /// alters; Important is "marked important"; Other is the rest. **It has no custom split's
    /// query**, which may test flags and labels, so in a custom split it knows only what
    /// leaves the inbox, and answers `unknown` for everything else.
    ///
    /// It also cannot see a custom split claiming a row out of a built-in one — labelling a
    /// conversation in Important when a custom split collects that label. That row is answered
    /// `stays` here and dropped by the next reading; the list keeps a row he has just marked
    /// whatever the reading says (MAIL-UX T17), so nothing vanishes under his cursor.
    private static func staysInSplit(_ id: String, after change: MailChange) -> Bool? {
        switch id {
        case MailSplit.calendarID:
            return true
        case MailSplit.importantID:
            if case .important(let important) = change { return important }
            return true
        case MailSplit.otherID:
            if case .important(let important) = change { return !important }
            return true
        default:
            return nil
        }
    }

    /// The membership table, change by change, with one line per column — so that a cell can
    /// be found by reading and a missing one does not compile.
    private static func belongs(after change: MailChange, in place: MailPlace,
                                of kind: PlaceKind) -> Bool? {
        switch change {
        case .done:
            switch kind {
            case .inbox, .snoozed: return false
            case .done, .labelLike, .bin: return true
            case .search, .composed: return nil
            }

        case .notDone:
            switch kind {
            case .done: return false
            case .inbox, .labelLike, .bin: return true
            // Whether a snoozed conversation brought back to the inbox is still snoozed is the
            // engine's decision about the snooze, not something the row shows.
            case .snoozed, .search, .composed: return nil
            }

        case .trash:
            // The one change every place but Trash itself is sure about, a search included:
            // nothing in the bin is shown anywhere else.
            return kind == .bin ? place == .mailbox(.trash) : false

        case .spam:
            return kind == .bin ? place == .mailbox(.spam) : false

        case .restore:
            switch kind {
            case .bin: return place != .mailbox(.trash)
            case .inbox, .done, .labelLike, .snoozed: return true
            case .search, .composed: return nil
            }

        case .notSpam:
            switch kind {
            case .bin: return place != .mailbox(.spam)
            case .inbox, .done, .labelLike, .snoozed: return true
            case .search, .composed: return nil
            }

        case .read:
            // Reading changes where nothing lives. A search keeps its row too: results do not
            // vanish from under him because he opened one.
            return true

        case .star(let starred):
            return starred || place != .mailbox(.starred)

        case .important(let important):
            return important || place != .mailbox(.important)

        case .mute(let muted):
            if kind == .search { return nil }
            return muted ? kind != .inbox : place != .mailbox(.muted)

        case .snooze:
            switch kind {
            case .inbox: return false
            case .done, .labelLike, .bin, .snoozed: return true
            case .search, .composed: return nil
            }

        case .unsnooze:
            switch kind {
            case .done, .snoozed: return false
            case .inbox, .labelLike, .bin: return true
            case .search, .composed: return nil
            }

        case .label(_, _, let remove):
            if kind == .search { return nil }
            if case .label(_, let id) = place { return !remove.contains(id) }
            return true

        case .move(_, _, let from):
            switch kind {
            case .inbox, .snoozed: return false
            case .done, .bin: return true
            case .labelLike:
                if case .label(_, let id) = place { return id != from }
                return true
            case .search, .composed: return nil
            }
        }
    }

    // MARK: - Filters

    /// Whether the row, as changed, still passes every filter the scope carries that a change
    /// can alter the answer to.
    private static func passes(_ row: MailRow, _ filters: Set<MailFilter>) -> Bool {
        if filters.contains(.unread), !row.isUnread { return false }
        if filters.contains(.starred), !row.isStarred { return false }
        if filters.contains(.important), !row.isImportant { return false }
        return true
    }
}

#endif
