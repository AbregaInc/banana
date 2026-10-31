import Foundation

/// Per-task duration *estimates* — how long to reserve when the scheduler places a task.
/// Reminders has no duration field, so this is the one thing that lives app-side. It's only
/// an input: once a task is placed and written to the calendar, the calendar block's
/// start→end is the source of truth (this is not a second copy of the schedule).
/// Keyed by the reminder's identifier. Plain (non-isolated) so producers can read it.
final class TaskDurationStore {
    static let shared = TaskDurationStore()

    static let defaultMinutes = 30
    static let options = [15, 30, 45, 60, 90, 120]

    private var map: [String: Int] = [:]
    /// One task's estimate as every device has it, by the reminder's stable id (`plan.taskDuration`).
    struct SyncedDuration: Codable, Equatable {
        var minutes: Int
        var updatedAt: Date
    }
    private var synced: [String: SyncedDuration] = [:]
    private let lock = NSLock()
    private let cloud = LegacyKVS.shared
    private let cloudKey = "taskDurations.v1"
    private var cloudObserver: NSObjectProtocol?

    init() {
        load()
        mergeCloud()
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: LegacyKVS.ubiquitous,
            queue: nil
        ) { [weak self] _ in
            // Off (every device moved to the Banana service): nothing more comes in.
            guard LegacyCloud.mayRead(.personal) else { return }
            // Late arrivals for the data platform (§3 seeding rule 6), off the main thread.
            if let arrived = self?.mergeCloud(), !arrived.isEmpty { SyncReport.arrived(Self.syncType, arrived) }
        }
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `KeyValueAdapters`)

    static let syncType = "plan.taskDuration"

    /// Every task's estimate, by the reminder's stable id.
    var syncEntries: [String: SyncedDuration] {
        lock.lock(); defer { lock.unlock() }
        return synced
    }

    /// One task's estimate, without copying the rest.
    func syncEntry(_ id: String) -> SyncedDuration? {
        lock.lock(); defer { lock.unlock() }
        return synced[id]
    }

    /// Other devices' estimates (nil: removed there), kept the usual way.
    func applySynced(_ changes: [String: SyncedDuration?]) {
        lock.lock()
        for (id, value) in changes { synced[id] = value }
        lock.unlock()
        saveCloud()
    }

    func minutes(for reminderID: String, externalID: String? = nil) -> Int {
        var shouldPushCloud = false
        var shouldSaveLocal = false
        lock.lock()
        let value: Int
        if let local = map[reminderID] {
            value = local
            if let externalID, !externalID.isEmpty, synced[externalID] == nil {
                synced[externalID] = SyncedDuration(minutes: local, updatedAt: Date())
                shouldPushCloud = true
            }
        } else if let externalID, let remote = synced[externalID]?.minutes {
            value = remote
            map[reminderID] = remote
            shouldSaveLocal = true
        } else {
            value = Self.defaultMinutes
        }
        lock.unlock()
        if shouldSaveLocal { save() }
        if shouldPushCloud {
            saveCloud()
            if let externalID { SyncReport.changed(Self.syncType, [externalID]) }
        }
        return value
    }
    func isSet(_ reminderID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return map[reminderID] != nil
    }
    func set(_ reminderID: String, externalID: String? = nil, minutes: Int?) {
        lock.lock()
        if let minutes { map[reminderID] = minutes } else { map[reminderID] = nil }
        if let externalID, !externalID.isEmpty {
            if let minutes {
                synced[externalID] = SyncedDuration(minutes: minutes, updatedAt: Date())
            } else {
                synced[externalID] = nil
            }
        }
        lock.unlock()
        save()
        if let externalID, !externalID.isEmpty {
            saveCloud()
            if minutes == nil { SyncReport.deleted(Self.syncType, [externalID]) } else { SyncReport.changed(Self.syncType, [externalID]) }
        }
    }

    private var url: URL {
        let d = AppSupport.directory
        return d.appendingPathComponent("task-durations.json")
    }
    private func save() {
        lock.lock(); let snapshot = map; lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
    private func load() {
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        map = m
    }

    /// The ids it took.
    @discardableResult
    private func mergeCloud() -> [String] {
        guard let data = cloud.data(forKey: cloudKey),
              let incoming = try? JSONDecoder().decode([String: SyncedDuration].self, from: data)
        else { return [] }
        var taken: [String] = []
        lock.lock()
        for (id, record) in incoming where record.updatedAt > (synced[id]?.updatedAt ?? .distantPast) {
            synced[id] = record
            taken.append(id)
        }
        lock.unlock()
        return taken
    }

    private func saveCloud() {
        lock.lock(); let snapshot = synced; lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        cloud.set(data, forKey: cloudKey)
    }
}
