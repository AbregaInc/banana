import XCTest

/// Filtering a show by how its narrators sound.
///
/// The precedence is the thing to pin. An explicit name mute is the listener's own decision and
/// wins outright. After that the voice speaks — including on episodes that DO credit a narrator,
/// which is the fix for a show that names all twenty of them: the credited branch used to return
/// before `mutedVoiceGenders` was consulted, so muting "female" matched nothing and the only way
/// to filter was muting every name by hand. A narrator with no verdict yet is never muted: not
/// knowing is not evidence, and hiding an episode on a guess is invisible to the listener.
final class NarratorVoiceFilterTests: XCTestCase {

    private func show(mutedNames: Set<String> = [], mutedVoices: Set<VoiceGender> = [],
                      episodes: [Episode] = []) -> Podcast {
        var podcast = Podcast(feedURL: URL(string: "https://example.com/feed")!, title: "Sleepy")
        podcast.mutedNarrators = mutedNames
        podcast.mutedVoiceGenders = mutedVoices
        podcast.episodes = episodes
        return podcast
    }

    private func episode(_ id: String, summary: String?) -> Episode {
        var ep = Episode(id: id, title: id, audioURL: URL(string: "https://example.com/\(id).mp3")!)
        ep.summary = summary
        return ep
    }

    func testAnUncreditedEpisodeIsFilteredByItsVoice() {
        let ep = episode("a", summary: "A gentle walk through the woods.")
        let podcast = show(mutedVoices: [.female], episodes: [ep])
        XCTAssertTrue(podcast.isMuted(ep, voice: .female))
        XCTAssertFalse(podcast.isMuted(ep, voice: .male))
    }

    /// The whole reason for the voice layer: nobody has to add a switch for a narrator the show
    /// has never used before.
    func testAVoiceFilterAppliesToANarratorNeverSeenBefore() {
        let ep = episode("new", summary: "Tonight's story.")
        let podcast = show(mutedVoices: [.female], episodes: [ep])
        XCTAssertTrue(podcast.isMuted(ep, voice: .female),
                      "no per-narrator setup should be required")
    }

    /// A credited episode IS filtered by voice now, and this is the trade that buys it.
    ///
    /// Previously the credited name returned before the gender was consulted, which made the
    /// filter useless on the one show that credits every episode — muting "female" matched
    /// nothing, and the only recourse was muting twenty names by hand. The cost is real and
    /// measured: both models called one actual narrator male at full confidence against her
    /// credited name, so a wrong verdict now hides her episodes. Because verdicts are stored per
    /// NARRATOR rather than per episode, that is one wrong entry rather than one per episode —
    /// but it is still wrong, and it is the reason an unjudged narrator is never muted.
    func testACreditedEpisodeIsFilteredByItsNarratorsVoice() {
        let ep = episode("credited", summary: "Narrator: Elizabeth Grace 🇬🇧")
        let podcast = show(mutedNames: [], mutedVoices: [.male], episodes: [ep])
        XCTAssertTrue(podcast.isMuted(ep, voice: .male),
                      "muting a gender has to reach credited narrators or it does nothing on Get Sleepy")
        XCTAssertFalse(podcast.isMuted(ep, voice: .female))
    }

    func testACreditedNameStillFiltersWhenMutedByName() {
        let ep = episode("credited", summary: "Narrator: Thomas Jones 🇬🇧")
        let podcast = show(mutedNames: ["Thomas Jones"], episodes: [ep])
        XCTAssertTrue(podcast.isMuted(ep, voice: nil))
    }

    /// No reading yet — the episode has not been listened to — must not hide anything.
    func testNoReadingMeansNoFiltering() {
        let ep = episode("unknown", summary: "A story with no credit.")
        let podcast = show(mutedVoices: [.female, .male], episodes: [ep])
        XCTAssertFalse(podcast.isMuted(ep, voice: nil))
    }

    func testNextUnplayedSkipsMutedVoices() {
        let keep = episode("keep", summary: "No credit here.")
        let drop = episode("drop", summary: "No credit here either.")
        var podcast = show(mutedVoices: [.female], episodes: [drop, keep])
        podcast.direction = .oldestFirst
        let readings: [String: VoiceGender] = ["drop": .female, "keep": .male]
        let next = podcast.nextUnplayed(5) { episodeID, _ in readings[episodeID] }
        XCTAssertEqual(next.map(\.id), ["keep"])
    }

