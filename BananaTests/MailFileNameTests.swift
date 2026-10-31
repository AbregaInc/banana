import XCTest

/// A file name from a stranger, made safe (MAIL-ENGINE 10.8, 11.2).
///
/// The name is what a person reads to know what a file is, and it is written by whoever sent
/// it. The shapes are a path that climbs out of a folder, a leading dot that hides the file, a
/// direction override that makes an executable read as a document, control characters, a name
/// longer than any file system takes, and nothing at all.
final class MailFileNameTests: XCTestCase {

    private func safe(_ name: String) -> String { MailFileName.safe(name) }

    // MARK: - Unchanged

    func testAnOrdinaryNameIsUnchanged() {
        for name in ["invoice.pdf", "Quarterly report (final) v2.xlsx", "photo 2026-10-06.jpeg", "résumé.pdf",
                     "日本語.txt", "a", "archive.tar.gz", "no extension", "emoji 😀.png"] {
            XCTAssertEqual(safe(name), name)
        }
    }

    // MARK: - What is removed

    /// `attachment-rlo-name` (a P21a fixture): `invoice` then a right-to-left override then
    /// `fdp.exe`, which a reader sees as "invoiceexe.pdf".
    func testADirectionOverrideIsRemovedSoAnExecutableDoesNotReadAsAPDF() {
        XCTAssertEqual(safe("invoice\u{202E}fdp.exe"), "invoicefdp.exe")
        XCTAssertEqual(safe("\u{202E}fdp.exe"), "fdp.exe")
        XCTAssertEqual(safe("a\u{2066}b\u{2069}c\u{200F}d\u{061C}e"), "abcde")
    }

    func testInvisibleCharactersAreRemoved() {
        XCTAssertEqual(safe("pay\u{200B}pal\u{2060}.pdf\u{FEFF}"), "paypal.pdf")
    }

