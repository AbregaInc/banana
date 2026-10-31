import XCTest
import SwiftUI

/// The body between the editor and the draft: what a line's mark makes of it, what the draft keeps
/// of the editor's text (bold, italic, underline and a safe link, and none of what could be pasted
/// with them), the way back, and the changes the format bar and the keys make to the selection.
final class MailRichTextTests: XCTestCase {

    // MARK: Making text

    private func bold(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.font = .body.bold()
        return piece
    }

    private func italic(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.font = .body.italic()
        return piece
    }

    private func blocks(_ text: AttributedString) -> [MailTextBlock] { MailRichText.text(text).blocks }

    private func at(_ text: AttributedString, _ offset: Int) -> AttributedString.Index {
        text.index(text.startIndex, offsetByCharacters: offset)
    }

    private func caret(_ text: AttributedString, _ offset: Int) -> AttributedTextSelection {
        AttributedTextSelection(insertionPoint: at(text, offset))
    }

    private func range(_ text: AttributedString, _ from: Int, _ to: Int) -> AttributedTextSelection {
        AttributedTextSelection(range: at(text, from)..<at(text, to))
    }

    private func offset(of selection: AttributedTextSelection, in text: AttributedString) -> Int? {
        guard case .insertionPoint(let index) = selection.indices(in: text) else { return nil }
        return text.characters.distance(from: text.startIndex, to: index)
    }

    // MARK: Marks

    func testALineBeginningWithAMarkIsAListItemOrAQuote() {
        func kind(_ line: String) -> MailRichText.Mark.Kind? { MailRichText.mark(of: line)?.kind }
        XCTAssertEqual(kind("\u{2022} item"), .bullet)
        XCTAssertEqual(kind("- item"), .bullet)
        XCTAssertEqual(kind("1. one"), .number(1))
        XCTAssertEqual(kind("12. twelve"), .number(12))
        XCTAssertEqual(kind("> said"), .quote(1))
        XCTAssertEqual(kind(">said"), .quote(1))
        XCTAssertEqual(kind("> > said"), .quote(2))
        XCTAssertEqual(kind(">> said"), .quote(2))
        XCTAssertEqual(MailRichText.mark(of: "- item")?.length, 2)
        XCTAssertEqual(MailRichText.mark(of: "12. twelve")?.length, 4)
        XCTAssertEqual(MailRichText.mark(of: "> > said")?.length, 4)
    }

    func testWhatLooksLikeAMarkButIsNotOneIsText() {
        for line in ["-5 degrees", "a - b", "1.5 million", "2024. A year", "1234. four digits", "1.", "1 . x", "x > y",
                     "\u{2022}no space", "", " - indented"] {
            XCTAssertNil(MailRichText.mark(of: line), line.debugDescription)
        }
    }

    // MARK: From the editor to the draft

    func testNothingIsNoBlocksAndALineIsABlock() {
        XCTAssertEqual(blocks(AttributedString("")), [])
        XCTAssertEqual(blocks(AttributedString("a\nb")).map { MailAttributedText.plain($0.runs) }, ["a", "b"])
        XCTAssertEqual(blocks(AttributedString("a\n\nb")).count, 3)
        XCTAssertEqual(blocks(AttributedString("a\n")).count, 2, "a trailing line break is an empty line")
        XCTAssertEqual(blocks(AttributedString("a\r\nb\rc")).count, 3)
    }

