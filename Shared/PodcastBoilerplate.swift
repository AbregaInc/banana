import Foundation

// MARK: - Transcript-level opening detection
//
// Stage 2 of the skip plan: the wording a show repeats at the top of every episode, and the point
// where that wording stops and the episode starts. It needs a transcript of the episode being
// played, so it runs on the phone and the Mac and nowhere else — the Watch receives the finished
// `SkipSpan`s and never sees a word list.
//
// Every threshold here is the number that was measured against his own subscriptions, not a
// number that looked reasonable. Where the research offered a choice, this file takes the option
// that cuts less: `PodcastSkipPlan`'s rule is that a missed ad costs nothing and a wrong skip
// costs the listener the thing they opened the app for.

/// One timestamped token, as this file wants it.
///
/// Deliberately not `Banana/Model/Transcript.swift`'s `TranscriptWord`: that type lives in the
/// app target, and these detectors are tested on their own against literal passages from the
/// research corpus. Callers map one to the other in a line; nothing else is coupled.
struct SpokenWord: Codable, Hashable, Sendable {
    var text: String
    /// Seconds from the start of the episode's audio.
    var start: TimeInterval
    var end: TimeInterval

    init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What one show has said at the top of its episodes before.
///
/// Per show, because "repeated wording" only means anything within one show — two unrelated
/// podcasts sharing a stock phrase is a coincidence, not a promo. Persisted, because the whole
/// detector is "this is the third time I have heard this", which is not a fact any single episode
/// contains.
struct PodcastBoilerplateCorpus: Codable, Hashable, Sendable {

    // MARK: Thresholds

    /// How many words a repeated phrase must run to before it can become a skip.
    ///
    /// LOAD-BEARING. Dropping it to three (the floor `probA/blocks.py` used while *looking* for
    /// structure) produced 147 spurious blocks across the test corpus, because ordinary speech
    /// repeats short phrases constantly — "thanks so much for", "was written by", "before we
    /// begin" all matched across episodes of the same show and none of them is boilerplate. At
    /// eight the only things that survived were the network promo and the tagline. Do not lower
    /// it to buy recall; recall is the thing this feature is allowed to lose.
    static let repeatedPhraseWordFloor = 8

    /// How many episodes must contain a phrase, counting the one being analysed, before it is
    /// treated as this show's wording rather than something the host happened to say twice.
    static let corroboratingEpisodeFloor = 3

    /// The run length that counts as *evidence* that two episodes are saying the same thing, used
    /// only to vote on the tagline. `probA/blocks.py` matched at three. Three is safe here and not
    /// safe as a span floor, and the difference is the whole point: a three-word agreement votes,
    /// and `repeatedPhraseWordFloor` still decides what becomes a cut.
    static let agreementRunFloor = 3

    /// How much of each episode is remembered and searched.
    ///
    /// `probA/blocks.py` mined the first 400 s, and every opening measured — promo, ad pod,
    /// tagline — finished inside 100 s. Outros are deliberately excluded: no signal detected a
    /// credit roll at 100 % precision, so they are left alone rather than guessed at. This also
    /// keeps a show's corpus small enough to write to disk without thinking about it.
    static let learningHorizon: TimeInterval = 400

    /// How many episodes' openings to keep. Several times the ≥3 floor, so a show that changes its
    /// promo re-learns within a few episodes, and bounded so one long-running subscription cannot
    /// grow its corpus without limit.
    static let retainedEpisodeCount = 8

    /// The music bed. A stretch this long with no word in *this episode's own* timings is the gap
    /// between the last thing the host said in the intro and the first thing they say in the
    /// episode. Measured at 16.3 s, 24.2 s and 24.3 s on the three episodes that had one.
    static let silentGapFloor: TimeInterval = 8

    /// And no longer than this. The measured beds ran 16.3 s, 24.2 s and 24.3 s. A silence of
    /// several minutes is not a music bed — it is a stretch the recogniser produced no words for,
    /// which is exactly the audio nobody has checked, so it is left alone. This is a guard rather
    /// than a fitted value: 60 s is well clear of every bed measured, and it only ever cuts less.
    static let silentGapCeiling: TimeInterval = 60

    /// How late in an episode a gap may begin and still be read as the end of the opening.
    ///
    /// The measured beds began at 206 s, 226 s and 242 s. The one episode of the same show with no
    /// bed has its first long gap at 316 s — inside the story, where treating it as an opening
    /// boundary would have deleted four minutes of content. 300 s sits above every measured bed
    /// and below that gap, and it is the reason this detector correctly produces nothing on that
    /// fourth episode.
    static let silentGapHorizon: TimeInterval = 300

    // MARK: Stored corpus

