import XCTest

/// A legacy channel as `MoveOver` sees it: what it was told, and when it drained.
@MainActor
final class FakeLegacyChannel: LegacyChannel {
    let name: String
    let tier: LegacyTier
    let types: Set<String>
    let modes: LegacyCloudModeStore
    let events: SpaceSyncTests.LogBox
    var result = DrainResult()
    var failing = false
    /// Run as the drain starts (a test changes the world mid-sequence).
    var onDrain: (() -> Void)?
    private(set) var drains = 0
    private(set) var modesSet: [LegacyCloudMode] = []
    private(set) var modeAtDrain: [LegacyCloudMode] = []
    /// How often the move said it kept a drain's result.
    private(set) var kept = 0

    struct Offline: Error {}
    struct Interrupted: Error {}

    init(_ name: String, tier: LegacyTier, types: Set<String>, modes: LegacyCloudModeStore, events: SpaceSyncTests.LogBox) {
        self.name = name
        self.tier = tier
        self.types = types
        self.modes = modes
        self.events = events
    }

    var mode: LegacyCloudMode { modes.mode(tier) }

    func setMode(_ mode: LegacyCloudMode) {
        modesSet.append(mode)
        events.add("\(name) \(mode.rawValue)")
    }

    func drainKept() { kept += 1 }

    func drainToEnd() async throws -> DrainResult {
        drains += 1
        modeAtDrain.append(modes.mode(tier))
        events.add("\(name) drain")
        onDrain?()
        if hang {
            hang = false
            try? await Task.sleep(for: .seconds(10))   // a fetch stalled while the app was suspended
        }
        // As the zone poller does: only the move's background time running out stops a drain.
        if LegacyCloud.drainExpired { throw Interrupted() }
        if failing { throw Offline() }
        return result
    }

    /// The next drain hangs (for longer than the move waits).
    var hang = false
}

/// The move off iCloud on one device and between devices (docs/design/DATA-PLATFORM.md §3
/// "Seeding", §8), with fake legacy channels and the in-memory service.
@MainActor
final class MoveOverTests: XCTestCase {
    private var catalog: DataCatalog!
    private var server: MemorySyncServer!
    private var events: SpaceSyncTests.LogBox!
    private var defaults: UserDefaults!
    private var now = Date()
    private let extra = "plan.extra"
    private let meal = "food.meal"
    /// The devices `/v1/account` counts as active.
    private var devices: [String] = ["phone"]
    /// The ages of `/v1/account` the move asked for.
    private var asked: [TimeInterval] = []

