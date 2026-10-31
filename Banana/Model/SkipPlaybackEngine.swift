import Foundation

/// One jump automatic skipping actually made — what was taken, from where, and when.
///
/// Kept as a value so the player can tell the listener what happened and offer the move back
/// without holding on to any part of the plan machinery.
struct PerformedSkip: Equatable, Sendable {
    /// Every automatic span the jump passed over, in play order. More than one when adjacent
    /// spans collapsed (an ad pod running straight into a network promo is one move, not two).
    var spans: [SkipSpan]
    var from: Double
    var to: Double
    var at: Date

    var duration: Double { max(0, to - from) }

    /// What was taken, in the plan's own words: "Ad", "Ad + Intro". De-duplicated in play order,
    /// because "Ad + Ad + Intro" describes the implementation rather than the listening.
    var label: String {
        var seen: [String] = []
        for span in spans where !seen.contains(span.kind.label) { seen.append(span.kind.label) }
        return seen.joined(separator: " + ")
    }
}

/// Everything about automatic ad skipping that is a decision rather than an AVPlayer call.
///
/// Split out of `PlayerController` because the rules that actually matter here are pure — which
/// seek teaches the feature something, when a stored plan has stopped describing the audio in
/// hand, whether a plan or a show's fixed pre-roll setting owns the opening — and testing them
/// through a live AVPlayer would amount to not testing them at all.
///
/// A value type on purpose. Everything it holds is a value, its only owner is the main actor,
/// and the alternative (another shared reference for playback code to reach into) is how the
/// races elsewhere in this app started.
struct SkipPlaybackEngine {
    /// The user's master switch. Off leaves the plan loaded and visible — the settings screen and
    /// the episode UI still have something honest to say — but nothing moves on its own.
    var isEnabled = true

    /// The plan as it applies *right now*: the stored plan with the correction book applied at
    /// load, plus session-local demotions for anything the listener rejected during this episode.
    /// Never written back to disk — the store keeps what was built, the book keeps what was
    /// learned, and this is neither.
    private(set) var plan: EpisodeSkipPlan?

    /// The one learning signal there is. Fed exclusively from `userSeeked`.
    private var watcher = SkipRewindWatcher()

    private(set) var lastSkip: PerformedSkip?

    /// Matches `EpisodeSkipPlan.destination(from:)`'s own default, so "spans that collapse into
    /// one jump" means the same thing when we group them as when the contract jumps them.
    private static let collapseTolerance: Double = 0.75

    // MARK: - Loading

    /// Adopt a stored plan for the episode about to play.
    ///
    /// Returns false when there is nothing to act on — no plan, or a plan that no longer
    /// describes these bytes. Ad pods are stitched per download, so a plan built against one copy
    /// of an episode is not merely stale for another copy, it is *wrong about a different file*,
    /// and acting on it would cut into content at the offsets where the other copy's ads were.
    @discardableResult
    mutating func load(_ candidate: EpisodeSkipPlan?,
                       corrections: SkipCorrectionBook,
                       audioByteCount: Int64?) -> Bool {
        watcher = SkipRewindWatcher()
        lastSkip = nil
        guard let candidate, candidate.isValid(forByteCount: audioByteCount) else {
            plan = nil
            return false
        }
        plan = corrections.applied(to: candidate)
        return true
    }

    mutating func clear() {
        plan = nil
        watcher = SkipRewindWatcher()
        lastSkip = nil
    }

    /// Whether anything in the loaded plan would move playback on its own.
    var hasAutomaticSpans: Bool { !(plan?.automaticSpans.isEmpty ?? true) }

    /// Where playback might need to jump from, for whoever schedules the wake-ups. Sorted, and
    /// only the starts — a span's end is where a jump lands, never where one begins.
    var automaticSpanStarts: [Double] {
        guard isEnabled, let plan else { return [] }
        return plan.automaticSpans.map(\.start).sorted()
    }

    // MARK: - The fixed pre-roll

    /// Whether an automatic plan already describes the region a show's fixed `autoSkipSeconds`
    /// pre-roll would have swallowed.
    ///
    /// The two are answers to the same question and only one of them can be right. The fixed skip
    /// is a blunt guess made once by hand; the plan is a measurement of this episode. Applying
    /// both means starting playback past the plan's own spans — so the plan never fires, the
    /// listener loses whatever sat between the guess and the truth, and the feature gets blamed
    /// for a cut it did not make. Where the plan has anything to say about that region, it wins
    /// outright. Where it doesn't (a plan that only found a host-read sponsor halfway in), the
    /// show's setting is untouched.
    func supersedesFixedPreRoll(ofSeconds seconds: Int) -> Bool {
        guard isEnabled, seconds > 0, let plan else { return false }
        return plan.automaticSpans.contains { $0.start < Double(seconds) }
    }

    // MARK: - Jumping

    /// Where playback should move to from `time`, or nil to keep playing.
    ///
    /// Mutating because a jump that is going to happen has to be remembered: the whole learning
    /// loop is "did the listener come back into what we just took", and that question can only be
    /// asked of a skip we recorded at the moment we made it.
    /// The least a skip may move and still be worth performing.
    ///
    /// `destination(from:)` pulls in any span starting within its tolerance ahead of the cursor,
    /// so a destination can legitimately sit a fraction of a second away. Seeking for that gains
    /// nothing audible, and — because a skip re-checks itself once the seek settles — a jump that
    /// barely moves is the raw material of an infinite loop. No real ad or promo is a quarter of
    /// a second long, so nothing worth skipping is lost by requiring this.
    static let minimumAdvance: Double = 0.25