    func testTurningTheFilterOffOffersEverythingAgain() {
        let ep = episode("a", summary: "No credit.")
        let podcast = show(mutedVoices: [], episodes: [ep])
        XCTAssertFalse(podcast.isMuted(ep, voice: .female))
    }

    // MARK: - Credited narrators (Get Sleepy, 100% failure)

    /// The reported bug. Every Get Sleepy episode credits its narrator, and the credited branch
    /// returned before `mutedVoiceGenders` was ever consulted — so muting "female" matched nothing
    /// on the one show it was asked for, and the only way to filter was muting all twenty names
    /// by hand.
    func testAGenderMuteAppliesToACreditedNarrator() {
        let podcast = show(mutedVoices: [.female],
                           episodes: [episode("a", summary: "Narrator: Nicola Chapman")])
        let episode = podcast.episodes[0]
        XCTAssertTrue(podcast.isMuted(episode, voice: .female),
                      "a credited narrator must still be filtered by gender")
        XCTAssertFalse(podcast.isMuted(episode, voice: .male))
    }

    /// An explicit name mute is the listener's own decision and still wins, whatever the voice
    /// turns out to be.
    func testAnExplicitNameMuteStillWins() {
        let podcast = show(mutedNames: ["Nicola Chapman"],
                           episodes: [episode("a", summary: "Narrator: Nicola Chapman")])
        XCTAssertTrue(podcast.isMuted(podcast.episodes[0], voice: .male))
    }

    /// Not yet judged must mean "play it", never "guess". Hiding an episode on no evidence is the
    /// one failure the listener cannot see or undo.
    func testANarratorWithNoVerdictYetIsNotMuted() {
        let podcast = show(mutedVoices: [.female],
                           episodes: [episode("a", summary: "Narrator: Someone New")])
        XCTAssertFalse(podcast.isMuted(podcast.episodes[0], voice: nil))
    }

    /// The payoff: one verdict per narrator covers every episode they read, which is what makes
    /// this different from muting names.
    func testOneVerdictCoversEveryEpisodeByThatNarrator() {
        let podcast = show(mutedVoices: [.female], episodes: [
            episode("a", summary: "Narrator: Nicola Chapman"),
            episode("b", summary: "Narrator: Nicola Chapman"),
            episode("c", summary: "Narrator: Ben Bowden"),
        ])
        let roster = podcast.narratorRoster
        let remaining = podcast.nextUnplayed(10) { _, narrator in
            narrator == NarratorCredit.canonical("Nicola Chapman", among: roster) ? .female : .male
        }
        XCTAssertEqual(remaining.count, 1, "both of hers drop out, his stays")
    }
}

/// Correcting a narrator's voice by hand.
///
/// The classifier is wrong about roughly one narrator in ten and sounds equally certain when it
/// is. Without a correction that sticks, a wrong verdict silently hides everything that narrator
/// reads and there is no way to find out why, let alone undo it.
@MainActor
final class NarratorVoiceOverrideTests: XCTestCase {

