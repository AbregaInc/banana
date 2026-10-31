import UserNotifications
import XCTest

// Booking on the app's side (docs/design/BOOKING.md §12, Stage E): the handle's rules and
// suggestions (the service's own, `Service/src/booking/types.js`), the booking type as the record
// the service reads, the store's default-type rule, the adapter between two devices through the
// in-memory service, and the booking calls' shapes (`Service/src/booking/api.js`).

// MARK: - The handle

final class BookingHandleTests: XCTestCase {
    func testAHandleIsThreeToThirtyLowerCaseLettersDigitsOrSingleDashesAndNotReserved() {
        XCTAssertNil(BookingHandle.problem("noor"))
        XCTAssertNil(BookingHandle.problem("noor-haddad"))
        XCTAssertNil(BookingHandle.problem("b0r"))
        XCTAssertEqual(BookingHandle.problem("bo"), .invalid)
        XCTAssertEqual(BookingHandle.problem(String(repeating: "a", count: 31)), .invalid)
        XCTAssertEqual(BookingHandle.problem("Noor"), .invalid, "the service takes lower case only")
        XCTAssertEqual(BookingHandle.problem("-noor"), .invalid)
        XCTAssertEqual(BookingHandle.problem("noor-"), .invalid)
        XCTAssertEqual(BookingHandle.problem("bo--ris"), .invalid)
        XCTAssertEqual(BookingHandle.problem("borís"), .invalid)
        XCTAssertEqual(BookingHandle.problem("api"), .reserved)
        XCTAssertEqual(BookingHandle.problem("well-known"), .reserved)
    }

    func testWhatIsTypedIsTrimmedLowerCasedAndSpacedWithDashes() {
        XCTAssertEqual(BookingHandle.normalised("  Noor Haddad "), "noor-haddad")
    }

    /// The same answers as the service's `handleIdeas` (run with node, 20 Oct 2026).
    func testSuggestionsMatchTheServicesFromTheNameThenTheEmail() {
        XCTAssertEqual(BookingHandle.ideas(name: "Noor Haddad", email: "noor@plan.example"),
                       ["noor", "noor-haddad", "noorhaddad", "noorh"])
        XCTAssertEqual(BookingHandle.ideas(name: "José Núñez", email: "first.last+tag@x.com"),
                       ["jose", "jose-nunez", "josenunez", "josen", "first-last-tag"])
        XCTAssertEqual(BookingHandle.ideas(name: nil, email: "-a.b-@x.com"), ["a-b"])
        XCTAssertEqual(BookingHandle.ideas(name: "Al", email: "al@x.com"), [], "too short to be a handle")
    }

    func testTheLinkIsTheSiteAndTheHandleAndShowsWithoutItsScheme() throws {
        let url = try XCTUnwrap(BookingHandle.link(base: "https://book.bananatheapp.com/", handle: "noor"))
        XCTAssertEqual(url.absoluteString, "https://book.bananatheapp.com/noor")
        XCTAssertEqual(BookingHandle.display(url), "book.bananatheapp.com/noor")
    }
}

// MARK: - The type as a record

final class BookingTypeRecordTests: XCTestCase {
    /// The service's `defaultType("America/New_York")` is `normaliseType` of exactly these fields
    /// (checked with node): the app's default is the service's default.
    func testTheDefaultTypesFieldsAreTheServicesDefault() throws {
        let fields = try CanonicalJSON.fields(of: BookingType.standard(zone: "America/New_York"))
        let expected = try JSONDecoder().decode([String: JSONValue].self, from: Data("""
        {"active":true,"bufferAfter":0,"bufferBefore":0,"horizonDays":30,
         "hours":[[],[[540,1020]],[[540,1020]],[[540,1020]],[[540,1020]],[[540,1020]],[]],
         "locations":[{"id":"meet","kind":"meet"}],"minutes":30,"notice":240,"order":0,"slug":"meeting",
         "timeZone":"America/New_York","title":"Meeting"}
        """.utf8))
        XCTAssertEqual(fields, expected)
        XCTAssertNil(fields["perDay"], "no limit is no field")
        XCTAssertNil(fields["step"], "the service works the step out from the length")
        XCTAssertNil(fields["calendar"], "the primary calendar of the oldest link")
    }