    private func mirrorFile(_ device: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("move-over-\(device)-\(UUID().uuidString).sqlite")
    }

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        catalog = try DataCatalog.decode(Data(contentsOf: url))
        server = MemorySyncServer(catalog: catalog)
        server.hubDevices = ["phone"]
        events = SpaceSyncTests.LogBox()
        defaults = UserDefaults(suiteName: "move-over-\(UUID().uuidString)")
        now = Date()
        devices = ["phone"]
        deviceDefaults = [:]
        asked = []
    }

    override func tearDown() async throws {
        MoveOver.onHealthConsentChanged = nil
    }

    /// `file`: a mirror on disk, so a relaunch opens the same one again.
    private func engine(_ device: String, hub: Bool, store: TestStore, file: URL? = nil) async throws -> SpaceSync {
        var config = SpaceSync.Configuration(device: device, isHub: hub, catalog: catalog)
        config.debounce = .seconds(3_600)   // the tests run passes themselves
        let events = self.events!
        config.log = { events.add("\(device): \($0)") }
        let mirror = try file.map { try RecordMirror(url: $0) } ?? RecordMirror()
        let engine = try SpaceSync(mirror: mirror, transport: MemoryTransport(server: server, device: device),
                                   config: config)
        await engine.registerAdapter(store)
        store.engine = engine
        return engine
    }

    /// `/v1/account` as the service works it out from what the devices reported.
    private func account() -> MoveOver.Account {
        let states = server.syncStates
        let phone = states["phone"]
        let seeded = phone?.seededAt != nil ? Set(phone?.seeded ?? []) : []
        let flipped = devices.allSatisfy { states[$0]?.flippedAt != nil }
        return MoveOver.Account(hasIPhone: devices.contains("phone"), seeded: seeded, allFlipped: flipped, icloud: "keep")
    }

    /// Each device's own defaults: the modes' floor is the device's, not the account's.
    private var deviceDefaults: [String: UserDefaults] = [:]

    private func modes(_ device: String) -> LegacyCloudModeStore {
        let suite = deviceDefaults[device] ?? UserDefaults(suiteName: "move-over-\(device)-\(UUID().uuidString)")!
        deviceDefaults[device] = suite
        return LegacyCloudModeStore(defaults: suite, account: "acc-\(device)", enabled: true)
    }

    private func move(_ device: String, hub: Bool, engine: SpaceSync, channels: [FakeLegacyChannel],
                      adapters: [any RecordAdapter], modes: LegacyCloudModeStore,
                      returning: @escaping () -> Void = {}, drainTimeout: TimeInterval = 5 * 60,
                      holdBackground: (@MainActor (String, @escaping @MainActor () -> Void) -> @MainActor () -> Void)? = nil) -> MoveOver {
        var deps = MoveOver.Dependencies(
            engine: engine, isHub: hub, channels: channels, adapters: adapters, modes: modes,
            account: { [unowned self] maxAge in self.asked.append(maxAge); return self.account() }, defaults: defaults,
            stateKey: MoveOver.stateKey(account: "acc-\(device)"), now: { [unowned self] in self.now },
            log: { [events] in events!.add("\(device) move: \($0)") }, returningPerson: returning)
        deps.drainTimeout = drainTimeout
        deps.holdBackground = holdBackground
        return MoveOver(deps)
    }

    private func item(_ title: String) -> [String: JSONValue] { ["title": .string(title)] }

    // MARK: - Order

    func testTheHubSeedsFirstAndASpokeWaitsReadWriteUntilThen() async throws {
        let phoneStore = TestStore(types: [extra])
        phoneStore.items[extra] = ["a": item("A")]
        let macStore = TestStore(types: [extra])
        macStore.items[extra] = ["b": item("B")]
        devices = ["phone", "mac"]
        let phoneModes = modes("phone"), macModes = modes("mac")
        let phoneChannel = FakeLegacyChannel("phone controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let macChannel = FakeLegacyChannel("mac controls", tier: .personal, types: [extra], modes: macModes, events: events)
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore),
                       channels: [macChannel], adapters: [macStore], modes: macModes)
        await mac.start(listening: false)

        XCTAssertEqual(macChannel.drains, 0, "a spoke doesn't drain before the iPhone has seeded")
        XCTAssertEqual(macModes.mode(.personal), .readWrite, "and keeps writing iCloud meanwhile")
        XCTAssertEqual(mac.state.personal.phase, .waiting)
        XCTAssertTrue(server.visible(type: extra).isEmpty, "nothing seeded")

        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: phoneStore),
                         channels: [phoneChannel], adapters: [phoneStore], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .flipped)
        XCTAssertEqual(server.syncStates["phone"]?.seeded, [extra], "the hub says what it seeded")
        XCTAssertNotNil(server.syncStates["phone"]?.flippedAt)

        await mac.advance()
        XCTAssertEqual(macChannel.drains, 1)
        XCTAssertEqual(mac.state.personal.phase, .flipped)
        XCTAssertEqual(Set(server.visible(type: extra).keys), ["a", "b"])
        XCTAssertEqual(macStore.items[extra]?["a"], item("A"), "the spoke has the hub's items")
    }

    func testASpokeWithNoIPhoneSeedsOnItsOwnAndOneWithNoAnswerWaits() async throws {
        let macStore = TestStore(types: [extra])
        macStore.items[extra] = ["b": item("B")]
        devices = ["mac"]
        let macModes = modes("mac")
        let channel = FakeLegacyChannel("mac controls", tier: .personal, types: [extra], modes: macModes, events: events)
        let macEngine = try await engine("mac", hub: false, store: macStore)
        var asked = MoveOver.Account(hasIPhone: nil)
        let mac = MoveOver(MoveOver.Dependencies(
            engine: macEngine, isHub: false, channels: [channel], adapters: [macStore], modes: macModes,
            account: { _ in asked }, defaults: defaults, stateKey: MoveOver.stateKey(account: "acc-mac")))
        await mac.start(listening: false)
        XCTAssertEqual(channel.drains, 0, "an older service: the spoke can't tell, so it waits")

        asked = MoveOver.Account(hasIPhone: false)
        await mac.advance()
        XCTAssertEqual(mac.state.personal.phase, .flipped)
        XCTAssertEqual(server.visible(type: extra)["b"], item("B"))
    }

    func testDrainThenReadOnlyThenSeed() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let events = self.events!
        server.beforeSync = { request in
            if !request.changes.isEmpty { events.add("request with \(request.changes.count) change(s)") }
        }
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)

        XCTAssertEqual(channel.modeAtDrain, [.readWrite], "the drain runs while the channel still writes")
        XCTAssertEqual(channel.modesSet, [.readOnly])
        let lines = events.all
        let drain = try XCTUnwrap(lines.firstIndex(of: "controls drain"))
        let readOnly = try XCTUnwrap(lines.firstIndex(of: "controls readOnly"))
        let seed = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("request with") })
        XCTAssertLessThan(drain, readOnly)
        XCTAssertLessThan(readOnly, seed, "nothing is seeded before the channel stopped writing")
        XCTAssertEqual(phoneModes.mode(.personal), .readOnly)
    }

    func testAFailedDrainSeedsNothingAndTriesAgain() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        channel.failing = true
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .waiting)
        XCTAssertEqual(phoneModes.mode(.personal), .readWrite)
        XCTAssertTrue(server.visible(type: extra).isEmpty)

        channel.failing = false
        await phone.advance()
        XCTAssertEqual(phone.state.personal.phase, .flipped)
    }

    // MARK: - Coverage and consent

    func testNothingMovesWithoutAdaptersForEveryTypeAChannelCarries() async throws {
        let store = TestStore(types: [extra])
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra, "plan.override"], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(channel.drains, 0, "plan.override has no adapter: the channel keeps going as today")
        XCTAssertEqual(phoneModes.mode(.personal), .readWrite)
        XCTAssertNil(server.syncStates["phone"])

        // A legacy arrival before the seed is ignored: the seed will read the store whole.
        store.items[extra] = ["late": item("Late")]
        LegacyCloud.applyingFromCloud { MoveOver.changed(type: extra, ids: ["late"]) }
        await Task.yield()
        let engine = phone.deps.engine
        await engine.syncNow(reason: "test")
        XCTAssertTrue(server.visible(type: extra).isEmpty)
    }

    func testWithoutTheConsentHealthLeavesICloudAndStaysOnTheDevice() async throws {
        server.consent = false
        devices = ["phone", "mac"]   // the readers stay on: the Mac hasn't flipped
        let store = TestStore(types: [extra, meal])
        store.items[extra] = ["a": item("A")]
        store.items[meal] = ["m": item("Oats")]
        let phoneModes = modes("phone")
        let personal = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let health = FakeLegacyChannel("wellness", tier: .health, types: [meal], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [personal, health], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)

        XCTAssertEqual(phone.state.personal.phase, .flipped)
        XCTAssertEqual(health.drains, 1, "drained, consent or not")
        XCTAssertEqual(health.modeAtDrain, [.readWrite])
        XCTAssertEqual(phoneModes.mode(.health), .readOnly, "health never stays in iCloud")
        XCTAssertEqual(phone.state.health.phase, .held)
        XCTAssertNil(server.record(meal, "m"), "and isn't seeded without the consent")
        XCTAssertNotNil(server.syncStates["phone"]?.seededAt)
        XCTAssertNotNil(server.syncStates["phone"]?.flippedAt, "nothing writes iCloud: a declined consent doesn't hold the gate")
        XCTAssertEqual(server.syncStates["phone"]?.seeded, [extra])

        // An old build's meal, read now: it stays here.
        LegacyCloud.applyingFromCloud {
            store.items[meal]?["late"] = item("Late")
            MoveOver.changed(type: meal, ids: ["late"])
        }
        await Task.yield()
        await phone.deps.engine.syncNow(reason: "test")
        XCTAssertNil(server.record(meal, "late"))

        server.consent = true
        await MoveOver.grantHealthConsent()
        XCTAssertEqual(phone.state.health.phase, .flipped)
        XCTAssertEqual(health.drains, 1, "not drained again")
        XCTAssertEqual(Set(server.visible(type: meal).keys), ["m", "late"])
        XCTAssertEqual(server.syncStates["phone"]?.seeded.map(Set.init), [extra, meal])
    }

    func testWithdrawingTheConsentWhileSeedingHoldsTheTier() async throws {
        let store = TestStore(types: [meal])
        store.items[meal] = ["m": item("Oats")]
        let phoneModes = modes("phone")
        let health = FakeLegacyChannel("wellness", tier: .health, types: [meal], modes: phoneModes, events: events)
        let server = self.server!
        health.onDrain = { server.offline = ["phone"] }   // the seed can't go up yet
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [health], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.health.phase, .seeding)

        server.offline = []
        server.consent = false
        await MoveOver.withdrawHealthConsent()
        XCTAssertEqual(phone.state.health.phase, .held, "never acknowledged now: held, so the gate isn't stuck")
        XCTAssertNotNil(phone.state.health.flippedAt)
        XCTAssertEqual(phoneModes.mode(.health), .readOnly)
        XCTAssertNotNil(server.syncStates["phone"]?.flippedAt, "nothing here writes iCloud")
    }

    func testASpokeWithoutTheConsentDoesNotWaitForTheHubToLeaveICloud() async throws {
        server.consent = false
        devices = ["phone", "mac"]
        let store = TestStore(types: [extra, meal])
        store.items[meal] = ["m": item("Oats")]
        let macModes = modes("mac")
        let personal = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: macModes, events: events)
        let health = FakeLegacyChannel("wellness", tier: .health, types: [meal], modes: macModes, events: events)
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: store),
                       channels: [personal, health], adapters: [store], modes: macModes)
        await mac.start(listening: false)
        XCTAssertEqual(mac.state.personal.phase, .waiting, "personal data waits for the iPhone")
        XCTAssertEqual(macModes.mode(.personal), .readWrite)
        XCTAssertEqual(mac.state.health.phase, .held, "health leaves iCloud at once")
        XCTAssertEqual(macModes.mode(.health), .readOnly)
        XCTAssertNil(server.syncStates["mac"], "nothing seeded yet, so nothing reported")
    }

    func testTheConsentIsHeardThroughTheMove() async throws {
        server.consent = false
        let store = TestStore(types: [extra])
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [], adapters: [store], modes: modes("phone"))
        await phone.start()
        var heard: [Bool] = []
        MoveOver.onHealthConsentChanged = { heard.append($0) }
        server.consent = true
        await MoveOver.grantHealthConsent()
        try await waitUntil { heard == [true] }
        let granted = await phone.deps.engine.healthConsent
        XCTAssertTrue(granted)
        server.consent = false
        await MoveOver.withdrawHealthConsent()
        try await waitUntil { heard == [true, false] }
    }

    // MARK: - What the drain found

    func testItemsDeletedElsewhereBeforeTheSeedAreDroppedNotSeeded() async throws {
        let store = TestStore(types: [meal])
        store.items[meal] = ["m1": item("Oats"), "m2": item("Deleted on the Mac")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("wellness", tier: .health, types: [meal], modes: phoneModes, events: events)
        channel.result.absent = [meal: ["m2", "not-here"]]
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)

        XCTAssertNil(store.items[meal]?["m2"], "out of the store")
        XCTAssertEqual(Set(server.visible(type: meal).keys), ["m1"])
        XCTAssertNil(server.record(meal, "m2"), "no tombstone: it was deleted elsewhere already")
    }

    func testADeleteTheDrainCouldNotSendIsDeletedInTheSpaceAfterTheSeed() async throws {
        let phoneStore = TestStore(types: [extra])
        phoneStore.items[extra] = ["x": item("X"), "y": item("Y")]
        let macStore = TestStore(types: [extra])
        macStore.items[extra] = ["y": item("Y")]   // x deleted here; iCloud never got the delete
        devices = ["phone", "mac"]
        let phoneModes = modes("phone"), macModes = modes("mac")
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: phoneStore),
                         channels: [FakeLegacyChannel("p", tier: .personal, types: [extra], modes: phoneModes, events: events)],
                         adapters: [phoneStore], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertNotNil(server.visible(type: extra)["x"])

        let macChannel = FakeLegacyChannel("m", tier: .personal, types: [extra], modes: macModes, events: events)
        macChannel.result.pendingDeletes = [extra: ["x"]]
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore),
                       channels: [macChannel], adapters: [macStore], modes: macModes)
        await mac.start(listening: false)

        XCTAssertNil(macStore.items[extra]?["x"], "the hub's seed brought it back; it goes again")
        XCTAssertNil(server.visible(type: extra)["x"], "deleted in the space")
        XCTAssertNotNil(server.record(extra, "x")?.deleted)
        XCTAssertEqual(mac.state.personal.phase, .flipped)
        XCTAssertTrue(mac.state.personal.pendingDeletes.isEmpty)
    }

    // MARK: - After the seed

    func testLateArrivalsEnterWithTheirSeedClocks() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let engine = try await engine("phone", hub: true, store: store)
        let phone = move("phone", hub: true, engine: engine, channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .flipped)

        // An old-build iPad's edit, two days old, applied by the read-only legacy reader.
        let edited = now.addingTimeInterval(-2 * 86_400)
        LegacyCloud.applyingFromCloud {
            store.items[extra]?["late"] = item("From the old iPad")
            store.editedAt["\(extra)/late"] = edited
            MoveOver.changed(type: extra, ids: ["late"])
        }
        try await waitUntil { self.server.record(self.extra, "late") != nil }
        let clock = try XCTUnwrap(server.record(extra, "late")?.clocks["title"])
        XCTAssertEqual(HLC(clock)?.ms, HLCClock.ms(edited), "the item's own edit time, not a fresh clock")

        // This device's own edit, outside an apply, gets a fresh clock.
        store.items[extra]?["a"] = item("A, edited")
        MoveOver.changed(type: extra, ids: ["a"])
        await engine.syncNow(reason: "test")
        let fresh = try XCTUnwrap(server.record(extra, "a")?.clocks["title"])
        XCTAssertGreaterThan(HLC(fresh)?.ms ?? 0, HLCClock.ms(edited))
    }

    func testTheFlipWaitsForEveryRecordOfTheSeedToBeAcknowledged() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let server = self.server!
        channel.onDrain = { server.offline = ["phone"] }   // the network goes as the seed is about to go up
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)

        XCTAssertEqual(phone.state.personal.phase, .seeding)
        XCTAssertEqual(phoneModes.mode(.personal), .readOnly)
        XCTAssertNil(server.syncStates["phone"], "nothing reported before the seed is acknowledged")

        server.offline = []
        await phone.advance()
        XCTAssertEqual(phone.state.personal.phase, .flipped)
        XCTAssertNotNil(server.syncStates["phone"]?.seededAt)
        XCTAssertNotNil(server.syncStates["phone"]?.flippedAt)
        XCTAssertEqual(channel.drains, 1, "drained once")
    }

    func testOffOnceEveryDeviceHasFlippedOrThirtyDaysAfter() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        devices = ["phone", "mac"]   // the Mac never flips
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        await phone.advance()
        XCTAssertEqual(phone.state.personal.phase, .flipped)
        XCTAssertEqual(phoneModes.mode(.personal), .readOnly, "late arrivals still read")

        now = now.addingTimeInterval(29 * 86_400)
        await phone.advance()
        XCTAssertEqual(phoneModes.mode(.personal), .readOnly)

        now = now.addingTimeInterval(2 * 86_400)
        await phone.advance()
        XCTAssertEqual(phone.state.personal.phase, .off)
        XCTAssertEqual(phoneModes.mode(.personal), .off)
        XCTAssertEqual(channel.modesSet, [.readOnly, .off])
    }

    func testOffAsSoonAsTheAccountSaysEveryDeviceFlipped() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .flipped, "the account hadn't heard of the flip yet")
        await phone.advance()
        XCTAssertEqual(phone.state.personal.phase, .off)
        XCTAssertEqual(phoneModes.mode(.personal), .off)
    }

    func testTheMoveResumesWhereItWasAfterARelaunch() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        devices = ["phone", "mac"]
        let file = mirrorFile("phone")
        let first = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store, file: file),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await first.start(listening: false)
        XCTAssertEqual(first.state.personal.phase, .flipped)

        // Relaunched: the same mirror file opened by a new engine.
        let relaunched = try await engine("phone", hub: true, store: store, file: file)
        let again = move("phone", hub: true, engine: relaunched, channels: [channel], adapters: [store], modes: phoneModes)
        XCTAssertEqual(again.state, first.state, "kept for the account")
        await again.start(listening: false)
        XCTAssertEqual(channel.drains, 1, "not drained again")
        XCTAssertEqual(modes("phone").mode(.personal), .readOnly, "the mode is kept for the account too")
    }

    func testACrashAfterTheModeWasKeptButNotThePhaseDrainsAgainAndGoesOn() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        phoneModes.set(.readOnly, for: .personal)   // kept before the crash; the phase wasn't
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(channel.modeAtDrain, [.readOnly], "drained again, read-only (the channels then judge only what iCloud confirmed)")
        XCTAssertEqual(phone.state.personal.phase, .flipped)
        XCTAssertEqual(server.visible(type: extra)["a"], item("A"))
    }

    func testATierPastTheDrainNeverDrainsAgainAfterARelaunch() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A"), "gone": item("Deleted elsewhere")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        channel.result.absent = [extra: ["gone"]]
        let server = self.server!
        channel.onDrain = { server.offline = ["phone"] }
        let file = mirrorFile("phone")
        let first = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store, file: file),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await first.start(listening: false)
        XCTAssertEqual(first.state.personal.phase, .seeding)

        // Relaunched after a crash that kept the phase but not the mode (a device's fresh defaults
        // stand in for that), and with "gone" back in the store, as if the drop hadn't happened.
        server.offline = []
        store.items[extra]?["gone"] = item("Deleted elsewhere")
        var state = first.state
        state.personal.absent = [extra: ["gone"]]
        defaults.set(try JSONEncoder().encode(state), forKey: MoveOver.stateKey(account: "acc-phone"))
        deviceDefaults["phone"] = nil
        let freshModes = modes("phone")
        let again = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: freshModes, events: events)
        let relaunched = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store, file: file),
                              channels: [again], adapters: [store], modes: freshModes)
        await relaunched.start(listening: false)
        XCTAssertEqual(again.drains, 0, "never drained twice")
        XCTAssertEqual(freshModes.mode(.personal), .readOnly, "read-only again")
        XCTAssertNil(store.items[extra]?["gone"], "what was deleted elsewhere is dropped again")
        XCTAssertEqual(relaunched.state.personal.phase, .flipped)
        XCTAssertEqual(Set(server.visible(type: extra).keys), ["a"])
    }

    func testDeletesTheDrainCouldNotSendSurviveARelaunch() async throws {
        let phoneStore = TestStore(types: [extra])
        phoneStore.items[extra] = ["x": item("X"), "y": item("Y")]
        devices = ["phone", "mac"]
        let phoneModes = modes("phone"), macModes = modes("mac")
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: phoneStore),
                         channels: [FakeLegacyChannel("p", tier: .personal, types: [extra], modes: phoneModes, events: events)],
                         adapters: [phoneStore], modes: phoneModes)
        await phone.start(listening: false)

        let macStore = TestStore(types: [extra])
        macStore.items[extra] = ["y": item("Y")]
        let macChannel = FakeLegacyChannel("m", tier: .personal, types: [extra], modes: macModes, events: events)
        macChannel.result.pendingDeletes = [extra: ["x"]]
        let server = self.server!
        macChannel.onDrain = { server.offline = ["mac"] }
        let file = mirrorFile("mac")
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore, file: file),
                       channels: [macChannel], adapters: [macStore], modes: macModes)
        await mac.start(listening: false)
        XCTAssertEqual(mac.state.personal.phase, .seeding)
        XCTAssertEqual(mac.state.personal.pendingDeletes, [extra: ["x"]], "kept across the relaunch")
        XCTAssertEqual(macChannel.kept, 1, "the channel may let go of what it held, now the move has it")

        server.offline = []
        let relaunched = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore, file: file),
                              channels: [macChannel], adapters: [macStore], modes: macModes)
        await relaunched.start(listening: false)
        XCTAssertEqual(relaunched.state.personal.phase, .flipped)
        XCTAssertNil(server.visible(type: extra)["x"])
        XCTAssertNil(macStore.items[extra]?["x"])
        XCTAssertEqual(macChannel.drains, 1)
    }

    func testADeleteMadeWhileASpokeWaitsForTheHubIsCarriedAcrossARelaunch() async throws {
        devices = ["phone", "mac"]
        let phoneStore = TestStore(types: [extra])
        phoneStore.items[extra] = ["x": item("X"), "y": item("Y"), "z": item("Z")]
        let phoneEngine = try await engine("phone", hub: true, store: phoneStore)

        let macStore = TestStore(types: [extra])
        macStore.items[extra] = ["x": item("X"), "y": item("Y"), "z": item("Z")]
        let macModes = modes("mac")
        let channel = FakeLegacyChannel("m", tier: .personal, types: [extra], modes: macModes, events: events)
        let file = mirrorFile("mac")
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore, file: file),
                       channels: [channel], adapters: [macStore], modes: macModes)
        await mac.start(listening: false)
        XCTAssertEqual(mac.state.personal.phase, .waiting, "the iPhone hasn't seeded")

        // The person deletes x and z on the Mac meanwhile, then makes z again; the store reports it
        // through the move's hooks, as the app's do (the iPhone's x arriving later is an echo).
        macStore.viaMoveOver = true
        macStore.delete(extra, "x")
        macStore.delete(extra, "z")
        macStore.set(extra, "z", item("Z again"))
        XCTAssertEqual(mac.state.personal.pendingDeletes, [extra: ["x"]], "held in the move's state; z's delete no longer stands")

        // Relaunched before the seed: the same mirror, a new engine and move.
        let relaunched = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore, file: file),
                              channels: [channel], adapters: [macStore], modes: macModes)
        XCTAssertEqual(relaunched.state.personal.pendingDeletes, [extra: ["x"]])

        // The iPhone seeds, x included; the Mac moves.
        await phoneEngine.seed(types: [extra])
        try await phoneEngine.reportSyncState(seededAt: Date(), flippedAt: nil)
        await relaunched.start(listening: false)
        await relaunched.advance()
        XCTAssertEqual(relaunched.state.personal.phase, .flipped)
        XCTAssertNotNil(server.record(extra, "x")?.deleted, "the Mac's delete reached the space")
        XCTAssertNil(macStore.items[extra]?["x"], "and the iPhone's seed didn't bring it back here")
        XCTAssertNotNil(server.visible(type: extra)["z"])
        await phoneEngine.syncNow(reason: "test")
        XCTAssertNil(phoneStore.items[extra]?["x"], "the iPhone has it gone too")
    }

    func testAUserDeleteDuringAnAsyncLegacyBatchIsCarried() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A"), "b": item("B")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("fitness", tier: .personal, types: [extra], modes: phoneModes, events: events)
        devices = ["phone", "mac"]
        let engine = try await engine("phone", hub: true, store: store)
        let phone = move("phone", hub: true, engine: engine, channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .flipped)

        // An old build's change to "a" is being applied, and waits on the store meanwhile.
        let extra = self.extra
        let batch = Task { @MainActor in
            await LegacyCloud.applyingFromCloud(LegacyCloud.ApplyScope([extra: ["a"]])) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(LegacyCloud.isApplyingFromCloud(type: extra, id: "a"))
        XCTAssertFalse(LegacyCloud.isApplyingFromCloud(type: extra, id: "b"))
        store.items[extra]?["b"] = nil
        MoveOver.deleted(type: extra, ids: ["b"])   // the person deletes "b" here, meanwhile
        await batch.value
        await engine.syncNow(reason: "test")
        XCTAssertNil(server.visible(type: extra)["b"], "this device's delete reached the space")
        XCTAssertNotNil(server.record(extra, "b")?.deleted)
        XCTAssertNotNil(server.visible(type: extra)["a"])
    }

    func testARefusedSeedRecordDoesNotHoldTheFlipButKeepsThePurgeShut() async throws {
        let override = "plan.override"
        server.refuse[extra] = "too_large"
        let store = TestStore(types: [extra, override])
        store.items[extra] = ["a": item("Too big")]
        store.items[override] = ["o": item("O")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra, override], modes: phoneModes, events: events)
        devices = ["phone", "mac"]
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .flipped, "the refused record stays here; the device moves")
        XCTAssertNil(server.syncStates["phone"]?.seededAt, "the seed isn't whole: the purge gate stays shut")
        XCTAssertNotNil(server.syncStates["phone"]?.flippedAt)
        XCTAssertEqual(server.syncStates["phone"]?.seeded, [override], "spokes wait only for what went up")
        XCTAssertTrue(events.all.contains { $0.contains("refused") && $0.contains(extra) && $0.contains("purge") })
        XCTAssertEqual(store.items[extra]?["a"], item("Too big"))
    }

    func testAHeldTierStopsReadingAfterThirtyDaysAndSeedsWhenTheConsentComesLater() async throws {
        server.consent = false
        devices = ["phone", "mac"]
        let store = TestStore(types: [meal])
        store.items[meal] = ["m": item("Oats")]
        let phoneModes = modes("phone")
        let health = FakeLegacyChannel("wellness", tier: .health, types: [meal], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [health], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.health.phase, .held)

        now = now.addingTimeInterval(31 * 86_400)
        await phone.advance()
        XCTAssertEqual(phoneModes.mode(.health), .off)
        XCTAssertTrue(phone.state.health.readersOff)
        XCTAssertNil(server.record(meal, "m"))

        server.consent = true
        await MoveOver.grantHealthConsent()
        XCTAssertEqual(phone.state.health.phase, .off, "seeded, with its readers already off")
        XCTAssertEqual(phoneModes.mode(.health), .off)
        XCTAssertEqual(server.visible(type: meal)["m"], item("Oats"))
    }

    func testTheAccountIsReadRarelyWhileNothingIsCovered() async throws {
        let store = TestStore(types: [extra])
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra, "plan.override"], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        await phone.advance()
        XCTAssertEqual(Set(asked), [6 * 3_600], "nothing to move: every few hours, not every minute")
    }

    func testTheAccountIsReadEveryTenMinutesForTheHubAndEveryMinuteForAnAcknowledgement() async throws {
        devices = ["phone", "mac"]
        let macStore = TestStore(types: [extra])
        macStore.items[extra] = ["b": item("B")]
        let macModes = modes("mac")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: macModes, events: events)
        let server = self.server!
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore),
                       channels: [channel], adapters: [macStore], modes: macModes)
        await mac.start(listening: false)
        asked = []
        await mac.advance()
        XCTAssertEqual(asked, [10 * 60], "waiting for the iPhone: every ten minutes")

        let phoneStore = TestStore(types: [extra])
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: phoneStore),
                         channels: [FakeLegacyChannel("p", tier: .personal, types: [extra], modes: modes("phone"), events: events)],
                         adapters: [phoneStore], modes: modes("phone"))
        await phone.start(listening: false)
        channel.onDrain = { server.offline = ["mac"] }   // the Mac's seed can't be acknowledged yet
        await mac.advance()
        XCTAssertEqual(mac.state.personal.phase, .seeding)
        asked = []
        await mac.advance()
        XCTAssertEqual(asked, [60], "a seed out: every minute")
    }

    func testStateFromAnotherBuildDecodes() throws {
        let partial = try JSONDecoder().decode(MoveOver.State.self, from: Data(#"{"personal":{"phase":"seeding"}}"#.utf8))
        XCTAssertEqual(partial.personal.phase, .seeding)
        XCTAssertEqual(partial.health, MoveOver.TierState())
        XCTAssertFalse(partial.returningChecked)
        XCTAssertEqual(try JSONDecoder().decode(MoveOver.State.self, from: Data("{}".utf8)), MoveOver.State())
    }

    // MARK: - In the background

    func testAStepHoldsBackgroundTimeAndItsDrainsGoOnInTheBackground() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let events = self.events!
        var holding = false
        channel.onDrain = { events.add("drain while holding: \(holding)") }
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes,
                         holdBackground: { name, _ in
                             holding = true
                             events.add("hold \(name)")
                             return { holding = false; events.add("let go") }
                         })
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .flipped, "drained and seeded, the app in the background or not")
        XCTAssertTrue(events.all.contains("drain while holding: true"))
        XCTAssertFalse(holding, "let go at the end of the step")
        XCTAssertEqual(events.all.filter { $0 == "hold move over" }.count, events.all.filter { $0 == "let go" }.count)
        XCTAssertTrue(events.all.contains { $0.contains("controls drain started") })
        XCTAssertTrue(events.all.contains { $0.contains("controls drained in") && $0.contains("0 deleted here") })
    }

    func testWhenTheBackgroundTimeRunsOutTheDrainStopsAndGoesAgainAtTheNextStep() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        var expire: (@MainActor () -> Void)?
        channel.onDrain = { expire?(); expire = nil }   // iOS takes the time back mid-drain, once
        var holds = 0
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes,
                         holdBackground: { _, expired in
                             holds += 1
                             if holds == 1 { expire = expired }
                             return {}
                         })
        await phone.start(listening: false)
        XCTAssertEqual(phone.state.personal.phase, .waiting, "interrupted: nothing moved")
        XCTAssertFalse(LegacyCloud.drainExpired, "the next step starts with fresh time")
        XCTAssertTrue(events.all.contains { $0.contains("didn't drain") && $0.contains("Interrupted") })

        await phone.advance()   // the next pass, a push, the foreground, a background refresh
        XCTAssertEqual(channel.drains, 2)
        XCTAssertEqual(phone.state.personal.phase, .flipped)
    }

    func testAHungDrainDoesntHoldTheMove() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        channel.hang = true
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes, drainTimeout: 0.3)
        let began = Date()
        await phone.start(listening: false)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "given up on, not waited for")
        XCTAssertEqual(phone.state.personal.phase, .waiting)
        XCTAssertTrue(events.all.contains { $0.contains("didn't drain") && $0.contains("DrainTimedOut") })

        await phone.advance()   // not stuck: the next step runs
        XCTAssertEqual(channel.drains, 2)
        XCTAssertEqual(phone.state.personal.phase, .flipped)
    }

    func testWhilePlayingTheMoveStepsAtMostEveryFiveMinutes() {
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertTrue(MovePace.stepDue(last: nil, now: t), "the first look while playing steps")
        XCTAssertFalse(MovePace.stepDue(last: t, now: t.addingTimeInterval(4 * 60)))
        XCTAssertTrue(MovePace.stepDue(last: t, now: t.addingTimeInterval(5 * 60)))
    }

    func testAColdBackgroundLaunchStartsTheEngineForTheMirrorsAccount() {
        XCTAssertTrue(MovePace.startsWithoutAccountYet(flagOn: true, serviceAvailable: true, signedIn: true,
                                                       bound: "acc", engineRunning: false), "a push or a refresh can advance")
        XCTAssertFalse(MovePace.startsWithoutAccountYet(flagOn: true, serviceAvailable: true, signedIn: true,
                                                        bound: nil, engineRunning: false), "no mirror yet: wait for the account")
        XCTAssertFalse(MovePace.startsWithoutAccountYet(flagOn: true, serviceAvailable: true, signedIn: false,
                                                        bound: "acc", engineRunning: false), "signed out")
        XCTAssertFalse(MovePace.startsWithoutAccountYet(flagOn: false, serviceAvailable: true, signedIn: true,
                                                        bound: "acc", engineRunning: false), "--no-space-sync")
        XCTAssertFalse(MovePace.startsWithoutAccountYet(flagOn: true, serviceAvailable: true, signedIn: true,
                                                        bound: "acc", engineRunning: true), "already up")
    }

    func testStepsThatComeWhileOneRunsShareTheNextNotPileUp() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        async let first: Void = phone.start(listening: false)
        async let second: Void = phone.advance()   // the while-playing look, meanwhile
        _ = await (first, second)
        XCTAssertEqual(channel.drains, 1, "one drain: the second step joined the running one")
        XCTAssertTrue([.flipped, .off].contains(phone.state.personal.phase), "moved (and, the only device, its readers off)")
    }

    // MARK: - Returning person

    func testANewDeviceThatFindsTheSpaceInUseFinishesOnboarding() async throws {
        server.inject(extra, "a", set: item("A"), clock: HLC(ms: 1_760_000_000_000, counter: 0, device: "phone").text)
        let store = TestStore(types: [extra])
        let macModes = modes("mac")
        var returned = 0
        devices = ["phone", "mac"]
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: store),
                       channels: [], adapters: [store], modes: macModes, returning: { returned += 1 })
        await mac.start(listening: false)
        await mac.advance()
        XCTAssertEqual(returned, 1)
        XCTAssertTrue(mac.state.returningChecked)
    }

    func testAnEmptySpaceIsNotSomeoneComingBack() async throws {
        let store = TestStore(types: [extra])
        var returned = 0
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [], adapters: [store], modes: modes("phone"), returning: { returned += 1 })
        await phone.start(listening: false)
        XCTAssertEqual(returned, 0)
        XCTAssertTrue(phone.state.returningChecked)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - The progress line (Settings › Banana account)

