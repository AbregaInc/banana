#if !BANANA_PUBLIC
import Foundation

/// Precious local editor state. Gmail's ID/version and the pending operation are committed with it.
struct MailDraftRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case editing, held, sending, uncertain, failed, sent, deleted }
    struct Part: Codable, Equatable, Sendable {
        var fragment: MailFragment
        var text: MailText
        var complete: Bool
        init(_ part: MailDraftPart) {
            fragment = part.fragment; complete = true
            switch part.body {
            case .text(let value, _, _): text = value
            case .designed(_, _, _, let value, _): text = value
            case .notOnDevice: text = MailText(blocks: []); complete = false
            }
        }
        var value: MailDraftPart { MailDraftPart(fragment: fragment, body: complete ? .text(text, quoteStartsAt: nil, notices: []) : .notOnDevice) }
    }
    struct Snapshot: Codable, Equatable, Sendable {
        var id: MailDraftID; var conversation: MailConversationID; var account: String
        var inReplyTo: String?
        var isReply: Bool; var isForward: Bool; var from: MailIdentity
        var to: [MailPerson]; var cc: [MailPerson]; var bcc: [MailPerson]
        var subject: String; var body: MailText; var signature: Part?; var quote: Part?
        var attachments: [MailDraftAttachment]; var format: MailDraft.Format
        var schedule: MailSchedule?; var remindIfNoReply: Date?; var encodedBytes: Int; var editedAt: Date
        init(_ draft: MailDraft) {
            id = draft.id; conversation = draft.conversation; account = draft.account
            isReply = draft.isReply; isForward = draft.isForward; from = draft.from
            to = draft.to; cc = draft.cc; bcc = draft.bcc; subject = draft.subject; body = draft.body
            signature = draft.signature.map(Part.init); quote = draft.quote.map(Part.init)
            attachments = draft.attachments; format = draft.format; schedule = draft.schedule
            remindIfNoReply = draft.remindIfNoReply; encodedBytes = draft.encodedBytes; editedAt = draft.editedAt
        }
        var value: MailDraft {
            MailDraft(id: id, conversation: conversation, account: account, isReply: isReply,
                isForward: isForward, from: from, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                signature: signature?.value, quote: quote?.value, attachments: attachments, format: format,
                schedule: schedule, remindIfNoReply: remindIfNoReply, delivery: nil,
                encodedBytes: encodedBytes, editedAt: editedAt)
        }
    }
    var scope: String
    var snapshot: Snapshot
    var revision: Int = 1
    var acknowledgedRevision: Int = 0
    var remote: GmailDraftReference?
    var pending: GmailDraftMutation?
    var pendingRevision: Int?
    var state: State = .editing
    var sendAt: Date?
    var wantsDelete = false
    var thenDone = false
    var conflict = false
    var generation: Int = 0
    var needsDelivery: Bool {
        ![.sent, .deleted, .failed].contains(state) && !conflict &&
        (pending != nil || acknowledgedRevision < revision || state == .held || state == .uncertain || wantsDelete)
    }
}
#endif
