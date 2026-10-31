#if !BANANA_PUBLIC
import Foundation

/// What a plain-text draft is, in the two forms it has: the string the person edits, and the
/// contract's `MailText` the source stores. The composer is plain text only, so a line is a
/// paragraph and nothing else is read or written.
enum MailPlainText {

    /// One paragraph for each line, and an empty one for each blank line, so a body comes back as
    /// it was typed. No text at all is no blocks.
    static func text(_ string: String) -> MailText {
        guard !string.isEmpty else { return MailText(blocks: []) }
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        return MailText(blocks: lines.map { line in
            MailTextBlock(kind: .paragraph, runs: line.isEmpty ? [] : [MailTextRun(text: String(line))])
        })
    }

    /// The way back. A quote is written as the `> ` lines it was, a list item as the "- " or "1. "
    /// line it was, and any other block as its text: nothing is dropped. (Bold, italic and links are
    /// not in a string; `MailRichText` is the way back with them.)
    static func string(_ text: MailText) -> String {
        var numbered = 0
        return text.blocks.map { block -> String in
            let line = MailAttributedText.plain(block.runs)
            switch block.kind {
            case .quote(let depth):
                numbered = 0
                return String(repeating: ">", count: max(depth, 1)) + " " + line
            case .item(let ordered, _, let number):
                if ordered {
                    numbered = number ?? (numbered + 1)
                    return "\(numbered). " + line
                }
                numbered = 0
                return "- " + line
            default:
                numbered = 0
                return line
            }
        }.joined(separator: "\n")
    }

    /// The first line with something on it, white space collapsed: what a row says of a draft.
    static func firstLine(_ string: String) -> String {
        for line in string.split(separator: "\n") {
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !collapsed.isEmpty { return collapsed }
        }
        return ""
    }

    /// Whether there is anything in it but white space.
    static func isBlank(_ string: String) -> Bool {
        string.allSatisfy(\.isWhitespace)
    }
}

#endif
