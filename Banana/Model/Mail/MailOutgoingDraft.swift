#if !BANANA_PUBLIC
import Foundation
import UniformTypeIdentifiers

/// Read-only local outgoing content while the durable send waits, runs, or awaits its provider copy.
/// Stable ids prevent a provider draft rewrite from replacing the visible card during Undo.
enum MailOutgoingDraft {
    private static let prefix = "local:outgoing:"
    static func draftID(_ message: MailMessageID) -> MailDraftID? {
        guard message.message.hasPrefix(prefix) else { return nil }
        return MailDraftID(raw: String(message.message.dropFirst(prefix.count)))
    }
    static func message(_ draft: MailDraft) -> MailMessage {
        let id = MailMessageID(account: draft.account, message: prefix + draft.id.raw)
        return MailMessage(id: id,
            from: MailPerson(name: draft.from.name, address: draft.from.address, isMe: true, isKnown: true, fromTheirMail: false),
            to: draft.to, cc: draft.cc, bcc: draft.bcc, replyTo: [], deliveredTo: nil, listName: nil,
            date: draft.editedAt, isUnread: false, isMine: true,
            firstLine: MailPlainText.firstLine(MailPlainText.string(draft.body)), body: .text,
            attachments: draft.attachments.map { file in
                MailAttachment(id: MailAttachmentID(message: id, part: file.id), name: file.name,
                    mimeType: UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                    typeMismatch: false, bytes: file.bytes, localFile: file.file, isInline: false, isExecutable: file.isExecutable)
            }, delivery: draft.delivery, draft: nil)
    }
    static func body(_ draft: MailDraft) -> MailBody {
        var blocks = draft.body.blocks
        func text(_ part: MailDraftPart?) -> MailText? {
            switch part?.body {
            case .text(let value, _, _)?: return value
            case .designed(_, _, _, let value, _)?: return value
            default: return nil
            }
        }
        if let signature = text(draft.signature) { blocks += signature.blocks }
        let quote = text(draft.quote)
        let quoteStarts: Int? = quote == nil ? nil : blocks.count
        if let quote { blocks += quote.blocks }
        return .text(MailText(blocks: blocks), quoteStartsAt: quoteStarts, notices: [])
    }
}
#endif
