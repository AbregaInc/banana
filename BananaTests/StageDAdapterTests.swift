import XCTest

// Stage D of the data platform (docs/design/DATA-PLATFORM.md): the adapters for the plan, podcast,
// notes and core types, run against the in-memory service (`MemorySyncServer`) with two engines,
// the phone (the hub) and the iPad. Stores are fakes over the real models, or the real stores the
// test target compiles (`SkipPlanStore`, `NarratorVoiceStore`), on throwaway folders: nothing here
// reads or writes anyone's data.

// MARK: - Fakes over the stores' seams

/// A Controls store: items by kind as the bytes it writes, `applyCloud` as the stores do it.
@MainActor
final class FakeControls: CloudControlSource {
    var items: [ControlKind: [String: Data]] = [:]
    var edited: [String: Date] = [:]
    /// Kinds whose items wait for an item of another kind with the same id (settings for a show).
    var parent: [ControlKind: ControlKind] = [:]

    func put<T: Encodable>(_ kind: ControlKind, _ id: String, _ value: T, at: Date? = nil) {
        items[kind, default: [:]][id] = try! JSONEncoder().encode(value)
        if let at { edited["\(kind.rawValue)-\(id)"] = at }
    }

    func value<T: Decodable>(_ kind: ControlKind, _ id: String, as type: T.Type) -> T? {
        items[kind]?[id].flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func cloudItems(_ kind: ControlKind) -> [String: Data] { items[kind] ?? [:] }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        if item != nil, let parent = parent[kind], items[parent]?[id] == nil { return false }
        items[kind, default: [:]][id] = item
        // As `PodcastLibrary` and `RoutineStore` do: their mutators report what they did.
        if item == nil { ControlChangeReporter.deleted(kind, id) } else { ControlChangeReporter.changed(kind, id) }
        return true
    }
}

/// The library's progress, with its rule: the later stamp wins, ties by `ProgressTie`.
@MainActor
final class FakeProgress: ProgressSyncSource {
    var progress: [String: EpisodeProgressRecord] = [:]
    var known: Set<String> = []
    var batches = 0

    func syncProgressEpisodeIDs() -> [String] { Array(progress.keys) }
    func syncProgress(_ episodeID: String) -> EpisodeProgressRecord? { progress[episodeID] }
    func knowsEpisode(_ id: String) -> Bool { known.contains(id) || progress[id] != nil }

    func applySyncedProgress(_ episodeID: String, _ incoming: EpisodeProgressRecord) -> Bool {
        if let own = progress[episodeID] {
            let ownAt = own.updatedAt ?? .distantPast, incomingAt = incoming.updatedAt ?? .distantPast
            if ProgressTie.isTie(ownAt, incomingAt) {
                guard ProgressTie.beats(.init(completed: incoming.completed, position: incoming.position),
                                        .init(completed: own.completed, position: own.position)) else { return false }
            } else if ownAt > incomingAt {
                return false
            }
        }
        progress[episodeID] = incoming
        return true
    }

    func applyingSyncedBatch(_ body: () -> Void) {
        batches += 1
        body()
    }
}

@MainActor
final class FakeListens: ListenSyncSource {
    var syncListens: [ListenEvent] = []
    var active: UUID?
    var routes: [UUID: URL] = [:]
    var stored: [UUID: Data] = [:]
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("listens-\(UUID().uuidString)")

    func addRoute(_ id: UUID, _ data: Data) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id.uuidString).route")
        try! data.write(to: url)
        routes[id] = url
    }

    func syncRouteFile(_ event: ListenEvent) -> URL? {
        guard event.id != active, event.routePointCount > 0 else { return nil }
        return routes[event.id]
    }

    func applySyncedListen(_ event: ListenEvent) {
        if let index = syncListens.firstIndex(where: { $0.id == event.id }) { syncListens[index] = event }
        else { syncListens.append(event) }
    }

    func storeSyncedRoute(_ id: UUID, data: Data) { stored[id] = data }
    func removeSyncedListens(_ ids: [UUID]) { syncListens.removeAll { ids.contains($0.id) } }
    func syncEditedAt(_ id: UUID) -> Date? { nil }
}

@MainActor
final class FakeTranscripts: TranscriptSyncSource {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)")
    var syncTranscripts: [String: Transcript.Source] = [:]
    var syncBlobDirectory: URL { folder.appendingPathComponent("blobs") }

    func keep(_ transcript: Transcript) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! JSONEncoder().encode(transcript).write(to: syncTranscriptFile(transcript.episodeID))
        syncTranscripts[transcript.episodeID] = transcript.source
    }

    func transcript(_ id: String) -> Transcript? {
        (try? Data(contentsOf: syncTranscriptFile(id))).flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
    }

    func syncTranscriptFile(_ episodeID: String) -> URL {
        folder.appendingPathComponent(BlobFiles.sha256(of: Data(episodeID.utf8)) + ".json")
    }

    func storeSyncedTranscript(_ episodeID: String, packed file: URL) {
        guard let transcript = TranscriptAdapter.unpack(file), transcript.episodeID == episodeID else { return }
        if transcript.source.qualityRank > (syncTranscripts[episodeID]?.qualityRank ?? 0) { keep(transcript) }
    }
}

@MainActor
final class FakeNotes: VoiceNoteSyncSource {
    var compareSubmillisecondDates = false // controlled reference to the former store policy
    var syncNotes: [VoiceNote] = []
    var audio: [UUID: URL] = [:]
    var storedAudio: [UUID: Data] = [:]
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")

    func record(_ note: VoiceNote, audio data: Data) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(note.audioFilename)
        try! data.write(to: url)
        audio[note.id] = url
        syncNotes.append(note)
    }

    func syncAudioFile(_ note: VoiceNote) -> URL? { audio[note.id] }

    func applySyncedNote(_ note: VoiceNote) -> Bool {
        if let index = syncNotes.firstIndex(where: { $0.id == note.id }) {
            if compareSubmillisecondDates {
                guard syncNotes[index].syncDate <= note.syncDate else { return false }
            } else {
                guard !syncNotes[index].isNewerForSync(than: note) else { return false }
            }
            syncNotes[index] = note
        } else {
            syncNotes.append(note)
        }
        return true
    }

    func storeSyncedAudio(_ id: UUID, file: URL) { storedAudio[id] = try? Data(contentsOf: file) }
    func removeSyncedNotes(_ ids: [UUID]) { syncNotes.removeAll { ids.contains($0.id) } }
}

