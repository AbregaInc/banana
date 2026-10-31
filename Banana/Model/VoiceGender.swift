import Foundation

/// What a narrator's voice sounds like, for shows that never say who is reading.
///
/// A guess, always — see `VoiceGenderClassifier` for how it is made and how often it is wrong.
/// Kept out of that file so the shared model layer can refer to it without pulling CoreML in.
enum VoiceGender: String, Codable, Sendable, CaseIterable {
    case male, female

    var label: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        }
    }
}
