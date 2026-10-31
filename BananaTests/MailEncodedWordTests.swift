import XCTest

/// RFC 2047 encoded words in headers, and the unfolding and cleaning a subject gets
/// (MAIL-ENGINE 10.8).
///
/// Whether Gmail's `payload.headers` arrive with their encoded words already decoded is not
/// known until the read probe (reuse review B-15), so the reading is written to give the same
/// words either way: an encoded word is decoded, plain text is left alone, and the tests
/// below hold both forms of every case. What cannot be decoded is left as it was written, never
/// replaced by a guess, so a header is never made to say something its sender did not.
final class MailEncodedWordTests: XCTestCase {

    private func decode(_ text: String) -> String { MailHeaderText.decodeEncodedWords(text) }

    // MARK: - The two encodings

    func testBase64WordsAreDecoded() {
        XCTAssertEqual(decode("=?UTF-8?B?SGVsbG8=?="), "Hello")
        XCTAssertEqual(decode("=?UTF-8?B?Q2Fmw6k=?="), "Café")
        XCTAssertEqual(decode("=?utf-8?b?5pel5pys6Kqe?="), "日本語", "the letters of the charset and the encoding are not case sensitive")
    }

    func testBase64WithTheLastPaddingLeftOffIsStillDecoded() {
        XCTAssertEqual(decode("=?UTF-8?B?SGVsbG8?="), "Hello")
        XCTAssertEqual(decode("=?UTF-8?B?Q2Fmw6k?="), "Café")
    }

    func testQuotedPrintableWordsAreDecodedWithUnderscoreAsSpace() {
        XCTAssertEqual(decode("=?UTF-8?Q?Caf=C3=A9?="), "Café")
        XCTAssertEqual(decode("=?utf-8?q?Hello_World?="), "Hello World")
        XCTAssertEqual(decode("=?UTF-8?Q?100=25_sure=3F?="), "100% sure?")
    }

    func testAnEqualsSignNotFollowedByTwoHexDigitsIsItself() {
        XCTAssertEqual(decode("=?utf-8?q?a=zz?="), "a=zz")
        XCTAssertEqual(decode("=?utf-8?q?end=?="), "end=")
        XCTAssertEqual(decode("=?utf-8?q?x=4?="), "x=4")
    }

    // MARK: - Charsets

    func testTheCharsetsMailIsWrittenInAreDecodedBySystemName() {
        XCTAssertEqual(decode("=?ISO-8859-1?Q?Andr=E9?="), "André")
        XCTAssertEqual(decode("=?windows-1252?B?gA==?="), "€")
        XCTAssertEqual(decode("=?Shift_JIS?B?grGC8YLJgr+CzQ==?="), "こんにちは")
        XCTAssertEqual(decode("=?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?="), "こんにちは")
        XCTAssertEqual(decode("=?GB2312?B?xOO6ww==?="), "你好")
        XCTAssertEqual(decode("=?big5?B?p0Gmbg==?="), "你好")
        XCTAssertEqual(decode("=?koi8-r?B?8NLJ18XU?="), "Привет")
        XCTAssertEqual(decode("=?us-ascii?Q?plain?="), "plain")
    }

    func testALanguageSuffixOnTheCharsetIsIgnored() {
        XCTAssertEqual(decode("=?UTF-8*en?Q?Hello?="), "Hello")
    }

    /// L6: an unknown charset is one rule, for a header's word and a body alike: UTF-8 if the
    /// bytes are valid UTF-8, else Windows-1252, a byte it leaves undefined becoming U+FFFD.
    /// Never left as the raw `=?...?=`: "Cafe" is better than `=?unknown-8bit?Q?Caf=E9?=`.
    func testAnUnknownCharsetIsReadAsUTF8IfTheBytesAreValidUTF8() {
        XCTAssertEqual(decode("=?unknown-8bit?Q?Caf=C3=A9?="), "Café")
        XCTAssertEqual(decode("=?x-no-such-charset?B?SGk=?="), "Hi")
        XCTAssertEqual(decode("=?unknown-8bit?B?5pel5pys6Kqe?="), "日本語")
    }