    /// One episode's opening, normalized. Storing tokens rather than pre-computed phrase hashes
    /// keeps one representation to reason about: the repeated-phrase counts and the tagline vote
    /// are both derived from these at detection time, and neither can drift from the other.
    struct LearnedOpening: Codable, Hashable, Sendable {
        var episodeID: String
        var tokens: [String]
    }

    var podcastID: UUID
    private(set) var openings: [LearnedOpening] = []

    init(podcastID: UUID) {
        self.podcastID = podcastID
    }

    var learnedEpisodeCount: Int { openings.count }

    /// Fold one episode's opening into the corpus. Re-learning an episode replaces its entry
    /// rather than letting a re-transcription corroborate itself.
    mutating func learn(episodeID: String, words: [SpokenWord]) {
        let tokens = Self.normalizedTokens(in: words, before: Self.learningHorizon).map(\.token)
        guard !tokens.isEmpty else { return }
        openings.removeAll { $0.episodeID == episodeID }
        openings.append(LearnedOpening(episodeID: episodeID, tokens: tokens))
        if openings.count > Self.retainedEpisodeCount {
            openings.removeFirst(openings.count - Self.retainedEpisodeCount)
        }
    }

    // MARK: Stage 2a — wording repeated verbatim across episodes

    /// Stretches of this episode whose wording this show has said, word for word, in at least
    /// `corroboratingEpisodeFloor` episodes counting this one.
    ///
    /// `episodeID` is excluded from the corroborating set so an episode already folded into the
    /// corpus cannot vouch for itself.
    func repeatedBoilerplateSpans(in words: [SpokenWord], episodeID: String) -> [SkipSpan] {
        let target = Self.normalizedTokens(in: words, before: Self.learningHorizon)
        guard target.count >= Self.repeatedPhraseWordFloor else { return [] }

        let others = openings.filter { $0.episodeID != episodeID }
        // The episode in hand is one of the episodes, so it needs this many *other* episodes.
        let neededElsewhere = Self.corroboratingEpisodeFloor - 1
        guard neededElsewhere > 0, others.count >= neededElsewhere else { return [] }

        var seenIn: [String: Int] = [:]
        for opening in others {
            for phrase in Self.phrases(of: opening.tokens) {
                seenIn[phrase, default: 0] += 1
            }
        }

        var covered = [Bool](repeating: false, count: target.count)
        let targetTokens = target.map(\.token)
        for start in 0...(target.count - Self.repeatedPhraseWordFloor) {
            let phrase = targetTokens[start..<(start + Self.repeatedPhraseWordFloor)].joined(separator: " ")
            guard (seenIn[phrase] ?? 0) >= neededElsewhere else { continue }
            for i in start..<(start + Self.repeatedPhraseWordFloor) { covered[i] = true }
        }

        return Self.runs(of: covered).map { range in
            let first = words[target[range.lowerBound].wordIndex]
            let last = words[target[range.upperBound - 1].wordIndex]
            let text = target[range].map { words[$0.wordIndex].text }.joined(separator: " ")
            return SkipSpan(start: first.start,
                            end: last.end,
                            kind: Self.kind(ofBoilerplate: text),
                            source: .repeatedBoilerplate,
                            confidence: .automatic,
                            sponsor: nil)
        }
    }

    // MARK: Stage 2b — the end of the opening tagline

    /// The show's spoken tagline in this episode, when other episodes confirm it.
    ///
    /// Not the same detector as 2a with a looser comparison. A tagline is read live every week, so
    /// the speech recogniser mangles a different word each time — "where we listen" comes back as
    /// "when we listen" and "where we lessen" on the same show — and a verbatim match finds
    /// nothing. So each token is voted on: it counts when at least two *other* episodes contain a
    /// run of `agreementRunFloor` tokens through it, and the confirmed run must still reach
    /// `repeatedPhraseWordFloor`.
    ///
    /// That eight-word floor is what keeps this off the host's own introduction. "My name's Thomas
    /// and I'm your host" is confirmed across episodes too, and it is seven words, so it is not
    /// cut. Nothing else had to be added to hold that line.
    ///
    /// Returns the tagline itself, not everything up to it. What sits between the promo and the
    /// tagline is the ad pod, which is stages 0 and 1's finding to make; claiming it here would be
    /// guessing about audio this detector cannot see.
    func taglineSpan(in words: [SpokenWord],
                     episodeID: String,
                     startingAfter cutoff: TimeInterval = 0) -> SkipSpan? {
        let target = Self.normalizedTokens(in: words, before: Self.learningHorizon)
        guard target.count >= Self.repeatedPhraseWordFloor else { return nil }

        let others = openings.filter { $0.episodeID != episodeID }
        let neededElsewhere = Self.corroboratingEpisodeFloor - 1
        guard neededElsewhere > 0, others.count >= neededElsewhere else { return nil }

        let targetTokens = target.map(\.token)
        var votes = [Int](repeating: 0, count: target.count)
        for opening in others {
            let agreed = Self.tokensAgreeing(targetTokens, with: opening.tokens)
            for (i, isAgreed) in agreed.enumerated() where isAgreed { votes[i] += 1 }
        }
        let confirmed = votes.map { $0 >= neededElsewhere }

        // The last confirmed run that starts after everything 2a already claimed. Earlier runs are
        // the promo, which 2a states verbatim and states better.
        let candidates = Self.runs(of: confirmed)
            .filter { $0.count >= Self.repeatedPhraseWordFloor }
            .filter { words[target[$0.lowerBound].wordIndex].start >= cutoff }
        guard let range = candidates.last else { return nil }

        return SkipSpan(start: words[target[range.lowerBound].wordIndex].start,
                        end: words[target[range.upperBound - 1].wordIndex].end,
                        kind: .showOpening,
                        source: .taglineBoundary,
                        confidence: .automatic,
                        sponsor: nil)
    }

