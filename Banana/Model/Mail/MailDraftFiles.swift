#if !BANANA_PUBLIC
import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Bounded file work on the draft actor. The precious copy is synced before SQLite names it.
enum MailDraftFiles {
    static let chunkBytes = 1024 * 1024
    static let maximumBytes = 25 * 1024 * 1024
    static func keep(_ source: URL, directory: URL) throws -> MailDraftAttachment {
        let id = UUID().uuidString.lowercased(), name = MailFileName.safe(source.lastPathComponent)
        let destination = directory.appendingPathComponent(id)
        let temporary = try MailFiles.createTemporary(beside: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var bytes = 0
        while let data = try readChunk(input), !data.isEmpty {
            bytes += data.count
            guard bytes <= maximumBytes else { throw MailDraftDriver.Failure.attachmentsNotReady }
            try output.write(contentsOf: data)
        }
        try output.close()
        try MailFiles.install(temporary: temporary, at: destination, protection: .completeUntilFirstUserAuthentication,
                              quarantine: MailQuarantine(), durability: .synced)
        return MailDraftAttachment(id: id, name: name, bytes: bytes, file: destination,
                                   isExecutable: FileManager.default.isExecutableFile(atPath: source.path))
    }
    static func describe(_ file: MailDraftAttachment) throws -> GmailDraftComposition.Attachment {
        guard let url = file.file else { throw MailDraftDriver.Failure.attachmentsNotReady }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hashes: [String] = [], bytes = 0
        while let data = try readChunk(input), !data.isEmpty {
            bytes += data.count
            guard bytes <= maximumBytes else { throw MailDraftDriver.Failure.attachmentsNotReady }
            hashes.append(hash(data))
        }
        guard bytes == file.bytes else { throw MailDraftDriver.Failure.changed }
        let mime = UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .init(name: file.name, mimeType: mime, bytes: bytes, chunks: hashes)
    }
    static func readChunk(_ input: FileHandle) throws -> Data? {
        var result = Data()
        while result.count < chunkBytes {
            guard let next = try input.read(upToCount: chunkBytes - result.count), !next.isEmpty else { break }
            result.append(next)
        }
        return result.isEmpty ? nil : result
    }
    static func download(_ message: GmailMessage, token: String, api: any GmailAPI, directory: URL, selected: Set<String>? = nil) async throws -> [MailDraftAttachment] {
        guard let messageID = message.id, let payload = message.payload else { throw GmailError.malformed }
        let extraction = MIMEStructure.extract(payload)
        guard extraction.structure.cut == nil else { throw GmailError.malformed }
        var parts: [String: GmailPart] = [:]
        func visit(_ part: GmailPart, path: String) throws {
            let id = part.partId ?? path
            guard parts[id] == nil else { throw GmailError.malformed }
            parts[id] = part
            for (index, child) in (part.parts ?? []).enumerated() { try visit(child, path: path + "." + String(index)) }
        }
        try visit(payload, path: "0")
        var files: [MailDraftAttachment] = [], total = 0
        do {
            for attachment in extraction.structure.attachments where selected == nil || selected!.contains(attachment.partID) {
                try Task.checkCancellation()
                let body: GmailPartBody
                if let inline = parts[attachment.partID]?.body, inline.data != nil || inline.size == 0 { body = GmailPartBody(size: inline.size, data: inline.data ?? "") }
                else if let remote = attachment.attachmentID {
                    body = try await api.attachment(token: token, messageID: messageID, attachmentID: remote)
                } else { throw GmailError.malformed }
                guard let encoded = body.data, encoded.utf8.count <= ((maximumBytes - total + 2) / 3) * 4 + 4 else { throw GmailError.responseTooLarge }
                var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
                guard let data = Data(base64Encoded: base64), data.count <= maximumBytes - total,
                      body.size == nil || body.size == data.count else { throw GmailError.malformed }
                total += data.count
                let id = UUID().uuidString.lowercased(), destination = directory.appendingPathComponent(id)
                try MailFiles.install(data, at: destination, protection: .completeUntilFirstUserAuthentication,
                                      quarantine: MailQuarantine(), durability: .synced)
                files.append(.init(id: attachment.partID, name: attachment.name, bytes: data.count, file: destination, isExecutable: false))
            }
            return files
        } catch {
            for file in files { if let url = file.file { try? FileManager.default.removeItem(at: url) } }
            throw error
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
#endif