    mutating func jump(from time: Double, now: Date = Date()) -> PerformedSkip? {
        guard isEnabled, let plan,
              let destination = plan.destination(from: time),
              destination - time >= Self.minimumAdvance
        else { return nil }
        // Every automatic span this one move passes over. A rewind into any of them is an
        // objection to this jump, so each has to be recorded separately — they may well come
        // from different detectors, and it is the detector that gets demoted, not the jump.
        let crossed = plan.automaticSpans
            .filter { $0.end > time && $0.end <= destination + 0.001 }
            .sorted { $0.start < $1.start }
        for span in crossed { watcher.recordSkip(span, now: now) }
        let performed = PerformedSkip(spans: crossed, from: time, to: destination, at: now)
        lastSkip = performed
        return performed
    }

    // MARK: - Learning

    /// Feed EVERY user-initiated seek here, and nothing else.
    ///
    /// The distinction is the whole feature. A skip's own jump lands the playhead at the end of a
    /// span; handing that back here would look exactly like a listener objecting, the detector
    /// would be demoted by its own success, and automatic skipping would quietly switch itself
    /// off show by show. `PlayerController` makes that structurally impossible rather than
    /// carefully avoidable — see the note on `seek(to:)` there.
    ///
    /// Returns the span the listener rewound into when this seek says a recent skip was wrong.
    mutating func userSeeked(to time: Double, now: Date = Date()) -> SkipSpan? {
        watcher.userSeeked(to: time, now: now)
    }

    /// How far before a span's start a deliberate seek still counts as aiming at that span.
    ///
    /// Someone who wants to hear an ad scrubs to roughly its beginning, not exactly onto its first
    /// frame, and landing a second short of it must not hand them straight back to the skip they
    /// were trying to get around.
    static let deliberateVisitLeadIn: Double = 3.0

    /// Suppress auto-skipping for a stretch the listener deliberately navigated into.
    ///
    /// Automatic skipping applies to playback *arriving* at a span on its own. It must never
    /// override someone steering: scrubbing back to hear a sponsor read, or to catch something
    /// said just before an ad, is a direct instruction to leave that audio alone. Without this, a
    /// seek into a span is answered by a jump straight back out of it, and the listener cannot
    /// reach that audio at all no matter how many times they try.
    ///
    /// Deliberately NOT a correction. Wanting to hear an ad once says nothing about whether the
    /// detector was right that it is an ad, and treating it as evidence would retire working
    /// detectors for the opposite of a mistake. Only a rewind straight back out of a skip that
    /// just happened carries that meaning, and `userSeeked` is what reads it.
    ///
    /// Returns the spans that were suppressed, for the caller to log or surface.
    @discardableResult
    mutating func noteDeliberateVisit(to time: Double) -> [SkipSpan] {
        guard isEnabled, let plan else { return [] }
        let aimedAt = plan.automaticSpans.filter { span in
            span.contains(time) || (span.start > time && span.start - time <= Self.deliberateVisitLeadIn)
        }
        guard let first = aimedAt.min(by: { $0.start < $1.start }) else { return [] }
        // The whole collapsed run, not just the span landed in: a jump would have taken them
        // across all of it in one move, so suppressing a third of it would still deny them the
        // rest.
        let run = collapsedRun(containing: first)
        demoteForSession(run)
        return run
    }

    /// Stop acting on these spans for the rest of this episode.
    ///
    /// Separate from the correction book, which decides what happens on *future* episodes once a
    /// detector has misfired often enough. This is the immediate half: someone who has just
    /// rewound into a skipped stretch must not have it taken away again a second later, however
    /// far the detector still is from its threshold.
    mutating func demoteForSession(_ spans: [SkipSpan]) {
        guard var working = plan, !spans.isEmpty else { return }
        let ids = Set(spans.map(\.id))
        working.spans = working.spans.map { span in
            guard ids.contains(span.id) else { return span }
            var demoted = span
            demoted.confidence = .offered
            return demoted
        }
        plan = working
        if let last = lastSkip, !ids.isDisjoint(with: Set(last.spans.map(\.id))) { lastSkip = nil }
    }

    /// The run of adjacent automatic spans `span` belongs to — exactly the set one jump would
    /// have collapsed into a single move.
    ///
    /// Used when a rewind lands in one span of a multi-span jump: the listener objected to the
    /// move that was made, not to the third of it they happened to land in, so the whole run
    /// stops for the session. Only the span they actually landed in counts as a *correction*,
    /// though — one rewind is one piece of evidence about one detector.
    func collapsedRun(containing span: SkipSpan) -> [SkipSpan] {
        guard let plan else { return [span] }
        let ordered = plan.automaticSpans.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return [span] }
        var run: [SkipSpan] = []
        for candidate in ordered {
            if let previous = run.last, candidate.start - previous.end > Self.collapseTolerance {
                if run.contains(where: { $0.id == span.id }) { return run }
                run = []
            }
            run.append(candidate)
        }
        return run.contains(where: { $0.id == span.id }) ? run : [span]
    }
}
