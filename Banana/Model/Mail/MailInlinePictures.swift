#if !BANANA_PUBLIC
import Foundation
import CryptoKit
import GRDB

/// A picture that is a part of the message itself (`cid:`): found by its Content-ID in the stored MIME
/// structure, read from the attachment store when it is there, and otherwise fetched once from the
/// account's own mailbox (`attachments.get`, never from the sender's server) and kept.
///
/// - Only `image/*` parts of at most `maximumBytes` that start with the bytes of a picture are returned.
/// - The file lives in `Attachments.noindex` (relative path in the `attachment` row), is replaced on
///   every fetch, and is the disposable tier: losing it only means fetching the part again.
/// - Gmail's `attachmentId` is not stable between reads, so when the stored one is refused the message
///   is read again for a fresh one.
struct MailInlinePictures: Sendable {
    let stores: MailStores
    let api: any GmailAPI
    let token: @Sendable (String) async throws -> String

    static let maximumBytes = 4 * 1024 * 1024

    func resource(contentID raw: String, message: MailMessageID) async -> MailResource? {
        let wanted = Self.clean(raw)
        guard !wanted.isEmpty else { return nil }
        let account = message.account.lowercased()
        if let hit = await cached(account: account, message: message.message, contentID: wanted) { return hit }
        guard let content = try? await MailBlobStore(stores: stores).content(account: account, messageID: message.message),
              let part = Self.find(wanted, in: content.structure.root),
              part.mimeType.hasPrefix("image/"), part.mimeType != "image/svg+xml",
              (part.size ?? 0) <= Self.maximumBytes else { return nil }
        guard let data = await bytes(of: part, account: account, message: message.message),
              data.count <= Self.maximumBytes, let mime = Self.sniff(data) else { return nil }
        try? await store(data, mime: mime, part: part, contentID: wanted, account: account, message: message.message)
        return MailResource(data: data, mimeType: mime)
    }

    // MARK: Finding

    static func clean(_ raw: String) -> String {
        (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    static func find(_ contentID: String, in part: MIMEStructure.Part) -> MIMEStructure.Part? {
        if let id = part.contentID, id.caseInsensitiveCompare(contentID) == .orderedSame { return part }
        for child in part.children { if let found = find(contentID, in: child) { return found } }
        return nil
    }

    /// The type a picture's own first bytes say it is; nothing else is ever handed to the decoder.
    static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }

    // MARK: Disk

    private func cached(account: String, message: String, contentID: String) async -> MailResource? {
        let row: (path: String, mime: String?)? = try? await stores.blobs.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT path, sniffed_mime FROM attachment WHERE account=? AND gmail_id=? AND lower(content_id)=lower(?) AND state=1",
                                             arguments: [account, message, contentID]), let path: String = row[0] else { return nil }
            return (path, row[1])
        }
        guard let row, Self.isSafe(row.path) else { return nil }
        let url = stores.directories.attachments.appendingPathComponent(row.path)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url), let mime = Self.sniff(data) else { return nil }
        return MailResource(data: data, mimeType: mime)
    }

    /// A relative path of plain names: nothing that could leave the attachment directory.
    static func isSafe(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && pieces.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func store(_ data: Data, mime: String, part: MIMEStructure.Part, contentID: String, account: String, message: String) async throws {
        guard message.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }
        let owner = SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = "inline-" + part.partID.map { $0.isNumber ? String($0) : "-" }.joined()
        let relative = owner + "/" + message + "/" + name
        let destination = stores.directories.attachments.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MailFiles.install(data, at: destination, protection: .complete, quarantine: MailQuarantine(), durability: .atomic)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await stores.blobs.write { db in
            try db.execute(sql: """
                INSERT INTO attachment(account,gmail_id,part_id,filename,declared_mime,sniffed_mime,size,content_id,inline,attachment_id,state,path,bytes,used_at,keep)
                VALUES (?,?,?,NULL,?,?,?,?,1,?,1,?,?,?,0)
                ON CONFLICT(account,gmail_id,part_id) DO UPDATE SET declared_mime=excluded.declared_mime, sniffed_mime=excluded.sniffed_mime,
                    size=excluded.size, content_id=excluded.content_id, inline=1, attachment_id=excluded.attachment_id,
                    state=1, path=excluded.path, bytes=excluded.bytes, used_at=excluded.used_at
                """, arguments: [account, message, part.partID, part.mimeType, mime, part.size, contentID, part.attachmentID, relative, data.count, now])
        }
    }

    // MARK: Mailbox

    private func bytes(of part: MIMEStructure.Part, account: String, message: String) async -> Data? {
        guard let access = try? await token(account) else { return nil }
        if let id = part.attachmentID,
           let body = try? await api.attachment(token: access, messageID: message, attachmentID: id), let data = Self.decode(body.data) { return data }
        // The stored attachment id is stale or refused: read the message again for this part's current one.
        guard let full = try? await api.message(token: access, id: message, format: .full), let payload = full.payload,
              let current = Self.find(partID: part.partID, in: payload, path: "0") else { return nil }
        if let data = Self.decode(current.body?.data) { return data }
        guard let id = current.body?.attachmentId,
              let body = try? await api.attachment(token: access, messageID: message, attachmentID: id) else { return nil }
        return Self.decode(body.data)
    }

    private static func find(partID: String, in part: GmailPart, path: String) -> GmailPart? {
        if (part.partId ?? path) == partID { return part }
        for (index, child) in (part.parts ?? []).enumerated() {
            if let found = find(partID: partID, in: child, path: path + "." + String(index)) { return found }
        }
        return nil
    }

    private static func decode(_ encoded: String?) -> Data? {
        guard var text = encoded, !text.isEmpty, text.utf8.count <= maximumBytes * 2 else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}

#endif
