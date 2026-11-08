#if !BANANA_PUBLIC
import Foundation

/// The identifiers of the composer's box (direction A): its handle and ⤢, the photo and sparkle
/// tools, the assistant's line, and the field it folds into. Foundation only, like every
/// `MailIdentifiers*.swift`: the UI tests compile these files too.
extension MailID {
    static let composerBox = "mail.composer.box"
    static let composerHandle = "mail.composer.handle"
    static let composerExpand = "mail.composer.expand"
    static let composerPhoto = "mail.composer.photo"
    static let composerAssistant = "mail.composer.assistant"
    static let composerAssistantField = "mail.composer.assistant.field"
    static let composerAssistantUndo = "mail.composer.assistant.undo"
    /// The draft folded into the bottom field: tapping it resumes.
    static let composerFolded = "mail.composer.folded"
    static let composerFoldedSend = "mail.composer.folded.send"
    static let composerFoldedSendLater = "mail.composer.folded.sendLater"
    /// The switch at the start of a reply's To line: Reply all, Reply, Forward.
    static let composerReplyStyle = "mail.composer.replyStyle"
    static func composerReplyStyleChoice(_ title: String) -> String {
        "mail.composer.replyStyle." + title.lowercased().replacingOccurrences(of: " ", with: "")
    }
    /// "…" › Discard draft.
    static let discardDraft = "mail.more.discardDraft"
}

#endif
