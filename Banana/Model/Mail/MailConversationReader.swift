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
            let facts = try MailMessageImporter.facts(threadPK: pk, in: db)
            let flags = MailThreadFlags(rawValue: thread["flags"])
            let rows = try Row.fetchAll(db, sql: "SELECT gmail_id,recipients,prep_state FROM message WHERE thread_pk=?", arguments: [pk])
            var bcc: [String: [String]] = [:], states: [String: Int] = [:]
            for row in rows {
                let message: String = row["gmail_id"]
                states[message] = row["prep_state"]
                if let json: String = row["recipients"] {
                    bcc[message] = try JSONDecoder().decode(MailMessageImporter.Recipients.self, from: Data(json.utf8)).bcc
                }
            }
            func person(_ address: String, name: String? = nil) -> MailPerson {
                MailPerson(name: name, address: address, isMe: address.lowercased() == account,
                           isKnown: false, fromTheirMail: false)
            }
            let labels = Set(facts.flatMap(\.labels))
            let labelRows = try Row.fetchAll(db, sql: "SELECT gmail_id,name,background_color FROM label WHERE account_pk=? AND kind=1", arguments: [thread["account_pk"] as Int64])
            let refs: [MailLabelRef] = labelRows.compactMap { row in
                let label: String = row["gmail_id"]
                guard labels.contains(label) else { return nil }
                return MailLabelRef(id: label, name: row["name"], colorHex: row["background_color"])
            }.sorted { $0.id < $1.id }
            let messages = facts.map { fact in
                MailMessage(id: MailMessageID(account: account, message: fact.gmailID),
                    from: person(fact.fromAddress, name: fact.fromName),
                    to: fact.toAddresses.map { person($0) }, cc: fact.ccAddresses.map { person($0) },
                    bcc: (bcc[fact.gmailID] ?? []).map { person($0) }, replyTo: [], deliveredTo: nil,
                    listName: fact.listID, date: Date(timeIntervalSince1970: Double(fact.internalDate) / 1000),
                    isUnread: fact.labels.contains("UNREAD"), isMine: fact.isFromMe, firstLine: fact.snippet,
                    body: states[fact.gmailID] == 1 ? .preparing : .notOnDevice,
                    attachments: [], delivery: nil, draft: nil)
            }
            let wake: Int64? = thread["wake_at"]
            return MailConversation(id: MailConversationID(account: account, thread: id.thread), subject: thread["subject"] ?? "",
                labels: refs, inInbox: flags.contains(.inInbox), isStarred: flags.contains(.starred),
                isImportant: flags.contains(.important), isMuted: flags.contains(.muted),
                snoozedUntil: wake.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                system: !facts.isEmpty && facts.allSatisfy { $0.labels.contains("TRASH") } ? .trash
                    : !facts.isEmpty && facts.allSatisfy { $0.labels.contains("SPAM") } ? .spam : nil,
                messages: messages, invite: nil, unsubscribe: nil, draft: nil,
                newestIsMine: flags.contains(.lastIsMine), appliedThrough: 0)
        }
        guard var value = indexed else { return nil }
        // Primary-key batches avoid an account-wide blob scan and do not read body columns.
        let ids = value.messages.map(\.id.message)
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
                for row in rows {
                    let headerData: Data = row["headers"], structureData: Data = row["structure"]
                    let headers = try JSONDecoder().decode([GmailHeader].self, from: MailBlobCodec.decode(headerData))
                    result[row["gmail_id"]] = Metadata(headers: MessageHeaders(payload: GmailPart(headers: headers)),
                        structure: try JSONDecoder().decode(MIMEStructure.self, from: MailBlobCodec.decode(structureData)),
                        ready: (row["ready"] as Bool?) == true)
                }
                return result
            }
            for index in offset..<min(offset + 50, ids.count) {
                guard let stored = metadata[ids[index]] else { continue }
                let messageID = value.messages[index].id
                value.messages[index].body = stored.ready ? .text : .preparing
                value.messages[index].replyTo = stored.headers.replyTo.mailboxes.map {
                    MailPerson(name: MailAddressRules.displayName($0.name, address: $0.address), address: $0.address,
                               isMe: $0.key == account, isKnown: false, fromTheirMail: false)
                }
                value.messages[index].deliveredTo = stored.headers.deliveredTo.mailboxes.first?.address
                value.messages[index].attachments = stored.structure.attachments.map {
                    MailAttachment(id: MailAttachmentID(message: messageID, part: $0.partID), name: $0.name,
                        mimeType: $0.mimeType, typeMismatch: false, bytes: $0.size ?? 0, localFile: nil,
                        isInline: $0.isInline, isExecutable: false)
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
    }
}

#endif
