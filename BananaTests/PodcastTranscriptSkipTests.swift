import XCTest

/// The two transcript-level skip detectors: `PodcastBoilerplateCorpus` (stage 2 — the wording a
/// show repeats at the top of every episode, and where it stops) and `PodcastSponsorSlate`
/// (stage 3 — host-read sponsor messages).
///
/// Most of what is asserted here is that nothing is cut. That is the point of both detectors: the
/// passages below are the real ones from the measurement corpus that fooled every simpler
/// approach tried before these — two hosts spending eighty seconds on a Formula One title
/// *sponsor*, an episode whose subject shares a name with a sponsor, an ad that names its sponsor
/// and says the word "sponsors" out loud but skips the script. Each is quoted verbatim from the
/// transcript it came from, so that a change which starts cutting them fails here rather than in
/// someone's ears.
final class PodcastTranscriptSkipTests: XCTestCase {

    private let show = UUID()

    /// Timings the detectors can use without a real transcript. Every threshold that touches time
    /// here (the 15 s naming window, the 180 s read window) is far larger than any passage below,
    /// so an even cadence changes nothing about what is found.
    private func words(_ text: String, from start: TimeInterval = 0,
                       cadence: TimeInterval = 0.4) -> [SpokenWord] {
        var out: [SpokenWord] = []
        var t = start
        for token in text.split(separator: " ") {
            out.append(SpokenWord(text: String(token), start: t, end: t + cadence))
            t += cadence
        }
        return out
    }

    // MARK: - Passages from the measurement corpus

    /// Acquired, "Ferrari", 12119–12163 s. Ground truth: not an ad. This is the control the
    /// research called out by name — the hosts are discussing Ferrari's revenue segments, and the
    /// word "sponsor" appears three times ("sponsorship" twice, then HP as "the title sponsor").
    /// A keyword detector cuts it. This one must not.
    private let titleSponsorControl = """
        though, is sponsorship, commercial, and brand. The Formula One team. Yeah, I was going to \
        say, the commercial and brand, this is sort of where their lifestyle stuff is the fashion, \
        but really the interesting bit here is sponsorship. Formula One for them is a profit \
        generating center that is also the single best marketing dollars they could ever spend. \
        Yes. Thank you, Liberty Media, and their stewardship of Formula One. Like overnight in the \
        last 10 years, Formula One went from just a marketing spend for Ferrari, two, the best \
        marketing activity they do, and a real meaningful profit center. Yep, I mean, the HP deal \
        alone, the title sponsor of the team is
        """

    /// Acquired, "Ferrari", 13030–13060 s. Ground truth: not an ad. The brand-collision case: the
    /// episode's own subject is a brand, said seven times in thirty seconds. If "Ferrari" were
    /// ever learned as a sponsor of this show — and one of this show's sponsors did read an ad
    /// built entirely around Ferrari — a brand-name detector would cut the episode itself.
    private let subjectIsTheBrandControl = """
        mean, it's astonishing calling back to our F1 episode. Ferrari is the most popular F1 team \
        in the world. By a large margin. And hasn't really won much since Michael Schumacher. \
        Yeah, and sells the most expensive cars that the vast, vast majority of their fans will \
        never be able to buy. absolutely exclusionary. I bet a lot of fans of the Mercedes racing \
        team, one way or another, can find a way to buy a Mercedes. Almost none of the fans of \
        Ferrari can find a way to buy a Ferrari. All right, you just pulled
        """

    /// Acquired, "Vanguard", 8592–8636 s. Ground truth: this IS an ad — and it is the one the
    /// detector is measured as missing. It names a slate sponsor, it says "sponsors" out loud, and
    /// it is woven into an analogy about the episode's own subject instead of using the script.
    /// Declining it is the accepted cost of the pairing rule; a missed ad leaves the listener
    /// exactly where they were.
    private let wovenAdWithoutTheScript = """
        or worse. The feature ships, everyone moves on, and you never really close the loop. So \
        listeners, if you haven't guessed by now, Statzig is one of our sponsors this episode. \
        This problem that we are describing gets way harder when AI is involved. LLMs are \
        nondeterministic, meaning that the same prompt doesn't always produce the same output, and \
        small changes to a user flow or a prompt can have surprisingly large downstream effects.
        """

