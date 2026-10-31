import Foundation

/// Starting a routine by hand: play what it plays — the next episode from its shows, or its
/// Apple Music pick, or the audio of its wake slot — with its sleep timer.
///
/// The only button for this was on the retired Today screen, so a routine set to "Manual (a
/// button)" had no button.
@MainActor
enum RoutineStart {
    /// What starting it would play.
    enum Source: Equatable {
        case episode(String)
        case music
        case slot
        case nothing
    }

    static func source(of routine: Routine, library: PodcastLibrary) -> Source {
        if let next = library.nextInPool(routine.podcastIDs) { return .episode(next.episode.title) }
        if routine.musicItem != nil { return .music }
        // A slot counts only when something is set for it: a button that plays nothing is worse
        // than no button.
        guard let slot = routine.slot, WakeCoordinator.shared.wake.source(for: slot) != nil else { return .nothing }
        return .slot
    }

    /// What pressing Start plays, in words; nil when there's nothing to play.
    static func summary(of routine: Routine, library: PodcastLibrary) -> String? {
        switch source(of: routine, library: library) {
        case .episode(let title): return RoutineWording.plays(episode: title, music: false, slot: false)
        case .music: return RoutineWording.plays(episode: nil, music: true, slot: false)
        case .slot: return RoutineWording.plays(episode: nil, music: false, slot: true)
        case .nothing: return nil
        }
    }

    static func start(_ routine: Routine, library: PodcastLibrary, player: PlayerController, music: MusicController) {
        Telemetry.shared.record(.feature(.routineStarted))
        if let next = library.nextInPool(routine.podcastIDs) {
            player.play(next.episode, in: next.podcast, routineID: routine.id)
            if let minutes = routine.sleepTimerMinutes { player.startSleepTimer(minutes: minutes) }
        } else if let item = routine.musicItem {
            Task { await music.playWake(item) }
        } else if let slot = routine.slot {
            Task {
                await WakeCoordinator.shared.play(slot: slot, reason: "cue:\(routine.name)",
                                                  sleepTimerMinutes: routine.sleepTimerMinutes,
                                                  routineID: routine.id)
            }
        }
    }
}
