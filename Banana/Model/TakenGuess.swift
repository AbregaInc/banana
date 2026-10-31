import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// For a repeating reminder whose name no list knows — "AG1", "Morning stack", "Evening pills" —
/// the on-device model's guess at whether it's something taken (`ReminderToTaken`). Asked once
/// per name, on the device, and remembered; a guess only ever leads to an offer, never a move.
@MainActor
enum TakenGuess {
    private static let key = "takenGuess.v1"

    /// The model's answer for this name, when it has been asked.
    static func known(_ title: String) -> Bool? {
        answers[normalized(title)]
    }

    /// Asks about the names not yet asked about. True when any answer was new.
    static func ask(_ titles: [String]) async -> Bool {
        let asking = Array(Set(titles.map(normalized))).filter { !$0.isEmpty && answers[$0] == nil }.prefix(8)
        guard !asking.isEmpty else { return false }
        var learned = answers
        var changed = false
        for title in asking {
            guard let answer = await guess(title) else { continue }
            learned[title] = answer
            changed = true
        }
        if changed { UserDefaults.standard.set(learned, forKey: key) }
        return changed
    }

    private static var answers: [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool]) ?? [:]
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func guess(_ title: String) async -> Bool? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return nil }
        let availability = Intelligence.current
        guard Intelligence.route(.knowledge, given: availability) == .device,
              let (session, chosen) = Intelligence.session(for: .knowledge, instructions: instructions,
                                                           availability: availability) else { return nil }
        do {
            let answer: GeneratedTakenGuess = try await Intelligence.withTimeout(seconds: 10, route: chosen) {
                try await session.respond(to: "Reminder: \(title)", generating: GeneratedTakenGuess.self,
                                          options: .init(temperature: 0)).content
            }
            return answer.takesSomething
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static let instructions = """
    You decide whether a repeating phone reminder is about taking something — a supplement, \
    vitamin, medicine, pill, powder, drops, a shot or an inhaler — or about anything else: an \
    activity, a chore, an errand, a call, a meal, or a drink like coffee or water. Judge only the \
    reminder's words. Brand names of supplements (AG1, LMNT, Thorne) count as something taken.
    """
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedTakenGuess {
    @Guide(description: "True only if the reminder is about taking a supplement, vitamin, medicine or similar")
    var takesSomething: Bool
}
#endif
