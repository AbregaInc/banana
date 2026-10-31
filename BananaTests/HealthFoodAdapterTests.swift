import XCTest

// MARK: - Fake stores (the real ones need CloudKit and HealthKit, which this target leaves out)

/// `WellnessStore`'s lists and mutators: full retained meal history, and a supplement's
/// delete that takes its doses and reports each.
@MainActor
final class FakeWellness: WellnessSyncPort {
    var meals: [MealEntry] = []
    var supplements: [SupplementSchedule] = []
    var supplementLogs: [SupplementLog] = []
    var edited: [String: Date] = [:]
    var reports: HealthFood.Reports?
    private(set) var batches = 0

    func applySpaceChanges(_ changes: WellnessCloudChanges) {
        batches += 1
        WellnessCloudMerge.apply(changes, meals: &meals, supplements: &supplements, logs: &supplementLogs)
    }

    func editedAt(_ record: WellnessCloudRecord) -> Date? { edited[record.name] }

    func addMeal(_ meal: MealEntry) {
        meals.insert(meal, at: 0)
        reports?.changed(WellnessSpace.meal, [meal.id.uuidString])
    }

    func upsertSupplement(_ supplement: SupplementSchedule) {
        supplements.removeAll { $0.id == supplement.id }
        supplements.append(supplement)
        reports?.changed(WellnessSpace.supplement, [supplement.id.uuidString])
    }

    func logDose(_ supplement: UUID, day: String, at date: Date) {
        let log = SupplementLog(supplementID: supplement, date: date, status: .taken, day: day)
        supplementLogs.removeAll { WellnessCloudRecord.doseKey($0) == WellnessCloudRecord.doseKey(log) }
        supplementLogs.insert(log, at: 0)
        reports?.changed(WellnessSpace.dose, [WellnessSpace.doseID(log)])
    }

    /// As `WellnessStore.deleteSupplement`: its doses go too, and their deletes are sent.
    func deleteSupplement(_ id: UUID) {
        let doses = WellnessSpace.doseIDs(of: id, in: supplementLogs)
        supplements.removeAll { $0.id == id }
        supplementLogs.removeAll { $0.supplementID == id }
        reports?.deleted(WellnessSpace.supplement, [id.uuidString])
        reports?.deleted(WellnessSpace.dose, doses)
    }
}

/// A store syncing through `CloudControlSource` (workout plans, the meal backlog…), as bytes.
@MainActor
final class FakeControlSource: CloudControlSource {
    var items: [ControlKind: [String: Data]] = [:]
    func cloudItems(_ kind: ControlKind) -> [String: Data] { items[kind] ?? [:] }
    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        items[kind, default: [:]][id] = item
        return true
    }
}

@MainActor
final class FakeKeyed<Value: Codable & Sendable>: HealthFood.KeyedValues {
    var values: [String: Value] = [:]
    func adopt(_ changes: [String: Value?]) {
        for (key, value) in changes { values[key] = value }
    }
}

@MainActor
final class FakeWorkouts: WorkoutSyncPort {
    var summaries: [FitnessSessionSummary] = []
    let directory: URL
    var edited: [UUID: Date] = [:]
    var reports: HealthFood.Reports?

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-fitness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).samples") }
    func samplesFile(_ id: UUID) -> URL? { FileManager.default.fileExists(atPath: url(id).path) ? url(id) : nil }

    func adoptSpaceSummaries(_ incoming: [FitnessSessionSummary]) {
        for summary in incoming {
            summaries.removeAll { $0.id == summary.id }
            summaries.append(summary)
        }
    }

    func adoptSpaceWorkout(_ summary: FitnessSessionSummary, samples: URL) async -> Bool {
        try? FileManager.default.removeItem(at: url(summary.id))
        try? FileManager.default.copyItem(at: samples, to: url(summary.id))
        adoptSpaceSummaries([summary])
        return true
    }

    func removeSpaceWorkouts(_ ids: [UUID]) {
        summaries.removeAll { ids.contains($0.id) }
        for id in ids { try? FileManager.default.removeItem(at: url(id)) }
    }

    func installSpaceSamples(_ id: UUID, from file: URL) -> Bool {
        (try? FileManager.default.moveItem(at: file, to: url(id))) != nil
    }

    func editedAt(_ id: UUID) -> Date? { edited[id] }

    func record(_ summary: FitnessSessionSummary, samples: Data) {
        try? samples.write(to: url(summary.id))
        summaries.append(summary)
        reports?.changed(WorkoutAdapter.type, [summary.id.uuidString])
    }
}

@MainActor
final class FakeSnapshot: HealthSnapshotPort {
    var hasData = true
    var packed = HealthSnapshotCoding.pack(Data(#"{"workouts":[],"trends":{}}"#.utf8))!
    var snapshotDate: Date? = Date(timeIntervalSince1970: 1_760_000_000)
    var adopted: [Data] = []
    func snapshotMaker() -> @Sendable () -> Data? {
        let packed = self.packed
        return { packed }
    }
    func adoptSnapshot(_ packed: Data) { adopted.append(packed) }
}

/// A requests inbox: the asker writes requests, the carrier marks what it did.
@MainActor
final class FakeRequests<R: Codable & Sendable & Identifiable>: HealthRequestPort where R.ID == UUID {
    var requests: [R] = []
    var outcomes: [UUID: String] = [:]
    /// Set on the device that carries requests out: it does so as they arrive.
    var carry: ((R) -> Void)?
    let asked: (R) -> Date

    init(asked: @escaping (R) -> Date) { self.asked = asked }

    func adoptRequests(_ incoming: [R], done: Set<UUID>) {
        for request in incoming where !requests.contains(where: { $0.id == request.id }) {
            requests.append(request)
            if !done.contains(request.id) { carry?(request) }
        }
    }
    func removeRequests(_ ids: [UUID]) { requests.removeAll { ids.contains($0.id) } }
    func askedAt(_ request: R) -> Date { asked(request) }
}

// MARK: - The tests

/// Stage C's adapters (docs/design/DATA-PLATFORM.md §3, §5–§7): every health and food type round-
/// trips its store's items unchanged, seeds at the item's own time, and moves between two devices
/// through the in-memory service.
@MainActor
final class HealthFoodAdapterTests: XCTestCase {
    private var catalog: DataCatalog!
    private var server: MemorySyncServer!
    private var logs: SpaceSyncTests.LogBox!
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)   // 9 Oct 2025, whole seconds
    private var hashes: HealthFood.BlobHashes!

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DataCatalog", withExtension: "json"))
        catalog = try DataCatalog.decode(Data(contentsOf: url))
        server = MemorySyncServer(catalog: catalog)
        server.hubDevices = ["phone"]
        logs = SpaceSyncTests.LogBox()
        hashes = HealthFood.BlobHashes(file: nil)
    }

    private func engine(_ device: String, hub: Bool, _ adapters: [any RecordAdapter], consent: Bool = true) async throws -> SpaceSync {
        var config = SpaceSync.Configuration(device: device, isHub: hub, catalog: catalog)
        config.debounce = .seconds(3_600)
        config.blobRetryBase = 0.05
        let logs = self.logs!
        config.log = { logs.add("\(device): \($0)") }
        let engine = try SpaceSync(mirror: RecordMirror(), transport: MemoryTransport(server: server, device: device), config: config)
        for adapter in adapters { await engine.registerAdapter(adapter) }
        if consent { await engine.setHealthConsent(true) }
        if !hub { await engine.setHubPresence(.seeded(catalog.healthTypes)) }
        return engine
    }