    func testAPlaceSendsOnlyWhatItsKindUses() throws {
        var type = BookingType.standard(zone: "UTC")
        type.locations = [BookingPlace(kind: .phoneHostCalls, url: "https://zoom.us/j/1", phone: "+1 555 0100"),
                          BookingPlace(kind: .phoneGuestCalls, phone: "+1 555 0100")]
        let places = try CanonicalJSON.fields(of: type)["locations"]
        let decoded = try JSONDecoder().decode([[String: String]].self, from: JSONEncoder().encode(XCTUnwrap(places)))
        XCTAssertEqual(decoded, [["id": "phone", "kind": "phone_host_calls"],
                                 ["id": "phone", "kind": "phone_guest_calls", "phone": "+1 555 0100"]])
    }

    func testAMissingFieldTakesTheServicesDefaultAndAnUnknownPlaceIsLeftOut() throws {
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data("""
        {"title":"Intro","slug":"intro","minutes":15,
         "locations":[{"id":"x","kind":"teleport"},{"id":"zoom","kind":"zoom","url":"https://zoom.us/j/1"}]}
        """.utf8))
        let type = try SyncShape.fields.decode(BookingType.self, from: fields)
        XCTAssertEqual(type.minutes, 15)
        XCTAssertEqual(type.hours, BookingType.weekdays9to5)
        XCTAssertEqual(type.notice, 240)
        XCTAssertEqual(type.horizonDays, 30)
        XCTAssertTrue(type.active)
        XCTAssertEqual(type.locations, [BookingPlace(kind: .zoom, url: "https://zoom.us/j/1")])
    }

    func testOnePhonePlaceWhoeverCalls() {
        var type = BookingType.standard(zone: "UTC")
        type.set(.phoneHostCalls, to: BookingPlace(kind: .phoneHostCalls))
        type.set(.phoneGuestCalls, to: BookingPlace(kind: .phoneGuestCalls, phone: "+1 555"))
        XCTAssertEqual(type.locations.map(\.kind), [.meet, .phoneGuestCalls], "they call me replaced I call them")
        type.set(.phoneHostCalls, to: nil)
        XCTAssertEqual(type.locations.map(\.kind), [.meet])
    }

    func testAPlaceTheServiceWouldDropIsNotUsable() {
        XCTAssertFalse(BookingPlace(kind: .zoom, url: "http://zoom.us/j/1").isUsable, "https only")
        XCTAssertFalse(BookingPlace(kind: .zoom, url: "").isUsable)
        XCTAssertTrue(BookingPlace(kind: .zoom, url: "https://us02web.zoom.us/j/1").isUsable)
        XCTAssertFalse(BookingPlace(kind: .phoneGuestCalls, phone: " ").isUsable)
        XCTAssertFalse(BookingPlace(kind: .inPerson, address: "").isUsable)
        XCTAssertTrue(BookingPlace(kind: .phoneHostCalls).isUsable)
        XCTAssertTrue(BookingPlace.isZoom(URL(string: "https://us02web.zoom.us/j/1")!))
    }

    func testASlugComesFromTheTitleAndIsUnique() {
        XCTAssertEqual(BookingSlug.make(from: "Intro call", taken: []), "intro-call")
        XCTAssertEqual(BookingSlug.make(from: "Intro call", taken: ["intro-call"]), "intro-call-2")
        XCTAssertEqual(BookingSlug.make(from: "Intro call", taken: ["intro-call", "intro-call-2"]), "intro-call-3")
        XCTAssertEqual(BookingSlug.make(from: "Café ☕ chat!", taken: []), "cafe-chat")
        XCTAssertEqual(BookingSlug.make(from: "☕", taken: []), "meeting")
    }

    func testTheDeviceZoneIsOneTheServiceTakes() {
        XCTAssertEqual(BookingType.deviceZone(TimeZone(identifier: "Europe/Sofia")!), "Europe/Sofia")
        XCTAssertEqual(BookingType.deviceZone(TimeZone(secondsFromGMT: 3_600)!), "UTC", "an offset isn't a zone")
    }
}

// MARK: - The store

@MainActor
final class BookingTypeStoreTests: XCTestCase {
    private var folder: URL!
    private var changed: [String] = []
    private var deleted: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("booking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func store() -> BookingTypeStore {
        let store = BookingTypeStore(directory: folder)
        store.report = { [weak self] changed, deleted in
            self?.changed += changed
            self?.deleted += deleted
        }
        return store
    }

