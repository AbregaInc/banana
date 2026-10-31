#if !BANANA_PUBLIC
import Foundation
import UniformTypeIdentifiers

/// What an attachment is, as the system says it (`UTType`), for the symbol, the words and the one
/// question that matters for safety: is it a program. No table of extensions is kept here and no
/// bytes are read by hand; the contract's `mimeType` is what the engine found the bytes to be, and
/// the file's name is what the sender called it.
///
/// **A file whose name and type disagree is shown as what it is** (the symbol and the words are of
/// the real type) **and says so**: "Its name says PDF document." The name is never trusted to pick
/// the symbol, and never to pick how the file is opened.
struct MailAttachmentKind: Equatable, Sendable {
    /// What the bytes are. Nil only when the system knows neither the type nor the name's.
    var type: UTType?
    /// An SF Symbol.
    var symbol: String
    /// "PDF document", "PNG image": the system's own words for the type, or "File".
    var label: String
    /// A program, or something that runs when opened. It is never previewed.
    var isProgram: Bool
    /// What the name says it is, when that is not what it is.
    var nameSays: String?

    static func of(name: String, mimeType: String, typeMismatch: Bool = false) -> MailAttachmentKind {
        let byName = type(ofName: name)
        var real = UTType(mimeType: mimeType)
        if real == nil || real == .data || real == .item { real = byName }
        let disagrees: Bool
        if let real, let byName {
            disagrees = typeMismatch || !(real.conforms(to: byName) || byName.conforms(to: real))
        } else {
            disagrees = typeMismatch && byName != nil
        }
        let program = (real.map(isProgram) ?? false) || (byName.map(isProgram) ?? false)
            || runsWhenOpened(name: name)
        return MailAttachmentKind(
            type: real, symbol: program ? "exclamationmark.triangle" : symbol(for: real),
            label: real?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "File",
            isProgram: program, nameSays: disagrees ? byName?.localizedDescription : nil)
    }

    /// What the extension of a name says, by the system's own table.
    static func type(ofName name: String) -> UTType? {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }

    /// Extensions that run when opened and that a given system may not have a type for (the
    /// iPhone's table has no `.command` or `.dmg`). Not a table of types: only a way not to trust a
    /// name the system does not know. Everything else is the system's.
    private static let runWhenOpened: Set<String> = [
        "command", "dmg", "pkg", "app", "exe", "msi", "bat", "cmd", "scr", "ps1", "vbs", "jar", "sh", "workflow",
    ]

    static func runsWhenOpened(name: String) -> Bool {
        runWhenOpened.contains((name as NSString).pathExtension.lowercased())
    }

    static func isProgram(_ type: UTType) -> Bool {
        if type.conforms(to: .executable) || type.conforms(to: .application) || type.conforms(to: .script)
            || type.conforms(to: .diskImage) || type.conforms(to: .unixExecutable) {
            return true
        }
        return UTType("com.apple.installer-package-archive").map { type.conforms(to: $0) } ?? false
    }

    private static func symbol(for type: UTType?) -> String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .emailMessage) { return "envelope" }
        if type.conforms(to: .zip) || type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// An attachment of a received message, as the reader draws it: made once when the conversation
/// arrives, never in a view body. The name is the engine's safe one run through `MailFileName` again
/// (it is shown, and saved under, and a stranger wrote it).
struct MailAttachmentDisplay: Equatable, Identifiable, Sendable {
    var id: MailAttachmentID
    var name: String
    var sizeText: String
    var symbol: String
    var kindText: String
    /// A line under it, in warning: a program, or a name that says something else.
    var note: String?
    var isProgram: Bool
    /// Non-nil when the bytes are on this device and can be looked at.
    var localFile: URL?

    init(_ attachment: MailAttachment) {
        let kind = MailAttachmentKind.of(name: attachment.name, mimeType: attachment.mimeType,
                                         typeMismatch: attachment.typeMismatch)
        id = attachment.id
        name = MailFileName.safe(attachment.name)
        sizeText = MailAttachmentSize.text(attachment.bytes)
        symbol = kind.symbol
        kindText = kind.label
        isProgram = kind.isProgram || attachment.isExecutable
        if isProgram {
            note = MailAttachmentText.program
            symbol = "exclamationmark.triangle"
        } else if let says = kind.nameSays {
            note = MailAttachmentText.nameSays(says)
        }
        localFile = attachment.localFile
    }
}

/// An attachment of a draft, as a chip says it.
struct MailDraftAttachmentDisplay: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var sizeText: String
    var symbol: String
    var isProgram: Bool
    var file: URL?

    init(_ attachment: MailDraftAttachment) {
        let kind = MailAttachmentKind.of(name: attachment.name, mimeType: "")
        id = attachment.id
        name = MailFileName.safe(attachment.name)
        sizeText = MailAttachmentSize.text(attachment.bytes)
        isProgram = kind.isProgram || attachment.isExecutable
        symbol = isProgram ? "exclamationmark.triangle" : kind.symbol
        file = attachment.file
    }
}

#endif
