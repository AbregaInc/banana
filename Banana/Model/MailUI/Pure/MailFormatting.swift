#if !BANANA_PUBLIC
import SwiftUI

/// The kinds of line the editor makes by a mark at its start (see `MailRichText`).
enum MailParagraphKind: Equatable, Sendable {
    case bullet, number, quote

    init(_ kind: MailRichText.Mark.Kind) {
        switch kind {
        case .bullet: self = .bullet
        case .number: self = .number
        case .quote: self = .quote
        }
    }
}

/// What the format bar shows of the selection: which of the formats it has all of.
struct MailFormatState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var link: URL?
    /// The kind of the line the selection begins in.
    var paragraph: MailParagraphKind?
    /// Whether any text is selected: a link is made of selected words.
    var hasSelection = false
}

/// Changing the format of the selection and of the lines it touches, on the text the editor holds.
/// Pure: the text and the selection come in, and go out changed. The editor keeps the selection
/// through all of it (`AttributedString.transform(updating:)`).
enum MailFormatting {

    enum Trait: Sendable, CaseIterable {
        case bold, italic, underline

        /// The letter of its ⌘ chord, which is every Mac text editor's. Where an editor takes the
        /// chord itself (UIKit's does) nothing here is needed; the Mac has no Format menu to carry
        /// it to an `NSTextView`, so the composer binds it (`MailComposerBodyArea`) to the same
        /// toggle the format bar's button runs.
        var chordKey: Character {
            switch self {
            case .bold: "b"
            case .italic: "i"
            case .underline: "u"
            }
        }
    }

    // MARK: - What the selection has

    static func state(of text: AttributedString, in selection: AttributedTextSelection,
                      fonts: Font.Context = MailRichText.fonts) -> MailFormatState {
        var state = MailFormatState()
        switch selection.indices(in: text) {
        case .insertionPoint:
            apply(selection.typingAttributes(in: text), to: &state, fonts: fonts)
        case .ranges(let ranges):
            state.hasSelection = ranges.ranges.contains { !$0.isEmpty }
            var bold = true, italic = true, underline = true
            var link: URL?
            var linkAll = true
            var seen = false
            for container in selection.attributes(in: text) {
                seen = true
                var one = MailFormatState()
                apply(container, to: &one, fonts: fonts)
                bold = bold && one.bold
                italic = italic && one.italic
                underline = underline && one.underline
                if let found = one.link {
                    if let link, link != found { linkAll = false }
                    link = link ?? found
                } else {
                    linkAll = false
                }
            }
            if seen {
                state.bold = bold
                state.italic = italic
                state.underline = underline
                state.link = linkAll ? link : nil
            } else {
                apply(selection.typingAttributes(in: text), to: &state, fonts: fonts)
            }
        }
        if let mark = firstLine(of: text, selection: selection).flatMap({ MailRichText.mark(of: $0.text) }) {
            state.paragraph = MailParagraphKind(mark.kind)
        }
        return state
    }

    private static func apply(_ container: AttributeContainer, to state: inout MailFormatState, fonts: Font.Context) {
        if let font = container.font {
            let traits = font.resolve(in: fonts)
            state.bold = traits.isBold
            state.italic = traits.isItalic
        }
        state.underline = container.underlineStyle != nil
        state.link = container.link
    }

    // MARK: - Bold, italic, underline, link

    /// Turns a trait on for the selection, or off if all of it has it; with no selection, for what
    /// is typed next.
    static func toggle(_ trait: Trait, in text: inout AttributedString, selection: inout AttributedTextSelection,
                       fonts: Font.Context = MailRichText.fonts) {
        let now = state(of: text, in: selection, fonts: fonts)
        switch trait {
        case .bold:
            let on = !now.bold
            text.transformAttributes(in: &selection) { container in
                container.font = (container.font ?? .body).bold(on)
            }
        case .italic:
            let on = !now.italic
            text.transformAttributes(in: &selection) { container in
                container.font = (container.font ?? .body).italic(on)
            }
        case .underline:
            let on = !now.underline
            text.transformAttributes(in: &selection) { container in
                container.underlineStyle = on ? .single : nil
            }
        }
    }