    /// Acquired, "Vanguard", 1874–1884 s: the scripted hand-off, verbatim.
    private let scriptedHandoff = """
        But before we tell that story, now is a great time to thank our presenting partner, J.P. \
        Morgan. Yes. And today, listeners, we are going
        """

    /// Acquired, "Vanguard", 1980–1987 s: the call to action the read ends on.
    private let handoffPayoff = """
        accelerator platform, go to jpmorgan.com slash acquired or contact your JP Morgan rep and \
        tell them that Ben and
        """

    /// The other three hand-off shapes the same show uses, verbatim from "Vanguard" and "Ferrari".
    private let otherHandoffs = [
        "now is a great time to thank our longtime friend of the show, service now. Yes, it is.",
        "now is a great time to thank one of our favorite partners, Versell. So for 20 years,",
        "now is a great time to tell you about one of our favorite companies, Statzig. Yes. So listeners,",
    ]

    // MARK: - Stage 3: both halves are required

    private func slateLearnedFromAnEarlierEpisode() -> PodcastSponsorSlate {
        var slate = PodcastSponsorSlate(podcastID: show)
        slate.learn(episodeID: "earlier", words: words(scriptedHandoff))
        for (i, handoff) in otherHandoffs.enumerated() {
            slate.learn(episodeID: "earlier-\(i)", words: words(handoff))
        }
        return slate
    }

    func testSlateIsLearnedFromTheHandoffPositionOnly() {
        let slate = slateLearnedFromAnEarlierEpisode()
        XCTAssertEqual(slate.sponsors.map(\.name),
                       ["J.P. Morgan", "service now", "Versell", "Statzig"])
    }

    /// The control the 100 %-precision figure was measured against. Three uses of the word
    /// "sponsor", no scripted hand-off, no learned brand.
    func testTitleSponsorDiscussionIsNotCut() {
        let slate = slateLearnedFromAnEarlierEpisode()
        XCTAssertTrue(titleSponsorControl.lowercased().contains("sponsor"))
        XCTAssertEqual(slate.spans(in: words(titleSponsorControl), episodeID: "this"), [])
    }

    /// Brand collision. Even with the episode's own subject wrongly sitting in the slate, the
    /// missing hand-off means nothing is cut — which is why the sponsor half can never fire alone.
    func testASponsorThatIsAlsoTheEpisodesSubjectIsNotCut() {
        var slate = PodcastSponsorSlate(podcastID: show)
        slate.learn(episodeID: "earlier",
                    words: words("now is a great time to thank our presenting partner, Ferrari. Yes."))
        XCTAssertEqual(slate.sponsors.map(\.name), ["Ferrari"])

        let spans = slate.spans(in: words(subjectIsTheBrandControl), episodeID: "this")
        XCTAssertEqual(spans, [], "the brand is said seven times; without the script it is the subject, not an ad")
    }

    /// The learned-sponsor half alone is not enough either, even inside a real ad.
    func testSponsorNamedWithoutTheScriptedHandoffIsLeftAlone() {
        let slate = slateLearnedFromAnEarlierEpisode()
        XCTAssertTrue(wovenAdWithoutTheScript.contains("sponsors"))
        XCTAssertEqual(slate.spans(in: words(wovenAdWithoutTheScript), episodeID: "this"), [])
    }

    /// And the hand-off half alone is not enough.
    func testHandoffWithAnUnknownBrandIsLeftAlone() {
        var slate = PodcastSponsorSlate(podcastID: show)
        slate.learn(episodeID: "earlier", words: words(scriptedHandoff))

        let unknown = words("now is a great time to thank our presenting partner, Northwind Analytics. Yes. And today,")
        XCTAssertEqual(slate.spans(in: unknown, episodeID: "this"), [])
    }

    func testBothHalvesTogetherCutTheReadAndNameTheSponsor() {
        let slate = slateLearnedFromAnEarlierEpisode()
        let episode = words(scriptedHandoff + " " + handoffPayoff)

        let spans = slate.spans(in: episode, episodeID: "this")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.source, .sponsorRead)
        XCTAssertEqual(spans.first?.kind, .hostReadAd)
        XCTAssertEqual(spans.first?.confidence, .automatic)
        // Required, not decoration: one correction retires one sponsor on one show, and without
        // this the correction would retire host-read ads for the whole show.
        XCTAssertEqual(spans.first?.sponsor, "J.P. Morgan")

