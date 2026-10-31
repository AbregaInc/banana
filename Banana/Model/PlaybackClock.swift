import Foundation

/// The playhead, on its own object.
///
/// It used to live on `PlayerController` as `@Published var currentTime`, ticking once a second.
/// Nine views observe the PlayerController — but only three of them care what the playhead says;
/// the rest want to know *which episode* is loaded, which changes when you press play and not
/// otherwise. Publishing the clock from the same object dragged all nine into a re-render every
/// second: `RootView` re-evaluated, and with it the whole tab tree, `TodayView`, the timeline and
/// the weather stripe — three times a second, with the screen off, in a pocket.
///
/// On a phone with a real day in it that came to 100% CPU, and iOS kills a background audio app
/// that averages over 80%. It did. That's what "the podcast plays for a few minutes and then
/// stops" was: not the audio failing, but the process being executed for burning a core to render
/// a screen nobody was looking at.
///
/// So the fast-moving state moves out. Views that draw a progress bar observe this; views that
/// just need the episode observe the player and are left alone.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
}
