import SwiftUI

/// Compact playback bar shown in the tab view's bottom accessory slot. Tapping
/// the title area opens the full player; transport buttons use full 44pt targets.
///
/// Deliberately does NOT observe `PlaybackClock`: the clock ticks once a second for the whole
/// session, and the bar only ever shows a time in one rare fallback. The two labels that need
/// the tick are their own child views, so the tick re-renders a Text — not the whole accessory.
struct NowPlayingBar: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: PodcastLibrary
    #if os(iOS)
    @ObservedObject private var notes = VoiceNoteStore.shared
    #endif
    var onExpand: () -> Void = {}

    var body: some View {

        let _ = RenderStats.note("NowPlayingBar")
        Group {
            if let episode = player.currentEpisode {
                HStack(spacing: 8) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        Artwork(url: artworkURL, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            subtitleView
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                #if os(iOS)
                Button { notes.beginCapture(kind: .podcastCapture) } label: {
                    Image(systemName: notes.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundStyle(notes.isRecording ? DS.Palette.danger : DS.Palette.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(notes.isRecording ? "Stop note" : "Capture this moment")
                #else
                sleepTimerMenu
                #endif

                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                }
                .buttonStyle(.plain)
                .tint(.primary)
                .padding(.leading, 12)
                .padding(.trailing, 4)
            }
        }
        // The recording screen is shown by RootView's VoiceCaptureHost, not here: this bar and
        // Notes both presenting it made them fight over the one sheet.
    }

    /// One-tap sleep timer, reachable from wherever playback was started.
    private var sleepTimerMenu: some View {
        Menu {
            if player.sleepTimerEnd != nil {
                Button("Cancel sleep timer", role: .destructive) { player.cancelSleepTimer() }
                Divider()
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("Sleep in \(minutes) min") { player.startSleepTimer(minutes: minutes) }
            }
        } label: {
            Image(systemName: player.sleepTimerEnd != nil ? "moon.zzz.fill" : "moon.zzz")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .tint(player.sleepTimerEnd != nil ? DS.Palette.accent : .primary)
    }

    @ViewBuilder private var subtitleView: some View {
        if player.sleepTimerEnd != nil {
            SleepCountdownLabel().foregroundStyle(DS.Palette.accent)
        } else if let name = podcastName {
            Text(name).foregroundStyle(.secondary)
        } else {
            ClockTimeLabel().foregroundStyle(.secondary)
        }
    }

    private var artworkURL: URL? {
        guard let pid = player.currentPodcastID else { return nil }
        return library.podcast(pid)?.artworkURL
    }

    private var podcastName: String? {
        guard let pid = player.currentPodcastID else { return nil }
        return library.podcast(pid)?.title
    }
}

/// The elapsed/total fallback label — the only part of the bar that needs the 1 Hz tick.
private struct ClockTimeLabel: View {
    @EnvironmentObject var clock: PlaybackClock

    var body: some View {
        Text("\(hhmm(clock.time)) / \(hhmm(clock.duration))")
    }

    private func hhmm(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Accessory bar for an Apple Music wake. The music plays in the system Music app (not our
/// AVPlayer), so the podcast bar can't represent it — this is the in-app stop surface.
struct MusicWakeBar: View {
    @EnvironmentObject var music: MusicController

    var body: some View {
        if let item = music.wakePlaying {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(item.subtitle ?? "Wake music").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { music.stopWake() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .padding(.leading, 12)
            .padding(.trailing, 4)
        }
    }
}

/// The sleep-timer countdown. Observes the clock so the minutes tick down while playing —
/// isolated here so the tick re-renders this Text alone, not the bar.
private struct SleepCountdownLabel: View {
    @EnvironmentObject var clock: PlaybackClock
    @EnvironmentObject var player: PlayerController

    var body: some View {
        if let remaining = player.sleepTimerRemaining {
            Text("Sleep in \(Int(ceil(remaining / 60))) min")
        }
    }
}
