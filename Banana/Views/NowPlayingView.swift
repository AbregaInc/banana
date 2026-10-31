import SwiftUI
import AVKit

/// The full player, in three zones that never trade places:
///
/// 1. The artwork — or, in its place, Up next or the transcript. They open *inside* the player so
///    the controls stay exactly where your thumb left them.
/// 2. What's playing: date line, title, and the show in its own colour.
/// 3. The scrubber and one transport row — speed · −15 · play · +30 · sleep — then transcript,
///    output and Up next (and, on iPhone, a voice note).
///
/// The background is a wash of the artwork's colour (`ArtworkTint`), so each show looks like
/// itself. Previous/next episode moved into Up next, where you can see what they'd play.
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerController
    #if os(iOS)
    @ObservedObject private var notes = VoiceNoteStore.shared
    #endif
    @EnvironmentObject var library: PodcastLibrary
    @Environment(\.dismiss) private var dismiss

    enum Panel { case artwork, upNext, transcript, notes }
    @State private var panel: Panel = Self.initialPanel

    private static var initialPanel: Panel {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--player-upnext") { return .upNext }
        if args.contains("--player-transcript") { return .transcript }
        if args.contains("--player-notes") { return .notes }
        #endif
        return .artwork
    }
    @State private var tint: Color?

    var body: some View {

        let _ = RenderStats.note("NowPlayingView")
        VStack(spacing: DS.Space.l) {
            // The player's views, as a switch with words (`PageSwitch`). They were three icons
            // in the bottom row with nothing to say what they were or that they were a set.
            PageSwitch(label: "Showing", selection: $panel, choices: [Panel.artwork, .transcript, .notes, .upNext], title: {
                switch $0 {
                case .artwork: "Playing"
                case .transcript: "Transcript"
                case .notes: "Notes"
                case .upNext: "Up next"
                }
            }, fills: true)
            .disabled(player.currentEpisode == nil)
            .accessibilityIdentifier("player.panels")
            zoneOne
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.snappy(duration: 0.25), value: panel)

            // With a panel open its header already names the episode; the block would say it twice.
            if panel == .artwork {
                info
            }

            VStack(spacing: DS.Space.m) {
                PlaybackScrubber()
                SkipNoticeBar()
                transport
                secondaryRow
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.xl)
        .background {
            LinearGradient(colors: [(tint ?? .clear).opacity(DS.Tint.strong), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 660)
        #endif
        .presentationDragIndicator(.visible)
        .task(id: artworkURL) { tint = await ArtworkTint.color(for: artworkURL) }
        #if os(iOS)
        // Over the full player the player shows the recording screen itself — it's on top;
        // everywhere else RootView's VoiceCaptureHost does.
        .sheet(isPresented: Binding(get: { notes.isRecording }, set: { _ in })) {
            VoiceCaptureView()
        }
        #endif
    }

    // MARK: - Zone 1

    @ViewBuilder private var zoneOne: some View {
        switch panel {
        case .artwork:
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height, 360)
                Artwork(url: artworkURL, size: side)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .upNext:
            VStack(alignment: .leading, spacing: DS.Space.m) {
                panelHeader
                upNextList
            }
        case .transcript:
            VStack(alignment: .leading, spacing: DS.Space.m) {
                panelHeader
                if let episode = player.currentEpisode {
                    TranscriptView(episode: episode, embedded: true)
                }
            }
        case .notes:
            VStack(alignment: .leading, spacing: DS.Space.m) {
                panelHeader
                if let episode = player.currentEpisode {
                    EpisodeNotesPanel(episode: episode)
                }
            }
        }
    }

    /// The artwork shrunk to a row while a panel is open; tap it to go back.
    private var panelHeader: some View {
        Button { panel = .artwork } label: {
            HStack(spacing: DS.Space.m) {
                Artwork(url: artworkURL, size: 56)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    // What's playing; the switch above already says which panel this is.
                    Text(player.currentEpisode?.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text(podcastName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var upNextList: some View {
        let next = player.upNext()
        if next.isEmpty {
            ContentUnavailableView("Nothing up next", systemImage: "text.line.first.and.arrowtriangle.forward")
        } else if let podcast = player.currentPodcastID.flatMap(library.podcast) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(next) { episode in
                        Button {
                            player.play(episode, in: podcast, routineID: player.activeRoutineID)
                            panel = .artwork
                        } label: {
                            EpisodeRow(episode: episode, isCurrent: false, isPlaying: false,
                                       isCompleted: false, progress: progress(of: episode, in: podcast))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Zone 2

    private var info: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let date = player.currentEpisode?.pubDate {
                Text(EpisodeRowText.dateLine(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The title opens the episode's notes, where podcast apps keep an episode's details.
            Button { panel = panel == .notes ? .artwork : .notes } label: {
                Text(player.currentEpisode?.title ?? "")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(player.currentEpisode == nil)
            .accessibilityHint("Shows the episode notes")
            if let name = podcastName {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint ?? .secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Zone 3

    /// Speed · −15 · play · +30 · sleep. Nothing here ever moves.
    private var transport: some View {
        HStack {
            speedMenu
                .frame(width: 52)
            Spacer()
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 28))
                    .frame(width: DS.Row.minHeight, height: DS.Row.minHeight)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(DS.Palette.accent)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 28))
                    .frame(width: DS.Row.minHeight, height: DS.Row.minHeight)
                    .contentShape(Rectangle())
            }
            Spacer()
            SleepTimerMenu()
                .frame(width: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    /// Where the sound goes, and a note about this moment.
    private var secondaryRow: some View {
        HStack {
            Spacer()
            #if os(iOS)
            AirPlayButton()
                .frame(width: 44, height: 44)
            Spacer()
            Button { notes.beginCapture(kind: .podcastCapture) } label: {
                Image(systemName: "mic").font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(player.currentEpisode == nil)
            .accessibilityLabel("Record a note")
            Spacer()
            #else
            AirPlayButton()
                .frame(width: 44, height: 44)
            Spacer()
            Button {
                MacNavigator.shared.section = .notes
                dismiss()
            } label: {
                Image(systemName: "quote.bubble.fill").font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Notes")
            Spacer()
            #endif
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                ForEach(PlayerController.speedOptions, id: \.self) { rate in
                    Text(speedLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(speedLabel(player.speed))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Speed \(speedLabel(player.speed))")
    }

    private func progress(of episode: Episode, in podcast: Podcast) -> Double? {
        guard let position = podcast.positions[episode.id], let duration = episode.duration, duration > 0 else { return nil }
        return position / duration
    }

    private var artworkURL: URL? {
        guard let pid = player.currentPodcastID else { return nil }
        return library.podcast(pid)?.artworkURL
    }

    private var podcastName: String? {
        guard let pid = player.currentPodcastID else { return nil }
        return library.podcast(pid)?.title
    }

    private func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(String(format: "%g", rate))×"
    }
}

#if os(iOS)
/// The system's output picker (AirPlay, Bluetooth, the phone's speaker).
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        view.activeTintColor = UIColor(DS.Palette.accent)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#else
/// The Mac's output picker (AirPlay speakers, headphones).
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

/// The draggable scrubber + elapsed/remaining time labels — the only part of the full player
/// that needs the 1 Hz (up to ~3 Hz at high playback speed) clock tick, isolated so the tick
/// re-renders this view alone, not the whole sheet. Mirrors `NowPlayingBar`'s `ClockTimeLabel`.
private struct PlaybackScrubber: View {
    @EnvironmentObject var clock: PlaybackClock
    @EnvironmentObject var player: PlayerController

    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: $scrubValue, in: 0...max(duration, 1)) { editing in
                if editing {
                    scrubbing = true
                } else {
                    player.seek(to: scrubValue)
                    scrubbing = false
                }
            }
            .tint(DS.Palette.accent)
            .onAppear { scrubValue = clock.time }
            .onChange(of: clock.time) { _, t in if !scrubbing { scrubValue = t } }

            HStack {
                Text(hhmm(displayTime))
                Spacer()
                Text("-" + hhmm(max(0, duration - displayTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var displayTime: Double { scrubbing ? scrubValue : clock.time }
    /// The clock reads 0 until the item has loaded; the feed's length stands in until then.
    private var duration: Double {
        clock.duration > 0 ? clock.duration : (player.currentEpisode?.duration ?? 0)
    }

    private func hhmm(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The speed/sleep control row's sleep-timer button. Keeps a (declared-but-unread-in-body)
/// `@EnvironmentObject var clock` purely to retain the per-second re-evaluation that makes the
/// "N min" countdown caption tick — the same pattern already shipped for
/// `NowPlayingBar`'s `SleepCountdownLabel` (NowPlayingBar.swift:170-179).
private struct SleepTimerMenu: View {
    @EnvironmentObject var clock: PlaybackClock
    @EnvironmentObject var player: PlayerController

    var body: some View {
        Menu {
            // "When episode ends" is how people actually use a sleep timer, so it comes first.
            Button("When episode ends") {
                let left = max(60, clock.duration - clock.time)
                player.startSleepTimer(minutes: Int((left / 60).rounded(.up)))
            }
            ForEach([60, 45, 30, 15, 5], id: \.self) { minutes in
                Button("\(minutes) minutes") { player.startSleepTimer(minutes: minutes) }
            }
            if player.sleepTimerEnd != nil {
                Divider()
                Button("Turn off timer", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: player.sleepTimerEnd != nil ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 20))
                if player.sleepTimerEnd != nil {
                    Text(sleepTimerLabel)
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(player.sleepTimerEnd != nil ? DS.Palette.accent : .primary)
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(player.sleepTimerEnd != nil ? "Sleep timer, \(sleepTimerLabel)" : "Sleep timer")
    }

    private var sleepTimerLabel: String {
        if let remaining = player.sleepTimerRemaining { return "\(Int(ceil(remaining / 60))) min" }
        return "Sleep"
    }
}

/// The playing episode's show notes, in the player. Built off the main thread with `ShowNotes`
/// (the WebKit importer froze the Episode info sheet); links open in the browser.
private struct EpisodeNotesPanel: View {
    let episode: Episode
    @State private var notes: AttributedString?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            Group {
                if let notes {
                    Text(notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .tint(DS.Palette.accent)
                } else if loaded {
                    Text("This episode has no notes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: episode.id) {
            let html = episode.summary ?? ""
            notes = await Task.detached(priority: .userInitiated) { ShowNotes.attributed(html) }.value
            loaded = true
        }
    }
}

