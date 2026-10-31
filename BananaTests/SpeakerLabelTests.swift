import XCTest

/// Who is speaking in a transcript: the names shown, the phrases a turn is cut into, and how a
/// diarizer's turns label the words.
final class SpeakerLabelTests: XCTestCase {
    private func words(_ spoken: [(String, Int?)]) -> [TranscriptWord] {
        spoken.enumerated().map { index, word in
            TranscriptWord(text: word.0, start: Double(index), end: Double(index) + 0.9, speaker: word.1)
        }
    }

    private func transcript(_ spoken: [(String, Int?)], names: [Int: String] = [:]) -> Transcript {
        Transcript(episodeID: "e", source: .feed, words: words(spoken), speakerNames: names)
    }

    // MARK: Names

    func testAPublishersNamesAreUsed() {
        let labels = transcript([("Hi", 0), ("Hello", 1)], names: [0: "Ezra Klein", 1: " Sam "]).speakerLabels
        XCTAssertEqual(labels, [0: "Ezra Klein", 1: "Sam"])
    }

    func testUnnamedSpeakersAreNumberedInTheOrderTheyFirstSpeak() {
        // The diarizer's own numbering is arbitrary: whoever opens the episode is Speaker 1.
        let labels = transcript([("Hi", 4), ("Hello", 2), ("Again", 4)]).speakerLabels
        XCTAssertEqual(labels, [4: "Speaker 1", 2: "Speaker 2"])
    }

    func testNamedAndUnnamedTogether() {
        let labels = transcript([("Hi", 0), ("Hello", 1)], names: [0: "Host", 1: ""]).speakerLabels
        XCTAssertEqual(labels, [0: "Host", 1: "Speaker 2"])
    }

    func testOneVoiceOrNoneGetsNoLabels() {
        XCTAssertEqual(transcript([("Hi", 0), ("there", 0)], names: [0: "Host"]).speakerLabels, [:])
        XCTAssertEqual(transcript([("Hi", nil), ("there", nil)]).speakerLabels, [:])
    }

    // MARK: Phrases

    func testAPhraseIsOnePersons() {
        let phrases = Phrase.segment(words([("So", 0), ("what", 0), ("happened", 0), ("Well", 1), ("it", 1), ("rained.", 1)]))
        XCTAssertEqual(phrases.map(\.range), [0..<3, 3..<6])
        XCTAssertEqual(phrases.map(\.speaker), [0, 1])
        XCTAssertEqual(phrases.map(\.startsTurn), [true, true])
    }

    func testTheNameGoesOverTheFirstPhraseOfATurnOnly() {
        let phrases = Phrase.segment(words([("One.", 0), ("Two.", 0), ("Three.", 1), ("Four.", 1), ("Five.", 0)]))
        XCTAssertEqual(phrases.map(\.startsTurn), [true, false, true, false, true])
    }

    func testAWordWithNoSpeakerStaysWithWhoeverWasSpeaking() {
        let phrases = Phrase.segment(words([("Yes.", 0), ("um", nil), ("right.", nil), ("No.", 1)]))
        XCTAssertEqual(phrases.map(\.speaker), [0, 0, 1])
        XCTAssertEqual(phrases.map(\.startsTurn), [true, false, true])
    }

    func testATranscriptWithoutSpeakersIsCutAsBefore() {
        let spoken = (0..<25).map { ("w\($0)", Int?.none) }
        let phrases = Phrase.segment(words(spoken))
        XCTAssertEqual(phrases.map(\.range), [0..<12, 12..<24, 24..<25])
        XCTAssertTrue(phrases.allSatisfy { $0.speaker == nil && !$0.startsTurn })
    }

    // MARK: A diarizer's turns

    func testADiarizersSpeakersAreNumberedByWhoSpeaksFirst() {
        let turns = Diarization.turns([(speaker: "S7", start: 10, end: 20), (speaker: "S2", start: 0, end: 9),
                                       (speaker: "S7", start: 30, end: 31), (speaker: "S9", start: 5, end: 5)])
        XCTAssertEqual(turns, [SpeakerTurn(speaker: 0, start: 0, end: 9), SpeakerTurn(speaker: 1, start: 10, end: 20),
                               SpeakerTurn(speaker: 1, start: 30, end: 31)], "an empty segment is dropped")
    }

    func testWordsTakeTheSpeakerOfTheTurnTheyFallIn() {
        let labelled = Diarization.label(words([("a", nil), ("b", nil), ("c", nil)]),
                                         with: [SpeakerTurn(speaker: 0, start: 0, end: 0.95), SpeakerTurn(speaker: 1, start: 2, end: 3)])
        XCTAssertEqual(labelled.map(\.speaker), [0, nil, 1], "a word between turns is left unlabelled")
    }
}
