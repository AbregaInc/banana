import Foundation
import os

/// Everything Banana can put in front of a plan builder for one episode.
///
/// Deliberately a bag of *what is available*, not of what any one stage needs: the stages differ
/// in what they can run against (headers alone, whole bytes, this episode's transcript, earlier
/// episodes of the same show), and a first streamed listen legitimately has almost none of it.
/// A builder handed less says less; it never guesses to fill a gap.
struct SkipPlanInputs {
    var episode: Episode
    /// The whole show, so cross-episode stages (boilerplate repeated across episodes, a sponsor
    /// slate learned from earlier ones) have something to compare against.
    var podcast: Podcast
    /// The audio on disk, when this copy has been downloaded. Nil on a first streamed listen.
    var localAudioURL: URL?
    /// Size of the audio the plan will describe — the downloaded file, or the streamed
    /// response's `Content-Length`. Recorded on the plan so it can be rejected later when the
    /// bytes change.
    var audioByteCount: Int64?
    /// The host's own declared ad slots, when the response carried them.
    var declaredSlots: DeclaredAdSlots?
    /// This episode's transcript, when one already exists. Never produced on demand: transcribing
    /// ahead of a live playhead is not something this feature is allowed to cost.
    var transcript: Transcript?
}

/// The detector entry point. Given an episode and whatever Banana could put in front of it,
/// return a plan — or nil, which is the right answer far more often than a bad span is.
///
/// Main-actor by design. The stages need the library, the transcript store and earlier episodes
/// of the same show, all of which live here, and making the protocol main-actor means none of
/// that has to be copied across an isolation boundary to reach them. An implementation is
/// expected to get itself off the main actor for anything that reads bytes or scans text.
@MainActor
protocol EpisodeSkipPlanBuilding {
    func buildPlan(from inputs: SkipPlanInputs) async -> EpisodeSkipPlan?
}

/// What is installed until the detectors are wired in: no plan, ever.
///
/// The whole feature degrades to "podcasts play normally", which is exactly the behaviour that
/// existed before it and exactly what a missing detector should cost.
struct NoSkipPlanBuilder: EpisodeSkipPlanBuilding {
    func buildPlan(from inputs: SkipPlanInputs) async -> EpisodeSkipPlan? { nil }
}

/// Owns the skip-plan cache, the correction book, and the job of getting plans built.
///
/// The player asks this for a plan and is told about one arriving late; the download manager
/// hands it the ad-server headers it was already receiving and throwing away; the Watch bridge
/// asks it for a payload. Nothing else needs to know any of it exists.
@MainActor
final class SkipPlanService: ObservableObject {
    private static let log = Logger(subsystem: "com.boris.banana", category: "adskip")

    let store: SkipPlanStore

    /// Replaced at wire-up once the detector stages are available. Left as a protocol so the
    /// playback, storage, sync and UI halves of this feature could be built and shipped against
    /// a contract instead of against an implementation.
    /// Defaults to the real detector. `NoSkipPlanBuilder` stays available for tests and for
    /// turning the feature off wholesale without unpicking the wiring.
    var builder: any EpisodeSkipPlanBuilding = SkipPlanDetector()

    weak var library: PodcastLibrary?
    weak var downloads: DownloadManager?

    /// Fired on the main actor when a plan lands for an episode — including *after* playback of
    /// that episode has already begun, which is the normal case for a streamed first listen:
    /// the headers arrive a few hundred milliseconds in, well before a pre-roll ends. The player
    /// re-reads the plan and acts on it from wherever the playhead is by then.
    var onPlanReady: ((String) -> Void)?

    /// Fired when a plan should be handed to the Watch (built, or rebuilt with better inputs).
    var onPlanShareable: ((String) -> Void)?

    private var buildsInFlight: Set<String> = []
    /// Episodes probed for headers this launch, so a replay doesn't re-issue the request.
    private var probed: Set<String> = []

    /// The store is nil-defaulted rather than `= SkipPlanStore()`: a default argument expression is
    /// evaluated at the call site, which is not necessarily on the main actor, and `SkipPlanStore`
    /// is main-actor isolated. Building it inside the initialiser keeps the isolation honest.
    init(store: SkipPlanStore? = nil) {
        self.store = store ?? SkipPlanStore()
    }

