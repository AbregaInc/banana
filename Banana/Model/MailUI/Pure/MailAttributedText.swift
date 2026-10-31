#if !BANANA_PUBLIC
import Foundation

/// The one place a message's meaning (`MailText`) becomes text with styles (MAIL-UX: "the UI
/// maps it to attributed text with its own type styles, in one place"). No HTML is parsed here
/// or anywhere in a screen; the engine has already said what the message means.
///
/// A link's address is kept off the result on purpose: the slice shows a link as underlined text
/// and opens nothing. Links open through `MailLinkRules` (MAIL-UX 10.7), which a later package
/// brings.
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
            if run.style.contains(.underline) || run.link != nil { piece.underlineStyle = .single }
            if run.style.contains(.strikethrough) { piece.strikethroughStyle = .single }
            out.append(piece)
        }
        return out
    }

    /// The block's text without styles: for a snippet, a test, or VoiceOver.
    static func plain(_ runs: [MailTextRun]) -> String {
        runs.map(\.text).joined()
    }
}

#endif
