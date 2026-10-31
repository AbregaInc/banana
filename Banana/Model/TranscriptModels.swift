import Foundation

/// One timestamped token of a transcript — the unit we highlight during playback.
struct TranscriptWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval   // seconds from episode start
    var end: TimeInterval
    var speaker: Int?         // diarization speaker index, if known
}

/// A full episode transcript with word-level timing, optionally speaker-labelled.
struct Transcript: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case feed
        /// Apple's SpeechAnalyzer. The raw value is retained so old saved transcripts still decode.
        case onDevice
        case parakeet

        nonisolated var qualityRank: Int {
            switch self {
            case .feed: return 3
            case .parakeet: return 2
            case .onDevice: return 1
            }
        }
    }

    var episodeID: String
    var source: Source
    var words: [TranscriptWord]
    /// Diarization speaker index → display name (from metadata), when known.
    var speakerNames: [Int: String] = [:]

    /// What each speaker is called in the transcript: the name the publisher gave, or "Speaker 1",
    /// "Speaker 2" in the order they first speak. Empty when the transcript doesn't tell two
    /// people apart: one voice needs no name over every line.
    var speakerLabels: [Int: String] {
        var order: [Int] = []
        var seen = Set<Int>()
        for word in words {
            if let speaker = word.speaker, seen.insert(speaker).inserted { order.append(speaker) }
        }
        guard order.count > 1 else { return [:] }
        var labels: [Int: String] = [:]
        for (position, speaker) in order.enumerated() {
            let name = speakerNames[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            labels[speaker] = name.isEmpty ? "Speaker \(position + 1)" : name
        }
        return labels
    }

    /// Index of the word active at playback time `t` (binary search; nil before the first
    /// or in a gap). Used to drive karaoke highlighting each tick.
    /// The spoken text around a moment — what you'd just heard when you reached for the record
    /// button. Defaults to the ~30s leading up to `t` plus a few seconds after, so a note captures
    /// the thought's trigger, not just the instant.
    func excerpt(around t: TimeInterval, before: TimeInterval = 30, after: TimeInterval = 4) -> String {
        guard !words.isEmpty else { return "" }
        let lo = t - before, hi = t + after
        let slice = words.filter { $0.end >= lo && $0.start <= hi }
        return slice.map(\.text).joined(separator: " ")
    }

    func index(at t: TimeInterval) -> Int? {
        guard !words.isEmpty else { return nil }
        var lo = 0, hi = words.count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            let w = words[mid]
            if t < w.start { hi = mid - 1 }
            else if t > w.end { lo = mid + 1 }
            else { found = mid; break }
        }
        // In a gap between words → snap to the most recent one that has started.
        if found == nil {
            let i = lo - 1
            if words.indices.contains(i) { found = i }
        }
        return found
    }
}

/// A short run of words rendered as one line and highlighted as a unit.
struct Phrase: Identifiable, Sendable, Equatable {
    let id: Int
    let range: Range<Int>       // indices into the transcript's words
    let start: TimeInterval
    /// Who says it, when the transcript tells speakers apart.
    var speaker: Int? = nil
    /// The first phrase of a speaker's turn: their name goes above it.
    var startsTurn = false

    func contains(_ wordIndex: Int?) -> Bool {
        guard let wordIndex else { return false }
        return range.contains(wordIndex)
    }

    /// Break words into phrases on sentence punctuation, ~12-word runs, and a change of speaker
    /// (a phrase is one person's). A word with no speaker belongs to whoever was speaking.
    static func segment(_ words: [TranscriptWord]) -> [Phrase] {
        var phrases: [Phrase] = []
        var start = 0
        var id = 0
        var lastSpeaker: Int?
        var current: Int?
        for i in words.indices {
            if let speaker = words[i].speaker, current == nil { current = speaker }
            let endsSentence = words[i].text.hasSuffix(".") || words[i].text.hasSuffix("?")
                || words[i].text.hasSuffix("!") || words[i].text.hasSuffix("…")
            let longRun = i - start >= 11
            let nextSpeaker = i + 1 < words.count ? words[i + 1].speaker : nil
            let handsOver = nextSpeaker != nil && current != nil && nextSpeaker != current
            if endsSentence || longRun || handsOver || i == words.count - 1 {
                let speaker = current ?? lastSpeaker
                phrases.append(Phrase(id: id, range: start..<(i + 1), start: words[start].start,
                                      speaker: speaker, startsTurn: speaker != nil && speaker != lastSpeaker))
                if let speaker { lastSpeaker = speaker }
                current = nil
                id += 1
                start = i + 1
            }
        }
        return phrases
    }
}

/// One diarized speech turn: who spoke, from when to when.
struct SpeakerTurn: Hashable {
    var speaker: Int
    var start: TimeInterval
    var end: TimeInterval
}

enum Diarization {
    /// A diarizer's segments as turns: its speaker ids become 0, 1, 2… in the order the speakers
    /// first speak, so "Speaker 1" is whoever opens the episode.
    static func turns(_ segments: [(speaker: String, start: TimeInterval, end: TimeInterval)]) -> [SpeakerTurn] {
        var index: [String: Int] = [:]
        return segments.sorted { $0.start < $1.start }.compactMap { segment in
            guard segment.end > segment.start else { return nil }
            let speaker = index[segment.speaker] ?? index.count
            index[segment.speaker] = speaker
            return SpeakerTurn(speaker: speaker, start: segment.start, end: segment.end)
        }
    }

    /// Assign each word a speaker index by the turn its midpoint falls into.
    /// Non-destructive: words outside every turn keep `speaker == nil`.
    static func label(_ words: [TranscriptWord], with turns: [SpeakerTurn]) -> [TranscriptWord] {
        guard !turns.isEmpty else { return words }
        let sorted = turns.sorted { $0.start < $1.start }
        return words.map { word in
            let mid = (word.start + word.end) / 2
            var w = word
            w.speaker = sorted.first(where: { mid >= $0.start && mid <= $0.end })?.speaker
            return w
        }
    }
}
