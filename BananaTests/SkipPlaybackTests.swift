import XCTest

/// The decision half of automatic ad skipping (`Banana/Model/SkipPlaybackEngine.swift`) plus the
/// persistence rules around it (`Banana/Model/SkipPlanStore.swift`).
///
/// Tested here rather than through `PlayerController` for the usual reason this project splits
/// logic out of its players: `PlayerController` is an AVPlayer, an audio session, a Lock Screen,
/// a CloudKit progress sync and a Watch link, and none of that has an opinion about whether a
/// rewind means the feature got something wrong. `SkipPlanStore` is included because it is
/// Foundation-only and takes its directory as a parameter, so every case here runs against a
/// throwaway temp folder and never touches real listening data.
// `SkipPlanStore` and `SkipCorrectionBook`'s owner are main-actor isolated, because they are read
// and written from the player and the UI. The tests exercise them directly, so the case is too.
@MainActor
final class SkipPlaybackTests: XCTestCase {

    private let show = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func span(_ start: Double, _ end: Double,
                      source: SkipSource = .encoderSeam,
                      kind: SkipKind = .adPod,
                      confidence: SkipConfidence = .automatic,
                      sponsor: String? = nil) -> SkipSpan {
        SkipSpan(start: start, end: end, kind: kind, source: source,
                 confidence: confidence, sponsor: sponsor)
    }

    private func plan(_ spans: [SkipSpan], bytes: Int64? = nil) -> EpisodeSkipPlan {
        EpisodeSkipPlan(episodeID: "ep-1", podcastID: show, spans: spans,
                        engineVersion: EpisodeSkipPlan.currentEngineVersion,
                        builtAt: Date(), audioByteCount: bytes)
    }

    private func makeTempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The user-seek distinction

