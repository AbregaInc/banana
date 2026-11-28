#if !BANANA_PUBLIC
import CryptoKit
import Foundation
import GRDB

/// Bridges cancellation or account revocation into the final synchronous intent transaction.
final class MailOvernightSavePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var valid: Bool { lock.withLock { active } }
    func invalidate() { lock.withLock { active = false } }
}

enum MailOvernightDrafts {
    static func draftID(for conversation: MailConversationID, anchor: MailMessageID) -> MailDraftID {
        let key = [conversation.account, conversation.thread, anchor.message].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return MailDraftID(raw: "overnight-" + digest)
    }

    /// Authoritative index check shared by the scan and the atomic write. Treat unknown
    /// mail, pending actions and a visible reply or provider draft as reasons to abstain.
    static func latestInbound(_ id: MailConversationID, rfcID: String? = nil, in db: Database) throws -> String? {
        let blocked: MailThreadFlags = [.hasDraft, .lastIsMine, .muted, .isList, .keptAfterRemoval]
        return try String.fetchOne(db, sql: """
            SELECT m.gmail_id FROM account a JOIN thread t USING(account_pk)
            JOIN message m ON m.msg_pk=(SELECT msg_pk FROM message
                WHERE thread_pk=t.thread_pk ORDER BY internal_date DESC,gmail_id DESC LIMIT 1)
            WHERE a.email=? AND t.gmail_id=? AND (t.flags & ?) != 0 AND (t.flags & ?)=0
            AND t.pending=0 AND t.fetched_count=t.message_count AND m.vis=0 AND m.fetch_state>0
            AND (m.flags & ?)=0 AND (m.flags & ?)!=0 AND m.from_addr IS NOT NULL
            AND lower(m.from_addr)<>lower(a.email) AND m.rfc_message_id IS NOT NULL
            AND length(m.rfc_message_id)>0 AND (? IS NULL OR m.rfc_message_id=?)
            AND EXISTS(SELECT 1 FROM message_label ml JOIN label l USING(label_pk)
                       WHERE ml.msg_pk=m.msg_pk AND l.gmail_id='INBOX')
            AND NOT EXISTS(SELECT 1 FROM message_label ml JOIN label l USING(label_pk)
                           WHERE ml.msg_pk=m.msg_pk AND l.gmail_id IN ('SENT','DRAFT','TRASH','SPAM'))
            """, arguments: [id.account,id.thread,MailThreadFlags.inInbox.rawValue,blocked.rawValue,
                             MailMessageFlags.fromMe.rawValue,MailMessageFlags.labelsKnown.rawValue, rfcID, rfcID])
    }
}
#endif
