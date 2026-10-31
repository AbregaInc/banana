import XCTest

/// Routines, alarms, wake sounds and show settings sync as one record each (CloudControlsSync).
final class ControlKindTests: XCTestCase {
    func testRecordNamesRoundTrip() {
        let id = UUID().uuidString
        for kind in ControlKind.allCases {
            let parsed = ControlKind.parse(kind.recordName(id))
            XCTAssertEqual(parsed?.kind, kind)
            XCTAssertEqual(parsed?.id, id)
        }
        XCTAssertEqual(ControlKind.parse("wake-sleep")?.id, "sleep")
    }

    func testUnknownRecordsAreNotMistakenForAKind() {
        XCTAssertNil(ControlKind.parse("meal-123"))
        XCTAssertNil(ControlKind.parse("routine"))   // no separator, no id
        XCTAssertNil(ControlKind.parse(""))
    }

    func testOnlyListsTakeThePhonesWholeSet() {
        XCTAssertTrue(ControlKind.routine.adoptsPhoneSet)
        XCTAssertTrue(ControlKind.alarm.adoptsPhoneSet)
        XCTAssertTrue(ControlKind.wake.adoptsPhoneSet)
        XCTAssertFalse(ControlKind.podcast.adoptsPhoneSet)   // a show's settings are only ever updated
        // The library and history merge: nothing a device has is dropped for being missing elsewhere.
        XCTAssertFalse(ControlKind.show.adoptsPhoneSet)
        XCTAssertFalse(ControlKind.listen.adoptsPhoneSet)
    }

    func testAnEpisodeURLGetsAStableHashedName() {
        let episode = "https://feeds.example.com/episodes/123?utm_source=rss&x=é"
        let name = ControlKind.skipPlan.recordName(episode)
        XCTAssertEqual(name, ControlKind.skipPlan.recordName(episode))   // stable
        XCTAssertTrue(name.hasPrefix("skipPlan-~"))
        XCTAssertLessThanOrEqual(name.count, 255)
        XCTAssertEqual(ControlKind.parse(name)?.kind, .skipPlan)
        // A plain id stays readable.
        XCTAssertEqual(ControlKind.show.recordName("ABC-123"), "show-ABC-123")
    }

    func testNoKindTakesAnothersRecords() {
        XCTAssertEqual(ControlKind.parse("listenRoute-X")?.kind, .listenRoute)
        XCTAssertEqual(ControlKind.parse("listen-X")?.kind, .listen)
        XCTAssertEqual(ControlKind.parse("narratorGender-x")?.kind, .narratorGender)
    }
}

final class ControlMergeTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    func testTheNewerEditWins() {
        XCTAssertTrue(ControlMerge.remoteWins(remote: later, local: earlier))
        XCTAssertFalse(ControlMerge.remoteWins(remote: earlier, local: later))
    }

    func testTheSameEditIsNotAppliedAgain() {
        XCTAssertFalse(ControlMerge.remoteWins(remote: later, local: later))
    }

    func testAnythingBeatsNothing() {
        XCTAssertTrue(ControlMerge.remoteWins(remote: earlier, local: nil))
    }

    func testTheSeedLosesToAnyRealEdit() {
        // The phone's first sync is stamped `unedited`; a routine changed on the Mac before the
        // phone got there must survive it.
        XCTAssertFalse(ControlMerge.remoteWins(remote: ControlEnvelope.unedited, local: earlier))
    }

    func testAMacTakesThePhonesSet() {
        let drop = ControlMerge.localOnly(local: ["mac-wake", "shared"], server: ["shared", "phone-wake"])
        XCTAssertEqual(drop, ["mac-wake"])
    }

    func testNothingIsDroppedBeforeThePhoneHasPublished() {
        XCTAssertEqual(ControlMerge.localOnly(local: ["mac-wake"], server: []), [])
    }

    func testABigItemIsPackedAndComesBackExactly() throws {
        let transcriptish = Data(String(repeating: "the quick brown fox jumps over the lazy dog ", count: 2000).utf8)
        let envelope = ControlEnvelope.edit(transcriptish, at: later)
        XCTAssertEqual(envelope.packed, true)
        XCTAssertLessThan(envelope.item?.count ?? .max, transcriptish.count)
        let decoded = try JSONDecoder().decode(ControlEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded.unpackedItem, transcriptish)
    }

    func testASmallItemIsLeftAsItIs() {
        let small = Data("{\"speed\":1.5}".utf8)
        let envelope = ControlEnvelope.edit(small, at: later)
        XCTAssertNil(envelope.packed)
        XCTAssertEqual(envelope.unpackedItem, small)
    }

    func testADeletedHashedItemStillSaysWhichItWas() throws {
        let envelope = ControlEnvelope.tombstone(at: later, key: "https://example.com/ep/1")
        let decoded = try JSONDecoder().decode(ControlEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded.key, "https://example.com/ep/1")
        XCTAssertTrue(decoded.deleted)
    }

    func testATombstoneCarriesItsTimeAndNoItem() throws {
        let envelope = ControlEnvelope.tombstone(at: later)
        let decoded = try JSONDecoder().decode(ControlEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertTrue(decoded.deleted)
        XCTAssertNil(decoded.item)
        XCTAssertEqual(decoded.editedAt, later)
    }
}

