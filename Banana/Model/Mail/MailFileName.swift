#if !BANANA_PUBLIC
import Foundation

// This file names nothing outside Foundation and nothing outside itself, on purpose. P21a
// compiles it alone into the Mac-only checks (`MailMacChecks`, MAIL-ENGINE 18.6), where no other
// mail file is present, so a reference to `MailAddressRules` or any other mail type would stop
// that target building. Whatever else in mail needs what is shared here — `MailAddressRules`
// does — names it from the other side.

/// What cannot be seen in text a stranger wrote, and what is done about it (MAIL-ENGINE 10.8).
///
/// A sender writes names, subjects and file names, so a sender can put in them what a person
/// cannot see: a right-to-left override that makes `fdp.exe` read as `exe.pdf`, a zero-width
/// joiner that makes `sam@plan.example` two strings that look the same, a run of variation selectors
/// that carries a message inside another. `removing(from:)` takes out everything Unicode itself
/// calls invisible by design — `Default_Ignorable_Code_Point`, which is the standard
/// library's property and not a list of ours — **except where the character is doing its
/// work**, because removing it would change what a person reads:
///
/// 1. a variation selector directly after a character that is kept, is itself visible and is
///    not white space (emoji presentation; the ideograph variants Japanese names use);
/// 2. U+200D inside an emoji sequence (a family, a profession, a couple: one grapheme cluster
///    with an emoji, not ASCII, before the joiner and after it), and the tag sequence that
///    follows U+1F3F4 and ends in U+E007F (the flags of England, Scotland and Wales); a tag
///    anywhere else is removed, which is how text is hidden inside text;
/// 3. U+200C and U+200D where IDNA's own rule allows them (RFC 5892, A.1 and A.2): after a
///    virama, in the Indic scripts; and U+200C between a letter that joins to its left and one
///    that joins to its right, as in Persian and Urdu, where it is part of how a word is
///    spelt. Between Latin, Cyrillic or Greek letters neither is ever kept.
///
/// **A direction control is never kept**, inside an emoji sequence too: nothing in a name needs
/// one, and one is how a file called `invoice` + U+202E + `fdp.exe` is made to read as a PDF.
///
/// The joining types come from `NSRegularExpression`'s `\p{jt=…}`, the system's own Unicode
/// data, since the standard library does not expose them. If the system could not compile the
/// patterns the joiner of rule 3's second half is not kept — the safe direction — and
/// `MailCleaningTests` is where that is noticed.
enum MailHiddenCharacters {

    /// U+061C, U+200E–U+200F, U+202A–U+202E, U+2066–U+2069: what reorders the text around it.
    static func isDirectionControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    /// Whether the system compiled the joining-type patterns. A test asserts it.
    static var joiningPatternsCompile: Bool { JoiningTypes.patterns != nil }

    /// `text` without what cannot be seen, as above. Everything else — emoji, every script, the
    /// joiners and selectors that are doing their work — stays. Linear in the text: each
    /// scalar is looked at a bounded number of times, and a joining type is asked of the
    /// system once for each distinct scalar.
    static func removing(from text: String) -> String {
        // Most text has none, and most text is short: do not build a second string for it.
        guard text.unicodeScalars.contains(where: { $0.properties.isDefaultIgnorableCodePoint }) else {
            return text
        }
        // The direction controls go first, whatever they are inside. What is left is what
        // the other rules look at, so that a control put in the middle of an emoji sequence or
        // a Persian word cannot stand between two things that belong together (it is gone, and
        // they are together) or break the sequence's cluster.
        var text = text
        if text.unicodeScalars.contains(where: isDirectionControl) {
            var without = String.UnicodeScalarView()
            for scalar in text.unicodeScalars where !isDirectionControl(scalar) { without.append(scalar) }
            text = String(without)
        }
        let s = Array(text.unicodeScalars)
        let n = s.count
        var keep = [Bool](repeating: true, count: n)
        var clusters: (start: [Int], end: [Int])?
        let joining = JoiningTypes()

        var i = 0
        while i < n {
            let scalar = s[i]
            guard scalar.properties.isDefaultIgnorableCodePoint else { i += 1; continue }

            if isDirectionControl(scalar) {
                keep[i] = false
            } else if scalar.properties.isVariationSelector {
                keep[i] = i > 0 && keep[i - 1] && isVisible(s[i - 1])
            } else if scalar.value == 0x200D {
                if clusters == nil { clusters = clusterBounds(of: text, count: n) }
                keep[i] = joinsEmoji(s, at: i, clusters: clusters) || followsVirama(s, keep, at: i)
            } else if scalar.value == 0x200C {
                keep[i] = followsVirama(s, keep, at: i) || joinsLetters(s, at: i, joining)
            } else if (0xE0020...0xE007F).contains(scalar.value) {
                // A whole tag run is kept or removed together, so the loop moves past it.
                let end = tagRunEnd(s, from: i)
                let keepRun = isFlagTagSequence(s, keep, from: i, to: end)
                for k in i..<end { keep[k] = keepRun }
                i = end
                continue
            } else {
                keep[i] = false
            }
            i += 1
        }

        var kept = String.UnicodeScalarView()
        for (scalar, stays) in zip(s, keep) where stays { kept.append(scalar) }
        return String(kept)
    }

