import XCTest

/// Who a message says it is from: whether an address is one, what name may be shown beside it,
/// and what is stripped from every name (MAIL-ENGINE 10.8).
///
/// Every rule here answers a way of making one person look like another. A name that says
/// "noor@plan.example" over x@evil.example; a Latin word with one Cyrillic letter in it; an address
/// with a full-width `@` or a letter that draws nothing; a right-to-left override that turns
/// "fdp.exe" into "exe.pdf". The tests are those shapes, and the ordinary names that must not be
/// caught by the rules written for them. (What `cleaned` keeps and removes has its own class,
/// `MailCleaningTests`.)
final class MailAddressRulesTests: XCTestCase {

    // MARK: - isValid

    func testOrdinaryAddressesAreValid() {
        for address in ["bob@example.com", "bob.smith+tag@mail.example.co.uk", "a@b.co", "noor@plan.example",
                        "x@sub-domain.example.org", "Bob@Example.COM", "under_score@exa_mple.com",
                        "bob@192.0.2.1", "üser@example.com", "bob@xn--bcher-kva.de",
                        "o'brien@example.com", "a!#$%&'*+-/=?^_`{|}~b@example.com", "..@example.com"] {
            XCTAssertTrue(MailAddressRules.isValid(address), address)
        }
    }

    /// One "@", both sides, no whitespace, no angle brackets, no comma or semicolon, a host with a
    /// dot (MAIL-ENGINE 7.2).
    func testTheShapesThatAreNotAddressesAreNotValid() {
        for address in ["", "bob", "bob@", "@example.com", "bob@@example.com", "bob@x@example.com",
                        "bob@example", "bob@.com", "bob@example..com", "bob@example.com.", "bob@a.b..c",
                        "bob smith@example.com", "bob@exa mple.com", "bob\t@example.com",
                        "bob@example.com\n", " bob@example.com", "<bob@example.com>", "bob@example.com>",
                        "bob,alice@example.com", "bob;x@example.com", "bob@example,com",
                        "bob@[192.0.2.1]", "bob@exa!mple.com"] {
            XCTAssertFalse(MailAddressRules.isValid(address), address.debugDescription)
        }
    }

    /// What no unquoted local part may hold, and the address a reader once made of `<mailto:x@y.z>`.
    func testTheCharactersNoUnquotedLocalPartMayHoldAreRefused() {
        for address in ["mailto:x@y.z", "a\"b@example.com", "\"a b\"@example.com", "\"ab\"@example.com",
                        "a(b@example.com", "a)b@example.com", "a[b@example.com", "a]b@example.com",
                        "a\\b@example.com", "a:b@example.com", "a;b@example.com", "a<b@example.com"] {
            XCTAssertFalse(MailAddressRules.isValid(address), address.debugDescription)
        }
    }