    /// Makes the selected words a link, or takes the link off them (`nil`). Nothing happens with
    /// nothing selected, or for an address that is not `http`, `https` or `mailto`.
    static func setLink(_ url: URL?, in text: inout AttributedString, selection: inout AttributedTextSelection) {
        guard hasSelectedText(text, selection) else { return }
        if let url, MailBodyHTML.safeLink(url) == nil { return }
        text.transformAttributes(in: &selection) { container in
            container.link = url
        }
    }

    static func hasSelectedText(_ text: AttributedString, _ selection: AttributedTextSelection) -> Bool {
        if case .ranges(let ranges) = selection.indices(in: text) { return ranges.ranges.contains { !$0.isEmpty } }
        return false
    }

    /// The words selected.
    static func selectedText(_ text: AttributedString, _ selection: AttributedTextSelection) -> String {
        guard case .ranges(let ranges) = selection.indices(in: text) else { return "" }
        return ranges.ranges.map { String(text[$0].characters) }.joined()
    }

    /// An address as he typed it, as a link: "example.com" is `https://example.com`, "a@b.example" is
    /// `mailto:`, and what is not an address (or is not allowed) is nil.
    static func link(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.contains("://") || text.lowercased().hasPrefix("mailto:") {
            // As it is.
        } else if text.contains("@"), !text.contains("/") {
            text = "mailto:" + text
        } else {
            text = "https://" + text
        }
        return MailBodyHTML.safeLink(URL(string: text))
    }

