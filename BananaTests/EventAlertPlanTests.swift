import XCTest

/// Which calendar events get a "starting soon" notification.
///
/// A notification that never arrives is indistinguishable from an event that never had one, so
/// the rules are tested directly rather than left to be noticed in the wild.
final class EventAlertPlanTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testCalendarMuteKeepsOtherCalendarsAndMergedInvitationsAudible() throws {
        let wife = GoogleCalendarIDs.calendarInfoID("wife@example.com")
        let mine = GoogleCalendarIDs.calendarInfoID("me@example.com")
        XCTAssertFalse(EventAlertPlan.allows(calendarID: wife, muted: ["wife@example.com"]))
        XCTAssertFalse(EventAlertPlan.allows(calendarID: wife, muted: [wife]), "Exclusions use info IDs")
        XCTAssertTrue(EventAlertPlan.allows(calendarID: mine, muted: ["wife@example.com"]))
        XCTAssertTrue(EventAlertPlan.allows(calendarID: wife, alsoOn: [mine], muted: ["wife@example.com"]))
        XCTAssertFalse(EventAlertPlan.allows(calendarID: wife, alsoOn: [mine], muted: ["wife@example.com", "me@example.com"]))
        XCTAssertTrue(EventAlertPlan.allows(calendarID: nil, muted: ["wife@example.com"]))
        var settings = SmartScheduleSettings()
        settings.mutedCalendarIDs = ["wife@example.com"]
        let copy = try JSONDecoder().decode(SmartScheduleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(copy.mutedCalendarIDs, settings.mutedCalendarIDs)
        XCTAssertTrue(copy.excludedCalendarIDs.isEmpty, "Muting must keep events and busy time")
        XCTAssertTrue(try JSONDecoder().decode(SmartScheduleSettings.self, from: Data("{}".utf8)).mutedCalendarIDs.isEmpty)
    }

    private func event(_ id: String, inMinutes: Double) -> EventAlertPlan.Candidate {
        EventAlertPlan.Candidate(id: id, title: "Event \(id)",
                                 start: now.addingTimeInterval(inMinutes * 60))
    }