    // MARK: Stage 2c — the music bed after the opening

    /// Extends an opening to the far side of the music bed that follows it.
    ///
    /// Uses only this episode's own word timings, so it cannot be fooled by another episode's
    /// structure. It fires when the first long silence after the opening begins inside
    /// `silentGapHorizon`, and it produces nothing when there is no such gap — which is the
    /// measured behaviour on one of the four episodes tested, whose intro runs straight into its
    /// story with no bed at all.
    ///
    /// Emitted as its own span rather than folded into the opening, because the learning loop
    /// retires this half first: one rewind here drops the bed extension and leaves the tagline cut
    /// standing (`SkipCorrectionBook.threshold(for: .silenceExtension)` is 1).
    static func silenceExtensionSpan(in words: [SpokenWord], openingEnd: TimeInterval) -> SkipSpan? {
        guard openingEnd > 0, words.count >= 2 else { return nil }
        for (a, b) in zip(words, words.dropFirst()) {
            guard b.start > openingEnd else { continue }
            // Clamped rather than compared, so a gap the opening's last word ends inside still
            // measures from where the opening actually stopped — and so an opening boundary
            // rounded by a caller cannot fall a float's width short and lose the gap entirely.
            let gapStart = max(a.end, openingEnd)
            // The gap must be the *first* one after the opening. Walking past a short gap to find
            // a longer one further in is how a boundary gets invented in content.
            guard gapStart <= silentGapHorizon else { return nil }
            let gap = b.start - gapStart
            guard gap >= silentGapFloor else { continue }
            guard gap <= silentGapCeiling else { return nil }
            return SkipSpan(start: openingEnd,
                            end: b.start,
                            kind: .showOpening,
                            source: .silenceExtension,
                            confidence: .automatic,
                            sponsor: nil)
        }
        return nil
    }

    // MARK: The three together

    /// Every opening finding for one episode, in playback order.
    ///
    /// Chained rather than independent: the tagline looks past what 2a already claimed, and the
    /// bed extension starts from wherever the opening actually ended. Each stays a separate span
    /// so a correction retires one detector and not the set.
    func openingSpans(in words: [SpokenWord], episodeID: String) -> [SkipSpan] {
        var spans = repeatedBoilerplateSpans(in: words, episodeID: episodeID)
        let boilerplateEnd = spans.last?.end ?? 0

        if let tagline = taglineSpan(in: words, episodeID: episodeID, startingAfter: boilerplateEnd) {
            spans.append(tagline)
        }

        let openingEnd = spans.last?.end ?? 0
        if openingEnd > 0, let bed = Self.silenceExtensionSpan(in: words, openingEnd: openingEnd) {
            spans.append(bed)
        }
        return spans
    }

    // MARK: Text handling

