#if !BANANA_PUBLIC
import Foundation

/// How big an attachment is, and how big it makes the message: what the screen says and what the
/// limit is held against.
enum MailAttachmentSize {

    /// What `bytes` weigh once encoded for mail: base64, in lines of 76 characters with their line
    /// breaks. A message is held to `MailTuning.maxEncodedBytes` as sent, not as attached.
    static func encoded(_ bytes: Int) -> Int {
        guard bytes > 0 else { return 0 }
        let characters = (bytes + 2) / 3 * 4
        return characters + (characters + 75) / 76 * 2
    }

    /// The same for several.
    static func encoded(_ sizes: [Int]) -> Int {
        sizes.reduce(0) { $0 + encoded($1) }
    }

    /// Whether `sizes` are more than a message may be.
    static func isOver(_ sizes: [Int]) -> Bool {
        encoded(sizes) > MailTuning.maxEncodedBytes
    }

    /// "412 KB", "2.4 MB": the system's own format for a file.
    static func text(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The size of a file, or nil when it is not one a message can carry (a folder, or gone).
    /// A stat, and so not for the main thread.
    static func fileSize(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize
    }
}

/// What the composer and the reader say about attachments, in one place, so that a test can hold
/// every line against the design (MAIL-UX 6.2.9, 6.3.5).
enum MailAttachmentText {

    /// What Gmail takes, in the words a person says it in. The limit itself is
    /// `MailTuning.maxEncodedBytes`; this is that, as attachments, which is what he can change.
    static let limitWords = "about 25 MB of attachments"

    /// "“movie.mov” (80 MB) wasn't added. Gmail takes about 25 MB of attachments."
    static func notAdded(_ name: String, bytes: Int) -> String {
        "\u{201C}\(name)\u{201D} (\(MailAttachmentSize.text(bytes))) wasn\u{2019}t added. Gmail takes \(limitWords)."
    }

    /// The line under the chips when the message is over: "31 MB · Gmail takes about 25 MB of
    /// attachments".
    static func overTheLimit(bytes: Int) -> String {
        "\(MailAttachmentSize.text(bytes)) \u{00B7} Gmail takes \(limitWords)"
    }

    /// The line under the chips otherwise: "3 attachments · 2.4 MB".
    static func summary(count: Int, bytes: Int) -> String {
        "\(count) \(count == 1 ? "attachment" : "attachments") \u{00B7} \(MailAttachmentSize.text(bytes))"
    }

    static func couldNotAttach(_ name: String) -> String {
        "Couldn\u{2019}t attach \u{201C}\(name)\u{201D}."
    }

    /// Sending a message that is over.
    static let tooLargeToSend = MailToast(
        text: "Too large for Gmail, which takes \(limitWords). Remove one to send.", action: nil)

    static func removed(_ name: String) -> MailToast {
        MailToast(text: "Removed \u{201C}\(name)\u{201D}", action: .undo)
    }

    /// Under a program in a message: it is never opened.
    static let program = "A program. It is not opened here."

    /// Under a file whose name says it is something else than it is.
    static func nameSays(_ kind: String) -> String {
        "Its name says \(kind)."
    }

    /// Paste, when there is no file or picture to paste.
    static let nothingToPaste = "There is no file or picture to paste."
}

#endif
