import XCTest

/// Where the owner will be (`Whereabouts`, `WhereaboutsBuilder`, `WhereaboutsAdapter`;
/// docs/design/BOOKING.md §13): what the phone publishes so booking hours follow travel.
final class WhereaboutsBuilderTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let london = TimeZone(identifier: "Europe/London")!
    private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func event(_ title: String, _ start: String, _ end: String, location: String? = nil) -> WhereaboutsBuilder.Event {
        WhereaboutsBuilder.Event(title: title, location: location, notes: "Seat 14C, confirmation ABC123", start: at(start), end: at(end))
    }

    // Thursday 15 Oct 2026, a week in London from Saturday night, and two copies of the outbound
    // flight (the airline's and Google's own).
    private var now: Date { at("2026-10-15T12:00:00Z") }
    private var trip: [WhereaboutsBuilder.Event] {
        [event("Flight: New York (JFK) – London (LHR)", "2026-10-17T22:00:00Z", "2026-10-18T07:00:00Z"),
         event("Flight to London (BA 178)", "2026-10-17T22:01:00Z", "2026-10-18T07:00:00Z", location: "New York JFK"),
         event("Dinner with Sam", "2026-10-20T18:00:00Z", "2026-10-20T20:00:00Z", location: "London"),
         event("Flight: London (LHR) – New York (JFK)", "2026-10-28T11:00:00Z", "2026-10-28T19:00:00Z")]
    }

    func testStaysComeFromTheFlightsAndAStayAtHomesClockIsNone() {
        let flights = WhereaboutsBuilder.flights(from: trip)
        XCTAssertEqual(flights.count, 2, "two copies of one flight are one; dinner is no flight")
        let built = WhereaboutsBuilder.build(flights: flights, current: newYork, home: newYork, now: now)
        XCTAssertEqual(built.current, "America/New_York")
        XCTAssertEqual(built.home, "America/New_York")
        XCTAssertEqual(built.stays, [Whereabouts.Stay(from: at("2026-10-18T07:00:00Z"), to: at("2026-10-28T11:00:00Z"), zone: "Europe/London")])
        XCTAssertEqual(built.flights, [Whereabouts.Flight(departs: at("2026-10-17T22:00:00Z"), arrives: at("2026-10-18T07:00:00Z")),
                                       Whereabouts.Flight(departs: at("2026-10-28T11:00:00Z"), arrives: at("2026-10-28T19:00:00Z"))])
        XCTAssertEqual(built.updatedAt, now)
    }

    func testTheRecordCoversTheLongestBookingHorizonAndNoMore() {
        let flights = [TripTimeZone.Flight(departs: at("2026-10-14T08:00:00Z"), arrives: at("2026-10-14T16:00:00Z"), zone: london),   // yesterday
                       TripTimeZone.Flight(departs: at("2026-10-12T08:00:00Z"), arrives: at("2026-10-12T16:00:00Z"), zone: london),   // long gone
                       TripTimeZone.Flight(departs: at("2027-01-10T08:00:00Z"), arrives: at("2027-01-10T16:00:00Z"), zone: london),   // day 87
                       TripTimeZone.Flight(departs: at("2027-01-20T08:00:00Z"), arrives: at("2027-01-20T16:00:00Z"), zone: london)]   // day 97
        let built = WhereaboutsBuilder.build(flights: flights, current: newYork, home: newYork, now: now)
        XCTAssertEqual(built.flights.map(\.departs), [at("2026-10-14T08:00:00Z"), at("2027-01-10T08:00:00Z")])
        XCTAssertGreaterThanOrEqual(WhereaboutsBuilder.horizonDays, 91, "the booking horizon is up to 90 days, from today")
        // The window reaches the 90th day's end wherever "now" falls in a day.
        XCTAssertGreaterThan(now.addingTimeInterval(Double(WhereaboutsBuilder.horizonDays) * 86_400), now.addingTimeInterval(91 * 86_400 - 1))
    }

    func testOnlyNewsIsPublishedAndADayOldCopyIsSaidAgain() {
        let first = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: trip), current: newYork, home: newYork, now: now)
        XCTAssertTrue(WhereaboutsBuilder.shouldPublish(first, over: nil))
        let again = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: trip), current: newYork, home: newYork,
                                             now: now.addingTimeInterval(3_600))
        XCTAssertTrue(again.sameContent(as: first))
        XCTAssertFalse(WhereaboutsBuilder.shouldPublish(again, over: first), "an hour on, nothing new")
        let tomorrow = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: trip), current: newYork, home: newYork,
                                                now: now.addingTimeInterval(86_400))
        XCTAssertTrue(WhereaboutsBuilder.shouldPublish(tomorrow, over: first), "a day on: said again, so the service keeps trusting it")
        let landed = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: trip), current: london, home: newYork,
                                              now: now.addingTimeInterval(3_600))
        XCTAssertTrue(WhereaboutsBuilder.shouldPublish(landed, over: first), "the phone changed zone")
        let cancelled = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: Array(trip.prefix(2))), current: newYork,
                                                 home: newYork, now: now.addingTimeInterval(3_600))
        XCTAssertTrue(WhereaboutsBuilder.shouldPublish(cancelled, over: first), "a flight went")
    }

    /// The record says when and in which zone, nothing else: no airport, city, title or place.
    func testThePayloadIsOnlyTimesAndZones() throws {
        let built = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: trip), current: newYork, home: newYork, now: now)
        let encoded = try SyncShape.wrapped.encode(built)
        guard case .object(let outer) = encoded, outer.keys.sorted() == ["v"], case .object(let fields)? = outer["v"] else {
            return XCTFail("one field, v: \(encoded)")
        }
        XCTAssertEqual(fields.keys.sorted(), ["current", "flights", "home", "stays", "updatedAt"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let text = String(decoding: try encoder.encode(encoded), as: UTF8.self)
        for word in ["JFK", "LHR", "London (", "BA 178", "Dinner", "Sam", "ABC123", "Seat"] {
            XCTAssertFalse(text.contains(word), "\(word) left the phone: \(text)")
        }
        let zones = Set(text.matches(of: /"(?:zone|current|home)":"([^"]+)"/).map { String($0.1) })
        XCTAssertEqual(zones, ["America/New_York", "Europe/London"])
        // Times are milliseconds, as the service reads them.
        XCTAssertTrue(text.contains("\"updatedAt\":\(Int64(now.timeIntervalSince1970 * 1000))"))
        XCTAssertEqual(try SyncShape.wrapped.decode(Whereabouts.self, from: outer), built)
    }

    /// Two thousand located events over three months (far more than a heavy calendar has: only
    /// events with a location reach the builder) — measured, not budgeted: the app builds on a
    /// utility-priority detached task, debounced, never on the main thread. Debug simulator,
    /// 9 Nov 2026: 0.185 s average for the 2,000.
    func testBuildingFromAHeavyCalendarIsCheap() {
        var events: [WhereaboutsBuilder.Event] = []
        for day in 0..<92 {
            let base = now.addingTimeInterval(Double(day) * 86_400)
            for n in 0..<21 {
                events.append(WhereaboutsBuilder.Event(title: "Meeting \(n) with the team about the plan", location: n % 3 == 0 ? "Room 4" : nil,
                                                       notes: nil, start: base.addingTimeInterval(Double(n) * 1_800),
                                                       end: base.addingTimeInterval(Double(n) * 1_800 + 1_800)))
            }
            if day % 10 == 0 { events.append(event("Flight: New York (JFK) – London (LHR)", "2026-10-17T22:00:00Z", "2026-10-18T07:00:00Z")) }
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = WhereaboutsBuilder.build(flights: WhereaboutsBuilder.flights(from: events), current: newYork, home: newYork, now: now)
        }
    }
}