    func testNothingIsMadeUntilBookingOpensThenTheDefaultIsShownAndNotSent() {
        let store = store()
        XCTAssertTrue(store.entries.isEmpty, "never at launch")
        store.openedBooking(zone: "Europe/Sofia")
        XCTAssertEqual(store.types.map(\.id), [BookingTypeStore.defaultID])
        XCTAssertEqual(store.types.first?.type, .standard(zone: "Europe/Sofia"))
        XCTAssertTrue(store.syncTypes.isEmpty, "the service offers the same default by itself")
        XCTAssertTrue(changed.isEmpty)
        store.openedBooking(zone: "America/New_York")
        XCTAssertEqual(store.types.first?.type.timeZone, "Europe/Sofia", "made once")
        XCTAssertEqual(BookingTypeStore(directory: folder).types.first?.unsent, true, "kept across launches")
    }

    func testChangingTheDefaultSendsItUnderTheIDEveryDeviceUses() {
        let store = store()
        store.pullCompleted()
        store.openedBooking(zone: "UTC")
        store.update(BookingTypeStore.defaultID) { $0.minutes = 30 }
        XCTAssertTrue(changed.isEmpty, "no change, nothing sent")
        store.update(BookingTypeStore.defaultID) { $0.minutes = 45 }
        XCTAssertEqual(changed, [BookingTypeStore.defaultID])
        XCTAssertEqual(store.syncTypes[BookingTypeStore.defaultID]?.type.minutes, 45)
    }

    func testAChangeToTheDefaultBeforeThePullWaitsForIt() {
        let store = store()
        store.openedBooking(zone: "UTC")
        store.update(BookingTypeStore.defaultID) { $0.minutes = 45 }
        XCTAssertTrue(changed.isEmpty, "held: the account's own default may still be on its way")
        XCTAssertTrue(store.syncTypes.isEmpty)
        XCTAssertEqual(store.entry(BookingTypeStore.defaultID)?.held, true)
        XCTAssertEqual(BookingTypeStore(directory: folder).entry(BookingTypeStore.defaultID)?.held, true, "kept across launches")
        store.pullCompleted()
        XCTAssertEqual(changed, [BookingTypeStore.defaultID], "nothing arrived: it goes up as made here")
        XCTAssertEqual(store.syncTypes[BookingTypeStore.defaultID]?.type.minutes, 45)
    }

    func testAHeldDefaultIsLaidOverTheAccountsOwnFieldByField() {
        let store = store()
        store.openedBooking(zone: "UTC")
        store.update(BookingTypeStore.defaultID) { $0.title = "Chat" }
        var theirs = BookingType.standard(zone: "UTC")
        theirs.minutes = 60
        theirs.notice = 0
        let keptOwn = store.applySynced(BookingTypeStore.defaultID, theirs)
        XCTAssertTrue(keptOwn, "what was changed here goes up over theirs")
        let merged = store.entry(BookingTypeStore.defaultID)?.type
        XCTAssertEqual(merged?.title, "Chat", "changed here")
        XCTAssertEqual(merged?.minutes, 60, "theirs, not the default's 30")
        XCTAssertEqual(merged?.notice, 0)
        XCTAssertEqual(store.entry(BookingTypeStore.defaultID)?.held, false)
        XCTAssertFalse(store.applySynced(BookingTypeStore.defaultID, theirs), "an ordinary arrival afterwards")
    }

    func testAZoneChangedOnTheHeldDefaultCountsAsChanged() {
        let store = store()
        store.openedBooking(zone: "Europe/Sofia")
        store.update(BookingTypeStore.defaultID) { $0.timeZone = "America/New_York" }
        var theirs = BookingType.standard(zone: "Europe/London")
        theirs.minutes = 60
        XCTAssertTrue(store.applySynced(BookingTypeStore.defaultID, theirs))
        let merged = store.entry(BookingTypeStore.defaultID)?.type
        XCTAssertEqual(merged?.timeZone, "America/New_York", "measured from the zone it was made in, not its own")
        XCTAssertEqual(merged?.minutes, 60)
    }

