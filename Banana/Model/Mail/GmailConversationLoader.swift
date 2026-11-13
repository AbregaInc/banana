#if !BANANA_PUBLIC
import Foundation
import GRDB
import CryptoKit

/// Read-only provider ingestion. The index is promoted only after original content
/// and its prepared representation are committed. No sync checkpoint is advanced.
actor GmailConversationLoader {
    let stores: MailStores
    let writer: MailWriter
    let api: any GmailAPI
    let token: @Sendable (String) async throws -> String
    enum Failure: Error, Equatable { case wrongAccount, malformed, missingMessage, incompleteBody }
    /// Preparations made because someone asked for the body (an open, a Load control) while its
    /// original was here and its prepared form was not: the cases where an open waits on the
    /// preparer. Everything else is prepared ahead (`preparedAhead`).
    private(set) var preparedOnRequest = 0
    private(set) var preparedAhead = 0

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
            preparedOnRequest += 1
            guard try await blobs.prepare(account: account, messageID: id.message, at: Int64(Date().timeIntervalSince1970 * 1000)) != nil else { throw Failure.incompleteBody }
            try await promoteCached(id, thread: identity.0, rowID: identity.1)
            return
        }
        try Task.checkCancellation()
        let access = try await token(account)
        let profile = try await api.profile(token: access)
        guard profile.emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        guard let floor = profile.historyId else { throw Failure.malformed }
        let message = try await api.message(token: access, id: id.message, format: .full)
        let fetched = try await complete(message, id: id, thread: identity.0, rowID: identity.1, floor: floor, access: { access })
        try await commit([(fetched, identity.1, identity.0)], account: account)
    }

    /// Optional background verification, independent of body availability. Old cached
    /// structures gain fingerprints too; failures leave every original attachment visible.
    func verifyCalendarCopies(_ id: MailMessageID) async throws {
        let account = id.account.lowercased()
        let original = try await stores.blobs.read { db -> (Data, String)? in
            guard let row = try Row.fetchOne(db, sql: "SELECT structure,thread_id FROM content WHERE account=? AND gmail_id=? AND level=2",
                                            arguments: [account, id.message]) else { return nil }
            return (row[0], row[1])
        }
        guard let original else { return }
        var structure = try JSONDecoder().decode(MIMEStructure.self, from: MailBlobCodec.decode(original.0))
        let candidates = structure.uncheckedCalendarCopies
        guard !candidates.isEmpty else { return }
        let access = try await token(account)
        guard try await api.profile(token: access).emailAddress?.lowercased() == account else { throw Failure.wrongAccount }
        let pictures = MailInlinePictures(stores: stores, api: api, token: { _ in access })
        for part in candidates {
            try Task.checkCancellation()
            let originalPart = MailAttachmentFetcher.find(partID: part.partID, in: structure.root)
            guard let originalPart,
                  let bytes = await pictures.bytes(of: originalPart, account: account, message: id.message, limit: 256 * 1024),
                  bytes.count == part.size,
                  let index = structure.attachments.firstIndex(where: { $0.partID == part.partID }) else { return }
            structure.attachments[index].contentSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        try Task.checkCancellation()
        let encoded = try MailBlobCodec.encode(JSONEncoder().encode(structure))
        let changed = try await stores.blobs.write { db in
            // A refresh may have replaced the provider handles while requests were in flight.
            try db.execute(sql: "UPDATE content SET structure=?,bytes=bytes-length(structure)+? WHERE account=? AND gmail_id=? AND structure=?",
                           arguments: [encoded, encoded.count, account, id.message, original.0])
            return db.changesCount > 0
        }
        if changed {
            _ = try await writer.transact { _ in
                var change = MailStoreChange()
                change.conversations.insert(MailConversationID(account: account, thread: original.1))
                return change
            }
        }
    }

    /// Messages Banana Cloud already holds (MAIL-CLOUD-SYNC §5a), stored as `body` stores a read:
    /// content and its prepared form first, then one index transaction for all of them. Each is
    /// applied at its own `historyId` (the cloud's position for its labels), so the stale-read rule
    /// holds. A message this device holds no row for is skipped; one whose text cannot be stored
    /// here gets its headers only (`CloudStored.headersOnly`) and is left to the per-message path.
    func storeCloud(_ messages: [GmailMessage], account rawAccount: String) async throws -> CloudStored {
        let account = rawAccount.lowercased()
        let ids = messages.compactMap(\.id)
        let rows = try await stores.index.read { db -> [String: (String, Int64, Int)] in
            var out: [String: (String, Int64, Int)] = [:]
            for id in ids {
                if let row = try Row.fetchOne(db, sql: """
                    SELECT t.gmail_id,m.msg_pk,m.fetch_state FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
                    JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id=?
                    """, arguments: [account, id]) { out[id] = (row[0], row[1], row[2]) }
            }
            return out
        }
        func headersOnly(_ message: GmailMessage) -> (FetchedMessage, Int64, String)? {
            guard let messageID = message.id, let row = rows[messageID], let floor = message.historyId,
                  message.threadId == row.0, message.payload?.headers != nil else { return nil }
            return (FetchedMessage(wire: message, floor: floor, headers: MessageHeaders(payload: message.payload), structure: nil), row.1, row.0)
        }
        var problems: [String] = []
        // Mail known only by id is not listed until its headers are in, and they came with this
        // batch: they go in first, in one transaction, so new mail is on the list now rather than
        // after every body of the batch has been prepared.
        var listedFirst = Set<String>()
        let stubs = messages.filter { $0.id.flatMap { rows[$0]?.2 } == 0 }.compactMap(headersOnly)
        if !stubs.isEmpty {
            let early = try await commitCloud([], headed: stubs, account: account)
            listedFirst = Set(early.headersOnly)
            problems += early.problems
        }
        var ready: [(FetchedMessage, Int64, String)] = [], headed: [(FetchedMessage, Int64, String)] = []
        var unstored: [String] = []
        for message in messages {
            try Task.checkCancellation()
            guard let messageID = message.id, let row = rows[messageID], let floor = message.historyId else { continue }
            let id = MailMessageID(account: account, message: messageID)
            do {
                let fetched = try await complete(message, id: id, thread: row.0, rowID: row.1, floor: floor,
                                                 access: { [token] in try await token(account) })
                ready.append((fetched, row.1, row.0))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One message that cannot be stored here (malformed, too large, a part that would
                // not load) never holds back the rest of the batch. Its headers still go in, so its
                // row is listed; its text is left to the per-message path.
                problems.append(Self.describe(error))
                if listedFirst.contains(messageID) { unstored.append(messageID) }
                else if let item = headersOnly(message) { headed.append(item) }
            }
        }
        var result = try await commitCloud(ready, headed: headed, account: account)
        result.headersOnly += unstored
        result.problems = problems + result.problems
        return result
    }

    /// What `storeCloud` did with a batch: text stored, headers only, and why any could not be stored
    /// (error kinds only: no ids, addresses or content).
    struct CloudStored: Equatable, Sendable {
        var stored: [String] = []
        var headersOnly: [String] = []
        var problems: [String] = []
    }

    /// An error's kind for the log: never an id, address, URL, SQL or content.
    static func describe(_ error: Error) -> String {
        if let gmail = error as? GmailError { return String(describing: gmail) }
        if let database = error as? DatabaseError { return "sqlite code=\(database.extendedResultCode.rawValue)" }
        if let url = error as? URLError { return "URLError code=\(url.code.rawValue)" }
        let type = String(reflecting: Swift.type(of: error)), name = String(describing: error)
        // A case without a payload names itself; anything else is its type and code only.
        return name.allSatisfy { $0.isLetter || $0.isNumber } ? "\(type).\(name)" : "\(type); code=\((error as NSError).code)"
    }

    /// `commit` for a cloud batch, each message in its own savepoint: one the index refuses is left
    /// out without undoing the others.
    private func commitCloud(_ ready: [(fetched: FetchedMessage, rowID: Int64, thread: String)],
                             headed: [(fetched: FetchedMessage, rowID: Int64, thread: String)],
                             account: String) async throws -> CloudStored {
        guard !ready.isEmpty || !headed.isEmpty else { return CloudStored() }
        try Task.checkCancellation()
        return try await writer.transactValue { db in
            var change = MailStoreChange(), result = CloudStored()
            for (full, items) in [(true, ready), (false, headed)] {
                for item in items {
                    guard let id = item.fetched.wire.id else { continue }
                    var applied = MailStoreChange()
                    do {
                        try db.inSavepoint {
                            applied = try MailMessageImporter.apply(item.fetched, account: account, myAddresses: [account], in: db)
                            if full {
                                try db.execute(sql: "UPDATE message SET fetch_state=2,prep_state=2 WHERE msg_pk=? AND gmail_id=? AND account_pk=(SELECT account_pk FROM account WHERE email=?)", arguments: [item.rowID, id, account])
                            }
                            return .commit
                        }
                    } catch {
                        result.problems.append(Self.describe(error))
                        continue
                    }
                    change.formUnion(applied)
                    change.conversations.insert(MailConversationID(account: account, thread: item.thread))
                    if full { result.stored.append(id) } else { result.headersOnly.append(id) }
                }
            }
            return (result, change)
        }
    }

    /// A `full` message made whole (external body parts read through `attachment`), its content and
    /// prepared form committed to `blobs.sqlite`.
    private func complete(_ fetched: GmailMessage, id: MailMessageID, thread: String, rowID: Int64, floor: UInt64,
                          access: () async throws -> String) async throws -> FetchedMessage {
        let account = id.account.lowercased(), blobs = MailBlobStore(stores: stores)
        var message = fetched
        guard message.id == id.message, message.threadId == thread, let payload = message.payload, let mime = payload.mimeType, !mime.isEmpty else { throw Failure.malformed }
        var extraction = MIMEStructure.extract(payload)
        guard extraction.structure.cut == nil, !extraction.bodyTooLarge, !extraction.malformedBody else { throw Failure.incompleteBody }
        if !extraction.missingBodyPartIDs.isEmpty {
            let access = try await access()
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
        try await blobs.put(message, account: account, extraction: extraction, ftsRowID: rowID, at: at)
        guard try await blobs.prepare(account: account, messageID: id.message, at: at) != nil else { throw Failure.incompleteBody }
        preparedAhead += 1
        return FetchedMessage(wire: message, floor: floor, headers: MessageHeaders(payload: message.payload), structure: extraction.structure)
    }

    /// One index transaction for messages whose content is committed: rows, labels (stale-read
    /// rule), `fetch_state = 2, prep_state = 2`.
    private func commit(_ ready: [(fetched: FetchedMessage, rowID: Int64, thread: String)], account: String) async throws {
        guard !ready.isEmpty else { return }
        try Task.checkCancellation()
        _ = try await writer.transact { db in
            var change = MailStoreChange()
            for item in ready {
                change.formUnion(try MailMessageImporter.apply(item.fetched, account: account, myAddresses: [account], in: db))
                try db.execute(sql: "UPDATE message SET fetch_state=2,prep_state=2 WHERE msg_pk=? AND gmail_id=? AND account_pk=(SELECT account_pk FROM account WHERE email=?)", arguments: [item.rowID, item.fetched.wire.id, account])
                change.conversations.insert(MailConversationID(account: account, thread: item.thread))
            }
            return change
        }
    }
    /// Prepares an original this device already stores whose prepared form is missing or was made
    /// by an older preparer (`MailReprepare`), and tells open screens. False when there is no
    /// stored original, or it cannot be prepared.
    func prepareStored(_ id: MailMessageID) async throws -> Bool {
        let account = id.account.lowercased()
        guard let identity = try await stores.index.read({ db -> (String, Int64)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT t.gmail_id,m.msg_pk FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
                JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id=?
                """, arguments: [account, id.message]) else { return nil }
            return (row[0], row[1])
        }) else { return false }
        guard try await MailBlobStore(stores: stores).prepare(account: account, messageID: id.message,
                                                              at: Int64(Date().timeIntervalSince1970 * 1000)) != nil else { return false }
        preparedAhead += 1
        try await promoteCached(id, thread: identity.0, rowID: identity.1)
        return true
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
