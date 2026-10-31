import SwiftUI

/// Follow-along transcript synced to playback ("karaoke"). Words are grouped into short
/// phrases for smooth scrolling; the phrase under the playhead is highlighted, with the
/// exact active word emphasised inside it. Tapping a phrase seeks there.
struct TranscriptView: View {
    let episode: Episode
    /// Shown inside the player (in the artwork's place) rather than as its own sheet: no
    /// navigation bar, no Done, a reading size that leaves the controls in view.
    var embedded = false
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var clock: PlaybackClock
    /// Observe the shared coordinator directly. Caching its status in @State meant the screen
    /// froze at whatever load() set — 0% — while the background task did the actual work.
    @ObservedObject private var coordinator = TranscriptCoordinator.shared
    @ObservedObject private var visibility = AppVisibility.shared
    @Environment(\.dismiss) private var dismiss

    @State private var transcript: Transcript?
    @State private var phrases: [Phrase] = []
    /// Who is who, when the transcript tells speakers apart (`Transcript.speakerLabels`).
    @State private var speakerLabels: [Int: String] = [:]
    @State private var credits: EpisodeCredits?
    /// The karaoke playhead, sampled at ~10 Hz from the player (not the 1 Hz clock) so the highlight
    /// follows each word instead of jumping ~5 at a time. This view is only on-screen in the
    /// foreground, so the fast tick can't re-run in the background (where the 1 Hz clock matters).
    @State private var playhead: Double = 0

