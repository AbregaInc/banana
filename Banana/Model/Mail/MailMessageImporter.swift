#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Metadata ingestion inside the existing index writer transaction. A full payload is still
/// only header-fetched here: body durability must be established by the blob writer first.
enum MailMessageImporter {
    enum Failure: Error { case transactionRequired, invalidIdentity, changedThread, corruptRecipients }
    struct Recipients: Codable { var to: [String]; var cc: [String]; var bcc: [String] }

    @discardableResult
    static func apply(_ fetched: FetchedMessage, account: String, myAddresses: Set<String>,
                      in db: Database) throws -> MailStoreChange {
        guard db.isInsideTransaction else { throw Failure.transactionRequired }
        let account = account.lowercased(), wire = fetched.wire
        guard MailAddressRules.isValid(account), let id = wire.id, !id.isEmpty,
              let threadID = wire.threadId, !threadID.isEmpty else { throw Failure.invalidIdentity }
        try db.execute(sql: "INSERT OR IGNORE INTO account(email) VALUES (?)", arguments: [account])
        let accountPK = try Int64.fetchOne(db, sql: "SELECT account_pk FROM account WHERE email=?", arguments: [account])!
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tombstone WHERE account_pk=? AND gmail_id=?)",
                             arguments: [accountPK, id]) == true { return MailStoreChange() }
        try db.execute(sql: "INSERT OR IGNORE INTO thread(account_pk,gmail_id,tie) VALUES (?,?,?)",
                       arguments: [accountPK, threadID, tie(account: account, thread: threadID)])
        let threadPK = try Int64.fetchOne(db, sql: "SELECT thread_pk FROM thread WHERE account_pk=? AND gmail_id=?",
                                        arguments: [accountPK, threadID])!
        try db.execute(sql: "INSERT OR IGNORE INTO message(account_pk,gmail_id,thread_pk) VALUES (?,?,?)",
                       arguments: [accountPK, id, threadPK])
        let stored = try Row.fetchOne(db, sql: "SELECT msg_pk,thread_pk,history_id,flags,vis FROM message WHERE account_pk=? AND gmail_id=?",
                                      arguments: [accountPK, id])!
        let msgPK: Int64 = stored[0], oldThread: Int64 = stored[1]
        guard oldThread == threadPK else { throw Failure.changedThread }
        let visibility: Int = stored[4]
        guard visibility != 4 else { return MailStoreChange() }
        let historyText: String? = stored[2]
        let oldHistory = historyText.flatMap(GmailNumber.unsigned)
        let incomingHistory = max(fetched.floor, wire.historyId ?? 0)
        if let oldHistory, incomingHistory < oldHistory { return MailStoreChange() }
        var labelsChanged = false
        var flags = MailMessageFlags(rawValue: stored[3])
        if let labels = wire.labelIds, incomingHistory >= (oldHistory ?? 0) {
            try db.execute(sql: "DELETE FROM message_label WHERE msg_pk=?", arguments: [msgPK])
            for label in Set(labels).sorted() {
                try db.execute(sql: "INSERT OR IGNORE INTO label(account_pk,gmail_id,name,kind) VALUES (?,?,?,?)",
                    arguments: [accountPK, label, label, SystemLabel(rawValue: label) == nil ? 1 : 0])
                labelsChanged = labelsChanged || db.changesCount > 0
                try db.execute(sql: "INSERT INTO message_label(msg_pk,label_pk) SELECT ?,label_pk FROM label WHERE account_pk=? AND gmail_id=?",
                               arguments: [msgPK, accountPK, label])
            }
            flags.insert(.labelsKnown)
            try db.execute(sql: "UPDATE message SET history_id=? WHERE msg_pk=?", arguments: [String(incomingHistory), msgPK])
        }
        // A minimal response cannot wipe previously fetched header fields. Missing labels
        // are independently unknown even when the headers are complete.
        if wire.payload?.headers != nil && fetched.headers.isComplete {
            let headers = fetched.headers, sender = fetched.headers.sender
            if let sender, myAddresses.contains(sender.key) { flags.insert(.fromMe) }
            else { flags.remove(.fromMe) }
            if let structure = fetched.structure {
                if structure.attachments.isEmpty { flags.remove(.hasAttachment) } else { flags.insert(.hasAttachment) }
                if structure.invite == nil { flags.remove(.hasInvite) } else { flags.insert(.hasInvite) }
            }
            let recipients = Recipients(to: headers.to.mailboxes.map(\.key), cc: headers.cc.mailboxes.map(\.key),
                                        bcc: headers.bcc.mailboxes.map(\.key))
            let json = String(decoding: try JSONEncoder().encode(recipients), as: UTF8.self)
            try db.execute(sql: """
                UPDATE message SET fetch_state=max(fetch_state,1),from_addr=?,from_name=?,subject=?,
                  recipients=?,rfc_message_id=?,list_id=?,fts_dirty=1 WHERE msg_pk=?
                """, arguments: [sender?.key, sender.flatMap { MailAddressRules.displayName($0.name, address: $0.address) },
                    headers.subject, json, headers.value("Message-ID"), headers.value("List-ID"), msgPK])
        }
        try db.execute(sql: """
            UPDATE message SET flags=?,internal_date=coalesce(?,internal_date),
              snippet=coalesce(?,snippet),size_estimate=coalesce(?,size_estimate) WHERE msg_pk=?
            """, arguments: [flags.rawValue, wire.internalDate, wire.snippet.map(MailHeaderText.display), wire.sizeEstimate, msgPK])
        let facts = try facts(threadPK: threadPK, in: db)
        if let imported = facts.first(where: { $0.rowID == msgPK }) {
            try db.execute(sql: "UPDATE message SET vis=? WHERE msg_pk=?", arguments: [imported.vis, msgPK])
        }
        var change = try MailIndexWriter.rebuildThread(threadPK, facts: facts, myAddresses: myAddresses, in: db)
        change.labelsChanged = change.labelsChanged || labelsChanged
        return change
    }

    static func facts(threadPK: Int64, in db: Database) throws -> [MessageFacts] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM message WHERE thread_pk=? ORDER BY internal_date,gmail_id", arguments: [threadPK])
        let labelRows = try Row.fetchAll(db, sql: """
            SELECT ml.msg_pk,l.gmail_id,l.name FROM message_label ml
            JOIN message m ON m.msg_pk=ml.msg_pk JOIN label l ON l.label_pk=ml.label_pk WHERE m.thread_pk=?
            """, arguments: [threadPK])
        var labels: [Int64: Set<String>] = [:], names: [String: String] = [:]
        for row in labelRows {
            let pk: Int64 = row[0], id: String = row[1], name: String = row[2]
            labels[pk, default: []].insert(id); names[id] = name
        }
        let overlays = try Row.fetchAll(db, sql: """
            SELECT o.msg_pk,l.gmail_id,l.name,o.want,o.refused FROM overlay o
            JOIN message m ON m.msg_pk=o.msg_pk JOIN label l ON l.label_pk=o.label_pk WHERE m.thread_pk=?
            """, arguments: [threadPK])
        var pending = Set<Int64>(), refused = Set<Int64>()
        for row in overlays {
            let pk: Int64 = row[0], id: String = row[1], name: String = row[2], want: Bool = row[3]
            let wasRefused: Bool = row[4]
            if !wasRefused {
                if want { labels[pk, default: []].insert(id) } else { labels[pk, default: []].remove(id) }
            }
            pending.insert(pk); names[id] = name
            if wasRefused { refused.insert(pk) }
        }
        return try rows.map { row in
            let pk: Int64 = row["msg_pk"], flags = MailMessageFlags(rawValue: row["flags"])
            let json: String? = row["recipients"]
            var recipients = Recipients(to: [], cc: [], bcc: [])
            if let json {
                guard let decoded = try? JSONDecoder().decode(Recipients.self, from: Data(json.utf8)) else { throw Failure.corruptRecipients }
                recipients = decoded
            }
            let effective = labels[pk] ?? []
            let storedVis: Int = row["vis"]
            let vis = storedVis >= 3 ? storedVis : effective.contains("TRASH") ? 1 : effective.contains("SPAM") ? 2 : 0
            return MessageFacts(gmailID: row["gmail_id"], rowID: pk, arrivalSequence: row["arrival_seq"], internalDate: row["internal_date"],
                fetchState: row["fetch_state"], vis: vis, labels: effective, labelsKnown: flags.contains(.labelsKnown),
                bananaLabels: effective.compactMap { names[$0] }.filter { $0.hasPrefix("Banana/") },
                fromName: row["from_name"], fromAddress: row["from_addr"] ?? "", isFromMe: flags.contains(.fromMe),
                toAddresses: recipients.to, ccAddresses: recipients.cc, subject: row["subject"] ?? "",
                snippet: row["snippet"] ?? "", hasAttachment: flags.contains(.hasAttachment), hasInvite: flags.contains(.hasInvite),
                listID: row["list_id"], hasUndeliveredIntent: pending.contains(pk), hasRefusedIntent: refused.contains(pk))
        }
    }

    static func tie(account: String, thread: String) -> Int64 {
        var hash: UInt64 = 14695981039346656037
        for byte in (account + "\u{0}" + thread).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int64(bitPattern: hash)
    }
}

#endif