/// A settings singleton shaped like `AppSettings.Snapshot`: every setting optional, one field each.
struct FakeSettings: Codable, Equatable {
    var distanceUnit: String?
    var poolLength: String?
    var sleepTimerMinutes: Int?
    var mapsProvider: String?

    static let compiled = FakeSettings(distanceUnit: "miles", poolLength: "yards25", sleepTimerMinutes: 45, mapsProvider: nil)
}

@MainActor
final class FakeSettingsStore {
    var value = FakeSettings.compiled

    func binding() -> SyncBinding {
        .single("core.appSettings", id: "appSettings", shape: .fields,
                value: { [unowned self] in self.value },
                apply: { [unowned self] incoming, fields in
                    let cleared = Set(fields.filter { $0.value.isNull }.keys)
                    if let v = incoming.distanceUnit { self.value.distanceUnit = v }
                    if let v = incoming.poolLength { self.value.poolLength = v }
                    if let v = incoming.sleepTimerMinutes { self.value.sleepTimerMinutes = v }
                    if let v = incoming.mapsProvider { self.value.mapsProvider = v } else if cleared.contains("mapsProvider") { self.value.mapsProvider = nil }
                    return .taken
                },
                defaultValue: { FakeSettings.compiled })
    }
}

// MARK: - The tests