    func testAnUnchangedZoneTakesTheAccountsOwn() {
        let store = store()
        store.openedBooking(zone: "Europe/Sofia")
        store.update(BookingTypeStore.defaultID) { $0.title = "Chat" }
        let theirs = BookingType.standard(zone: "Europe/London")
        XCTAssertTrue(store.applySynced(BookingTypeStore.defaultID, theirs))
        XCTAssertEqual(store.entry(BookingTypeStore.defaultID)?.type.timeZone, "Europe/London")
    }

    func testAddingATypeSendsTheShownDefaultTooWithAUniqueSlugLast() throws {
        let store = store()
        store.pullCompleted()
        store.openedBooking(zone: "UTC")
        var intro = BookingType.standard(zone: "UTC")
        intro.title = "Meeting"
        let id = store.add(intro)
        XCTAssertEqual(Set(changed), [BookingTypeStore.defaultID, id])
        let added = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(added.type.slug, "meeting-2", "the default has meeting")
        XCTAssertEqual(added.type.order, 1)
        XCTAssertEqual(store.types.map(\.id), [BookingTypeStore.defaultID, id])
    }

    func testTheSlugStaysWhenTheTitleChangesSoGuestsLinksKeepWorking() throws {
        let store = store()
        var type = BookingType.standard(zone: "UTC")
        type.title = "Intro call"
        let id = store.add(type)
        store.update(id) {
            $0.title = "First chat"
            $0.slug = "first-chat"
        }
        XCTAssertEqual(store.entry(id)?.type.title, "First chat")
        XCTAssertEqual(store.entry(id)?.type.slug, "intro-call")
    }

    func testTheAccountsTypesArrivingReplaceTheShownDefault() {
        let store = store()
        store.openedBooking(zone: "UTC")
        var intro = BookingType.standard(zone: "UTC")
        intro.title = "Intro"
        intro.slug = "intro"
        store.applySynced("abc", intro)
        XCTAssertEqual(store.types.map(\.id), ["abc"])
        XCTAssertTrue(changed.isEmpty, "what arrived isn't sent back")
    }

    func testRemovingAndRestoring() {
        let store = store()
        var type = BookingType.standard(zone: "UTC")
        type.title = "Coffee"
        let id = store.add(type)
        let entry = store.entry(id)!
        store.remove(id)
        XCTAssertEqual(deleted, [id])
        store.restore(entry)
        XCTAssertEqual(store.entry(id)?.type.title, "Coffee")
        XCTAssertEqual(changed.last, id)
    }
}

// MARK: - Between devices

