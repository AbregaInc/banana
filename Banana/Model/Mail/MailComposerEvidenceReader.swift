#if !BANANA_PUBLIC
import CryptoKit
import Darwin
import Foundation
import GRDB
import PDFKit

struct MailComposerEvidenceItem: Codable, Sendable {
    let kind: String
    let account: String
    let threadID: String
    let messageID: String
    let subject: String
    let sender: String
    var isMine: Bool = false
    let sent: String
    let text: String
    let coverage: String
    let filename: String?
    var partID: String? = nil
    var recoveredThreadMessage = false
}

/// All reads are local. Only authenticated callers may deliver this evidence to the composer.
struct MailComposerEvidenceReader: Sendable {
    let stores: MailStores

    private struct Header: Sendable {
        let thread, message, subject, sender, address, snippet: String
        let date, pk: Int64
        var recoveredThreadMessage = false
        var correspondentHistory = false
        let mine, hasAttachment, fullyFetched: Bool
        let peers: Set<String>
        let visibleParticipants: Set<String>
        init(_ row: Row, checkingAudience: Bool = false) {
            thread = row["thread"]; message = row["message"]; subject = row["subject"]
            sender = row["sender"]; snippet = row["snippet"]; date = row["date"]; pk = row["msg_pk"]
            mine = MailMessageFlags(rawValue: row["flags"]).contains(.fromMe)
            fullyFetched = (row["fetch_state"] as Int) == 2
            hasAttachment = MailMessageFlags(rawValue: row["flags"]).contains(.hasAttachment)
            address = row["address"]
            let recipients = (mine || checkingAudience ? row["recipients"] as String? : nil).flatMap {
                try? JSONDecoder().decode(MailMessageImporter.Recipients.self, from: Data($0.utf8))
            }
            let visibleRecipients = (recipients?.to ?? []) + (recipients?.cc ?? [])
            peers = mine ? Set(visibleRecipients.prefix(64).map { $0.lowercased() }) :
                (address.isEmpty ? [] : [address.lowercased()])
            visibleParticipants = checkingAudience ? Set(([address] + visibleRecipients).filter { !$0.isEmpty }.map { $0.lowercased() }) : []
        }
    }