@MainActor
final class StageDAdapterTests: XCTestCase {
    private var catalog: DataCatalog!
    private var server: MemorySyncServer!
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        catalog = try DataCatalog.decode(Data(contentsOf: url))
        server = MemorySyncServer(catalog: catalog)
        server.hubDevices = ["phone"]
    }

    private func engine(_ device: String, hub: Bool, _ adapters: [any RecordAdapter]) async throws -> SpaceSync {
        var config = SpaceSync.Configuration(device: device, isHub: hub, catalog: catalog)
        config.debounce = .seconds(3_600)   // the tests run passes themselves
        config.blobRetryBase = 0.05
        let engine = try SpaceSync(mirror: RecordMirror(), transport: MemoryTransport(server: server, device: device),
                                   config: config)
        for adapter in adapters { await engine.registerAdapter(adapter) }
        return engine
    }

    /// The phone seeds, then the iPad after it, as `MoveOver` orders them.
    private func phoneThenIPad(_ types: [String], phone: [any RecordAdapter], iPad: [any RecordAdapter]) async throws
        -> (SpaceSync, SpaceSync) {
        let p = try await engine("phone", hub: true, phone)
        await p.seed(types: types)
        let i = try await engine("ipad", hub: false, iPad)
        await i.setHubPresence(.seeded(Set(types)))
        await i.seed(types: types)
        await p.syncNow(reason: "test")
        return (p, i)
    }

    private func controls(_ source: FakeControls, _ kinds: [(ControlKind, ControlsAdapter.Codec)]) -> BoundAdapter {
        BoundAdapter("controls", kinds.map { kind, codec in
            ControlsAdapter.binding(LegacyInventory.controlKinds[kind.rawValue]!, kind: kind, source: source, codec: codec,
                                    editedAt: { [unowned source] kind, id in source.edited["\(kind.rawValue)-\(id)"] })
        })
    }

    private func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    // MARK: Controls: round trips, ids, seed clocks

    func testControlsItemsRoundTripUnchangedThroughTheSpace() async throws {
        let showID = UUID().uuidString
        let podcast = Podcast(id: UUID(uuidString: showID)!, feedURL: URL(string: "https://example.com/feed.xml")!,
                              title: "Acquired", author: "Ben & David", artworkURL: URL(string: "https://example.com/a.jpg"))
        var settings = PodcastSettings(podcast)
        settings.speed = 1.4
        settings.mutedNarrators = ["Zed", "Ann"]
        settings.mutedVoiceGenders = [.female]
        let alarm = OneOffAlarm(fire: t0.addingTimeInterval(86_400 * 3_650), label: "Flight")

        let phone = FakeControls()
        phone.put(.show, showID, PodcastSubscription(podcast), at: t0)
        phone.put(.podcast, showID, settings, at: t0)
        phone.put(.alarm, alarm.id.uuidString, alarm, at: t0)
        phone.put(.skipCorrection, "episode-1", 3, at: t0)
        let iPad = FakeControls()
        let kinds: [(ControlKind, ControlsAdapter.Codec)] = [
            (.show, .model(PodcastSubscription.self)), (.podcast, .model(PodcastSettings.self)),
            (.alarm, .model(OneOffAlarm.self)), (.skipCorrection, .model(Int.self, shape: .wrapped)),
        ]
        let types = ["podcast.show", "podcast.settings", "plan.alarm", "podcast.skipCorrection"]
        _ = try await phoneThenIPad(types, phone: [controls(phone, kinds)], iPad: [controls(iPad, kinds)])

        XCTAssertEqual(iPad.value(.show, showID, as: PodcastSubscription.self), PodcastSubscription(podcast))
        XCTAssertEqual(iPad.value(.podcast, showID, as: PodcastSettings.self), settings)
        XCTAssertEqual(iPad.value(.alarm, alarm.id.uuidString, as: OneOffAlarm.self), alarm)
        XCTAssertEqual(iPad.value(.skipCorrection, "episode-1", as: Int.self), 3)

        // Fields are the item's own keys; a value that isn't a struct is `v`; ids are the stores'.
        let show = try XCTUnwrap(server.record("podcast.settings", showID))
        XCTAssertEqual(show.fields["speed"], .double(1.4))
        XCTAssertEqual(show.fields["mutedNarrators"], .array([.string("Ann"), .string("Zed")]), "a set, sorted")
        XCTAssertEqual(server.record("podcast.skipCorrection", "episode-1")?.fields, ["v": .int(3)])
        // Seeded at the item's last edit, as the Controls sync knew it.
        XCTAssertEqual(show.clocks["speed"], HLC(ms: ms(t0), counter: 0, device: "phone").text)
    }

    func testRealSkipPlanAndNarratorStoresRoundTripUnchanged() async throws {
        let folder = { FileManager.default.temporaryDirectory.appendingPathComponent("stage-d-\(UUID().uuidString)") }
        let (phoneDir, iPadDir) = (folder(), folder())
        for dir in [phoneDir, iPadDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { for dir in [phoneDir, iPadDir] { try? FileManager.default.removeItem(at: dir) } }
        let phoneSkips = SkipPlanStore(directory: phoneDir), iPadSkips = SkipPlanStore(directory: iPadDir)
        let phoneVoices = NarratorVoiceStore(directory: phoneDir), iPadVoices = NarratorVoiceStore(directory: iPadDir)
        let slots = DeclaredAdSlots(episodeID: "ep-9", headers: ["x-ad-break": "120,900"], byteCount: 42_000_000,
                                    capturedAt: t0)
        _ = phoneSkips.applyCloud(.adSlots, id: "ep-9", item: try JSONEncoder().encode(slots))
        _ = phoneSkips.applyCloud(.skipCorrection, id: "ep-9|120", item: try JSONEncoder().encode(2))
        let reading = NarratorVoiceStore.Reading(gender: .male, confidence: 0.93, windowsUsed: 7, decidedAt: t0)
        _ = phoneVoices.applyCloud(.narratorReading, id: "https://example.com/ep/9", item: try JSONEncoder().encode(reading))
        _ = phoneVoices.applyCloud(.narratorOverride, id: "Jane Doe", item: try JSONEncoder().encode(VoiceGender.female))

        func adapters(_ skips: SkipPlanStore, _ voices: NarratorVoiceStore) -> [any RecordAdapter] {
            let none: @MainActor (ControlKind, String) -> Date? = { _, _ in nil }
            return [BoundAdapter("skip plans", [
                ControlsAdapter.binding("podcast.adSlots", kind: .adSlots, source: skips, codec: .model(DeclaredAdSlots.self), editedAt: none),
                ControlsAdapter.binding("podcast.skipCorrection", kind: .skipCorrection, source: skips,
                                        codec: .model(Int.self, shape: .wrapped), editedAt: none),
            ]), BoundAdapter("narrator voices", [
                ControlsAdapter.binding("podcast.narratorReading", kind: .narratorReading, source: voices,
                                        codec: .model(NarratorVoiceStore.Reading.self), editedAt: none),
                ControlsAdapter.binding("podcast.narratorOverride", kind: .narratorOverride, source: voices,
                                        codec: .model(VoiceGender.self, shape: .wrapped), editedAt: none),
            ])]
        }
        let types = ["podcast.adSlots", "podcast.skipCorrection", "podcast.narratorReading", "podcast.narratorOverride"]
        _ = try await phoneThenIPad(types, phone: adapters(phoneSkips, phoneVoices), iPad: adapters(iPadSkips, iPadVoices))

        // The same values (a JSONEncoder's bytes needn't come out in the same order twice).
        func same<T: Codable>(_ a: Data?, _ b: Data?, _ type: T.Type) -> Bool {
            guard let a, let b, let x = try? JSONDecoder().decode(T.self, from: a),
                  let y = try? JSONDecoder().decode(T.self, from: b) else { return false }
            return (try? CanonicalJSON.value(of: x)) == (try? CanonicalJSON.value(of: y))
        }
        XCTAssertTrue(same(iPadSkips.cloudItem(.adSlots, id: "ep-9"), phoneSkips.cloudItem(.adSlots, id: "ep-9"), DeclaredAdSlots.self))
        XCTAssertTrue(same(iPadSkips.cloudItem(.skipCorrection, id: "ep-9|120"), phoneSkips.cloudItem(.skipCorrection, id: "ep-9|120"), Int.self))
        XCTAssertTrue(same(iPadVoices.cloudItem(.narratorReading, id: "https://example.com/ep/9"),
                           phoneVoices.cloudItem(.narratorReading, id: "https://example.com/ep/9"), NarratorVoiceStore.Reading.self))
        XCTAssertEqual(iPadVoices.narratorOverrides["Jane Doe"], .female)
        XCTAssertEqual(server.record("podcast.narratorOverride", "Jane Doe")?.fields, ["v": .string("female")],
                       "a long id travels as it is")
    }

    func testAControlKindHeldUntilItsParentArrivesIsAppliedOnReplay() async throws {
        let showID = UUID().uuidString
        let podcast = Podcast(id: UUID(uuidString: showID)!, feedURL: URL(string: "https://example.com/f.xml")!,
                              title: "Show", author: nil, artworkURL: nil)
        let phone = FakeControls()
        phone.put(.podcast, showID, PodcastSettings(podcast), at: t0)
        let iPad = FakeControls()
        iPad.parent = [.podcast: .show]   // settings wait for their show, as `PodcastLibrary` does
        let kinds: [(ControlKind, ControlsAdapter.Codec)] = [(.podcast, .model(PodcastSettings.self))]
        let (_, i) = try await phoneThenIPad(["podcast.settings"], phone: [controls(phone, kinds)], iPad: [controls(iPad, kinds)])
        XCTAssertNil(iPad.items[.podcast]?[showID], "held: no show yet")

        iPad.put(.show, showID, PodcastSubscription(podcast))   // the show arrives (here, from its feed)
        await i.replay(types: ["podcast.settings"])
        XCTAssertEqual(iPad.value(.podcast, showID, as: PodcastSettings.self), PodcastSettings(podcast))
    }

    // MARK: Phone-set kinds

    func testTheIPadsDefaultAlarmsDontMultiplyItTakesThePhonesSet() async throws {
        let future = t0.addingTimeInterval(86_400 * 3_650)
        let mine = OneOffAlarm(fire: future, label: "Phone's"), theirs = OneOffAlarm(fire: future.addingTimeInterval(60), label: "Also phone's")
        let phone = FakeControls()
        phone.put(.alarm, mine.id.uuidString, mine, at: t0)
        phone.put(.alarm, theirs.id.uuidString, theirs, at: t0)
        let iPad = FakeControls()
        let iPadDefault = OneOffAlarm(fire: future, label: "iPad's default")
        iPad.put(.alarm, iPadDefault.id.uuidString, iPadDefault, at: t0.addingTimeInterval(100))
        let kinds: [(ControlKind, ControlsAdapter.Codec)] = [(.alarm, .model(OneOffAlarm.self))]
        let (_, i) = try await phoneThenIPad(["plan.alarm"], phone: [controls(phone, kinds)], iPad: [controls(iPad, kinds)])

        XCTAssertEqual(Set((iPad.items[.alarm] ?? [:]).keys), [mine.id.uuidString, theirs.id.uuidString])
        XCTAssertEqual(server.visible(type: "plan.alarm").count, 2, "the iPad's own default didn't join the phone's")
        XCTAssertTrue(server.requests.filter { $0.device == "ipad" }.allSatisfy { $0.changes.isEmpty }, "the spoke seeded nothing")

        // After that, an edit on the iPad flows.
        var moved = mine
        moved.label = "Moved on the iPad"
        iPad.put(.alarm, mine.id.uuidString, moved)
        i.changed(type: "plan.alarm", ids: [mine.id.uuidString])
        await i.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: "plan.alarm")[mine.id.uuidString]?["label"], .string("Moved on the iPad"))
    }

    // MARK: Podcast progress: precious, never back

    private func progressAdapter(_ source: FakeProgress) -> BoundAdapter {
        BoundAdapter("progress", [PodcastProgressAdapter.binding(source)])
    }

    func testProgressSeedsAtItsStampACompletedCopyAtCounterOne() async throws {
        let phone = FakeProgress()
        phone.progress = ["done": .init(position: 0, completed: true, updatedAt: t0),
                          "half": .init(position: 1_200, completed: false, updatedAt: t0)]
        let p = try await engine("phone", hub: true, [progressAdapter(phone)])
        await p.seed(types: [PodcastProgressAdapter.type])
        XCTAssertEqual(server.record(PodcastProgressAdapter.type, "done")?.clocks["v"], HLC(ms: ms(t0), counter: 1, device: "phone").text)
        XCTAssertEqual(server.record(PodcastProgressAdapter.type, "half")?.clocks["v"], HLC(ms: ms(t0), counter: 0, device: "phone").text)
        XCTAssertEqual(server.record(PodcastProgressAdapter.type, "half")?.fields["v"]?.objectValue?["position"], .int(1_200))
    }

    func testAFinishBeatsAPositionStampedAlikeOnEveryDevice() async throws {
        let phone = FakeProgress(), iPad = FakeProgress()
        phone.progress = ["e": .init(position: 2_000, completed: false, updatedAt: t0)]
        iPad.progress = ["e": .init(position: 0, completed: true, updatedAt: t0)]
        _ = try await phoneThenIPad([PodcastProgressAdapter.type], phone: [progressAdapter(phone)], iPad: [progressAdapter(iPad)])
        XCTAssertEqual(phone.progress["e"]?.completed, true)
        XCTAssertEqual(iPad.progress["e"]?.completed, true)
    }

    func testAPositionOnlyCopyWithAnOlderStampNeverBeatsANewerOne() async throws {
        // The iPad listened further, later; the phone then relays a Watch report stamped earlier,
        // which goes up with a fresh clock and so wins the merge in the space.
        let phone = FakeProgress(), iPad = FakeProgress()
        phone.progress = ["e": .init(position: 300, completed: false, updatedAt: t0)]
        iPad.known = ["e"]
        let (p, i) = try await phoneThenIPad([PodcastProgressAdapter.type], phone: [progressAdapter(phone)], iPad: [progressAdapter(iPad)])
        XCTAssertEqual(iPad.progress["e"]?.position, 300)

        iPad.progress["e"] = .init(position: 1_800, completed: false, updatedAt: t0.addingTimeInterval(600))
        i.changed(type: PodcastProgressAdapter.type, ids: ["e"])
        // Before the phone hears of it, the Watch's older report lands there.
        phone.progress["e"] = .init(position: 900, completed: false, updatedAt: t0.addingTimeInterval(300))
        p.changed(type: PodcastProgressAdapter.type, ids: ["e"])
        await i.syncNow(reason: "test")
        await p.syncNow(reason: "test")   // the phone's copy wins the merge on its fresh clock …
        await i.syncNow(reason: "test")   // … the iPad keeps its later one and sends it again …
        XCTAssertEqual(iPad.progress["e"]?.position, 1_800, "the iPad's later progress never went back")
        await p.syncNow(reason: "test")   // … and the phone takes it.
        XCTAssertEqual(phone.progress["e"]?.position, 1_800)
        XCTAssertEqual(server.visible(type: PodcastProgressAdapter.type)["e"]?["v"]?.objectValue?["position"], .int(1_800))
    }

    func testProgressForAnEpisodeNotHereYetWaitsInTheMirrorAndIsAppliedOnReplay() async throws {
        let phone = FakeProgress(), iPad = FakeProgress()
        phone.progress = ["new-episode": .init(position: 0, completed: true, updatedAt: t0),
                          "known": .init(position: 50, completed: false, updatedAt: t0)]
        iPad.known = ["known"]
        let (_, i) = try await phoneThenIPad([PodcastProgressAdapter.type], phone: [progressAdapter(phone)], iPad: [progressAdapter(iPad)])
        XCTAssertNil(iPad.progress["new-episode"], "its feed hasn't loaded here")
        XCTAssertEqual(iPad.progress["known"]?.position, 50)
        XCTAssertGreaterThan(iPad.batches, 0, "applied as one batch")

        iPad.known.insert("new-episode")   // the feed loaded: `PodcastLibrary` calls replay
        await i.replay(types: [PodcastProgressAdapter.type])
        XCTAssertEqual(iPad.progress["new-episode"]?.completed, true)
    }

    // MARK: Listens and their routes

    func testAListensRouteGoesUpOnlyOnceTheListenHasEnded() async throws {
        let phone = FakeListens(), iPad = FakeListens()
        let id = UUID()
        let route = Data((0..<240).map { UInt8($0) })
        phone.syncListens = [ListenEvent(id: id, date: t0, podcastTitle: "Acquired", episodeTitle: "Nvidia", routePointCount: 10)]
        phone.addRoute(id, route)
        phone.active = id
        let adapter = { (source: FakeListens) in ListenAdapter.adapter(source) }
        let (p, i) = try await phoneThenIPad([ListenAdapter.type], phone: [adapter(phone)], iPad: [adapter(iPad)])
        XCTAssertNil(server.record(ListenAdapter.type, id.uuidString)?.fields["route"], "still recording: no route yet")
        XCTAssertEqual(server.record(ListenAdapter.type, id.uuidString)?.fields["episodeTitle"], .string("Nvidia"),
                       "the rest of the listen went meanwhile")
        XCTAssertTrue(server.blobPuts.isEmpty)

        phone.active = nil
        phone.syncListens[0].endedAt = t0.addingTimeInterval(1_800)
        p.changed(type: ListenAdapter.type, ids: [id.uuidString])
        await p.syncNow(reason: "test")
        let reference = try XCTUnwrap(server.record(ListenAdapter.type, id.uuidString)?.fields["route"]?.blobReference)
        XCTAssertEqual(reference.sha256, BlobFiles.sha256(of: route))
        XCTAssertEqual(server.blobPuts.count, 1)

        await i.syncNow(reason: "test")
        await i.blobsSettled()
        XCTAssertEqual(iPad.stored[id], route, "routes come down eagerly")
        XCTAssertEqual(iPad.syncListens.first?.endedAt, phone.syncListens[0].endedAt)
        XCTAssertEqual(iPad.syncListens.first?.route, [], "points stay in the route file")
    }

    // MARK: Transcripts: the better one wins

    func testATranscriptOfALowerQualityNeverReplacesABetterOne() async throws {
        let phone = FakeTranscripts(), iPad = FakeTranscripts()
        let word = TranscriptWord(text: "hello", start: 1, end: 1.4, speaker: nil)
        phone.keep(Transcript(episodeID: "https://example.com/ep/1", source: .onDevice, words: [word]))
        iPad.keep(Transcript(episodeID: "https://example.com/ep/1", source: .parakeet, words: [word, word]))
        let (p, _) = try await phoneThenIPad([TranscriptAdapter.type], phone: [TranscriptAdapter.adapter(phone)],
                                             iPad: [TranscriptAdapter.adapter(iPad)])
        await p.syncNow(reason: "test")
        XCTAssertEqual(server.record(TranscriptAdapter.type, "https://example.com/ep/1")?.fields["source"], .string("parakeet"),
                       "the iPad's better transcript went up in place of the phone's")
        XCTAssertEqual(iPad.syncTranscripts["https://example.com/ep/1"], .parakeet)

        // Its text comes down when the phone first wants it.
        let fetched = await p.ensureBlob(type: TranscriptAdapter.type, id: "https://example.com/ep/1", field: TranscriptAdapter.bodyField)
        XCTAssertTrue(fetched)
        XCTAssertEqual(phone.transcript("https://example.com/ep/1")?.source, .parakeet)
        XCTAssertEqual(phone.transcript("https://example.com/ep/1")?.words.count, 2)
    }

    // MARK: Voice notes

    func testCanonicalNoteEchoStopsKeptOwnFeedback() throws {
        let stamp = Date(timeIntervalSinceReferenceDate: 814310821.492354)
        let note = VoiceNote(createdAt: stamp, updatedAt: stamp, audioFilename: "fixture.m4a")
        let fields = try CanonicalJSON.fields(of: note)
        var decisions: [Int] = []
        for legacy in [true, false] {
            let source = FakeNotes()
            source.compareSubmillisecondDates = legacy
            source.syncNotes = [note]
            let adapter = VoiceNoteAdapter.adapter(source)
            var kept = 0
            for _ in 0..<100 {
                XCTAssertEqual(adapter.apply(VoiceNoteAdapter.type, records: [(id: note.id.uuidString, fields: fields)])[note.id.uuidString], true)
                kept += adapter.keptOwn(VoiceNoteAdapter.type).count
            }
            decisions.append(kept)
        }
        XCTAssertEqual(decisions, [100, 0], "the same canonical echo no longer requests another upload")
    }

    func testAVoiceNoteAndItsRecordingRoundTrip() async throws {
        let phone = FakeNotes(), iPad = FakeNotes()
        var note = VoiceNote(createdAt: t0, audioFilename: "note-1.m4a")
        note.transcript = "Look into cooling"
        note.context = .init(episodeID: "ep", episodeTitle: "Data Centers", podcastTitle: "Acquired", timestamp: 2_040)
        note.status = .transcribed
        let audio = Data(repeating: 7, count: 4_096)
        phone.record(note, audio: audio)
        let (_, i) = try await phoneThenIPad([VoiceNoteAdapter.type], phone: [VoiceNoteAdapter.adapter(phone)],
                                             iPad: [VoiceNoteAdapter.adapter(iPad)])
        XCTAssertEqual(iPad.syncNotes, [note])
        XCTAssertNil(iPad.storedAudio[note.id], "the recording comes down on first use (lazy)")
        let fetched = await i.ensureBlob(type: VoiceNoteAdapter.type, id: note.id.uuidString, field: VoiceNoteAdapter.audioField)
        XCTAssertTrue(fetched)
        XCTAssertEqual(iPad.storedAudio[note.id], audio)
        XCTAssertEqual(server.record(VoiceNoteAdapter.type, note.id.uuidString)?.clocks["transcript"],
                       HLC(ms: ms(t0), counter: 0, device: "phone").text, "seeded at the note's own time")
    }

    // MARK: Settings and key-value dictionaries

    func testSettingsMergeFieldByFieldTheMacsUnitsAndThePhonesPoolBothStand() async throws {
        let phone = FakeSettingsStore(), mac = FakeSettingsStore()
        mac.value.distanceUnit = "kilometers"   // differs from the default: the spoke seeds it, at 0
        let (p, m) = try await phoneThenIPad(["core.appSettings"], phone: [BoundAdapter("settings", [phone.binding()])],
                                             iPad: [BoundAdapter("settings", [mac.binding()])])
        let seeded = try XCTUnwrap(server.record("core.appSettings", "appSettings"))
        XCTAssertEqual(Set(seeded.fields.keys), ["distanceUnit"], "nothing seeds a default")
        XCTAssertEqual(phone.value.distanceUnit, "kilometers", "a spoke's real value beats a hub still on the default")

        mac.value.distanceUnit = "miles"
        m.changed(type: "core.appSettings", ids: ["appSettings"])
        phone.value.poolLength = "meters50"
        p.changed(type: "core.appSettings", ids: ["appSettings"])
        await m.syncNow(reason: "test")
        await p.syncNow(reason: "test")
        await m.syncNow(reason: "test")
        for store in [phone, mac] {
            XCTAssertEqual(store.value.distanceUnit, "miles")
            XCTAssertEqual(store.value.poolLength, "meters50")
        }

        // A setting cleared on one device is cleared on the other.
        phone.value.mapsProvider = "google"
        p.changed(type: "core.appSettings", ids: ["appSettings"])
        await p.syncNow(reason: "test")
        await m.syncNow(reason: "test")
        XCTAssertEqual(mac.value.mapsProvider, "google")
        mac.value.mapsProvider = nil
        m.changed(type: "core.appSettings", ids: ["appSettings"])
        await m.syncNow(reason: "test")
        await p.syncNow(reason: "test")
        XCTAssertNil(phone.value.mapsProvider)
    }

    func testPerKeyDictionaryEntriesFromTwoDevicesBothStand() async throws {
        var phoneEntries: [String: Int] = ["id:a": 420], iPadEntries: [String: Int] = ["id:b": 480]
        func binding(_ entries: @escaping () -> [String: Int], _ set: @escaping ([String: Int?]) -> Void) -> BoundAdapter {
            BoundAdapter("key-value", [.keyed("plan.reminderAnchorUsual", entries: entries, set: set)])
        }
        let phone = binding({ phoneEntries }, { for (k, v) in $0 { phoneEntries[k] = v } })
        let iPad = binding({ iPadEntries }, { for (k, v) in $0 { iPadEntries[k] = v } })
        let (p, i) = try await phoneThenIPad(["plan.reminderAnchorUsual"], phone: [phone], iPad: [iPad])
        XCTAssertEqual(phoneEntries, ["id:a": 420, "id:b": 480])
        XCTAssertEqual(iPadEntries, ["id:a": 420, "id:b": 480])
        XCTAssertEqual(server.record("plan.reminderAnchorUsual", "id:a")?.fields, ["v": .int(420)])

        // Written at once on both, as the whole dictionary used to be: neither erases the other.
        phoneEntries["title:stretch"] = 600
        p.changed(type: "plan.reminderAnchorUsual", ids: ["title:stretch"])
        iPadEntries["id:a"] = 435
        i.changed(type: "plan.reminderAnchorUsual", ids: ["id:a"])
        await p.syncNow(reason: "test")
        await i.syncNow(reason: "test")
        await p.syncNow(reason: "test")
        XCTAssertEqual(phoneEntries, ["id:a": 435, "id:b": 480, "title:stretch": 600])
        XCTAssertEqual(iPadEntries, phoneEntries)
    }

    // MARK: Fable's review: the Controls sync notes nothing of the space's changes

    func testTakingAndRemovingThroughTheAdapterIsNoEditForTheControlsSync() async throws {
        // `CloudControlsSync.mark` and `offered` return at once while `isApplyingFromSpace`: the
        // engine's records, and the account-change clear, leave its state (edit times, tombstones,
        // what waits to go up) untouched, whatever the Controls channel's mode.
        let saved = (ControlChangeReporter.changed, ControlChangeReporter.deleted)
        defer { (ControlChangeReporter.changed, ControlChangeReporter.deleted) = saved }
        var seen: [String] = []
        ControlChangeReporter.changed = { kind, id in seen.append("changed \(kind.rawValue) \(id) \(ControlChangeReporter.isApplyingFromSpace)") }
        ControlChangeReporter.deleted = { kind, id in seen.append("deleted \(kind.rawValue) \(id) \(ControlChangeReporter.isApplyingFromSpace)") }
        let showID = UUID().uuidString
        let podcast = Podcast(id: UUID(uuidString: showID)!, feedURL: URL(string: "https://example.com/s.xml")!,
                              title: "Show", author: nil, artworkURL: nil)
        let store = FakeControls()
        let adapter = controls(store, [(.show, .model(PodcastSubscription.self))])
        let fields = try CanonicalJSON.fields(of: PodcastSubscription(podcast))
        _ = adapter.apply("podcast.show", records: [(id: showID, fields: fields)])
        adapter.remove("podcast.show", ids: [showID])
        XCTAssertEqual(seen, ["changed show \(showID) true", "deleted show \(showID) true"])
        XCTAssertFalse(ControlChangeReporter.isApplyingFromSpace, "the scope ends")
        XCTAssertNil(store.items[.show]?[showID])
    }

    func testAnOldBuildsRoutineArrivingAfterTheFlipEntersAtItsSeedClockOnce() async throws {
        let routine = "plan.routine", id = UUID().uuidString
        let store = FakeControls()
        let adapter = controls(store, [(.routine, .model(OneOffAlarm.self))])   // any Codable item will do
        let phone = try await engine("phone", hub: true, [adapter])
        let suite = UserDefaults(suiteName: "stage-d-\(UUID().uuidString)")!
        let modes = LegacyCloudModeStore(defaults: suite, account: "acc", enabled: true)
        let channel = FakeLegacyChannel("controls", tier: .personal, types: [routine], modes: modes, events: SpaceSyncTests.LogBox())
        let move = MoveOver(MoveOver.Dependencies(
            engine: phone, isHub: true, channels: [channel], adapters: [adapter], modes: modes,
            account: { _ in MoveOver.Account(hasIPhone: true, seeded: [routine], allFlipped: false, icloud: "keep") },
            defaults: suite, stateKey: "stage-d-move", log: { _ in }))
        await move.start(listening: false)
        defer { move.stop() }
        XCTAssertEqual(move.state.personal.phase, .flipped)

        // A store's own report of the item it's applying from iCloud doesn't go to the space;
        // the Controls sync's arrival does, once.
        let editedAt = t0.addingTimeInterval(-86_400)
        let alarm = OneOffAlarm(fire: t0.addingTimeInterval(86_400 * 3_650), label: "From an old build")
        LegacyCloud.applyingFromCloud {
            store.put(.routine, id, alarm, at: editedAt)
            XCTAssertNil(ControlsAdapter.ownReport(.routine, id: id), "the store's own report isn't sent as well")
            ControlsAdapter.legacyApplied(.routine, id: id, deleted: false)
        }
        XCTAssertEqual(ControlsAdapter.ownReport(.routine, id: id), routine, "outside it, an edit here is reported")
        for _ in 0..<200 where server.record(routine, id) == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(server.record(routine, id)?.clocks["label"], HLC(ms: ms(editedAt), counter: 0, device: "phone").text,
                       "entered with its own edit time, never a fresh clock")
    }

    // MARK: Fable's review: progress stamped ahead never wins everywhere

    func testAFutureStampedCopyHereStaysButDoesntGoUpOverTheSpaces() async throws {
        let now = Date()
        let phone = FakeProgress(), iPad = FakeProgress()
        phone.progress = ["e": .init(position: 600, completed: false, updatedAt: now.addingTimeInterval(-3_600))]
        iPad.known = ["e"]
        let p = try await engine("phone", hub: true, [progressAdapter(phone)])
        await p.seed(types: [PodcastProgressAdapter.type])
        let i = try await engine("ipad", hub: false, [BoundAdapter("progress", [PodcastProgressAdapter.binding(iPad, now: { now })])])
        await i.setHubPresence(.seeded([PodcastProgressAdapter.type]))
        await i.seed(types: [PodcastProgressAdapter.type])
        XCTAssertEqual(iPad.progress["e"]?.position, 600)

        // The Watch relays a report stamped by a clock a day fast; then the phone listens on.
        iPad.progress["e"] = .init(position: 120, completed: false, updatedAt: now.addingTimeInterval(86_400))
        phone.progress["e"] = .init(position: 700, completed: false, updatedAt: now)
        p.changed(type: PodcastProgressAdapter.type, ids: ["e"])
        await p.syncNow(reason: "test")
        let sentBefore = server.requests.filter { $0.device == "ipad" && !$0.changes.isEmpty }.count
        await i.syncNow(reason: "test")
        await i.syncNow(reason: "test")
        XCTAssertEqual(iPad.progress["e"]?.position, 120, "the library's own rule stands here")
        XCTAssertEqual(server.requests.filter { $0.device == "ipad" && !$0.changes.isEmpty }.count, sentBefore,
                       "the skewed copy isn't sent up to beat everyone's")
        XCTAssertEqual(server.visible(type: PodcastProgressAdapter.type)["e"]?["v"]?.objectValue?["position"], .int(700))
        await p.syncNow(reason: "test")
        XCTAssertEqual(phone.progress["e"]?.position, 700, "the phone's progress never went back")
    }

    func testProgressWithNoStampSeedsLowAndLosesToAnyStampedCopy() async throws {
        let phone = FakeProgress(), iPad = FakeProgress()
        phone.progress = ["e": .init(position: 50, completed: false, updatedAt: nil)]
        iPad.progress = ["e": .init(position: 900, completed: false, updatedAt: t0)]
        _ = try await phoneThenIPad([PodcastProgressAdapter.type], phone: [progressAdapter(phone)], iPad: [progressAdapter(iPad)])
        XCTAssertEqual(server.record(PodcastProgressAdapter.type, "e")?.fields["v"]?.objectValue?["position"], .int(900))
        XCTAssertEqual(phone.progress["e"]?.position, 900)
    }

    // MARK: Fable's review: keys that name someone or something

    func testTitleKeysTravelHashedWithTheKeyInAFieldAndEmptyKeysStayHome() async throws {
        var phoneEntries: [String: Int] = ["title:take creatine": 480, "id:abc": 420, "": 1]
        var iPadEntries: [String: Int] = [:]
        func binding(_ entries: @escaping () -> [String: Int], _ set: @escaping ([String: Int?]) -> Void) -> BoundAdapter {
            BoundAdapter("key-value", [.keyed("plan.reminderAnchorUsual", hashKey: { $0.hasPrefix("title:") },
                                              entries: entries, set: set)])
        }
        let phone = binding({ phoneEntries }, { for (k, v) in $0 { phoneEntries[k] = v } })
        let iPad = binding({ iPadEntries }, { for (k, v) in $0 { iPadEntries[k] = v } })
        let (p, i) = try await phoneThenIPad(["plan.reminderAnchorUsual"], phone: [phone], iPad: [iPad])
        let records = server.visible(type: "plan.reminderAnchorUsual")
        XCTAssertEqual(records.count, 2, "the empty key isn't kept")
        XCTAssertEqual(records["id:abc"], ["v": .int(420)], "a plain short key is its id")
        let hashed = try XCTUnwrap(records.first { $0.key.hasPrefix("h:") })
        XCTAssertFalse(hashed.key.contains("creatine"))
        XCTAssertEqual(hashed.value["key"], .string("title:take creatine"))
        XCTAssertEqual(iPadEntries, ["title:take creatine": 480, "id:abc": 420], "the key comes back as it was")

        let long = "id:" + String(repeating: "x", count: 300)
        phoneEntries[long] = 5
        p.changed(type: "plan.reminderAnchorUsual", ids: [SyncKeys.recordID(long, hashed: false)!])
        await p.syncNow(reason: "test")
        await i.syncNow(reason: "test")
        XCTAssertEqual(iPadEntries[long], 5, "a long key travels hashed too")
        // Removed through its hashed id.
        iPad.remove("plan.reminderAnchorUsual", ids: [hashed.key])
        XCTAssertNil(iPadEntries["title:take creatine"])
    }

    // MARK: Fable's review: every T1 type has an adapter

    func testEveryPersonalCatalogTypeHasAStageDAdapter() {
        let personal = Set(catalog.types.filter { !$0.isHealth }.map(\.type))
        let listed = Set(EverythingElseTypes.all)
        XCTAssertEqual(listed.count, EverythingElseTypes.all.count, "no type twice")
        let notYet = Set(EverythingElseTypes.withoutAdapter)
        XCTAssertTrue(personal.subtracting(notYet).isSubset(of: listed), "no adapter for \(personal.subtracting(listed).subtracting(notYet).sorted())")
        XCTAssertTrue(notYet.isDisjoint(with: listed) && notYet.isSubset(of: LegacyInventory.withoutLegacy),
                      "a type without an adapter is one no legacy channel carries, so the move doesn't wait for it")
        XCTAssertTrue(listed.allSatisfy { catalog[$0] != nil }, "not in the catalog: \(listed.filter { catalog[$0] == nil })")
        // core.wakePlan is T2 in the catalog and stays among these adapters.
        XCTAssertTrue(listed.subtracting(personal).isSubset(of: ["core.wakePlan"]))
    }

    func testATranscriptsBlobFileIsOnlyAPackedCopyAlreadyMade() async throws {
        let source = FakeTranscripts()
        source.keep(Transcript(episodeID: "ep", source: .parakeet, words: [TranscriptWord(text: "a", start: 0, end: 1, speaker: nil)]))
        let adapter = TranscriptAdapter.adapter(source)
        XCTAssertNil(adapter.blobFile(TranscriptAdapter.type, id: "ep", field: TranscriptAdapter.bodyField),
                     "nothing is packed on the main actor")
        let item = try XCTUnwrap(adapter.snapshot(TranscriptAdapter.type)["ep"])
        let fields = try await Task.detached { try CanonicalJSON.fields(of: item) }.value   // the engine encodes off it
        let file = try XCTUnwrap(adapter.blobFile(TranscriptAdapter.type, id: "ep", field: TranscriptAdapter.bodyField))
        XCTAssertEqual(fields["body"]?.blobReference?.sha256, BlobFiles.sha256(of: try Data(contentsOf: file)))
    }

    // MARK: Performance (house rule): snapshot, encode and seed at a heavy user's size

    func testSeedingThreeThousandListensAndTwoThousandProgressRecordsStaysOffTheMainActor() async throws {
        let listens = FakeListens()
        listens.syncListens = (0..<3_000).map { n in
            ListenEvent(id: UUID(), date: t0.addingTimeInterval(Double(n) * 3_600), endedAt: t0.addingTimeInterval(Double(n) * 3_600 + 1_500),
                        podcastID: UUID(), episodeID: "https://example.com/episodes/\(n)", podcastTitle: "Show \(n % 40)",
                        episodeTitle: "Episode \(n) — a title of a usual length", lat: 37.7, lon: -122.4, place: "Home",
                        routePointCount: n % 10 == 0 ? 60 : 0)
        }
        for event in listens.syncListens where event.routePointCount > 0 {
            listens.addRoute(event.id, Data(repeating: UInt8(truncatingIfNeeded: event.date.hashValue), count: 24 * 60))
        }
        let progress = FakeProgress()
        for n in 0..<2_000 {
            progress.progress["https://example.com/episodes/\(n)"] = .init(position: Double(n), completed: n % 3 == 0,
                                                                           updatedAt: t0.addingTimeInterval(Double(n)))
        }
        let adapters: [any RecordAdapter] = [ListenAdapter.adapter(listens), BoundAdapter("progress", [PodcastProgressAdapter.binding(progress)])]
        let clock = ContinuousClock()

        // What the main actor does: take the snapshot (values, no encoding) and the seed clocks.
        var snapshotTime = Duration.zero
        var snapshots: [String: [String: any Encodable & Sendable]] = [:]
        for (adapter, type) in [(adapters[0], ListenAdapter.type), (adapters[1], PodcastProgressAdapter.type)] {
            let start = clock.now
            let items = adapter.snapshot(type)
            for id in items.keys { _ = adapter.seedClock(type, id: id); _ = adapter.seedRank(type, id: id) }
            snapshotTime += clock.now - start
            snapshots[type] = items
        }
        // What runs off it: the canonical encoding (and the routes' hashes).
        let taken = snapshots
        let encodeTime = await Task.detached {
            let start = ContinuousClock.now
            for items in taken.values { for item in items.values { _ = try? CanonicalJSON.fields(of: item) } }
            return ContinuousClock.now - start
        }.value
        // The whole seed, through the engine against the in-memory service, one type at a time.
        let phone = try await engine("phone", hub: true, adapters)
        var start = clock.now
        await phone.seed(types: [PodcastProgressAdapter.type])
        let progressSeed = clock.now - start
        start = clock.now
        await phone.seed(types: [ListenAdapter.type])
        let listenSeed = clock.now - start
        let seedTime = progressSeed + listenSeed

        XCTAssertEqual(server.visible(type: ListenAdapter.type).count, 3_000)
        XCTAssertEqual(server.visible(type: PodcastProgressAdapter.type).count, 2_000)
        let isSeeded = await phone.isSeeded
        XCTAssertTrue(isSeeded)
        print("PERF stage D: main-actor snapshot+seed clocks \(snapshotTime); encode off main \(encodeTime); full seed (encode, mirror, the in-memory service): 2,000 progress \(progressSeed), 3,000 listens with 300 route uploads \(listenSeed), together \(seedTime)")
        XCTAssertLessThan(snapshotTime, .milliseconds(250), "the main actor only copies values")
    }
}