    /// The design's list stopped at whitespace. These read as an address and are not one, and a
    /// reply to one would go to a mailbox nobody can tell from the real one.
    func testAnAddressWithACharacterThatCannotBeSeenIsNotValid() {
        for hidden in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{200E}", "\u{202E}",
                       "\u{2066}", "\u{061C}", "\u{00AD}", "\u{0000}", "\u{0007}", "\u{00A0}", "\u{2028}",
                       // marks and letters that draw nothing, which are not "format" characters:
                       "\u{FE00}", "\u{FE0F}", "\u{E0100}", "\u{034F}", "\u{3164}", "\u{115F}", "\u{1160}",
                       "\u{FFA0}", "\u{180B}", "\u{E0067}"] {
            XCTAssertFalse(MailAddressRules.isValid("sam\(hidden)@plan.example"), "local part: \(hidden.debugDescription)")
            XCTAssertFalse(MailAddressRules.isValid("sam@z0\(hidden).ai"), "domain: \(hidden.debugDescription)")
        }
    }

    /// MAJOR 3: `noor＠plan.example@evil.example` read as valid, its one real `@` being the last.
    func testALookAlikeAtSignInTheLocalPartIsNotAnAddress() {
        for lookAlike in ["\u{FF20}", "\u{FE6B}", "\u{FF1C}", "\u{FF1E}", "\u{FE64}", "\u{FE65}"] {
            XCTAssertFalse(MailAddressRules.isValid("noor\(lookAlike)plan.example@evil.example"), lookAlike.debugDescription)
            XCTAssertNil(MailAddressRules.normalized("noor\(lookAlike)plan.example@evil.example"))
        }
    }

    func testALocalPartThatCompatibilityFoldingWouldChangeIsNotAnAddress() {
        XCTAssertFalse(MailAddressRules.isValid("\u{FF42}\u{FF4F}\u{FF52}\u{FF49}\u{FF53}@plan.example"), "full-width letters")
        XCTAssertFalse(MailAddressRules.isValid("\u{1D41B}oris@plan.example"), "a mathematical bold letter")
        XCTAssertFalse(MailAddressRules.isValid("e\u{0301}ric@example.com"), "a letter and a separate accent: folding joins them")
        XCTAssertTrue(MailAddressRules.isValid("\u{00E9}ric@example.com"))
    }

    func testALocalPartThatBeginsWithACombiningMarkIsNotAnAddress() {
        XCTAssertFalse(MailAddressRules.isValid("\u{0301}a@example.com"))
        XCTAssertFalse(MailAddressRules.isValid("\u{064E}\u{0628}@example.com"))
    }

    /// A word that mixes Latin with Cyrillic or Greek is the shape L4 refuses in a name; the
    /// address is what is shown instead of a suspect name, so it gets the same test.
    func testALocalPartWithAWordMixingLatinWithCyrillicOrGreekIsNotAnAddress() {
        XCTAssertFalse(MailAddressRules.isValid("n\u{043E}or@plan.example"), "Cyrillic o among Latin letters")
        XCTAssertFalse(MailAddressRules.isValid("p\u{0430}ypal@example.com"))
        XCTAssertFalse(MailAddressRules.isValid("bor\u{03B9}s@plan.example"), "Greek iota among Latin letters")
        XCTAssertFalse(MailAddressRules.isValid("\u{0431}\u{043E}ris@plan.example"), "a Cyrillic start and a Latin end")
        // Two words, each in its own script, are not a mixed word: the dot separates them.
        XCTAssertTrue(MailAddressRules.isValid("ivan.\u{0438}\u{0432}\u{0430}\u{043D}@example.com"))
    }

    func testAnHonestNonASCIILocalPartIsAnAddress() {
        for address in ["\u{00FC}ser@example.com", "jos\u{00E9}@example.com", "\u{674E}\u{96F7}@example.cn",
                        "\u{0438}\u{0432}\u{0430}\u{043D}@example.ru", "\u{03B3}\u{03B9}\u{03C9}\u{03C1}\u{03B3}\u{03BF}\u{03C2}@example.gr",
                        "\u{0623}\u{062D}\u{0645}\u{062F}@example.sa", "a\u{674E}@example.cn",
                        "\u{0915}\u{094D}\u{0937}@example.in", "\u{05D0}\u{05D1}\u{05D2}@example.il"] {
            XCTAssertTrue(MailAddressRules.isValid(address), address)
        }
    }

    func testAnAddressTooLongToBeOneIsNotValidAndIsRefusedWithoutReadingIt() {
        XCTAssertTrue(MailAddressRules.isValid(String(repeating: "a", count: 64) + "@example.com"))
        XCTAssertFalse(MailAddressRules.isValid(String(repeating: "a", count: 400) + "@example.com"))
        XCTAssertFalse(MailAddressRules.isValid(String(repeating: "a", count: 100_000) + "@example.com"))
        XCTAssertFalse(MailAddressRules.isValid("bob@" + String(repeating: "a", count: 64) + ".com"),
                       "a label is at most 63 bytes")
    }

    // MARK: - normalized

    func testTheDomainIsLowerCasedAndTheLocalPartIsLeftAsWritten() {
        XCTAssertEqual(MailAddressRules.normalized("Bob@Example.COM"), "Bob@example.com")
        XCTAssertNil(MailAddressRules.normalized("not an address"))
    }

    /// The UI is given no domain with a non-ASCII label: it gets the `xn--` form, where a
    /// Cyrillic "a" in "apple.com" no longer looks like an "a".
    func testANonASCIIDomainIsGivenInItsPunycodeForm() {
        XCTAssertEqual(MailAddressRules.normalized("info@b\u{00FC}cher.de"), "info@xn--bcher-kva.de")
        XCTAssertEqual(MailAddressRules.normalized("support@\u{0430}pple.com"), "support@xn--pple-43d.com")
        XCTAssertNotEqual(MailAddressRules.normalized("support@\u{0430}pple.com"),
                          MailAddressRules.normalized("support@apple.com"),
                          "the lookalike is not the real domain")
    }

    /// The system's conversion maps a full-width letter to the plain one, drops what is invisible
    /// and maps an ideographic full stop to a dot: each would make two domains that differ to
    /// the eye one. They are refused before the conversion, not repaired by it.
    func testADomainTheConversionWouldMergeWithAnotherIsNotAnAddress() {
        XCTAssertFalse(MailAddressRules.isValid("bob@\u{FF45}xample.com"), "a full-width letter")
        XCTAssertFalse(MailAddressRules.isValid("bob@exa\u{3002}mple.com"), "an ideographic full stop")
        XCTAssertFalse(MailAddressRules.isValid("bob@exam\u{FE00}ple.com"), "a variation selector")
        XCTAssertFalse(MailAddressRules.isValid("bob@exam\u{3164}ple.com"), "a Hangul filler")
        XCTAssertNil(MailAddressRules.normalized("bob@\u{FF45}xample.com"))
    }

    func testKeyComparesAddressesWithoutRegardToCase() {
        XCTAssertEqual(MailAddress(name: "A", address: "Bob@Example.com").key,
                       MailAddress(name: "B", address: "bob@example.com").key)
        XCTAssertNotEqual(MailAddress(name: nil, address: "bob@example.com").key,
                          MailAddress(name: nil, address: "bob@example.org").key)
        XCTAssertEqual(MailAddress(name: nil, address: "Bob@Example.COM").domain, "example.com")
    }

    // MARK: - displayName

    func testAnOrdinaryNameIsShownAsItIs() {
        for name in ["Bob Smith", "Dr. M\u{00FC}ller", "O'Brien, Pat", "Anna 2nd", "\u{1F642}", "Bob \u{1F642} Smith",
                     "\u{0410}\u{043D}\u{043D}\u{0430} \u{0418}\u{0432}\u{0430}\u{043D}\u{043E}\u{0432}\u{0430}",
                     "\u{0393}\u{03B9}\u{03CE}\u{03C1}\u{03B3}\u{03BF}\u{03C2}", "\u{674E}\u{96F7}", "Henry \u{2167}",
                     "Acme, Inc.", "The New York Times"] {
            XCTAssertEqual(MailAddressRules.displayName(name, address: "x@example.com"), name, name)
        }
    }

    func testNoNameMeansTheAddressIsShown() {
        XCTAssertNil(MailAddressRules.displayName(nil, address: "bob@example.com"))
        XCTAssertNil(MailAddressRules.displayName("", address: "bob@example.com"))
        XCTAssertNil(MailAddressRules.displayName("   \t ", address: "bob@example.com"))
        XCTAssertNil(MailAddressRules.displayName("\u{200B}\u{202E}", address: "bob@example.com"),
                     "a name of nothing but what cannot be seen is no name")
    }

    /// `from-name-is-address`: a name that is an address is replaced by the address, whatever
    /// the address beside it is.
    func testANameThatContainsAnAddressOrBracketsIsReplacedByTheAddress() {
        for name in ["noor@plan.example", "Sam Lee <sam@plan.example>", "a > b", "Fwd <3", "me@here", "<", ">"] {
            XCTAssertNil(MailAddressRules.displayName(name, address: "x@evil.example"), name)
        }
    }

    func testAFullwidthAtSignOrBracketIsTheSameAsTheRealOne() {
        for name in ["noor\u{FF20}plan.example", "\u{FF1C}sam\u{FF1E}", "noor\u{FE6B}plan.example"] {
            XCTAssertNil(MailAddressRules.displayName(name, address: "x@evil.example"),
                         "\(name) reads as an address")
        }
    }

    func testANameThatReadsAsAWebAddressIsReplacedByTheAddress() {
        // (Which endings the system's link detector knows is its own list and moves with the
        // system, so nothing exotic is asserted here.)
        for name in ["paypal.com", "PAYPAL.COM", "Visit www.example.org now", "http://evil.example",
                     "Support: paypal.com/login", "Amazon.com Support"] {
            XCTAssertNil(MailAddressRules.displayName(name, address: "x@evil.example"), name)
        }
    }

    // MARK: - Scripts: one word, three scripts (L4)

    /// `Pаypal` with a Cyrillic letter, a Greek capital that is a Latin one, a Greek letter inside
    /// a Latin word: a word spelt in letters of two of the three scripts that pass for each other.
    func testAWordThatMixesLatinWithCyrillicOrGreekShowsTheAddress() {
        for name in ["P\u{0430}ypal", "\u{0430}pple", "Noor \u{0391}lpha", "A\u{03B1}b", "Bob Sm\u{0456}th",
                     "\u{041C}ark", "Hello \u{0421}orp", "\u{0441}afe"] {
            XCTAssertNil(MailAddressRules.displayName(name, address: "x@evil.example"), name)
            XCTAssertTrue(MailScripts.hasWordMixingLookAlikeScripts(name), name)
        }
        // Greek with Cyrillic in one word.
        XCTAssertTrue(MailScripts.hasWordMixingLookAlikeScripts("\u{03B1}\u{0431}"))
    }

    /// Per word: "Tinkoff Банк" is two words, each in its own script, and is how people there
    /// write. A Japanese name is Han and kana in one word and is a name. Latin beside Han,
    /// Hangul, Arabic or Devanagari deceives no one.
    func testNamesThatAreNotASpoofShowTheName() {
        for name in ["Tinkoff \u{0411}\u{0430}\u{043D}\u{043A}",              // Latin word, Cyrillic word
                     "\u{7530}\u{4E2D}\u{3055}\u{304F}\u{3089}",                   // Japanese: Han and Hiragana
                     "\u{7530}\u{4E2D} \u{3055}\u{304F}\u{3089}",
                     "\u{674E}\u{96F7} Lee",                                      // Han beside Latin
                     "\u{AE40}\u{BBFC}\u{C218} Kim",                              // Korean beside Latin
                     "\u{0623}\u{062D}\u{0645}\u{062F} 123",                      // Arabic with Latin digits
                     "Bob \u{05D0}\u{05D1}\u{05D2}",                               // Hebrew
                     "Raj \u{0930}\u{093E}\u{091C}",                                // Devanagari
                     "Ann \u{0410}\u{043D}\u{043D}\u{0430}",                        // Latin and Cyrillic words
                     "M\u{00FC}ller Jos\u{00E9} \u{00C5}ngstr\u{00F6}m",             // accented Latin
                     "\u{0410}\u{043D}\u{043D}\u{0430} 2024 \u{2014} \u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}!"] {
            XCTAssertEqual(MailAddressRules.displayName(name, address: "x@example.com"), name, name)
            XCTAssertFalse(MailScripts.hasWordMixingLookAlikeScripts(name), name)
        }
    }

    func testCharactersOfNoScriptDoNotMakeAMix() {
        XCTAssertEqual(MailAddressRules.displayName("Bob (work) \u{2713}", address: "x@y.com"), "Bob (work) \u{2713}")
        XCTAssertNil(MailAddressRules.displayName("\u{0410}nna-2", address: "x@y.com"),
                     "a Cyrillic capital then Latin letters is one word, whatever follows it")
        XCTAssertEqual(MailAddressRules.displayName("\u{0410}\u{043D}\u{043D}\u{0430}-2", address: "x@y.com"),
                       "\u{0410}\u{043D}\u{043D}\u{0430}-2")
    }

    func testHiddenCharactersAreRemovedBeforeTheNameIsJudgedAndShown() {
        XCTAssertEqual(MailAddressRules.displayName("Sam\u{200B} Lee", address: "x@y.com"), "Sam Lee")
        XCTAssertEqual(MailAddressRules.displayName("No\u{202E}or", address: "x@y.com"), "Noor")
        XCTAssertNil(MailAddressRules.displayName("sam\u{200B}@plan.example", address: "x@y.com"),
                     "with the joiner gone it is an address, which is what it was all along")
        // A joiner that splits a word between scripts is removed first, and the word is then
        // judged as what it really is.
        XCTAssertNil(MailAddressRules.displayName("P\u{200D}\u{0430}ypal", address: "x@y.com"))
    }

    func testAShownNameHasSingleSpacesAndNoLineBreaks() {
        XCTAssertEqual(MailAddressRules.displayName("  Bob \t  Smith  ", address: "x@y.com"), "Bob Smith")
        let shown = MailAddressRules.displayName("Bob\r\nBcc: attacker", address: "x@y.com") ?? ""
        XCTAssertEqual(shown, "Bob Bcc: attacker")
        XCTAssertFalse(shown.contains("\r") || shown.contains("\n"))
    }

    /// A name is a few words. One longer than any is text written to fill the space beside the
    /// address, and also bounds what the checks above have to read.
    func testANameLongerThan256CharactersIsReplacedByTheAddress() {
        XCTAssertNotNil(MailAddressRules.displayName(String(repeating: "a", count: 256), address: "x@y.com"))
        XCTAssertNil(MailAddressRules.displayName(String(repeating: "a", count: 257), address: "x@y.com"))
        XCTAssertNil(MailAddressRules.displayName(String(repeating: "a", count: 1_000_000), address: "x@y.com"))
    }

    func testTheNameIsJudgedOnItsOwnWhateverTheAddressIs() {
        XCTAssertEqual(MailAddressRules.displayName("Bob", address: "bob@example.com"), "Bob")
        XCTAssertEqual(MailAddressRules.displayName("Bob", address: "x@evil.example"), "Bob")
        XCTAssertEqual(MailAddressRules.displayName("Bob", address: ""), "Bob")
    }

    // MARK: - cleaned (the rest is in MailCleaningTests)

    func testCleaningTwiceChangesNothing() {
        for text in ["a\u{200B}b", "\u{202E}x\u{202C}", "plain", "", "\u{1F600}\u{200D}\u{1F600}", "a\u{FE00}\u{FE00}",
                     "\u{0645}\u{06CC}\u{200C}\u{062E}", "\u{1F3F4}\u{E0067}\u{E007F}", "x\u{E0067}y"] {
            let once = MailAddressRules.cleaned(text)
            XCTAssertEqual(MailAddressRules.cleaned(once), once, text.debugDescription)
        }
    }
}