    /// Whether selected words are already an address, so that the link key needs no question.
    static func looksLikeAnAddress(_ words: String) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        return text.contains("://") || text.contains("@") || text.contains(".")
    }

    // MARK: - Lists and quotes

    /// A line the selection touches: where it starts (in characters), and what it says.
    struct Line: Equatable {
        var start: Int
        var text: String
        var mark: MailRichText.Mark? { MailRichText.mark(of: text) }
    }

    /// The lines a selection touches. A selection that ends at the very start of a line does not
    /// touch it.
    static func lines(of text: AttributedString, selection: AttributedTextSelection) -> [Line] {
        let characters = Array(text.characters)
        let count = characters.count
        func offset(_ index: AttributedString.Index) -> Int { text.characters.distance(from: text.startIndex, to: index) }
        var first = 0, last = 0
        switch selection.indices(in: text) {
        case .insertionPoint(let index):
            first = offset(index); last = first
        case .ranges(let ranges):
            guard let low = ranges.ranges.first, let high = ranges.ranges.last else { return [] }
            first = offset(low.lowerBound); last = offset(high.upperBound)
            if last > first, last > 0, characters[last - 1] == "\n" { last -= 1 }
        }
        first = min(max(first, 0), count)
        last = min(max(last, first), count)
        var start = first
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        var lines: [Line] = []
        while true {
            var end = start
            while end < count, characters[end] != "\n" { end += 1 }
            lines.append(Line(start: start, text: String(characters[start..<end])))
            if end >= last || end >= count { break }
            start = end + 1
        }
        return lines
    }

    private static func firstLine(of text: AttributedString, selection: AttributedTextSelection) -> Line? {
        lines(of: text, selection: selection).first
    }

    /// Makes the lines he has selected (or the one the caret is in) bullets, a numbered list, or a
    /// quote; or, if all of them already are, plain lines again. A line of another kind is changed
    /// to this one. Numbers begin at 1.
    static func toggle(_ kind: MailParagraphKind, in text: inout AttributedString,
                       selection: inout AttributedTextSelection) {
        let touched = lines(of: text, selection: selection)
        guard !touched.isEmpty else { return }
        let removing = touched.allSatisfy { $0.mark.map { MailParagraphKind($0.kind) } == kind }
        let caret = collapsedCaret(in: text, selection)

        text.transform(updating: &selection) { edited in
            for (index, line) in touched.enumerated().reversed() {
                let oldLength = line.mark?.length ?? 0
                var at = edited.index(edited.startIndex, offsetByCharacters: line.start)
                if oldLength > 0 {
                    edited.removeSubrange(at..<edited.index(at, offsetByCharacters: oldLength))
                    at = edited.index(edited.startIndex, offsetByCharacters: line.start)
                }
                let mark = removing ? "" : newMark(kind, number: index + 1)
                if !mark.isEmpty { edited.insert(AttributedString(mark), at: at) }
            }
        }
        // A caret at the start of a line, or inside its old mark, goes after the new mark: the
        // editor leaves one at the edge of an insertion where it was.
        if let caret, let line = touched.first {
            let oldLength = line.mark?.length ?? 0
            let newLength = removing ? 0 : newMark(kind, number: 1).count
            let moved = caret <= line.start + oldLength ? line.start + newLength : caret + newLength - oldLength
            selection = AttributedTextSelection(insertionPoint: text.index(text.startIndex, offsetByCharacters: moved))
        }
    }

    private static func newMark(_ kind: MailParagraphKind, number: Int) -> String {
        switch kind {
        case .bullet: return MailRichText.bullet
        case .number: return "\(number). "
        case .quote: return "> "
        }
    }

    private static func collapsedCaret(in text: AttributedString, _ selection: AttributedTextSelection) -> Int? {
        guard case .insertionPoint(let index) = selection.indices(in: text) else { return nil }
        return text.characters.distance(from: text.startIndex, to: index)
    }

    // MARK: - Return in a list

    /// He pressed Return: `old` is the text before and `text` is the text now, which has one more
    /// character, a line break, put in at the caret. If the line it ended is a list item or a quote
    /// the next line begins with the same mark (a numbered list counts on); and if that line was
    /// nothing but its mark, the list ends: the mark goes, and no new line is made. Returns whether
    /// it did anything.
    @discardableResult
    static func continueAfterReturn(from old: AttributedString, text: inout AttributedString,
                                    selection: inout AttributedTextSelection) -> Bool {
        let before = Array(old.characters)
        let after = Array(text.characters)
        // What arrived is a Return, and perhaps the letters typed straight after it: keys can
        // come faster than the editor's updates, and then one change holds "\n" and "s". The run
        // begins with the line break, or this was not a Return; what follows it is kept, after
        // the mark, as the start of the next item.
        let inserted = after.count - before.count
        guard inserted >= 1 else { return false }
        var at = 0
        while at < before.count, before[at] == after[at] { at += 1 }
        guard at < after.count, after[at] == "\n",
              Array(after[(at + inserted)...]) == Array(before[at...]) else { return false }
        let typedAfter = inserted - 1

        var start = at
        while start > 0, after[start - 1] != "\n" { start -= 1 }
        let line = String(after[start..<at])
        guard let mark = MailRichText.mark(of: line) else { return false }

        if line.count == mark.length {
            // The list is over: its empty last line is what the Return ends. Letters typed with
            // it begin the plain line that takes its place.
            text.transform(updating: &selection) { edited in
                let from = edited.index(edited.startIndex, offsetByCharacters: start)
                edited.removeSubrange(from..<edited.index(from, offsetByCharacters: mark.length + 1))
            }
            selection = AttributedTextSelection(
                insertionPoint: text.index(text.startIndex, offsetByCharacters: start + typedAfter))
            return true
        }
        let next: String
        switch mark.kind {
        case .bullet: next = String(line.prefix(mark.length))
        case .number(let number): next = "\(number + 1). "
        case .quote: next = String(line.prefix(mark.length))
        }
        text.transform(updating: &selection) { edited in
            edited.insert(AttributedString(next), at: edited.index(edited.startIndex, offsetByCharacters: at + 1))
        }
        selection = AttributedTextSelection(
            insertionPoint: text.index(text.startIndex, offsetByCharacters: at + 1 + next.count + typedAfter))
        return true
    }
}

#endif