final class OneOffAlarmListTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func alarm(_ minutes: Double, _ label: String = "") -> OneOffAlarm {
        OneOffAlarm(fire: now.addingTimeInterval(minutes * 60), label: label)
    }

    func testAddingKeepsTheSoonestFirst() {
        let late = alarm(90), early = alarm(10)
        XCTAssertEqual(OneOffAlarmList.adding(early, to: [late]).map(\.id), [early.id, late.id])
    }

    func testAChangeFromAnotherDeviceReplacesTheAlarm() {
        var moved = alarm(30)
        let list = [moved, alarm(60)]
        moved.fire = now.addingTimeInterval(120 * 60)
        let next = OneOffAlarmList.applying(moved, id: moved.id, to: list, now: now)
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next.last, moved)
    }

    func testADeleteFromAnotherDeviceRemovesIt() {
        let gone = alarm(30), kept = alarm(60)
        XCTAssertEqual(OneOffAlarmList.applying(nil, id: gone.id, to: [gone, kept], now: now), [kept])
    }

    func testAnAlarmThatHasAlreadyRungIsNotAdded() {
        let past = alarm(-5)
        XCTAssertEqual(OneOffAlarmList.applying(past, id: past.id, to: [], now: now), [])
    }

    func testEveryAlarmIsOfferedByID() throws {
        let one = alarm(5, "Laundry")
        let items = OneOffAlarmList.cloudItems([one])
        let data = try XCTUnwrap(items[one.id.uuidString])
        XCTAssertEqual(try JSONDecoder().decode(OneOffAlarm.self, from: data), one)
    }

    func testTheTitleFallsBackToTheTime() {
        XCTAssertEqual(alarm(5, "Laundry").title, "Laundry")
        XCTAssertTrue(alarm(5).title.hasPrefix("Alarm"))
    }
}

final class PodcastSettingsTests: XCTestCase {
    private func podcast() -> Podcast {
        var podcast = Podcast(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Show")
        podcast.positions = ["ep1": 1_234]
        podcast.completed = ["ep0"]
        podcast.currentEpisodeID = "ep1"
        return podcast
    }

    func testSettingsTravelAndProgressStays() throws {
        var there = podcast()
        there.speed = 1.5
        there.syncToWatch = true
        there.downloadRule = .latest(5)
        there.watchAudioQuality = .low
        there.skipsAdsAutomatically = false
        there.mutedNarrators = ["Thomas"]
        // Progress on the sending device must never reach this one through settings.
        there.positions = [:]
        there.completed = []

        let data = try JSONEncoder().encode(PodcastSettings(there))
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        let here = settings.applied(to: podcast())

        XCTAssertEqual(here.speed, 1.5)
        XCTAssertTrue(here.syncToWatch)
        XCTAssertEqual(here.downloadRule, .latest(5))
        XCTAssertEqual(here.watchAudioQuality, .low)
        XCTAssertEqual(here.skipsAdsAutomatically, false)
        XCTAssertEqual(here.mutedNarrators, ["Thomas"])
        XCTAssertEqual(here.positions, ["ep1": 1_234])
        XCTAssertEqual(here.completed, ["ep0"])
        XCTAssertEqual(here.currentEpisodeID, "ep1")
    }

    func testASubscriptionArrivesAsTheSameShow() throws {
        let original = podcast()
        let data = try JSONEncoder().encode(PodcastSubscription(original))
        let subscription = try JSONDecoder().decode(PodcastSubscription.self, from: data)
        let here = subscription.podcast(id: original.id)
        // Same id everywhere, so its progress and settings find it.
        XCTAssertEqual(here.id, original.id)
        XCTAssertEqual(here.feedURL, original.feedURL)
        XCTAssertEqual(here.title, original.title)
        // No episodes and no progress travel with it — those come from the feed and progress sync.
        XCTAssertTrue(here.episodes.isEmpty)
        XCTAssertTrue(here.positions.isEmpty)
    }

    func testANewerBuildsExtraSettingIsIgnored() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PodcastSettings(podcast()))) as? [String: Any])
        json["somethingNew"] = true
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNoThrow(try JSONDecoder().decode(PodcastSettings.self, from: data))
    }
}

