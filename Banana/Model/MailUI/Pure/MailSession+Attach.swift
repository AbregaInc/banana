#if !BANANA_PUBLIC
import Foundation

/// Attachments in the composer, the session's half: taking a chip off, with the toast and its
/// Undo (every action shows at once, with Undo; none asks).
extension MailSession {

    /// The × on a chip: the file is off the draft at once, and the toast puts it back.
    func removeAttachment(_ id: String, from composer: MailComposerModel) {
        guard let removed = composer.files.remove(id) else { return }
        let name = MailFileName.safe(removed.attachment.name)
        present(MailAttachmentText.removed(name)) { [weak composer] in
            composer?.files.restore(removed)
        }
    }
}

#endif
