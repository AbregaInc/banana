#if !BANANA_PUBLIC
import Foundation

/// The identifiers of attachments and formatting in the composer, and of an attachment in a
/// message. Foundation only, like every `MailIdentifiers*.swift`: the UI tests compile these too.
extension MailID {
    /// The paperclip: a menu of the file panel and, where there is a finger, the photo picker.
    static let attach = "mail.composer.attach"
    /// The row of chips under the body, and one chip by the file's name.
    static let attachments = "mail.composer.attachments"
    static func attachmentChip(_ name: String) -> String { attachments + "." + name }
    static func attachmentRemove(_ name: String) -> String { attachments + "." + name + ".remove" }
    /// What is said under the chips: how many and how big, or why one was not added.
    static let attachmentsSummary = "mail.composer.attachments.summary"
    static let attachmentsNotice = "mail.composer.attachments.notice"

    /// The format bar, and its button to show it and hide it.
    static let formatBar = "mail.composer.format"
    static let formatToggle = "mail.composer.format.toggle"
    static let formatBold = "mail.composer.format.bold"
    static let formatItalic = "mail.composer.format.italic"
    static let formatUnderline = "mail.composer.format.underline"
    static let formatLink = "mail.composer.format.link"
    static let formatLinkField = "mail.composer.format.link.field"
    static let formatBullets = "mail.composer.format.bullets"
    static let formatNumbers = "mail.composer.format.numbers"
    static let formatQuote = "mail.composer.format.quote"

    /// A received message's attachment, by its name.
    static func receivedAttachment(_ name: String) -> String { "mail.conversation.attachment." + name }
    static let attachmentNote = "mail.conversation.attachment.note"
}

#endif
