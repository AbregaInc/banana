#if !BANANA_PUBLIC
import Foundation

/// Decode only the stable editor fields; retain the original journal row as evidence.
struct MailLegacyDraft: Decodable {
    var content: StoredDraft
    var fromName: String?
    var editedAt: Date
    var gmailDraftID: String?
    var uploadedMessageID: String?
    var uploadStarted: Bool?
    var requiresSentCheckBeforeRetry: Bool?
    var discarded: Bool?
    var thenDone: Bool?
    var remindIfNoReply: Date?

    func recovered(scope: String, state: String, attachmentsDirectory: URL) throws -> MailDraftRecord {
        let component: (String) -> Bool = { !$0.isEmpty && ![".", ".."].contains($0) && !$0.contains("/") && !$0.contains("\0") }
        guard component(content.localID), content.attachments.allSatisfy({ component($0.id) && $0.size >= 0 }) else {
            throw MailIntentStore.Failure.invalidGroup
        }
        func part(_ fragment: MailFragment?) throws -> MailDraftPart? {
            guard let fragment else { return nil }
            return MailDraftPart(fragment: fragment, body: try MailHTMLPreparer.prepare(plain: nil, html: fragment.html).body)
        }
        let files = content.attachments.map { attachment in
            MailDraftAttachment(id: attachment.id, name: attachment.filename, bytes: attachment.size,
                file: attachment.source == nil ? attachmentsDirectory.appendingPathComponent(content.localID, isDirectory: true)
                    .appendingPathComponent(attachment.id) : nil, isExecutable: false)
        }
        let bodyBytes = content.body.blocks.reduce(0) { total, block in
            min(MailTuning.maxEncodedBytes + 1, total + block.runs.reduce(1) {
                min(MailTuning.maxEncodedBytes + 1, $0 + $1.text.utf8.count)
            })
        }
        let draft = MailDraft(id: .init(raw: content.localID),
            conversation: .init(account: content.account, thread: content.threadID ?? "local:" + content.localID),
            account: content.account, isReply: ["reply", "replyAll"].contains(content.kind), isForward: content.kind == "forward",
            from: .init(account: content.account, address: content.fromAlias ?? content.account, name: fromName,
                        isDefault: true, hasSignature: content.signature != nil),
            to: content.to, cc: content.cc, bcc: content.bcc, subject: content.subject, body: content.body,
            signature: try part(content.signature), quote: try part(content.quote), attachments: files,
            format: content.format, schedule: nil, remindIfNoReply: remindIfNoReply, delivery: nil,
            encodedBytes: files.reduce(bodyBytes) {
                min(MailTuning.maxEncodedBytes + 1, $0 + ((min(MailTuning.maxEncodedBytes, $1.bytes) + 2) / 3) * 4)
            }, editedAt: editedAt)
        var record = MailDraftRecord(scope: scope, snapshot: .init(draft))
        record.snapshot.inReplyTo = content.inReplyTo
        if content.kind == "forward" { record.snapshot.forwardMessageID = content.sourceMessageID }
        record.thenDone = thenDone ?? false
        if let id = gmailDraftID, let message = uploadedMessageID {
            record.remote = .init(id: id, message: .init(id: message, threadId: content.threadID))
        }
        if discarded == true { record.state = .deleted }
        else if state == "sent" { record.state = .sent }
        else if state != "editing" || uploadStarted == true || requiresSentCheckBeforeRetry == true
            || (gmailDraftID != nil && uploadedMessageID == nil) {
            record.state = .uncertain
            record.legacyReview = true
        }
        return record
    }
}
#endif
