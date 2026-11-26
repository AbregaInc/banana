#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Disk-to-contract projection. Message bodies are read separately from the prepared
/// cache; opening a conversation never decompresses its HTML or runs text preparation.
struct MailConversationReader: Sendable {
    let stores: MailStores

    func conversation(_ id: MailConversationID) async throws -> MailConversation? {
        let account = id.account.lowercased()
        let indexed = try await stores.index.read { db -> MailConversation? in
            guard let thread = try Row.fetchOne(db, sql: """
                SELECT t.* FROM thread t JOIN account a ON a.account_pk=t.account_pk
                WHERE a.email=? AND t.gmail_id=?
                """, arguments: [account, id.thread]) else { return nil }
            let pk: Int64 = thread["thread_pk"]
            let flags = MailThreadFlags(rawValue: thread["flags"])
            func person(_ address: String, name: String? = nil) -> MailPerson {
                MailPerson(name: name, address: address, isMe: address.lowercased() == account,
                           isKnown: false, fromTheirMail: false)
            }
            var labels = Set<String>()
            var allTrash = true
            var allSpam = true
            let messages = try MailMessageImporter.mapFacts(threadPK: pk, in: db) { fact, recipients, row in
                labels.formUnion(fact.labels)
                allTrash = allTrash && fact.labels.contains("TRASH")
                allSpam = allSpam && fact.labels.contains("SPAM")
                let preparation: Int = row["prep_state"]
                return MailMessage(id: MailMessageID(account: account, message: fact.gmailID),
                    from: person(fact.fromAddress, name: fact.fromName),
                    to: fact.toAddresses.map { person($0) }, cc: fact.ccAddresses.map { person($0) },
                    bcc: recipients.bcc.map { person($0) }, replyTo: [], deliveredTo: nil,
                    listName: fact.listID, date: Date(timeIntervalSince1970: Double(fact.internalDate) / 1000),
                    isUnread: fact.labels.contains("UNREAD"), isMine: fact.isFromMe, firstLine: MailSnippet.display(fact.snippet),
                    body: preparation == 1 ? .preparing : .notOnDevice,
                    attachments: [], delivery: nil, draft: nil, isUnsentDraft: fact.labels.contains("DRAFT"))
            }
            let refs = try Self.userLabels(labels, accountPK: thread["account_pk"], in: db)
            // Snoozed until: only while it is away. A conversation back from its snooze keeps the time
            // in `wake_at` for its row ("Back from snooze") and is not snoozed.
            let returned: Int64? = thread["returned_at"]
            let wake: Int64? = returned == nil && !flags.contains(.inInbox) ? thread["wake_at"] : nil
            return MailConversation(id: MailConversationID(account: account, thread: id.thread), subject: thread["subject"] ?? "",
                labels: refs, inInbox: flags.contains(.inInbox), isStarred: flags.contains(.starred),
                isImportant: flags.contains(.important), isMuted: flags.contains(.muted),
                snoozedUntil: wake.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                system: !messages.isEmpty && allTrash ? .trash
                    : !messages.isEmpty && allSpam ? .spam : nil,
                messages: messages, invite: nil, unsubscribe: nil, draft: nil,
                newestIsMine: flags.contains(.lastIsMine), appliedThrough: 0)
        }
        guard var value = indexed else { return nil }
        // Primary-key batches avoid an account-wide blob scan and do not read body columns.
        let ids = value.messages.map(\.id.message)
        let newest = value.messages.filter { !$0.isUnsentDraft }.max { $0.date < $1.date }?.id
        for offset in stride(from: 0, to: ids.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + 50, ids.count)])
            let metadata = try await stores.blobs.read { db -> [String: Metadata] in
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT c.gmail_id,c.headers,c.structure,
                           (p.prep_version=? AND p.source_rev=c.content_rev) AS ready
                    FROM content c LEFT JOIN prepared p ON p.account=c.account AND p.gmail_id=c.gmail_id
                    WHERE c.account=? AND c.gmail_id IN (\(placeholders))
                    """, arguments: StatementArguments([MailHTMLPreparer.version, account] as [(any DatabaseValueConvertible)?] + batch.map { $0 as (any DatabaseValueConvertible)? }))
                var result: [String: Metadata] = [:]
                var files: [String: [String: String]] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT gmail_id,part_id,path FROM attachment WHERE account=? AND state=1 AND gmail_id IN (\(placeholders))",
                                            arguments: StatementArguments([account] as [(any DatabaseValueConvertible)?] + batch.map { $0 as (any DatabaseValueConvertible)? })) {
                    if let path: String = row["path"] { files[row["gmail_id"], default: [:]][row["part_id"]] = path }
                }
                for row in rows {
                    let headerData: Data = row["headers"], structureData: Data = row["structure"]
                    let headers = try JSONDecoder().decode([GmailHeader].self, from: MailBlobCodec.decode(headerData))
                    result[row["gmail_id"]] = Metadata(headers: MessageHeaders(payload: GmailPart(headers: headers)),
                        structure: try JSONDecoder().decode(MIMEStructure.self, from: MailBlobCodec.decode(structureData)),
                        ready: (row["ready"] as Bool?) == true, files: files[row["gmail_id"]] ?? [:])
                }
                return result
            }
            for index in offset..<min(offset + 50, ids.count) {
                guard let stored = metadata[ids[index]] else { continue }
                let messageID = value.messages[index].id
                if messageID == newest, !value.messages[index].isMine, value.system == nil {
                    value.unsubscribe = MailUnsubscribeRules.decide(headers: stored.headers)
                }
                value.messages[index].body = stored.ready ? .text : .preparing
                value.messages[index].replyTo = stored.headers.replyTo.mailboxes.map {
                    MailPerson(name: MailAddressRules.displayName($0.name, address: $0.address), address: $0.address,
                               isMe: $0.key == account, isKnown: false, fromTheirMail: false)
                }
                value.messages[index].deliveredTo = stored.headers.deliveredTo.mailboxes.first?.address
                value.messages[index].attachments = stored.structure.displayAttachments.map {
                    MailAttachment(id: MailAttachmentID(message: messageID, part: $0.partID), name: $0.name,
                        mimeType: $0.mimeType, typeMismatch: false, bytes: $0.size ?? 0,
                        localFile: stored.files[$0.partID].flatMap(localFile),
                        isInline: $0.isInline, isExecutable: MailAttachmentKind.of(name: $0.name, mimeType: $0.mimeType).isProgram)
                }
                if let invite = stored.structure.invite, let uid = invite.uid, !uid.isEmpty {
                    value.invite = MailInvite(method: MailInvite.Method(rawValue: invite.method?.lowercased() ?? "other") ?? .other, uid: uid)
                }
            }
        }
        return value
    }

    private struct Metadata: Sendable {
        var headers: MessageHeaders
        var structure: MIMEStructure
        var ready: Bool
        /// Part id to the relative path of the file kept for it.
        var files: [String: String]
    }

    /// The effective message labels already include pending edits. Read just their current
    /// catalog metadata, using the unique account / provider-id index. Binding the IDs as one
    /// JSON array keeps the statement fixed even for threads with thousands of distinct labels.
    private static func userLabels(_ ids: Set<String>, accountPK: Int64, in db: Database) throws -> [MailLabelRef] {
        guard !ids.isEmpty else { return [] }
        let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        let statement = try db.cachedStatement(sql: """
            SELECT gmail_id,name,background_color FROM label
            WHERE account_pk=? AND kind=1 AND gmail_id IN (SELECT value FROM json_each(?))
            """)
        return try Row.fetchAll(statement, arguments: [accountPK, encoded]).map { row in
            MailLabelRef(id: row["gmail_id"], name: row["name"], colorHex: row["background_color"])
        }.sorted { $0.id < $1.id }
    }

    /// An attachment kept on this device: only if the file is still there and its path stays in the attachment directory.
    private func localFile(_ path: String) -> URL? {
        guard MailInlinePictures.isSafe(path) else { return nil }
        let url = stores.directories.attachments.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

#endif