    func read(account: String, thread: String, selectedMessageID: String?, query: String?, includeAttachments: Bool,
              matchingParticipants: Bool, ownerAddresses: Set<String>, earlierThreadAttachments: Bool = false, exactTitle: Bool = false,
              threadAudience: Set<String>? = nil) async throws -> [MailComposerEvidenceItem] {
        if let threadAudience, threadAudience.isEmpty || selectedMessageID == nil { return [] }
        if (earlierThreadAttachments || exactTitle) && selectedMessageID == nil { return [] }
        if exactTitle && (query?.utf8.count ?? 0) > 160 { return [] }
        let words = (query ?? "").prefix(160).split { !$0.isLetter && !$0.isNumber }.prefix(8)
        let bodyMatch = words.map { "\"" + $0 + "\"*" }.joined(separator: " AND ")
        let match = words.map { "{subject snippet sender}:\"" + $0 + "\"*" }.joined(separator: " AND ")
        let (selected, related) = try await stores.searchReader.read { db -> ([Header], [Header]) in
            let columns = """
                m.msg_pk,m.flags,m.fetch_state,substr(coalesce(m.from_addr,''),1,320) AS address,
                CASE WHEN length(m.recipients)<=16384 THEN m.recipients END AS recipients,
                t.gmail_id AS thread, m.gmail_id AS message, m.internal_date AS date,
                substr(coalesce(m.subject,''),1,160) AS subject,
                substr(coalesce(nullif(m.from_name,''),m.from_addr,''),1,120) AS sender,
                substr(coalesce(m.snippet,''),1,400) AS snippet
                """
            let scope = """
                JOIN thread t ON t.thread_pk=m.thread_pk AND t.account_pk=m.account_pk
                JOIN account a ON a.account_pk=m.account_pk
                WHERE a.email=? AND m.vis=0 AND NOT EXISTS (
                    SELECT 1 FROM message_label ml JOIN label l USING(label_pk)
                    WHERE ml.msg_pk=m.msg_pk AND l.gmail_id IN ('DRAFT','SPAM','TRASH'))
                """
            var cutoff = ""
            var args: StatementArguments = [account, thread]
            if let selectedMessageID {
                guard let anchor = try Row.fetchOne(db, sql: """
                    SELECT m.internal_date,m.msg_pk FROM message m \(scope) AND t.gmail_id=? AND m.gmail_id=?
                    """, arguments: [account, thread, selectedMessageID]) else { return ([], []) }
                cutoff = " AND (m.internal_date,m.msg_pk)<=(?,?)"
                args += [anchor["internal_date"] as Int64, anchor["msg_pk"] as Int64]
            }
            let rankWithinThread = threadAudience != nil && selectedMessageID != nil &&
                query == nil && !includeAttachments && !earlierThreadAttachments
            let headerLimit = earlierThreadAttachments ? 50 : (rankWithinThread ? 32 : 6)
            let candidates = try Row.fetchAll(db, sql: """
                SELECT \(columns) FROM message m \(scope) AND t.gmail_id=? \(cutoff)
                ORDER BY m.internal_date DESC,m.msg_pk DESC LIMIT ?
                """, arguments: args + [headerLimit]).map { Header($0, checkingAudience: threadAudience != nil) }
            let recent: [Header]
            if rankWithinThread, let audience = threadAudience {
                let originalIDs = Set(candidates.prefix(6).map(\.message))
                recent = Self.threadEvidence(candidates, audience: audience).map { header in
                    var header = header
                    header.recoveredThreadMessage = !originalIDs.contains(header.message)
                    return header
                }
            } else { recent = candidates }
            if rankWithinThread, let audience = threadAudience, let anchor = recent.first, !anchor.mine {
                // Earlier mail with the same correspondent in other threads, ranked by the distinctive
                // words it shares with the selected question. Every recipient of the reply must have
                // been on that message, as for older messages in the thread.
                let peer = anchor.address.lowercased()
                if !peer.isEmpty, !ownerAddresses.contains(peer) {
                    let pattern = "%\"" + peer.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "") + "\"%"
                    let others = try Row.fetchAll(db, sql: """
                        SELECT \(columns) FROM message m \(scope) AND t.gmail_id<>?
                        AND (m.internal_date,m.msg_pk)<(?,?)
                        AND (lower(m.from_addr)=? OR lower(m.recipients) LIKE ?)
                        ORDER BY m.internal_date DESC,m.msg_pk DESC LIMIT 40
                        """, arguments: [account, thread, anchor.date, anchor.pk, peer, pattern])
                        .map { Header($0, checkingAudience: true) }
                        .filter { audience.isSubset(of: $0.visibleParticipants) }
                    let chosen = Self.correspondentEvidence(others, question: anchor.snippet).map { header -> Header in
                        var header = header
                        header.recoveredThreadMessage = true
                        header.correspondentHistory = true
                        return header
                    }
                    return (recent, chosen)
                }
            }
            guard !match.isEmpty, let anchor = recent.first else { return (recent, []) }
            let peers = anchor.peers.subtracting(ownerAddresses)
            if matchingParticipants && peers.isEmpty { return (recent, []) }
            if exactTitle {
                // Only an exact subject can resolve a named reference. An incomplete
                // posting list cannot prove that the title names a unique thread.
                let headerMatch = words.map { "subject:\"" + $0 + "\"*" }.joined(separator: " AND ")
                let hits = try Int64.fetchAll(db, sql: """
                    SELECT rowid FROM mail_header_search WHERE mail_header_search MATCH ? LIMIT 401
                    """, arguments: [headerMatch])
                guard !hits.isEmpty, hits.count <= 400 else { return (recent, []) }
                let marks = Array(repeating: "?", count: hits.count).joined(separator: ",")
                let candidates = try Row.fetchAll(db, sql: """
                    SELECT \(columns) FROM message m \(scope)
                    AND (m.internal_date,m.msg_pk)<(?,?) AND t.gmail_id<>?
                    AND length(m.subject)<=160 AND m.msg_pk IN (\(marks))
                    ORDER BY m.internal_date DESC,m.msg_pk DESC
                    """, arguments: StatementArguments([account]) + [anchor.date,anchor.pk,thread] + StatementArguments(hits)).map { Header($0) }
                let title = Self.normalizedTitle(query ?? "")
                let matches = candidates.filter {
                    Self.normalizedTitle($0.subject) == title && (!matchingParticipants || !peers.isDisjoint(with: $0.peers))
                }
                guard Set(matches.map(\.thread)).count == 1 else { return (recent, []) }
                return (recent, Array(matches.prefix(3)))
            }
            // The read-only search connection attaches the header index. Inspect bounded
            // postings from each index before sorting. A busy mailbox can have more hits.
            let older = try Row.fetchAll(db, sql: """
                WITH header_hits(pk) AS (
                    SELECT rowid FROM mail_header_search WHERE mail_header_search MATCH ?
                    ORDER BY rowid DESC LIMIT 400
                ), body_hits(pk) AS (
                    SELECT d.msg_pk FROM msg_fts JOIN body_doc d ON d.rowid=msg_fts.rowid
                    JOIN message indexedMessage ON indexedMessage.msg_pk=d.msg_pk AND indexedMessage.fts_state=2
                    WHERE msg_fts MATCH ? AND msg_fts.rowid<=?
                    ORDER BY msg_fts.rowid DESC LIMIT 400
                ), hits(pk) AS (SELECT pk FROM header_hits UNION SELECT pk FROM body_hits)
                SELECT \(columns) FROM hits JOIN message m ON m.msg_pk=hits.pk
                \(scope) AND (m.internal_date,m.msg_pk)<(?,?) AND t.gmail_id<>?
                ORDER BY m.internal_date DESC,m.msg_pk DESC LIMIT 24
                """, arguments: [match,bodyMatch,MailBodySearchSchema.rowID(date: anchor.date, message: 0xFFFFF),
                                 account,anchor.date,anchor.pk,thread]).map { Header($0) }
            return (recent, Array(older.lazy.filter { !matchingParticipants || !peers.isDisjoint(with: $0.peers) }.prefix(3)))
        }
        guard !selected.isEmpty else { return [] }
        if earlierThreadAttachments {
            guard query == nil, let anchor = selected.first, anchor.message == selectedMessageID,
                  selected.count < 50, !anchor.mine else { return [] }
            let peer = anchor.address.lowercased()
            guard !peer.isEmpty, !ownerAddresses.contains(peer) else { return [] }
            let eligible = selected.dropFirst().filter { header in
                header.peers.contains(peer) && (threadAudience?.isSubset(of: header.visibleParticipants) ?? true)
            }
            return try await uniqueEarlierAttachment(in: eligible, account: account)
        }
        var result: [MailComposerEvidenceItem] = []
        var attachmentCount = 0
        for header in selected + related {
            try Task.checkCancellation()
            if let threadAudience, header.thread == thread, header.message != selectedMessageID,
               !threadAudience.isSubset(of: header.visibleParticipants) { continue }
            func item(_ kind: String, _ text: String, _ coverage: String, filename: String? = nil, partID: String? = nil) -> MailComposerEvidenceItem {
                .init(kind: kind, account: account, threadID: header.thread, messageID: header.message,
                      subject: header.subject, sender: header.sender, isMine: header.mine,
                      sent: Date(timeIntervalSince1970: Double(header.date) / 1000).ISO8601Format(),
                      text: Self.boundedText(text), coverage: coverage, filename: filename, partID: partID, recoveredThreadMessage: header.recoveredThreadMessage)
            }
            let body = try await stores.blobs.read { db -> String? in
                // Bound both the SQL result and the decoded envelope before allocation.
                guard let b = try Data.fetchOne(db, sql: """
                    SELECT p.body FROM prepared p JOIN content c USING(account,gmail_id)
                    WHERE p.account=? AND p.gmail_id=? AND p.prep_version=? AND p.source_rev=c.content_rev
                    AND length(p.body)<=270000
                    """, arguments: [account,header.message,MailHTMLPreparer.version]),
                      b.count>=8, b.dropFirst(4).prefix(4).reduce(0, { ($0 << 8) + Int($1) }) <= 262144,
                      let raw = try? MailBlobCodec.decode(b),
                      let value = try? JSONDecoder().decode(MailPreparedBody.self, from: raw),
                      value.version == MailHTMLPreparer.version else { return nil }
                return value.text.blocks.compactMap { block -> String? in
                    switch block.kind {
                    case .quote, .fineprint: return nil
                    default: return block.runs.map(\.text).joined()
                    }
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let prepared = body.flatMap { $0.isEmpty ? nil : $0 }
            let text = prepared ?? header.snippet
            let isRelated = header.thread != thread && !header.correspondentHistory
            // Body FTS also indexes quoted material. A posting alone never proves
            // that the author actually supplied the requested evidence.
            if isRelated {
                let searchable = [header.subject, header.sender, header.address, header.snippet, text].joined(separator: "\n")
                guard words.allSatisfy({ searchable.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
            }
            var start = text.startIndex
            if isRelated, let hit = words.compactMap({ text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }).min() {
                start = text.index(hit, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
            }
            let excerpt = String(text[start...].prefix(900))
            if !excerpt.isEmpty {
                result.append(item(header.thread == thread || header.correspondentHistory ? "selectedMessage" : "relatedMessage",
                                   excerpt, prepared != nil ? "cached message excerpt" : "header snippet only"))
            }
            guard includeAttachments, let selectedMessageID,
                  (match.isEmpty ? header.message == selectedMessageID : header.thread != thread),
                  attachmentCount < 3 else { continue }
            let attachments = try await stores.blobs.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT filename,declared_mime,path,part_id FROM attachment
                    WHERE account=? AND gmail_id=? AND state=1 AND inline=0 AND length(path) BETWEEN 1 AND 1024
                    AND length(filename) BETWEEN 1 AND 255 AND lower(declared_mime) IN ('application/pdf','text/plain','text/csv')
                    AND bytes BETWEEN 1 AND 524288 ORDER BY part_id LIMIT 2
                    """, arguments: [account,header.message]).map { row in
                        (row["filename"] as String, row["declared_mime"] as String, row["path"] as String,row["part_id"] as String)
                    }
            }
            for (name, mime, path, part) in attachments where attachmentCount < 3 {
                try Task.checkCancellation()
                if let captured = Self.attachmentText(root: stores.directories.attachments, account: account,
                                                      message: header.message, filename: name, mime: mime, path: path) {
                    result.append(item("attachment", captured, "cached attachment excerpt", filename: name, partID: part))
                    attachmentCount += 1
                }
            }
        }
        return result
    }

    // Keep the newest turns for amendments. Spend at most two remaining
    // slots on older messages whose own snippet shares distinctive terms with
    // the selected question. Only compare messages visible to the draft audience.
    /// At most two earlier messages with the correspondent whose snippet shares at least two
    /// distinctive terms with the selected question; nothing when none does.
    private static func correspondentEvidence(_ rows: [Header], question: String) -> [Header] {
        func terms(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }.map(String.init))
        }
        let asked = terms(question)
        guard asked.count >= 2, !rows.isEmpty else { return [] }
        let overlaps = rows.map { terms($0.subject + " " + $0.snippet).intersection(asked) }
        var counts = [String: Int]()
        for words in overlaps { for word in words { counts[word, default: 0] += 1 } }
        let scored = overlaps.enumerated().compactMap { index, words -> (Int, Int)? in
            let distinctive = words.filter { (counts[$0] ?? 0) * 2 <= max(rows.count, 2) }
            guard distinctive.count >= 2 else { return nil }
            return (index, distinctive.reduce(0) { $0 + 100 / (counts[$1] ?? 1) })
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(2).map { rows[$0.0] }
    }

    private static func threadEvidence(_ rows: [Header], audience: Set<String>) -> [Header] {
        guard rows.count > 6, let anchor = rows.first else { return rows }
        let earlier = rows.dropFirst().filter { audience.isSubset(of: $0.visibleParticipants) }
        guard earlier.count > 5 else { return [anchor] + earlier }
        func terms(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
                .filter { $0.count >= 3 }.map(String.init))
        }
        let question = terms(anchor.snippet)
        guard question.count >= 2 else { return [anchor] + earlier.prefix(5) }
        let overlaps = earlier.map { terms($0.snippet).intersection(question) }
        var counts = [String: Int]()
        for words in overlaps {
            for word in words { counts[word, default: 0] += 1 }
        }
        let scores = overlaps.map { words -> Int in
            let distinctive = words.filter { (counts[$0] ?? 0) * 2 <= earlier.count }
            guard distinctive.count >= 2 else { return 0 }
            return distinctive.reduce(0) { $0 + 100 / (counts[$1] ?? 1) }
        }
        let available = Array(3..<earlier.count)
        let relevant = available.sorted {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
        }.prefix(2)
        let used = (Array(0..<3) + relevant).sorted()
        return [anchor] + used.map { earlier[$0] }
    }

    private static func normalizedTitle(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Inspect only a bounded complete history of earlier messages shared with
    /// this correspondent. A missing download or a second file makes a generic
    /// reference ambiguous, even when only one of those files is readable.
    private func uniqueEarlierAttachment(in headers: [Header], account: String) async throws -> [MailComposerEvidenceItem] {
        guard !headers.isEmpty, headers.allSatisfy(\.fullyFetched) else { return [] }
        let ids = headers.map(\.message)
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let files = try await stores.blobs.read { db in
            try Row.fetchAll(db, sql: """
                SELECT gmail_id,part_id,substr(filename,1,256) AS name,substr(declared_mime,1,100) AS mime,
                       CASE WHEN length(path)<=1024 THEN path END AS path,state,bytes
                FROM attachment WHERE account=? AND gmail_id IN (\(marks)) AND inline=0 LIMIT 2
                """, arguments: StatementArguments([account]) + StatementArguments(ids)).map { row in
                    (message: row["gmail_id"] as String, part: row["part_id"] as String, name: row["name"] as String?,
                     mime: row["mime"] as String?, path: row["path"] as String?, state: row["state"] as Int,
                     bytes: row["bytes"] as Int?)
                }
        }
        guard files.count == 1, let file = files.first, let header = headers.first(where: { $0.message == file.message }),
              !headers.contains(where: { $0.hasAttachment && $0.message != file.message }),
              let name = file.name, !name.isEmpty, name.utf8.count <= 255, let mime = file.mime?.lowercased(),
              ["application/pdf","text/plain","text/csv"].contains(mime), file.state == 1,
              let size = file.bytes, (1...524288).contains(size), let path = file.path else { return [] }
        // The attachment cache only contains opened files. Consult the actual
        // MIME manifest as well: an unopened sibling is still an alternative.
        let fileIsUnique = try await stores.blobs.read { db in
            guard let blob = try Data.fetchOne(db, sql: """
                SELECT structure FROM content WHERE account=? AND gmail_id=? AND length(structure)<=131072
                """, arguments: [account, file.message]), blob.count >= 8,
                  blob.dropFirst(4).prefix(4).reduce(0, { ($0 << 8) + Int($1) }) <= 131072,
                  let data = try? MailBlobCodec.decode(blob),
                  let structure = try? JSONDecoder().decode(MIMEStructure.self, from: data), structure.cut == nil else { return false }
            let documents = structure.attachments.filter { !$0.isInline }
            return documents.count == 1 && documents[0].partID == file.part &&
                documents[0].name == name && documents[0].mimeType.lowercased() == mime
        }
        guard fileIsUnique else { return [] }
        try Task.checkCancellation()
        guard let text = Self.attachmentText(root: stores.directories.attachments, account: account,
                                             message: file.message, filename: name, mime: mime, path: path) else { return [] }
        return [.init(kind: "attachment", account: account, threadID: header.thread, messageID: file.message,
                      subject: header.subject, sender: header.sender, isMine: header.mine,
                      sent: Date(timeIntervalSince1970: Double(header.date) / 1000).ISO8601Format(),
                      text: text, coverage: "cached attachment excerpt", filename: name, partID: file.part)]
    }

    // Bound encoded output as well as the number of user-perceived characters:
    // a single grapheme may contain an arbitrary number of combining marks.
    private static func boundedText(_ value: String) -> String {
        var bytes = value.utf8.prefix(4096)
        while !bytes.isEmpty {
            if let clipped = String(bytes: bytes, encoding: .utf8) { return clipped }
            bytes = bytes.dropLast()
        }
        return ""
    }

    static func attachmentText(root: URL, account: String, message: String, filename: String, mime: String, path: String) -> String? {
        let pieces = path.components(separatedBy: "/")
        let owner = SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let kind = MailAttachmentKind.of(name: filename, mimeType: mime)
        guard !kind.isProgram, kind.nameSays == nil, MailInlinePictures.isSafe(path), !path.utf8.contains(0), pieces.count == 4,
              pieces[0] == owner, pieces[1] == message, pieces[2].hasPrefix("part-"), pieces[3] == filename else { return nil }
        // Open each component relative to an already-open directory; never follow a symlink or block on a FIFO.
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        for (index, part) in pieces.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index < pieces.count - 1 ? O_DIRECTORY : O_NONBLOCK)
            let next = openat(fd, part, flags)
            guard next >= 0 else { return nil }
            close(fd); fd = next
        }
        let maximum = 512 * 1024
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximum,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1),
              data.count == info.st_size else { return nil }
        let text: String
        switch mime.lowercased() {
        case "text/plain", "text/csv":
            guard !data.contains(0), let plain = String(data: data, encoding: .utf8) else { return nil }
            text = String(plain.prefix(1000))
        case "application/pdf":
            guard data.starts(with: Data("%PDF-".utf8)), let doc = PDFDocument(data: data),
                  !doc.isLocked else { return nil }
            var excerpt = ""
            for i in 0..<min(doc.pageCount, 3) where excerpt.count < 1000 {
                if let page = doc.page(at: i), page.numberOfCharacters > 0,
                   let selection = page.selection(for: NSRange(location: 0, length: min(1000 - excerpt.count, page.numberOfCharacters))) {
                    excerpt += (selection.string ?? "").prefix(1000 - excerpt.count)
                    if excerpt.count < 1000 { excerpt += "\n" }
                }
            }
            text = excerpt
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : boundedText(trimmed)
    }
}
#endif
