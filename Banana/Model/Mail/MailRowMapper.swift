#if !BANANA_PUBLIC
import Foundation

/// The only conversion from a stored summary to the UI contract. No database reads,
/// text parsing, or date formatting belong here; the writer prepared these values.
enum MailRowMapper {
    static func row(_ stored: IndexRow, labels: [MailLabelRef], reason: MailRowReason?,
                    in scope: MailScope) -> MailRow {
        let useRecipients: Bool
        switch scope.place {
        case .mailbox(.sent), .mailbox(.drafts), .mailbox(.outbox): useRecipients = true
        case .label(_, let id): useRecipients = id == "SENT" || id == "DRAFT"
        default: useRecipients = false
        }
        let people = useRecipients ? stored.recipients : stored.people
        return MailRow(id: MailConversationID(account: stored.account, thread: stored.thread),
            key: MailOrderKey(group: 0, sortKey: stored.sortKey, tie: stored.tie),
            date: Date(timeIntervalSince1970: Double(stored.lastDate) / 1_000),
            people: people.prefix(6).map {
                MailPerson(name: $0.n, address: $0.a, isMe: $0.isMe,
                           isKnown: false, fromTheirMail: false)
            },
            peopleTotal: useRecipients ? stored.recipientsTotal : stored.peopleTotal,
            messageCount: stored.messageCount, subject: stored.subject, snippet: stored.snippet,
            isUnread: stored.unread, isStarred: stored.flags.contains(.starred),
            isImportant: stored.flags.contains(.important),
            hasAttachment: stored.flags.contains(.hasAttachment),
            isInvitation: stored.flags.contains(.hasInvite), inInbox: stored.flags.contains(.inInbox),
            isMuted: stored.flags.contains(.muted), hasPendingChange: stored.pending != 0,
            fromGmailSearch: false, labels: labels,
            reason: reason ?? (stored.pending == 2 ? .changeRefused(.other) : stored.flags.contains(.keptAfterRemoval) ? .keptAfterRemoval
                : snoozeReason(stored)),
            isOnDevice: true, actionBoundary: stored.actionBoundary)
    }

    /// "Until Thu 8 AM" while snoozed, "Back from snooze" once it has come back to the inbox (8.1).
    /// The summary holds a wake time only for those two states.
    private static func snoozeReason(_ stored: IndexRow) -> MailRowReason? {
        func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1_000) }
        if let returned = stored.returnedAt, returned > 0, stored.flags.contains(.inInbox) {
            return .backFromSnooze(due: date(returned), wasIfNoReply: false)
        }
        if let wake = stored.wakeAt, stored.returnedAt == nil, !stored.flags.contains(.inInbox) {
            return .snoozed(until: date(wake), ifNoReply: false)
        }
        return nil
    }
}

extension IndexRow {
    /// The same input for a fixture source that has no SQL or local database row IDs.
    init(summary: ThreadSummary, id: MailConversationID, key: MailOrderKey) {
        self.init(threadPK: 0, account: id.account, thread: id.thread,
                  sortKey: key.sortKey, tie: key.tie, unread: summary.unreadCount > 0,
                  messageCount: summary.messageCount, flags: summary.flags,
                  subject: summary.subject, snippet: summary.snippet,
                  people: summary.people, peopleTotal: summary.peopleTotal,
                  labelPKs: [], wakeAt: summary.wakeAt, returnedAt: summary.returnedAt,
                  waitingUntil: summary.waitingUntil, pending: summary.pending,
                  lastDate: summary.lastDate, recipients: summary.recipients,
                  recipientsTotal: summary.recipientsTotal)
    }
}

#endif
