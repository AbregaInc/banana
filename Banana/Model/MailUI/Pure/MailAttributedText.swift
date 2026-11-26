#if !BANANA_PUBLIC
import Foundation

/// The one place a message's meaning (`MailText`) becomes text with styles (MAIL-UX: "the UI
/// maps it to attributed text with its own type styles, in one place"). No HTML is parsed here
/// or anywhere in a screen; the engine has already said what the message means.
///
/// Safe links use the system URL action on iOS, iPadOS and macOS.
enum MailAttributedText {
    private static let addresses = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func mailbox(for link: URL) -> String? {
        guard link.scheme?.lowercased() == "mailto",
              let parts = URLComponents(url: link, resolvingAgainstBaseURL: false), parts.host == nil,
              MailAddressRules.isValid(parts.path) else { return nil }
        return parts.path
    }

    /// One block's runs, with their styles.
    static func make(_ runs: [MailTextRun], detectAddresses: Bool = false) -> AttributedString {
        guard let first = runs.first else { return AttributedString() }
        var out = styled(first, detectAddresses: detectAddresses)
        for run in runs.dropFirst() { out.append(styled(run, detectAddresses: detectAddresses)) }
        return out
    }

    private static func styled(_ run: MailTextRun, detectAddresses: Bool) -> AttributedString {
        var attributes = AttributeContainer()
        var intent = InlinePresentationIntent()
        if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
        if run.style.contains(.italic) { intent.insert(.emphasized) }
        if run.style.contains(.code) { intent.insert(.code) }
        if !intent.isEmpty { attributes.inlinePresentationIntent = intent }
        if let link = MailBodyHTML.safeLink(run.link) { attributes.link = link }
        if run.style.contains(.underline) { attributes.underlineStyle = .single }
        if run.style.contains(.strikethrough) { attributes.strikethroughStyle = .single }
        var piece = AttributedString(run.text, attributes: attributes)
        if detectAddresses, run.link == nil, run.text.utf8.count <= 4_096, run.text.contains("@"),
           let addresses {
            let range = NSRange(run.text.startIndex..<run.text.endIndex, in: run.text)
            for match in addresses.matches(in: run.text, range: range) {
                guard let url = match.url, mailbox(for: url) != nil,
                      let span = Range(match.range, in: run.text),
                      let lo = AttributedString.Index(span.lowerBound, within: piece),
                      let hi = AttributedString.Index(span.upperBound, within: piece) else { continue }
                piece[lo..<hi].link = url
            }
        }
        return piece
    }

    /// Every block of a message, styled, with addresses made links. Its fonts are applied by the
    /// view, so the result does not depend on the pane's width or text size.
    static func blocks(_ text: MailText) -> [AttributedString] { text.blocks.map { make($0.runs, detectAddresses: true) } }

    /// The body's text as the reader draws it: `.text`'s text, or `.designed`'s plain text.
    static func blocks(_ body: MailBody) -> [AttributedString]? {
        displayText(in: body).map { blocks($0) }
    }

    /// Prepare the beginning and expensive paragraphs off the main thread. A lazy row
    /// can style a short later paragraph when the reader actually scrolls to it.
    static func openingBlocks(_ body: MailBody) -> [AttributedString?]? {
        guard let text = displayText(in: body) else { return nil }
        return text.blocks.enumerated().map { index, block in
            if index < 64 || block.runs.count > 8 { return make(block.runs, detectAddresses: true) }
            var bytes = 0
            for run in block.runs {
                bytes += run.text.utf8.count + (run.link?.absoluteString.utf8.count ?? 0)
                if bytes > 1024 { return make(block.runs, detectAddresses: true) }
            }
            return nil
        }
    }

    private static func displayText(in body: MailBody) -> MailText? {
        switch body {
        case .text(let text, _, _): return text
        case .designed(_, _, _, let plain, _): return plain
        case .notOnDevice: return nil
        }
    }

    /// The block's text without styles: for a snippet, a test, or VoiceOver.
    static func plain(_ runs: [MailTextRun]) -> String {
        runs.map(\.text).joined()
    }
}

#endif
