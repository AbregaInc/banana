import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Structured credits pulled from an episode's show notes / description by the on-device
/// language model. Everything is optional — the model returns only what the notes state.
struct EpisodeNarrator: Codable, Hashable, Identifiable {
    enum Role: String, Codable, Hashable {
        case primary
        case supporting
        case unknown
    }

    var id: String { name.lowercased() }
    var name: String
    var role: Role = .unknown
    /// Filled once audio diarization can link this credited person to a recurring voice.
    var voiceClusterID: String?
    /// The evidence behind the name. A credit is stronger than an unconfirmed voice match.
    var confidence: Double = 1
}

struct EpisodeCredits: Codable, Hashable {
    var host: String?
    var guests: [String] = []
    /// Every credited reader. Sleep stories can have a main reader plus guests or alternating parts.
    var narrators: [EpisodeNarrator] = []
    /// Free-text roles the model couldn't slot elsewhere ("Music by …", "Producer …").
    var others: [String] = []

    var isEmpty: Bool { host == nil && guests.isEmpty && narrators.isEmpty && others.isEmpty }

    /// Kept for old UI and callers while older cache files are migrated on read.
    var narratorNames: [String] { narrators.map(\.name) }

    private enum CodingKeys: String, CodingKey { case host, guests, narrators, narrator, others }

    init(host: String? = nil, guests: [String] = [], narrators: [EpisodeNarrator] = [], others: [String] = []) {
        self.host = host
        self.guests = guests
        self.narrators = narrators
        self.others = others
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        guests = try c.decodeIfPresent([String].self, forKey: .guests) ?? []
        narrators = try c.decodeIfPresent([EpisodeNarrator].self, forKey: .narrators) ?? []
        if narrators.isEmpty, let narrator = try c.decodeIfPresent(String.self, forKey: .narrator) {
            narrators = [EpisodeNarrator(name: narrator, role: .primary)]
        }
        others = try c.decodeIfPresent([String].self, forKey: .others) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encode(guests, forKey: .guests)
        try c.encode(narrators, forKey: .narrators)
        try c.encode(others, forKey: .others)
    }
}

/// Extracts `EpisodeCredits` from episode metadata using Apple's on-device model
/// (`FoundationModels`, iOS 26). Falls back to `nil` when the model is unavailable so
/// callers can degrade gracefully.
enum CreditsExtractor {

    /// `extract`'s result, distinguishing "no credits found" from "this input deterministically
    /// can't be processed" — only the latter is safe for a caller to remember and skip retrying.
    enum Outcome {
        case credits(EpisodeCredits?)
        /// The model threw `exceededContextWindowSize` for this exact (title, showNotes) pair.
        /// That input size doesn't change between calls in the same process, so a retry would
        /// throw the same way — unlike `.refusal`/`.decodingFailure`, which are properties of a
        /// sampled, non-deterministic generation and can succeed on a later attempt.
        case permanentlyUnavailable
    }

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    static func extract(title: String, showNotes: String) async -> Outcome {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return .credits(nil) }
            let notes = cleaned(showNotes)
            guard !notes.isEmpty else { return .credits(nil) }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let prompt = """
                Episode title: \(title)

                Show notes:
                \(notes.prefix(4000))
                """
                let response = try await session.respond(to: prompt, generating: GeneratedCredits.self)
                return .credits(response.content.asCredits)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                return .permanentlyUnavailable
            } catch {
                return .credits(nil)
            }
        }
        #endif
        return .credits(nil)
    }

    /// Strip HTML tags and collapse whitespace — show notes are usually HTML.
    private static func cleaned(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let instructions = """
    You extract the people credited in a podcast episode from its show notes. \
    Only include names that the notes explicitly mention. Do not guess or invent names. \
    Put the main host in `host`, interview guests in `guests`, and — for sleep stories or \
    narrated fiction — every person who reads the story in `narrators`. Mark the main long-form \
    reader as `primary`; use `supporting` for a substantial second reader. Put any other credited \
    roles (producer, music, editor) as short strings in `others`. Leave fields empty when \
    the notes don't state them.
    """
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
private struct GeneratedCredits {
    @Guide(description: "The main host or presenter, if named.")
    var host: String?
    @Guide(description: "Interview guests explicitly named in the notes.")
    var guests: [String]
    @Guide(description: "For sleep stories or narrated content, every credited reader. Include only explicitly named people.")
    var narrators: [GeneratedNarrator]
    @Guide(description: "Other credited roles, e.g. 'Produced by Jane Doe'.")
    var others: [String]

    var asCredits: EpisodeCredits {
        func clean(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let readers = narrators.compactMap { narrator -> EpisodeNarrator? in
            guard let name = clean(narrator.name) else { return nil }
            return EpisodeNarrator(name: name, role: EpisodeNarrator.Role(rawValue: narrator.role) ?? .unknown)
        }
        return EpisodeCredits(host: clean(host),
                              guests: guests.compactMap(clean),
                              narrators: readers,
                              others: others.compactMap(clean))
    }
}

@available(iOS 26, *)
@Generable
private struct GeneratedNarrator {
    @Guide(description: "The explicitly credited narrator's name.")
    var name: String?
    @Guide(description: "One of: primary, supporting, unknown.")
    var role: String
}
#endif
