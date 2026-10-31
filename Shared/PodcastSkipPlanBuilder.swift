import Foundation

/// Combines what the individual detectors found into one plan.
///
/// This is where a false positive would be manufactured, so it is deliberately pessimistic. The
/// detectors each earned their place by measuring at no false positives *in isolation*; nothing
/// measured what happens when two of them disagree about the same stretch of audio. Rather than
/// guess, disagreement demotes: the span stays visible and stops being silent.
enum SkipPlanBuilder {

    /// How much overlap counts as "these two detectors are talking about the same audio".
    /// Below this they are treated as separate findings that happen to touch.
    private static let overlapFraction = 0.5

    /// Rank used only to decide whose boundaries survive a merge between detectors that AGREE.
    /// It is not a tiebreak for disagreement; disagreement is never resolved by preferring someone.
    private static func authority(_ source: SkipSource) -> Int {
        switch source {
        case .declaredByHost: return 5   // the server stated the byte range; nothing beats that
        case .encoderSeam: return 4      // physical evidence in the file itself
        case .repeatedBoilerplate: return 3
        case .taglineBoundary: return 2
        case .sponsorRead: return 2
        case .silenceExtension: return 1 // only ever extends something else's finding
        }
    }

    /// Two findings agree if they describe the same sort of thing. An ad pod found by the header
    /// and the same pod found acoustically are the same finding twice, which is corroboration.
    /// An opening and a sponsor read claiming the same seconds are not, and that is a real
    /// conflict: one of them is wrong about what this audio is.
    private static func agree(_ a: SkipSpan, _ b: SkipSpan) -> Bool {
        if a.kind == b.kind { return true }
        // An ad pod sitting inside what another detector called the opening is the normal shape of
        // a pre-roll: the ad is stitched in ahead of the show's own intro. Not a disagreement.
        let pair: Set<SkipKind> = [a.kind, b.kind]
        if pair == [.adPod, .networkPromo] { return true }
        if pair == [.adPod, .showOpening] { return true }
        if pair == [.networkPromo, .showOpening] { return true }
        return false
    }

    private static func overlapRatio(_ a: SkipSpan, _ b: SkipSpan) -> Double {
        let lo = max(a.start, b.start), hi = min(a.end, b.end)
        let shared = max(0, hi - lo)
        let smaller = min(a.duration, b.duration)
        guard smaller > 0 else { return 0 }
        return shared / smaller
    }

    /// Build the final plan from every detector's findings.
    ///
    /// `audioDuration` is used only to reject nonsense; a detector that claims a span running past
    /// the end of the episode has misread something, and the whole span is dropped rather than
    /// clamped, because a detector that is wrong about the end is not trustworthy about the start.
    static func build(episodeID: String,
                      podcastID: UUID,
                      findings: [SkipSpan],
                      audioDuration: Double?,
                      audioByteCount: Int64?,
                      builtAt: Date,
                      corrections: SkipCorrectionBook = SkipCorrectionBook()) -> EpisodeSkipPlan {

        var usable = findings.filter { span in
            guard span.duration > 0.5 else { return false }          // sub-second cuts help nobody
            if let d = audioDuration, span.end > d + 0.5 { return false }
            return span.start >= 0
        }
        usable.sort { $0.start < $1.start }

        var merged: [SkipSpan] = []
        for span in usable {
            guard let idx = merged.lastIndex(where: {
                overlapRatio($0, span) >= overlapFraction
            }) else {
                merged.append(span)
                continue
            }
            let existing = merged[idx]

            if agree(existing, span) {
                // Corroboration. Take the union of the two, since both detectors independently
                // believe this audio is skippable, and keep the more authoritative provenance so
                // the learning loop retires the right detector if it turns out to be wrong.
                let winner = authority(span.source) > authority(existing.source) ? span : existing
                var combined = winner
                combined.start = min(existing.start, span.start)
                combined.end = max(existing.end, span.end)
                combined.confidence = (existing.confidence.isAutomatic && span.confidence.isAutomatic)
                    ? .automatic : .offered
                merged[idx] = combined
            } else {
                // Genuine disagreement about what this audio is. Keep the more conservative
                // reading — the intersection, not the union — and stop skipping it silently.
                var narrowed = authority(span.source) > authority(existing.source) ? span : existing
                narrowed.start = max(existing.start, span.start)
                narrowed.end = min(existing.end, span.end)
                narrowed.confidence = .offered
                merged[idx] = narrowed
            }
        }

        let plan = EpisodeSkipPlan(episodeID: episodeID,
                                   podcastID: podcastID,
                                   spans: merged.filter { $0.duration > 0.5 },
                                   engineVersion: EpisodeSkipPlan.currentEngineVersion,
                                   builtAt: builtAt,
                                   audioByteCount: audioByteCount)
        return corrections.applied(to: plan)
    }
}
