import Foundation

/// The plain words of a phrase: lowercase, a plural as its singular, fillers ("a", "the", "with")
/// and numbers dropped. What "made of the person's own words" means for an event's title or place
/// (`EventPhrase`) and for a food's name (`GroundedFoodEstimate`).
enum PlainWords {
    static let fillers: Set<String> = ["a", "an", "and", "the", "of", "with", "in", "on", "some", "plain"]

    static func stemmed(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }

    /// Every word, in order, stemmed.
    static func ordered(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(stemmed)
    }

    static func words(_ text: String) -> Set<String> {
        Set(ordered(text).filter { !fillers.contains($0) && !$0.allSatisfy(\.isNumber) })
    }
}
