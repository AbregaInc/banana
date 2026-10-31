import Foundation

/// Who narrated an episode, read from what the publisher already tells us.
///
/// Shows that use a rotating cast usually say so in the episode notes — Get Sleepy writes
/// "Narrator: Thomas Jones 🇬🇧" on essentially every recent episode. That is free, exact, and
/// needs no audio: measured over a real library, 99% of the most recent 400 episodes name their
/// narrator, and the 1% that do not are old ones. A voice model asked the same question is
/// inferring, at around 90% accuracy and a real battery cost, something already written down.
enum NarratorCredit {

    /// The label the publisher writes before the name.
    ///
    /// Deliberately narrow. Loosening this to catch "Read by" or "Voiced by" would also start
    /// matching prose in the episode description, and a wrong narrator is worse than none: it
    /// silently filters episodes the listener wanted.
    private static let pattern = try! NSRegularExpression(
        pattern: "Narrator:\\s*(.{2,60}?)\\s*(?=\\p{Regional_Indicator}|Writer:|Sound|Music|<|$)",
        options: [.caseInsensitive])

    /// The narrator named in an episode's notes, or nil when none is given.
    static func name(in summary: String?) -> String? {
        guard let summary, !summary.isEmpty else { return nil }
        let range = NSRange(summary.startIndex..., in: summary)
        guard let match = pattern.firstMatch(in: summary, range: range),
              let captured = Range(match.range(at: 1), in: summary) else { return nil }
        return tidy(String(summary[captured]))
    }

    /// Strip the decoration publishers put around the name: flags, the writing hand that follows a
    /// writer credit, HTML entities, and stray punctuation.
    private static func tidy(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        // Publishers emit both the entity and the literal non-breaking space, and a name holding
        // one never matches the same name holding the other — which left "Thomas" failing to
        // resolve onto "Thomas Jones" and quietly doubling the roster.
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        // Keep only what can appear in a name. `isEmojiPresentation` alone is not enough: the
        // writing hand a writer credit trails is U+270D plus a variation selector, and U+270D is
        // text-default, so it survived — leaving "Thomas Jones ✍️" as a second spelling and making
        // the merge of plain "Thomas" ambiguous enough to abandon.
        text.unicodeScalars.removeAll { scalar in
            // Default-ignorable first: `CharacterSet.letters` covers Unicode categories L* AND M*,
            // so a variation selector (U+FE0F, a nonspacing mark) counts as a letter and survived
            // the filter. That left "Thomas Jones ✍️" as a second spelling of the same narrator,
            // which made resolving plain "Thomas" ambiguous and abandoned the merge. Real accents
            // are marks too, so they are kept — only the invisible ones go.
            if scalar.properties.isDefaultIgnorableCodePoint { return true }
            return !(CharacterSet.letters.contains(scalar)
                     || CharacterSet.whitespaces.contains(scalar)
                     || "'’-.".unicodeScalars.contains(scalar))
        }
        text = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–—\t\n\r"))
        guard trimmed.count >= 2, trimmed.rangeOfCharacter(from: .letters) != nil else { return nil }
        return trimmed
    }

    /// Resolve the short forms a publisher mixes in ("Thomas" beside "Thomas Jones") onto one name.
    ///
    /// Without this a show reads as having far more narrators than it has — a real library showed
    /// 29 distinct credits for 20 actual people — and muting "Thomas Jones" would leave the
    /// episodes credited to plain "Thomas" still arriving.
    static func canonical(_ name: String, among known: some Collection<String>) -> String {
        let full = known.filter { $0.contains(" ") }.sorted { $0.count > $1.count }
        let lowered = name.lowercased()
        // A short form must be an unambiguous prefix: "Chris" matching both "Chris Adams" and
        // "Chris Bell" is not a credit we can resolve, so it stays as written.
        let candidates = full.filter { $0.lowercased() == lowered || $0.lowercased().hasPrefix(lowered + " ") }
        // Spellings that differ only in capitals are one person, not an ambiguity.
        let people = Dictionary(grouping: candidates, by: { $0.lowercased() })
        guard people.count == 1, let spellings = people.values.first else { return name }
        return spellings.count == 1 ? spellings[0] : preferredSpelling(spellings)
    }

    /// One spelling per person. Publishers are inconsistent about capitalising particles — the
    /// same narrator appears as both "Chloe De Burgh" and "Chloe de Burgh" — and two spellings
    /// mean muting one leaves the other still arriving.
    private static func preferredSpelling(_ variants: some Collection<String>) -> String {
        variants.sorted {
            let a = $0.filter(\.isUppercase).count, b = $1.filter(\.isUppercase).count
            return a == b ? $0 < $1 : a > b
        }.first ?? ""
    }

    /// Every narrator a show credits, canonicalised, most frequent first.
    static func roster(for summaries: some Sequence<String?>) -> [(name: String, episodes: Int)] {
        let raw = summaries.compactMap { name(in: $0) }
        let known = Set(raw)
        var byFold: [String: (spellings: Set<String>, count: Int)] = [:]
        for credit in raw {
            let resolved = canonical(credit, among: known)
            let key = resolved.lowercased()
            var entry = byFold[key] ?? (spellings: [], count: 0)
            entry.spellings.insert(resolved)
            entry.count += 1
            byFold[key] = entry
        }
        return byFold.values.map { (name: preferredSpelling($0.spellings), episodes: $0.count) }
            .sorted { $0.episodes == $1.episodes ? $0.name < $1.name : $0.episodes > $1.episodes }
    }
}
