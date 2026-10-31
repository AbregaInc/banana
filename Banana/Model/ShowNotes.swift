import Foundation

/// Show notes, which arrive as HTML, as text SwiftUI can draw: paragraphs and line breaks kept,
/// list items as bullets, links still links, entities decoded, everything else dropped.
///
/// This replaced WebKit's HTML importer (`NSAttributedString` with `.documentType: .html`). That
/// importer has to run on the main thread and spins a nested run loop while it loads; called from
/// the Episode info sheet's body it ran on every render and froze the app. This is plain string
/// work: fast, and safe off the main thread.
enum ShowNotes {
    static func attributed(_ html: String) -> AttributedString? {
        let source = html
            .replacing(/<!--[\s\S]*?-->/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        var builder = Builder()
        let tag = /<(\/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>/
        let matches = source.matches(of: tag)
        if matches.isEmpty {
            // Plain text: its line breaks are real.
            builder.appendPlain(decodeEntities(source))
            return builder.result()
        }
        var cursor = source.startIndex
        var skipping: String?   // inside <script> or <style>
        for match in matches {
            if skipping == nil { builder.appendHTMLText(decodeEntities(String(source[cursor..<match.range.lowerBound]))) }
            cursor = match.range.upperBound
            let closing = match.output.1 == "/"
            let name = match.output.2.lowercased()
            if let skipped = skipping {
                if closing && name == skipped { skipping = nil }
                continue
            }
            switch name {
            case "script", "style":
                if !closing { skipping = name }
            case "br":
                builder.lineBreak()
            case "p", "div", "blockquote", "section", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr":
                builder.paragraphBreak()
            case "li":
                if !closing {
                    builder.lineBreak()
                    builder.appendRaw("\u{2022} ")
                }
            case "ul", "ol":
                builder.lineBreak()
            case "a":
                builder.link = closing ? nil : href(in: String(match.output.3))
            default:
                break
            }
        }
        if skipping == nil { builder.appendHTMLText(decodeEntities(String(source[cursor...]))) }
        return builder.result()
    }

    /// The link an `<a>` tag points at — web and mail links only.
    static func href(in attributes: String) -> URL? {
        guard let match = attributes.firstMatch(of: /(?i)href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) else { return nil }
        let raw = String(match.output.1 ?? match.output.2 ?? match.output.3 ?? "")
        guard let url = URL(string: decodeEntities(raw).trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "bull": "\u{2022}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});/) { match in
            let body = String(match.output.1)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
            }
            return named[body.lowercased()] ?? String(match.output.0)
        }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Runs of text, laid out the way a browser would: whitespace collapsed, and breaks between
    /// blocks owed until the next text arrives, so a closing tag at the end adds nothing.
    private struct Builder {
        var runs: [(text: String, link: URL?)] = []
        var link: URL?
        private var owedBreaks = 0
        private var atStart = true
        private var endsWithSpace = true

        mutating func appendHTMLText(_ text: String) {
            var collapsed = text.replacing(/\s+/, with: " ")
            if owedBreaks > 0 || atStart || endsWithSpace {
                collapsed = String(collapsed.drop { $0 == " " })
            }
            guard !collapsed.isEmpty else { return }
            payBreaks()
            runs.append((collapsed, link))
            atStart = false
            endsWithSpace = collapsed.hasSuffix(" ")
        }

        mutating func appendPlain(_ text: String) {
            runs.append((text, nil))
            atStart = false
        }

        mutating func appendRaw(_ text: String) {
            payBreaks()
            runs.append((text, nil))
            atStart = false
            endsWithSpace = text.hasSuffix(" ")
        }

        mutating func lineBreak() { if !atStart { owedBreaks = max(owedBreaks, 1) } }
        mutating func paragraphBreak() { if !atStart { owedBreaks = max(owedBreaks, 2) } }

        private mutating func payBreaks() {
            guard owedBreaks > 0 else { return }
            if let last = runs.indices.last, runs[last].text.hasSuffix(" ") {
                runs[last].text.removeLast()
            }
            runs.append((String(repeating: "\n", count: owedBreaks), nil))
            owedBreaks = 0
            endsWithSpace = true
        }

        func result() -> AttributedString? {
            var out = AttributedString()
            for run in runs {
                var piece = AttributedString(run.text)
                if let url = run.link { piece.link = url }
                out += piece
            }
            // Drop trailing whitespace.
            while let last = out.characters.last, last.isWhitespace {
                out.removeSubrange(out.index(beforeCharacter: out.endIndex)..<out.endIndex)
            }
            guard !out.characters.isEmpty else { return nil }
            // Bare addresses in the text become links too.
            let plain = String(out.characters)
            if let detector = ShowNotes.linkDetector {
                for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                    guard let url = match.url, let range = Range(match.range, in: plain),
                          let lower = AttributedString.Index(range.lowerBound, within: out),
                          let upper = AttributedString.Index(range.upperBound, within: out),
                          out[lower..<upper].link == nil else { continue }
                    out[lower..<upper].link = url
                }
            }
            return out
        }
    }
}