@MainActor
final class WhereaboutsAdapterTests: XCTestCase {
    private final class Source: WhereaboutsSyncSource {
        var syncWhereabouts: Whereabouts?
        func adoptSyncedWhereabouts(_ value: Whereabouts) {
            guard value.updatedAt > (syncWhereabouts?.updatedAt ?? .distantPast) else { return }
            syncWhereabouts = value
        }
    }

    private var catalog: DataCatalog!
    private var server: MemorySyncServer!

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        catalog = try DataCatalog.decode(Data(contentsOf: url))
        server = MemorySyncServer(catalog: catalog)
        server.hubDevices = ["phone"]
    }

    private func engine(_ device: String, hub: Bool, _ source: Source) async throws -> SpaceSync {
        var config = SpaceSync.Configuration(device: device, isHub: hub, catalog: catalog)
        config.debounce = .seconds(3_600)
        let engine = try SpaceSync(mirror: RecordMirror(), transport: MemoryTransport(server: server, device: device), config: config)
        await engine.registerAdapter(WhereaboutsAdapter.adapter(source))
        return engine
    }

    func testTheTypeIsTheServicesOwnAndThePhonesToWrite() {
        let entry = catalog[WhereaboutsAdapter.type]
        XCTAssertEqual(entry?.writers, .hub)
        XCTAssertEqual(entry?.tier, .t1)
        XCTAssertTrue(EverythingElseTypes.all.contains(WhereaboutsAdapter.type))
        XCTAssertTrue(LegacyInventory.withoutLegacy.contains(WhereaboutsAdapter.type), "seeded on its own, never moved off iCloud")
    }

    func testThePhonesRecordReachesTheServiceAndTheIPadAndBack() async throws {
        let phone = Source(), iPad = Source()
        let value = Whereabouts(current: "America/New_York", home: "America/New_York",
                                stays: [.init(from: Date(timeIntervalSince1970: 1_792_306_800), to: Date(timeIntervalSince1970: 1_793_185_200), zone: "Europe/London")],
                                flights: [.init(departs: Date(timeIntervalSince1970: 1_792_274_400), arrives: Date(timeIntervalSince1970: 1_792_306_800))],
                                updatedAt: Date(timeIntervalSince1970: 1_792_065_600))
        phone.syncWhereabouts = value
        let p = try await engine("phone", hub: true, phone)
        await p.seed(types: [WhereaboutsAdapter.type])
        await p.syncNow(reason: "test")

        let record = try XCTUnwrap(server.record(WhereaboutsAdapter.type, WhereaboutsAdapter.id))
        XCTAssertEqual(record.fields.keys.sorted(), ["v"], "merged whole: one field")
        XCTAssertEqual(try SyncShape.wrapped.decode(Whereabouts.self, from: record.fields), value)

        let i = try await engine("ipad", hub: false, iPad)
        await i.setHubPresence(.seeded([WhereaboutsAdapter.type]))
        await i.seed(types: [WhereaboutsAdapter.type])
        await i.syncNow(reason: "test")
        XCTAssertEqual(iPad.syncWhereabouts, value)
    }
}
