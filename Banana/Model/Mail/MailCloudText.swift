#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Attachment text Banana Cloud read once for the account (MAIL-CLOUD-SYNC §5b): the words in PDFs,
/// Office files and text attachments, so search finds a message by what its files say. Devices store
/// it beside the body and index it; they never download the files to search them.
enum MailCloudText {
    struct Part: Codable, Equatable, Sendable {
        var partId: String
        var name: String
        var text: String
    }

    /// What one message keeps, at most (the cloud keeps the same).
    static let charactersMost = 200_000

    /// Between a file's name and its words, and between files: never in extracted text, and a word
    /// break to the index's tokenizer.
    private static let nameEnd: Character = "\u{1F}", partEnd: Character = "\u{1E}"

    /// What is stored and indexed for a message: each file's name and words.
    static func indexed(_ parts: [Part]) -> String {
        let clean = { (text: String) in text.filter { $0 != nameEnd && $0 != partEnd } }
        return String(parts.map { clean($0.name) + String(nameEnd) + clean($0.text) }
            .joined(separator: String(partEnd)).prefix(charactersMost))
    }

    /// The file a search's words were found in and the words around the first of them, as a search
    /// row's excerpt ("lease.pdf · …monthly rent 2,400…"); nil when no word is in any file.
    static func excerpt(_ stored: String, words: [String], before: Int = 50, after: Int = 110) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for part in stored.split(separator: partEnd, omittingEmptySubsequences: true) {
            let fields = part.split(separator: nameEnd, maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let name = String(fields[0]), text = fields[1]
            let found = words.compactMap { text.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
            guard let found else { continue }
            let start = text.index(found.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(found.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
            let words = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return name + " · " + (start > text.startIndex ? "…" : "") + words + (end < text.endIndex ? "…" : "")
        }
        return nil
    }

    static func register(in migrations: inout MailMigrations) {
        migrations.index.registerMigration("v16-cloud-text") { db in
            // The feed said the cloud read this message's attachment text and this device has not
            // stored it (1). Pulled with the message, or alone for a message already here.
            try db.execute(sql: "ALTER TABLE message ADD COLUMN cloud_text INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: """
                CREATE INDEX message_cloud_text ON message(account_pk, internal_date DESC, msg_pk DESC)
                WHERE cloud_text = 1 AND vis != 4
                """)
        }
        migrations.blobs.registerMigration("mail-cloud-attachment-text-v1") { db in
            // text: MailBlobCodec of MailCloudText.indexed(parts). Registered after MailRankedSchema:
            // a change is recorded for the ranked index in the same transaction, as every source is.
            try db.execute(sql: """
                CREATE TABLE attachment_text(account TEXT NOT NULL, gmail_id TEXT NOT NULL, text BLOB NOT NULL,
                    PRIMARY KEY(account, gmail_id)) WITHOUT ROWID
                """)
            for (event, ref) in [("INSERT", "new"), ("DELETE", "old"), ("UPDATE OF text", "new")] {
                try db.execute(sql: """
                    CREATE TRIGGER ranked_attachment_text_\(event.prefix(3)) AFTER \(event) ON attachment_text BEGIN
                    INSERT INTO ranked_blob_dirty VALUES(\(ref).account,\(ref).gmail_id,randomblob(16))
                        ON CONFLICT(account,gmail_id) DO UPDATE SET version=excluded.version; END
                    """)
            }
        }
    }

    /// Stores the text of messages the cloud sent, replacing any earlier copy.
    static func store(_ items: [(account: String, gmailID: String, parts: [Part])], in db: Database) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO attachment_text(account,gmail_id,text) VALUES(?,?,?)
            ON CONFLICT(account,gmail_id) DO UPDATE SET text=excluded.text
            """)
        for item in items {
            let text = indexed(item.parts)
            guard !text.isEmpty else { continue }
            try statement.execute(arguments: [item.account.lowercased(), item.gmailID, try MailBlobCodec.encode(Data(text.utf8))])
        }
    }

    /// The stored text of one message, or "".
    static func text(account: String, gmailID: String, in db: Database) throws -> String {
        guard let blob = try Data.fetchOne(db, sql: "SELECT text FROM attachment_text WHERE account=? AND gmail_id=?",
                                           arguments: [account.lowercased(), gmailID]) else { return "" }
        return String(decoding: try MailBlobCodec.decode(blob), as: UTF8.self)
    }
}
#endif
