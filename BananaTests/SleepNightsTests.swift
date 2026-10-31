import XCTest

/// How many times you got up in the night, and what for — from the Watch's sleep stages and
/// steps, then your corrections. Built for a new baby from the start.
final class SleepNightsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Minutes after 11 pm on 28 Sep 2026.
    private func t(_ minutes: Double) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 23))!.addingTimeInterval(minutes * 60)
    }

    private func asleep(_ from: Double, _ to: Double) -> SleepNights.Segment { .init(start: t(from), end: t(to), stage: .asleep) }
    private func awake(_ from: Double, _ to: Double) -> SleepNights.Segment { .init(start: t(from), end: t(to), stage: .awake) }
    private func steps(_ from: Double, _ to: Double, _ count: Double) -> SleepNights.StepSample {
        .init(start: t(from), end: t(to), count: count)
    }

    /// 11 pm to 7 am, with a 4-minute bathroom trip at 3:10, a 1-minute stir at 1:00, and 25
    /// minutes up with steps at 4:30.
    private func night() -> [NightSummary] {
        SleepNights.nights(segments: [
            asleep(0, 120), awake(120, 121), asleep(121, 250), awake(250, 254), asleep(254, 330),
            awake(330, 355), asleep(355, 480),
        ], steps: [steps(250, 252, 22), steps(252, 254, 18), steps(332, 352, 240)], calendar: calendar)
    }

    func testFindsTheNightAndItsWakeUps() throws {
        let nights = night()
        XCTAssertEqual(nights.count, 1)
        let n = try XCTUnwrap(nights.first)
        XCTAssertEqual(n.bedtime, t(0))
        XCTAssertEqual(n.wake, t(480))
        XCTAssertEqual(n.night, calendar.startOfDay(for: t(480)), "a night belongs to the morning it ends")
        XCTAssertEqual(n.asleepMinutes, 480 - 1 - 4 - 25, accuracy: 0.01)
        XCTAssertEqual(n.wakes.map(\.start), [t(250), t(330)], "a one-minute stir without steps isn't a wake-up")
        XCTAssertEqual(n.wakes[0].steps, 40)
        XCTAssertEqual(n.wakes[1].steps, 240)
    }

    /// The Watch staged a 20-step bathroom trip at 12:56 as asleep (2 Oct 2026); its minute-by-minute
    /// steps say otherwise, and that's a trip.
    func testAWalkTheStagesSleptThroughIsAWakeUp() throws {
        let n = try XCTUnwrap(SleepNights.nights(
            segments: [asleep(0, 480)],
            steps: [steps(116, 117, 19), steps(117, 118, 1)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.count, 1)
        XCTAssertEqual(n.wakes[0].steps, 20)
        XCTAssertEqual(n.wakes[0].start, t(115))
        XCTAssertEqual(SleepNights.guess(minutes: n.wakes[0].minutes, steps: n.wakes[0].steps,
                                         profile: .init([]), babyDuty: false), .bathroom)
    }

    /// Turning over makes a step now and then — never a walk — and a chunk from Health is too coarse
    /// to say when it happened.
    func testStrayStepsAndCoarseChunksDontMakeAWakeUp() throws {
        let strays = (0..<20).map { steps(30 + Double($0) * 6, 31 + Double($0) * 6, 1) }
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 480)],
                                                 steps: strays + [steps(200, 240, 40)], calendar: calendar).first)
        XCTAssertTrue(n.wakes.isEmpty)
    }

    /// A walk inside a stretch the stages already have awake isn't counted twice.
    func testAWalkAlreadyAwakeIsntAddedAgain() throws {
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 250), awake(250, 254), asleep(254, 480)],
                                                 steps: [steps(251, 252, 22)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.count, 1)
        XCTAssertEqual(n.wakes[0].steps, 22)
    }

    func testANapIsNotANight() {
        let nap = SleepNights.nights(segments: [asleep(0, 90)], steps: [], calendar: calendar)
        XCTAssertTrue(nap.isEmpty)
    }

    func testGapsBetweenAsleepStretchesAreWakeUpsEvenWithoutAwakeSamples() throws {
        // Some sources record only asleep time; the gap is where you were up.
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 200), asleep(206, 480)],
                                                 steps: [steps(201, 205, 30)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.count, 1)
        XCTAssertEqual(n.wakes[0].minutes, 6, accuracy: 0.01)
    }

    /// The Watch writes steps in chunks of several minutes: a 30-step trip to the bathroom inside
    /// a 40-minute chunk that's otherwise asleep is all the wake-up's — not the quarter of it a
    /// time-share gave, which made real trips look like fidgeting.
    func testAChunkThatsMostlyAsleepGivesAllItsStepsToTheWakeUp() throws {
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 100), asleep(110, 480)],
                                                 steps: [steps(90, 130, 30)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.map(\.steps), [30])
    }

    func testAChunkOverTwoWakeUpsIsSharedByTimeAwake() throws {
        // Up 100–110 and 200–205, each widened a minute either side: 12 and 7 minutes awake.
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 100), asleep(110, 200), asleep(205, 480)],
                                                 steps: [steps(95, 210, 30)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.map(\.steps), [19, 11])
    }

    func testWalkingToBedStaysWithTheEvening() throws {
        // A chunk from 10:30 pm to 11:12 pm: 30 minutes of it before falling asleep, 9 in the
        // (widened) stretch awake at 11:03 — so most of its steps were the walk to bed.
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 3), asleep(10, 480)],
                                                 steps: [steps(-30, 12, 30)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.map(\.steps), [7])
        XCTAssertEqual(SleepNights.classified([n], labels: [:], babyDuty: false).first?.wakes.first?.kind, .awakeInBed)
    }

    func testStepsWhileAsleepAreNobodys() throws {
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 100), asleep(110, 480)],
                                                 steps: [steps(200, 210, 50)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.map(\.steps), [0])
    }

    func testDefaultGuesses() throws {
        let n = try XCTUnwrap(SleepNights.classified(night(), labels: [:], babyDuty: false).first)
        XCTAssertEqual(n.wakes.map(\.kind), [.bathroom, .upForAWhile])
        XCTAssertEqual(SleepNights.upLine(n), "Up 2\u{00D7}: bathroom, up for a while")
    }

    func testOnBabyDutyTheLongTripIsTheBaby() throws {
        let n = try XCTUnwrap(SleepNights.classified(night(), labels: [:], babyDuty: true).first)
        XCTAssertEqual(n.wakes.map(\.kind), [.bathroom, .baby])
    }

    func testNoStepsIsAwakeInBed() {
        XCTAssertEqual(SleepNights.guess(minutes: 30, steps: 2, profile: .init([]), babyDuty: true), .awakeInBed)
    }

    func testYourLabelWinsEvenIfTheStartMovedAMinute() throws {
        var labels: [String: NightWakeKind] = [:]
        labels[SleepNights.labelKey(t(251))] = .baby
        let n = try XCTUnwrap(SleepNights.classified(night(), labels: labels, babyDuty: false).first)
        XCTAssertEqual(n.wakes[0].kind, .baby)
        XCTAssertTrue(n.wakes[0].labelled)
    }

    func testLabelsTeachWhatEachKindLooksLike() {
        // Three quick bathroom trips and three long baby stretches with few steps (feeding sitting
        // down) — the default rule would call a 20-minute, 30-step stretch the bathroom by steps
        // alone, but it looks like the labelled baby stretches.
        func wake(_ minutes: Double, _ steps: Int, _ kind: NightWakeKind) -> NightWake {
            NightWake(start: t(0), end: t(minutes), steps: steps, kind: kind, labelled: true)
        }
        let profile = SleepNights.Profile([
            wake(3, 40, .bathroom), wake(4, 55, .bathroom), wake(5, 35, .bathroom),
            wake(25, 30, .baby), wake(35, 20, .baby), wake(20, 45, .baby),
        ])
        XCTAssertEqual(SleepNights.guess(minutes: 22, steps: 30, profile: profile, babyDuty: true), .baby)
        XCTAssertEqual(SleepNights.guess(minutes: 4, steps: 45, profile: profile, babyDuty: true), .bathroom)
        XCTAssertEqual(SleepNights.guess(minutes: 22, steps: 30, profile: profile, babyDuty: false), .upForAWhile,
                       "baby duty off means no baby guesses")
    }

    func testAnUnknownKindFromANewerBuildStillDecodes() throws {
        let wake = try JSONDecoder().decode(NightWake.self, from: Data(#"{"start":0,"end":300,"steps":40,"kind":"feeding","labelled":true}"#.utf8))
        XCTAssertEqual(wake.kind, .upForAWhile)
    }

    /// Every time you got up gets a row, and so does a long stretch awake in bed; the brief ones
    /// in bed — most of a night's list — are one line.
    func testBriefStretchesInBedAreFoldedIntoOneLine() {
        func wake(_ at: Double, _ minutes: Double, _ kind: NightWakeKind) -> NightWake {
            NightWake(start: t(at), end: t(at + minutes), steps: 0, kind: kind)
        }
        let wakes = [wake(10, 4, .awakeInBed), wake(60, 3, .bathroom), wake(120, 6.5, .awakeInBed),
                     wake(200, 20, .awakeInBed), wake(300, 2, .awakeInBed), wake(400, 4.5, .awakeInBed)]
        let (listed, brief) = SleepNights.split(wakes)
        XCTAssertEqual(listed.map(\.start), [t(60), t(120), t(200)])
        XCTAssertEqual(brief.map(\.start), [t(10), t(300), t(400)])
        XCTAssertEqual(SleepNights.briefLine(brief), "Also awake in bed 3\u{00D7} \u{00B7} 11m")
    }

    func testDurationText() {
        XCTAssertEqual(SleepNights.duration(432), "7h 12m")
        XCTAssertEqual(SleepNights.duration(65), "1h 5m")
        XCTAssertEqual(SleepNights.duration(360), "6h")
        XCTAssertEqual(SleepNights.duration(38.4), "38m")
    }

    // MARK: - Hand-washing

    /// A hand-wash during a stretch awake — or just after, as you get back into bed — is the
    /// bathroom, however few steps the Watch counted.
    func testAHandwashMakesItTheBathroom() throws {
        let n = try XCTUnwrap(SleepNights.nights(segments: [asleep(0, 100), asleep(104, 480)], steps: [],
                                                 handwashes: [t(106)], calendar: calendar).first)
        XCTAssertEqual(n.wakes.first?.handwash, t(106))
        let kinds = SleepNights.classified([n], labels: [:], babyDuty: false).first?.wakes.map(\.kind)
        XCTAssertEqual(kinds, [.bathroom])
    }

    /// On baby duty a hand-wash may be a nappy: it says you got up, not what for.
    func testOnBabyDutyAHandwashOnlySaysYouGotUp() {
        XCTAssertEqual(SleepNights.guess(minutes: 20, steps: 3, handwashed: true, profile: .init([]), babyDuty: true), .baby)
        XCTAssertEqual(SleepNights.guess(minutes: 20, steps: 3, handwashed: true, profile: .init([]), babyDuty: false), .bathroom)
    }

    func testAHandwashKeepsABriefStretch() throws {
        // 90 seconds awake, no steps: a stir — unless you washed your hands in it.
        let segments = [asleep(0, 100), asleep(101.5, 480)]
        let stir = try XCTUnwrap(SleepNights.nights(segments: segments, steps: [], calendar: calendar).first)
        XCTAssertTrue(stir.wakes.isEmpty)
        let washed = try XCTUnwrap(SleepNights.nights(segments: segments, steps: [], handwashes: [t(101)], calendar: calendar).first)
        XCTAssertEqual(washed.wakes.count, 1)
    }

    // MARK: - The Watch's minute-by-minute steps

    func testWatchMinutesReplaceHealthsChunksWhereTheyReach() {
        // A 20-minute chunk of 40 steps, half of it inside a window the Watch sent: the half
        // outside keeps its 20 steps, and the window's minutes stand in for the rest.
        let window = NightMotionReport.Window(start: t(10), end: t(100),
                                              minutes: [.init(start: t(12), steps: 25)], walking: [])
        let out = SleepNights.preferringMinutes([steps(0, 20, 40)], windows: [window])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].start, t(0))
        XCTAssertEqual(out[0].end, t(10))
        XCTAssertEqual(out[0].count, 20, accuracy: 0.01)
        XCTAssertEqual(out[1].start, t(12))
        XCTAssertEqual(out[1].end, t(13))
        XCTAssertEqual(out[1].count, 25)
    }

    func testWithoutWatchMinutesHealthsChunksStand() {
        let chunks = [steps(0, 20, 40)]
        XCTAssertEqual(SleepNights.preferringMinutes(chunks, windows: []).map(\.count), [40])
    }

    // MARK: - The measures sleep research uses

    /// 11 pm to 7 am with a 4-minute bathroom trip at 3:10 and 25 minutes up at 4:30 (plus a
    /// one-minute stir that isn't a wake-up but is still time awake).
    func testAwakeLongestSleepAndFirstTrip() throws {
        let n = try XCTUnwrap(SleepNights.classified(night(), labels: [:], babyDuty: false).first)
        XCTAssertEqual(SleepNights.awakeMinutes(n), 30, accuracy: 0.01)
        XCTAssertEqual(SleepNights.longestSleepMinutes(n), 250, accuracy: 0.01, "11 pm to the 3:10 trip")
        XCTAssertEqual(try XCTUnwrap(SleepNights.firstTripMinutes(n)), 250, accuracy: 0.01)
    }

    func testBriefStirringsDontBreakTheLongestSleep() throws {
        var n = try XCTUnwrap(SleepNights.classified(night(), labels: [:], babyDuty: false).first)
        // A 3-minute stretch in bed at 1 am: remembered by nobody, so the night isn't broken there.
        n.wakes.insert(NightWake(start: t(120), end: t(123), steps: 0, kind: .awakeInBed), at: 0)
        XCTAssertEqual(SleepNights.longestSleepMinutes(n), 250, accuracy: 0.01)
    }

    func testNightsWithTwoOrMoreTrips() throws {
        let one = try XCTUnwrap(SleepNights.classified(night(), labels: [:], babyDuty: false).first)
        var two = one
        two.wakes[1].kind = .bathroom
        XCTAssertEqual(SleepNights.nightsWithTwoOrMoreTrips([one, two]), 1)
    }

    // MARK: - Learning from your labels

    func testConfirmingGuessesCountsTowardLearning() throws {
        let n = try XCTUnwrap(SleepNights.classified(night(), labels: [:], babyDuty: false).first)
        XCTAssertEqual(SleepNights.unconfirmed(n).map(\.start), [t(250), t(330)])
        var labels: [String: NightWakeKind] = [:]
        for wake in SleepNights.unconfirmed(n) { labels[SleepNights.labelKey(wake.start)] = wake.kind }
        let confirmed = SleepNights.classified([n], labels: labels, babyDuty: false)
        XCTAssertTrue(SleepNights.unconfirmed(try XCTUnwrap(confirmed.first)).isEmpty)
        XCTAssertEqual(SleepNights.learning(confirmed).labelled, 2)
        XCTAssertFalse(SleepNights.learning(confirmed).inUse, "needs three each of two kinds")
    }
}