/// A blocker just added stays on the Day grid: the grid's cached window takes the fresher read
/// for the days it covered, and keeps its own copy elsewhere.
final class PlanningWindowSliceTests: XCTestCase {
    private struct Item: Equatable {
        var name: String
        var start: Date
        var end: Date?
    }

    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    private func replace(_ cached: [Item], _ fresh: [Item], from lo: Double, to hi: Double) -> [String] {
        PlanningWindowSlice.replacing(cached, with: fresh, from: at(lo), to: at(hi),
                                      span: { ($0.start, $0.end) }).map(\.name).sorted()
    }

    func testANewEventInTheReadAppears() {
        let old = [Item(name: "standup", start: at(9), end: at(9.5))]
        let fresh = old + [Item(name: "blocker", start: at(14), end: at(15))]
        XCTAssertEqual(replace(old, fresh, from: 0, to: 24), ["blocker", "standup"])
    }

    func testAnEventGoneFromTheReadGoes() {
        let old = [Item(name: "cancelled", start: at(9), end: at(10))]
        XCTAssertEqual(replace(old, [], from: 0, to: 24), [])
    }

    func testDaysTheReadDidNotCoverAreKept() {
        // The Day view's window starts yesterday; the timeline's read starts today.
        let yesterday = Item(name: "yesterday", start: at(-10), end: at(-9))
        let stale = Item(name: "stale", start: at(10), end: at(11))
        XCTAssertEqual(replace([yesterday, stale], [], from: 0, to: 24), ["yesterday"])
    }

    func testAnEventAcrossTheEdgeBelongsToTheRead() {
        let overnight = Item(name: "overnight", start: at(-2), end: at(1))
        XCTAssertEqual(replace([overnight], [], from: 0, to: 24), [])
        XCTAssertEqual(replace([], [overnight], from: 0, to: 24), ["overnight"])
    }

    func testAMomentWithoutAnEndIsPlacedByItsStart() {
        let reminder = Item(name: "moment", start: at(3), end: nil)
        XCTAssertEqual(replace([reminder], [], from: 0, to: 24), [])
        XCTAssertEqual(replace([reminder], [], from: 4, to: 24), ["moment"])
    }
}

/// A read that couldn't reach every calendar leaves what's shown from the ones it missed: an
/// iPad whose sign-in stalled for two accounts had their events on its timeline and gone from
/// its calendar ("Lunch", 6 October 2026).
final class PlanningWindowIncompleteReadTests: XCTestCase {
    private struct Event: Equatable {
        var id: String?
        var calendar: String?
        var start: Date
        var end: Date?
    }

    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    private func kept(_ fresh: [Event], known: [Event], complete: Bool, covered: Set<String>) -> [String] {
        PlanningWindowSlice.keepingUncovered(fresh, known: known, complete: complete, covered: covered,
                                             from: at(0), to: at(24), calendarID: \.calendar, id: \.id,
                                             span: { ($0.start, $0.end) }).compactMap(\.id).sorted()
    }

    private var standup: Event { Event(id: "standup", calendar: "home", start: at(9), end: at(9.5)) }
    private var lunch: Event { Event(id: "lunch", calendar: "work", start: at(12), end: at(13)) }

    func testAnUnreachedCalendarsEventsStay() {
        // "work" couldn't be read; the window had its lunch.
        XCTAssertEqual(kept([standup], known: [standup, lunch], complete: false, covered: ["home"]),
                       ["lunch", "standup"])
    }

    func testTheyComeFromTheTimelineWhenTheWindowNeverHadThem() {
        // `known` is the window as it was plus the timeline: here only the timeline has lunch.
        XCTAssertEqual(kept([standup], known: [lunch], complete: false, covered: ["home"]), ["lunch", "standup"])
    }

