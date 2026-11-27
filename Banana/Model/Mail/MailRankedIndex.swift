#if !BANANA_PUBLIC
import Darwin
import Foundation
import GRDB
import MailTantivy
import UniformTypeIdentifiers

/// Exclusively owned, rebuildable cache. SQLite is authoritative for grants, identity and content.
actor MailRankedIndex {
    private let stores: MailStores
    private let writer: MailWriter
    private var engine: TantivyIndex?
    private var lease: FileHandle?
    private var working = false
    private var revision: UInt64 = 0
    private(set) var ready = false
    private static let fields = ["subject", "sender", "recipients", "snippet", "body", "filename", "attachments"]
    init(_ stores: MailStores, writer: MailWriter? = nil) {
        self.stores = stores
        self.writer = writer ?? MailWriter(stores: stores, sink: nil)
    }

    struct Document: Sendable {
        let id, account, date: Int64
        let subject, sender, recipients, snippet, body: String
        let files: [String]
        /// What the message's attached files say (MailCloudText), when the cloud has read them.
        var attachments = ""

        var native: TantivyDocumentFields {
            var fields = [
                DocumentField(name: "id", value: .u64(UInt64(id))),
                DocumentField(name: "account", value: .u64(UInt64(account))),
            ]
            for (name, value) in zip(
                MailRankedIndex.fields, [subject, sender, recipients, snippet, body, files.joined(separator: " "), attachments])
            {
                fields.append(DocumentField(name: name, value: .text(value)))
            }
            return TantivyDocumentFields(fields: fields)
        }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
    static func words(_ text: String) -> [String] {
        folded(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func open(_ path: URL) throws -> TantivyIndex {
        let schema = TantivySchemaBuilder()
        for field in ["id", "account"] {
            schema.addU64Field(
                name: field,
                options: NumericFieldOptions(indexed: true, stored: false, fast: field == "id", fieldnorms: false))
        }
        for field in fields {
            schema.addTextField(
                name: field,
                options: TextFieldOptions(
                    tokenizer: ["sender", "recipients", "filename"].contains(field) ? .default : .enStem,
                    record: .withFreqs, stored: false, fast: false, fieldnorms: field != "attachments"))
        }
        return try TantivyIndex.newWithSchema(path: path.path, schemaBuilder: schema)
    }

    /// A separate OS lease guards cache replacement as well as the library writer. Process exit releases it.
    private func lock(_ directory: URL) throws {
        guard lease == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        lease = handle
    }

    /// Batched reads never hold a mailbox transaction across suspension. Concurrent edits go into the queues.
    private static func documents(_ db: Database, where condition: String, _ arguments: StatementArguments) throws
        -> [Document]
    {
        try Row.fetchAll(
            db,
            sql: """
                SELECT m.msg_pk,m.account_pk,coalesce(m.internal_date,0),h.subject,h.sender,h.recipients,h.snippet,
                  CASE WHEN m.fts_state=2 THEN p.text END,
                  (SELECT json_group_object(x.part_id,x.filename) FROM blobs.attachment x WHERE x.account=a.email AND x.gmail_id=m.gmail_id
                   AND x.inline=0 AND length(x.filename)>0),c.structure,at.text
                FROM idx.message m JOIN idx.account a ON a.account_pk=m.account_pk
                JOIN idx.mail_header_search h ON h.rowid=m.msg_pk
                LEFT JOIN blobs.content c ON c.account=a.email AND c.gmail_id=m.gmail_id
                LEFT JOIN blobs.prepared p ON p.account=a.email AND p.gmail_id=m.gmail_id
                LEFT JOIN blobs.attachment_text at ON at.account=a.email AND at.gmail_id=m.gmail_id
                WHERE \(condition)
                """, arguments: arguments
        ).map { row in
            let blob: Data? = row[7]
            let text = blob.flatMap { try? MailBlobCodec.decode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            struct FileList: Decodable {
                struct File: Decodable {
                    let partID, name: String
                    let isInline: Bool
                }
                let attachments: [File]
            }
            // Original MIME metadata can outlive individual attachment-cache entries.
            let structure: Data? = row[9]
            let original = structure.flatMap {
                try? JSONDecoder().decode(FileList.self, from: MailBlobCodec.decode($0))
            }
            let names: String = row[8]
            var parts = try JSONDecoder().decode([String: String].self, from: Data(names.utf8))
            for file in original?.attachments ?? [] {
                parts[file.partID] = file.isInline || file.name.isEmpty ? nil : file.name
            }
            let attached: Data? = row[10]
            var document = Document(
                id: row[0], account: row[1], date: row[2], subject: row[3] ?? "", sender: row[4] ?? "",
                recipients: row[5] ?? "", snippet: row[6] ?? "", body: String(text.prefix(16_000)),
                files: Array(Set(parts.values)).sorted())
            document.attachments = attached.flatMap { try? MailBlobCodec.decode($0) }
                .map { String(String(decoding: $0, as: UTF8.self).prefix(MailCloudText.charactersMost)) } ?? ""
            return document
        }
    }

    private static func hints(_ docs: [Document], in db: Database) throws {
        let insert = try db.cachedStatement(
            sql: "INSERT INTO ranked_hint(msg,kind,term,account,date) VALUES(?,?,?,?,?)")
        for doc in docs {
            for (kind, terms) in [(0, Set(words(doc.sender))), (1, Set(doc.files.map(folded)))] {
                for term in terms { try insert.execute(arguments: [doc.id, kind, term, doc.account, doc.date]) }
            }
        }
    }

    private func openOrBuild() async throws {
        let directory = stores.directories.cache.appendingPathComponent("RankedMail.noindex", isDirectory: true)
        try lock(directory)
        // v3: the attachments field, unnormalised and ranked on its own. Other versions are rebuilt.
        let path = directory.appendingPathComponent("v3", isDirectory: true)
        let retired = ["v1", "v2"].map { directory.appendingPathComponent($0, isDirectory: true) }
        let marker = directory.appendingPathComponent("complete")
        let epoch = try await stores.searchReader.read { db in
            guard
                let value = try String.fetchOne(
                    db,
                    sql:
                        "SELECT idx.ranked_epoch.id || blobs.ranked_epoch.id FROM idx.ranked_epoch,blobs.ranked_epoch")
            else { throw CocoaError(.fileReadCorruptFile) }
            return "3:" + value
        }
        let fm = FileManager.default
        if (try? String(contentsOf: marker, encoding: .utf8)) == epoch,
            fm.fileExists(atPath: path.appendingPathComponent("meta.json").path), let existing = try? Self.open(path)
        {
            engine = existing
            return
        }
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
        for old in retired where fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
        if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
        let index = try Self.open(path)
        try await writer.maintainSearchIndex {
            try $0.execute(sql: "DELETE FROM ranked_dirty; DELETE FROM ranked_hint")
        }
        try await stores.blobs.write { try $0.execute(sql: "DELETE FROM ranked_blob_dirty") }
        var cursor: Int64 = 0
        while true {
            try Task.checkCancellation()
            let after = cursor
            let batch = try await stores.searchReader.read {
                try Self.documents($0, where: "m.msg_pk>? ORDER BY m.msg_pk LIMIT 256", [after])
            }
            guard let last = batch.last else { break }
            try index.indexDocs(docs: batch.map(\.native))
            try await writer.maintainSearchIndex { try Self.hints(batch, in: $0) }
            cursor = last.id
        }
        try index.commit()
        try Data(epoch.utf8).write(to: marker, options: .atomic)
        engine = index
    }

    private struct Change: Sendable {
        let msg: Int64?
        let account, gmailID: String?
        let version: Data
    }

    private func updateBatch(_ index: TantivyIndex) async throws -> Bool {
        let changes = try await stores.searchReader.read { db in
            let headers = try Row.fetchAll(db, sql: "SELECT msg,version FROM idx.ranked_dirty LIMIT 128").map {
                Change(msg: $0[0], account: nil, gmailID: nil, version: $0[1])
            }
            let blobs = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.msg_pk,b.account,b.gmail_id,b.version FROM
                    (SELECT * FROM blobs.ranked_blob_dirty LIMIT 128) b
                    LEFT JOIN idx.account a ON a.email=b.account
                    LEFT JOIN idx.message m ON m.account_pk=a.account_pk AND m.gmail_id=b.gmail_id
                    """
            ).map { Change(msg: $0[0], account: $0[1], gmailID: $0[2], version: $0[3]) }
            return headers + blobs
        }
        guard !changes.isEmpty else { return false }
        let ids = Set(changes.compactMap(\.msg)).sorted()
        if !ids.isEmpty {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let docs = try await stores.searchReader.read {
                try Self.documents($0, where: "m.msg_pk IN (\(placeholders))", StatementArguments(ids))
            }
            for id in ids {
                let field = DocumentField(name: "id", value: .u64(UInt64(id)))
                if try index.docExists(id: field) { try index.deleteDoc(id: field) }
            }
            if !docs.isEmpty { try index.indexDocs(docs: docs.map(\.native)) }
            try index.commit()
            try await writer.maintainSearchIndex { db in
                try db.execute(
                    sql: "DELETE FROM ranked_hint WHERE msg IN (\(placeholders))", arguments: StatementArguments(ids))
                try Self.hints(docs, in: db)
                for change in changes where change.account == nil {
                    try db.execute(
                        sql: "DELETE FROM ranked_dirty WHERE msg=? AND version=?",
                        arguments: [change.msg, change.version])
                }
            }
        }
        if changes.contains(where: { $0.account != nil }) {
            try await stores.blobs.write { db in
                for change in changes where change.account != nil {
                    try db.execute(
                        sql: "DELETE FROM ranked_blob_dirty WHERE account=? AND gmail_id=? AND version=?",
                        arguments: [change.account, change.gmailID, change.version])
                }
            }
        }
        return true
    }

    func synchronize() async throws {
        guard !working else { return }
        revision &+= 1
        working = true
        ready = false
        defer { working = false }
        do {
            if engine == nil { try await openOrBuild() }
            guard let engine else { return }
            while try await updateBatch(engine) { try Task.checkCancellation() }
            ready = true
        } catch {
            engine = nil
            throw error
        }
    }

    private static func clean(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql:
                "SELECT NOT EXISTS(SELECT 1 FROM idx.ranked_dirty) AND NOT EXISTS(SELECT 1 FROM blobs.ranked_blob_dirty)"
        ) == true
    }

    struct Page: Sendable {
        var ids: [Int64] = []
        var rows: [IndexRow] = []
        var offset = 0
        var remaining: Int { ids.count - offset }
    }

    func top(_ text: String, allowed: Set<String>) async throws -> [IndexRow]? {
        try await page(text, allowed: allowed, before: nil, limit: 50)?.rows
    }

    /// Keep group membership for pagination, but decode only rows this surface will display.
    /// nil requests the authoritative chronological fallback and background catch-up.
    func page(_ text: String, allowed grants: Set<String>, before: MailOrderKey?, limit: Int) async throws -> Page? {
        let allowed = Set(grants.map { $0.lowercased() })
        let tokens = Self.words(text)
        guard !allowed.isEmpty, !tokens.isEmpty else { return Page() }
        guard ready, let engine else { return nil }
        let ticket = revision
        let marks = allowed.map { _ in "?" }.joined(separator: ",")
        let scoped = try await stores.searchReader.read { db -> (ids: [Int64], all: Bool)? in
            guard try Self.clean(db) else { return nil }
            let rows = try Row.fetchAll(db, sql: "SELECT account_pk,email FROM idx.account")
            let ids: [Int64] = rows.compactMap { allowed.contains($0[1] as String) ? $0[0] : nil }
            return (ids, ids.count == rows.count)
        }
        guard let scoped else { return nil }
        let accounts = scoped.ids
        guard !accounts.isEmpty else { return Page() }
        let basic = tokens.joined(separator: " ")
        let together = tokens.joined(separator: " AND ")
        var clauses = ["(\(basic))", "(\(together))"]
        if tokens.count <= 2 {
            for field in ["subject", "sender", "snippet"] {
                clauses.append("(" + tokens.map { field + ":" + $0 }.joined(separator: " AND ") + ")")
            }
        }
        let access = accounts.map { "account:\($0)" }.joined(separator: " OR ")
        let expression = (scoped.all ? "" : "(\(access))^0 AND ") + "(" + clauses.joined(separator: " OR ") + ")"
        let query = TantivySearchQuery(
            queryStr: expression, defaultFields: Self.fields.filter { $0 != "attachments" }, fuzzyFields: [], topDocLimit: 200, topDocOffset: 0)
        // Native segment order can change after a merge. Use the persistent message ID to break equal scores.
        func matches(_ query: TantivySearchQuery) throws -> [Int64] {
            try engine.searchDocIds(query: query, idField: "id")
                .sorted { $0.score == $1.score ? $0.docId < $1.docId : $0.score > $1.score }
                .map { Int64($0.docId) }
        }
        let candidates = try matches(query)
        let fileSlots = tokens.last.flatMap { UTType(filenameExtension: $0) }?.isDeclared == true ? 3 : 1
        var fileMatches: [Int64] = []
        if tokens.count > 1 {
            let filename = tokens.map { "filename:" + $0 }.joined(separator: " AND ")
            let fileQuery = TantivySearchQuery(
                queryStr: (scoped.all ? "" : "(\(access))^0 AND ") + "(" + filename + ")",
                defaultFields: ["filename"], fuzzyFields: [], topDocLimit: 50, topDocOffset: 0)
            fileMatches = try matches(fileQuery)
        }
        let fileIDs = fileMatches
        // Attachment text is ranked on its own (docs/performance/mail-attachment-search.md): in the
        // main ranking, BM25 length normalisation against an average dominated by messages without
        // files buries every document, and without it long files win unrelated searches. Its best
        // match with every word takes one place in the first five.
        let attachQuery = TantivySearchQuery(
            queryStr: (scoped.all ? "" : "(\(access))^0 AND ") + "(" + tokens.map { "attachments:" + $0 }.joined(separator: " AND ") + ")",
            defaultFields: ["attachments"], fuzzyFields: [], topDocLimit: 50, topDocOffset: 0)
        let attachIDs = try matches(attachQuery)
        // Keep the canonical rows, grants, hint lookup and dirty check in the same read transaction.
        let page: Page? = try await stores.searchReader.read { db in
            guard try Self.clean(db) else { return nil }
            let sender = tokens.count == 1
            let term = sender ? tokens[0] : Self.folded(text.trimmingCharacters(in: .whitespacesAndNewlines))
            var hints: [(Int64, Int64)] = []
            for account in accounts {
                hints += try Row.fetchAll(
                    db,
                    sql:
                        "SELECT h.msg,h.date FROM idx.ranked_hint h CROSS JOIN idx.message m ON m.msg_pk=h.msg CROSS JOIN idx.thread t ON t.thread_pk=m.thread_pk WHERE h.kind=? AND h.term=? AND h.account=? AND t.last_date>0 ORDER BY h.date DESC,h.msg DESC LIMIT 40",
                    arguments: [sender ? 0 : 1, term, account]
                ).map { ($0[0], $0[1]) }
            }
            let hintIDs = hints.sorted { ($0.1, $0.0) > ($1.1, $1.0) }.map(\.0)
            let ids = Array(Set(candidates + hintIDs + fileIDs + attachIDs))
            guard !ids.isEmpty else { return Page() }
            var args = StatementArguments(ids)
            args += StatementArguments(allowed.sorted())
            let membership = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.msg_pk,t.thread_pk FROM idx.message m CROSS JOIN idx.thread t ON t.thread_pk=m.thread_pk
                    CROSS JOIN idx.account a ON a.account_pk=t.account_pk
                    WHERE m.msg_pk IN (\(ids.map { _ in "?" }.joined(separator:","))) AND a.email IN (\(marks)) AND t.last_date>0
                    """, arguments: args)
            var byMessage: [Int64: Int64] = [:]
            for row in membership { byMessage[row[0]] = row[1] }
            var seen = Set<Int64>()
            var result: [Int64] = []
            func append(_ keys: [Int64], count: Int) {
                var added = 0
                for id in keys {
                    guard let thread = byMessage[id], seen.insert(thread).inserted else { continue }
                    result.append(thread)
                    added += 1
                    if added == count || result.count == MailTuning.listStep { break }
                }
            }
            if sender {
                append(candidates, count: 1)
                append(hintIDs, count: 3)
            } else {
                append(hintIDs, count: 1)
                append(candidates, count: 1)
                append(fileIDs, count: fileSlots)
            }
            append(attachIDs, count: 1)
            if result.count < MailTuning.listStep { append(candidates, count: MailTuning.listStep) }
            let offset: Int
            if let before {
                offset =
                    before.group == -1
                    ? result.indices.first { -Int64($0) < before.sortKey } ?? result.count : result.count
            } else {
                offset = 0
            }
            let visible = Array(result.dropFirst(offset).prefix(limit))
            guard !visible.isEmpty else { return Page(ids: result, rows: [], offset: offset) }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.thread_pk,a.email,t.gmail_id,t.last_date,t.tie,t.unread_count>0,t.message_count,t.flags,t.subject,t.snippet,
                           t.people,t.people_total,t.labels,t.wake_at,t.returned_at,t.waiting_until,t.pending,t.last_date,
                           t.recipients,t.recipients_total,t.arrival_seq
                    FROM idx.thread t JOIN idx.account a ON a.account_pk=t.account_pk
                    WHERE t.thread_pk IN (\(visible.map { _ in "?" }.joined(separator:",")))
                    """, arguments: StatementArguments(visible))
            var hydrated = try rows.map(MailIndexReader.decode)
            // A row whose subject and snippet lack a searched word shows where the words are, when
            // that is a file's text (MailRow.snippet: "in a search, the excerpt around the match").
            for index in hydrated.indices {
                let shown = Set(Self.words(hydrated[index].subject + " " + hydrated[index].snippet))
                guard !tokens.allSatisfy(shown.contains),
                      let message = attachIDs.first(where: { byMessage[$0] == hydrated[index].threadPK }),
                      let blob = try Data.fetchOne(db, sql: """
                          SELECT at.text FROM idx.message m JOIN idx.account a ON a.account_pk=m.account_pk
                          JOIN blobs.attachment_text at ON at.account=a.email AND at.gmail_id=m.gmail_id WHERE m.msg_pk=?
                          """, arguments: [message]),
                      let excerpt = MailCloudText.excerpt(String(decoding: try MailBlobCodec.decode(blob), as: UTF8.self), words: tokens)
                else { continue }
                hydrated[index].snippet = excerpt
            }
            let byThread = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.threadPK, $0) })
            return Page(ids: result, rows: visible.compactMap { byThread[$0] }, offset: offset)
        }
        return ready && revision == ticket ? page : nil
    }
}
#endif