    func testPlainTextStaysPlain() {
        let text = MailRichText.text(AttributedString("Hello there\nsecond line"))
        XCTAssertEqual(text.blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(text.blocks.flatMap(\.runs).map(\.style), [[], []])
        XCTAssertEqual(text.blocks.flatMap(\.runs).map(\.link), [nil, nil])
        XCTAssertEqual(MailPlainText.string(text), "Hello there\nsecond line")
    }

    func testBoldItalicUnderlineAndALinkAreKept() {
        var text = AttributedString("a ")
        text += bold("b")
        text += AttributedString(" ")
        text += italic("i")
        var both = AttributedString(" bi"); both.font = .body.bold().italic(); text += both
        var under = AttributedString(" u"); under.underlineStyle = .single; text += under
        var link = AttributedString(" l"); link.link = URL(string: "https://example.com/x"); text += link

        let runs = blocks(text)[0].runs
        XCTAssertEqual(runs.map(\.text), ["a ", "b", " ", "i", " bi", " u", " l"])
        XCTAssertEqual(runs.map(\.style), [[], .bold, [], .italic, [.bold, .italic], .underline, []])
        XCTAssertEqual(runs.last?.link, URL(string: "https://example.com/x"))
    }

    func testWhatCouldBePastedWithTheFormatsIsNotKept() {
        // A web page's text arrives with its colours, sizes, families and spacing.
        var pasted = AttributedString("Red big struck spaced")
        pasted.foregroundColor = .red
        pasted.backgroundColor = .yellow
        pasted.font = .system(size: 40, design: .serif)
        pasted.strikethroughStyle = .single
        pasted.kern = 4
        pasted.tracking = 3
        pasted.baselineOffset = 8
        let runs = blocks(pasted)[0].runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].style, [], "no bold, italic, underline: nothing of the rest has a place")
        XCTAssertNil(runs[0].link)
        XCTAssertEqual(MailBodyHTML.html(from: pasted), "<p>Red big struck spaced</p>")
    }

    func testAFontThatIsBoldStaysBoldWhateverItsSizeOrFamily() {
        var pasted = AttributedString("loud")
        pasted.font = .system(size: 30, weight: .bold, design: .serif)
        XCTAssertEqual(blocks(pasted)[0].runs[0].style, .bold)
    }

    func testALinkThatIsNotHttpHttpsOrMailtoIsDroppedAndTheWordsStay() {
        var text = AttributedString("click")
        text.link = URL(string: "javascript:alert(1)")
        let runs = blocks(text)[0].runs
        XCTAssertEqual(runs.map(\.text), ["click"])
        XCTAssertNil(runs[0].link)
        XCTAssertEqual(MailBodyHTML.html(from: text), "<p>click</p>")
    }

    func testAPictureLeavesNoTextBehind() {
        XCTAssertEqual(MailPlainText.string(MailRichText.text(AttributedString("a\u{FFFC}b"))), "ab")
    }

    func testLinesWithMarksAreListItemsAndQuotesWithTheirFormatsKept() {
        var text = AttributedString("- ")
        text += bold("bold")
        text += AttributedString(" item\n\u{2022} second\n3. third\n4. fourth\n> quote ")
        text += italic("em")
        let kinds = blocks(text).map(\.kind)
        XCTAssertEqual(kinds, [.item(ordered: false, depth: 0, number: nil), .item(ordered: false, depth: 0, number: nil),
                               .item(ordered: true, depth: 0, number: 3), .item(ordered: true, depth: 0, number: 4),
                               .quote(depth: 1)])
        XCTAssertEqual(blocks(text)[0].runs.map(\.text), ["bold", " item"], "the mark is not part of the words")
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [.bold, []])
        XCTAssertEqual(blocks(text)[4].runs.map(\.text), ["quote ", "em"])
    }

    // MARK: And back

    func testTheDraftComesBackToTheEditorAsItWas() {
        var text = AttributedString("Hi ")
        text += bold("there")
        var link = AttributedString(" now"); link.link = URL(string: "https://example.com"); text += link
        text += AttributedString("\n\n- one\n- two\n1. first\n2. second\n> quoted\n>> deeper")
        let kept = MailRichText.text(text)
        let back = MailRichText.attributed(kept)
        XCTAssertEqual(String(back.characters), "Hi there now\n\n\u{2022} one\n\u{2022} two\n1. first\n2. second\n> quoted\n>> deeper")
        XCTAssertEqual(MailRichText.text(back), kept, "what he reopens is what he left")
    }

    func testANumberedListIsWrittenCountingOnWhenItsNumbersAreMissing() {
        let kept = MailText(blocks: [
            MailTextBlock(kind: .item(ordered: true, depth: 0, number: nil), runs: [MailTextRun(text: "a")]),
            MailTextBlock(kind: .item(ordered: true, depth: 0, number: nil), runs: [MailTextRun(text: "b")]),
        ])
        XCTAssertEqual(String(MailRichText.attributed(kept).characters), "1. a\n2. b")
    }

    func testABlockThatIsNotOneOfTheEditorsKindsIsStillWhatItSaid() {
        let kept = MailText(blocks: [
            MailTextBlock(kind: .heading(level: 2), runs: [MailTextRun(text: "Title")]),
            MailTextBlock(kind: .preformatted, runs: [MailTextRun(text: "code")]),
            MailTextBlock(kind: .rule, runs: []),
        ])
        XCTAssertEqual(String(MailRichText.attributed(kept).characters), "Title\ncode\n---")
        XCTAssertEqual(MailRichText.text(MailRichText.attributed(kept)).blocks.first?.runs.first?.style, .bold,
                       "a heading is bold in the editor")
    }

    func testThePlainFormOfADraftWithListsKeepsTheirMarks() {
        let kept = MailRichText.text(AttributedString("a\n\u{2022} b\n7. c\n> d"))
        XCTAssertEqual(MailPlainText.string(kept), "a\n- b\n7. c\n> d")
    }

    // MARK: Bold, italic, underline

    func testBoldOnTheSelectionAndOffAgain() {
        var text = AttributedString("hello world")
        var selection = range(text, 0, 5)
        MailFormatting.toggle(.bold, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [.bold, []])
        XCTAssertTrue(MailFormatting.state(of: text, in: selection).bold)
        XCTAssertFalse(MailFormatting.state(of: text, in: selection).italic)
        MailFormatting.toggle(.bold, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [[]])
        XCTAssertFalse(MailFormatting.state(of: text, in: selection).bold)
    }

    func testItalicAndUnderlineAddToWhatIsThere() {
        var text = AttributedString("hello world")
        var selection = range(text, 0, 11)
        MailFormatting.toggle(.bold, in: &text, selection: &selection)
        MailFormatting.toggle(.italic, in: &text, selection: &selection)
        MailFormatting.toggle(.underline, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [[.bold, .italic, .underline]])
        let state = MailFormatting.state(of: text, in: selection)
        XCTAssertTrue(state.bold && state.italic && state.underline)
        MailFormatting.toggle(.italic, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [[.bold, .underline]], "italic off keeps the rest")
    }

    func testAButtonIsOnOnlyWhenAllOfTheSelectionHasIt() {
        var text = bold("bold")
        text += AttributedString(" plain")
        XCTAssertTrue(MailFormatting.state(of: text, in: range(text, 0, 4)).bold)
        XCTAssertFalse(MailFormatting.state(of: text, in: range(text, 0, 10)).bold, "part of it is not all of it")
        var selection = range(text, 0, 10)
        MailFormatting.toggle(.bold, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [.bold], "so the first press makes all of it bold")
    }

    func testWithNothingSelectedTheTraitIsForWhatIsTypedNext() {
        var text = AttributedString("hello")
        var selection = caret(text, 5)
        XCTAssertFalse(MailFormatting.state(of: text, in: selection).bold)
        MailFormatting.toggle(.bold, in: &text, selection: &selection)
        XCTAssertTrue(MailFormatting.state(of: text, in: selection).bold, "the bar shows what the next letter will be")
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [[]], "and nothing already typed changed")
    }

    func testTheMacsChordsAreTheBarsTogglesUnderTheirOwnLetters() {
        // ⌘B, ⌘I and ⌘U on the Mac run `MailFormatting.toggle` for the trait, which is what the
        // format bar's button runs, so the bar shows what the key did.
        XCTAssertEqual(MailFormatting.Trait.allCases.map(\.chordKey), ["b", "i", "u"])
        XCTAssertEqual(Set(MailFormatting.Trait.allCases.map(\.chordKey)).count, 3, "no two share a letter")
        var text = AttributedString("the report")
        var selection = range(text, 0, 10)
        for trait in MailFormatting.Trait.allCases {
            MailFormatting.toggle(trait, in: &text, selection: &selection)
        }
        var state = MailFormatting.state(of: text, in: selection)
        XCTAssertTrue(state.bold && state.italic && state.underline, "all three show on")
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [[.bold, .italic, .underline]])
        for trait in MailFormatting.Trait.allCases {
            MailFormatting.toggle(trait, in: &text, selection: &selection)
        }
        state = MailFormatting.state(of: text, in: selection)
        XCTAssertFalse(state.bold || state.italic || state.underline, "and the second press takes each off")
    }

    // MARK: Links

    func testALinkIsMadeOfSelectedWordsAndTakenOffAgain() throws {
        var text = AttributedString("see the report")
        var selection = range(text, 8, 14)
        let url = try XCTUnwrap(URL(string: "https://example.com/r"))
        MailFormatting.setLink(url, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.text), ["see the ", "report"])
        XCTAssertEqual(blocks(text)[0].runs.map(\.link), [nil, url])
        XCTAssertEqual(MailFormatting.state(of: text, in: selection).link, url)
        XCTAssertEqual(MailBodyHTML.html(from: text), "<p>see the <a href=\"https://example.com/r\">report</a></p>")
        MailFormatting.setLink(nil, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.link), [nil])
    }

    func testALinkIsNotMadeOfNothingOrOfAnAddressThatIsNotAllowed() throws {
        var text = AttributedString("hello world")
        var selection = caret(text, 3)
        MailFormatting.setLink(URL(string: "https://example.com"), in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.link), [nil], "with nothing selected there is nothing to link")
        selection = range(text, 0, 5)
        MailFormatting.setLink(URL(string: "javascript:alert(1)"), in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].runs.map(\.link), [nil])
        XCTAssertFalse(MailFormatting.hasSelectedText(text, caret(text, 2)))
        XCTAssertTrue(MailFormatting.hasSelectedText(text, selection))
        XCTAssertEqual(MailFormatting.selectedText(text, selection), "hello")
    }

    func testWhatHeTypesForALinkBecomesOneOrNothing() {
        XCTAssertEqual(MailFormatting.link(from: "https://example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(MailFormatting.link(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertNil(MailFormatting.link(from: " example.com/a b "), "a space is not an address")
        XCTAssertEqual(MailFormatting.link(from: "sam@lee.example")?.absoluteString, "mailto:sam@lee.example")
        XCTAssertEqual(MailFormatting.link(from: "mailto:sam@lee.example")?.absoluteString, "mailto:sam@lee.example")
        XCTAssertNil(MailFormatting.link(from: ""))
        XCTAssertNotEqual(MailFormatting.link(from: "javascript:alert(1)")?.scheme, "javascript")
        XCTAssertNil(MailFormatting.link(from: "file:///etc/passwd"))
        XCTAssertNil(MailFormatting.link(from: "ftp://example.com"))
    }

    func testSelectedWordsThatAreAnAddressNeedNoQuestion() {
        XCTAssertTrue(MailFormatting.looksLikeAnAddress("example.com"))
        XCTAssertTrue(MailFormatting.looksLikeAnAddress("https://example.com"))
        XCTAssertTrue(MailFormatting.looksLikeAnAddress("sam@lee.example"))
        XCTAssertFalse(MailFormatting.looksLikeAnAddress("the report"))
        XCTAssertFalse(MailFormatting.looksLikeAnAddress("report"))
        XCTAssertFalse(MailFormatting.looksLikeAnAddress(""))
    }

    // MARK: Lists and quotes

    func testBulletsOnTheLineTheCaretIsInAndOffAgain() {
        var text = AttributedString("one\ntwo\nthree")
        var selection = caret(text, 5)
        MailFormatting.toggle(MailParagraphKind.bullet, in: &text, selection: &selection)
        XCTAssertEqual(String(text.characters), "one\n\u{2022} two\nthree")
        XCTAssertEqual(offset(of: selection, in: text), 7, "the caret keeps its place in the word")
        XCTAssertEqual(MailFormatting.state(of: text, in: selection).paragraph, .bullet)
        MailFormatting.toggle(MailParagraphKind.bullet, in: &text, selection: &selection)
        XCTAssertEqual(String(text.characters), "one\ntwo\nthree")
        XCTAssertEqual(offset(of: selection, in: text), 5)
        XCTAssertNil(MailFormatting.state(of: text, in: selection).paragraph)
    }

    func testACaretOnAnEmptyLineGoesAfterTheMarkItMakes() {
        var text = AttributedString("one\n")
        var selection = caret(text, 4)
        MailFormatting.toggle(MailParagraphKind.number, in: &text, selection: &selection)
        XCTAssertEqual(String(text.characters), "one\n1. ")
        XCTAssertEqual(offset(of: selection, in: text), 7, "so what he types next is the first item")
    }

    func testSeveralSelectedLinesBecomeANumberedListFromOneAndAreChangedToAnotherKind() {
        var text = AttributedString("a\nb\nc\nd")
        var selection = range(text, 2, 7)       // b, c, d
        MailFormatting.toggle(MailParagraphKind.number, in: &text, selection: &selection)
        XCTAssertEqual(String(text.characters), "a\n1. b\n2. c\n3. d")
        selection = range(text, 2, text.characters.count)
        MailFormatting.toggle(MailParagraphKind.bullet, in: &text, selection: &selection)
        XCTAssertEqual(String(text.characters), "a\n\u{2022} b\n\u{2022} c\n\u{2022} d", "a list of another kind is changed")
        selection = range(text, 2, text.characters.count)
        MailFormatting.toggle(MailParagraphKind.bullet, in: &text, selection: &selection)
        XCTAssertEqual(String(text.characters), "a\nb\nc\nd", "and all of them already bullets makes them lines again")
    }

    func testASelectionThatEndsAtTheStartOfALineDoesNotTouchIt() {
        var text = AttributedString("a\nb\nc")
        var selection = range(text, 0, 4)       // "a\nb\n": ends at the start of c
        MailFormatting.toggle(MailParagraphKind.quote, in: &text, selection: &selection)
        XCTAssertEqual(String(text.characters), "> a\n> b\nc")
    }

    func testAQuoteIsMadeOfALineAndTheDraftKeepsItAsAQuote() {
        var text = AttributedString("He said\nyes")
        var selection = caret(text, 9)
        MailFormatting.toggle(MailParagraphKind.quote, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text).map(\.kind), [.paragraph, .quote(depth: 1)])
        XCTAssertEqual(MailBodyHTML.html(from: text), "<p>He said</p><blockquote><p>yes</p></blockquote>")
    }

    func testTheMarkedLinesKeepTheirBoldAndLinks() {
        var text = bold("heavy")
        text += AttributedString(" line")
        var selection = caret(text, 2)
        MailFormatting.toggle(MailParagraphKind.bullet, in: &text, selection: &selection)
        XCTAssertEqual(blocks(text)[0].kind, .item(ordered: false, depth: 0, number: nil))
        XCTAssertEqual(blocks(text)[0].runs.map(\.style), [.bold, []])
    }

    // MARK: Return in a list

    /// What the editor does for Return: the text has a line break at the caret.
    private func pressReturn(_ text: inout AttributedString, selection: inout AttributedTextSelection) -> Bool {
        let before = text
        text.replaceSelection(&selection, withCharacters: "\n")
        return MailFormatting.continueAfterReturn(from: before, text: &text, selection: &selection)
    }

    func testReturnAtTheEndOfABulletBeginsTheNextBullet() {
        var text = AttributedString("\u{2022} one")
        var selection = caret(text, 5)
        XCTAssertTrue(pressReturn(&text, selection: &selection))
        XCTAssertEqual(String(text.characters), "\u{2022} one\n\u{2022} ")
        XCTAssertEqual(offset(of: selection, in: text), 8, "the caret is after the new mark")
    }

    /// Found on the phone: Return and the next letter arrived in one update of the editor, and the
    /// item that followed had no bullet. The letters typed with the Return begin the next item.
    func testReturnAndALetterInOneUpdateStillBeginTheNextItem() {
        var text = AttributedString("\u{2022} one")
        var selection = caret(text, 5)
        let before = text
        text.replaceSelection(&selection, withCharacters: "\ns")
        XCTAssertTrue(MailFormatting.continueAfterReturn(from: before, text: &text, selection: &selection))
        XCTAssertEqual(String(text.characters), "\u{2022} one\n\u{2022} s")
        XCTAssertEqual(offset(of: selection, in: text), 9, "the caret is after the letter")

        var numbered = AttributedString("1. one")
        var inNumbered = caret(numbered, 6)
        let numberedBefore = numbered
        numbered.replaceSelection(&inNumbered, withCharacters: "\ntw")
        XCTAssertTrue(MailFormatting.continueAfterReturn(from: numberedBefore, text: &numbered, selection: &inNumbered))
        XCTAssertEqual(String(numbered.characters), "1. one\n2. tw")
        XCTAssertEqual(offset(of: inNumbered, in: numbered), 12)
    }

    func testReturnAndALetterOnAnEmptyItemEndTheListAndKeepTheLetter() {
        var text = AttributedString("\u{2022} one\n\u{2022} ")
        var selection = caret(text, 8)
        let before = text
        text.replaceSelection(&selection, withCharacters: "\nx")
        XCTAssertTrue(MailFormatting.continueAfterReturn(from: before, text: &text, selection: &selection))
        XCTAssertEqual(String(text.characters), "\u{2022} one\nx")
        XCTAssertEqual(offset(of: selection, in: text), 7, "the caret is after the letter on the plain line")
    }

    func testReturnInANumberedListCountsOn() {
        var text = AttributedString("1. one\n2. two")
        var selection = caret(text, 13)
        XCTAssertTrue(pressReturn(&text, selection: &selection))
        XCTAssertEqual(String(text.characters), "1. one\n2. two\n3. ")
    }

    func testReturnInAQuoteKeepsTheQuote() {
        var text = AttributedString("> > deep")
        var selection = caret(text, 8)
        XCTAssertTrue(pressReturn(&text, selection: &selection))
        XCTAssertEqual(String(text.characters), "> > deep\n> > ")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        var text = AttributedString("\u{2022} one\n\u{2022} ")
        var selection = caret(text, 8)
        XCTAssertTrue(pressReturn(&text, selection: &selection))
        XCTAssertEqual(String(text.characters), "\u{2022} one\n", "the empty item is gone and no new line is made")
        XCTAssertEqual(offset(of: selection, in: text), 6)
    }

    func testReturnInTheMiddleOfAnItemSplitsItAndTheSecondHalfIsAnItemToo() {
        var text = AttributedString("- onetwo")
        var selection = caret(text, 5)
        XCTAssertTrue(pressReturn(&text, selection: &selection))
        XCTAssertEqual(String(text.characters), "- one\n- two")
    }

    func testReturnInAPlainLineChangesNothingAndTypingIsNotAReturn() {
        var text = AttributedString("plain")
        var selection = caret(text, 5)
        XCTAssertFalse(pressReturn(&text, selection: &selection))
        XCTAssertEqual(String(text.characters), "plain\n")

        var list = AttributedString("- one")
        var inList = caret(list, 5)
        let before = list
        list.replaceSelection(&inList, withCharacters: "x")
        XCTAssertFalse(MailFormatting.continueAfterReturn(from: before, text: &list, selection: &inList))
        XCTAssertEqual(String(list.characters), "- onex")
    }
}