extension MoveOverTests {
    func testTheProgressLineSaysWhatTheMoveDoesInFewestWords() {
        let english = Locale(identifier: "en_US")
        typealias P = MoveOver.Progress
        XCTAssertEqual(P(stage: .waitingForIPhone).text(locale: english), "Moving to Banana · waiting for your iPhone")
        XCTAssertEqual(P(stage: .reading("workouts")).text(locale: english), "Moving to Banana · reading workouts")
        XCTAssertEqual(P(stage: .uploading(done: 1_240, of: 6_800)).text(locale: english),
                       "Moving to Banana · uploading 1,240 of 6,800")
        XCTAssertEqual(P(stage: .moving).text(locale: english), "Moving to Banana")
        let words = ["controls zone": "plans", "controls zone (health)": "plans", "meals zone": "meals",
                     "wellness zone": "wellness", "progress zone": "progress", "fitness zone": "workouts",
                     "fitness zone (voice notes)": "voice notes", "settings zone": "settings",
                     "key-value store": "settings", "key-value store (health)": "settings", "iCloud Drive": "voice notes"]
        for (channel, word) in words { XCTAssertEqual(P.zone(forChannel: channel), word, channel) }
    }

    func testTheProgressFollowsTheMoveAndEndsAtTheFlip() async throws {
        let store = TestStore(types: [extra])
        store.items[extra] = ["a": item("A"), "b": item("B"), "c": item("C")]
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("fitness zone (voice notes)", tier: .personal, types: [extra], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        var duringDrain: MoveOver.Progress?
        channel.onDrain = { [weak phone] in duringDrain = phone?.progressNow }
        channel.failing = true
        await phone.start(listening: false)
        XCTAssertEqual(duringDrain?.stage, .reading("voice notes"), "while the drain reads")
        XCTAssertEqual(phone.progressNow?.stage, .reading("voice notes"), "a drain that stopped goes again from there")
        try await waitUntil { MoveOver.progress.value?.stage == .reading("voice notes") }   // published for Settings

        // The drain ends; the seed can't go up yet.
        channel.failing = false
        let server = self.server!
        channel.onDrain = { server.offline = ["phone"] }
        await phone.advance()
        XCTAssertEqual(phone.state.personal.phase, .seeding)
        let stage = try XCTUnwrap(phone.progressNow?.stage)
        XCTAssertTrue(stage == .uploading(done: 0, of: 3) || stage == .moving, "\(stage)")

        server.offline = []
        await phone.advance()
        XCTAssertEqual(phone.state.personal.phase, .flipped)
        XCTAssertNil(phone.progressNow, "nothing once flipped")
        XCTAssertNil(phone.state.seedTotal)
        phone.stop()
        try await waitUntil { MoveOver.progress.value == nil }   // stopped: no line
    }

    func testASpokeSaysItWaitsForTheIPhone() async throws {
        let macStore = TestStore(types: [extra])
        devices = ["phone", "mac"]
        let macModes = modes("mac")
        let channel = FakeLegacyChannel("controls zone", tier: .personal, types: [extra], modes: macModes, events: events)
        let mac = move("mac", hub: false, engine: try await engine("mac", hub: false, store: macStore),
                       channels: [channel], adapters: [macStore], modes: macModes)
        await mac.start(listening: false)
        XCTAssertEqual(mac.progressNow?.stage, .waitingForIPhone)
        mac.stop()
    }

    func testNothingCoveredSaysNothing() async throws {
        let store = TestStore(types: [extra])
        let phoneModes = modes("phone")
        let channel = FakeLegacyChannel("controls zone", tier: .personal, types: [extra, "plan.override"], modes: phoneModes, events: events)
        let phone = move("phone", hub: true, engine: try await engine("phone", hub: true, store: store),
                         channels: [channel], adapters: [store], modes: phoneModes)
        await phone.start(listening: false)
        XCTAssertNil(phone.progressNow)
        phone.stop()
    }

    func testTheLineIsPublishedAtMostOnceAnInterval() async throws {
        let model = MoveOver.ProgressModel()
        model.interval = 0.2
        model.publish(.init(stage: .reading("plans")))
        XCTAssertEqual(model.value?.stage, .reading("plans"), "the first at once")
        model.publish(.init(stage: .reading("meals")))
        model.publish(.init(stage: .reading("workouts")))
        XCTAssertEqual(model.value?.stage, .reading("plans"), "the next waits for the interval")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.value?.stage, .reading("workouts"), "and is the latest")
    }
}
