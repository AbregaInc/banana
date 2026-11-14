#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Counts only eligible, known content work using the existing partial queue indexes.
/// No message bodies, whole-history decode, or new network requests are needed.
enum MailSyncProgressReader {
    static let countLimit = 1_000
    struct Pending: Equatable, Sendable {
        var count: Int
        var isExact: Bool
    }
    static func pending(accounts: [String], in db: Database, limit: Int = countLimit) throws -> [String: Pending] {
        let limit = max(1, min(limit, Int.max - 1))
        var counts: [String: Pending] = [:]
        for account in accounts {
            guard let owner = try Int64.fetchOne(db, sql: "SELECT account_pk FROM account WHERE email=?", arguments: [account]) else {
                counts[account] = Pending(count: 0, isExact: true); continue
            }
            let cloud = try MailCloudFeedIndex.state(account: account, in: db) != nil
            let index = cloud ? "message_cloud_pull" : "message_sync_fill_newest"
            let content = cloud ? "AND m.cloud_content=1" : ""
            let count = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (SELECT m.msg_pk FROM message m INDEXED BY \(index)
                WHERE m.account_pk=? AND (m.fetch_state<2 OR m.prep_state=0) AND m.vis!=4
                  AND m.fetch_state<2 \(content)
                  AND NOT EXISTS(SELECT 1 FROM held_removal h WHERE h.msg_pk=m.msg_pk)
                LIMIT ?)
                """, arguments: [owner, limit + 1]) ?? 0
            counts[account] = Pending(count: count, isExact: count <= limit)
        }
        return counts
    }
}
#endif