    func testFiresTheChosenLeadTimeBeforeTheStart() {
        let items = EventAlertPlan.items(from: [event("a", inMinutes: 60)], leads: [15], now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].fireAt, now.addingTimeInterval(45 * 60))
    }

    func testEventsAlreadyStartedAreSkipped() {
        let items = EventAlertPlan.items(from: [event("past", inMinutes: -5)], leads: [10], now: now)
        XCTAssertTrue(items.isEmpty)
    }

    /// An event still to come whose only lead has already passed is worth announcing immediately,
    /// not dropping — otherwise a 30-minute lead silently loses everything in the next half hour.
    func testAnImminentEventStillFiresRatherThanBeingDropped() {
        let items = EventAlertPlan.items(from: [event("soon", inMinutes: 5)], leads: [30], now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertGreaterThan(items[0].fireAt, now)
        XCTAssertLessThan(items[0].fireAt, items[0].start)
    }

    func testEventsBeyondTheHorizonAreSkipped() {
        let items = EventAlertPlan.items(from: [event("far", inMinutes: 60 * 24 * 30)],
                                         leads: [10], now: now)
        XCTAssertTrue(items.isEmpty)
    }

    /// iOS keeps 64 pending notifications for the whole app and silently drops the rest, so events
    /// take a bounded share rather than starving the bedtime and leave-by alerts.
    func testThePendingCountIsCapped() {
        let many = (0..<200).map { event("e\($0)", inMinutes: Double($0 + 1) * 10) }
        let items = EventAlertPlan.items(from: many, leads: [5], now: now)
        XCTAssertEqual(items.count, EventAlertPlan.maximumPending)
    }

    /// When capped, the SOONEST events must survive — a cap that kept next week and dropped this
    /// afternoon would be worse than no notifications.
    func testTheCapKeepsTheSoonestEvents() {
        let many = (0..<200).map { event("e\($0)", inMinutes: Double($0 + 1) * 10) }
        let items = EventAlertPlan.items(from: many, leads: [5], now: now)
        XCTAssertTrue(items.first?.id.hasPrefix("e0#") == true)
        XCTAssertEqual(items, items.sorted { $0.fireAt < $1.fireAt })
    }

    func testDuplicateEventIDsProduceOneSetOfAlerts() {
        let items = EventAlertPlan.items(from: [event("a", inMinutes: 30), event("a", inMinutes: 30)],
                                         leads: [5], now: now)
        XCTAssertEqual(items.count, 1)
    }

    // MARK: - Several lead times per event

    /// The shipped default: told five minutes ahead, and again as it starts.
    func testTheDefaultGivesTwoAlertsPerEvent() {
        let items = EventAlertPlan.items(from: [event("a", inMinutes: 60)],
                                         leads: EventAlertPlan.defaultLeads, now: now)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.fireAt), [now.addingTimeInterval(55 * 60),
                                            now.addingTimeInterval(60 * 60)])
        XCTAssertEqual(Set(items.map(\.id)).count, 2, "each alert needs its own identifier")
    }

    /// An event closer than the longest lead should get the alerts that still make sense and no
    /// duplicate for the one that has passed — the reason the imminent-event rule only fires when
    /// nothing else would.
    func testAPassedLeadDoesNotAddAnExtraAlertWhenAnotherStillFires() {
        let items = EventAlertPlan.items(from: [event("a", inMinutes: 3)],
                                         leads: EventAlertPlan.defaultLeads, now: now)
        XCTAssertEqual(items.count, 1, "only the at-the-start alert is still ahead of us")
        XCTAssertEqual(items[0].fireAt, now.addingTimeInterval(3 * 60))
    }

    /// But an event whose every lead has passed is still announced rather than lost.
    func testAnEventWithEveryLeadPassedIsStillAnnounced() {
        let items = EventAlertPlan.items(from: [event("a", inMinutes: 2)], leads: [30, 15], now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertGreaterThan(items[0].fireAt, now)
        XCTAssertLessThan(items[0].fireAt, items[0].start)
    }

    func testTurningEveryLeadOffMeansNoAlerts() {
        XCTAssertTrue(EventAlertPlan.items(from: [event("a", inMinutes: 60)], leads: [], now: now).isEmpty)
    }

    /// The cap counts NOTIFICATIONS, not events — two leads means half as many events covered, and
    /// the soonest still have to win.
    func testTheCapCountsNotificationsAcrossLeads() {
        let many = (0..<200).map { event("e\($0)", inMinutes: Double($0 + 1) * 10) }
        let items = EventAlertPlan.items(from: many, leads: EventAlertPlan.defaultLeads, now: now)
        XCTAssertEqual(items.count, EventAlertPlan.maximumPending)
        XCTAssertEqual(items, items.sorted { $0.fireAt < $1.fireAt })
        XCTAssertTrue(items.first?.id.hasPrefix("e0#") == true)
    }

    /// Banana owns its own alerts. Whether the event also has a calendar alarm is irrelevant —
    /// an alarm on the data says nothing about whether any app is allowed to show it, and
    /// silencing another app's notifications is done in that app.
    func testEveryEventIsAnnouncedRegardlessOfWhatElseMight() {
        let items = EventAlertPlan.items(from: [event("a", inMinutes: 60), event("b", inMinutes: 90)],
                                         leads: [10], now: now)
        XCTAssertEqual(items.map(\.id).sorted(), ["a#10", "b#10"])
    }

    func testBodyNamesTheStartTime() {
        let item = EventAlertPlan.Item(id: "a", title: "Standup",
                                       start: now.addingTimeInterval(600), fireAt: now)
        let formatter = DateFormatter(); formatter.timeStyle = .short; formatter.dateStyle = .none
        XCTAssertTrue(EventAlertPlan.body(for: item, now: now, formatter: formatter).contains("10 minutes"))
    }
}