        // Starts on the hand-off's first word ("now"), which is index 6 of this passage.
        XCTAssertEqual(spans.first?.start ?? -1, episode[6].start, accuracy: 0.001)
        // Ends on the last time the brand is said — the call to action — not on the sign-off after
        // it. Stopping a beat early is the safe side of the boundary.
        XCTAssertLessThan(spans.first?.end ?? .greatestFiniteMagnitude, episode.last!.end)
    }

    /// An episode may not vouch for itself. Otherwise the first episode of any show would learn
    /// its own sponsors and immediately cut them, with no earlier episode having confirmed
    /// anything — which is the corroboration the whole stage rests on.
    func testAnEpisodeCannotCorroborateItself() {
        var slate = PodcastSponsorSlate(podcastID: show)
        let episode = words(scriptedHandoff + " " + handoffPayoff)
        slate.learn(episodeID: "this", words: episode)

        XCTAssertEqual(slate.sponsors.map(\.name), ["J.P. Morgan"])
        XCTAssertEqual(slate.spans(in: episode, episodeID: "this"), [])
    }

    // MARK: - Stage 3: brand matching and the learning loop

    /// The recogniser hears the same brand differently every week. These are the actual variants
    /// it produced across the two measured episodes.
    func testBrandFoldingAbsorbsTheRecognisersMishearings() {
        XCTAssertEqual(PodcastSponsorSlate.folded("Vercel"), PodcastSponsorSlate.folded("Versell"))
        XCTAssertEqual(PodcastSponsorSlate.folded("Statsig"), PodcastSponsorSlate.folded("Statzig"))
        XCTAssertEqual(PodcastSponsorSlate.folded("ServiceNow"), PodcastSponsorSlate.folded("service now"))
        // Not a general fuzzy match: two unrelated brands must not fold together.
        XCTAssertNotEqual(PodcastSponsorSlate.folded("Vercel"), PodcastSponsorSlate.folded("Statsig"))
        XCTAssertNotEqual(PodcastSponsorSlate.folded("Vercel"), PodcastSponsorSlate.folded("Ferrari"))
    }

    func testRetiringOneSponsorLeavesTheRestOfTheSlate() {
        var slate = slateLearnedFromAnEarlierEpisode()
        slate.retire(sponsorNamed: "Vercel")   // spelled as a human would, not as the recogniser did

        XCTAssertEqual(slate.sponsors.map(\.name), ["J.P. Morgan", "service now", "Statzig"])
        XCTAssertEqual(slate.spans(in: words(otherHandoffs[1] + " Versell is fast."), episodeID: "this"), [])
    }

    func testCorruptSlateEntryDropsThatSponsorAndNotTheShow() {
        var library = PodcastSponsorLibrary()
        library.learn(podcastID: show, episodeID: "earlier", words: words(scriptedHandoff))
        let encoded = try! JSONEncoder().encode(library)

        let restored = try! JSONDecoder().decode(PodcastSponsorLibrary.self, from: encoded)
        XCTAssertEqual(restored[show].sponsors.map(\.name), ["J.P. Morgan"])

        let damaged = Data(#"{"slates":{"\#(show.uuidString)":{"podcastID":"not-a-uuid"}}}"#.utf8)
        XCTAssertEqual((try? JSONDecoder().decode(PodcastSponsorLibrary.self, from: damaged))?.slates.count, 0)
    }

    // MARK: - Stage 2a: the eight-word floor

    private func corpus(learning openings: [String]) -> PodcastBoilerplateCorpus {
        var corpus = PodcastBoilerplateCorpus(podcastID: show)
        for (i, text) in openings.enumerated() { corpus.learn(episodeID: "e\(i)", words: words(text)) }
        return corpus
    }

    /// The floor is load-bearing: at three-to-five words the same corpus produced 147 spurious
    /// blocks, because ordinary speech repeats short phrases constantly. Seven words repeated
    /// across three episodes is still ordinary speech.
    func testASevenWordRepeatProducesNothing() {
        let shared = "thanks so much for tuning in tonight"
        XCTAssertEqual(shared.split(separator: " ").count, 7)

        let corpus = self.corpus(learning: ["\(shared) alpha bravo charlie delta",
                                            "\(shared) foxtrot golf hotel india"])
        XCTAssertEqual(corpus.repeatedBoilerplateSpans(in: words("\(shared) kilo lima mike november"),
                                                       episodeID: "this"),
                       [])
    }

    func testAnEightWordRepeatProducesExactlyThatSpan() {
        let shared = "thanks so much for tuning in again tonight"
        XCTAssertEqual(shared.split(separator: " ").count, PodcastBoilerplateCorpus.repeatedPhraseWordFloor)

        let corpus = self.corpus(learning: ["\(shared) alpha bravo charlie delta",
                                            "\(shared) foxtrot golf hotel india"])
        let episode = words("\(shared) kilo lima mike november")
        let spans = corpus.repeatedBoilerplateSpans(in: episode, episodeID: "this")

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.source, .repeatedBoilerplate)
        XCTAssertEqual(spans.first?.start ?? -1, episode[0].start, accuracy: 0.001)
        XCTAssertEqual(spans.first?.end ?? -1, episode[7].end, accuracy: 0.001)
    }

    /// Two episodes is a coincidence. Three is a pattern.
    func testAPhraseInOnlyTwoEpisodesProducesNothing() {
        let shared = "thanks so much for tuning in again tonight friends"
        var corpus = PodcastBoilerplateCorpus(podcastID: show)
        corpus.learn(episodeID: "e0", words: words("\(shared) alpha bravo charlie"))

        XCTAssertEqual(corpus.repeatedBoilerplateSpans(in: words("\(shared) delta echo foxtrot"),
                                                       episodeID: "this"),
                       [])
    }

    /// Get Sleepy's network promo, verbatim across three episodes of the show. The one block the
    /// verbatim rule is supposed to find.
    func testTheNetworkPromoIsFoundAndLabelledAsOne() {
        let promo = """
            Get Sleepy is a production of Somber Studios. To listen at free, access our entire \
            catalog of episodes and support the show directly. Check out our premium feed by going \
            to get sleepy.com slash support. Now, a quick word from our sponsors.
            """
        let corpus = self.corpus(learning: ["\(promo) Ultra running shoes are all about space,",
                                            "\(promo) This episode is brought to you by Facebook."])

        let episode = words("\(promo) Tonight's story begins in a quiet garden.")
        let spans = corpus.repeatedBoilerplateSpans(in: episode, episodeID: "this")

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.kind, .networkPromo)
        XCTAssertEqual(spans.first?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(spans.first?.end ?? -1, episode[promo.split(separator: " ").count - 1].end, accuracy: 0.001)
    }

    // MARK: - Stage 2b: the tagline, and where it stops

    /// The four readings of one tagline, as the recogniser actually transcribed them across four
    /// episodes of Get Sleepy. No two agree: "where we listen" comes back as "when we listen" and
    /// "where we lessen", and the show's own name lands as both "Sleepy" and "Sleeping". A verbatim
    /// match finds none of it, which is why 2b votes instead.
    private let taglineReadings = [
        "ep1": "Welcome, to get sleeping, where we listen, we relax, and we get sleepy. Thanks so much for tuning in.",
        "ep2": "Welcome to Get Sleeping, where we listen. We relax, and we get sleepy. My name's Thomas, and I'm your host.",
        "ep3": "Welcome to Get Sleepy. When we listen. We relax, and we get sleeping. As always, my name's Thomas and I'm your host.",
        "hive": "Welcome to Get Sleeping, where we lessen. We relax, and we get sleepy. I'm your host, Thomas.",
    ]

    private func taglineCorpus(excluding target: String) -> PodcastBoilerplateCorpus {
        var corpus = PodcastBoilerplateCorpus(podcastID: show)
        for (id, text) in taglineReadings.sorted(by: { $0.key < $1.key }) where id != target {
            corpus.learn(episodeID: id, words: words(text))
        }
        return corpus
    }

    func testTheTaglineSurvivesTheRecognisersVariance() {
        let episode = words(taglineReadings["ep1"]!)
        let span = taglineCorpus(excluding: "ep1").taglineSpan(in: episode, episodeID: "ep1")

        XCTAssertEqual(span?.source, .taglineBoundary)
        XCTAssertEqual(span?.kind, .showOpening)
        XCTAssertEqual(span?.start ?? -1, episode[0].start, accuracy: 0.001)
        // Ends on "sleepy." — the thirteenth word — and not on the thanks that follows it.
        XCTAssertEqual(span?.end ?? -1, episode[12].end, accuracy: 0.001)
    }

    /// The eight-word floor doing the second job it was hired for. "My name's Thomas, and I'm your
    /// host" is confirmed across episodes too, and at seven words it is not cut — so the opening
    /// stops at the tagline instead of running on into whatever the host says next.
    func testTheHostsOwnIntroductionIsNotSweptIntoTheTagline() {
        let episode = words(taglineReadings["ep2"]!)
        let span = taglineCorpus(excluding: "ep2").taglineSpan(in: episode, episodeID: "ep2")

        XCTAssertNotNil(span)
        XCTAssertEqual(span?.end ?? -1, episode[12].end, accuracy: 0.001)
        let cutText = episode.prefix { $0.end <= (span?.end ?? 0) }.map(\.text).joined(separator: " ")
        XCTAssertFalse(cutText.contains("Thomas"))
    }

    func testATaglineNoOtherEpisodeConfirmsProducesNothing() {
        var corpus = PodcastBoilerplateCorpus(podcastID: show)
        corpus.learn(episodeID: "e0", words: words("Some other show says something else entirely tonight, friends."))
        corpus.learn(episodeID: "e1", words: words("And a third show says a third completely different thing."))

        XCTAssertNil(corpus.taglineSpan(in: words(taglineReadings["ep1"]!), episodeID: "this"))
    }

    // MARK: - Stage 2c: the music bed

    /// The measured beds ran 16.3 s, 24.2 s and 24.3 s. A gap over the floor, inside the horizon,
    /// extends the opening to the first word on the far side of it.
    func testASilentGapExtendsTheOpeningToTheEndOfTheBed() {
        var episode = words("we relax and we get sleepy", from: 80)
        episode.append(SpokenWord(text: "A", start: 106, end: 106.3))

        let span = PodcastBoilerplateCorpus.silenceExtensionSpan(in: episode, openingEnd: episode[5].end)
        XCTAssertEqual(span?.source, .silenceExtension)
        XCTAssertEqual(span?.kind, .showOpening)
        XCTAssertEqual(span?.start ?? -1, episode[5].end, accuracy: 0.001)
        XCTAssertEqual(span?.end ?? -1, 106, accuracy: 0.001)
    }

    /// One of the four episodes measured runs its intro straight into its story with no bed at
    /// all, and this detector correctly produced nothing on it. Without a gap there is no
    /// boundary, and inventing one deletes the opening of the story.
    func testNoGapProducesNoExtension() {
        var episode = words("we relax and we get sleepy", from: 80)
        episode.append(contentsOf: words("and this is where our story begins tonight", from: 82.4))

        XCTAssertNil(PodcastBoilerplateCorpus.silenceExtensionSpan(in: episode, openingEnd: episode[5].end))
    }

    /// A gap just under the floor is not a bed either. Get Sleepy has a 4.5 s pause between its ad
    /// pod and its tagline; treating that as the end of the opening would cut the tagline out of
    /// the corpus and everything after it into the skip.
    func testAGapUnderTheFloorProducesNoExtension() {
        var episode = words("we relax and we get sleepy", from: 80)
        episode.append(SpokenWord(text: "Welcome", start: 82.4 + PodcastBoilerplateCorpus.silentGapFloor - 1,
                                  end: 83 + PodcastBoilerplateCorpus.silentGapFloor))

        XCTAssertNil(PodcastBoilerplateCorpus.silenceExtensionSpan(in: episode, openingEnd: episode[5].end))
    }

    /// The horizon is what keeps this off a pause inside the story. The one episode with no bed
    /// has its first long gap at 316 s, and treating that as an opening boundary would have
    /// deleted four minutes of the thing the listener came for.
    func testAGapPastTheHorizonProducesNoExtension() {
        var episode = words("we relax and we get sleepy", from: 80)
        episode.append(SpokenWord(text: "Just", start: 340, end: 340.4))

        XCTAssertNil(PodcastBoilerplateCorpus.silenceExtensionSpan(in: episode, openingEnd: episode[5].end))
    }

    // MARK: - The three stages together

    /// The real shape of a Get Sleepy episode: a fixed network promo, then an ad slot filled
    /// differently on every download, then the tagline, then the music bed. Each stage finds its
    /// own part and they arrive in playback order.
    func testOpeningSpansChainPromoThenTaglineThenBed() {
        let promo = """
            Get Sleepy is a production of Somber Studios. To listen at free, access our entire \
            catalog of episodes and support the show directly. Now, a quick word from our sponsors.
            """
        // Different creative per download — the reason the promo and the tagline are two findings
        // and not one, and the reason a verbatim match cannot bridge them.
        let adSlots = ["ep2": "This episode is brought to you by a running shoe.",
                       "ep3": "The award winning airline programme rewards more than travel.",
                       "hive": "Whatever it takes on game day, it matters where you stay."]

        var corpus = PodcastBoilerplateCorpus(podcastID: show)
        for (id, tagline) in taglineReadings.sorted(by: { $0.key < $1.key }) where id != "ep1" {
            corpus.learn(episodeID: id, words: words("\(promo) \(adSlots[id]!) \(tagline)"))
        }

        var episode = words("\(promo) A different advert entirely fills this slot today. \(taglineReadings["ep1"]!)")
        episode.append(SpokenWord(text: "Tonight", start: episode.last!.end + 20, end: episode.last!.end + 20.4))

        let spans = corpus.openingSpans(in: episode, episodeID: "ep1")
        XCTAssertEqual(spans.map(\.source), [.repeatedBoilerplate, .taglineBoundary, .silenceExtension])
        guard spans.count == 3 else { return }
        XCTAssertEqual(spans[0].kind, .networkPromo)
        // Contiguous and in order, so `EpisodeSkipPlan.destination(from:)` collapses the tagline
        // and the bed into one jump instead of two visible stutters.
        XCTAssertEqual(spans[1].end, spans[2].start, accuracy: 0.001)
        XCTAssertEqual(spans[2].end, episode.last!.start, accuracy: 0.001)
        // The ad slot between them belongs to the stages that read the audio, not this one.
        XCTAssertLessThan(spans[0].end, spans[1].start)
    }

    // MARK: - The corpus on disk

    func testCorpusRoundTripsAndAnUnreadableOneMeansNoBoilerplateKnown() {
        var library = PodcastBoilerplateLibrary()
        library.learn(podcastID: show, episodeID: "e0", words: words("one two three four five six seven eight"))
        let encoded = try! JSONEncoder().encode(library)

        XCTAssertEqual(try! JSONDecoder().decode(PodcastBoilerplateLibrary.self, from: encoded)[show]
            .learnedEpisodeCount, 1)

        // A corpus that cannot be read costs skips and never costs content: the show degrades to
        // "no boilerplate known" and every other detector on the episode is untouched.
        let damaged = Data(#"{"corpora":{"\#(show.uuidString)":{"openings":"not an array"}}}"#.utf8)
        let salvaged = try? JSONDecoder().decode(PodcastBoilerplateLibrary.self, from: damaged)
        XCTAssertEqual(salvaged?.corpora.count, 0)
        XCTAssertEqual(salvaged?[show].learnedEpisodeCount ?? -1, 0)
    }

    func testCorpusKeepsOnlyTheMostRecentEpisodes() {
        var corpus = PodcastBoilerplateCorpus(podcastID: show)
        for i in 0..<(PodcastBoilerplateCorpus.retainedEpisodeCount + 4) {
            corpus.learn(episodeID: "e\(i)", words: words("one two three four five six seven eight nine"))
        }
        XCTAssertEqual(corpus.learnedEpisodeCount, PodcastBoilerplateCorpus.retainedEpisodeCount)
        XCTAssertEqual(corpus.openings.first?.episodeID, "e4")
    }

    /// Re-transcribing an episode replaces its entry rather than letting the same episode count
    /// twice towards the three-episode floor.
    func testRelearningAnEpisodeReplacesItRatherThanCorroborating() {
        let shared = "thanks so much for tuning in again tonight friends"
        var corpus = PodcastBoilerplateCorpus(podcastID: show)
        corpus.learn(episodeID: "e0", words: words("\(shared) alpha bravo"))
        corpus.learn(episodeID: "e0", words: words("\(shared) alpha bravo"))

        XCTAssertEqual(corpus.learnedEpisodeCount, 1)
        XCTAssertEqual(corpus.repeatedBoilerplateSpans(in: words("\(shared) charlie delta"), episodeID: "this"),
                       [])
    }
}
