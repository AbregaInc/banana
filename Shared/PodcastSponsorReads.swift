import Foundation

// MARK: - Host-read sponsor detection
//
// Stage 3 of the skip plan: the sponsor message the hosts read aloud in the middle of an episode.
// Unlike an ad-server pod it is baked into the file, it is in the hosts' own voices, and it has no
// acoustic seam around it — the only thing that separates it from the episode is what is said.
//
// It fires only when BOTH halves are present: a scripted hand-off phrase, and a sponsor this show
// has already read for in an earlier episode. Neither half ships alone, and that is not caution
// for its own sake — it is what produced 100 % precision over the 28 control passages, one of
// which is eighty seconds of two hosts discussing a Formula One title *sponsor*, using the word
// three times, with no hand-off phrase and no known brand anywhere in it.
//
// The cost is recall: one measured ad was woven into an analogy about the episode's own subject
// instead of the usual script, and this detector does not find it. That is the trade the whole
// feature is built on. A missed ad leaves the listener where they already were.

/// The sponsors one show has been heard reading for, and the detector that uses them.
struct PodcastSponsorSlate: Codable, Hashable, Sendable {

    // MARK: Thresholds

    /// The scripted hand-off, transcribed from the shows themselves. Half the pairing; on its own
    /// it is never acted on.
    ///
    /// This is the phrase set that was measured, expanded from the research regex into literal
    /// wording. It is deliberately not generalised — every phrase added here is precision spent,
    /// and precision is the only thing this stage has. The last two are subsumed by the first and
    /// are kept because the measured regex listed them.
    static let handoffPhrases = [
        "now is a great time to thank our",
        "now is a great time to thank one of our",
        "now is a great time to tell you about one of our favorite companies",
        "now is a great time to tell you about one of our favourite companies",
        "great time to thank our presenting partner",
        "great time to thank our longtime friend",
    ]

    /// How soon after the hand-off the sponsor has to be named for the two to be the same event.
    ///
    /// Measured at 3.0–5.0 s across all seven detected reads: the script is "…thank our presenting
    /// partner, J.P. Morgan". Fifteen seconds is three times the widest measured gap and still far
    /// too short for an unrelated brand mention to drift into range.
    static let sponsorNamingWindow: TimeInterval = 15

    /// How far past the hand-off a repeat of the sponsor's name still belongs to the read.
    ///
    /// The read ends on its call to action, which is the last time the brand is said. The longest
    /// measured read ran 125 s. At 180 s the cut ended inside the hand-verified boundary on all
    /// seven — always a second or two early, never late, which is the direction that costs nothing.
    static let sponsorReadWindow: TimeInterval = 180

    /// How much of a folded brand key a run of words has to account for before it counts as saying
    /// the brand. "JP" is two characters and turns up inside ordinary speech; the measured slate
    /// folds to `jpmorgan`, `servisenow`, `versel` and `statsig`, all of which clear five.
    static let minimumMatchedKeyLength = 5

    /// A brand is at most this many words. "J.P. Morgan Payments" is the longest measured.
    static let maximumNameWordCount = 4

    /// How far past the hand-off to look for the comma that ends the role phrase — "…thank our
    /// presenting partner," and "…thank our longtime friend of the show," are the measured shapes.
    static let maximumRoleWordCount = 8

    /// Bounds on what one show keeps, so a subscription running for years cannot grow this file
    /// without limit. Sponsors rotate; the slate is meant to hold a season, not a history.
    static let maximumSponsorCount = 24
    static let retainedEpisodeIDCount = 8

    // MARK: Stored slate

    struct LearnedSponsor: Codable, Hashable, Sendable {
        /// As the show says it, for the correction key and for anything shown to the listener.
        var name: String
        /// The comparison form — see `PodcastSponsorSlate.folded`.
        var key: String
        /// Which episodes it was heard in. The pairing requires an *earlier* episode, so an
        /// episode cannot be its own corroboration.
        var episodeIDs: [String]
    }

    var podcastID: UUID
    private(set) var sponsors: [LearnedSponsor] = []

    init(podcastID: UUID) {
        self.podcastID = podcastID
    }

    // MARK: Learning

