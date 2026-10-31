import Foundation

/// What Banana learns when a skip was wrong.
///
/// There is exactly one honest signal available: the listener rewinding back into audio that was
/// skipped. That means "you took something I wanted". There is no corresponding gesture for "you
/// missed an ad" — someone sitting through an ad Banana failed to spot does nothing observable —
/// so this only ever tightens the feature, never loosens it. That asymmetry is deliberate and
/// matches the rule the whole design follows: err towards playing too much.
///
/// Corrections retire a *detector on a show*, not a category and not the feature. The measured
/// failure modes are all local: one show's opening runs longer than its tagline, one sponsor is
/// also one show's subject. Switching the whole feature off in response would throw away skips
/// that were never in question.
struct SkipCorrectionBook: Codable, Sendable {
    /// Rewind-into-skip counts, keyed by show and detector, and by sponsor where that applies.
    private var counts: [String: Int] = [:]

    /// How many corrections a detector may take on one show before it stops skipping silently.
    ///
    /// These differ because the detectors fail differently. A seam either is or is not an encoder
    /// boundary, and one rewind against a measured zero-false-positive record is more likely to be
    /// someone scrubbing than a miscalibration, so it takes two. A sponsor read that collides with
    /// an episode's subject is wrong the first time and wrong every time after, so it takes one.
    static func threshold(for source: SkipSource) -> Int {
        switch source {
        case .declaredByHost: return .max      // the server said so; a rewind cannot make it untrue
        case .encoderSeam: return 2
        case .repeatedBoilerplate: return 2
        case .taglineBoundary: return 2
        case .silenceExtension: return 1       // the least certain half of the opening cut
        case .sponsorRead: return 1
        }
    }

    static func key(podcastID: UUID, source: SkipSource, sponsor: String?) -> String {
        let suffix = sponsor.map { "|\($0.lowercased())" } ?? ""
        return "\(podcastID.uuidString)|\(source.rawValue)\(suffix)"
    }

    /// Every learned count, by key — what syncs between devices, one record per key.
    var allCounts: [String: Int] { counts }

    /// Another device's count for one key (nil: cleared there).
    mutating func setCount(_ count: Int?, forKey key: String) {
        counts[key] = count
    }

    /// Record that the listener rewound into this span.
    mutating func recordCorrection(for span: SkipSpan, podcastID: UUID) {
        let k = Self.key(podcastID: podcastID, source: span.source, sponsor: span.sponsor)
        counts[k, default: 0] += 1
    }

    func corrections(for span: SkipSpan, podcastID: UUID) -> Int {
        counts[Self.key(podcastID: podcastID, source: span.source, sponsor: span.sponsor)] ?? 0
    }

    /// Whether this span may still be skipped without asking.
    func allowsAutomatic(_ span: SkipSpan, podcastID: UUID) -> Bool {
        corrections(for: span, podcastID: podcastID) < Self.threshold(for: span.source)
    }

    /// Apply what has been learned to a freshly built plan, demoting spans whose detector has been
    /// corrected often enough on this show. Demoted spans stay in the plan and stay visible; they
    /// simply stop happening on their own.
    func applied(to plan: EpisodeSkipPlan) -> EpisodeSkipPlan {
        var out = plan
        out.spans = plan.spans.map { span in
            guard span.confidence.isAutomatic,
                  !allowsAutomatic(span, podcastID: plan.podcastID) else { return span }
            var demoted = span
            demoted.confidence = .offered
            return demoted
        }
        return out
    }

    /// A short, honest description of what has been retired, for the settings screen. Empty when
    /// nothing has been learned, so the UI can stay quiet rather than showing an empty section.
    func retiredDetectors(forShow podcastID: UUID) -> [SkipSource] {
        SkipSource.allCases.filter { source in
            let prefix = "\(podcastID.uuidString)|\(source.rawValue)"
            let hits = counts.filter { $0.key.hasPrefix(prefix) }.map(\.value).max() ?? 0
            return hits >= Self.threshold(for: source)
        }
    }
}

/// Detects the one learning signal there is: a seek that lands inside audio just skipped.
///
/// The window matters. Someone rewinding thirty seconds later is navigating, not objecting, and
/// counting that as a correction would retire good detectors on ordinary scrubbing. Only a rewind
/// that arrives shortly after the jump, and lands inside the span that was taken, counts.
struct SkipRewindWatcher {
    /// How long after a skip a rewind still reads as an objection to that skip.
    var window: TimeInterval = 25

    private var recent: [(span: SkipSpan, at: Date, landedAt: Double)] = []

    mutating func recordSkip(_ span: SkipSpan, now: Date) {
        recent.append((span, now, span.end))
        recent = recent.filter { now.timeIntervalSince($0.at) <= window }
    }

    /// Call on every user-initiated seek. Returns the span the listener rewound into, if this seek
    /// says a recent skip was wrong.
    ///
    /// Requires the seek to go backwards from where the skip left them, so jumping forward and
    /// back through an episode does not read as an objection.
    mutating func userSeeked(to time: Double, now: Date) -> SkipSpan? {
        recent = recent.filter { now.timeIntervalSince($0.at) <= window }
        guard let hit = recent.first(where: { $0.span.contains(time) && time < $0.landedAt }) else {
            return nil
        }
        recent.removeAll { $0.span == hit.span }
        return hit.span
    }
}