    func testSlashesAndColonsAndNULAreRemovedNotReplaced() {
        XCTAssertEqual(safe("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(safe("a/b/c.txt"), "abc.txt")
        XCTAssertEqual(safe("C:\\Users\\x.txt"), "C\\Users\\x.txt",
                       "only the colon goes; a backslash is no separator on these file systems")
        XCTAssertEqual(safe("a:b"), "ab")
        XCTAssertEqual(safe("a\u{0}b.txt"), "ab.txt")
        XCTAssertEqual(safe("/"), "Attachment")
        XCTAssertEqual(safe("///:::"), "Attachment")
    }

    func testControlCharactersAreRemovedAndTheWhitespaceAmongThemBecomesASpace() {
        XCTAssertEqual(safe("a\u{07}b\u{1B}c\u{7F}d\u{9F}e"), "abcde")
        XCTAssertEqual(safe("a\tb"), "a b", "a tab is whitespace as well as a control: words do not run together")
        XCTAssertEqual(safe("a\r\nb\nc"), "a b c")
        XCTAssertEqual(safe("a\u{0085}b"), "a b")
    }

    func testLeadingDotsAreRemovedSoAFileIsNotHidden() {
        XCTAssertEqual(safe(".hidden"), "hidden")
        XCTAssertEqual(safe("...x"), "x")
        XCTAssertEqual(safe("..\u{202E}.bashrc"), "bashrc", "a dot behind an override is leading too")
        XCTAssertEqual(safe(". .  name"), "name", "and so is whitespace the dots uncover")
        XCTAssertEqual(safe("a.b.c"), "a.b.c", "only leading ones")
        XCTAssertEqual(safe("name."), "name.")
    }

    func testWhitespaceIsCollapsedAndTrimmed() {
        XCTAssertEqual(safe("  a    b \n c  "), "a b c")
        XCTAssertEqual(safe("a\u{00A0}\u{00A0}b\u{3000}c"), "a b c")
        XCTAssertEqual(safe("a\u{2028}b"), "a b")
    }

    func testAnEmptyOrFullyStrippedNameBecomesAttachment() {
        for name in ["", "   ", ".", "..", "...", ". .", "\u{200B}", "\u{202E}", "\u{0}", "/", ":", "\t\n", "\u{7}"] {
            XCTAssertEqual(safe(name), "Attachment", name.debugDescription)
        }
    }

    // MARK: - 255 bytes, extension kept

    func testANameOfExactly255BytesIsUnchanged() {
        let name = String(repeating: "a", count: 251) + ".pdf"
        XCTAssertEqual(name.utf8.count, 255)
        XCTAssertEqual(safe(name), name)
    }

    func testALongNameIsCutToFitWithItsExtensionKept() {
        let result = safe(String(repeating: "a", count: 300) + ".pdf")
        XCTAssertEqual(result.utf8.count, 255)
        XCTAssertTrue(result.hasSuffix(".pdf"))
        XCTAssertEqual(result, String(repeating: "a", count: 251) + ".pdf")
    }

    func testTheCutIsOnACharacterBoundaryAndCountedInBytes() {
        let twoByte = safe(String(repeating: "é", count: 200) + ".txt")
        XCTAssertLessThanOrEqual(twoByte.utf8.count, 255)
        XCTAssertTrue(twoByte.hasSuffix(".txt"))
        XCTAssertEqual(Set(twoByte.dropLast(4)), ["é"], "no half characters")
        XCTAssertEqual(twoByte.dropLast(4).count, 125, "251 bytes of two-byte characters is 125")

        // A flag is two scalars and eight bytes; a cluster is never split.
        let flags = safe(String(repeating: "🇯🇵", count: 100) + ".png")
        XCTAssertLessThanOrEqual(flags.utf8.count, 255)
        XCTAssertEqual(Set(flags.dropLast(4)), ["🇯🇵"])
        XCTAssertEqual(flags.dropLast(4).count, 31)
    }

    func testAnExtensionTooLongToBeOneIsCutWithTheNameAndAThirtyTwoByteOneIsKept() {
        let ext32 = String(repeating: "x", count: 32)
        let kept = safe(String(repeating: "a", count: 300) + "." + ext32)
        XCTAssertEqual(kept.utf8.count, 255)
        XCTAssertTrue(kept.hasSuffix("." + ext32))

        let tooLong = safe(String(repeating: "a", count: 300) + "." + String(repeating: "x", count: 40))
        XCTAssertLessThanOrEqual(tooLong.utf8.count, 255)
        XCTAssertFalse(tooLong.isEmpty)
    }

    func testAnExtensionWithASpaceInItIsNotAnExtension() {
        let result = safe(String(repeating: "a", count: 300) + ".a b")
        XCTAssertLessThanOrEqual(result.utf8.count, 255)
        XCTAssertFalse(result.hasSuffix(".a b"))
    }

    func testANameOfNothingButABigExtensionStillComesBackWithinTheLimit() {
        let result = safe("." + String(repeating: "x", count: 400))
        XCTAssertEqual(result.utf8.count, 255)
        XCTAssertFalse(result.hasPrefix("."))
    }

    func testAMegabyteNameIsCutToo() {
        let result = safe(String(repeating: "n", count: 1_000_000) + ".docx")
        XCTAssertEqual(result.utf8.count, 255)
        XCTAssertTrue(result.hasSuffix(".docx"))
    }

    /// MINOR 5: one letter under three hundred combining marks, then `.pdf`: the cluster does not
    /// fit, nothing of the base is kept, and the answer used to be `.pdf`, a hidden file.
    func testABaseThatCannotFitLeavesAttachmentAndTheExtensionAndNeverAHiddenFile() {
        let result = safe("a" + String(repeating: "\u{0301}", count: 300) + ".pdf")
        XCTAssertEqual(result, "Attachment.pdf")
        XCTAssertFalse(result.hasPrefix("."))
        XCTAssertLessThanOrEqual(result.utf8.count, 255)
    }

    func testANameOfNothingButInvisibleCharactersAfterTheDotsIsAttachment() {
        XCTAssertEqual(safe(".\u{FE0F}"), "Attachment")
        XCTAssertEqual(safe("/\u{FE0F}"), "Attachment")
        XCTAssertEqual(safe(". \u{200B} \u{E0067}"), "Attachment")
        XCTAssertEqual(safe("/\u{FE0F}x"), "x", "a selector left standing after a slash is not kept")
    }

    func testAJoinedEmojiInANameSurvivesAndAJoinerBetweenLettersDoesNot() {
        XCTAssertEqual(safe("\u{1F469}\u{200D}\u{1F4BB}.png"), "\u{1F469}\u{200D}\u{1F4BB}.png")
        XCTAssertEqual(safe("pay\u{200D}pal.pdf"), "paypal.pdf")
        XCTAssertEqual(safe("\u{0645}\u{06CC}\u{200C}\u{062E}.txt"), "\u{0645}\u{06CC}\u{200C}\u{062E}.txt")
    }

    // MARK: - Always safe

    func testWhateverGoesInTheResultIsAPlainNameWithinTheLimit() {
        var generator = MailTestSplitMix(seed: 0x5EED)
        // Interesting scalars: separators, controls, hidden characters, dots, spaces, ASCII,
        // multi-byte, a combining mark, emoji and a regional indicator.
        let pool: [UInt32] = [0x2F, 0x3A, 0x00, 0x07, 0x09, 0x0A, 0x7F, 0x85, 0x9F, 0x2E, 0x2E, 0x20, 0x20, 0x41, 0x62,
                              0x30, 0xE9, 0x20AC, 0x1F600, 0x1F1EF, 0x0301, 0x202E, 0x200B, 0x200D, 0x2066, 0xFEFF,
                              0x061C, 0xA0, 0x2028, 0x3000]
        for _ in 0..<2_000 {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<Int(generator.next() % 400) {
                if let scalar = Unicode.Scalar(pool[Int(generator.next() % UInt64(pool.count))]) { scalars.append(scalar) }
            }
            let name = String(scalars)
            let result = safe(name)
            XCTAssertFalse(result.isEmpty, name.debugDescription)
            XCTAssertLessThanOrEqual(result.utf8.count, 255, name.debugDescription)
            XCTAssertFalse(result.hasPrefix("."), name.debugDescription)
            XCTAssertFalse(result.hasPrefix(" ") || result.hasSuffix(" "), name.debugDescription)
            XCTAssertFalse(result.contains("  "), name.debugDescription)
            for scalar in result.unicodeScalars {
                XCTAssertFalse(scalar == "/" || scalar == ":" || scalar.value == 0, name.debugDescription)
                XCTAssertNotEqual(scalar.properties.generalCategory, .control, name.debugDescription)
                XCTAssertFalse(MailHiddenCharacters.isDirectionControl(scalar), name.debugDescription)
                XCTAssertFalse([0x200B, 0x2060, 0xFEFF].contains(scalar.value), name.debugDescription)
            }
            XCTAssertEqual(safe(result), result, "making a name safe twice changes nothing: \(name.debugDescription)")
        }
    }
}

/// A small deterministic generator, so a failing name can be found again.
private struct MailTestSplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