    func testAnUnknownCharsetIsReadAsWindows1252WhenTheBytesAreNotValidUTF8() {
        XCTAssertEqual(decode("=?unknown-8bit?Q?Caf=E9?="), "Café")
        XCTAssertEqual(decode("=?x-unknown?B?gA==?="), "€", "0x80 is the euro sign in Windows-1252")
        XCTAssertEqual(decode("=?x-unknown?Q?=93quoted=94?="), "\u{201C}quoted\u{201D}")
    }

    func testAByteWindows1252LeavesUndefinedBecomesTheReplacementCharacter() {
        XCTAssertEqual(decode("=?x-unknown?Q?a=81b?="), "a\u{FFFD}b")
        XCTAssertEqual(decode("=?x-unknown?Q?=8D=8F=90=9D?="), "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}")
        XCTAssertEqual(decode("=?x-unknown?Q?Caf=E9=81?="), "Caf\u{E9}\u{FFFD}")
    }

    /// Words of one unknown charset are decoded together, as words of any charset are, and what is
    /// around an unknown word is as it was.
    func testWordsInAnUnknownCharsetAreJoinedAndDoNotDisturbTheirNeighbours() {
        XCTAssertEqual(decode("a =?x-no-such-charset?Q?b?= c"), "a b c")
        XCTAssertEqual(decode("=?UTF-8?Q?ok?= =?x-no-such-charset?Q?b?="), "okb", "whitespace between two encoded words goes")
        XCTAssertEqual(decode("=?x-foo?Q?=C3?= =?x-foo?Q?=A9?="), "é", "a character split between two words of one unknown charset")
    }

    /// A known charset whose bytes it cannot read is the same case: real mail labels Latin-1 text
    /// `us-ascii`.
    func testBytesThatTheirCharsetCannotReadAreReadByTheSameRule() {
        XCTAssertEqual(decode("=?us-ascii?Q?Caf=E9?="), "Café")
        XCTAssertEqual(decode("=?us-ascii?Q?=C3=A9?="), "é")
    }

    func testTheOneRuleIsAvailableForBodiesToo() {
        XCTAssertEqual(MailCharset.text([0x43, 0x61, 0x66, 0xE9], charset: "unknown-8bit"), "Café")
        XCTAssertEqual(MailCharset.text([0x43, 0x61, 0x66, 0xE9], charset: nil), "Café")
        XCTAssertEqual(MailCharset.text([0x43, 0x61, 0x66, 0xE9], charset: "iso-8859-1"), "Café")
        XCTAssertEqual(MailCharset.text([0xC3, 0xA9], charset: "x-nonsense"), "é")
        XCTAssertEqual(MailCharset.text([0x61, 0xFF, 0x62], charset: "utf-8"), "a\u{FFFD}b",
                       "declared UTF-8 with a bad byte is UTF-8 with a replacement character")
        XCTAssertNil(MailCharset.encoding(named: "x-nonsense"))
        XCTAssertEqual(MailCharset.encoding(named: "UTF8"), .utf8)
        XCTAssertEqual(MailCharset.encoding(named: "utf-8*en"), .utf8)
    }

    /// A very large run of bytes is read in linear time.
    func testALongRunOfUndefinedBytesIsReadWithoutQuadraticCost() {
        let bytes = [UInt8](repeating: 0x81, count: 200_000)
        let text = MailCharset.text(bytes, charset: "x-unknown")
        XCTAssertEqual(text.unicodeScalars.count, 200_000)
        XCTAssertTrue(text.unicodeScalars.allSatisfy { $0 == "\u{FFFD}" })
    }

    func testInvalidUTF8IsDecodedWithReplacementCharactersNotLost() {
        XCTAssertEqual(decode("=?UTF-8?Q?a=FFb?="), "a\u{FFFD}b")
    }

    func testBase64ThatIsNotBase64LeavesTheWordAsWritten() {
        XCTAssertEqual(decode("=?UTF-8?B?!!!!?="), "=?UTF-8?B?!!!!?=")
        XCTAssertEqual(decode("=?UTF-8?B?SGVs bG8=?="), "=?UTF-8?B?SGVs bG8=?=", "whitespace ends a word")
    }

    // MARK: - Adjacent words

