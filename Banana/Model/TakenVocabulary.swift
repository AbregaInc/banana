import Foundation

/// The names of things people take: every prescribable drug's generic and brand names (RxNorm)
/// and the ingredients and brands on NIH's supplement labels (DSLD), bundled as
/// Resources/TakenVocabulary.json by tools/build_taken_vocabulary.py. What tells "Synthroid",
/// "LMNT" or "L-theanine" apart from "Workout" (`ReminderToTaken`) — matched on the device, so a
/// reminder's title goes nowhere. Pure apart from reading the file once.
enum TakenVocabulary {
    struct Lists: Sendable {
        var medications: Set<String> = []
        var supplements: Set<String> = []

        var isEmpty: Bool { medications.isEmpty && supplements.isEmpty }
    }

    /// The bundled lists, read the first time they're needed.
    static let bundled: Lists = load(Bundle.main.url(forResource: "TakenVocabulary", withExtension: "json"))

    static func load(_ url: URL?) -> Lists {
        struct File: Decodable {
            var medications: [String]
            var supplements: [String]
        }
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return Lists() }
        return Lists(medications: Set(file.medications), supplements: Set(file.supplements))
    }

    /// What a title names, if it names something taken: a medication (which wins — Banana never
    /// suggests re-timing one) or a supplement. Runs of up to four words are looked up as written
    /// and singular ("Vitamins" is "vitamin").
    static func kind(of title: String, in lists: Lists = bundled) -> SupplementSchedule.Kind? {
        guard !lists.isEmpty else { return nil }
        let asWritten = self.words(title)
        // "L-Theanine" is also "theanine", "Omega-3" also "omega 3": the hyphen's parts as words.
        let split = asWritten.flatMap { $0.split(separator: "-").map(String.init) }
        var supplement = false
        for words in split == asWritten ? [asWritten] : [asWritten, split] {
            switch kind(words, in: lists) {
            case .medication?: return .medication
            case .supplement?: supplement = true
            case nil: break
            }
        }
        return supplement ? .supplement : nil
    }

    private static func kind(_ words: [String], in lists: Lists) -> SupplementSchedule.Kind? {
        var supplement = false
        for length in stride(from: min(4, words.count), through: 1, by: -1) {
            for start in 0...(words.count - length) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                for candidate in [phrase, singular(phrase)] {
                    if lists.medications.contains(candidate) { return .medication }
                    if lists.supplements.contains(candidate) { supplement = true }
                }
            }
        }
        return supplement ? .supplement : nil
    }

    /// Lowercased words, as the build script writes names: letters, digits, "+" and "-" kept
    /// ("omega-3", "b12"), the rest spaces.
    static func words(_ title: String) -> [String] {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9+\\- ]", with: " ", options: .regularExpression)
            .split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    /// "vitamins" → "vitamin", "probiotics" → "probiotic"; "glass" stays.
    private static func singular(_ phrase: String) -> String {
        guard phrase.count > 4, phrase.hasSuffix("s"), !phrase.hasSuffix("ss") else { return phrase }
        return String(phrase.dropLast())
    }
}