    func testACompleteReadIsTheWholeAnswer() {
        // Lunch was cancelled: a read that reached every calendar and didn't return it means it's gone.
        XCTAssertEqual(kept([standup], known: [standup, lunch], complete: true, covered: ["home", "work"]), ["standup"])
    }

    func testAReachedCalendarsMissingEventGoesEvenFromAnIncompleteRead() {
        // "work" was read and has no lunch any more; it's "school" that failed.
        XCTAssertEqual(kept([standup], known: [standup, lunch], complete: false, covered: ["home", "work"]), ["standup"])
    }

    func testNothingIsKeptTwiceOrFromOutsideTheDays() {
        let tomorrow = Event(id: "tomorrow", calendar: "work", start: at(30), end: at(31))
        XCTAssertEqual(kept([standup], known: [lunch, lunch, tomorrow], complete: false, covered: ["home"]),
                       ["lunch", "standup"])
    }
}

/// Short events stay end to end at every zoom (a 3:30–3:45 blocker before a 3:45 swim).
final class CalendarBlockHeightTests: XCTestCase {
    func testAShortEventBeforeAnotherKeepsItsOwnMinutes() {
        // Zoomed out: 15 min is 11 pt, the swim starts 11 pt below.
        XCTAssertEqual(CalendarBlockHeight.height(natural: 11, minimum: 24, roomBelow: 11), 11)
    }

    func testAShortEventWithRoomIsStretchedToBeReadable() {
        XCTAssertEqual(CalendarBlockHeight.height(natural: 11, minimum: 24, roomBelow: 60), 24)
        XCTAssertEqual(CalendarBlockHeight.height(natural: 11, minimum: 24, roomBelow: nil), 24)
    }

    func testItStretchesOnlyAsFarAsTheNextBlock() {
        XCTAssertEqual(CalendarBlockHeight.height(natural: 11, minimum: 24, roomBelow: 17), 17)
    }

    func testALongEventIsItsOwnLength() {
        XCTAssertEqual(CalendarBlockHeight.height(natural: 90, minimum: 24, roomBelow: 90), 90)
    }

    func testAnEventOverlappingTheNextIsNeverCutShorterThanItsMinutes() {
        XCTAssertEqual(CalendarBlockHeight.height(natural: 40, minimum: 24, roomBelow: 20), 40)
    }
}

/// A pinch that starts on an event doesn't open it (or, on a task, tick it off).
final class ZoomTapGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testTapsCountWhenNothingIsZooming() {
        XCTAssertTrue(ZoomTapGate().allowsTap(at: t0))
    }

    func testNoTapWhileAPinchIsUnderWay() {
        var gate = ZoomTapGate()
        gate.pinchChanged(at: at(0))
        XCTAssertFalse(gate.allowsTap(at: at(0.5)))
    }

    func testTheLingeringFingerStillBelongsToThePinch() {
        // The pinch ends when one finger lifts; the other lifts over an event a second later.
        var gate = ZoomTapGate()
        gate.pinchChanged(at: at(0))
        XCTAssertFalse(gate.allowsTap(at: at(1.0)))
        gate.fingersLifted(at: at(1.0))
        XCTAssertFalse(gate.allowsTap(at: at(1.1)))
        XCTAssertTrue(gate.allowsTap(at: at(1.0 + ZoomTapGate.settle + 0.01)))
    }

    func testAMissedLiftCannotLockTapsForGood() {
        var gate = ZoomTapGate()
        gate.pinchChanged(at: at(0))
        XCTAssertTrue(gate.allowsTap(at: at(ZoomTapGate.limit + 0.1)))
    }

    func testLiftingWithoutAPinchChangesNothing() {
        var gate = ZoomTapGate()
        gate.fingersLifted(at: at(0))
        XCTAssertTrue(gate.allowsTap(at: at(0.1)))
    }
}