@MainActor
final class BookingTypeAdapterTests: XCTestCase {
    private var catalog: DataCatalog!
    private var server: MemorySyncServer!
    private var folders: [URL] = []

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        catalog = try DataCatalog.decode(Data(contentsOf: url))
        server = MemorySyncServer(catalog: catalog)
        server.hubDevices = ["phone"]
    }

    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func store() throws -> BookingTypeStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("booking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return BookingTypeStore(directory: folder)
    }

    private func engine(_ device: String, hub: Bool, _ store: BookingTypeStore) async throws -> SpaceSync {
        var config = SpaceSync.Configuration(device: device, isHub: hub, catalog: catalog)
        config.debounce = .seconds(3_600)   // the tests run passes themselves
        let engine = try SpaceSync(mirror: RecordMirror(), transport: MemoryTransport(server: server, device: device), config: config)
        await engine.registerAdapter(BookingTypeAdapter.adapter(store))
        store.report = { changed, deleted in
            engine.changed(type: BookingTypeAdapter.type, ids: changed)
            engine.deleted(type: BookingTypeAdapter.type, ids: deleted)
        }
        return engine
    }

    func testTheTypeIsInTheCatalogAndHasItsAdapter() {
        XCTAssertNotNil(catalog[BookingTypeAdapter.type])
        XCTAssertTrue(EverythingElseTypes.all.contains(BookingTypeAdapter.type))
        XCTAssertTrue(EverythingElseTypes.withoutAdapter.isEmpty)
        XCTAssertTrue(LegacyInventory.withoutLegacy.contains(BookingTypeAdapter.type), "seeded on its own, never moved off iCloud")
    }

    func testATypeMadeOnThePhoneReachesTheIPadAndTheServiceReadsItsFields() async throws {
        let phone = try store(), iPad = try store()
        var intro = BookingType.standard(zone: "Europe/Sofia")
        intro.title = "Intro call"
        intro.minutes = 15
        intro.locations = [BookingPlace(kind: .zoom, url: "https://us02web.zoom.us/j/1")]
        let p = try await engine("phone", hub: true, phone)
        await p.seed(types: [BookingTypeAdapter.type])
        let id = phone.add(intro)
        await p.syncNow(reason: "test")

        let record = try XCTUnwrap(server.record(BookingTypeAdapter.type, id))
        XCTAssertEqual(record.fields["slug"]?.stringValue, "intro-call")
        XCTAssertEqual(record.fields["timeZone"]?.stringValue, "Europe/Sofia")

        let i = try await engine("ipad", hub: false, iPad)
        await i.setHubPresence(.seeded([BookingTypeAdapter.type]))
        await i.seed(types: [BookingTypeAdapter.type])
        await i.syncNow(reason: "test")
        XCTAssertEqual(iPad.entry(id)?.type, phone.entry(id)?.type)
        XCTAssertEqual(iPad.entry(id)?.type.minutes, 15)
    }

    func testTwoDevicesChangingDifferentFieldsBothStandAndADeleteGoesEverywhere() async throws {
        let phone = try store(), iPad = try store()
        let p = try await engine("phone", hub: true, phone)
        await p.seed(types: [BookingTypeAdapter.type])
        var type = BookingType.standard(zone: "UTC")
        type.title = "Coffee"
        let id = phone.add(type)
        await p.syncNow(reason: "test")
        let i = try await engine("ipad", hub: false, iPad)
        await i.setHubPresence(.seeded([BookingTypeAdapter.type]))
        await i.seed(types: [BookingTypeAdapter.type])
        await i.syncNow(reason: "test")
        XCTAssertNotNil(iPad.entry(id))

        phone.update(id) { $0.minutes = 45 }
        iPad.update(id) { $0.title = "Coffee walk" }
        await p.syncNow(reason: "test")
        await i.syncNow(reason: "test")
        await p.syncNow(reason: "test")
        XCTAssertEqual(phone.entry(id)?.type.minutes, 45)
        XCTAssertEqual(phone.entry(id)?.type.title, "Coffee walk")
        XCTAssertEqual(iPad.entry(id)?.type.minutes, 45)
        XCTAssertEqual(iPad.entry(id)?.type.title, "Coffee walk")

        iPad.remove(id)
        await i.syncNow(reason: "test")
        await p.syncNow(reason: "test")
        XCTAssertNil(phone.entry(id))
    }

    func testTheShownDefaultIsNeverSentSoItCantOverwriteTheAccountsOwn() async throws {
        let phone = try store(), mac = try store()
        let p = try await engine("phone", hub: true, phone)
        await p.seed(types: [BookingTypeAdapter.type])
        await p.syncNow(reason: "test")   // the phone has pulled: its change goes at once
        phone.openedBooking(zone: "UTC")
        phone.update(BookingTypeStore.defaultID) { $0.minutes = 60 }
        await p.syncNow(reason: "test")

        // The Mac opens Booking before anything has arrived: its own default shows, unsent.
        mac.openedBooking(zone: "UTC")
        let m = try await engine("mac", hub: false, mac)
        await m.setHubPresence(.seeded([BookingTypeAdapter.type]))
        await m.seed(types: [BookingTypeAdapter.type])
        await m.syncNow(reason: "test")
        XCTAssertEqual(mac.entry(BookingTypeStore.defaultID)?.type.minutes, 60, "the phone's edit stands")
        XCTAssertEqual(server.record(BookingTypeAdapter.type, BookingTypeStore.defaultID)?.fields["minutes"], .int(60))
    }

    /// Fable's case: the Mac changes the default before the phone's has reached it. Only what the
    /// Mac changed goes up, at the Mac's clock; the phone's own changes stand.
    func testTheDefaultEditedBeforeTheAccountsArrivedOnlySendsWhatChanged() async throws {
        let phone = try store(), mac = try store()
        let p = try await engine("phone", hub: true, phone)
        await p.seed(types: [BookingTypeAdapter.type])
        await p.syncNow(reason: "test")
        phone.openedBooking(zone: "UTC")
        phone.update(BookingTypeStore.defaultID) {
            $0.minutes = 60
            $0.notice = 0
        }
        await p.syncNow(reason: "test")

        mac.openedBooking(zone: "UTC")
        mac.update(BookingTypeStore.defaultID) { $0.title = "Chat" }   // before its first pull: held
        let m = try await engine("mac", hub: false, mac)
        await m.setHubPresence(.seeded([BookingTypeAdapter.type]))
        await m.seed(types: [BookingTypeAdapter.type])
        await m.syncNow(reason: "test")
        await m.syncNow(reason: "test")
        await p.syncNow(reason: "test")

        for store in [phone, mac] {
            let type = try XCTUnwrap(store.entry(BookingTypeStore.defaultID)?.type)
            XCTAssertEqual(type.title, "Chat")
            XCTAssertEqual(type.minutes, 60, "the phone's change was not overwritten by the Mac's default")
            XCTAssertEqual(type.notice, 0)
        }
        let record = try XCTUnwrap(server.record(BookingTypeAdapter.type, BookingTypeStore.defaultID))
        XCTAssertTrue(record.clocks["title"]?.hasSuffix("mac") == true, "the Mac's change: \(record.clocks["title"] ?? "")")
        XCTAssertTrue(record.clocks["minutes"]?.hasSuffix("phone") == true, "still the phone's: \(record.clocks["minutes"] ?? "")")
    }
}

