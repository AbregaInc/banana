#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Gmail's label directory, separate from message membership and durable local intent.
/// A missing/invalid response never replaces the last successful directory.
enum MailLabelCatalog {
    enum Failure: Error { case invalidResponse, wrongAccount, transactionRequired }
    struct Reading: Equatable, Sendable {
        var places: [String: [MailLabelNode]] = [:]
        var refs: [Int64: MailLabelRef] = [:]
    }

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-label-directory") { db in
            try db.execute(sql: "ALTER TABLE label ADD COLUMN listed INTEGER NOT NULL DEFAULT 0")
        }
    }

    static func fetch(account: String, api: any GmailAPI, token: String, writer: MailWriter) async throws {
        let profile = try await api.profile(token: token)
        guard profile.emailAddress?.lowercased() == account.lowercased() else { throw Failure.wrongAccount }
        let labels = try await api.labels(token: token)
        try Task.checkCancellation()
        _ = try await writer.transact { try replace(labels, account: account, in: $0) }
    }

    static func replace(_ labels: [GmailLabel], account: String, in db: Database) throws -> MailStoreChange {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let required = Set(["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"])
        guard required.isSubset(of: Set(labels.filter { $0.type == "system" }.compactMap(\.id))),
              MailAddressRules.isValid(account), labels.allSatisfy({
            $0.id?.isEmpty == false && $0.name?.isEmpty == false && ($0.type == "user" || $0.type == "system")
        }), Set(labels.compactMap(\.id)).count == labels.count else { throw Failure.invalidResponse }
        let owner = account.lowercased()
        try db.execute(sql: "INSERT OR IGNORE INTO account(email) VALUES (?)", arguments: [owner])
        let pk = try Int64.fetchOne(db, sql: "SELECT account_pk FROM account WHERE email=?", arguments: [owner])!
        // Absence from a directory is not deletion evidence. Keep prior entries until
        // an account-verified, per-label request confirms notFound (MAIL-ENGINE 5.3).
        for label in labels {
            let kind = label.type == "system" ? 0 : label.name!.hasPrefix("Banana/") ? 2 : 1
            try db.execute(sql: """
                INSERT INTO label(account_pk,gmail_id,name,kind,list_visibility,message_visibility,text_color,background_color,listed)
                VALUES(?,?,?,?,?,?,?,?,1) ON CONFLICT(account_pk,gmail_id) DO UPDATE SET
                name=excluded.name,kind=excluded.kind,list_visibility=excluded.list_visibility,
                message_visibility=excluded.message_visibility,text_color=excluded.text_color,
                background_color=excluded.background_color,listed=1
                """, arguments: [pk, label.id, label.name, kind, label.labelListVisibility,
                    label.messageListVisibility, label.color?.textColor, label.color?.backgroundColor])
        }
        try db.execute(sql: "UPDATE account SET labels_at=? WHERE account_pk=?", arguments: [Int64(Date().timeIntervalSince1970 * 1000), pk])
        return MailStoreChange(labelsChanged: true)
    }

    static func read(in db: Database) throws -> Reading {
        var result = Reading()
        let rows = try Row.fetchCursor(db, sql: """
            SELECT a.email,l.label_pk,l.gmail_id,l.name,l.background_color FROM label l
            JOIN account a ON a.account_pk=l.account_pk WHERE l.listed=1 AND l.kind=1
            ORDER BY a.email,l.name COLLATE NOCASE,l.gmail_id
            """)
        while let row = try rows.next() {
            let account: String = row[0], pk: Int64 = row[1], id: String = row[2]
            let ref = MailLabelRef(id: id, name: row[3], colorHex: row[4])
            result.refs[pk] = ref
            // Preserve full Gmail paths; every label is reachable even without a parent label.
            result.places[account, default: []].append(MailLabelNode(id: account + "|" + id, ref: ref, children: []))
        }
        return result
    }
}

#endif
