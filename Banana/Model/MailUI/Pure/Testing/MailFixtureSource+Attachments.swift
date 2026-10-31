#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation
import UniformTypeIdentifiers

/// Attachments in memory for the sample mailbox, as the contract's members say them: a file added
/// to a draft is **copied** into a folder of this launch's own (`MailSampleFiles`), never read
/// whole and never under the app's data directory; a message's attachment has its bytes made
/// when it is asked for (`fetchAttachment`), as a small stand-in of the right type.
///
/// Nothing here is sent anywhere. The folders are swept by the next launch.
extension MailFixtureSource {

    // MARK: - On a draft

    func addAttachment(_ file: URL, to draft: MailDraftID) async -> MailDraftAttachment? {
        guard drafts[draft] != nil else { return nil }
        // Taken off a moment ago and brought back (Undo): the same one, as it was.
        if let index = removedFiles[draft]?.firstIndex(where: { $0.file == file }) {
            let back = removedFiles[draft]!.remove(at: index)
            attach(back, to: draft)
            return back
        }
        guard let kept = await MailSampleFiles.stage(copyOf: file, in: MailSampleFiles.folder(forDraft: draft)),
              drafts[draft] != nil else { return nil }
        let kind = MailAttachmentKind.of(name: kept.name, mimeType: "")
        let attachment = MailDraftAttachment(id: UUID().uuidString, name: kept.name, bytes: kept.bytes,
                                             file: kept.url, isExecutable: kind.isProgram)
        attach(attachment, to: draft)
        return attachment
    }

    func removeAttachment(_ id: String, from draft: MailDraftID) {
        guard var stored = drafts[draft], let index = stored.attachments.firstIndex(where: { $0.id == id }) else { return }
        // The file stays where it is, so that Undo can bring it back; the next launch sweeps it.
        removedFiles[draft, default: []].append(stored.attachments.remove(at: index))
        stored.encodedBytes = Self.encodedBytes(of: stored)
        drafts[draft] = stored
    }

    private func attach(_ attachment: MailDraftAttachment, to draft: MailDraftID) {
        guard var stored = drafts[draft] else { return }
        stored.attachments.append(attachment)
        stored.encodedBytes = Self.encodedBytes(of: stored)
        drafts[draft] = stored
    }

    /// What it would weigh as sent: its files encoded, and its words.
    nonisolated static func encodedBytes(of draft: MailDraft) -> Int {
        MailAttachmentSize.encoded(draft.attachments.map(\.bytes)) + MailPlainText.string(draft.body).utf8.count
    }

    // MARK: - A forward carries what the message had

    /// The original's attachments, as a forward's own: each as the size it was sent at, with a
    /// stand-in file to look at. A reply carries none.
    func forwardedAttachments(of message: MailMessage, in draft: MailDraftID) async -> [MailDraftAttachment] {
        var carried: [MailDraftAttachment] = []
        for original in message.attachments {
            let file: URL?
            if let local = original.localFile {
                file = local
            } else {
                file = await standInFile(for: original, folder: MailSampleFiles.folder(forDraft: draft))
            }
            carried.append(MailDraftAttachment(id: UUID().uuidString, name: original.name, bytes: original.bytes,
                                               file: file, isExecutable: original.isExecutable))
        }
        return carried
    }

    /// The files a sent message carries: what was on the draft, which is where its bytes are.
    nonisolated static func sentAttachments(of draft: MailDraft, message: MailMessageID) -> [MailAttachment] {
        draft.attachments.enumerated().map { part, attached in
            let type = MailAttachmentKind.type(ofName: attached.name)
            return MailAttachment(id: MailAttachmentID(message: message, part: String(part)), name: attached.name,
                                  mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                                  typeMismatch: false, bytes: attached.bytes, localFile: attached.file,
                                  isInline: false, isExecutable: attached.isExecutable)
        }
    }

    // MARK: - On a message

    /// The bytes of a received attachment, here: a small stand-in of its type, written with its
    /// quarantine, and then the conversation says where it is. The chip that asked for it is
    /// waiting and shows nothing until it arrives.
    func fetchAttachment(_ id: MailAttachmentID) {
        let thread = MailConversationID(account: id.message.account,
                                        thread: String(id.message.message.prefix { $0 != "~" }))
        guard let stored = threads[thread],
              let message = stored.conversation.messages.first(where: { $0.id == id.message }),
              let attachment = message.attachments.first(where: { $0.id == id }),
              attachment.localFile == nil else { return }
        let sender = message.from.address
        Task { @MainActor [weak self] in
            guard let self,
                  let url = await self.standInFile(for: attachment, folder: MailSampleFiles.folder(forMessage: id.message),
                                                   sender: sender),
                  var current = self.threads[thread],
                  let at = current.conversation.messages.firstIndex(where: { $0.id == id.message }),
                  let part = current.conversation.messages[at].attachments.firstIndex(where: { $0.id == id })
            else { return }
            current.conversation.messages[at].attachments[part].localFile = url
            self.threads[thread] = current
            self.publish()
        }
    }

    /// Writes the stand-in for an attachment and returns where it is.
    private func standInFile(for attachment: MailAttachment, folder: URL, sender: String? = nil) async -> URL? {
        let type = UTType(mimeType: attachment.mimeType)
        let made = MailSampleFiles.standIn(named: attachment.name, actually: attachment.typeMismatch ? type?.preferredFilenameExtension : nil)
        return await MailSampleFiles.stage(made.data, named: attachment.name, type: made.type, in: folder, from: sender)
    }
}
#endif

#endif