// MARK: - The booking calls

final class BookingServiceTests: XCTestCase {
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testTheCallsGoWhereTheHostAPIIs() throws {
        let read = BananaService.request(.booking, host: "service.example", session: "s")
        XCTAssertEqual(read.httpMethod, "GET")
        XCTAssertEqual(read.url?.absoluteString, "https://service.example/v1/booking")
        XCTAssertEqual(read.value(forHTTPHeaderField: "Authorization"), "Bearer s")

        let claim = BananaService.request(.claimHandle(handle: "noor", timeZone: "Europe/Sofia"), host: "service.example", session: "s")
        XCTAssertEqual(claim.httpMethod, "PUT")
        XCTAssertEqual(claim.url?.path, "/v1/booking")
        let body = try json(claim)
        XCTAssertEqual(body["handle"] as? String, "noor")
        XCTAssertEqual(body["timeZone"] as? String, "Europe/Sofia")
        XCTAssertNil(body["name"], "the name stays the service's")

        let upcoming = BananaService.request(.upcomingBookings, host: "service.example", session: "s")
        XCTAssertEqual(upcoming.httpMethod, "GET")
        XCTAssertEqual(upcoming.url?.path, "/v1/booking/upcoming")
    }

    func testTheBookingStateReadsWithAndWithoutAHandle() throws {
        let none = try JSONDecoder().decode(BananaService.BookingState.self, from: Data("""
        {"handle":null,"link":null,"suggested":["noor","noor-haddad"],"name":"Noor Haddad","timeZone":null,"types":[]}
        """.utf8))
        XCTAssertNil(none.handle)
        XCTAssertEqual(none.suggested.first, "noor")
        XCTAssertNil(none.site)

        let some = try JSONDecoder().decode(BananaService.BookingState.self, from: Data("""
        {"handle":"noor","link":"https://beta-book.bananatheapp.com/noor","suggested":[],"name":"Noor","timeZone":"Europe/Sofia",
         "types":[{"slug":"meeting","title":"Meeting","active":true,"link":"https://beta-book.bananatheapp.com/noor/meeting"}]}
        """.utf8))
        XCTAssertEqual(some.handle, "noor")
        XCTAssertEqual(some.site, "https://beta-book.bananatheapp.com")
        XCTAssertEqual(some.types.first?.slug, "meeting")
        // Kept and read back as it was.
        XCTAssertEqual(try JSONDecoder().decode(BananaService.BookingState.self, from: JSONEncoder().encode(some)), some)
    }