    /// Learn this show's sponsors from one episode: whoever is named in the hand-off position.
    ///
    /// The hand-off is the only place a sponsor's name is stated unambiguously — "…thank our
    /// presenting partner, J.P. Morgan." Names taken from anywhere else in an episode would be
    /// names the episode is *about*, which is exactly the collision this stage exists to avoid.
    mutating func learn(episodeID: String, words: [SpokenWord]) {
        for handoff in Self.handoffs(in: words) {
            guard let name = Self.sponsorName(after: handoff, in: words) else { continue }
            note(name: name, episodeID: episodeID)
        }
    }

    private mutating func note(name: String, episodeID: String) {
        let key = Self.folded(name)
        guard key.count >= Self.minimumMatchedKeyLength else { return }

        // The same sponsor is read with and without a product suffix from week to week — "J.P.
        // Morgan" one episode, "J.P. Morgan Payments" the next. Folding those together keeps one
        // correction key per sponsor, so retiring the sponsor retires it however it was said.
        if let existing = sponsors.firstIndex(where: {
            $0.key.hasPrefix(key) || key.hasPrefix($0.key)
        }) {
            var merged = sponsors[existing]
            if key.count < merged.key.count {
                merged.key = key
                merged.name = name
            }
            if !merged.episodeIDs.contains(episodeID) {
                merged.episodeIDs.append(episodeID)
                if merged.episodeIDs.count > Self.retainedEpisodeIDCount {
                    merged.episodeIDs.removeFirst(merged.episodeIDs.count - Self.retainedEpisodeIDCount)
                }
            }
            sponsors[existing] = merged
            return
        }

        sponsors.append(LearnedSponsor(name: name, key: key, episodeIDs: [episodeID]))
        if sponsors.count > Self.maximumSponsorCount {
            sponsors.removeFirst(sponsors.count - Self.maximumSponsorCount)
        }
    }

    /// Drop one sponsor from this show for good.
    ///
    /// The measured failure mode for this stage is a sponsor that is also an episode's subject,
    /// which is a property of one sponsor on one show and of nothing else — the same reason
    /// `SkipSpan.sponsor` is carried on every span this file produces.
    mutating func retire(sponsorNamed name: String) {
        let key = Self.folded(name)
        // Below the key floor a prefix match is a syllable, not a brand, so a too-short name
        // retires only an exact hit rather than sweeping the slate.
        guard key.count >= Self.minimumMatchedKeyLength else {
            sponsors.removeAll { $0.key == key }
            return
        }
        sponsors.removeAll { $0.key.hasPrefix(key) || key.hasPrefix($0.key) }
    }

    // MARK: Detection

    /// Host-read sponsor spans in this episode.
    ///
    /// A hand-off with no known sponsor beside it produces nothing, and a known sponsor with no
    /// hand-off produces nothing. Both are real cases in the measured data: one episode names a
    /// slate sponsor and says the word "sponsors" out loud in an ad this detector still declines
    /// to cut, because the scripted phrase is absent and guessing is not on the menu.
    func spans(in words: [SpokenWord], episodeID: String) -> [SkipSpan] {
        let known = sponsors.filter { sponsor in
            sponsor.episodeIDs.contains { $0 != episodeID }
        }
        guard !known.isEmpty else { return [] }

        let handoffs = Self.handoffs(in: words)
        guard !handoffs.isEmpty else { return [] }

        // Scanned once per sponsor for the whole episode rather than once per hand-off: an
        // episode of this length is thirty thousand words and the fold is not free.
        var mentionsByKey: [String: [Mention]] = [:]
        for sponsor in known where mentionsByKey[sponsor.key] == nil {
            mentionsByKey[sponsor.key] = Self.mentions(of: sponsor.key, in: words)
        }

        var out: [SkipSpan] = []
        for handoff in handoffs {
            let start = words[handoff.wordRange.lowerBound].start

            // Whichever known sponsor is named first inside the hand-off window. In every measured
            // read that is the very next clause.
            var named: LearnedSponsor?
            var namedAt = TimeInterval.greatestFiniteMagnitude
            for sponsor in known {
                let first = (mentionsByKey[sponsor.key] ?? []).first { mention in
                    mention.start >= start && mention.start - start <= Self.sponsorNamingWindow
                }
                guard let mention = first, mention.start < namedAt else { continue }
                named = sponsor
                namedAt = mention.start
            }
            guard let sponsor = named else { continue }

            // The read ends on the last time the brand is said inside the window — the call to
            // action. Ending on the brand rather than on a trailing sign-off stops a second or two
            // short of the true boundary, which is the safe side of it.
            let ends = (mentionsByKey[sponsor.key] ?? [])
                .filter { $0.start >= start && $0.start - start <= Self.sponsorReadWindow }
                .map(\.end)
            guard let end = ends.max(), end > start else { continue }

            out.append(SkipSpan(start: start,
                                end: end,
                                kind: .hostReadAd,
                                source: .sponsorRead,
                                confidence: .automatic,
                                sponsor: sponsor.name))
        }
        return out
    }

