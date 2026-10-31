import Foundation
import os

/// The real detector: runs each measured stage over whatever inputs this episode actually has,
/// and hands the findings to `SkipPlanBuilder` to merge.
///
/// The stages are deliberately independent and deliberately unequal in what they need. Two of them
/// work on bytes alone, which is why a streamed first listen can still skip a stitched ad block
/// before the listener hears it. The other two need this episode's transcript and earlier episodes
/// of the same show to compare against, so they contribute nothing on a first listen and everything
/// on the second. Nothing here transcribes: producing a transcript ahead of a live playhead is a
/// cost this feature is not allowed to impose, and the overnight on-charger task already exists.
@MainActor
final class SkipPlanDetector: EpisodeSkipPlanBuilding {

    private let log = Logger(subsystem: "com.boris.banana", category: "adskip")

    /// Learned per-show state: wording that recurs across episodes, and the sponsors this show
    /// reads for. Both are built from transcripts of *earlier* episodes, so they improve as the
    /// library fills and are useless on a show's first episode. That is the intended shape.
    private var boilerplate: PodcastBoilerplateLibrary
    private var sponsors: PodcastSponsorLibrary
    private let directory: URL
    private let transcripts: TranscriptStore

    init(directory: URL = AppSupport.directory, transcripts: TranscriptStore = .shared) {
        self.directory = directory
        self.transcripts = transcripts
        self.boilerplate = PodcastBoilerplateLibrary.load(from: directory)
        self.sponsors = PodcastSponsorLibrary.load(from: directory)
    }

    func buildPlan(from inputs: SkipPlanInputs) async -> EpisodeSkipPlan? {
        let episodeID = inputs.episode.id
        var findings: [SkipSpan] = []

        // Stage 0 — the host's own declaration. Correct by construction and free: these headers
        // arrive on every download and on a HEAD issued alongside a stream.
        if let slots = inputs.declaredSlots, !slots.isEmpty {
            let spans = PodcastAdServerHeaders.spans(fromHeaders: slots.headers)
            if !spans.isEmpty { log.info("[adskip] \(episodeID, privacy: .public): \(spans.count) declared") }
            findings += spans
        }

        // Stage 1 — encoder seams, from the bytes. Only the prefix is read: every seam measured
        // sat inside the first 82 seconds, and reading a whole episode to find them would cost
        // hundreds of megabytes of I/O for nothing.
        if let url = inputs.localAudioURL, let prefix = Self.readPrefix(of: url) {
            let spans = PodcastAudioSeams.spans(in: prefix)
            if !spans.isEmpty { log.info("[adskip] \(episodeID, privacy: .public): \(spans.count) seam") }
            findings += spans
        }

        // Stages 2 and 3 need this episode's words and earlier episodes to compare against.
        if let words = inputs.transcript?.words.map({ SpokenWord(text: $0.text, start: $0.start, end: $0.end) }),
           !words.isEmpty {
            learnFromEarlierEpisodes(of: inputs.podcast, excluding: episodeID)

            let corpus = boilerplate[inputs.podcast.id]
            findings += corpus.openingSpans(in: words, episodeID: episodeID)
            findings += sponsors[inputs.podcast.id].spans(in: words, episodeID: episodeID)

            // This episode joins the corpus only after it has been used, so its own wording can
            // never be the thing that "corroborates" a cut in itself.
            boilerplate.learn(podcastID: inputs.podcast.id, episodeID: episodeID, words: words)
            sponsors.learn(podcastID: inputs.podcast.id, episodeID: episodeID, words: words)
            persistLearnedState()
        }

        guard !findings.isEmpty else { return nil }

        return SkipPlanBuilder.build(episodeID: episodeID,
                                     podcastID: inputs.podcast.id,
                                     findings: findings,
                                     audioDuration: inputs.episode.duration,
                                     audioByteCount: inputs.audioByteCount,
                                     builtAt: Date(),
                                     corrections: WakeCoordinator.shared.skipPlans.corrections)
    }

    // MARK: - Inputs

    /// How much of the file the seam stage needs in hand.
    ///
    /// Sized from the file's own bitrate rather than a constant: bitrate is fixed within one MP3
    /// but varies between episodes of the same show — 128 and 320 kbit/s both measured on one feed
    /// — so a prefix sized for the slower one would truncate the faster one's seams away. 4 MB is
    /// the fallback when the bitrate cannot be read, which covers the worst case observed.
    private static func readPrefix(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return nil }

        let scan = PodcastAudioSeams.scan(head)
        let wanted = PodcastAudioSeams.minimumPrefixByteCount(for: scan) ?? (4 * 1024 * 1024)
        guard wanted > head.count else { return head }

        try? handle.seek(toOffset: 0)
        return try? handle.read(upToCount: wanted)
    }

    /// Feed the cross-episode stages the transcripts already on disk for this show.
    ///
    /// Only transcripts that exist are used. Nothing is transcribed here — that is the overnight
    /// task's job, and doing it inline would put a multi-minute CPU burn behind a play button.
    private func learnFromEarlierEpisodes(of podcast: Podcast, excluding episodeID: String) {
        for episode in podcast.episodes where episode.id != episodeID {
            guard let transcript = transcripts.transcript(for: episode.id), !transcript.words.isEmpty else { continue }
            let words = transcript.words.map { SpokenWord(text: $0.text, start: $0.start, end: $0.end) }
            boilerplate.learn(podcastID: podcast.id, episodeID: episode.id, words: words)
            sponsors.learn(podcastID: podcast.id, episodeID: episode.id, words: words)
        }
    }

    private func persistLearnedState() {
        do {
            try boilerplate.save(to: directory)
            try sponsors.save(to: directory)
        } catch {
            // Learned state is a cache of what transcripts already say, so a failed write costs a
            // rebuild rather than anything the listener would notice. It must not fail a plan.
            log.error("[adskip] could not persist learned state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