/// What a page and Settings say while data is still arriving.
final class SyncActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func running() -> SyncActivity {
        var activity = SyncActivity()
        activity.running = true
        return activity
    }

    func testANewDeviceSaysItIsGettingTheData() {
        var activity = running()
        activity.willFetch()
        XCTAssertEqual(activity.waitingLine(.fitness), "Getting your workouts and Health data from iCloud\u{2026}")
        activity.received(120)
        activity.received(192)
        XCTAssertEqual(activity.waitingLine(.fitness), "Getting your workouts and Health data from iCloud\u{2026} 312 so far")
        XCTAssertEqual(activity.statusLine(now: t0), "Downloading\u{2026} 312 so far")
    }

    func testOnceAFirstDownloadFinishesThePageSaysNothing() {
        var activity = running()
        activity.willFetch()
        activity.didFetch(at: t0)
        XCTAssertNil(activity.waitingLine(.fitness))
        XCTAssertEqual(activity.statusLine(now: t0.addingTimeInterval(10)), "Up to date")
        // Later fetches don't bring the note back.
        activity.willFetch()
        activity.received(3)
        XCTAssertNil(activity.waitingLine(.fitness))
    }

    func testAFailureIsSaid() {
        var activity = running()
        activity.willFetch()
        activity.failed("not signed in to iCloud")
        XCTAssertEqual(activity.statusLine(now: t0), "Couldn\u{2019}t sync \u{2014} not signed in to iCloud")
        XCTAssertTrue(activity.waitingLine(.wellness)?.contains("not signed in") == true)
    }

    func testNothingYetReadsAsNotSynced() {
        XCTAssertEqual(running().statusLine(now: t0), "Not synced yet")
    }

    func testASyncThatIsOffHereNeverClaimsToBeDownloading() {
        // The Simulator, a build without iCloud: no perpetual "Getting…" note.
        let off = SyncActivity()
        XCTAssertNil(off.waitingLine(.fitness))
        XCTAssertEqual(off.statusLine(now: t0), "Off on this device")
    }
}


@MainActor
final class CoalescingRunTests: XCTestCase {
    func testARequestDuringAPassWaitsForThePassAfterIt() async {
        let runs = CoalescingRun()
        var passes = 0
        var release: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await runs.run {
                passes += 1
                if passes == 1 { await withCheckedContinuation { release = $0 } }
                return 1
            }
        }
        while release == nil { await Task.yield() }
        // Two asks while the first pass waits: neither starts a pass of its own, and neither
        // returns before the pass that serves them has run.
        var answered = 0
        let during = Task { @MainActor in let total = await runs.run { passes += 100; return 100 }; answered += 1; return total }
        let duringAgain = Task { @MainActor in let total = await runs.run { passes += 100; return 100 }; answered += 1; return total }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(answered, 0, "still waiting for their pass")
        release?.resume()
        let total = await first.value
        let waited = await during.value
        let waitedAgain = await duringAgain.value
        XCTAssertEqual(passes, 2, "one more pass, not one per request")
        XCTAssertEqual(total, 2)
        XCTAssertEqual(waited, 2)
        XCTAssertEqual(waitedAgain, 2)
    }

    func testRunsAgainAfterFinishing() async {
        let runs = CoalescingRun()
        let one = await runs.run { 3 }
        let two = await runs.run { 4 }
        XCTAssertEqual(one, 3)
        XCTAssertEqual(two, 4)
    }
}

final class PeerBrowsePacingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverRestartsRightAfterAStop() {
        XCTAssertEqual(PeerBrowsePacing.startDelay(now: now, lastStopped: nil), 0, "never stopped: start now")
        XCTAssertEqual(PeerBrowsePacing.startDelay(now: now, lastStopped: now), PeerBrowsePacing.restartGap)
        XCTAssertEqual(PeerBrowsePacing.startDelay(now: now, lastStopped: now.addingTimeInterval(-0.5)), 1.5, accuracy: 0.0001)
        XCTAssertEqual(PeerBrowsePacing.startDelay(now: now, lastStopped: now.addingTimeInterval(-10)), 0)
    }

    func testABurstSharesOneBrowse() {
        XCTAssertGreaterThan(PeerBrowsePacing.linger, PeerBrowsePacing.restartGap)
        XCTAssertGreaterThanOrEqual(PeerBrowsePacing.linger, 10, "longer than a burst of downloads")
    }
}

final class PendingRemovalsTests: XCTestCase {
    private struct Event { let id: String?; let title: String }

    func testADeclinedEventIsLeftOutWhileItsUndoLasts() {
        let events = [Event(id: "a", title: "Standup"), Event(id: "b", title: "Declined review"), Event(id: nil, title: "Routine")]
        let shown = PendingRemovals.visible(events, id: \.id, hiding: ["b"])
        XCTAssertEqual(shown.map(\.title), ["Standup", "Routine"], "things with no event id are never hidden")
        XCTAssertEqual(PendingRemovals.visible(events, id: \.id, hiding: []).count, 3, "undone: back")
    }
}