    // MARK: Hand-off phrases

    private struct Handoff {
        /// Indices into the caller's `words`, covering the matched phrase.
        var wordRange: Range<Int>
        /// Whether the matched phrase already ended on the comma that closes the role phrase, as
        /// "…one of our favorite companies," does and "…thank our" does not.
        var endsOnRoleComma: Bool
    }

    private static let handoffPhraseTokens: [[String]] = handoffPhrases.map { phrase in
        phrase.split(separator: " ").map { PodcastBoilerplateCorpus.normalized(String($0)) }
    }

    private static func handoffs(in words: [SpokenWord]) -> [Handoff] {
        var tokens: [(token: String, wordIndex: Int)] = []
        tokens.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            let token = PodcastBoilerplateCorpus.normalized(word.text)
            if !token.isEmpty { tokens.append((token, index)) }
        }

        var out: [Handoff] = []
        var i = 0
        while i < tokens.count {
            // Longest match wins: the short phrases in the list are prefixes of the long ones, and
            // the longer one puts the role phrase's comma inside the match, which is where the
            // sponsor's name is read from.
            var matched = 0
            for phrase in handoffPhraseTokens where phrase.count > matched && phrase.count <= tokens.count - i {
                var isMatch = true
                for (offset, expected) in phrase.enumerated() {
                    if tokens[i + offset].token != expected { isMatch = false; break }
                }
                if isMatch { matched = phrase.count }
            }
            guard matched > 0 else { i += 1; continue }
            let length = matched
            let lastWordIndex = tokens[i + length - 1].wordIndex
            out.append(Handoff(wordRange: tokens[i].wordIndex..<(lastWordIndex + 1),
                               endsOnRoleComma: words[lastWordIndex].text.hasSuffix(",")))
            // Skip past the match: the shorter phrases in the list are prefixes of the longer
            // ones, and one hand-off is one event.
            i += length
        }
        return out
    }

    /// The brand named in the hand-off position: everything between the comma that closes the role
    /// phrase and the end of that sentence.
    private static func sponsorName(after handoff: Handoff, in words: [SpokenWord]) -> String? {
        var index = handoff.wordRange.upperBound
        if !handoff.endsOnRoleComma {
            let limit = min(words.count, index + maximumRoleWordCount)
            while index < limit, !words[index].text.hasSuffix(",") {
                if isSentenceEnd(words[index].text) { return nil }
                index += 1
            }
            guard index < limit, words[index].text.hasSuffix(",") else { return nil }
            index += 1
        }

        var parts: [String] = []
        while index < words.count, parts.count < maximumNameWordCount {
            let text = words[index].text
            parts.append(text)
            if isSentenceEnd(text) { break }
            index += 1
        }

        let name = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        return name.isEmpty ? nil : name
    }

    /// A full stop after two letters or fewer is an initial — "J.P." — not the end of a sentence.
    /// Without this the slate learns "J.P." instead of "J.P. Morgan".
    private static func isSentenceEnd(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last, last == "." || last == "!" || last == "?" else {
            return false
        }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.count > 2
    }

    // MARK: Brand matching

    /// The comparison form of a brand name.
    ///
    /// Speech recognition mishears brands in consistent ways, and the research had to spell the
    /// variants out by hand — Vercel came back as "Versell", Statsig as "Statzig", ServiceNow as
    /// two words. Folding a soft c to s, z to s, and runs of a repeated letter to one collapses
    /// exactly those: `vercel`, `versell` → `versel`; `statzig`, `statsig` → `statsig`;
    /// `servicenow`, `service now` → `servisenow`.
    ///
    /// It is deliberately not an edit-distance match. Distance two on a six-letter word puts
    /// unrelated brands within reach of each other, and a brand matched wrongly here is a wrongly
    /// attributed correction, which retires the wrong sponsor.
    static func folded(_ name: String) -> String {
        var stripped = String.UnicodeScalarView()
        for scalar in name.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9": stripped.append(scalar)
            default: continue
            }
        }
        let source = Array(String(stripped))
        var out: [Character] = []
        out.reserveCapacity(source.count)
        for (i, character) in source.enumerated() {
            var folded = character
            if folded == "z" {
                folded = "s"
            } else if folded == "c", i + 1 < source.count, "eiy".contains(source[i + 1]) {
                folded = "s"
            }
            if out.last == folded { continue }
            out.append(folded)
        }
        return String(out)
    }

    private struct Mention {
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Every place in the episode where this brand is said, allowing for a mention that runs into
    /// its own URL — "vercel.com slash acquired" folds to `verselsom…`, which still starts with the
    /// brand's key.
    private static func mentions(of key: String, in words: [SpokenWord]) -> [Mention] {
        guard key.count >= minimumMatchedKeyLength else { return [] }
        var out: [Mention] = []
        var i = 0
        while i < words.count {
            var matchedLength: Int?
            var joined = ""
            for length in 1...maximumNameWordCount {
                let index = i + length - 1
                guard index < words.count else { break }
                joined += words[index].text
                let candidate = folded(joined)
                guard candidate.count >= minimumMatchedKeyLength else { continue }
                if candidate.hasPrefix(key) || key.hasPrefix(candidate) { matchedLength = length }
            }
            guard let length = matchedLength else { i += 1; continue }
            out.append(Mention(start: words[i].start, end: words[i + length - 1].end))
            i += length
        }
        return out
    }

    // MARK: Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case podcastID
        case sponsors
    }

    /// A slate is learned, never authoritative. An unreadable entry costs that sponsor; an
    /// unreadable slate costs this show its host-read detection and touches nothing else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        podcastID = try c.decode(UUID.self, forKey: .podcastID)
        sponsors = (try? c.decodeIfPresent(LossyArray<LearnedSponsor>.self, forKey: .sponsors))
            .flatMap { $0?.elements } ?? []
        sponsors.removeAll { $0.key.count < Self.minimumMatchedKeyLength || $0.name.isEmpty }
        if sponsors.count > Self.maximumSponsorCount {
            sponsors.removeFirst(sponsors.count - Self.maximumSponsorCount)
        }
    }
}

