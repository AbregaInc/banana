#if DEBUG && os(iOS)
import SwiftUI

/// `--transcript-demo <audio-path>` — seeds a synthetic transcript keyed to a short local audio
/// file, plays it, and shows the REAL TranscriptView. Lets the karaoke scroll/highlight be watched
/// (and journalled) in real time on a device, instead of waiting for a 4½-hour episode.
struct TranscriptDemoView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var downloads: DownloadManager

    private static let episodeID = "transcript-demo-episode"

    @State private var showSheet = false

    var body: some View {
        Color(.systemBackground)
            .task { start(); try? await Task.sleep(for: .seconds(1)); showSheet = true }
            // Exactly the real path: the transcript lives inside a .sheet (NowPlayingView presents
            // it the same way). If the sheet drops the PlaybackClock environment object, sync breaks
            // here but not in a direct-child test — which is the difference worth checking.
            .sheet(isPresented: $showSheet) { TranscriptView(episode: demoEpisode) }
    }

    private var demoEpisode: Episode {
        Episode(id: Self.episodeID, title: "Transcript Demo",
                audioURL: URL(string: "https://example.com/demo.m4a")!, pubDate: Date(), duration: 1049)
    }

    private func start() {
        let args = ProcessInfo.processInfo.arguments
        let flag = args.firstIndex(of: "--transcript-demo") ?? args.firstIndex(of: "--voicenote-demo")
        guard let i = flag, i + 1 < args.count else { return }
        // A bare name resolves inside the app's own Documents (where the test file was pushed);
        // an absolute path is used as-is.
        let raw = args[i + 1]
        let audio: URL = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent((raw as NSString).lastPathComponent)
        PlaybackDiagnostics.shared.log("transcript-demo: audio",
                                       "\(audio.path) exists=\(FileManager.default.fileExists(atPath: audio.path))")

        // ~40 words/sec over the 1049s file → ~42,000 words → ~3,500 phrases, matching the real
        // 44k-word episode. The point isn't realistic speech density; it's a LazyVStack thousands of
        // rows long so the active phrase can be DEEP in it — which is where scrollTo tends to fail.
        let rate = 2.7   // words/sec — real speech, so a phrase lasts ~4–5s (the gap seen on device)
        let count = Int(1049 * rate)
        // Whole sentences, cycled at SENTENCE boundaries.
        //
        // This used to loop a 27-word fragment and append a full stop every twelfth word wherever
        // it happened to land, so the transcript read as spliced nonsense — "giving it enough.
        // room. Banana keeps the plan, routines, movement, and listening history together so."
        // Fine for the original purpose, which was a LazyVStack thousands of rows deep to prove
        // scrollTo reaches a phrase buried in it; not fine on the App Store page, where the same
        // text sits under "Stay with every word" and reads as a broken transcription engine.
        //
        // Density is unchanged, so the scroll stress test this fixture exists for still holds.
        let sentences = [
            "The thing people underestimate is how much of this was decided before anyone wrote a line of code.",
            "You had a team that had shipped together twice already, so they skipped the arguments most groups spend a year having.",
            "And that turns out to matter more than the technology choice, which is the part everyone wants to talk about.",
            "By the time the first version went out, the interesting decisions were eighteen months behind them.",
            "What shipped was almost boring, and that was the point.",
            "Everything surprising had already happened in the room where they decided what not to build.",
        ].map { $0.split(separator: " ").map(String.init) }

        // `--transcript-speakers`: two voices taking turns every other sentence, one named by the
        // publisher and one not, to look at the speaker names. Without it the fixture is as it was.
        let twoVoices = ProcessInfo.processInfo.arguments.contains("--transcript-speakers")
        var words: [TranscriptWord] = []
        var n = 0
        var s = 0
        while n < count {
            let sentence = sentences[s % sentences.count]
            for (i, word) in sentence.enumerated() where n < count {
                let t = Double(n) / rate
                // The word already carries its own punctuation; only the final one gets the stop.
                let token = (i == sentence.count - 1) ? word : word
                words.append(TranscriptWord(text: token, start: t, end: t + 0.3,
                                            speaker: twoVoices ? (s / 2) % 2 : nil))
                n += 1
            }
            s += 1
        }
        TranscriptStore.shared.save(Transcript(episodeID: Self.episodeID, source: .onDevice, words: words,
                                               speakerNames: twoVoices ? [0: "Maya Chen"] : [:]))

        _ = downloads.debugRegisterDownload(episodeID: Self.episodeID, file: audio)

        var podcast = Podcast(feedURL: URL(string: "https://example.com/feed")!, title: "Demo Feed")
        podcast.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000DE")!
        podcast.episodes = [demoEpisode]
        player.play(demoEpisode, in: podcast)

        // `--voicenote-demo`: exercise the whole capture pipeline headlessly — snapshot context
        // (episode + timestamp + transcript excerpt), pause, record ~4s, stop, save, resume, write
        // the Reminder. Verifies everything but the on-device transcription of the note (sim can't).
        if ProcessInfo.processInfo.arguments.contains("--voicenote-demo") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                VoiceNoteStore.shared.player = player
                player.setPlaying(true, reason: "voicenote-demo: ensure playing")   // so resume is testable
                try? await Task.sleep(for: .seconds(1))
                let wasPlaying = player.isPlaying
                VoiceNoteStore.shared.beginCapture(kind: .podcastCapture)
                PlaybackDiagnostics.shared.log("voicenote-demo: wasPlaying before capture", "\(wasPlaying), duringCapture=\(player.isPlaying)")
                PlaybackDiagnostics.shared.log("voicenote-demo: began capture", "playerPlaying=\(player.isPlaying)")
                try? await Task.sleep(for: .seconds(4))
                VoiceNoteStore.shared.finishCapture()
                try? await Task.sleep(for: .seconds(1))
                let n = VoiceNoteStore.shared.notes.first
                PlaybackDiagnostics.shared.log("voicenote-demo: finished",
                    "notes=\(VoiceNoteStore.shared.notes.count) resumed=\(player.isPlaying) ctx=\(n?.context?.anchorLine ?? "nil") reminder=\(n?.reminderID ?? "nil")")
            }
        }
        // Jump deep in, then PAUSE. With the clock frozen, onChange can't fire — so if the active
        // phrase ends up centered when the transcript opens, it's the ON-APPEAR scroll doing it.
        // That isolates exactly the fix: does opening the transcript mid-episode snap to position?
        player.seek(to: 520)
        player.setPlaying(false, reason: "demo: isolate initial scroll")
        PlaybackDiagnostics.shared.log("transcript-demo: seeded \(words.count) words, PAUSED @520s", "")
    }
}
#endif
