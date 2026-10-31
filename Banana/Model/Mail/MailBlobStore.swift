#if !BANANA_PUBLIC
import Foundation
import GRDB

struct MailStoredContent: Sendable {
    var revision: Int64
    var headers: [GmailHeader]
    var structure: MIMEStructure
    var html: String?
    var plain: String?
}

/// Original provider content. Preparation and index promotion happen only after this commit.
struct MailBlobStore: Sendable {
    let stores: MailStores
    enum Failure: Error { case incomplete, invalidIdentity, corrupt, removed }

    func put(_ message: GmailMessage, account: String, extraction: MIMEExtraction,
             ftsRowID: Int64, at: Int64) async throws {
        guard let id = message.id, !id.isEmpty, let thread = message.threadId, !thread.isEmpty,
              let date = message.internalDate, MailAddressRules.isValid(account), ftsRowID > 0 else { throw Failure.invalidIdentity }
        guard let headers = message.payload?.headers, extraction.structure.cut == nil,
              !extraction.bodyTooLarge, !extraction.malformedBody, extraction.missingBodyPartIDs.isEmpty else { throw Failure.incomplete }
        let account = account.lowercased()
        let encoder = JSONEncoder()
        let headerData = try MailBlobCodec.encode(encoder.encode(headers))
        let structureData = try MailBlobCodec.encode(encoder.encode(extraction.structure))
        let html = try extraction.html.map { try MailBlobCodec.encode(Data($0.utf8)) }
        let plain = try extraction.plain.map { try MailBlobCodec.encode(Data($0.utf8)) }
        let bytes = headerData.count + structureData.count + (html?.count ?? 0) + (plain?.count ?? 0)
        try await stores.blobs.write { db in
            // Keep this check inside the serialized blob write. If index deletion
            // happens after the check, its following cleanup waits for this write;
            // if cleanup already ran, the retained tombstone rejects this late body.
            // Use the existing serialized index connection for this tiny read.
            // Acquiring a pooled reader here can block behind unrelated list
            // snapshots while holding the blob writer. No extra connection/cache
            // is needed. Index writers must never synchronously wait on blobs.
            let removed = try stores.index.writeWithoutTransaction { index in
                try Bool.fetchOne(index, sql: "SELECT EXISTS(SELECT 1 FROM tombstone t JOIN account a ON a.account_pk=t.account_pk WHERE a.email=? AND t.gmail_id=?)",
                    arguments: [account, id]) == true
            }
            guard !removed else { throw Failure.removed }
            try db.execute(sql: """
                INSERT INTO content(account,gmail_id,thread_id,internal_date,size_estimate,snippet,fts_rowid,
                    headers,structure,html,plain,level,bytes,stored_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,2,?,?)
                ON CONFLICT(account,gmail_id) DO UPDATE SET
                    thread_id=excluded.thread_id,internal_date=excluded.internal_date,size_estimate=excluded.size_estimate,
                    snippet=excluded.snippet,headers=excluded.headers,structure=excluded.structure,
                    html=excluded.html,plain=excluded.plain,level=excluded.level,bytes=excluded.bytes,stored_at=excluded.stored_at,
                    content_rev=content.content_rev+1
                """, arguments: [account, id, thread, date, message.sizeEstimate, message.snippet, ftsRowID,
                    headerData, structureData, html, plain, bytes, at])
            try db.execute(sql: "DELETE FROM prepared WHERE account=? AND gmail_id=?", arguments: [account, id])
        }
    }

    func content(account: String, messageID: String) async throws -> MailStoredContent? {
        try await stores.blobs.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT headers,structure,html,plain,content_rev FROM content WHERE account=? AND gmail_id=? AND level=2",
                                            arguments: [account.lowercased(), messageID]) else { return nil }
            let decoder = JSONDecoder()
            let headers: Data = row[0], structure: Data = row[1]
            func string(_ data: Data?) throws -> String? {
                guard let data else { return nil }
                guard let text = String(data: try MailBlobCodec.decode(data), encoding: .utf8) else { throw Failure.corrupt }
                return text
            }
            return MailStoredContent(revision: row[4], headers: try decoder.decode([GmailHeader].self, from: MailBlobCodec.decode(headers)),
                structure: try decoder.decode(MIMEStructure.self, from: MailBlobCodec.decode(structure)),
                html: try string(row[2]), plain: try string(row[3]))
        }
    }

    /// Nonisolated async work stays off the main actor. Reading never invokes HTML parsing.
    func prepare(account: String, messageID: String, at: Int64) async throws -> MailPreparedBody? {
        guard let content = try await content(account: account, messageID: messageID) else { return nil }
        try Task.checkCancellation()
        let value = try MailHTMLPreparer.prepare(plain: content.plain, html: content.html)
        try Task.checkCancellation()
        return try await savePrepared(value, sourceRevision: content.revision, account: account, messageID: messageID, at: at) ? value : nil
    }

    func savePrepared(_ value: MailPreparedBody, sourceRevision: Int64, account: String, messageID: String, at: Int64) async throws -> Bool {
        let body = try MailBlobCodec.encode(JSONEncoder().encode(value))
        let text = value.text.blocks.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
        let textData = try MailBlobCodec.encode(Data(text.utf8))
        return try await stores.blobs.write { db in
            try db.execute(sql: """
                INSERT INTO prepared(account,gmail_id,prep_version,body,text,bytes,made_at,source_rev)
                SELECT account,gmail_id,?,?,?,?,?,content_rev FROM content
                WHERE account=? AND gmail_id=? AND content_rev=?
                ON CONFLICT(account,gmail_id) DO UPDATE SET prep_version=excluded.prep_version,
                    body=excluded.body,text=excluded.text,bytes=excluded.bytes,made_at=excluded.made_at,source_rev=excluded.source_rev
                """, arguments: [value.version, body, textData, body.count + textData.count, at, account.lowercased(), messageID, sourceRevision])
            return db.changesCount == 1
        }
    }

    func prepared(account: String, messageID: String) async throws -> MailPreparedBody? {
        try await stores.blobs.read { db in
            guard let data = try Data.fetchOne(db, sql: """
                SELECT p.body FROM prepared p JOIN content c ON c.account=p.account AND c.gmail_id=p.gmail_id
                WHERE p.account=? AND p.gmail_id=? AND p.prep_version=? AND p.source_rev=c.content_rev
                """, arguments: [account.lowercased(), messageID, MailHTMLPreparer.version]) else { return nil }
            let value = try JSONDecoder().decode(MailPreparedBody.self, from: MailBlobCodec.decode(data))
            guard value.version == MailHTMLPreparer.version else { return nil }
            return value
        }
    }
}

#endif