    private func meal(_ name: String, at date: Date, id: UUID = UUID()) -> MealEntry {
        MealEntry(id: id, date: date, items: [MealItem(name: name, serving: "1 bowl",
                                                       macros: .init(calories: 300, proteinGrams: 10, carbohydrateGrams: 40, fatGrams: 8))],
                  source: .manual, name: name)
    }

    private func summary(_ id: UUID = UUID(), start: Date, samples: Int = 10) throws -> FitnessSessionSummary {
        try CanonicalJSON.decode(FitnessSessionSummary.self, from: [
            "id": .string(id.uuidString), "start": .int(HLCClock.ms(start)), "end": .int(HLCClock.ms(start) + 1_800_000),
            "activity": .string("Run"), "sampleCount": .int(Int64(samples)), "totalDistance": .double(5012.5),
        ])
    }

    private func encoded(_ items: [String: any Encodable & Sendable]) throws -> [String: [String: JSONValue]] {
        try items.mapValues { try CanonicalJSON.fields(of: $0) }
    }

    /// Encode everything `a` holds, hand it to `b`, encode what `b` holds: the same.
    @discardableResult
    private func roundTrip(_ type: String, from a: any RecordAdapter, to b: any RecordAdapter,
                           blobs: [String] = [], file: StaticString = #filePath, line: UInt = #line) throws -> [String: [String: JSONValue]] {
        let sent = try encoded(a.snapshot(type))
        XCTAssertFalse(sent.isEmpty, "\(type): nothing to send", file: file, line: line)
        let results = b.apply(type, records: sent.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        XCTAssertEqual(Set(results.filter(\.value).keys), Set(sent.keys), "\(type): every record taken", file: file, line: line)
        for id in sent.keys {
            for field in blobs {
                guard let source = a.blobFile(type, id: id, field: field) else { continue }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: source, to: copy)
                b.storeBlob(type, id: id, field: field, file: copy)
            }
        }
        let back = try encoded(b.snapshot(type))
        XCTAssertEqual(back.mapValues { CanonicalJSON.string($0) }, sent.mapValues { CanonicalJSON.string($0) },
                       "\(type): unchanged", file: file, line: line)
        return sent
    }

    // MARK: - Coverage

    func testEveryHealthAndFoodTypeHasOneAdapter() throws {
        let adapters = allAdapters(isHub: true)
        let types = adapters.flatMap(\.types)
        // The list `SyncAdapters.healthAndFood` is checked against: the catalog's health and food
        // types. (Other T2 types, such as the wake plan worked out from sleep, are Stage D's.)
        let catalogued = Set(catalog.types.map(\.type).filter { $0.hasPrefix("health.") || $0.hasPrefix("food.") })
        XCTAssertEqual(Set(HealthFood.types), catalogued)
        XCTAssertEqual(HealthFood.types.count, catalogued.count)
        XCTAssertTrue(catalogued.isSubset(of: catalog.healthTypes), "all of them need the Health consent")
        XCTAssertEqual(Set(types), catalogued, "an adapter for every health and food type, and nothing else")
        XCTAssertEqual(types.count, Set(types).count, "one adapter per type")
        let carried = LegacyInventory.controlsHealth.union(LegacyInventory.meals).union(LegacyInventory.wellness)
            .union(LegacyInventory.fitness).union(LegacyInventory.kvsHealth)
        XCTAssertTrue(Set(types).isSuperset(of: carried.filter { $0.hasPrefix("health.") || $0.hasPrefix("food.") }),
                      "every health and food type the health tier's legacy channels carry (the wake plan is Stage D's)")
    }