final class InvitationReplyTextTests: XCTestCase {
    func testAReplySaysWhatItDid() {
        XCTAssertEqual(GoogleCalendarRSVP.accepted.confirmation(title: "Standup"), "Going to \u{201C}Standup\u{201D}")
        XCTAssertEqual(GoogleCalendarRSVP.tentative.confirmation(title: "Standup"), "Maybe for \u{201C}Standup\u{201D}")
        XCTAssertEqual(GoogleCalendarRSVP.declined.confirmation(title: ""), "Declined the invitation")
    }
}

final class PendingSeriesRemovalTests: XCTestCase {
    private struct Event { let id: String; let start: Date }
    private func event(_ raw: String, _ day: Int) -> Event {
        Event(id: GoogleCalendarIDs.eventInfoID(calendarID: "me@example.com", eventID: raw),
              start: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
    }

    func testDeletingAWholeSeriesHidesEveryOccurrenceAtOnce() {
        let events = [event("abc_20270118T083000Z", 0), event("abc_20270120T083000Z", 2),
                      event("other", 1), event("abcd_20270118T083000Z", 0)]
        let token = PendingRemovals.seriesToken(eventInfoID: events[1].id, from: nil)!
        let shown = PendingRemovals.visible(events, id: \.id, start: \.start, hiding: [token])
        XCTAssertEqual(shown.map(\.id), [events[2].id, events[3].id], "only that series' occurrences go")
    }

    func testThisAndFollowingHidesFromThatOneOn() {
        let events = [event("abc_1", 0), event("abc_2", 2), event("abc_3", 4)]
        let token = PendingRemovals.seriesToken(eventInfoID: events[1].id, from: events[1].start)!
        let shown = PendingRemovals.visible(events, id: \.id, start: \.start, hiding: [token])
        XCTAssertEqual(shown.map(\.id), [events[0].id], "earlier ones stay")
    }

    func testASingleEventIsHiddenByItsOwnID() {
        let events = [event("solo", 0), event("abc_1", 1)]
        XCTAssertEqual(PendingRemovals.visible(events, id: \.id, start: \.start, hiding: [events[0].id]).map(\.id),
                       [events[1].id])
    }
}

final class CueTimeTextTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }

    func testTheDayIsSaidPlainly() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 22))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 7, minute: 10))!
        XCTAssertEqual(CueTimeText.day(now, now: now, calendar: calendar), "Today")
        XCTAssertTrue(CueTimeText.day(tomorrow, now: now, calendar: calendar).hasPrefix("Tomorrow, "))
    }

    func testAWakeCueSaysWhatSetIt() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        let wake = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 7, minute: 10))!
        let meeting = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9, minute: 30))!
        let plan = WakePlan(days: [.init(date: day, weekday: 6, firstMeeting: meeting, wake: wake, bedtime: nil)],
                            explanation: "")
        let withMeeting = CueTimeText.reason(triggerIsWakePlan: true, ruleDescription: "Before your first meeting",
                                             date: wake, plan: plan, calendar: calendar)
        XCTAssertTrue(withMeeting.contains("first meeting at"), withMeeting)
        let quiet = WakePlan(days: [.init(date: day, weekday: 6, firstMeeting: nil, wake: wake, bedtime: nil)], explanation: "")
        XCTAssertTrue(CueTimeText.reason(triggerIsWakePlan: true, ruleDescription: "x", date: wake, plan: quiet,
                                         calendar: calendar).contains("usual wake time"))
        XCTAssertEqual(CueTimeText.reason(triggerIsWakePlan: false, ruleDescription: "7:00 AM · weekdays",
                                          date: wake, plan: plan, calendar: calendar), "7:00 AM · weekdays")
    }

    /// A skip says what was skipped and when, so it's plain it worked.
    func testASkipSaysWhatAndWhen() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 22))!
        let wake = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 7, minute: 10))!
        let time = wake.formatted(date: .omitted, time: .shortened)
        let skipped = CueTimeText.skipped("Wake up", at: wake, hasTime: true, now: now, calendar: calendar)
        XCTAssertTrue(skipped.hasPrefix("Skipped Wake up \u{00B7} Tomorrow, "), skipped)
        XCTAssertTrue(skipped.hasSuffix(" at \(time)"), skipped)
        XCTAssertEqual(CueTimeText.restored("Stretch", at: now, hasTime: false, now: now, calendar: calendar),
                       "Stretch is back \u{00B7} Today")
    }
}

