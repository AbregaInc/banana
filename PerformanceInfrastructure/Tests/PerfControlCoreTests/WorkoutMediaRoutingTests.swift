import Testing
@testable import PerformanceContracts

@Suite struct WorkoutMediaRoutingTests {
    @Test func activePhonePlaybackOwnsAWorkoutWithNoLocalEpisode() {
        #expect(
            WorkoutMediaRouting.source(
                hasWatchEpisode: false,
                hasPhoneEpisode: true) == .phone)
        #expect(
            WorkoutMediaRouting.shouldAutoStartOnWatch(
                hasWatchEpisode: false,
                phoneIsPlaying: true,
                hasHeadphones: true) == false)
    }

    @Test func existingWatchPlaybackRemainsTheLocalSource() {
        #expect(
            WorkoutMediaRouting.source(
                hasWatchEpisode: true,
                hasPhoneEpisode: true) == .watch)
        #expect(
            WorkoutMediaRouting.shouldAutoStartOnWatch(
                hasWatchEpisode: true,
                phoneIsPlaying: false,
                hasHeadphones: true) == false)
    }

    @Test func silentWorkoutMayAutoStartADownloadedWatchEpisode() {
        #expect(
            WorkoutMediaRouting.source(
                hasWatchEpisode: false,
                hasPhoneEpisode: false) == .none)
        #expect(
            WorkoutMediaRouting.shouldAutoStartOnWatch(
                hasWatchEpisode: false,
                phoneIsPlaying: false,
                hasHeadphones: true))
    }

    /// The Watch's speaker is never the place for a podcast: no headphones, no auto-start.
    @Test func noHeadphonesMeansASilentWorkout() {
        #expect(
            WorkoutMediaRouting.shouldAutoStartOnWatch(
                hasWatchEpisode: false,
                phoneIsPlaying: false,
                hasHeadphones: false) == false)
    }

    /// Finding out about headphones opens the Watch's audio session, so it's only asked when
    /// the workout would otherwise start something.
    @Test func headphonesAreOnlyCheckedWhenAudioWouldStart() {
        var asked = false
        func check() -> Bool { asked = true; return true }
        _ = WorkoutMediaRouting.shouldAutoStartOnWatch(
            hasWatchEpisode: false, phoneIsPlaying: true, hasHeadphones: check())
        #expect(asked == false)
        _ = WorkoutMediaRouting.shouldAutoStartOnWatch(
            hasWatchEpisode: false, phoneIsPlaying: false, hasHeadphones: check())
        #expect(asked)
    }

    @Test func onlyTheWatchSpeakerIsNotHeadphones() {
        let builtIn: Set<String> = ["Speaker", "Receiver"]
        #expect(WorkoutMediaRouting.reachesHeadphones(outputs: ["Speaker"], builtIn: builtIn) == false)
        #expect(WorkoutMediaRouting.reachesHeadphones(outputs: [], builtIn: builtIn) == false)
        #expect(WorkoutMediaRouting.reachesHeadphones(outputs: ["BluetoothA2DPOutput"], builtIn: builtIn))
        #expect(WorkoutMediaRouting.reachesHeadphones(outputs: ["BluetoothLE"], builtIn: builtIn))
    }
}
