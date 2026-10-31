import XCTest

/// What `cleaned` removes and what it keeps (MAIL-ENGINE 10.8, L3), and whether the system's
/// regular-expression engine can answer the questions put to it (L3, L4).
///
/// The rule: remove everything Unicode itself calls invisible by design
/// (`Default_Ignorable_Code_Point`), **except** where the character is doing its work —
/// a variation selector after a visible character, U+200D inside an emoji sequence, a flag's tag
/// sequence, and U+200C and U+200D where IDNA's own rule allows them. A direction control is
/// never kept. The first draft of this rule named U+200B–U+200D outright, and followed to the
/// letter it split every joined emoji and took the joiner out of honest Persian names.
final class MailCleaningTests: XCTestCase {

    private func cleaned(_ text: String) -> String { MailAddressRules.cleaned(text) }

    // MARK: - Does the system's engine answer?

    /// The ruling says to stop and say so if the script or joining-type patterns do not compile
    /// on the system's ICU. They are used from here on: if this fails, nothing else about
    /// scripts or joiners is to be trusted, and the fallback in the code (every word mixed,
    /// no joiner kept) is only the safe direction, not an answer.
    func testTheScriptAndJoiningTypePatternsCompileOnThisSystem() {
        XCTAssertTrue(MailScripts.patternsCompile, #"\p{Script=Latin|Cyrillic|Greek}"#)
        XCTAssertTrue(MailHiddenCharacters.joiningPatternsCompile, #"\p{jt=L|D|R|T}"#)
        for pattern in [#"\p{Script=Latin}"#, #"\p{Script=Cyrillic}"#, #"\p{Script=Greek}"#,
                        #"\p{jt=L}"#, #"\p{jt=D}"#, #"\p{jt=R}"#, #"\p{jt=T}"#] {
            XCTAssertNotNil(try? NSRegularExpression(pattern: pattern), pattern)
        }
    }

    /// What the patterns return, in the cases the entry names: a Japanese name, a Cyrillic name, a
    /// Latin name with one Cyrillic letter in it, an accented Latin name.
    func testWhatTheScriptPatternsSayOfTheNamesTheEntryNames() {
        func scripts(_ text: String) -> Set<String> {
            var found: Set<String> = []
            for (script, pattern) in [("Latin", #"\p{Script=Latin}"#), ("Cyrillic", #"\p{Script=Cyrillic}"#),
                                      ("Greek", #"\p{Script=Greek}"#)] {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(location: 0, length: text.utf16.count)
                if expression.firstMatch(in: text, options: [], range: range) != nil { found.insert(script) }
            }
            return found
        }
        XCTAssertEqual(scripts("\u{7530}\u{4E2D}\u{3055}\u{304F}\u{3089}"), [], "a Japanese name: none of the three")
        XCTAssertEqual(scripts("\u{0410}\u{043D}\u{043D}\u{0430}"), ["Cyrillic"], "a Cyrillic name")
        XCTAssertEqual(scripts("P\u{0430}ypal"), ["Latin", "Cyrillic"], "Latin with one Cyrillic letter")
        XCTAssertEqual(scripts("M\u{00FC}ller Jos\u{00E9}"), ["Latin"], "accented Latin")
        XCTAssertEqual(scripts("\u{0393}\u{03B9}\u{03CE}\u{03C1}\u{03B3}\u{03BF}\u{03C2}"), ["Greek"])
        // And the verdicts built on them.
        XCTAssertFalse(MailScripts.hasWordMixingLookAlikeScripts("\u{7530}\u{4E2D}\u{3055}\u{304F}\u{3089}"))
        XCTAssertFalse(MailScripts.hasWordMixingLookAlikeScripts("\u{0410}\u{043D}\u{043D}\u{0430}"))
        XCTAssertTrue(MailScripts.hasWordMixingLookAlikeScripts("P\u{0430}ypal"))
        XCTAssertFalse(MailScripts.hasWordMixingLookAlikeScripts("M\u{00FC}ller Jos\u{00E9}"))
    }

    // MARK: - Emoji survive whole

    func testAFamilyAProfessionAndACoupleSurviveWhole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let profession = "\u{1F469}\u{200D}\u{1F4BB}"
        let couple = "\u{1F468}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F468}"
        let withSkinTone = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"
        for emoji in [family, profession, couple, withSkinTone] {
            XCTAssertEqual(cleaned(emoji), emoji)
            XCTAssertEqual(cleaned("I am \(emoji) today").unicodeScalars.count, "I am \(emoji) today".unicodeScalars.count)
        }
    }

    func testTheFlagOfScotlandSurvivesAndATagSequenceAfterAnythingElseDoesNot() {
        let scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        XCTAssertEqual(cleaned(scotland), scotland)
        XCTAssertEqual(cleaned("x" + scotland), "x\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}")
        // Tags after anything else are how text is hidden inside text.
        XCTAssertEqual(cleaned("a\u{E0067}\u{E0062}\u{E007F}"), "a")
        XCTAssertEqual(cleaned("\u{1F600}\u{E0067}\u{E0062}\u{E007F}"), "\u{1F600}")
        XCTAssertEqual(cleaned("hi \u{E0048}\u{E0069}"), "hi ")
        // A tag sequence that is not closed, or has a stray cancel in it, is not a flag.
        XCTAssertEqual(cleaned("\u{1F3F4}\u{E0067}\u{E0062}"), "\u{1F3F4}")
        XCTAssertEqual(cleaned("\u{1F3F4}\u{E0067}\u{E007F}\u{E0062}\u{E007F}"), "\u{1F3F4}")
        XCTAssertEqual(cleaned("\u{1F3F4}\u{E007F}"), "\u{1F3F4}", "a cancel alone is no sequence")
    }

    // MARK: - Joiners that do their work

    func testAPersianWordKeepsItsZeroWidthNonJoiner() {
        let word = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"      // می‌خواهم
        XCTAssertEqual(cleaned(word), word)
        // Urdu, and a transparent mark either side.
        let marked = "\u{0628}\u{064E}\u{200C}\u{062A}"
        XCTAssertEqual(cleaned(marked), marked)
    }

    func testADevanagariConjunctKeepsItsJoiner() {
        let conjunct = "\u{0915}\u{094D}\u{200D}\u{0937}"
        XCTAssertEqual(cleaned(conjunct), conjunct)
        let nonJoiner = "\u{0915}\u{094D}\u{200C}\u{0937}"
        XCTAssertEqual(cleaned(nonJoiner), nonJoiner, "either joiner after a virama")
    }

    func testLatinCyrillicAndGreekLettersNeverKeepAJoiner() {
        XCTAssertEqual(cleaned("Pay\u{200D}Pal"), "PayPal")
        XCTAssertEqual(cleaned("Pay\u{200C}Pal"), "PayPal")
        XCTAssertEqual(cleaned("\u{0410}\u{200C}\u{0411}"), "\u{0410}\u{0411}")
        XCTAssertEqual(cleaned("\u{03B1}\u{200D}\u{03B2}"), "\u{03B1}\u{03B2}")
        XCTAssertEqual(cleaned("sam\u{200D}@plan.example"), "sam@plan.example")
    }

    func testAZeroWidthNonJoinerBetweenLettersThatDoNotJoinIsRemoved() {
        // A right-joining letter before it, or a left-joining one after it: no join to break.
        XCTAssertEqual(cleaned("\u{0627}\u{200C}\u{0628}"), "\u{0627}\u{0628}", "alef joins only to its right")
        XCTAssertEqual(cleaned("\u{0628}\u{200C}\u{0627}\u{0627}"), "\u{0628}\u{200C}\u{0627}\u{0627}",
                       "beh before alef is the shape that joins")
        XCTAssertEqual(cleaned("\u{0628}\u{200C}"), "\u{0628}", "a joiner at the end joins nothing")
        XCTAssertEqual(cleaned("\u{200C}\u{0628}"), "\u{0628}", "and neither at the start")
    }

    /// More than eight transparent marks between the letters is more than the rule allows.
    func testMoreThanEightTransparentMarksBetweenTheLettersIsRefused() {
        let eight = "\u{0628}" + String(repeating: "\u{064E}", count: 8) + "\u{200C}\u{062A}"
        let nine = "\u{0628}" + String(repeating: "\u{064E}", count: 9) + "\u{200C}\u{062A}"
        XCTAssertEqual(cleaned(eight), eight)
        XCTAssertEqual(cleaned(nine), nine.replacingOccurrences(of: "\u{200C}", with: ""))
    }

    // MARK: - Variation selectors

    func testAVariationSelectorSurvivesAfterAnEmojiAndAfterAnIdeographAndNotAfterASpace() {
        XCTAssertEqual(cleaned("\u{2764}\u{FE0F}"), "\u{2764}\u{FE0F}", "emoji presentation")
        XCTAssertEqual(cleaned("\u{8FBB}\u{E0100}"), "\u{8FBB}\u{E0100}", "an ideograph variant, as in a Japanese name")
        XCTAssertEqual(cleaned("\u{845B}\u{FE00}"), "\u{845B}\u{FE00}")
        XCTAssertEqual(cleaned(" \u{FE0F}"), " ", "after white space it is nothing")
        XCTAssertEqual(cleaned("\u{FE0F}x"), "x", "at the start there is nothing before it")
        XCTAssertEqual(cleaned("\u{200B}\u{FE0F}"), "", "after something removed it is not directly after a kept character")
        XCTAssertEqual(cleaned("a\u{200B}\u{FE0F}b"), "ab")
    }

    /// A run of selectors is how a message is carried inside another: only the first, after a
    /// visible character, can be doing any work.
    func testARunOfVariationSelectorsKeepsOnlyTheFirst() {
        XCTAssertEqual(cleaned("a\u{FE00}\u{FE00}\u{FE00}"), "a\u{FE00}")
        let hidden = "\u{1F600}" + String(repeating: "\u{E0100}", count: 50)
        XCTAssertEqual(cleaned(hidden), "\u{1F600}\u{E0100}")
    }

    // MARK: - Direction controls never

    func testEveryDirectionControlGoesInsideAnEmojiSequenceToo() {
        var controls: [UInt32] = [0x061C]
        controls += Array(0x200E...0x200F)
        controls += Array(0x202A...0x202E)
        controls += Array(0x2066...0x2069)
        for value in controls {
            guard let control = Unicode.Scalar(value) else { return XCTFail("\(value)") }
            XCTAssertEqual(cleaned("a\(control)b"), "ab", String(value, radix: 16))
            XCTAssertEqual(cleaned("\u{1F469}\(control)\u{200D}\u{1F4BB}"), "\u{1F469}\u{200D}\u{1F4BB}",
                           "inside an emoji sequence: \(String(value, radix: 16))")
            XCTAssertEqual(cleaned("\u{0645}\u{06CC}\(control)\u{200C}\u{062E}"), "\u{0645}\u{06CC}\u{200C}\u{062E}",
                           "inside a Persian word: \(String(value, radix: 16))")
        }
        XCTAssertEqual(cleaned("invoice\u{202E}fdp.exe"), "invoicefdp.exe")
    }

    // MARK: - The rest of what is invisible by design

    func testTheFillersTheSoftHyphenTheBOMAndTheGraphemeJoinerAreRemoved() {
        for hidden in ["\u{3164}", "\u{115F}", "\u{1160}", "\u{FFA0}", "\u{00AD}", "\u{FEFF}", "\u{034F}", "\u{180E}",
                       "\u{2060}", "\u{2061}", "\u{206A}", "\u{200B}", "\u{17B4}"] {
            XCTAssertEqual(cleaned("a\(hidden)b"), "ab", hidden.debugDescription)
        }
    }

    func testWhatIsVisibleIsLeftAloneWhateverItsScript() {
        for text in ["a\u{200A}b", "a\u{202F}b", "a b", "e\u{0301}", "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}",
                     "\u{65E5}\u{672C}\u{8A9E}", "\u{1F600}", "tab\there", "\u{1F1EF}\u{1F1F5}", "\u{0915}\u{094D}\u{0937}"] {
            XCTAssertEqual(cleaned(text), text)
        }
    }

    /// Linear: a hundred thousand of each shape is not a long wait.
    func testHostileRunsOfInvisibleCharactersAreCleanedWithoutDelay() {
        for unit in ["\u{200D}", "\u{200C}", "\u{FE0F}", "\u{E0067}", "a\u{200C}b", "\u{0628}\u{200C}\u{062A}",
                     "\u{1F469}\u{200D}\u{1F4BB}", "\u{202E}"] {
            let text = String(repeating: unit, count: 20_000)
            let result = cleaned(text)
            XCTAssertLessThanOrEqual(result.unicodeScalars.count, text.unicodeScalars.count)
            XCTAssertEqual(cleaned(result), result, "stable: \(unit.debugDescription)")
        }
    }
}