    private func store() -> NarratorVoiceStore {
        NarratorVoiceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private let judged = NarratorVoiceStore.Reading(
        gender: .male, confidence: 0.95, windowsUsed: 3, decidedAt: Date())

    func testACorrectionBeatsTheClassifier() {
        let store = self.store()
        store.record(judged, for: "ep-1", narrator: "Elizabeth Grace")
        XCTAssertEqual(store.gender(forNarrator: "Elizabeth Grace"), VoiceGender.male)

        store.setOverride(.female, forNarrator: "Elizabeth Grace")
        XCTAssertEqual(store.gender(forNarrator: "Elizabeth Grace"), VoiceGender.female,
                       "the listener's answer wins over a confident wrong guess")
    }

    /// Re-listening must not quietly undo a correction — that would reproduce the same mistake.
    func testALaterVerdictCannotOverwriteACorrection() {
        let store = self.store()
        store.setOverride(.female, forNarrator: "Elizabeth Grace")
        store.record(judged, for: "ep-2", narrator: "Elizabeth Grace")
        XCTAssertEqual(store.gender(forNarrator: "Elizabeth Grace"), VoiceGender.female)
    }

    func testACorrectionCanBeCleared() {
        let store = self.store()
        store.record(judged, for: "ep-1", narrator: "Elizabeth Grace")
        store.setOverride(.female, forNarrator: "Elizabeth Grace")
        store.setOverride(nil, forNarrator: "Elizabeth Grace")
        XCTAssertEqual(store.gender(forNarrator: "Elizabeth Grace"), VoiceGender.male,
                       "clearing falls back to what was judged, not to nothing")
    }

    func testNamesMatchRegardlessOfCasingOrSpacing() {
        let store = self.store()
        store.setOverride(.female, forNarrator: "Elizabeth Grace")
        XCTAssertEqual(store.gender(forNarrator: "  elizabeth grace "), VoiceGender.female)
    }

    /// The point of keying by narrator: one verdict governs everything they read.
    func testAVerdictReachesEveryEpisodeByThatNarrator() {
        let store = self.store()
        store.record(judged, for: "ep-1", narrator: "Ben Bowden")
        XCTAssertEqual(store.voice(episodeID: "never-heard-of-it", narrator: "Ben Bowden"), VoiceGender.male)
    }

    /// An episode that credits nobody still falls back to its own reading.
    func testAnUncreditedEpisodeUsesItsOwnReading() {
        let store = self.store()
        store.record(judged, for: "ep-1")
        XCTAssertEqual(store.voice(episodeID: "ep-1", narrator: nil), VoiceGender.male)
        XCTAssertNil(store.voice(episodeID: "ep-2", narrator: nil))
    }
}

/// The filter used to shape only downloads: "Play next episode", auto-advance, Up Next and the
/// next button went straight to a muted narrator's episode, and the episode list never showed it.
final class NarratorFilterPlaybackTests: XCTestCase {
    private func episode(_ id: String, day: Int, narrator: String?) -> Episode {
        var ep = Episode(id: id, title: id, audioURL: URL(string: "https://example.com/\(id).mp3")!)
        ep.summary = narrator.map { "A story. Narrator: \($0) Writer: Someone" } ?? "A story."
        ep.pubDate = Date(timeIntervalSince1970: Double(day) * 86_400)
        return ep
    }

    private func show(_ episodes: [Episode], mutedNames: Set<String> = [], mutedVoices: Set<VoiceGender> = []) -> Podcast {
        var podcast = Podcast(feedURL: URL(string: "https://example.com/feed")!, title: "Sleepy")
        podcast.episodes = episodes
        podcast.direction = .oldestFirst
        podcast.mutedNarrators = mutedNames
        podcast.mutedVoiceGenders = mutedVoices
        return podcast
    }

    private let voices: [String: VoiceGender] = ["Chloe de Burgh": .female, "Thomas Jones": .male]
    private var lookup: (String, String?) -> VoiceGender? { { _, narrator in narrator.flatMap { self.voices[$0] } } }

    func testNextEpisodeSkipsAMutedVoice() {
        let podcast = show([episode("her", day: 1, narrator: "Chloe de Burgh"),
                            episode("him", day: 2, narrator: "Thomas Jones")], mutedVoices: [.female])
        XCTAssertEqual(podcast.nextEpisode(voiceOf: lookup)?.id, "him")
    }

    func testTheEpisodeInProgressIsSkippedToo() {
        var podcast = show([episode("her", day: 1, narrator: "Chloe de Burgh"),
                            episode("him", day: 2, narrator: "Thomas Jones")], mutedVoices: [.female])
        podcast.currentEpisodeID = "her"
        XCTAssertEqual(podcast.nextEpisode(voiceOf: lookup)?.id, "him")
    }

    func testWithoutAFilterNothingIsSkipped() {
        let podcast = show([episode("her", day: 1, narrator: "Chloe de Burgh"),
                            episode("him", day: 2, narrator: "Thomas Jones")])
        XCTAssertEqual(podcast.nextEpisode(voiceOf: lookup)?.id, "her")
        XCTAssertFalse(podcast.hasVoiceFilter)
    }

    func testANameMuteIgnoresCapitals() {
        let podcast = show([episode("a", day: 1, narrator: "Chloe de Burgh")], mutedNames: ["Chloe De Burgh"])
        XCTAssertTrue(podcast.isSkipped(podcast.episodes[0], roster: podcast.narratorRoster, voiceOf: { _, _ in nil }))
    }

    func testSpellingsThatDifferOnlyInCapitalsAreOnePerson() {
        let roster: Set<String> = ["Chloe De Burgh", "Chloe de Burgh", "Thomas Jones"]
        XCTAssertEqual(NarratorCredit.canonical("Chloe", among: roster), "Chloe De Burgh")
        XCTAssertEqual(NarratorCredit.canonical("chloe de burgh", among: roster), "Chloe De Burgh")
    }
}