    /// Lowercased, stripped to letters, digits and the apostrophe — the same normalization the
    /// research used, so "Sleepy." and "sleepy" are one token and punctuation drift between two
    /// passes of the recogniser does not break a match. Tokens that normalize away entirely are
    /// dropped, and their word indices with them, so a stray dash can never join two phrases.
    static func normalized(_ token: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in token.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9", "'": out.append(scalar)
            default: continue
            }
        }
        return String(out)
    }

    private static func normalizedTokens(in words: [SpokenWord],
                                         before horizon: TimeInterval) -> [(token: String, wordIndex: Int)] {
        var out: [(String, Int)] = []
        out.reserveCapacity(words.count)
        for (index, word) in words.enumerated() where word.start < horizon {
            let token = normalized(word.text)
            if !token.isEmpty { out.append((token, index)) }
        }
        return out
    }

    private static func phrases(of tokens: [String]) -> Set<String> {
        guard tokens.count >= repeatedPhraseWordFloor else { return [] }
        var out = Set<String>()
        for start in 0...(tokens.count - repeatedPhraseWordFloor) {
            out.insert(tokens[start..<(start + repeatedPhraseWordFloor)].joined(separator: " "))
        }
        return out
    }

    /// Which tokens of `target` sit inside a run of `agreementRunFloor` that `other` also contains.
    private static func tokensAgreeing(_ target: [String], with other: [String]) -> [Bool] {
        var agreed = [Bool](repeating: false, count: target.count)
        guard target.count >= agreementRunFloor, other.count >= agreementRunFloor else { return agreed }

        var runs = Set<String>()
        for start in 0...(other.count - agreementRunFloor) {
            runs.insert(other[start..<(start + agreementRunFloor)].joined(separator: " "))
        }
        for start in 0...(target.count - agreementRunFloor) {
            let run = target[start..<(start + agreementRunFloor)].joined(separator: " ")
            guard runs.contains(run) else { continue }
            for i in start..<(start + agreementRunFloor) { agreed[i] = true }
        }
        return agreed
    }

    private static func runs(of flags: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < flags.count {
            guard flags[i] else { i += 1; continue }
            var j = i
            while j < flags.count, flags[j] { j += 1 }
            out.append(i..<j)
            i = j
        }
        return out
    }

    /// Wording that marks a block as the *network's* promo rather than the show's own opening —
    /// taken from the measured promo, "Get Sleepy is a production of Somber Studios… support the
    /// show directly. Check out our premium feed…".
    ///
    /// This picks a label, not a cut. `SkipPlanBuilder.agree` treats `.networkPromo` and
    /// `.showOpening` as the same finding, so getting it wrong changes the word on screen and
    /// nothing else — which is why a short, literal list is enough and no guessing is warranted.
    private static let networkPromoMarkers = [
        "is a production of",
        "support the show",
        "premium feed",
    ]

    private static func kind(ofBoilerplate text: String) -> SkipKind {
        let tokens = text.split(separator: " ").map { normalized(String($0)) }.filter { !$0.isEmpty }
        let haystack = " " + tokens.joined(separator: " ") + " "
        for marker in networkPromoMarkers {
            let needle = " " + marker.split(separator: " ").map(String.init).joined(separator: " ") + " "
            if haystack.contains(needle) { return .networkPromo }
        }
        return .showOpening
    }

    // MARK: Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case podcastID
        case openings
    }

    /// A corpus is a cache of things already heard, never a source of truth. One unreadable
    /// opening costs that opening; a file that cannot be read at all costs this show its
    /// boilerplate and leaves every other detector on the episode untouched.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        podcastID = try c.decode(UUID.self, forKey: .podcastID)
        openings = (try? c.decodeIfPresent(LossyArray<LearnedOpening>.self, forKey: .openings))
            .flatMap { $0?.elements } ?? []
        if openings.count > Self.retainedEpisodeCount {
            openings.removeFirst(openings.count - Self.retainedEpisodeCount)
        }
    }
}

// MARK: - Persistence

/// Every show's boilerplate corpus, in one file.
///
/// A plain value type with an injected directory rather than a singleton reaching for the real
/// data folder: it keeps this testable against a temp directory, and it keeps the app's one
/// shared-mutable-state count from going up by one more.
struct PodcastBoilerplateLibrary: Codable, Sendable {
    static let fileName = "podcast-boilerplate.json"

    /// Keyed by `UUID.uuidString` because JSON object keys are strings and a `[UUID: _]` would
    /// encode as an array of alternating keys and values that no one can read in a crash report.
    private(set) var corpora: [String: PodcastBoilerplateCorpus] = [:]

    init() {}

    subscript(podcastID: UUID) -> PodcastBoilerplateCorpus {
        get { corpora[podcastID.uuidString] ?? PodcastBoilerplateCorpus(podcastID: podcastID) }
        set { corpora[podcastID.uuidString] = newValue }
    }

    mutating func learn(podcastID: UUID, episodeID: String, words: [SpokenWord]) {
        var corpus = self[podcastID]
        corpus.learn(episodeID: episodeID, words: words)
        self[podcastID] = corpus
    }

    // MARK: Disk

    static func load(from directory: URL) -> PodcastBoilerplateLibrary {
        let url = directory.appendingPathComponent(fileName)
        switch SnapshotLoader.load(from: url, as: PodcastBoilerplateLibrary.self) {
        case .loaded(let library): return library
        // A corpus that cannot be read means "no boilerplate known", which costs skips and never
        // costs content. The bytes are quarantined by the loader; nothing else here is affected.
        case .empty, .corrupt: return PodcastBoilerplateLibrary()
        }
    }

    func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    // MARK: Tolerant decode

    private enum CodingKeys: String, CodingKey { case corpora }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        corpora = (try? c.decodeIfPresent(LossyDictionary<PodcastBoilerplateCorpus>.self, forKey: .corpora))
            .flatMap { $0?.elements } ?? [:]
    }
}
