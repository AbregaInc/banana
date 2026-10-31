import Foundation

/// Automatic skipping of podcast ads, network promos and show openings.
///
/// The governing rule for everything in this file is that a *missed* ad is acceptable and a
/// *wrong* skip is not. A missed ad leaves the listener exactly where they were before Banana
/// existed. A wrong skip deletes content they opened the app to hear, and it is the kind of
/// failure that makes someone switch the whole feature off. So every detector here either
/// produces a span it can defend or produces nothing, and where two detectors disagree the
/// plan abstains rather than picking a winner.

/// What a span of audio is, as opposed to how it was found.
enum SkipKind: String, Codable, Sendable, CaseIterable {
    /// A slot the ad server stitched in. Dynamically inserted, different on every download.
    case adPod
    /// Fixed cross-promotion for the show's network. Baked into the file, identical every time.
    case networkPromo
    /// The show's own recurring opening: tagline, theme music, "welcome back to…".
    case showOpening
    /// A sponsor message the host reads aloud in the body of the episode.
    case hostReadAd

    var label: String {
        switch self {
        case .adPod: return "Ad"
        case .networkPromo: return "Promo"
        case .showOpening: return "Intro"
        case .hostReadAd: return "Sponsor"
        }
    }
}

/// How a span was found. Kept distinct from `SkipKind` because the learning loop demotes a
/// *detector*, not a category: if the sponsor-read stage misfires on one show, that says nothing
/// about the ad-server headers on the same show, and switching off the wrong one would either
/// lose good skips or keep the bad ones.
enum SkipSource: String, Codable, Sendable, CaseIterable {
    /// The host's own response headers declared the slot's byte range. Correct by construction:
    /// the server is telling us where it put the ad.
    case declaredByHost
    /// An MP3 encoder seam: a brief stereo-mode change that reverts within a frame or two, inside
    /// a silence gap, bounding a block of a standard spot length. Measured over roughly fourteen
    /// hours across six shows without a false positive.
    case encoderSeam
    /// Wording repeated verbatim across at least three episodes of the same show, at least eight
    /// words long. The length floor is load-bearing: relaxing it to three produced 147 spurious
    /// blocks in testing, because short phrases recur inside ordinary speech.
    case repeatedBoilerplate
    /// The end of a show tagline confirmed across episodes. The most conservative opening cut.
    case taglineBoundary
    /// Extends an opening to the end of its music bed, using a long gap with no speech in this
    /// episode's own word timings. Only fires when the gap is actually there.
    case silenceExtension
    /// A scripted sponsor hand-off phrase, corroborated by a sponsor learned from earlier episodes
    /// of the same show. Both halves are required.
    case sponsorRead

    /// Whether this detector needs a transcript of the episode being played. The Watch has no
    /// speech framework at all, and a first streamed listen has no transcript yet, so these
    /// stages can only ever contribute markers computed earlier somewhere else.
    var requiresTranscript: Bool {
        switch self {
        case .declaredByHost, .encoderSeam: return false
        case .repeatedBoilerplate, .taglineBoundary, .silenceExtension, .sponsorRead: return true
        }
    }

    /// Whether this detector can run against bytes alone, before or during streaming, with no
    /// prior download of the whole episode.
    var runsOnPartialAudio: Bool {
        switch self {
        case .declaredByHost, .encoderSeam: return true
        case .repeatedBoilerplate, .taglineBoundary, .silenceExtension, .sponsorRead: return false
        }
    }
}

/// How much trust a span has earned, which decides whether it is acted on silently.
enum SkipConfidence: String, Codable, Sendable {
    /// Skip it without saying anything. Reserved for detectors measured at no false positives.
    case automatic
    /// Show it, offer it, but do not take it. Where a detector has been demoted by corrections,
    /// or where stages disagreed.
    case offered

    var isAutomatic: Bool { self == .automatic }
}

/// One stretch of an episode Banana believes is not the thing the listener came for.
struct SkipSpan: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(source.rawValue)-\(Int(start * 1000))-\(Int(end * 1000))" }

    /// Seconds from the start of the episode's audio.
    var start: Double
    var end: Double
    var kind: SkipKind
    var source: SkipSource
    var confidence: SkipConfidence
    /// Set when `source` is `.sponsorRead`, so a correction can retire one sponsor on one show
    /// rather than the whole detector. This is the measured failure mode: a sponsor that is also
    /// the subject of an episode.
    var sponsor: String?

    var duration: Double { max(0, end - start) }

    func overlaps(_ other: SkipSpan) -> Bool { start < other.end && other.start < end }

    func contains(_ time: Double) -> Bool { time >= start && time < end }
}

/// Everything Banana knows about where to skip in one episode.
///
/// This is the unit that travels: it is small, it is self-contained, and acting on it needs no
/// transcript and no model. That matters because the Watch has neither, and it plays only files
/// transferred to it, so the phone computes the plan and the Watch simply obeys it.
struct EpisodeSkipPlan: Codable, Hashable, Sendable {
    var episodeID: String
    var podcastID: UUID
    var spans: [SkipSpan] = []
    /// Bumped when a detector changes behaviour, so stored plans from an older engine are
    /// recomputed instead of trusted.
    var engineVersion: Int = EpisodeSkipPlan.currentEngineVersion
    var builtAt: Date?
    /// Ad pods are stitched per download. A plan built for one copy of the audio does not
    /// describe a different copy, so the plan records which bytes it was built against and is
    /// discarded when they no longer match.
    var audioByteCount: Int64?

    static let currentEngineVersion = 1

    /// Spans that may be skipped without asking.
    var automaticSpans: [SkipSpan] { spans.filter { $0.confidence.isAutomatic } }

    /// The span containing a given playback time, if any.
    func span(at time: Double) -> SkipSpan? { spans.first { $0.contains(time) } }

    /// Where playback should jump to from `time`, or nil to keep playing.
    ///
    /// Adjacent automatic spans collapse into one jump: an ad pod that runs straight into a
    /// network promo should be a single move, not two visible stutters.
    func destination(from time: Double, tolerance: Double = 0.75) -> Double? {
        var cursor = time
        var moved = false
        var guardCount = 0
        while guardCount < 16 {
            guardCount += 1
            guard let hit = automaticSpans
                .filter({ $0.contains(cursor) || ($0.start > cursor && $0.start - cursor <= tolerance) })
                .max(by: { $0.end < $1.end })
            else { break }
            if hit.end <= cursor { break }
            cursor = hit.end
            moved = true
        }
        return moved ? cursor : nil
    }
}

extension EpisodeSkipPlan {
    /// Tolerant decode. A plan is a cache, never a source of truth, so a malformed span drops that
    /// span instead of taking the episode's whole plan with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeID = try c.decode(String.self, forKey: .episodeID)
        podcastID = try c.decode(UUID.self, forKey: .podcastID)
        spans = (try c.decodeIfPresent(LossyArray<SkipSpan>.self, forKey: .spans))?.elements ?? []
        engineVersion = try c.decodeIfPresent(Int.self, forKey: .engineVersion) ?? 0
        builtAt = try c.decodeIfPresent(Date.self, forKey: .builtAt)
        audioByteCount = try c.decodeIfPresent(Int64.self, forKey: .audioByteCount)
    }

    /// Whether this stored plan still describes the audio in hand.
    func isValid(forByteCount bytes: Int64?) -> Bool {
        guard engineVersion == EpisodeSkipPlan.currentEngineVersion else { return false }
        guard let recorded = audioByteCount, let bytes else { return true }
        return recorded == bytes
    }
}