    /// Whitespace between two encoded words is dropped (RFC 2047 section 6.2); whitespace
    /// between an encoded word and plain text is kept.
    func testWhitespaceBetweenEncodedWordsIsDroppedAndElsewhereKept() {
        XCTAssertEqual(decode("=?UTF-8?Q?Hel?= =?UTF-8?Q?lo?="), "Hello")
        XCTAssertEqual(decode("=?UTF-8?Q?Hel?=  \t =?UTF-8?Q?lo?="), "Hello")
        XCTAssertEqual(decode("a =?UTF-8?Q?b?= c"), "a b c")
        XCTAssertEqual(decode("a  =?UTF-8?Q?b?=  c"), "a  b  c")
        XCTAssertEqual(decode("=?UTF-8?Q?a?= b =?UTF-8?Q?c?="), "a b c")
    }

    /// A character may be split between two words, in the middle of its bytes.
    func testACharacterSplitBetweenTwoWordsOfOneCharsetIsWhole() {
        XCTAssertEqual(decode("=?UTF-8?Q?=C3?= =?UTF-8?Q?=A9?="), "é")
        XCTAssertEqual(decode("=?UTF-8?B?5pel?= =?UTF-8?B?5pys?="), "日本")
        // Split inside a three-byte character: E6 97 | A5, then a whole one.
        XCTAssertEqual(decode("=?UTF-8?B?5pc=?= =?UTF-8?B?peacrA==?="), "日本")
    }

    func testAdjacentWordsInTwoCharsetsAreEachDecodedAndJoined() {
        XCTAssertEqual(decode("=?UTF-8?Q?a?= =?ISO-8859-1?Q?=E9?="), "aé")
    }

    // MARK: - What is not an encoded word

    func testTextThatOnlyLooksLikeAnEncodedWordIsLeftAlone() {
        for text in ["=?", "?=", "=?=?=?", "=?UTF-8?B?SGVsbG8", "=?UTF-8?B?", "=?UTF-8?X?SGk=?=", "=?UTF-8?Q?a b?=",
                     "what =? is this ?=", "=?UTF-8??a?=", "=??Q?a?=", "plain text", "", "=", "?"] {
            XCTAssertEqual(decode(text), text, text.debugDescription)
        }
    }

    func testAnEncodedWordLongerThanTheLimitIsNotDecoded() {
        let long = "=?UTF-8?B?" + String(repeating: "QUJD", count: 400) + "?="
        XCTAssertEqual(decode(long), long)
        let fits = "=?UTF-8?B?" + String(repeating: "QUJD", count: 200) + "?="
        XCTAssertEqual(decode(fits), String(repeating: "ABC", count: 200))
    }

    func testPlainTextAroundWordsIsKeptExactly() {
        XCTAssertEqual(decode("Re: =?UTF-8?Q?Caf=C3=A9?= (urgent)"), "Re: Café (urgent)")
        XCTAssertEqual(decode("  lead =?UTF-8?Q?x?= trail  "), "  lead x trail  ")
    }

    // MARK: - A subject: unfolded, decoded, cleaned

    func testASubjectIsUnfolded() {
        XCTAssertEqual(MailHeaderText.unstructured("Hello\r\n World"), "Hello World")
        XCTAssertEqual(MailHeaderText.unstructured("Hello\n\tWorld"), "Hello World", "the tab that follows a break stays, and is shown as a space")
        XCTAssertEqual(MailHeaderText.unstructured("A\r\n B\r\n C"), "A B C")
    }

    /// `header-injection-reply`: a line break that is not a fold is a space, and no line break
    /// is left in what is shown.
    func testALineBreakThatIsNotAFoldIsASpaceAndNoLineBreakSurvives() {
        let subject = MailHeaderText.unstructured("Re: invoice\r\nBcc: attacker@evil.example")
        XCTAssertEqual(subject, "Re: invoice Bcc: attacker@evil.example")
        for text in ["a\rb", "a\nb", "a\r\n\r\nb", "\r\n", "a\u{0085}b", "a\u{2028}b"] {
            let shown = MailHeaderText.unstructured(text)
            XCTAssertFalse(shown.contains(where: { $0.isNewline }), text.debugDescription)
        }
    }