    /// The single most important behaviour in the feature. A jump lands the playhead exactly
    /// where a rewind would be measured from, so if a skip's own seek were fed back as a user
    /// seek, every detector would be demoted by its own successes and automatic skipping would
    /// switch itself off show by show. `PlayerController` keeps this structural — the jump calls
    /// the private seek, never `seek(to:)` — and this asserts the engine side of the same rule.
    func testSkipCausedSeekDoesNotRegisterACorrection() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 30)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        let now = Date()
        let performed = engine.jump(from: 0, now: now)
        XCTAssertEqual(performed?.to, 30)

        // Replaying the jump's own destination through the user path — what a careless wiring of
        // "tell the watcher about every seek" would do — must teach nothing.
        XCTAssertNil(engine.userSeeked(to: performed!.to, now: now.addingTimeInterval(0.05)))
    }

    func testUserRewindIntoAJustSkippedSpanRegistersACorrection() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 30)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        let now = Date()
        XCTAssertNotNil(engine.jump(from: 0, now: now))

        let corrected = engine.userSeeked(to: 12, now: now.addingTimeInterval(4))
        XCTAssertEqual(corrected?.source, .encoderSeam)
        XCTAssertEqual(corrected?.start, 0)
    }

    /// Someone rewinding half a minute later is navigating, not objecting. Counting it would
    /// retire good detectors on ordinary scrubbing.
    func testRewindLongAfterTheSkipIsNotACorrection() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 30)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        let now = Date()
        XCTAssertNotNil(engine.jump(from: 0, now: now))

        XCTAssertNil(engine.userSeeked(to: 12, now: now.addingTimeInterval(120)))
    }

    /// Skipping ahead past where the jump left you is navigation, not an objection to it.
    func testSeekPastTheSkippedStretchIsNotACorrection() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(60, 90)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        let now = Date()
        XCTAssertNotNil(engine.jump(from: 60, now: now))
        XCTAssertNil(engine.userSeeked(to: 95, now: now.addingTimeInterval(2)))
    }

    /// Having rewound into a skip, playing on must not send you forward again a second later.
    func testASpanRewoundIntoStopsSkippingForTheRestOfTheEpisode() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 30)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        let now = Date()
        XCTAssertNotNil(engine.jump(from: 0, now: now))
        let corrected = engine.userSeeked(to: 12, now: now.addingTimeInterval(3))
        engine.demoteForSession(engine.collapsedRun(containing: corrected!))

        XCTAssertNil(engine.jump(from: 12, now: now.addingTimeInterval(4)))
    }

    // MARK: - Collapsing

    func testAdjacentSpansCollapseIntoOneJump() {
        var engine = SkipPlaybackEngine()
        // An ad pod running straight into a network promo: one move, not two visible stutters.
        engine.load(plan([span(0, 30, source: .declaredByHost),
                          span(30, 45, source: .encoderSeam, kind: .networkPromo)]),
                    corrections: SkipCorrectionBook(), audioByteCount: nil)

        let performed = engine.jump(from: 0)
        XCTAssertEqual(performed?.to, 45)
        XCTAssertEqual(performed?.spans.count, 2)
        XCTAssertEqual(performed?.label, "Ad + Promo")
    }

    /// A gap wider than the collapse tolerance is two separate jumps, and rejecting one must not
    /// silently stop the other.
    func testSeparatedSpansAreTwoJumpsAndDemoteIndependently() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 30), span(600, 640, source: .sponsorRead, kind: .hostReadAd)]),
                    corrections: SkipCorrectionBook(), audioByteCount: nil)

        XCTAssertEqual(engine.jump(from: 0)?.to, 30)
        XCTAssertEqual(engine.collapsedRun(containing: span(0, 30)).count, 1)

        engine.demoteForSession([span(0, 30)])
        XCTAssertEqual(engine.jump(from: 600)?.to, 640, "the later sponsor read is untouched")
    }

    /// One rewind is one fact about one detector — but the *move* it objected to stops entirely.
    func testRewindIntoOneSpanOfACollapsedJumpStopsTheWholeRun() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 30, source: .declaredByHost),
                          span(30, 45, source: .encoderSeam)]),
                    corrections: SkipCorrectionBook(), audioByteCount: nil)

        let now = Date()
        XCTAssertNotNil(engine.jump(from: 0, now: now))
        let corrected = engine.userSeeked(to: 35, now: now.addingTimeInterval(2))
        XCTAssertEqual(corrected?.source, .encoderSeam, "the span actually landed in")

        let run = engine.collapsedRun(containing: corrected!)
        XCTAssertEqual(run.count, 2)
        engine.demoteForSession(run)
        XCTAssertNil(engine.jump(from: 0), "the move they rejected does not happen again")
    }

    // MARK: - Plan validity

    /// Ad pods are stitched per download. A plan built against one copy is not stale for another
    /// copy — it is an accurate description of a different file, and acting on it cuts content at
    /// the offsets where the other copy's ads happened to sit.
    func testPlanBuiltAgainstDifferentBytesIsRejected() {
        var engine = SkipPlaybackEngine()
        XCTAssertFalse(engine.load(plan([span(0, 30)], bytes: 48_000_000),
                                   corrections: SkipCorrectionBook(),
                                   audioByteCount: 51_500_000))
        XCTAssertNil(engine.plan)
        XCTAssertNil(engine.jump(from: 0))
    }

    func testPlanMatchingTheBytesInHandIsAccepted() {
        var engine = SkipPlaybackEngine()
        XCTAssertTrue(engine.load(plan([span(0, 30)], bytes: 48_000_000),
                                  corrections: SkipCorrectionBook(),
                                  audioByteCount: 48_000_000))
        XCTAssertEqual(engine.jump(from: 0)?.to, 30)
    }

    /// An unknown byte count is not evidence of a mismatch. The check exists to catch a *known*
    /// difference, not to throw plans away for want of a number.
    func testUnknownByteCountLeavesAPlanUsable() {
        var engine = SkipPlaybackEngine()
        XCTAssertTrue(engine.load(plan([span(0, 30)], bytes: 48_000_000),
                                  corrections: SkipCorrectionBook(), audioByteCount: nil))
    }

    func testStoreDropsAPlanWhoseBytesNoLongerMatch() throws {
        let dir = try makeTempDirectory("AdSkip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkipPlanStore(directory: dir)
        store.store(StoredSkipPlan(plan: plan([span(0, 30)], bytes: 48_000_000),
                                   usedDeclaredSlots: true))

        XCTAssertNotNil(store.plan(for: "ep-1", audioByteCount: 48_000_000))
        XCTAssertNil(store.plan(for: "ep-1", audioByteCount: 12_345))
        XCTAssertNil(store.record(for: "ep-1"), "a rejected plan is dropped, not left to be found again")
    }

    // MARK: - The fixed pre-roll

    /// The show's `autoSkipSeconds` and an automatic plan are two answers to the same question.
    /// Applying both starts playback past the plan's own spans, so the plan never fires and
    /// whatever sat between the guess and the truth is gone.
    func testPlanCoveringTheOpeningSupersedesTheFixedPreRoll() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 82)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        XCTAssertTrue(engine.supersedesFixedPreRoll(ofSeconds: 30))
        // And the plan alone gets the listener to the same place, in one move.
        XCTAssertEqual(engine.jump(from: 0)?.to, 82)
    }

    /// A plan that only found a host-read sponsor halfway in says nothing about the opening, so
    /// the show's own setting is left exactly as it was.
    func testPlanWithNothingInTheOpeningLeavesTheFixedPreRollAlone() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(600, 640, source: .sponsorRead, kind: .hostReadAd)]),
                    corrections: SkipCorrectionBook(), audioByteCount: nil)

        XCTAssertFalse(engine.supersedesFixedPreRoll(ofSeconds: 30))
    }

    func testARejectedPlanNeverSupersedesTheFixedPreRoll() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 82)], bytes: 1), corrections: SkipCorrectionBook(), audioByteCount: 2)

        XCTAssertFalse(engine.supersedesFixedPreRoll(ofSeconds: 30),
                       "a plan that does not describe these bytes cannot own this show's opening")
    }

    // MARK: - Corrections applied at load

    func testADetectorRetiredOnThisShowStopsSkippingSilently() {
        var book = SkipCorrectionBook()
        let sponsorSpan = span(600, 640, source: .sponsorRead, kind: .hostReadAd, sponsor: "Vanta")
        // A sponsor read that collides with an episode's subject is wrong the first time and
        // wrong every time after, so its threshold is one.
        book.recordCorrection(for: sponsorSpan, podcastID: show)

        var engine = SkipPlaybackEngine()
        engine.load(plan([sponsorSpan]), corrections: book, audioByteCount: nil)

        XCTAssertNil(engine.jump(from: 600))
        XCTAssertEqual(engine.plan?.spans.first?.confidence, .offered, "still visible, just not silent")
    }

    func testTheMasterSwitchStopsEverythingWithoutDiscardingThePlan() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(0, 30)]), corrections: SkipCorrectionBook(), audioByteCount: nil)
        engine.isEnabled = false

        XCTAssertNil(engine.jump(from: 0))
        XCTAssertFalse(engine.supersedesFixedPreRoll(ofSeconds: 30))
        XCTAssertNotNil(engine.plan, "the episode screen still has something honest to show")
    }

    // MARK: - Store durability

    /// The correction book is the only record of every time Banana got a skip wrong, it cannot be
    /// recomputed, and nobody is going to sit through the same wrong skip twice to teach it again.
    func testCorrectionsSurviveAReload() throws {
        let dir = try makeTempDirectory("AdSkip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sponsorSpan = span(600, 640, source: .sponsorRead, kind: .hostReadAd, sponsor: "Vanta")

        SkipPlanStore(directory: dir).recordCorrection(for: sponsorSpan, podcastID: show)

        let reloaded = SkipPlanStore(directory: dir)
        XCTAssertEqual(reloaded.retiredDetectors(forShow: show), [.sponsorRead])
        XCTAssertFalse(reloaded.corrections.allowsAutomatic(sponsorSpan, podcastID: show))
    }

    /// A corrections file that cannot be parsed must be copied aside before anything writes over
    /// it — the same decode-and-quarantine rule the rest of this app's stores learned the hard way.
    func testUnreadableCorrectionsAreQuarantinedRatherThanOverwritten() throws {
        let dir = try makeTempDirectory("AdSkip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("skip-corrections.json")
        try Data("definitely not { valid json [".utf8).write(to: url)

        _ = SkipPlanStore(directory: dir)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("skip-corrections.corrupt-") },
                      "the original is copied aside before any save can reach it")
        XCTAssertEqual(try Data(contentsOf: url).count, "definitely not { valid json [".count,
                       "and the original itself is left exactly where it was")
    }

    /// One unreadable plan costs one plan. Plans are a cache and rebuild; taking the whole file
    /// down with one bad record would throw away every other episode's for nothing.
    func testOneCorruptPlanDoesNotTakeTheOthersWithIt() throws {
        let dir = try makeTempDirectory("AdSkip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("skip-plans.json")
        let json = """
        {
          "good": {"plan": {"episodeID":"good","podcastID":"\(show.uuidString)","spans":[],"engineVersion":\(EpisodeSkipPlan.currentEngineVersion)}},
          "bad": {"plan": {"episodeID":"bad"}}
        }
        """
        try Data(json.utf8).write(to: url)

        let store = SkipPlanStore(directory: dir)
        XCTAssertNotNil(store.record(for: "good"))
        XCTAssertNil(store.record(for: "bad"))
    }

    /// Headers declaring a different length mean these are different bytes, so anything measured
    /// against the old ones has to go before it can be acted on.
    func testNewDeclaredSlotsForDifferentBytesDropTheOldPlan() throws {
        let dir = try makeTempDirectory("AdSkip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkipPlanStore(directory: dir)
        store.store(DeclaredAdSlots(episodeID: "ep-1",
                                    headers: ["x-megaphone-payload": "first"],
                                    byteCount: 48_000_000))
        store.store(StoredSkipPlan(plan: plan([span(0, 30)]), usedDeclaredSlots: true))

        store.store(DeclaredAdSlots(episodeID: "ep-1",
                                    headers: ["x-megaphone-payload": "second"],
                                    byteCount: 51_500_000))
        XCTAssertNil(store.record(for: "ep-1"))
    }

    func testHeaderCaptureKeepsAdHeadersAndDiscardsTransportNoise() {
        let slots = DeclaredAdSlots.capture(
            episodeID: "ep-1",
            headers: [
                "X-Megaphone-Payload": "slot=0-1200000",
                "Set-Cookie": "session=secret",
                "Content-Type": "audio/mpeg",
                "x-podtrac-id": "abc",
            ],
            byteCount: 48_000_000)

        XCTAssertEqual(Set(slots.headers.keys), ["x-megaphone-payload", "x-podtrac-id"])
        XCTAssertEqual(slots.byteCount, 48_000_000)
    }

    /// A plan built from headers alone is worth rebuilding once a transcript exists; one that
    /// already had everything is not worth rebuilding on every play.
    func testRebuildIsOnlyWorthItWhenTheInputsImproved() {
        let headersOnly = StoredSkipPlan(plan: plan([span(0, 30)]), usedDeclaredSlots: true)
        XCTAssertTrue(headersOnly.improvedBy(transcript: true, declaredSlots: true, localAudio: false))
        XCTAssertFalse(headersOnly.improvedBy(transcript: false, declaredSlots: true, localAudio: false))

        let complete = StoredSkipPlan(plan: plan([span(0, 30)]), usedTranscript: true,
                                      usedDeclaredSlots: true, usedLocalAudio: true)
        XCTAssertFalse(complete.improvedBy(transcript: true, declaredSlots: true, localAudio: true))
    }

    // MARK: - Steering beats skipping

    /// Scrubbing back onto an ad must let you hear it. Before this, a seek into a span was
    /// answered by a jump straight back out, so the audio could not be reached at all.
    func testSeekingIntoASpanStopsItBeingSkipped() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(10, 40)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        // Landing inside the ad, with no recent skip to object to.
        engine.noteDeliberateVisit(to: 25)

        XCTAssertNil(engine.jump(from: 25), "playback must stay where the listener put it")
        XCTAssertNil(engine.jump(from: 11), "and must not be bounced out on the way through either")
    }

    /// Aiming just short of an ad counts as aiming at it — nobody scrubs onto an exact frame.
    func testSeekingJustBeforeASpanAlsoStopsIt() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(10, 40)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        engine.noteDeliberateVisit(to: 8)

        XCTAssertNil(engine.jump(from: 10), "the span aimed at must not skip once reached")
    }

    /// A seek nowhere near an ad leaves automatic skipping alone.
    func testSeekingElsewhereLeavesSkippingArmed() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(10, 40)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        engine.noteDeliberateVisit(to: 300)

        // From inside the span: arriving there under its own steam, which is what auto-skip is for.
        XCTAssertEqual(engine.jump(from: 10)?.to, 40, "an untouched span should still skip")
    }

    /// Deliberately visiting an ad is not evidence the detector was wrong, so it must not count
    /// as a correction. Only a rewind straight back out of a skip that just happened does.
    func testDeliberateVisitIsNotACorrection() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(10, 40)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        engine.noteDeliberateVisit(to: 25)

        XCTAssertNil(engine.userSeeked(to: 25), "no skip happened, so there is nothing to object to")
    }

    /// Suppression covers the whole run one jump would have collapsed, not just the span landed in.
    func testDeliberateVisitSuppressesTheWholeCollapsedRun() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(10, 40), span(40, 70)]), corrections: SkipCorrectionBook(), audioByteCount: nil)

        engine.noteDeliberateVisit(to: 25)

        XCTAssertNil(engine.jump(from: 45), "the second half of the same move must stay reachable")
    }

    // MARK: - The seek storm (crash investigation, 09-16)

    /// The shape that pinned background CPU near 64% and hammered a still-loading AVPlayer.
    ///
    /// `destination(from:)` pulls in any span starting within its 0.75s tolerance ahead of the
    /// cursor, so after landing at the end of one span a near-adjacent span can sit a fraction of
    /// a second away. A skip re-checks itself once the seek settles, so a jump that barely moves
    /// re-arms a recheck that finds the same near-miss again: seek, recheck, seek, ~15 times a
    /// second. Requiring a minimum advance breaks it at the source.
    func testAJumpThatBarelyMovesIsRefusedRatherThanLooping() {
        var engine = SkipPlaybackEngine()
        // A span ending a hair past the playhead — the exact near-miss the tolerance admits.
        engine.load(plan([span(76.0, 76.1)]), corrections: SkipCorrectionBook(), audioByteCount: nil)
        XCTAssertNil(engine.jump(from: 76.0),
                     "a 0.1s advance is not worth a seek, and re-arming after one is how it spins")
    }

    func testARealAdIsStillSkippedNormally() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(76, 136)]), corrections: SkipCorrectionBook(), audioByteCount: nil)
        XCTAssertEqual(engine.jump(from: 76)?.to, 136, "a real ad must still skip")
    }

    /// The boundary itself, so the constant cannot be quietly loosened into uselessness or
    /// tightened into dropping real skips.
    func testTheMinimumAdvanceBoundaryIsExact() {
        let floor = SkipPlaybackEngine.minimumAdvance
        var justUnder = SkipPlaybackEngine()
        justUnder.load(plan([span(10, 10 + floor - 0.01)]), corrections: SkipCorrectionBook(), audioByteCount: nil)
        XCTAssertNil(justUnder.jump(from: 10))

        var exactly = SkipPlaybackEngine()
        exactly.load(plan([span(10, 10 + floor)]), corrections: SkipCorrectionBook(), audioByteCount: nil)
        XCTAssertEqual(exactly.jump(from: 10)?.to, 10 + floor)
    }

    /// Re-evaluating from a jump's own destination must terminate. This is the loop the player hit
    /// when it re-checked using the player's clock, which lags a seek while an item is still
    /// loading — it kept re-evaluating a position it had already left.
    func testRecheckingFromEachDestinationTerminates() {
        var engine = SkipPlaybackEngine()
        engine.load(plan([span(76, 90), span(90.2, 95), span(95.1, 95.2)]),
                    corrections: SkipCorrectionBook(), audioByteCount: nil)
        var position = 76.0
        var hops = 0
        while let performed = engine.jump(from: position), hops < 50 {
            XCTAssertGreaterThan(performed.to, position, "every hop must advance")
            position = performed.to
            hops += 1
        }
        XCTAssertLessThan(hops, 50, "re-checking from each destination must reach a fixed point")
    }
}
