#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Derived rows are written inside MailWriter's index transaction, after durable intent.
/// Callers supply the complete effective facts for this thread, not a partial network page.
enum MailIndexWriter {
    enum Failure: Error { case transactionRequired, missingThread }

    @discardableResult
    static func rebuildThread(_ threadPK: Int64, facts: [MessageFacts], myAddresses: Set<String>,
                              splits: [MailSplit] = [],
                              matches: (MailSplit, [MessageFacts]) -> Bool = { _, _ in false },
                              reuseStatements: Bool = true,
                              in db: Database) throws -> MailStoreChange {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        func statement(_ sql: String) throws -> Statement {
            try reuseStatements ? db.cachedStatement(sql: sql) : db.makeStatement(sql: sql)
        }
        guard let thread = try Row.fetchOne(statement("""
            SELECT t.account_pk, t.tie, a.email, t.gmail_id FROM thread t
            JOIN account a ON a.account_pk=t.account_pk WHERE t.thread_pk=?
            """), arguments: [threadPK]) else { throw Failure.missingThread }
        let accountPK: Int64 = thread[0], tie: Int64 = thread[1], account: String = thread[2]
        let gmailID: String = thread[3]
        var changedViews = Set(try String.fetchAll(statement("""
            SELECT v.key FROM view v JOIN view_thread vt ON vt.view_pk=v.view_pk WHERE vt.thread_pk=?
            """), arguments: [threadPK]))
        let summary = ThreadSummaryRules.summarise(facts, myAddresses: myAddresses)
        let memberships = ViewMembershipRules.memberships(facts, account: account, splits: splits,
            matches: matches, myAddresses: myAddresses)
        var labelPKs: [Int64] = []
        var labelsChanged = false
        for id in summary.labels.sorted() {
            // Listing labels can arrive before labels.list. Keep existing names/colors intact.
            let kind = SystemLabel(rawValue: id) == nil ? 1 : 0
            try statement("INSERT OR IGNORE INTO label(account_pk,gmail_id,name,kind) VALUES (?,?,?,?)").execute(
                           arguments: [accountPK, id, id, kind])
            labelsChanged = labelsChanged || db.changesCount > 0
            if let pk = try Int64.fetchOne(statement("SELECT label_pk FROM label WHERE account_pk=? AND gmail_id=?"),
                                          arguments: [accountPK, id]) { labelPKs.append(pk) }
        }
        let encoder = JSONEncoder()
        let people = String(decoding: try encoder.encode(summary.people), as: UTF8.self)
        let recipients = String(decoding: try encoder.encode(summary.recipients), as: UTF8.self)
        let labels = labelPKs.sorted().map(String.init).joined(separator: ",")
        // Timed/attention fields are independently owned; summarising mail must not erase them.
        try statement("""
            UPDATE thread SET last_date=?,message_count=?,fetched_count=?,unread_count=?,flags=?,
              subject=?,snippet=?,people=?,people_total=?,recipients=?,recipients_total=?,labels=?,pending=?
            WHERE thread_pk=?
            """).execute(arguments: [summary.lastDate, summary.messageCount, summary.fetchedCount,
                summary.unreadCount, summary.flags.rawValue, summary.subject, summary.snippet,
                people, summary.peopleTotal, recipients, summary.recipientsTotal, labels, summary.pending, threadPK])
        // Only memberships owned by the ordinary message rules are replaced. Timed snooze
        // memberships belong to their scheduler and must survive a header refresh.
        let snoozed = try MailIndexReader.viewKey(.snoozed)
        try statement("DELETE FROM view_thread WHERE thread_pk=? AND view_pk IN (SELECT view_pk FROM view WHERE key != ?)").execute(
                       arguments: [threadPK, snoozed])
        for membership in memberships {
            let key = try MailIndexReader.viewKey(membership.view)
            changedViews.insert(key)
            let kind: Int
            switch membership.view {
            case .label: kind = 0
            case .unified: kind = 1
            case .allMail: kind = 2
            case .split: kind = 3
            default: kind = 4
            }
            try statement("INSERT OR IGNORE INTO view(key,kind) VALUES (?,?)").execute(arguments: [key, kind])
            try statement("""
                INSERT INTO view_thread(view_pk,sort_key,tie,thread_pk,unread)
                SELECT view_pk,?,?,?,? FROM view WHERE key=?
                """).execute(arguments: [membership.sortKey, tie, threadPK, membership.unread, key])
        }
        return MailStoreChange(viewKeys: changedViews,
            conversations: [MailConversationID(account: account, thread: gmailID)], labelsChanged: labelsChanged)
    }
}

#endif
