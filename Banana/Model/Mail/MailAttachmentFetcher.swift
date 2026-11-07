#if !BANANA_PUBLIC
import Foundation
import CryptoKit
import GRDB

/// A received attachment, here: read from the attachment store if it is there, and otherwise fetched
/// once from the account's own mailbox (`attachments.get` through the service, 25 MB at most), checked,
/// kept in `Attachments.noindex` under its own name (so the system viewer knows what it is) and
/// recorded in the `attachment` row. It shares the part lookup, the fresh-id retry and the file rules with
/// `MailInlinePictures`.
///
/// Never waits behind the body queue: whoever taps an attachment is waiting for it.
struct MailAttachmentFetcher: Sendable {
    let pictures: MailInlinePictures

    static let maximumBytes = 25 * 1024 * 1024
    /// No bytes for this long is a failure; a bigger file is given the time its size needs at 100 KB/s on top.
    static let stall: TimeInterval = 30

    enum Failure: Error, Equatable, Sendable {
        case missing, tooLarge, notAllowed, unavailable, timedOut

        var reason: MailAttachmentFailure {
            switch self {
            case .missing: return .missing
            case .tooLarge: return .tooLarge
            case .notAllowed: return .notAllowed
            case .unavailable: return .unavailable
            case .timedOut: return .timedOut
            }
        }
    }

    enum Phase: Sendable, Equatable {
        case downloading(bytes: Int, of: Int)
    }

    private var stores: MailStores { pictures.stores }

    /// The local file for `id`, fetching it when it is not on the device.
    func file(for id: MailAttachmentID, deadline: TimeInterval? = nil,
              progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> URL {
        let account = id.message.account.lowercased(), message = id.message.message
        if let url = await cached(account: account, message: message, part: id.part) { return url }
        guard let content = try? await MailBlobStore(stores: stores).content(account: account, messageID: message),
              let part = Self.find(partID: id.part, in: content.structure.root) else { throw Failure.missing }
        let name = MailFileName.safe(part.filename ?? "attachment")
        guard !MailAttachmentKind.of(name: name, mimeType: part.mimeType).isProgram else { throw Failure.notAllowed }
        let declared = part.size ?? 0
        guard declared <= Self.maximumBytes else { throw Failure.tooLarge }
        progress(.downloading(bytes: 0, of: declared))
        let limit = deadline ?? (Self.stall + Double(declared) / 100_000)
        let data = try await withThrowingTaskGroup(of: Data?.self) { group -> Data in
            group.addTask { await pictures.bytes(of: part, account: account, message: message, limit: Self.maximumBytes) }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)); throw Failure.timedOut }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.unavailable }
            guard let data = first else { throw Failure.unavailable }
            return data
        }
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        progress(.downloading(bytes: data.count, of: declared))
        return try await store(data, part: part, name: name, account: account, message: message)
    }

    static func find(partID: String, in part: MIMEStructure.Part) -> MIMEStructure.Part? {
        if part.partID == partID { return part }
        for child in part.children { if let found = find(partID: partID, in: child) { return found } }
        return nil
    }

    // MARK: Disk

    /// Where an attachment is on this device, if it is: the row says, and the file must still be there.
    func cached(account: String, message: String, part: String) async -> URL? {
        let path: String? = try? await stores.blobs.read { db in
            try String.fetchOne(db, sql: "SELECT path FROM attachment WHERE account=? AND gmail_id=? AND part_id=? AND state=1",
                                arguments: [account, message, part])
        }
        guard let path, MailInlinePictures.isSafe(path) else { return nil }
        let url = stores.directories.attachments.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func store(_ data: Data, part: MIMEStructure.Part, name: String, account: String, message: String) async throws -> URL {
        guard message.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw Failure.notAllowed }
        let owner = SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = "part-" + part.partID.map { $0.isNumber ? String($0) : "-" }.joined()
        let relative = owner + "/" + message + "/" + folder + "/" + name
        let destination = stores.directories.attachments.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MailFiles.install(data, at: destination, protection: .complete, quarantine: MailQuarantine(), durability: .atomic)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try await stores.blobs.write { db in
                try db.execute(sql: """
                    INSERT INTO attachment(account,gmail_id,part_id,filename,declared_mime,sniffed_mime,size,content_id,inline,attachment_id,state,path,bytes,used_at,keep)
                    VALUES (?,?,?,?,?,NULL,?,?,?,?,1,?,?,?,0)
                    ON CONFLICT(account,gmail_id,part_id) DO UPDATE SET filename=excluded.filename, declared_mime=excluded.declared_mime,
                        size=excluded.size, content_id=excluded.content_id, inline=excluded.inline, attachment_id=excluded.attachment_id,
                        state=1, path=excluded.path, bytes=excluded.bytes, used_at=excluded.used_at
                    """, arguments: [account, message, part.partID, name, part.mimeType, part.size, part.contentID, part.isInline ? 1 : 0, part.attachmentID, relative, data.count, now])
            }
        } catch { throw Failure.unavailable }
        return destination
    }
}

#endif