    func testAClaimedHandleAndTheRefusals() throws {
        let claimed = try JSONDecoder().decode(BananaService.ClaimedHandle.self, from: Data("""
        {"handle":"noor","link":"https://book.bananatheapp.com/noor"}
        """.utf8))
        XCTAssertEqual(claimed.link.absoluteString, "https://book.bananatheapp.com/noor")
        XCTAssertEqual(BananaService.handleRefusal(status: 409, data: Data(#"{"error":"taken"}"#.utf8)), .taken)
        XCTAssertEqual(BananaService.handleRefusal(status: 400, data: Data(#"{"error":"reserved"}"#.utf8)), .reserved)
        XCTAssertEqual(BananaService.handleRefusal(status: 400, data: Data(#"{"error":"invalid"}"#.utf8)), .invalid)
        XCTAssertNil(BananaService.handleRefusal(status: 503, data: Data()), "the service down: asked again later")
        XCTAssertNil(BananaService.handleRefusal(status: 400, data: Data(#"{"error":"zone"}"#.utf8)), "the zone, not the handle")
        XCTAssertTrue(BananaService.zoneRefused(status: 400, data: Data(#"{"error":"zone"}"#.utf8)))
        XCTAssertFalse(BananaService.zoneRefused(status: 400, data: Data(#"{"error":"invalid"}"#.utf8)))
    }

    func testUpcomingBookingsReadTheServicesISOTimes() throws {
        let answer = try BananaService.UpcomingBookings.decode(Data("""
        {"bookings":[{"id":"m1","title":"Meeting","start":"2026-10-21T19:00:00.000Z","end":"2026-10-21T19:30:00.000Z",
          "status":"confirmed","invited":true,"guest":{"name":"Sam Lee","email":"sam@example.com","phone":null},
          "place":{"kind":"meet","detail":"https://meet.google.com/abc"}}]}
        """.utf8))
        let booking = try XCTUnwrap(answer.bookings.first)
        XCTAssertEqual(booking.start, Date(timeIntervalSince1970: 1_792_609_200))
        XCTAssertEqual(booking.end.timeIntervalSince(booking.start), 1_800)
        XCTAssertEqual(booking.guest.name, "Sam Lee")
        XCTAssertNil(booking.guest.phone)
        XCTAssertEqual(booking.place?.kind, "meet")
    }

    func testABookingPushNamesItsEventItsStartAndWhetherItWasCancelled() throws {
        let booked = try XCTUnwrap(BananaService.bookingTarget(
            ["b": ["k": "booking", "cal": "noor@plan.example", "event": "0f3a9c", "start": NSNumber(value: 1_792_609_200_000.0)]]))
        XCTAssertEqual(booked, .init(calendarID: "noor@plan.example", eventID: "0f3a9c",
                                     start: Date(timeIntervalSince1970: 1_792_609_200), cancelled: false))
        let cancelled = try XCTUnwrap(BananaService.bookingTarget(
            ["b": ["k": "booking", "cal": "c", "event": "e", "start": "2026-10-21T19:00:00.000Z", "status": "cancelled"]]))
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertEqual(cancelled.start, Date(timeIntervalSince1970: 1_792_609_200))
        XCTAssertEqual(BananaService.bookingTarget(["b": ["k": "booking", "cancelled": true]])?.cancelled, true)
        let bare = try XCTUnwrap(BananaService.bookingTarget(["b": ["k": "booking"]]), "today's pushes name nothing: the Plan opens")
        XCTAssertNil(bare.eventID)
        XCTAssertNil(bare.start)
        XCTAssertNil(BananaService.bookingTarget(["b": ["k": "alert", "cal": "c", "event": "e"]]))
    }

    func testABookingPushIsKnownByItsKind() {
        let push: [AnyHashable: Any] = ["aps": ["alert": ["title": "Booking", "body": "Sam booked Meeting, Tue 3:00 pm"],
                                                "thread-id": "booking"], "b": ["k": "booking"]]
        XCTAssertTrue(BananaService.isBookingPush(push))
        XCTAssertFalse(BananaService.isBookingPush(["b": ["k": "alert"]]))
        XCTAssertFalse(BananaService.isSyncPush(push))
    }
}

// MARK: - Notifications (the rule both delegates follow)

/// The iPhone's `MealPhotoNotificationDelegate` and the Mac's `MacNotificationDelegate` both act on
/// `NotificationRoute`: a Taken reminder shows over the app and "Taken" marks it on every device
/// (Fable's review: a second Mac delegate had replaced the one that did).
final class NotificationRouteTests: XCTestCase {
    private func route(_ id: String, category: String = "", _ userInfo: [AnyHashable: Any] = [:]) -> NotificationRoute {
        NotificationRoute.of(identifier: id, category: category, userInfo: userInfo)
    }

    func testATakenReminderShowsInFrontAndTakenMarksIt() {
        let dose = route(SupplementSchedule.notificationPrefix + "6F1C2E0A-0000-4000-8000-000000000001-0800",
                         category: NotificationRoute.doseCategory)
        XCTAssertEqual(dose, .dose)
        XCTAssertTrue(dose.showsInFront)
        XCTAssertEqual(dose.action(NotificationRoute.doseTakenAction), .markDoseTaken)
        XCTAssertEqual(dose.action(NotificationRoute.tap), .openTakenList)
        XCTAssertEqual(dose.action(UNNotificationDismissActionIdentifier), .nothing)
    }

    func testEventAlertsTheServicesAndThisDevicesOwn() {
        XCTAssertEqual(route("x", category: NotificationRoute.eventAlertCategory), .eventAlert)
        XCTAssertEqual(route("x", category: NotificationRoute.eventInviteCategory), .eventAlert)
        XCTAssertEqual(route(NotificationRoute.eventLocalPrefix + "cal|ev|10"), .eventAlert)
        XCTAssertTrue(NotificationRoute.eventAlert.showsInFront)
        XCTAssertEqual(NotificationRoute.eventAlert.action("EVENT_ACCEPT"), .eventAlert, "Accept, Decline and dismiss all go to EventAlerts")
    }

    func testABookingShowsInFrontAndATapOpensIt() {
        let booking = route("push-1", ["b": ["k": "booking", "cal": "c", "event": "e"]])
        XCTAssertEqual(booking, .booking)
        XCTAssertTrue(booking.showsInFront)
        XCTAssertEqual(booking.action(NotificationRoute.tap), .openBooking)
        XCTAssertEqual(booking.action(UNNotificationDismissActionIdentifier), .nothing)
    }

    func testAMealPhotoQuestionAndAnythingElse() {
        XCTAssertEqual(route("m", category: NotificationRoute.mealPhotoCategory), .mealPhoto)
        XCTAssertFalse(NotificationRoute.mealPhoto.showsInFront, "shown only behind the app, as before")
        XCTAssertEqual(route("other"), .other)
        XCTAssertFalse(NotificationRoute.other.showsInFront)
    }

    func testTheTapIdentifierIsTheSystems() {
        XCTAssertEqual(NotificationRoute.tap, UNNotificationDefaultActionIdentifier)
    }
}

// MARK: - What a push asks the Plan to open

/// `$pending` publishes in `willSet`: a Plan must take the value it was handed, and only one Plan
/// may open it (Fable: reading `pending` in the handler opened nothing, then the previous booking).
@MainActor
final class PlanOpenRequestsTests: XCTestCase {
    private let a = BananaService.BookingPushTarget(calendarID: "c", eventID: "a", start: nil, cancelled: false)
    private let b = BananaService.BookingPushTarget(calendarID: "c", eventID: "b", start: nil, cancelled: false)

    func testTwoPushesInARowOpenTheRightEventsOnceEach() async {
        let requests = PlanOpenRequests()
        var opened: [String] = []
        var watches: [Any] = []
        // Two Plans listening, as the views do: the handed value, taken on the main actor.
        for _ in 0..<2 {
            watches.append(requests.$pending.sink { pending in
                guard let pending else { return }
                Task { @MainActor in
                    if requests.take(pending) { opened.append(pending.eventID ?? "") }
                }
            })
        }
        requests.pending = a
        await Task.yield(); await Task.yield()
        XCTAssertEqual(opened, ["a"], "the first tap opens its own booking, once")
        XCTAssertNil(requests.pending)
        requests.pending = b
        await Task.yield(); await Task.yield()
        XCTAssertEqual(opened, ["a", "b"], "the second opens the second, not the first again")
        _ = watches
    }

    func testANewerRequestIsNotTakenAsAnOlderOne() {
        let requests = PlanOpenRequests()
        requests.pending = b
        XCTAssertFalse(requests.take(a))
        XCTAssertEqual(requests.pending, b)
        XCTAssertTrue(requests.take(b))
        XCTAssertFalse(requests.take(b), "taken once")
    }
}