    func testAnEncodedLineBreakDoesNotSurviveEither() {
        let subject = MailHeaderText.unstructured("=?utf-8?q?a=0D=0Ab?=")
        XCTAssertFalse(subject.contains(where: { $0.isNewline }))
        XCTAssertTrue(subject.hasPrefix("a") && subject.hasSuffix("b"))
        XCTAssertEqual(MailHeaderText.unstructured("=?utf-8?q?a=00b=07c?="), "abc", "NUL and BEL are removed")
    }

    /// `from-rlo-subject`.
    func testASubjectLosesItsDirectionOverrideAndItsInvisibleCharacters() {
        XCTAssertEqual(MailHeaderText.unstructured("Invoice \u{202E}fdp.exe"), "Invoice fdp.exe")
        XCTAssertEqual(MailHeaderText.unstructured("Pa\u{200B}y\u{2060}Pal"), "PayPal")
        XCTAssertEqual(MailHeaderText.unstructured("=?utf-8?q?Invoice_=E2=80=AEfdp.exe?="), "Invoice fdp.exe",
                       "also when the override arrives encoded")
    }

    func testASubjectIsTrimmedAndATabIsASpace() {
        XCTAssertEqual(MailHeaderText.unstructured("  Hi \t there  "), "Hi   there")
        XCTAssertEqual(MailHeaderText.unstructured(""), "")
        XCTAssertEqual(MailHeaderText.unstructured("   "), "")
    }

    // MARK: - Both forms, the same words

    /// The unverified behaviour: Gmail may or may not decode header values before sending them.
    /// Either way these read to the same text.
    func testAnEncodedAndADecodedSubjectReadTheSame() {
        let pairs = [("=?UTF-8?B?Q2Fmw6kgbWVudQ==?=", "Café menu"),
                     ("=?ISO-8859-1?Q?Andr=E9_Smith?=", "André Smith"),
                     ("=?UTF-8?Q?=F0=9F=98=80_hello?=", "😀 hello"),
                     ("=?UTF-8?B?5pel5pys6Kqe?=", "日本語")]
        for (encoded, decoded) in pairs {
            XCTAssertEqual(MailHeaderText.unstructured(encoded), decoded)
            XCTAssertEqual(MailHeaderText.unstructured(decoded), decoded)
        }
    }

    func testAnEncodedAndADecodedNameReadTheSame() {
        let encoded = MailAddressList.parse("=?UTF-8?B?Q2Fmw6k=?= <cafe@example.com>").mailboxes.first
        let decoded = MailAddressList.parse("Café <cafe@example.com>").mailboxes.first
        XCTAssertEqual(encoded, decoded)
        XCTAssertEqual(encoded?.name, "Café")
        let quoted = MailAddressList.parse("\"=?UTF-8?Q?Caf=C3=A9?=\" <cafe@example.com>").mailboxes.first
        XCTAssertEqual(quoted?.name, "Café", "a word inside quotes is decoded too, as mailers write it")
    }

    func testAnUnknownCharsetInANameIsReadByTheSameRule() {
        let list = MailAddressList.parse("=?x-no-such-charset?B?SGk=?= <w@example.com>")
        XCTAssertEqual(list.mailboxes.first?.name, "Hi")
        XCTAssertEqual(list.mailboxes.first?.address, "w@example.com")
        XCTAssertEqual(MailAddressList.parse("=?unknown-8bit?Q?Jos=E9?= <j@example.com>").mailboxes.first?.name, "José")
    }

    // MARK: - Unfolding as a function

    func testUnfoldLeavesTextWithNoLineBreakAlone() {
        XCTAssertEqual(MailHeaderText.unfold("no breaks here"), "no breaks here")
    }

    func testUnfoldKeepsTheWhitespaceThatFollowsABreak() {
        XCTAssertEqual(MailHeaderText.unfold("a\r\n b"), "a b")
        XCTAssertEqual(MailHeaderText.unfold("a\n  b"), "a  b")
        XCTAssertEqual(MailHeaderText.unfold("a\rb"), "a b")
        XCTAssertEqual(MailHeaderText.unfold("a\r\nb"), "a b")
    }
}
