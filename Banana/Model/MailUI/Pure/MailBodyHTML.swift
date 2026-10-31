#if !BANANA_PUBLIC
import Foundation

/// What a message he wrote is, in the two forms it is sent in: clean HTML and plain text, made
/// from the contract's `MailText` (what the composer keeps as the draft's body).
///
/// **This is the one serialiser, and it is written by hand on purpose.** No system call makes
/// mail-safe HTML: `NSAttributedString`'s HTML conversion runs WebKit on the main thread and
/// writes pages of inline style, so it is forbidden in this codebase. What is written here is only
/// `p`, `br`, `b`, `i`, `u`, `a href`, `ul`/`ol`/`li` and `blockquote`, with everything escaped and
/// a link kept only if it is `http`, `https` or `mailto`. Nothing a person could paste — a font, a
/// colour, a size, a script — has anywhere to go.
///
/// The plain-text alternative is the same message for a reader that cannot show HTML: lists are
/// "- " and "1. " lines, a quote is "> " lines, and a link is "text (address)".
enum MailBodyHTML {

    /// The only schemes a link in a message he writes may have.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// How deep a quote goes: a quote of a quote of a quote, and no further.
    static let maxQuoteDepth = 5

    /// The link as it may be sent: `http`, `https` or `mailto`, with an address in it, and nothing
    /// that is not printable. Anything else (`javascript:`, `data:`, `file:`, a bare word, a scheme
    /// hidden among control characters) is not a link and the words it covered are only words.
    static func safeLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        let text = url.absoluteString
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.properties.isWhitespace })
        else { return nil }
        if scheme == "mailto" {
            return text.count > "mailto:".count ? url : nil
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - HTML

    /// The message as HTML: paragraphs, with a line break for each line break inside one; lists;
    /// quotes. Nothing at all, or only white space, is the empty string.
    static func html(_ text: MailText) -> String {
        let blocks = trimmed(text.blocks)
        guard !blocks.isEmpty else { return "" }
        var out = ""
        var lines: [String] = []          // the paragraph being gathered
        var blanks = 0                     // empty lines since the last content
        var list: Bool?                    // an open list: true if ordered
        var quoteDepth = 0
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !lines.isEmpty else { return }
            out += "<p>" + lines.joined(separator: "<br>") + "</p>"
            lines = []
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            out += "<p>" + quoteLines.joined(separator: "<br>") + "</p>"
            quoteLines = []
        }
        func closeList() {
            if let ordered = list { out += ordered ? "</ol>" : "</ul>" }
            list = nil
        }
        func closeQuote() {
            flushQuote()
            while quoteDepth > 0 { out += "</blockquote>"; quoteDepth -= 1 }
        }
        for block in blocks {
            let empty = isEmpty(block)
            switch block.kind {
            case .quote(let rawDepth):
                let depth = min(max(rawDepth, 1), maxQuoteDepth)
                // A quote that begins with nothing is only an empty line.
                if empty, quoteDepth == 0 {
                    if !lines.isEmpty { flushParagraph(); blanks = 1 } else { blanks += 1 }
                    continue
                }
                if quoteDepth == 0 {
                    flushParagraph()
                    closeList()
                    if blanks > 1 { out += String(repeating: "<p><br></p>", count: blanks - 1) }
                    blanks = 0
                }
                if depth != quoteDepth {
                    flushQuote()
                    while quoteDepth < depth { out += "<blockquote>"; quoteDepth += 1 }
                    while quoteDepth > depth { out += "</blockquote>"; quoteDepth -= 1 }
                }
                if empty { flushQuote() } else { quoteLines.append(inline(block.runs)) }
            case .item(let ordered, _, _):
                if quoteDepth > 0 { closeQuote() }
                flushParagraph()
                if list != ordered {
                    closeList()
                    if blanks > 1 { out += String(repeating: "<p><br></p>", count: blanks - 1) }
                    blanks = 0
                    out += ordered ? "<ol>" : "<ul>"
                    list = ordered
                }
                // An item with nothing in it is not a line of the list.
                if !empty { out += "<li>" + inline(block.runs) + "</li>" }
            case .paragraph, .heading, .preformatted, .rule:
                if quoteDepth > 0 { closeQuote() }
                closeList()
                if empty {
                    if !lines.isEmpty { flushParagraph(); blanks = 1 } else { blanks += 1 }
                } else {
                    if lines.isEmpty, blanks > 1 { out += String(repeating: "<p><br></p>", count: blanks - 1) }
                    blanks = 0
                    lines.append(block.kind == .rule ? "---" : inline(block.runs))
                }
            }
        }
        flushParagraph()
        closeList()
        closeQuote()
        return out
    }

    /// The runs of one line as HTML. Adjacent runs that look the same are one; a link is `a`, and
    /// is not also underlined, because it is already.
    private static func inline(_ runs: [MailTextRun]) -> String {
        var out = ""
        var afterSpace = true      // a space at the start of a line counts as a second one
        for run in coalesced(runs) {
            var piece = escaped(run.text, afterSpace: &afterSpace)
            if run.style.contains(.underline), safeLink(run.link) == nil { piece = "<u>" + piece + "</u>" }
            if run.style.contains(.italic) { piece = "<i>" + piece + "</i>" }
            if run.style.contains(.bold) { piece = "<b>" + piece + "</b>" }
            if let link = safeLink(run.link) {
                piece = "<a href=\"" + escaped(link.absoluteString) + "\">" + piece + "</a>"
            }
            out += piece
        }
        return out
    }

    /// `& < > " '` made safe. For an address in an attribute, and for anything else that is not
    /// a line of text.
    static func escaped(_ text: String) -> String {
        var afterSpace = false
        return escaped(text, afterSpace: &afterSpace)
    }

    /// `escaped`, and a line break inside a run made `<br>`, and spaces that a reader would fold
    /// away (the second of two in a row, or one at the start of a line) kept as `&nbsp;`.
    private static func escaped(_ text: String, afterSpace: inout Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"; afterSpace = false
            case "<": out += "&lt;"; afterSpace = false
            case ">": out += "&gt;"; afterSpace = false
            case "\"": out += "&quot;"; afterSpace = false
            case "'": out += "&#39;"; afterSpace = false
            case "\n", "\r\n", "\r": out += "<br>"; afterSpace = true
            case " ":
                out += afterSpace ? "&nbsp;" : " "
                afterSpace = true
            default:
                out.append(character); afterSpace = false
            }
        }
        return out
    }

    // MARK: - Plain text

    /// The message as plain text: one line for each line he wrote; lists as "- " and "1. "; a quote
    /// as "> "; a link as "text (address)", or the address alone where that is what it said.
    static func plain(_ text: MailText) -> String {
        let blocks = trimmed(text.blocks)
        guard !blocks.isEmpty else { return "" }
        var lines: [String] = []
        var number = 0
        var inOrdered = false
        for block in blocks {
            if case .item(let ordered, _, _) = block.kind {
                if ordered {
                    number = inOrdered ? number + 1 : 1
                    inOrdered = true
                    lines.append("\(number). " + plainInline(block.runs))
                } else {
                    inOrdered = false
                    lines.append("- " + plainInline(block.runs))
                }
                continue
            }
            inOrdered = false
            switch block.kind {
            case .quote(let depth):
                let marks = String(repeating: ">", count: min(max(depth, 1), maxQuoteDepth))
                let line = plainInline(block.runs)
                lines.append(line.isEmpty ? marks : marks + " " + line)
            case .rule:
                lines.append("---")
            default:
                lines.append(plainInline(block.runs))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func plainInline(_ runs: [MailTextRun]) -> String {
        var out = ""
        for run in coalesced(runs) {
            guard let link = safeLink(run.link) else { out += run.text; continue }
            let address = link.absoluteString
            let shown = run.text.trimmingCharacters(in: .whitespaces)
            let bare = address.hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)) : address
            if shown.isEmpty {
                out += bare
            } else if shown == address || shown == bare {
                out += run.text
            } else {
                out += run.text + " (" + bare + ")"
            }
        }
        return out
    }

    // MARK: - Shared

    /// Without the empty lines before the first thing said and after the last.
    private static func trimmed(_ blocks: [MailTextBlock]) -> [MailTextBlock] {
        var first = 0
        var last = blocks.count
        while first < last, isEmpty(blocks[first]) { first += 1 }
        while last > first, isEmpty(blocks[last - 1]) { last -= 1 }
        return Array(blocks[first..<last])
    }

    /// Nothing in it but white space.
    private static func isEmpty(_ block: MailTextBlock) -> Bool {
        if case .rule = block.kind { return false }
        return block.runs.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
    }

    /// Neighbours with the same look are one run, so `<b>a</b><b>b</b>` is never written.
    private static func coalesced(_ runs: [MailTextRun]) -> [MailTextRun] {
        var out: [MailTextRun] = []
        for run in runs where !run.text.isEmpty {
            let style = run.style.intersection([.bold, .italic, .underline])
            let link = safeLink(run.link)
            if var last = out.last, last.style == style, last.link == link {
                last.text += run.text
                out[out.count - 1] = last
            } else {
                out.append(MailTextRun(text: run.text, style: style, link: link))
            }
        }
        return out
    }
}

#endif
