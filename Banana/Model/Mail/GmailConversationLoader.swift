#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Read-only provider ingestion. The index is promoted only after original content
/// and its prepared representation are committed. No sync checkpoint is advanced.
actor GmailConversationLoader {
    let stores: MailStores
    let writer: MailWriter
    let api: any GmailAPI
    let token: @Sendable (String) async throws -> String
    enum Failure: Error, Equatable { case wrongAccount, malformed, missingMessage, incompleteBody }

    init(stores: MailStores, writer: MailWriter, api: any GmailAPI,
         token: @escaping @Sendable (String) async throws -> String) {
        self.stores = stores; self.writer = writer; self.api = api; self.token = token
    }

    func thread(_ id: MailConversationID) async throws -> [MailMessageID] {
        let account = id.account.lowercased()
        let access = try await token(account)
        let profile = try await api.profile(token: access)
        guard profile.emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        guard let floor = profile.historyId else { throw Failure.malformed }
        let thread = try await api.thread(token: access, id: id.thread, format: .header)
        guard thread.id == id.thread, let messages = thread.messages else { throw Failure.malformed }
        var seen = Set<String>()
        for message in messages {
            guard let key = message.id, !key.isEmpty, seen.insert(key).inserted,
                  message.threadId == id.thread else { throw Failure.malformed }
        }
        for offset in stride(from: 0, to: messages.count, by: 20) {
            try Task.checkCancellation()
            let batch = Array(messages[offset..<min(offset + 20, messages.count)])
            _ = try await writer.transact { db in
                var changes = MailStoreChange()
                for message in batch {
                    changes.formUnion(try MailMessageImporter.apply(
                        FetchedMessage(wire: message, floor: floor, headers: MessageHeaders(payload: message.payload), structure: nil),
                        account: account, myAddresses: [account], in: db))
                }
                return changes
            }
        }
        return messages.map { MailMessageID(account: account, message: $0.id!) }
    }

    func body(_ id: MailMessageID) async throws {
        let account = id.account.lowercased(), blobs = MailBlobStore(stores: stores)
        let identity = try await stores.index.read { db -> (String, Int64, Bool)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT t.gmail_id,m.msg_pk,(m.fetch_state=2 AND m.prep_state=2) FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
                JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id=?
                """, arguments: [account, id.message]) else { return nil }
            return (row[0], row[1], row[2])
        }
        guard let identity else { throw Failure.missingMessage }
        if try await blobs.prepared(account: account, messageID: id.message) != nil {
            if !identity.2 { try await promoteCached(id, thread: identity.0, rowID: identity.1) }
            return
        }
        let hasOriginal = try await stores.blobs.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM content WHERE account=? AND gmail_id=? AND level=2)",
                              arguments: [account, id.message]) ?? false
        }
        if hasOriginal {
            guard try await blobs.prepare(account: account, messageID: id.message, at: Int64(Date().timeIntervalSince1970 * 1000)) != nil else { throw Failure.incompleteBody }
            try await promoteCached(id, thread: identity.0, rowID: identity.1)
            return
        }
        try Task.checkCancellation()
        let access = try await token(account)
        let profile = try await api.profile(token: access)
        guard profile.emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        guard let floor = profile.historyId else { throw Failure.malformed }
        var message = try await api.message(token: access, id: id.message, format: .full)
        guard message.id == id.message, message.threadId == identity.0, let payload = message.payload, let mime = payload.mimeType, !mime.isEmpty else { throw Failure.malformed }
        var extraction = MIMEStructure.extract(payload)
        guard extraction.structure.cut == nil, !extraction.bodyTooLarge, !extraction.malformedBody else { throw Failure.incompleteBody }
        if !extraction.missingBodyPartIDs.isEmpty {
            var parts: [String: MIMEStructure.Part] = [:]
            func visit(_ part: MIMEStructure.Part) {
                parts[part.partID] = part
                for child in part.children { visit(child) }
            }
            visit(extraction.structure.root)
            var downloaded: [String: GmailPartBody] = [:]
            var encodedBytes = 0
            let limit = ((MIMELimits().bodyBytes + 2) / 3) * 4
            for key in Set(extraction.missingBodyPartIDs).sorted() {
                try Task.checkCancellation()
                guard let part = parts[key], let attachment = part.attachmentID,
                      (part.size ?? 0) >= 0, (part.size ?? 0) <= MIMELimits().bodyBytes else { throw Failure.incompleteBody }
                let body = try await api.attachment(token: access, messageID: id.message, attachmentID: attachment)
                guard let data = body.data, (body.size ?? 0) >= 0,
                      (body.size ?? 0) <= MIMELimits().bodyBytes else { throw Failure.incompleteBody }
                encodedBytes += data.utf8.count
                guard encodedBytes <= limit else { throw Failure.incompleteBody }
                downloaded[key] = body
            }
            func hydrated(_ part: GmailPart, path: String) -> GmailPart {
                var result = part
                if let body = downloaded[part.partId ?? path] { result.body = body }
                result.parts = part.parts?.enumerated().map { hydrated($0.element, path: path + "." + String($0.offset)) }
                return result
            }
            message.payload = hydrated(payload, path: "0")
            extraction = MIMEStructure.extract(message.payload!)
        }
        guard extraction.structure.cut == nil, !extraction.bodyTooLarge, !extraction.malformedBody,
              extraction.missingBodyPartIDs.isEmpty else { throw Failure.incompleteBody }
        try Task.checkCancellation()
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        try await blobs.put(message, account: account, extraction: extraction, ftsRowID: identity.1, at: at)
        guard try await blobs.prepare(account: account, messageID: id.message, at: at) != nil else { throw Failure.incompleteBody }
        try Task.checkCancellation()
        let fetched = FetchedMessage(wire: message, floor: floor, headers: MessageHeaders(payload: message.payload), structure: extraction.structure)
        _ = try await writer.transact { db in
            var change = try MailMessageImporter.apply(fetched, account: account, myAddresses: [account], in: db)
            try db.execute(sql: "UPDATE message SET fetch_state=2,prep_state=2 WHERE msg_pk=? AND gmail_id=? AND account_pk=(SELECT account_pk FROM account WHERE email=?)", arguments: [identity.1, id.message, account])
            change.conversations.insert(MailConversationID(account: account, thread: identity.0))
            return change
        }
    }
    private func promoteCached(_ id: MailMessageID, thread: String, rowID: Int64) async throws {
        try Task.checkCancellation()
        let account = id.account.lowercased()
        _ = try await writer.transact { db in
            try db.execute(sql: "UPDATE message SET fetch_state=2,prep_state=2 WHERE msg_pk=? AND gmail_id=? AND account_pk=(SELECT account_pk FROM account WHERE email=?)",
                           arguments: [rowID, id.message, account])
            return MailStoreChange(conversations: [MailConversationID(account: account, thread: thread)])
        }
    }

}

#endif
