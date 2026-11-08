#if !BANANA_PUBLIC
import Foundation

/// The one place a message's meaning (`MailText`) becomes text with styles (MAIL-UX: "the UI
/// maps it to attributed text with its own type styles, in one place"). No HTML is parsed here
/// or anywhere in a screen; the engine has already said what the message means.
///
/// Safe links use the system URL action on iOS, iPadOS and macOS.
enum MailAttributedText {

    /// One block's runs, with their styles.
    static func make(_ runs: [MailTextRun]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent = InlinePresentationIntent()
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if run.style.contains(.code) { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let link = MailBodyHTML.safeLink(run.link) { piece.link = link }
            if run.style.contains(.underline) { piece.underlineStyle = .single }
            if run.style.contains(.strikethrough) { piece.strikethroughStyle = .single }
            out.append(piece)
        }
        return out
    }

    /// Every block of a message, styled: made once, off the main thread, when the body arrives
    /// (`MailReaderModel`), so drawing an open message builds no attributed text. Its fonts are
    /// applied by the view, so the result does not depend on the pane's width or text size.
    static func blocks(_ text: MailText) -> [AttributedString] { text.blocks.map { make($0.runs) } }

    /// The body's text as the reader draws it: `.text`'s text, or `.designed`'s plain text.
    static func blocks(_ body: MailBody) -> [AttributedString]? {
        switch body {
        case .text(let text, _, _): return blocks(text)
        case .designed(_, _, _, let plain, _): return blocks(plain)
        case .notOnDevice: return nil
        }
    }

    /// The block's text without styles: for a snippet, a test, or VoiceOver.
    static func plain(_ runs: [MailTextRun]) -> String {
        runs.map(\.text).joined()
    }
}

#endif