    private func allAdapters(isHub: Bool) -> [any RecordAdapter] {
        let photos = MealPhotoStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString)"))
        let foods = MyFoodsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID().uuidString).json"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString)")
        return [
            WellnessAdapter(port: FakeWellness()),
            HealthFood.ControlSourceAdapter(source: FakeControlSource(), kinds: FoodKinds.wellnessControls),
            HealthFood.ControlSourceAdapter(source: foods, kinds: [FoodKinds.myFood]),
            HealthFood.ControlSourceAdapter(source: FakeControlSource(), kinds: [FoodKinds.mealInbox]),
            MealPhotoAdapter(photos: photos, hashes: hashes),
            HealthFood.ControlSourceAdapter(source: FakeControlSource(), kinds: [FoodKinds.mealPhotoFound]),
            HealthFood.KeyedValuesAdapter(type: "food.searchPick", port: FakeKeyed<[String: Int]>(), whole: false),
            HealthFood.KeyedValuesAdapter(type: "food.estimatorStatus", port: FakeKeyed<MealEstimatorStatus>(), whole: true),
            HealthFood.KeyedValuesAdapter(type: "food.photoScanReport", port: FakeKeyed<MealPhotoScanReport>(), whole: true),
            HealthSnapshotAdapter(port: FakeSnapshot(), isHub: isHub, directory: dir, defaults: UserDefaults(suiteName: UUID().uuidString)!),
            WorkoutAdapter(port: FakeWorkouts(), isHub: isHub, directory: dir, hashes: hashes),
            HealthRequestsAdapter(type: "health.removalRequest", port: FakeRequests<HealthRemovalRequest> { $0.askedAt }),
            HealthRequestsAdapter(type: "health.workoutRevert", port: FakeRequests<WorkoutRevertRequest> { $0.askedAt }),
        ]
    }

    // MARK: - Round trips

    func testMealsSupplementsAndDosesRoundTripUnchanged() throws {
        let phone = FakeWellness(), mac = FakeWellness()
        let vitaminD = SupplementSchedule(name: "Vitamin D", dose: "1 capsule", hour: 8, ingredients: ["cholecalciferol"],
                                          anchor: TimingAnchor(moment: .meal("breakfast"), minutes: 10))
        phone.meals = [meal("Oats", at: t0), meal("Soup", at: t0.addingTimeInterval(3_600))]
        phone.meals[0].photoIDs = [UUID()]
        phone.supplements = [vitaminD, SupplementSchedule(name: "Levothyroxine", kind: .medication, dose: "100 mcg", hour: 7)]
        phone.supplementLogs = [SupplementLog(supplementID: vitaminD.id, date: t0, status: .taken, day: "20251009"),
                                SupplementLog(supplementID: vitaminD.id, date: t0.addingTimeInterval(86_400), status: .skipped)]
        let a = WellnessAdapter(port: phone), b = WellnessAdapter(port: mac)
        for type in WellnessSpace.types { try roundTrip(type, from: a, to: b) }
        XCTAssertEqual(mac.meals.map(\.name).sorted(), ["Oats", "Soup"])
        XCTAssertEqual(mac.supplements.first { $0.id == vitaminD.id }, vitaminD)
        XCTAssertEqual(mac.supplementLogs.count, 2)
        XCTAssertEqual(Set(mac.supplementLogs.compactMap(\.day)).count, 2, "every dose carries its day")
        XCTAssertEqual(mac.batches, 3, "one batch per type")
    }

    func testControlKindsRoundTripUnchanged() throws {
        let phone = FakeControlSource(), mac = FakeControlSource()
        let encoder = JSONEncoder()
        let plan = DeterministicWorkoutBuilder.build(preferences: .init(focus: .mixed, experience: .beginner, durationMinutes: 30,
                                                                         equipment: [.bodyweight], notes: ""))
        phone.items[.workoutPlan] = [plan.id.uuidString: try encoder.encode(plan)]
        let done = WorkoutCompletion(planID: plan.id, startedAt: t0, endedAt: t0.addingTimeInterval(1_800), completedExerciseIDs: ["squat"])
        phone.items[.workoutCompletion] = [done.id.uuidString: try encoder.encode(done)]
        phone.items[.foodCorrection] = ["greek yogurt": try encoder.encode(FoodCorrection(
            macros: .init(calories: 150, proteinGrams: 15, carbohydrateGrams: 6, fatGrams: 5), serving: "1 cup", observedCount: 2, grams: 245))]
        let inbox = MealInboxItem(eatenAt: t0, photos: [MealPhotoRef(takenAt: t0, cloudKey: "k1")], note: "curry", state: .ready,
                                  origin: .scanned, createdAt: t0, readiedBy: "install-1", readiedAt: t0)
        phone.items[.mealInbox] = [inbox.id.uuidString: try encoder.encode(inbox)]
        phone.items[.mealPhotoFound] = ["cloud-key-1": try encoder.encode(t0)]
        let kinds = FoodKinds.wellnessControls + [FoodKinds.mealInbox, FoodKinds.mealPhotoFound]
        let a = HealthFood.ControlSourceAdapter(source: phone, kinds: kinds)
        let b = HealthFood.ControlSourceAdapter(source: mac, kinds: kinds)
        for kind in kinds { try roundTrip(kind.type, from: a, to: b) }
        let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: XCTUnwrap(mac.items[.workoutPlan]?[plan.id.uuidString]))
        XCTAssertEqual(decoded.exercises.map(\.id), plan.exercises.map(\.id))
        XCTAssertEqual(try JSONDecoder().decode(MealInboxItem.self, from: XCTUnwrap(mac.items[.mealInbox]?[inbox.id.uuidString])), inbox)
        XCTAssertEqual(try JSONDecoder().decode(Date.self, from: XCTUnwrap(mac.items[.mealPhotoFound]?["cloud-key-1"])), t0)
    }

    func testMyFoodsRoundTripThroughTheRealStoreInOneSave() throws {
        let dir = FileManager.default.temporaryDirectory
        let phone = MyFoodsStore(fileURL: dir.appendingPathComponent("foods-\(UUID().uuidString).json"))
        let mac = MyFoodsStore(fileURL: dir.appendingPathComponent("foods-\(UUID().uuidString).json"))
        phone.save(MyFood(name: "Pumpkin gnocchi", barcode: "0123", per100g: .init(calories: 160, proteinGrams: 4, carbohydrateGrams: 33, fatGrams: 1),
                          servingLabel: "1 cup", servingGrams: 140, packageGrams: 500, source: .barcode, addedAt: t0,
                          standsFor: ["gnocchi"], bought: [t0]))
        var applied = 0
        mac.afterCloudApply = { applied += 1 }
        try roundTrip("food.myFood", from: HealthFood.ControlSourceAdapter(source: phone, kinds: [FoodKinds.myFood]),
                      to: HealthFood.ControlSourceAdapter(source: mac, kinds: [FoodKinds.myFood]))
        XCTAssertEqual(mac.foods.map(\.name), ["Pumpkin gnocchi"])
        XCTAssertEqual(applied, 1, "one batch")
    }

    func testMealPhotosRoundTripAsTheirBlob() throws {
        let dir = FileManager.default.temporaryDirectory
        let phone = MealPhotoStore(directory: dir.appendingPathComponent("photos-\(UUID().uuidString)"))
        let mac = MealPhotoStore(directory: dir.appendingPathComponent("photos-\(UUID().uuidString)"))
        let id = UUID()
        let jpeg = Data((0..<4_000).map { UInt8($0 % 251) })
        phone.save(jpeg, id: id)
        let a = MealPhotoAdapter(photos: phone, hashes: hashes), b = MealPhotoAdapter(photos: mac, hashes: hashes)
        let sent = try roundTrip(MealPhotoAdapter.type, from: a, to: b, blobs: ["v"])
        XCTAssertEqual(sent[id.uuidString]?["v"]?.blobReference?.sha256, HealthFood.BlobHashes.sha256(of: jpeg))
        XCTAssertEqual(mac.data(id), jpeg)
        b.remove(MealPhotoAdapter.type, ids: [id.uuidString])
        XCTAssertFalse(mac.has(id))
    }

    func testKeyedValuesRoundTripOneRecordPerKey() throws {
        let picks = FakeKeyed<[String: Int]>(), picksMac = FakeKeyed<[String: Int]>()
        picks.values = ["tj carrots": ["fndds:1": 3, "off:2": 1], "oats": ["fndds:9": 1]]
        let a = HealthFood.KeyedValuesAdapter(type: "food.searchPick", port: picks, whole: false)
        let sent = try roundTrip("food.searchPick", from: a,
                                 to: HealthFood.KeyedValuesAdapter(type: "food.searchPick", port: picksMac, whole: false))
        XCTAssertEqual(sent["tj carrots"]?["fndds:1"], .int(3), "each food is a field")
        XCTAssertEqual(picksMac.values, picks.values)
        XCTAssertNil(a.defaultEncoding("food.searchPick"), "no default item: every field differs (§3 seeding rule 5)")

        let status = FakeKeyed<MealEstimatorStatus>(), statusMac = FakeKeyed<MealEstimatorStatus>()
        status.values = ["install-1": MealEstimatorStatus(device: "Mac", canReadPhotos: true, canReadText: true, onPower: true, at: t0)]
        let sentStatus = try roundTrip("food.estimatorStatus", from: HealthFood.KeyedValuesAdapter(type: "food.estimatorStatus", port: status, whole: true),
                                       to: HealthFood.KeyedValuesAdapter(type: "food.estimatorStatus", port: statusMac, whole: true))
        XCTAssertEqual(sentStatus["install-1"].map { Set($0.keys) }, ["v"], "whole: one field")
        XCTAssertEqual(statusMac.values, status.values)

        let report = FakeKeyed<MealPhotoScanReport>(), reportMac = FakeKeyed<MealPhotoScanReport>()
        report.values = ["install-2": MealPhotoScanReport(access: nil, checkedAt: t0, found: 4, remaining: 0, device: "iPhone")]
        try roundTrip("food.photoScanReport", from: HealthFood.KeyedValuesAdapter(type: "food.photoScanReport", port: report, whole: true),
                      to: HealthFood.KeyedValuesAdapter(type: "food.photoScanReport", port: reportMac, whole: true))
        XCTAssertEqual(reportMac.values, report.values)
    }

    func testWorkoutsRoundTripWithTheirRecording() throws {
        let phone = FakeWorkouts(), mac = FakeWorkouts()
        let workout = try summary(start: t0)
        phone.record(workout, samples: Data(repeating: 7, count: 10_000))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)")
        let a = WorkoutAdapter(port: phone, isHub: true, directory: dir.appendingPathComponent("a"), hashes: hashes)
        let b = WorkoutAdapter(port: mac, isHub: false, directory: dir.appendingPathComponent("b"), hashes: hashes)
        let sent = try roundTrip(WorkoutAdapter.type, from: a, to: b, blobs: ["samples"])
        XCTAssertEqual(sent[workout.id.uuidString]?["samples"]?.blobReference?.size, 10_000)
        XCTAssertEqual(mac.summaries, [workout])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(mac.samplesFile(workout.id))), Data(repeating: 7, count: 10_000))
    }

    func testAWorkoutWithoutItsRecordingHereStillNamesIt() throws {
        let phone = FakeWorkouts(), mac = FakeWorkouts()
        let workout = try summary(start: t0)
        phone.record(workout, samples: Data(repeating: 1, count: 500))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)")
        let a = WorkoutAdapter(port: phone, isHub: true, directory: dir.appendingPathComponent("a"), hashes: hashes)
        let b = WorkoutAdapter(port: mac, isHub: false, directory: dir.appendingPathComponent("b"), hashes: hashes)
        let sent = try roundTrip(WorkoutAdapter.type, from: a, to: b)   // no blob fetched: lazy
        XCTAssertNil(mac.samplesFile(workout.id))
        // A spoke that never fetched the recording encodes the reference it last saw, never null:
        // it can't clear the recording for everyone.
        let again = WorkoutAdapter(port: mac, isHub: false, directory: dir.appendingPathComponent("b"), hashes: hashes)
        XCTAssertEqual(try encoded(again.snapshot(WorkoutAdapter.type))[workout.id.uuidString]?["samples"],
                       sent[workout.id.uuidString]?["samples"], "kept across launches")
    }

    func testTheHealthSnapshotGoesToASpokeWhole() throws {
        let phone = FakeSnapshot(), mac = FakeSnapshot()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)")
        let hub = HealthSnapshotAdapter(port: phone, isHub: true, directory: dir.appendingPathComponent("a"),
                                        defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spoke = HealthSnapshotAdapter(port: mac, isHub: false, directory: dir.appendingPathComponent("b"),
                                          defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sent = try encoded(hub.snapshot(HealthSnapshotAdapter.type))
        let reference = try XCTUnwrap(sent[HealthSnapshotAdapter.id]?["v"]?.blobReference)
        XCTAssertEqual(reference.sha256, HealthFood.BlobHashes.sha256(of: phone.packed))
        XCTAssertEqual(spoke.apply(HealthSnapshotAdapter.type, records: [(HealthSnapshotAdapter.id, sent[HealthSnapshotAdapter.id]!)]),
                       [HealthSnapshotAdapter.id: true])
        let file = try XCTUnwrap(hub.blobFile(HealthSnapshotAdapter.type, id: HealthSnapshotAdapter.id, field: "v"))
        spoke.storeBlob(HealthSnapshotAdapter.type, id: HealthSnapshotAdapter.id, field: "v", file: file)
        XCTAssertEqual(mac.adopted, [phone.packed], "adopted whole")
        XCTAssertTrue(spoke.snapshot(HealthSnapshotAdapter.type).isEmpty, "a spoke has no snapshot of its own to send")
    }

    func testRequestsRoundTrip() throws {
        let removal = HealthRemovalRequest(target: .pairedWith(start: t0), askedAt: t0)
        let mac = FakeRequests<HealthRemovalRequest> { $0.askedAt }, phone = FakeRequests<HealthRemovalRequest> { $0.askedAt }
        mac.requests = [removal]
        try roundTrip("health.removalRequest", from: HealthRequestsAdapter(type: "health.removalRequest", port: mac),
                      to: HealthRequestsAdapter(type: "health.removalRequest", port: phone))
        XCTAssertEqual(phone.requests, [removal])

        let revert = WorkoutRevertRequest(sessionID: UUID(), editedAt: t0, askedAt: t0.addingTimeInterval(60))
        let ipad = FakeRequests<WorkoutRevertRequest> { $0.askedAt }, other = FakeRequests<WorkoutRevertRequest> { $0.askedAt }
        ipad.requests = [revert]
        try roundTrip("health.workoutRevert", from: HealthRequestsAdapter(type: "health.workoutRevert", port: ipad),
                      to: HealthRequestsAdapter(type: "health.workoutRevert", port: other))
        XCTAssertEqual(other.requests, [revert])
    }

    // MARK: - Seed clocks (§3 seeding rule 3)

    func testSeedsAtEachItemsOwnTime() async throws {
        let wellness = FakeWellness()
        let edited = meal("Edited", at: t0), unknown = meal("Logged", at: t0.addingTimeInterval(120))
        wellness.meals = [edited, unknown]
        wellness.edited[WellnessCloudRecord.meal(edited.id).name] = t0.addingTimeInterval(900)
        let source = FakeControlSource()
        let done = WorkoutCompletion(planID: UUID(), startedAt: t0, endedAt: t0.addingTimeInterval(600))
        source.items[.workoutCompletion] = [done.id.uuidString: try JSONEncoder().encode(done)]
        let workouts = FakeWorkouts()
        let workout = try summary(start: t0.addingTimeInterval(-3_600))
        workouts.record(workout, samples: Data([1, 2, 3]))
        let removals = FakeRequests<HealthRemovalRequest> { $0.askedAt }
        let request = HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: t0.addingTimeInterval(42))
        removals.requests = [request]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)")
        let phone = try await engine("phone", hub: true, [
            WellnessAdapter(port: wellness),
            HealthFood.ControlSourceAdapter(source: source, kinds: FoodKinds.wellnessControls,
                                            editedAt: { _, _ in nil }),
            WorkoutAdapter(port: workouts, isHub: true, directory: dir, hashes: hashes),
            HealthRequestsAdapter(type: "health.removalRequest", port: removals),
        ])
        await phone.seed(types: [WellnessSpace.meal, "health.workoutCompletion", WorkoutAdapter.type, "health.removalRequest"])

        func clock(_ type: String, _ id: String, _ field: String) -> Int64? {
            server.record(type, id)?.clocks[field].flatMap(HLC.init)?.ms
        }
        XCTAssertEqual(clock(WellnessSpace.meal, edited.id.uuidString, "name"), HLCClock.ms(t0.addingTimeInterval(900)),
                       "the legacy sync's edit time")
        XCTAssertEqual(clock(WellnessSpace.meal, unknown.id.uuidString, "name"), HLCClock.ms(unknown.date),
                       "no edit time known: the meal's own")
        XCTAssertEqual(clock("health.workoutCompletion", done.id.uuidString, "planID"), HLCClock.ms(done.endedAt))
        XCTAssertEqual(clock(WorkoutAdapter.type, workout.id.uuidString, "start"), HLCClock.ms(workout.end!))
        XCTAssertEqual(clock(WorkoutAdapter.type, workout.id.uuidString, "samples"), HLCClock.ms(workout.end!))
        XCTAssertEqual(clock("health.removalRequest", request.id.uuidString, "request"), HLCClock.ms(request.askedAt))
    }

    // MARK: - Between two devices

    func testAMealLoggedOnThePhoneAppearsOnTheMac() async throws {
        let phoneStore = FakeWellness(), macStore = FakeWellness()
        let phone = try await engine("phone", hub: true, [WellnessAdapter(port: phoneStore)])
        let mac = try await engine("mac", hub: false, [WellnessAdapter(port: macStore)])
        phoneStore.reports = .engine(phone)
        macStore.reports = .engine(mac)
        await phone.seed(types: WellnessSpace.types)
        await mac.seed(types: WellnessSpace.types)

        let oats = meal("Oats", at: t0)
        phoneStore.addMeal(oats)
        await phone.syncNow(reason: "test")
        await mac.syncNow(reason: "test")
        XCTAssertEqual(macStore.meals, [oats])

        var renamed = oats
        renamed.name = "Overnight oats"
        macStore.meals = [renamed]
        mac.changed(type: WellnessSpace.meal, ids: [oats.id.uuidString])
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")
        XCTAssertEqual(phoneStore.meals.first?.name, "Overnight oats", "an edit on the Mac comes back, field by field")
        XCTAssertEqual(server.record(WellnessSpace.meal, oats.id.uuidString)?.clocks["name"].flatMap(HLC.init)?.device, "mac")
        XCTAssertEqual(server.record(WellnessSpace.meal, oats.id.uuidString)?.clocks["items"].flatMap(HLC.init)?.device, "phone",
                       "only the changed field was sent")
    }

    func testDeletingASupplementSendsItsDosesDeletesAndReceiversDontInferThem() async throws {
        let phoneStore = FakeWellness(), macStore = FakeWellness()
        let phone = try await engine("phone", hub: true, [WellnessAdapter(port: phoneStore)])
        let mac = try await engine("mac", hub: false, [WellnessAdapter(port: macStore)])
        phoneStore.reports = .engine(phone)
        await phone.seed(types: WellnessSpace.types)
        await mac.seed(types: WellnessSpace.types)
        let magnesium = SupplementSchedule(name: "Magnesium", dose: "200 mg", hour: 21)
        phoneStore.upsertSupplement(magnesium)
        phoneStore.logDose(magnesium.id, day: "20251008", at: t0.addingTimeInterval(-86_400))
        phoneStore.logDose(magnesium.id, day: "20251009", at: t0)
        await phone.syncNow(reason: "test")
        await mac.syncNow(reason: "test")
        XCTAssertEqual(macStore.supplementLogs.count, 2)

        phoneStore.deleteSupplement(magnesium.id)
        await phone.syncNow(reason: "test")
        let doseIDs = ["\(magnesium.id.uuidString)-20251008", "\(magnesium.id.uuidString)-20251009"]
        for id in doseIDs { XCTAssertNotNil(server.record(WellnessSpace.dose, id)?.deleted, "the deleting device sent each dose's delete") }
        await mac.syncNow(reason: "test")
        XCTAssertTrue(macStore.supplements.isEmpty)
        XCTAssertTrue(macStore.supplementLogs.isEmpty, "by their own tombstones")

        // A supplement removed alone (another device's delete arriving first) leaves its doses:
        // they go only by their own deletes.
        let other = FakeWellness()
        other.supplements = [magnesium]
        other.supplementLogs = [SupplementLog(supplementID: magnesium.id, date: t0, status: .taken, day: "20251009")]
        WellnessAdapter(port: other).remove(WellnessSpace.supplement, ids: [magnesium.id.uuidString])
        XCTAssertTrue(other.supplements.isEmpty)
        XCTAssertEqual(other.supplementLogs.count, 1, "no cascade inferred")
    }

    func testMealsBeyondTheFormerCapRemainAvailableAcrossDevices() async throws {
        let phoneStore = FakeWellness()
        phoneStore.meals = (0..<1_500).map { meal("Meal \($0)", at: t0.addingTimeInterval(Double(-$0) * 3_600)) }
        let oldest = phoneStore.meals.last!
        let phone = try await engine("phone", hub: true, [WellnessAdapter(port: phoneStore)])
        phoneStore.reports = .engine(phone)
        await phone.seed(types: WellnessSpace.types)
        XCTAssertEqual(server.visible(type: WellnessSpace.meal).count, 1_500)

        phoneStore.addMeal(meal("Meal 1500", at: t0.addingTimeInterval(3_600)))
        XCTAssertEqual(phoneStore.meals.count, 1_501)
        XCTAssertTrue(phoneStore.meals.contains { $0.id == oldest.id }, "older meals remain available to repeat")
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.visible(type: WellnessSpace.meal).count, 1_501, "the space retains the complete history")
        XCTAssertNil(server.record(WellnessSpace.meal, oldest.id.uuidString)?.deleted, "no tombstone for a cap")

        // A receiving device also keeps all 1,501 meals.
        let macStore = FakeWellness()
        let mac = try await engine("mac", hub: false, [WellnessAdapter(port: macStore)])
        macStore.reports = .engine(mac)
        await mac.seed(types: WellnessSpace.types)
        XCTAssertEqual(macStore.meals.count, 1_501)
        XCTAssertTrue(macStore.meals.contains { $0.id == oldest.id }, "the oldest meal is available on the other device")
        await mac.syncNow(reason: "test")
        XCTAssertFalse(server.requests.contains { $0.device == "mac" && $0.changes.contains { $0.delete != nil } })
    }

    func testOnlyTheHubPublishesTheHealthSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)")
        let phonePort = FakeSnapshot(), macPort = FakeSnapshot()
        let hubAdapter = HealthSnapshotAdapter(port: phonePort, isHub: true, directory: dir.appendingPathComponent("a"),
                                               defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spokeAdapter = HealthSnapshotAdapter(port: macPort, isHub: false, directory: dir.appendingPathComponent("b"),
                                                 defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let phone = try await engine("phone", hub: true, [hubAdapter])
        let mac = try await engine("mac", hub: false, [spokeAdapter])
        spokeAdapter.reports = .engine(mac)
        await phone.seed(types: [HealthSnapshotAdapter.type])
        await mac.seed(types: [HealthSnapshotAdapter.type])
        await mac.blobsSettled()
        XCTAssertEqual(macPort.adopted, [phonePort.packed], "eager on the spoke")

        spokeAdapter.snapshotChanged(urgent: true)   // a hide on the Mac: never its snapshot to send
        mac.changed(type: HealthSnapshotAdapter.type, ids: [HealthSnapshotAdapter.id])
        await mac.syncNow(reason: "test")
        XCTAssertFalse(server.requests.contains { $0.device == "mac" && $0.changes.contains { $0.type == HealthSnapshotAdapter.type } })
        XCTAssertEqual(server.record(HealthSnapshotAdapter.type, HealthSnapshotAdapter.id)?.clocks["v"].flatMap(HLC.init)?.device, "phone")
    }

    func testASnapshotBlobIsFoundByItsOwnHash() {
        let files = SnapshotFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("snapfiles-\(UUID().uuidString)"))
        let first = files.write(Data("one".utf8)), second = files.write(Data("two".utf8))
        let a = try? XCTUnwrap(first), b = try? XCTUnwrap(second)
        XCTAssertNotNil(files.file(sha: a?.sha256 ?? ""), "the one before the latest is kept (an upload may be reading it)")
        XCTAssertNotNil(files.file(sha: b?.sha256 ?? ""))
        XCTAssertEqual(files.file(sha: b?.sha256 ?? ""), files.latest)
        XCTAssertNil(files.file(sha: String(repeating: "0", count: 64)), "no file for bytes it never wrote")
        _ = files.write(Data("three".utf8))
        XCTAssertNil(files.file(sha: a?.sha256 ?? ""), "older ones go")
    }

    func testTheSnapshotGoesUpAtMostHourlyAndAtOnceForARemoval() throws {
        var now = t0
        var scheduled: [(Date, @MainActor () -> Void)] = []
        var published = 0
        let adapter = HealthSnapshotAdapter(
            port: FakeSnapshot(), isHub: true, directory: FileManager.default.temporaryDirectory.appendingPathComponent("pace-\(UUID().uuidString)"),
            reports: HealthFood.Reports(changed: { _, _ in published += 1 }, deleted: { _, _ in }, offered: { _, _ in }),
            defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { now }, schedule: { scheduled.append(($0, $1)) })
        adapter.snapshotChanged(urgent: false)
        XCTAssertEqual(published, 1, "the first change goes at once")
        now = t0.addingTimeInterval(60)
        adapter.snapshotChanged(urgent: false)
        adapter.snapshotChanged(urgent: false)
        XCTAssertEqual(published, 1, "then not within the hour")
        XCTAssertEqual(scheduled.count, 1, "one wait, however many changes")
        XCTAssertEqual(scheduled.first?.0, t0.addingTimeInterval(SnapshotPace.interval))
        now = t0.addingTimeInterval(120)
        adapter.snapshotChanged(urgent: true)
        XCTAssertEqual(published, 2, "a workout removed or hidden goes at once")
        now = t0.addingTimeInterval(SnapshotPace.interval + 1)
        scheduled.removeFirst().1()
        XCTAssertEqual(published, 2, "the wait finds nothing due: the urgent publish took it")
        now = t0.addingTimeInterval(SnapshotPace.interval + 100)
        adapter.snapshotChanged(urgent: false)
        XCTAssertEqual(published, 2)
        now = t0.addingTimeInterval(120 + SnapshotPace.interval)
        scheduled.removeFirst().1()
        XCTAssertEqual(published, 3, "the waiting change goes when its hour is over")
    }

    func testARemovalRequestIsTheAskersAndItsOutcomeIsTheHubs() async throws {
        let macPort = FakeRequests<HealthRemovalRequest> { $0.askedAt }, phonePort = FakeRequests<HealthRemovalRequest> { $0.askedAt }
        let type = "health.removalRequest"
        let phone = try await engine("phone", hub: true, [HealthRequestsAdapter(type: type, port: phonePort)])
        let mac = try await engine("mac", hub: false, [HealthRequestsAdapter(type: type, port: macPort)])
        phonePort.carry = { request in
            // Carried out after the record is in, as `HealthRemovalInbox.settle` does.
            Task { @MainActor in
                phonePort.outcomes[request.id] = "handled"
                phone.changed(type: type, ids: [request.id.uuidString])
            }
        }
        await phone.seed(types: [type])
        await mac.seed(types: [type])

        let request = HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: t0)
        macPort.requests.append(request)
        mac.changed(type: type, ids: [request.id.uuidString])
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")   // takes it, carries it out
        try await Task.sleep(for: .milliseconds(50))
        await phone.syncNow(reason: "test")   // sends the outcome
        await mac.syncNow(reason: "test")

        let record = try XCTUnwrap(server.record(type, request.id.uuidString))
        XCTAssertEqual(record.fields["outcome"], .string("handled"))
        XCTAssertEqual(record.clocks["request"].flatMap(HLC.init)?.device, "mac", "the asker wrote the request")
        XCTAssertEqual(record.clocks["outcome"].flatMap(HLC.init)?.device, "phone", "the hub wrote the outcome")
        let phoneSent = server.requests.filter { $0.device == "phone" }.flatMap(\.changes).filter { $0.id == request.id.uuidString }
        XCTAssertEqual(Set(phoneSent.flatMap(\.set.keys)), ["outcome"], "the hub never wrote the asker's half")
        let macSent = server.requests.filter { $0.device == "mac" }.flatMap(\.changes).filter { $0.id == request.id.uuidString }
        XCTAssertEqual(Set(macSent.flatMap(\.set.keys)), ["request"])
    }

    func testAWorkoutWithItsRecordingRoundTripsAndTheSpokeFetchesItWhenNeeded() async throws {
        let phoneStore = FakeWorkouts(), macStore = FakeWorkouts()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wk-\(UUID().uuidString)")
        let phoneAdapter = WorkoutAdapter(port: phoneStore, isHub: true, directory: dir.appendingPathComponent("a"), hashes: hashes)
        let macAdapter = WorkoutAdapter(port: macStore, isHub: false, directory: dir.appendingPathComponent("b"), hashes: hashes)
        let phone = try await engine("phone", hub: true, [phoneAdapter])
        let mac = try await engine("mac", hub: false, [macAdapter])
        macAdapter.hooks = .engine(mac)
        phoneStore.reports = .engine(phone)
        await phone.seed(types: [WorkoutAdapter.type])
        await mac.seed(types: [WorkoutAdapter.type])

        let recording = Data((0..<50_000).map { UInt8($0 % 233) })
        let workout = try summary(start: t0, samples: 1_000)
        phoneStore.record(workout, samples: recording)
        await phone.syncNow(reason: "test")
        XCTAssertEqual(server.blobPuts, [HealthFood.BlobHashes.sha256(of: recording)], "the recording went up first")
        await mac.syncNow(reason: "test")
        await mac.blobsSettled()
        XCTAssertEqual(macStore.summaries, [workout])
        XCTAssertNil(macStore.samplesFile(workout.id), "lazy: not fetched until needed")

        let fetched = await mac.ensureBlob(type: WorkoutAdapter.type, id: workout.id.uuidString, field: WorkoutAdapter.samples)
        XCTAssertTrue(fetched)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(macStore.samplesFile(workout.id))), recording)
    }

    func testAnEditWithANewRecordingIsTakenWithIt() async throws {
        let phoneStore = FakeWorkouts(), macStore = FakeWorkouts()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString)")
        let phoneAdapter = WorkoutAdapter(port: phoneStore, isHub: true, directory: dir.appendingPathComponent("a"), hashes: hashes)
        let macAdapter = WorkoutAdapter(port: macStore, isHub: false, directory: dir.appendingPathComponent("b"), hashes: hashes)
        let phone = try await engine("phone", hub: true, [phoneAdapter])
        let mac = try await engine("mac", hub: false, [macAdapter])
        phoneAdapter.hooks = .engine(phone)
        macStore.reports = .engine(mac)
        await phone.seed(types: [WorkoutAdapter.type])
        await mac.seed(types: [WorkoutAdapter.type])
        let workout = try summary(start: t0, samples: 100)
        phoneStore.summaries = [workout]
        try Data(repeating: 1, count: 1_000).write(to: phoneStore.url(workout.id))
        macStore.summaries = [workout]
        try Data(repeating: 1, count: 1_000).write(to: macStore.url(workout.id))

        // Trimmed on the Mac: a shorter recording.
        var trimmed = try summary(workout.id, start: t0.addingTimeInterval(60), samples: 80)
        trimmed.edit = SessionEdit(original: workout, at: t0.addingTimeInterval(7_200))
        macStore.summaries = [trimmed]
        try Data(repeating: 2, count: 800).write(to: macStore.url(workout.id))
        mac.changed(type: WorkoutAdapter.type, ids: [workout.id.uuidString])
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")
        let deadline = Date().addingTimeInterval(5)
        while phoneStore.summaries.first?.sampleCount != 80, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(phoneStore.summaries.first?.sampleCount, 80, "the phone took the edit")
        XCTAssertEqual(try Data(contentsOf: phoneStore.url(workout.id)), Data(repeating: 2, count: 800), "with its recording")
    }

    func testAnEditThatKeepsTheRecordingIsTakenAtOnce() async throws {
        let phoneStore = FakeWorkouts(), macStore = FakeWorkouts()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)")
        let phoneAdapter = WorkoutAdapter(port: phoneStore, isHub: true, directory: dir.appendingPathComponent("a"), hashes: hashes)
        let macAdapter = WorkoutAdapter(port: macStore, isHub: false, directory: dir.appendingPathComponent("b"),
                                        hashes: HealthFood.BlobHashes(file: nil))
        let workout = try summary(start: t0, samples: 100)
        phoneStore.summaries = [workout]
        try Data(repeating: 3, count: 2_000).write(to: phoneStore.url(workout.id))
        let phone = try await engine("phone", hub: true, [phoneAdapter])
        let mac = try await engine("mac", hub: false, [macAdapter])
        phoneAdapter.hooks = .engine(phone)
        macAdapter.hooks = .engine(mac)
        await phone.seed(types: [WorkoutAdapter.type])
        await mac.seed(types: [WorkoutAdapter.type])
        let fetched = await mac.ensureBlob(type: WorkoutAdapter.type, id: workout.id.uuidString, field: WorkoutAdapter.samples)
        XCTAssertTrue(fetched)

        // The pool length corrected on the Mac: an edit, the same recording.
        var corrected = workout
        corrected.poolLengthMeters = 25
        macStore.summaries = [corrected]
        mac.changed(type: WorkoutAdapter.type, ids: [workout.id.uuidString])
        await mac.syncNow(reason: "test")
        await phone.syncNow(reason: "test")
        XCTAssertEqual(phoneStore.summaries, [corrected], "taken at once: nothing to wait for")
        XCTAssertEqual(try Data(contentsOf: phoneStore.url(workout.id)), Data(repeating: 3, count: 2_000))
    }

    func testWithdrawingTheConsentDropsHealthRowsAndKeepsTheStores() async throws {
        let store = FakeWellness()
        store.meals = [meal("Oats", at: t0)]
        let mirror = try RecordMirror()
        var config = SpaceSync.Configuration(device: "phone", isHub: true, catalog: catalog)
        config.debounce = .seconds(3_600)
        let phone = try SpaceSync(mirror: mirror, transport: MemoryTransport(server: server, device: "phone"), config: config)
        await phone.registerAdapter(WellnessAdapter(port: store))
        await phone.setHealthConsent(true)
        await phone.seed(types: WellnessSpace.types)
        XCTAssertEqual(server.visible(type: WellnessSpace.meal).count, 1)
        XCTAssertEqual(try mirror.read { try $0.ids(type: WellnessSpace.meal) }.count, 1)

        server.consent = false
        await phone.setHealthConsent(false)
        await phone.consentWithdrawalConfirmed()
        XCTAssertTrue(try mirror.read { try $0.ids(type: WellnessSpace.meal) }.isEmpty, "T2 rows leave the mirror")
        XCTAssertEqual(store.meals.count, 1, "the store keeps its data")
        store.addMeal(meal("Soup", at: t0.addingTimeInterval(60)))
        phone.changed(type: WellnessSpace.meal, ids: [store.meals[0].id.uuidString])
        let before = server.requests.count
        await phone.syncNow(reason: "test")
        XCTAssertFalse(server.requests.dropFirst(before).contains { $0.changes.contains { $0.type == WellnessSpace.meal } },
                       "nothing health leaves the device")
    }

    // MARK: - The move (`MoveOver`): deletes made before the update

    func testADeleteMadeBeforeTheUpdateIsNotBroughtBack() async throws {
        let store = FakeWellness()
        let kept = meal("Oats", at: t0), deletedOnMac = meal("Deleted on the Mac", at: t0.addingTimeInterval(60))
        store.meals = [kept, deletedOnMac]
        let adapter = WellnessAdapter(port: store)
        let defaults = UserDefaults(suiteName: "hf-move-\(UUID().uuidString)")!
        let modes = LegacyCloudModeStore(defaults: defaults, account: "acc", enabled: true)
        let channel = FakeLegacyChannel("wellness", tier: .health, types: LegacyInventory.wellness, modes: modes, events: logs)
        channel.result.absent = [WellnessSpace.meal: [deletedOnMac.id.uuidString]]
        var config = SpaceSync.Configuration(device: "phone", isHub: true, catalog: catalog)
        config.debounce = .seconds(3_600)
        let engine = try SpaceSync(mirror: RecordMirror(), transport: MemoryTransport(server: server, device: "phone"), config: config)
        await engine.registerAdapter(adapter)
        await engine.setHealthConsent(true)
        let move = MoveOver(MoveOver.Dependencies(
            engine: engine, isHub: true, channels: [channel], adapters: [adapter], modes: modes,
            account: { _ in MoveOver.Account(hasIPhone: true, seeded: [], allFlipped: false, icloud: "keep") },
            defaults: defaults, stateKey: MoveOver.stateKey(account: "acc")))
        await move.start(listening: false)
        XCTAssertEqual(store.meals, [kept], "out of the store through its own delete path")
        XCTAssertEqual(Set(server.visible(type: WellnessSpace.meal).keys), [kept.id.uuidString])
        XCTAssertNil(server.record(WellnessSpace.meal, deletedOnMac.id.uuidString), "not seeded, and no tombstone")
        XCTAssertEqual(move.state.health.phase, .flipped)
    }

    // MARK: - Review fixes

    func testWorkoutsFromTheSpaceGoIntoAnOpenICloudBatch() throws {
        let a = try summary(start: t0), b = try summary(start: t0.addingTimeInterval(3_600))
        var summaries = [a]
        var working: [FitnessSessionSummary]? = [a]
        XCTAssertTrue(FitnessSpaceChanges.apply({ FitnessSpaceChanges.adopting([b], into: $0) },
                                                summaries: &summaries, working: &working, batchOpen: true))
        XCTAssertEqual(summaries, [a], "the list waits for the batch to publish")
        XCTAssertEqual(working, [b, a], "the batch's working copy has it, newest first")
        XCTAssertTrue(FitnessSpaceChanges.apply({ $0.filter { $0.id != a.id } }, summaries: &summaries, working: &working, batchOpen: true))
        XCTAssertEqual(working, [b])
        var none: [FitnessSessionSummary]?
        XCTAssertTrue(FitnessSpaceChanges.apply({ FitnessSpaceChanges.adopting([b], into: $0) },
                                                summaries: &summaries, working: &none, batchOpen: false))
        XCTAssertEqual(summaries, [b, a])
        XCTAssertNil(none)
        XCTAssertFalse(FitnessSpaceChanges.apply({ $0 }, summaries: &summaries, working: &none, batchOpen: false), "no change, no save")
    }

    func testDosesOfASupplementNotHereAreNotSent() throws {
        let store = FakeWellness()
        let kept = SupplementSchedule(name: "Iron")
        store.supplements = [kept]
        store.supplementLogs = [SupplementLog(supplementID: kept.id, date: t0, status: .taken, day: "20251009"),
                                SupplementLog(supplementID: UUID(), date: t0, status: .taken, day: "20251009")]
        let doses = WellnessAdapter(port: store).snapshot(WellnessSpace.dose)
        XCTAssertEqual(Array(doses.keys), ["\(kept.id.uuidString)-20251009"])
    }

    func testARequestThatAlreadyHasAnOutcomeIsNotCarriedOutAgain() throws {
        let phone = FakeRequests<HealthRemovalRequest> { $0.askedAt }
        var carried: [UUID] = []
        phone.carry = { carried.append($0.id) }
        let adapter = HealthRequestsAdapter(type: "health.removalRequest", port: phone)
        let done = HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: t0)
        let open = HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: t0)
        let fields = { (r: HealthRemovalRequest, outcome: Bool) -> [String: JSONValue] in
            var f: [String: JSONValue] = ["request": try! CanonicalJSON.value(of: r)]
            if outcome { f["outcome"] = .string("handled") }
            return f
        }
        _ = adapter.apply("health.removalRequest", records: [(done.id.uuidString, fields(done, true)), (open.id.uuidString, fields(open, false))])
        XCTAssertEqual(carried, [open.id], "a restored phone doesn't remove a workout twice")
    }

    func testThePhoneFetchesEveryRecordingInTheEndOneAtATime() async throws {
        let store = FakeWorkouts()
        let workout = try summary(start: t0)
        store.summaries = [workout]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("want-\(UUID().uuidString)")
        let recording = Data(repeating: 9, count: 300)
        let calls = SpaceSyncTests.LogBox()
        let adapter = WorkoutAdapter(port: store, isHub: true, directory: dir, hashes: hashes)
        adapter.retryBase = 0.05
        adapter.hooks = HealthFood.EngineHooks(ensureBlob: { _, id, _ in
            calls.add(id)
            guard calls.all.count >= 3 else { return false }   // the network fails twice
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
            try? recording.write(to: file)
            await MainActor.run { _ = store.installSpaceSamples(workout.id, from: file) }
            return true
        }, replay: { _ in })
        var fields = try CanonicalJSON.fields(of: workout)
        fields["samples"] = BlobReference(sha256: HealthFood.BlobHashes.sha256(of: recording), size: 300, ext: "samples").value
        XCTAssertEqual(adapter.apply(WorkoutAdapter.type, records: [(workout.id.uuidString, fields)]), [workout.id.uuidString: true])
        XCTAssertEqual(adapter.wantedRecordings, [workout.id.uuidString], "kept until it's here")
        let deadline = Date().addingTimeInterval(5)
        while store.samplesFile(workout.id) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.samplesFile(workout.id))), recording)
        XCTAssertEqual(calls.all.count, 3, "tried again after each failure")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(adapter.wantedRecordings.isEmpty)
        let relaunched = WorkoutAdapter(port: store, isHub: true, directory: dir, hashes: hashes)
        XCTAssertTrue(relaunched.wantedRecordings.isEmpty, "the list is kept across launches")
    }

    func testAWaitingSnapshotPublishSurvivesARelaunch() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var now = t0
        var published = 0
        var scheduled: [(Date, @MainActor () -> Void)] = []
        let reports = HealthFood.Reports(changed: { _, _ in published += 1 }, deleted: { _, _ in }, offered: { _, _ in })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pace2-\(UUID().uuidString)")
        let first = HealthSnapshotAdapter(port: FakeSnapshot(), isHub: true, directory: dir, reports: reports, defaults: defaults,
                                          now: { now }, schedule: { scheduled.append(($0, $1)) })
        first.snapshotChanged(urgent: false)
        now = t0.addingTimeInterval(60)
        first.snapshotChanged(urgent: false)
        XCTAssertEqual(published, 1)
        scheduled = []
        // Quit, and back after the hour.
        now = t0.addingTimeInterval(SnapshotPace.interval + 300)
        let second = HealthSnapshotAdapter(port: FakeSnapshot(), isHub: true, directory: dir, reports: reports, defaults: defaults,
                                           now: { now }, schedule: { scheduled.append(($0, $1)) })
        XCTAssertEqual(scheduled.count, 1, "the waiting publish is scheduled again")
        XCTAssertEqual(scheduled.first?.0, now.addingTimeInterval(5))
        now = now.addingTimeInterval(5)
        scheduled.removeFirst().1()
        XCTAssertEqual(published, 2)
        XCTAssertNil(second.pace.due)
    }

    // MARK: - Performance (house rule)

    /// About 2,000 meals and 300 workouts with recordings, as a seed meets them: what the main
    /// actor does (the snapshot and every item's own time, `takeSeedSnapshot`), the encoding off
    /// it (with every recording hashed for the first time), the seed into the mirror (offline,
    /// so nothing is sent), then sending it all to the (in-memory) service.
    func testSeedingCostForAYearOfMealsAndWorkouts() async throws {
        let wellness = FakeWellness()
        wellness.meals = (0..<2_000).map { meal("Meal \($0)", at: t0.addingTimeInterval(Double(-$0) * 3_600)) }
        let workouts = FakeWorkouts()
        for n in 0..<300 {
            let workout = try summary(start: t0.addingTimeInterval(Double(-n) * 86_400), samples: 2_000)
            try Data(repeating: UInt8(n % 256), count: 64 * 1024).write(to: workouts.url(workout.id))
            workouts.summaries.append(workout)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        let mealsAdapter = WellnessAdapter(port: wellness)
        let workoutAdapter = WorkoutAdapter(port: workouts, isHub: true, directory: dir, hashes: HealthFood.BlobHashes(file: nil))

        let clock = ContinuousClock()
        var items: [String: any Encodable & Sendable] = [:]
        let mainActorTime = clock.measure {
            for (adapter, type) in [(mealsAdapter as any RecordAdapter, WellnessSpace.meal), (workoutAdapter, WorkoutAdapter.type)] {
                let snapshot = adapter.snapshot(type)
                for id in snapshot.keys { _ = adapter.seedClock(type, id: id) }
                items.merge(snapshot.map { ("\(type)/\($0.key)", $0.value) }) { a, _ in a }
            }
        }
        let all = items
        let encodeTime = await Task.detached {
            ContinuousClock().measure { for item in all.values { _ = try? CanonicalJSON.fields(of: item) } }
        }.value

        let engine = try await engine("phone", hub: true, [WellnessAdapter(port: wellness),
            WorkoutAdapter(port: workouts, isHub: true, directory: dir, hashes: HealthFood.BlobHashes(file: nil))])
        server.offline = ["phone"]
        let seedTime = await clock.measure { await engine.seed(types: [WellnessSpace.meal, WorkoutAdapter.type]) }
        server.offline = []
        let sendTime = await clock.measure { await engine.syncNow(reason: "test") }
        XCTAssertEqual(server.visible(type: WellnessSpace.meal).count, 2_000)
        XCTAssertEqual(server.visible(type: WorkoutAdapter.type).count, 300)
        print("PERF stage C: main actor \(mainActorTime) (snapshot + own times of 2,000 meals and 300 workouts); "
              + "encoding off it \(encodeTime) (300 × 64 KB recordings hashed, first time); "
              + "seed into the mirror \(seedTime) (cached hashes); send to the in-memory service \(sendTime) "
              + "(2,300 records, 300 blobs)")
        XCTAssertLessThan(mainActorTime, .milliseconds(250), "taking the snapshot is all the main actor does")
    }
}