/// What the badges count: only what's waiting on the person.
final class ActionItemsTests: XCTestCase {
    func testScheduledRoutineIsDueOnlyAfterItsTimeUntilCompletedOrSkipped() {
        let now = Date(timeIntervalSince1970: 1_792_598_400)
        let past = now.addingTimeInterval(-3600)
        XCTAssertEqual(ActionItems.routineDueSince(start: past, hasTime: true, completed: false, skipped: false, now: now), past)
        XCTAssertNil(ActionItems.routineDueSince(start: now.addingTimeInterval(1), hasTime: true, completed: false, skipped: false, now: now))
        XCTAssertNil(ActionItems.routineDueSince(start: past, hasTime: false, completed: false, skipped: false, now: now))
        XCTAssertNil(ActionItems.routineDueSince(start: past, hasTime: true, completed: true, skipped: false, now: now))
        XCTAssertNil(ActionItems.routineDueSince(start: past, hasTime: true, completed: false, skipped: true, now: now))
    }

    func testMealsThatNeedYouAreCountedNotOnesBeingEstimated() {
        let now = Date()
        let items: [MealInboxItem] = [
            .init(eatenAt: now, state: .awaitingNote, origin: .scanned),
            .init(eatenAt: now, note: "x", state: .ready, origin: .typed),
            .init(eatenAt: now, note: "y", state: .proposed, origin: .typed),
            .init(eatenAt: now, note: "z", state: .failed, origin: .typed),
        ]
        XCTAssertEqual(ActionItems.food(items), 3)
    }

    func testADoseCountsOnceItsTimeHasComeUntilItsMarked() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let morning = SupplementSchedule(name: "Vitamin D", hour: 8)
        let taken = SupplementSchedule(name: "Iron", hour: 9)
        let evening = SupplementSchedule(name: "Magnesium", hour: 21)
        let off = SupplementSchedule(name: "Old", hour: 7, enabled: false)
        let due = ActionItems.dosesDue([morning, taken, evening, off], marked: { $0 == taken.id },
                                       now: now, calendar: calendar)
        XCTAssertEqual(due, 1, "the morning dose: the evening one isn't due yet, one's taken, one's off")
    }

    func testTheNutritionBadgeIsFoodAndDosesAndTheIconIsEverything() {
        let counts = ActionItems.Counts(plan: 2, food: 3, taken: 1)
        XCTAssertEqual(counts.nutrition, 4)
        XCTAssertEqual(counts.total, 6)
    }
}