// MARK: - Persistence

/// Every show's sponsor slate, in one file. Same shape and same reasoning as
/// `PodcastBoilerplateLibrary`: a value type over an injected directory, no singleton, no shared
/// mutable state.
struct PodcastSponsorLibrary: Codable, Sendable {
    static let fileName = "podcast-sponsors.json"

    private(set) var slates: [String: PodcastSponsorSlate] = [:]

    init() {}

    subscript(podcastID: UUID) -> PodcastSponsorSlate {
        get { slates[podcastID.uuidString] ?? PodcastSponsorSlate(podcastID: podcastID) }
        set { slates[podcastID.uuidString] = newValue }
    }

    mutating func learn(podcastID: UUID, episodeID: String, words: [SpokenWord]) {
        var slate = self[podcastID]
        slate.learn(episodeID: episodeID, words: words)
        self[podcastID] = slate
    }

    /// The permanent form of a per-sponsor correction: `SkipCorrectionBook` demotes this sponsor's
    /// spans to `.offered` after one rewind, and this removes it from the show for good.
    mutating func retire(sponsorNamed name: String, forShow podcastID: UUID) {
        var slate = self[podcastID]
        slate.retire(sponsorNamed: name)
        self[podcastID] = slate
    }

    // MARK: Disk

    static func load(from directory: URL) -> PodcastSponsorLibrary {
        let url = directory.appendingPathComponent(fileName)
        switch SnapshotLoader.load(from: url, as: PodcastSponsorLibrary.self) {
        case .loaded(let library): return library
        case .empty, .corrupt: return PodcastSponsorLibrary()
        }
    }

    func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    // MARK: Tolerant decode

    private enum CodingKeys: String, CodingKey { case slates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slates = (try? c.decodeIfPresent(LossyDictionary<PodcastSponsorSlate>.self, forKey: .slates))
            .flatMap { $0?.elements } ?? [:]
    }
}
