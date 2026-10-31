import Foundation

/// Chooses which device owns the media controls shown during a Watch workout.
enum WorkoutMediaRouting {
    enum Source: Equatable {
        case watch
        case phone
        case none
    }

    static func source(hasWatchEpisode: Bool, hasPhoneEpisode: Bool) -> Source {
        if hasWatchEpisode { return .watch }
        if hasPhoneEpisode { return .phone }
        return .none
    }

    /// A workout starts a podcast on the Watch only when nothing is playing anywhere and
    /// headphones are connected — the Watch's own speaker is never the place for one.
    /// `hasHeadphones` is only asked when the rest says yes: finding out opens the Watch's audio
    /// session.
    static func shouldAutoStartOnWatch(
        hasWatchEpisode: Bool,
        phoneIsPlaying: Bool,
        hasHeadphones: @autoclosure () -> Bool
    ) -> Bool {
        !hasWatchEpisode && !phoneIsPlaying && hasHeadphones()
    }

    /// Whether an audio route reaches something other than the Watch's own speaker — headphones,
    /// a car. Ports are `AVAudioSession.Port` raw values; `builtIn` names the Watch's own.
    static func reachesHeadphones(outputs: [String], builtIn: Set<String>) -> Bool {
        outputs.contains { !builtIn.contains($0) }
    }
}