/// A repeating reminder is overdue until its next instance's day begins — then that one's
/// outstanding and the earlier ones were missed. One rule for every repeat.
final class ReminderRolloverTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testYesterdaysEveningDoseIsMissedAtMidnightAndTodaysIsTheOne() {
        let stored = at(1, 20)
        let lateEvening = ReminderRollover.current(storedDue: stored, recurrence: .daily, now: at(1, 23), calendar: calendar)
        XCTAssertEqual(lateEvening.due, stored, "still its own day: overdue")
        XCTAssertEqual(lateEvening.missed, 0)
        let morning = ReminderRollover.current(storedDue: stored, recurrence: .daily, now: at(2, 10), calendar: calendar)
        XCTAssertEqual(morning.due, at(2, 20), "the next morning there's one to do, today's, though 8 PM hasn't come")
        XCTAssertEqual(morning.missed, 1)
        let justAfterMidnight = ReminderRollover.current(storedDue: stored, recurrence: .daily, now: at(2, 0, 1), calendar: calendar)
        XCTAssertEqual(justAfterMidnight.due, at(2, 20))
    }

    func testTheSameRuleForWeeklyAndMonthly() {
        let weekly = ReminderRollover.current(storedDue: at(5, 9), recurrence: .weekly, now: at(11, 23), calendar: calendar)
        XCTAssertEqual(weekly.due, at(5, 9), "a late watering is still worth doing all week")
        let nextWeek = ReminderRollover.current(storedDue: at(5, 9), recurrence: .weekly, now: at(12, 7), calendar: calendar)
        XCTAssertEqual(nextWeek.due, at(12, 9), "on next week's day, before its time, it's next week's")
        XCTAssertEqual(nextWeek.missed, 1)
        let monthly = ReminderRollover.current(storedDue: at(31, 9, month: 1), recurrence: .monthly,
                                               now: at(1, 10, month: 4), calendar: calendar)
        XCTAssertEqual(monthly.due, calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 9)),
                       "counted from the stored date: the 31st, not drifting to the 28th")
        XCTAssertEqual(monthly.missed, 2)
    }

    func testMonthsBehindAndOneOffs() {
        let behind = ReminderRollover.current(storedDue: at(1, 8, month: 1), recurrence: .daily, now: at(2, 10), calendar: calendar)
        XCTAssertEqual(behind.due, at(2, 8))
        XCTAssertGreaterThan(behind.missed, 250)
        let behindEvening = ReminderRollover.current(storedDue: at(1, 20, month: 1), recurrence: .daily, now: at(2, 10), calendar: calendar)
        XCTAssertEqual(behindEvening.due, at(2, 20), "jumping near now doesn't overshoot today's")
        let once = ReminderRollover.current(storedDue: at(1, 8), recurrence: .never, now: at(5, 8), calendar: calendar)
        XCTAssertEqual(once.due, at(1, 8))
        XCTAssertEqual(once.missed, 0)
    }

    func testNotYetDueStaysPut() {
        let today = ReminderRollover.current(storedDue: at(2, 20), recurrence: .daily, now: at(2, 10), calendar: calendar)
        XCTAssertEqual(today.due, at(2, 20))
        XCTAssertEqual(today.missed, 0)
    }

    func testAnInstanceIsNamedByItsDue() {
        let id = ReminderRollover.occurrenceID(reminder: "ABC-1", instanceDue: at(16, 20))
        XCTAssertEqual(ReminderRollover.instanceDue(occurrenceID: id), at(16, 20))
        XCTAssertNil(ReminderRollover.instanceDue(occurrenceID: ReminderRollover.occurrenceID(reminder: "ABC-1", instanceDue: nil)))
        XCTAssertNil(ReminderRollover.instanceDue(occurrenceID: "event:x:12"))
    }

    func testMissedItMovesOnToTheNextInstance() {
        XCTAssertEqual(ReminderRollover.next(after: at(5, 9), recurrence: .weekly, calendar: calendar), at(12, 9))
        XCTAssertEqual(ReminderRollover.next(after: at(2, 8), recurrence: .daily, calendar: calendar), at(3, 8))
        XCTAssertNil(ReminderRollover.next(after: at(2, 8), recurrence: .never, calendar: calendar))
    }
}

final class ReminderMissedTests: XCTestCase {
    func testMissedOnesAreSaidInTheirOwnUnits() {
        XCTAssertEqual(ReminderMissed(count: 1, every: .daily).text, "Missed yesterday")
        XCTAssertEqual(ReminderMissed(count: 3, every: .daily).text, "Missed 3 days")
        XCTAssertEqual(ReminderMissed(count: 1, every: .weekly).text, "Missed last week")
        XCTAssertEqual(ReminderMissed(count: 2, every: .monthly).text, "Missed 2 months")
    }
}

/// What was missed before a reminder Banana moved on, kept beside it.
@MainActor
final class MissedRepeatsLedgerTests: XCTestCase {
    private typealias Ledger = MissedRepeats.Ledger
    private let day = Date(timeIntervalSinceReferenceDate: 813_000_000)

    func testACountHoldsOnTheDayItStandsAtAndLapsesAfter() {
        let keys = Ledger.keys(externalID: "abc", title: "Creatine")
        let entries = ["id:abc": Ledger.Entry(due: day, count: 2)]
        XCTAssertEqual(Ledger.count(entries, keys: keys, on: day.addingTimeInterval(3_600)), 2)
        XCTAssertNil(Ledger.count(entries, keys: keys, on: day.addingTimeInterval(86_400)),
                     "ticked, the reminder moves on and the count says nothing")
    }

    func testTheTitleFindsACopyWithAnotherID() {
        let entries = ["title:creatine": Ledger.Entry(due: day, count: 1)]
        XCTAssertEqual(Ledger.count(entries, keys: Ledger.keys(externalID: "other", title: "Creatine"), on: day), 1)
    }

    func testItSurvivesTheRoundTripAndOldOnesArePruned() {
        let entries = ["id:a": Ledger.Entry(due: day, count: 1),
                       "id:old": Ledger.Entry(due: day.addingTimeInterval(-60 * 86_400), count: 4)]
        XCTAssertEqual(Ledger.decode(Ledger.encode(entries)), entries)
        XCTAssertEqual(Array(Ledger.pruned(entries, now: day).keys), ["id:a"])
        var bad = Ledger.encode(entries)
        bad["id:broken"] = "nonsense"
        XCTAssertEqual(Ledger.decode(bad).count, 2)
    }
}