    // MARK: - The exceptions

    /// A character a selector may attach to: not white space, and not itself invisible.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x80 && scalar.properties.isEmoji
    }

    /// For each scalar, where its grapheme cluster (one `Character`) starts and ends.
    private static func clusterBounds(of text: String, count: Int) -> (start: [Int], end: [Int]) {
        var starts = [Int](repeating: 0, count: count)
        var ends = [Int](repeating: 0, count: count)
        var offset = 0
        for character in text {
            let size = character.unicodeScalars.count
            for k in offset..<min(offset + size, count) { starts[k] = offset; ends[k] = offset + size }
            offset += size
        }
        return (starts, ends)
    }

    /// U+200D with an emoji (not ASCII) before it and after it, inside one cluster. A variation
    /// selector between the first emoji and the joiner (a heart, in a couple) is looked past.
    private static func joinsEmoji(_ s: [Unicode.Scalar], at i: Int,
                                   clusters: (start: [Int], end: [Int])?) -> Bool {
        guard let clusters else { return false }
        let first = clusters.start[i], last = clusters.end[i]
        guard i > first, i + 1 < last else { return false }
        var before = i - 1
        while before > first, s[before].properties.isVariationSelector { before -= 1 }
        return isEmoji(s[before]) && isEmoji(s[i + 1])
    }

    /// RFC 5892 A.1 and A.2: a joiner directly after a virama.
    private static func followsVirama(_ s: [Unicode.Scalar], _ keep: [Bool], at i: Int) -> Bool {
        i > 0 && keep[i - 1] && s[i - 1].properties.canonicalCombiningClass == .virama
    }

    /// RFC 5892 A.1, the joining half: a letter that joins to its left, at most eight
    /// transparent marks, the joiner, at most eight transparent marks, a letter that joins to
    /// its right.
    private static func joinsLetters(_ s: [Unicode.Scalar], at i: Int, _ joining: JoiningTypes) -> Bool {
        var before = i - 1
        var skipped = 0
        while before >= 0, joining.type(of: s[before]) == .transparent {
            before -= 1
            skipped += 1
            if skipped > 8 { return false }
        }
        guard before >= 0 else { return false }
        let left = joining.type(of: s[before])
        guard left == .left || left == .dual else { return false }

        var after = i + 1
        skipped = 0
        while after < s.count, joining.type(of: s[after]) == .transparent {
            after += 1
            skipped += 1
            if skipped > 8 { return false }
        }
        guard after < s.count else { return false }
        let right = joining.type(of: s[after])
        return right == .right || right == .dual
    }

    private static func isTag(_ scalar: Unicode.Scalar) -> Bool { (0xE0020...0xE007F).contains(scalar.value) }

    private static func tagRunEnd(_ s: [Unicode.Scalar], from start: Int) -> Int {
        var end = start
        while end < s.count, isTag(s[end]) { end += 1 }
        return end
    }

    /// U+1F3F4, kept, then one or more tags U+E0020–U+E007E and U+E007F last, and nothing more.
    private static func isFlagTagSequence(_ s: [Unicode.Scalar], _ keep: [Bool], from start: Int,
                                          to end: Int) -> Bool {
        guard start > 0, keep[start - 1], s[start - 1].value == 0x1F3F4, end - start >= 2,
              s[end - 1].value == 0xE007F else { return false }
        return s[start..<(end - 1)].allSatisfy { $0.value != 0xE007F }
    }

    // MARK: - Joining types

    private enum JoiningType { case left, dual, right, transparent, none }

    /// The Unicode `Joining_Type` of a scalar, asked of the system's regular-expression engine
    /// (`\p{jt=L}` and the rest) and remembered for the length of one cleaning.
    private final class JoiningTypes {

        /// Compiled once; nil if the system could not compile any of the four.
        static let patterns: [(JoiningType, NSRegularExpression)]? = {
            let wanted: [(JoiningType, String)] = [(.left, #"\p{jt=L}"#), (.dual, #"\p{jt=D}"#),
                                                   (.right, #"\p{jt=R}"#), (.transparent, #"\p{jt=T}"#)]
            var compiled: [(JoiningType, NSRegularExpression)] = []
            for (type, pattern) in wanted {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
                compiled.append((type, expression))
            }
            return compiled
        }()

        private var known: [UInt32: JoiningType] = [:]

        func type(of scalar: Unicode.Scalar) -> JoiningType {
            // Nothing below the combining marks joins, and most text lives there.
            if scalar.value < 0x0300 { return .none }
            if let cached = known[scalar.value] { return cached }
            var found = JoiningType.none
            if let patterns = Self.patterns {
                let text = String(scalar)
                let range = NSRange(location: 0, length: text.utf16.count)
                for (type, expression) in patterns
                where expression.firstMatch(in: text, options: [], range: range) != nil {
                    found = type
                    break
                }
            }
            known[scalar.value] = found
            return found
        }
    }
}

/// A file name that came from a stranger, made safe to show, to save under and to hand to a
/// share sheet (MAIL-ENGINE 10.8, 11.2).
///
/// The name is the sender's. It may hold a path ("../../x"), a hidden-file dot, a direction
/// override that turns `invoice` + U+202E + `fdp.exe` into a name that reads as a PDF, a control
/// character, or be a megabyte long. What is left is a single plain component, at most 255
/// bytes — the longest name the file system takes — with its extension kept, because the
/// extension is what the person reads to know what the file is.
enum MailFileName {

    /// What an empty or fully stripped name becomes.
    static let fallback = "Attachment"

    /// The longest name a file system here takes, in UTF-8 bytes.
    static let maxBytes = 255

    /// The longest extension that is kept whole when the name must be cut. A longer "extension"
    /// is just more of the name, and is cut with it.
    static let maxExtensionBytes = 32

    /// `name` with `/`, `:`, NUL, control characters and direction characters removed, what
    /// cannot be seen removed as everywhere (`MailHiddenCharacters`), runs of whitespace made
    /// one space, leading dots removed, and cut to 255 bytes with its extension kept. Never
    /// empty and never nothing but an extension: what has nothing left becomes "Attachment".
    ///
    /// The tab, line feeds and the like are control characters and also whitespace; they become
    /// a space rather than vanishing, so "a<tab>b" does not run its words together. Every
    /// other control character is removed.
    static func safe(_ name: String) -> String {
        // First what names a path or a stream, and the controls: they go before the invisible
        // characters are judged, so that a selector left standing after a "/" is not kept.
        var visible = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if isSeparator(scalar) { continue }
            if scalar.properties.isWhitespace { visible.append(" "); continue }
            if scalar.properties.generalCategory == .control { continue }
            visible.append(scalar)
        }
        // Then what cannot be seen, and then the whitespace that leaves behind.
        let cleaned = Array(MailHiddenCharacters.removing(from: String(visible)).unicodeScalars)

        var kept: [Unicode.Scalar] = []
        kept.reserveCapacity(min(cleaned.count, 4 * maxBytes))
        var lastWasSpace = true          // so leading whitespace never starts the result
        for scalar in cleaned {
            if scalar.properties.isWhitespace {
                if !lastWasSpace { kept.append(" "); lastWasSpace = true }
                continue
            }
            kept.append(scalar)
            lastWasSpace = false
        }

        // Leading dots, and any whitespace or invisible character they uncover, until the first
        // character is none of those. By index, not by removing one at a time: a name of a
        // hundred thousand dots must not cost a hundred thousand shifts.
        var start = 0
        while start < kept.count, isInert(kept[start], leading: true) { start += 1 }
        var end = kept.count
        while end > start, isInert(kept[end - 1], leading: false) { end -= 1 }

        guard start < end else { return fallback }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: kept[start..<end])
        return fit(String(text))
    }

    // MARK: - Cutting to length

    /// `text` within `maxBytes`, with its extension, if it has one, intact. Cuts on a character
    /// boundary, never inside a character or a cluster.
    private static func fit(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }

        var base = text
        var suffix = ""
        if let dot = text.lastIndex(of: "."), dot != text.startIndex {
            let candidate = String(text[dot...])           // ".pdf"
            if candidate.utf8.count - 1 <= maxExtensionBytes, !candidate.contains(" "),
               candidate.count > 1 {
                base = String(text[..<dot])
                suffix = candidate
            }
        }

        let room = maxBytes - suffix.utf8.count
        var kept = ""
        var used = 0
        for character in base {
            let size = String(character).utf8.count
            if used + size > room { break }
            kept.append(character)
            used += size
        }
        while kept.unicodeScalars.last == " " { kept.unicodeScalars.removeLast() }
        // A first character too big for the room (a letter under three hundred combining marks)
        // leaves nothing of the base. The name is then "Attachment" and its extension, never
        // the extension alone, which would be a hidden file.
        return kept.isEmpty ? fallback + suffix : kept + suffix
    }

    // MARK: - Classification

    /// What names a path or a stream in some file system here: removed, never replaced.
    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "/" || scalar == ":" || scalar.value == 0
    }

    /// What may not begin a name (dots, spaces, and what cannot be seen) and what may not end it.
    private static func isInert(_ scalar: Unicode.Scalar, leading: Bool) -> Bool {
        if scalar == " " || scalar.properties.isDefaultIgnorableCodePoint { return true }
        return leading && scalar == "."
    }
}

#endif