    // MARK: - Reading

    var corrections: SkipCorrectionBook { store.corrections }

    /// The byte count that decides whether a stored plan still describes the audio in hand: the
    /// downloaded file's real size, or failing that whatever the host declared when the headers
    /// were captured. Nil means "unknown", and an unknown count leaves a plan valid — the check
    /// exists to catch a *known* mismatch, not to throw away plans for want of a number.
    func audioByteCount(for episodeID: String) -> Int64? {
        if let url = downloads?.localURL(for: episodeID),
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            return size
        }
        return store.declaredSlots(for: episodeID)?.byteCount
    }

    func plan(for episodeID: String) -> EpisodeSkipPlan? {
        store.plan(for: episodeID, audioByteCount: audioByteCount(for: episodeID))
    }

    /// Throw away what was known about one episode's audio. Called when a copy is replaced or
    /// deleted: a plan without the bytes it describes is not stale, it is about something else.
    func forget(episodeID: String) {
        store.forgetPlan(for: episodeID)
    }

    func retiredDetectors(forShow podcastID: UUID) -> [SkipSource] {
        store.retiredDetectors(forShow: podcastID)
    }

    // MARK: - Corrections

    func recordCorrection(for span: SkipSpan, podcastID: UUID) {
        store.recordCorrection(for: span, podcastID: podcastID)
        objectWillChange.send()   // the per-show "what has been retired" list may have grown
    }

    /// A rewind on the Watch is still a wrong skip. The Watch has no correction book of its own —
    /// keeping one there would mean merging two books across a link that is often not there — so
    /// it reports the span it rewound into and the book on this device learns from it.
    func recordWatchCorrection(episodeID: String, spanID: String) {
        guard let plan = store.record(for: episodeID)?.plan,
              let span = plan.spans.first(where: { $0.id == spanID }) else { return }
        recordCorrection(for: span, podcastID: plan.podcastID)
    }

    // MARK: - Declared ad slots

    /// Headers captured from a response that carried this episode's audio.
    ///
    /// These ride along on every download already and were being discarded. A slot the server
    /// declares is correct by construction — it is the ad server saying where it put the ad —
    /// which is a different class of fact from anything a heuristic can produce.
    func adopt(_ slots: DeclaredAdSlots, episode: Episode?, podcast: Podcast?) {
        store.store(slots)
        guard let episode, let podcast else { return }
        requestBuild(episode: episode, podcast: podcast, reason: "declared slots")
    }

    /// Capture the ad-server headers for a streamed episode.
    ///
    /// AVPlayer will not surface response headers without a resource-loader delegate, and taking
    /// one on for this is not worth what it costs everywhere else. A separate HEAD, issued
    /// alongside `replaceCurrentItem` and never blocking it, gets the same headers off the final
    /// response of the redirect chain in a few hundred milliseconds — comfortably inside a
    /// pre-roll. Nothing waits on it; the plan simply arrives while the ad is still playing.
    /// Fetch the ad-server headers ahead of playback, for an episode likely to be played next.
    ///
    /// Speculative and cheap: a HEAD, once per episode per launch. Buys the few hundred
    /// milliseconds that decide whether a streamed episode's first ad is caught or heard.
    func prefetchDeclaredSlots(episode: Episode, podcast: Podcast) {
        probeStream(episode: episode, podcast: podcast)
    }

    func probeStream(episode: Episode, podcast: Podcast, freshOnly: Bool = false) {
        // A prefetch that has gone stale is re-fetched when playback actually starts.
        if freshOnly, let existing = store.declaredSlots(for: episode.id),
           !existing.isFresh(at: Date()) {
            probed.remove(episode.id)
            store.forgetDeclaredSlots(for: episode.id)
        }
        guard !probed.contains(episode.id) else { return }
        guard store.declaredSlots(for: episode.id) == nil else { return }
        probed.insert(episode.id)
        let episodeID = episode.id
        let url = episode.audioURL
        Task { @MainActor [weak self] in
            guard let slots = await Self.probe(episodeID: episodeID, url: url) else { return }
            guard let self else { return }
            Self.log.notice("stream headers captured for \(episodeID, privacy: .public): \(slots.headers.count, privacy: .public) ad header(s)")
            self.adopt(slots, episode: episode, podcast: podcast)
        }
    }

    /// HEAD, following redirects (the headers only appear on the final response of a two-hop
    /// chain), and short-fused: a probe that has not answered before the pre-roll is over has
    /// missed its moment and must not keep a request alive behind the listener's back.
    private nonisolated static func probe(episodeID: String, url: URL) async -> DeclaredAdSlots? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode < 400 else { return nil }
        let declaredLength = http.expectedContentLength
        let byteCount: Int64? = declaredLength > 0 ? Int64(declaredLength) : nil
        let slots = DeclaredAdSlots.capture(
            episodeID: episodeID, headers: http.allHeaderFields, byteCount: byteCount)
        return slots.isEmpty && byteCount == nil ? nil : slots
    }

    // MARK: - Building

    /// Make sure a usable plan exists for an episode, building one if the inputs have improved.
    ///
    /// Called when playback starts, when a download finishes, and when a transcript lands. Cheap
    /// to call repeatedly: an already-good plan short-circuits.
    func requestBuild(episode: Episode, podcast: Podcast, reason: String) {
        guard !buildsInFlight.contains(episode.id) else { return }

        let byteCount = audioByteCount(for: episode.id)
        let localURL = downloads?.localURL(for: episode.id)
        let declared = store.declaredSlots(for: episode.id)
        let transcript = TranscriptStore.shared.has(episode.id)

        if let existing = store.record(for: episode.id),
           existing.plan.isValid(forByteCount: byteCount),
           !existing.improvedBy(transcript: transcript,
                                declaredSlots: declared != nil,
                                localAudio: localURL != nil) {
            return
        }

        buildsInFlight.insert(episode.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.buildsInFlight.remove(episode.id) }
            let inputs = SkipPlanInputs(
                episode: episode,
                podcast: podcast,
                localAudioURL: localURL,
                audioByteCount: byteCount,
                declaredSlots: declared,
                transcript: transcript
                    ? await TranscriptStore.shared.localTranscriptAsync(for: episode.id)
                    : nil)
            guard var built = await self.builder.buildPlan(from: inputs) else { return }
            // The plan is only ever as trustworthy as the bytes it was measured against, so it
            // carries them whether the builder remembered to or not.
            if built.audioByteCount == nil { built.audioByteCount = byteCount }
            if built.builtAt == nil { built.builtAt = Date() }
            self.store.store(StoredSkipPlan(
                plan: built,
                usedTranscript: inputs.transcript != nil,
                usedDeclaredSlots: inputs.declaredSlots != nil,
                usedLocalAudio: inputs.localAudioURL != nil))
            let automatic = built.automaticSpans.count
            Self.log.notice("plan built for \(episode.id, privacy: .public) (\(reason, privacy: .public)): \(built.spans.count, privacy: .public) span(s), \(automatic, privacy: .public) automatic")
            self.onPlanReady?(episode.id)
            self.onPlanShareable?(episode.id)
        }
    }

    // MARK: - Watch payload

    /// The plan as the Watch should see it.
    ///
    /// Trimmed to the spans it will actually act on, and stripped of the byte count: the Watch's
    /// copy of an episode is usually transcoded on the way over, so its file is a different size
    /// by design and a byte check there would reject every plan. Timings survive transcoding
    /// unchanged, which is the only property acting on a plan depends on. A few hundred bytes on
    /// a link that also carries multi-megabyte audio.
    func watchPayload(for episodeID: String) -> Data? {
        guard let plan = store.record(for: episodeID)?.plan else { return nil }
        var trimmed = store.corrections.applied(to: plan)
        trimmed.spans = trimmed.automaticSpans
        trimmed.audioByteCount = nil
        guard !trimmed.spans.isEmpty else { return nil }
        return try? JSONEncoder().encode(trimmed)
    }

    // MARK: - Housekeeping

    /// Forget plans and headers for episodes the library no longer carries.
    func pruneToLibrary() {
        guard let library else { return }
        let known = Set(library.podcasts.lazy.flatMap(\.episodes).map(\.id))
        guard !known.isEmpty else { return }   // an unloaded library is not an empty one
        store.prune(keeping: known)
    }
}
