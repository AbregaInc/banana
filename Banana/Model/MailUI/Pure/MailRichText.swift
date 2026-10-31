#if !BANANA_PUBLIC
import SwiftUI

/// The body he writes, between the two forms it has: the `AttributedString` the system's text
/// editor holds, and the contract's `MailText` the draft keeps and the sender serialises
/// (`MailBodyHTML`).
///
/// **What the editor holds.** `TextEditor` over an `AttributedString` edits bold, italic (as the
/// `font`), underline and links, and keeps the selection and the typing attributes through them.
/// It has no list or quote model: `PresentationIntent`, paragraph styles and `NSTextList` are kept
/// and drawn as nothing. So **a list item and a quote line are lines that begin with their mark**:
/// "• " or "- ", "1. ", ">". The mark is what he sees and edits; it is read back into a list item
/// or a quote when the draft is made (`text`), and written back when the draft is opened
/// (`attributed`). Nothing else about a line is kept: paragraphs are lines, and a blank line
/// separates them.
enum MailRichText {

    /// What a bullet is written as when the editor is given one.
    static let bullet = "\u{2022} "

    /// The font context that bold and italic are read through. The default one tells the traits of
    /// a font as well as the view's does: they belong to the font, not to the environment.
    static let fonts = EnvironmentValues().fontResolutionContext

    // MARK: - Marks

    /// What a line begins with that makes it a list item or a quote.
    struct Mark: Equatable {
        enum Kind: Equatable {
            case bullet
            case number(Int)
            case quote(Int)
        }
        var kind: Kind
        /// How many characters the mark takes, white space after it included.
        var length: Int
    }

    /// The mark a line begins with, if it has one: "• x" and "- x" are bullets, "3. x" is the third
    /// of a numbered list (up to three digits), ">" is a quote and each further ">" a level deeper.
    static func mark(of line: String) -> Mark? {
        let characters = Array(line)
        guard let first = characters.first else { return nil }
        if (first == "\u{2022}" || first == "-"), characters.count >= 2, characters[1] == " " {
            return Mark(kind: .bullet, length: 2)
        }
        if first == ">" {
            var index = 0
            var depth = 0
            while index < characters.count {
                if characters[index] == ">" {
                    depth += 1
                    index += 1
                } else if characters[index] == " ", index + 1 < characters.count, characters[index + 1] == ">" {
                    index += 1
                } else {
                    break
                }
            }
            if index < characters.count, characters[index] == " " { index += 1 }
            return Mark(kind: .quote(min(depth, MailBodyHTML.maxQuoteDepth)), length: index)
        }
        var digits = 0
        while digits < min(3, characters.count), let value = characters[digits].wholeNumberValue,
              characters[digits].isASCII, (0...9).contains(value) {
            digits += 1
        }
        if digits > 0, characters.count > digits + 1, characters[digits] == ".", characters[digits + 1] == " " {
            let number = Int(String(characters[0..<digits])) ?? 1
            return Mark(kind: .number(number), length: digits + 2)
        }
        return nil
    }

    // MARK: - From the editor to the draft