    private var status: TranscriptCoordinator.Status { coordinator.status(for: episode.id) }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Transcript")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 620)
                #endif
            }
        }
        .task { playhead = player.preciseTime(); await load() }
        .task(id: "\(visibility.isActive)-\(player.isPlaying)") {
            guard visibility.isActive, player.isPlaying else { return }
            while !Task.isCancelled {
                playhead = player.preciseTime()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .onChange(of: clock.time) { _, newValue in
            if !player.isPlaying { playhead = newValue }
        }
        // The background task may finish while this screen is open — pick the transcript up then.
        .onChange(of: coordinator.status(for: episode.id)) { _, new in
            if case .ready = new, transcript == nil { Task { await showTranscript() } }
        }
    }

    @ViewBuilder private var content: some View {
        if let transcript, !phrases.isEmpty {
            karaoke(transcript)
        } else {
            placeholder
        }
    }

    // MARK: - Karaoke

    private func karaoke(_ transcript: Transcript) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    if let credits { creditsHeader(credits) }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(phrases) { phrase in
                            // Whose turn it is, over the first line of it. The transcript carried
                            // this (a publisher's names) and nothing showed it.
                            if phrase.startsTurn, let name = phrase.speaker.flatMap({ speakerLabels[$0] }) {
                                Text(name.uppercased())
                                    .font(DS.Typeface.eyebrow)
                                    .tracking(DS.Typeface.eyebrowTracking)
                                    .foregroundStyle(DS.Palette.accent)
                                    .padding(.top, DS.Space.s)
                                    .padding(.bottom, -DS.Space.s)
                                    .opacity(phrase.contains(activeWordIndex) ? 1 : 0.6)
                                    .accessibilityIdentifier("transcript.speaker")
                            }
                            Text(attributed(phrase, activeWord: activeWordIndex))
                                .font(embedded ? .body : .title3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // The current phrase at full strength, the rest well back.
                                .opacity(phrase.contains(activeWordIndex) ? 1 : 0.4)
                                .id(phrase.id)
                                .background(activeProbe(phrase, viewportHeight: outer.size.height))
                                .onTapGesture { player.seek(to: max(0, phrase.start - 0.15)) }
                        }
                    }
                    .padding()
                }
            }
            .onChange(of: activePhraseID) { _, id in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--transcript-demo") {
                    PlaybackDiagnostics.shared.log("transcript: phrase→\(id.map(String.init) ?? "nil")",
                                                   "clock=\(String(format: "%.1f", clock.time)) word=\(activeWordIndex.map(String.init) ?? "nil")")
                }
                #endif
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
            // Snap to the current position the moment the transcript appears. `onChange` only fires
            // on a *change*, so without this, opening the transcript mid-episode left it parked at
            // the very top — showing phrase 0 while you're an hour in — until the next phrase
            // boundary happened to tick over (several seconds of real speech later). That gap read
            // as "the transcript doesn't follow the audio at all". Jump straight there, no animation.
            .onChange(of: phrasesReady) { _, ready in
                guard ready, let id = activePhraseID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onAppear {
                guard let id = activePhraseID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// Flips true once the transcript's phrases exist, so the initial scroll can fire even when the
    /// transcript finishes loading *after* the view has already appeared.
    private var phrasesReady: Bool { !phrases.isEmpty }

    /// DEBUG-only: report where the ACTIVE phrase actually sits in the viewport, so a device with no
    /// screenshot can still say whether the scroll works. If scroll-to-center is working the active
    /// phrase's midY stays near the middle; if it's broken, midY drifts down and off-screen.
    @ViewBuilder private func activeProbe(_ phrase: Phrase, viewportHeight: CGFloat) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--transcript-demo"), phrase.contains(activeWordIndex) {
            GeometryReader { g in
                Color.clear.onAppear {}.onChange(of: g.frame(in: .scrollView).midY) { _, y in
                    let pct = viewportHeight > 0 ? Int(y / viewportHeight * 100) : -1
                    PlaybackDiagnostics.shared.log("transcript: active phrase midY=\(Int(y))",
                                                   "viewport=\(Int(viewportHeight)) (\(pct)% down — 50% is centered)")
                }
            }
        }
        #endif
    }

    /// Build a phrase's text, emphasising the active word when it's the live phrase.
    private func attributed(_ phrase: Phrase, activeWord: Int?) -> AttributedString {
        var out = AttributedString()
        for i in phrase.range {
            var run = AttributedString(transcript?.words[i].text ?? "")
            if i == activeWord {
                run.foregroundColor = DS.Palette.accent
                run.font = .title3.weight(.bold)
            }
            out += run
            if i != phrase.range.upperBound - 1 { out += AttributedString(" ") }
        }
        return out
    }

    private func creditsHeader(_ c: EpisodeCredits) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let host = c.host { creditRow("Host", host) }
            if !c.guests.isEmpty { creditRow("Guests", c.guests.joined(separator: ", ")) }
            if !c.narrators.isEmpty {
                creditRow("Narrators", c.narrators.map { narrator in
                    narrator.role == .primary ? "\(narrator.name) (primary)" : narrator.name
                }.joined(separator: ", "))
            }
            ForEach(c.others, id: \.self) { creditRow("", $0) }
        }
        .font(.footnote)
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .padding([.horizontal, .top])
    }

    private func creditRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !label.isEmpty {
                Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            }
            Text(value)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Placeholder / status

    private var placeholder: some View {
        VStack(spacing: 16) {
            switch status {
            case .preparing:
                ProgressView()
                Text("Downloading the speech model…").font(.headline)
                Text("One-off, a few hundred megabytes. It'll be instant next time.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            case .working(let p):
                ProgressView(value: p) { Text("Transcribing on device…") }
                    .padding(.horizontal, 40)
                if let eta = coordinator.eta(for: episode.id), eta > 5 {
                    Text("\(Int(p * 100))% · about \(Int((eta / 60).rounded())) min left")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                }
                Text("Keeping the screen on so this can finish — leaving the app pauses it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            case .unavailable:
                Image(systemName: "text.badge.xmark").font(.largeTitle).foregroundStyle(.secondary)
                Text("No transcript available").font(.headline)
            case .deferredForPlayback:
                Image(systemName: "moon.zzz").font(.largeTitle).foregroundStyle(.secondary)
                Text("Queued until playback stops").font(.headline)
                Text("Generating a transcript while audio is playing uses substantial power. Pause playback and try again, or Banana will process it on the charger.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Try now") { Task { await load(force: true) } }
                    .buttonStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Couldn't build a transcript").font(.headline)
                Button("Try again") { Task { await load(force: true) } }
                    .buttonStyle(.secondary)
            default:
                ProgressView("Preparing transcript…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private var activeWordIndex: Int? { transcript?.index(at: playhead) }
    private var activePhraseID: Phrase.ID? {
        guard let i = activeWordIndex else { return nil }
        var low = 0
        var high = phrases.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let phrase = phrases[mid]
            if i < phrase.range.lowerBound {
                high = mid - 1
            } else if i >= phrase.range.upperBound {
                low = mid + 1
            } else {
                return phrase.id
            }
        }
        return nil
    }

    private func load(force: Bool = false) async {
        // Long episodes go to a continued-processing task: it starts now and keeps running when you
        // leave the app, with progress in the system UI. Submission must come from the foreground in
        // response to a person's action — opening this screen is one. The status shown here comes
        // from the shared coordinator, so it tracks that task's real progress.
        #if os(iOS)
        if #available(iOS 26, *), !force,
           TranscriptStore.shared.transcript(for: episode.id) == nil,
           episode.availableTranscriptSources.isEmpty,
           !player.isPlaying,
           (episode.duration ?? 0) > 600,
           ContinuedTranscription.start(episode) {
            return
        }
        #endif
        // On the Mac there's nothing to hand off TO: the app isn't about to be suspended out from
        // under the work, so it just runs.
        let produced = await coordinator.ensureTranscript(for: episode, force: force)
        // `produced` is already the exact transcript `showTranscript()` would otherwise re-read
        // from disk (ensureTranscript never returns a value that wasn't just persisted — see
        // TranscriptStore.saveAsync). Under `force`, though, saveAsync's quality-rank guard can
        // defer to a higher-quality transcript already on disk, so the forced attempt's return
        // value could diverge from what's actually current — keep the disk re-read there.
        await showTranscript(prefetched: force ? nil : produced)
    }

    private func showTranscript(prefetched: Transcript? = nil) async {
        let result: Transcript?
        if let prefetched {
            result = prefetched
        } else {
            result = await TranscriptStore.shared.transcriptAsync(for: episode.id)
        }
        transcript = result
        let words = result?.words ?? []
        let prepared = await Task.detached(priority: .userInitiated) {
            (phrases: Phrase.segment(words), labels: result?.speakerLabels ?? [:])
        }.value
        speakerLabels = prepared.labels
        phrases = prepared.phrases
        credits = await coordinator.credits(for: episode)
    }
}

/// Lets the view hold the @MainActor singleton coordinator as a StateObject without
/// making the coordinator itself the view's own object.
@MainActor
final class TranscriptCoordinatorBox: ObservableObject {
    let value = TranscriptCoordinator.shared
}
