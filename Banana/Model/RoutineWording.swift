import Foundation

/// What each kind of routine does, in the words the app shows. Pure, for tests.
///
/// The words used to promise more than the app did: "Nudge sends a one-tap notification" (no
/// such notification exists) and "Manual is a button" (there was no button). A routine that
/// doesn't start by itself shows on the plan at its time and starts when you press Start.
enum RoutineWording {
    /// `Autonomy`'s cases, by raw value.
    enum Level: String { case auto, nudge, manual }

    /// The chip beside a routine's name.
    static func label(_ level: Level) -> String {
        switch level {
        case .auto: return "Auto"
        case .nudge: return "Scheduled"
        case .manual: return "Manual"
        }
    }

    /// One sentence under the routine's "when", in its editor.
    static func sentence(_ level: Level) -> String {
        switch level {
        case .auto:
            return "Starts by itself."
        case .nudge:
            return "Shows on your plan at its time and starts when you press Start, there or in Routines. An app can\u{2019}t start audio by itself in the middle of the day."
        case .manual:
            return "Starts when you press Start: in Routines, or from Plan\u{2019}s menu."
        }
    }

    /// What pressing Start plays.
    static func plays(episode: String?, music: Bool, slot: Bool) -> String? {
        if let episode { return "Plays \u{201C}\(episode)\u{201D}" }
        if music { return "Plays its music" }
        if slot { return "Plays its wake audio" }
        return nil
    }

    /// What a routine's sheet says under its actions. One with nothing set is a starter that
    /// came with the app: a new plan showed Wake, Commute, Focus and Wind down with no word of
    /// where they had come from (review of 9 Oct 2026).
    static func sheetFooter(sourceLabel: String) -> String {
        guard sourceLabel == "Not set" else { return sourceLabel }
        return "A starter routine. Edit it or switch it off in Routines."
    }

    /// What a routine with nothing to play says where Start would be.
    static let nothingToPlay = "Nothing to play yet: add a show or music to it."
}