    /// The body as the draft keeps it: one block for each line, with the mark of a list item or a
    /// quote read off the line, and the runs carrying bold, italic, underline and a safe link.
    /// Nothing at all is no blocks.
    static func text(_ attributed: AttributedString) -> MailText {
        guard !attributed.characters.isEmpty else { return MailText(blocks: []) }
        var lines: [[MailTextRun]] = [[]]
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                // A picture pasted into the editor leaves the "object" character: it is no text.
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            let style = style(of: run)
            let link = MailBodyHTML.safeLink(run.link)
            for (index, segment) in piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { lines.append([]) }
                if !segment.isEmpty {
                    lines[lines.count - 1].append(MailTextRun(text: String(segment), style: style, link: link))
                }
            }
        }
        return MailText(blocks: lines.map(block))
    }

    private static func style(of run: AttributedString.Runs.Run) -> MailTextStyle {
        var style: MailTextStyle = []
        if let font = run.font {
            let traits = font.resolve(in: fonts)
            if traits.isBold { style.insert(.bold) }
            if traits.isItalic { style.insert(.italic) }
        }
        if let intent = run.inlinePresentationIntent {
            if intent.contains(.stronglyEmphasized) { style.insert(.bold) }
            if intent.contains(.emphasized) { style.insert(.italic) }
        }
        if run.underlineStyle != nil { style.insert(.underline) }
        return style
    }

    private static func block(_ line: [MailTextRun]) -> MailTextBlock {
        let plain = line.map(\.text).joined()
        guard let mark = mark(of: plain) else {
            return MailTextBlock(kind: .paragraph, runs: merged(line))
        }
        let kind: MailTextBlock.Kind
        switch mark.kind {
        case .bullet: kind = .item(ordered: false, depth: 0, number: nil)
        case .number(let number): kind = .item(ordered: true, depth: 0, number: number)
        case .quote(let depth): kind = .quote(depth: depth)
        }
        return MailTextBlock(kind: kind, runs: merged(dropping(mark.length, from: line)))
    }

    /// The runs without their first `count` characters.
    private static func dropping(_ count: Int, from runs: [MailTextRun]) -> [MailTextRun] {
        var left = count
        var out: [MailTextRun] = []
        for run in runs {
            if left >= run.text.count {
                left -= run.text.count
                continue
            }
            var kept = run
            kept.text = String(run.text.dropFirst(left))
            left = 0
            out.append(kept)
        }
        return out
    }

    /// Neighbours with one look are one run.
    private static func merged(_ runs: [MailTextRun]) -> [MailTextRun] {
        var out: [MailTextRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = out.last, last.style == run.style, last.link == run.link {
                last.text += run.text
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }

    // MARK: - From the draft to the editor

    /// What the editor is given for a draft's body: each block a line, with its mark written in
    /// front, and bold, italic, underline and links as the editor draws them.
    static func attributed(_ text: MailText) -> AttributedString {
        var out = AttributedString()
        var numbered = 0
        for (index, block) in text.blocks.enumerated() {
            if index > 0 { out.append(AttributedString("\n")) }
            var mark = ""
            switch block.kind {
            case .item(let ordered, _, let number):
                if ordered {
                    numbered = number ?? (numbered + 1)
                    mark = "\(numbered). "
                } else {
                    numbered = 0
                    mark = bullet
                }
            case .quote(let depth):
                numbered = 0
                mark = String(repeating: ">", count: max(depth, 1)) + " "
            case .rule:
                numbered = 0
                mark = "---"
            default:
                numbered = 0
            }
            out.append(AttributedString(mark))
            for run in block.runs {
                out.append(attributed(run, bold: block.isHeading))
            }
        }
        return out
    }

    private static func attributed(_ run: MailTextRun, bold: Bool) -> AttributedString {
        var piece = AttributedString(run.text)
        let isBold = bold || run.style.contains(.bold)
        let isItalic = run.style.contains(.italic)
        if isBold || isItalic { piece.font = Font.body.bold(isBold).italic(isItalic) }
        if run.style.contains(.underline) { piece.underlineStyle = .single }
        if let link = MailBodyHTML.safeLink(run.link) { piece.link = link }
        return piece
    }
}

private extension MailTextBlock {
    var isHeading: Bool {
        if case .heading = kind { return true }
        return false
    }
}

// MARK: - The two forms a message is sent in, from what the editor holds

extension MailBodyHTML {
    /// A message as it goes, in its two forms: what he wrote, then his signature, then the original
    /// he is answering, **each its own part** and none merged into his words. The signature and the
    /// quote are the engine's prepared fragments and are appended exactly as they came; his words are
    /// serialised here. The plain text has the signature after the usual "-- " line and the quote as
    /// "> " lines.
    static func message(body: MailText, signature: MailDraftPart?,
                        quote: MailDraftPart?) -> (html: String, plain: String) {
        var html = Self.html(body)
        var parts: [String] = []
        let words = Self.plain(body)
        if !words.isEmpty { parts.append(words) }
        if let signature {
            html += signature.fragment.html
            if let text = signature.text.map { Self.plain($0) }, !text.isEmpty { parts.append("-- \n" + text) }
        }
        if let quote {
            html += quote.fragment.html
            if let text = quote.text.map { Self.plain($0) }, !text.isEmpty { parts.append(text) }
        }
        return (html, parts.joined(separator: "\n\n"))
    }

    /// The edited text as clean HTML.
    static func html(from attributed: AttributedString) -> String {
        html(MailRichText.text(attributed))
    }

    /// The edited text as plain text.
    static func plain(from attributed: AttributedString) -> String {
        plain(MailRichText.text(attributed))
    }
}

#endif
