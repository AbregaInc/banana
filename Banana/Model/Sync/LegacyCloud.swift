import Foundation

/// What a legacy iCloud channel may do while the data moves to the service
/// (docs/design/DATA-PLATFORM.md §3 seeding rules 1 and 6, §8 steps 1–2).
///
/// With the data platform on (`SpaceSyncFlag`), every channel is `readOnly` from the first launch:
/// until an account is bound (§2), and from then on by the device's floor. It still fetches and
/// applies what other devices write; what this device does is kept for the seed (edits in the
/// stores, deletes held on the device). Only with `--no-space-sync` on an install that never moved
/// do personal channels stay `readWrite`, as before. Health always has a `readOnly` floor,
/// independent of the migration flag, because personal health data must not be stored in iCloud.
enum LegacyCloudMode: String, Codable, Sendable, CaseIterable {
    /// Fetch, apply, save, send and delete, exactly as today.
    case readWrite
    /// Fetch and apply what other devices (old builds) still write; never save, send or delete
    /// anything in iCloud. A flipped device's drain (§3 seeding rule 6).
    case readOnly
    /// Neither fetch nor write: every device has flipped, or 30 days have passed since the flip.
    case off

    var writes: Bool { self == .readWrite }
    var reads: Bool { self != .off }
}

/// Which data a channel carries, for when it may move: personal data (T1) as soon as its adapters
/// exist, health and food (T2) only with the Health consent (§7).
enum LegacyTier: String, Codable, Sendable, CaseIterable {
    case personal, health

    init(type: String) { self = LegacyInventory.isHealth(type) ? .health : .personal }
}

/// The mode of each tier.
struct LegacyCloudModes: Codable, Equatable, Sendable {
    var personal: LegacyCloudMode = .readWrite
    var health: LegacyCloudMode = .readWrite

    subscript(tier: LegacyTier) -> LegacyCloudMode {
        get { tier == .personal ? personal : health }
        set { if tier == .personal { personal = newValue } else { health = newValue } }
    }
}

/// What a channel's complete fetch left behind, per catalog type, with the ids the stores (and so
/// the adapters) know their items by (`LegacyInventory` says how each channel's record names map).
struct DrainResult: Sendable, Equatable {
    /// Edited here and not yet confirmed by iCloud. Informational: the seed reads the store as it
    /// is, so these are seeded as this device's edits anyway (§3 seeding rule 1).
    var dirty: [String: Set<String>] = [:]
    /// Deleted here and not yet confirmed by iCloud (the delete couldn't go up during the drain).
    /// After the seed, `MoveOver` deletes them in the space too, so another device's seed of the
    /// same item doesn't bring it back.
    var pendingDeletes: [String: Set<String>] = [:]
    /// Wellness and Fitness only: items this device has, that were synced once (they have a
    /// `revisions` entry), aren't dirty, and are no longer in the zone: deleted elsewhere while
    /// this device wasn't fetching. Dropped before the seed.
    var absent: [String: Set<String>] = [:]

    var isEmpty: Bool { dirty.isEmpty && pendingDeletes.isEmpty && absent.isEmpty }

    mutating func merge(_ other: DrainResult) {
        for (type, ids) in other.dirty where !ids.isEmpty { dirty[type, default: []].formUnion(ids) }
        for (type, ids) in other.pendingDeletes where !ids.isEmpty { pendingDeletes[type, default: []].formUnion(ids) }
        for (type, ids) in other.absent where !ids.isEmpty { absent[type, default: []].formUnion(ids) }
    }

    /// Just these types' part.
    func only(_ types: Set<String>) -> DrainResult {
        DrainResult(dirty: dirty.filter { types.contains($0.key) },
                    pendingDeletes: pendingDeletes.filter { types.contains($0.key) },
                    absent: absent.filter { types.contains($0.key) })
    }

    mutating func note(_ keyPath: WritableKeyPath<DrainResult, [String: Set<String>]>, type: String, id: String) {
        self[keyPath: keyPath][type, default: []].insert(id)
    }
}

/// One legacy way data reaches iCloud (DATA-INVENTORY.md): a CloudKit zone's engine, the
/// key-value store, iCloud Drive. A channel carries one tier; a zone with both kinds of data
/// (Controls, Fitness) is two channels over one engine.
@MainActor protocol LegacyChannel: AnyObject {
    /// For logs.
    var name: String { get }
    var tier: LegacyTier { get }
    /// The catalog types this channel's items become.
    var types: Set<String> { get }
    /// The tier's mode changed (`LegacyCloud.set`): stop or start whatever writes or fetches.
    /// The channel reads the mode itself wherever it writes (`LegacyCloud.mode`); this is the moment
    /// to reconfigure an engine or drop what was queued.
    func setMode(_ mode: LegacyCloudMode)
    /// One complete fetch of everything the channel holds, applied to the stores. In `readWrite`
    /// it first sends what waits, so a delete made here reaches the other devices' drains. Throws
    /// when it couldn't read to the end (offline, the app went to the background): the move waits.
    func drainToEnd() async throws -> DrainResult
    /// `MoveOver` has kept what the last drain returned (it's in the move's own state): what the
    /// channel held only for the drain (deletes it couldn't send, `HeldDeletes`) can go.
    func drainKept()
}

extension LegacyChannel {
    func drainKept() {}
}

/// Deletes made here that a channel can't send any more (its tier no longer writes iCloud) or
/// dropped from its engine's queue: kept on the device, not in memory, until a drain has handed
/// them to the move (`DrainResult.pendingDeletes`) and the move has kept them. Record names.
///
/// Once a tier's drain is kept, the tier is drained for good: deletes of it come to the move
/// directly from then on (`MoveOver.hold`), and nothing more is held here for it.
final class HeldDeletes: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private let tierOf: @Sendable (String) -> LegacyTier
    /// What the last drain returned, so only those go when it's kept.
    private var handedOver: Set<String> = []

    init(key: String, defaults: UserDefaults = .standard, tierOf: @escaping @Sendable (String) -> LegacyTier = { _ in .personal }) {
        self.key = key
        self.defaults = defaults
        self.tierOf = tierOf
    }

    private var drainedKey: String { key + ".drained" }

    private var drained: Set<String> { Set(defaults.stringArray(forKey: drainedKey) ?? []) }

    var all: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(defaults.stringArray(forKey: key) ?? [])
    }

    func add(_ names: some Sequence<String>) {
        lock.lock()
        defer { lock.unlock() }
        let drained = drained
        var held = Set(defaults.stringArray(forKey: key) ?? [])
        let before = held.count
        held.formUnion(names.filter { !drained.contains(tierOf($0).rawValue) })
        if held.count != before { defaults.set(held.sorted(), forKey: key) }
    }

    /// Deletes no longer held: the item was made again here (an edit supersedes the delete).
    func remove(_ names: some Sequence<String>) {
        lock.lock()
        defer { lock.unlock() }
        var held = Set(defaults.stringArray(forKey: key) ?? [])
        let before = held.count
        held.subtract(names)
        if held.count != before { defaults.set(held.sorted(), forKey: key) }
    }

    /// For a drain: everything held, noted as handed over.
    func handOver() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        handedOver = Set(defaults.stringArray(forKey: key) ?? [])
        return handedOver
    }

    /// The move kept this tier's part of what was handed over: those go, and the tier is drained.
    func kept(tier: LegacyTier) {
        lock.lock()
        defer { lock.unlock() }
        let going = handedOver.filter { tierOf($0) == tier }
        handedOver.subtract(going)
        let held = Set(defaults.stringArray(forKey: key) ?? []).subtracting(going)
        defaults.set(held.sorted(), forKey: key)
        defaults.set(drained.union([tier.rawValue]).sorted(), forKey: drainedKey)
    }
}

/// The modes, persisted per account: the account whose mirror this install belongs to (§2, one
/// account per install). Thread-safe: key-value and iCloud Drive writes happen on any thread.
///
/// Under them is a floor kept per device, not per account: once a tier has moved off iCloud on
/// this device it never writes iCloud again, whichever account comes next, after the mirror's
/// account is forgotten, and with the data platform on or off. No account bound (§2) is read-only too.
final class LegacyCloudModeStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    /// The data platform is on (`SpaceSyncFlag`). Off, every channel is `readWrite` (above the
    /// floor), whatever was saved for the account. On with no account bound, both tiers are at
    /// least `readOnly` (§2: a device without an account syncs nothing, through iCloud or any
    /// other way), and the floor says so from then on; the read-only channels still read.
    let enabled: Bool
    private var account: String?
    private var modes: LegacyCloudModes
    private var floor: LegacyCloudModes

    init(defaults: UserDefaults, account: String?, enabled: Bool) {
        self.defaults = defaults
        self.enabled = enabled
        self.account = account
        modes = Self.load(defaults, account)
        floor = defaults.data(forKey: Self.floorKey).flatMap { try? JSONDecoder().decode(LegacyCloudModes.self, from: $0) }
            ?? LegacyCloudModes()
        raiseFloorWithoutAccount()
    }

    /// No account bound with the data platform on: nothing writes iCloud on this device again.
    /// Called with the lock held (or from `init`).
    private func raiseFloorWithoutAccount() {
        guard enabled, account == nil else { return }
        raiseFloor(.personal)
        raiseFloor(.health)
    }

    private func raiseFloor(_ tier: LegacyTier) {
        guard floor[tier] == .readWrite else { return }
        floor[tier] = .readOnly
        if let data = try? JSONEncoder().encode(floor) { defaults.set(data, forKey: Self.floorKey) }
    }

    static func key(account: String) -> String { "legacyCloud.modes.\(account)" }
    /// Posted (on the caller's thread) when a mode or the bound account changed.
    static let didChange = Notification.Name("LegacyCloudModeStore.didChange")

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    /// The device's floor.
    static let floorKey = "legacyCloud.floor"

    /// The higher of two modes: `off` above `readOnly` above `readWrite`.
    private static func higher(_ a: LegacyCloudMode, _ b: LegacyCloudMode) -> LegacyCloudMode {
        let order: [LegacyCloudMode] = [.readWrite, .readOnly, .off]
        return order.firstIndex(of: a)! >= order.firstIndex(of: b)! ? a : b
    }

    private func effective(_ tier: LegacyTier) -> LegacyCloudMode {
        // App Review 5.1.3(ii): personal health information must never be written to iCloud,
        // including on an old bound install or with the diagnostic sync flag disabled. Keep
        // migration reads and pending local edits; consented cross-device sync uses our service.
        let requiredFloor = Self.higher(floor[tier], tier == .health ? .readOnly : .readWrite)
        guard enabled else { return Self.higher(.readWrite, requiredFloor) }
        return Self.higher(account == nil ? Self.higher(modes[tier], .readOnly) : modes[tier], requiredFloor)
    }

    private static func load(_ defaults: UserDefaults, _ account: String?) -> LegacyCloudModes {
        guard let account, let data = defaults.data(forKey: key(account: account)),
              let modes = try? JSONDecoder().decode(LegacyCloudModes.self, from: data) else { return LegacyCloudModes() }
        return modes
    }

    func mode(_ tier: LegacyTier) -> LegacyCloudMode {
        lock.lock()
        defer { lock.unlock() }
        return effective(tier)
    }

    var all: LegacyCloudModes {
        lock.lock()
        defer { lock.unlock() }
        return LegacyCloudModes(personal: effective(.personal), health: effective(.health))
    }

    var boundAccount: String? {
        lock.lock()
        defer { lock.unlock() }
        return account
    }

    /// The install's mirror now belongs to this account (or none): its saved modes apply.
    func bind(account: String?) {
        lock.lock()
        guard account != self.account else { lock.unlock(); return }
        self.account = account
        modes = Self.load(defaults, account)
        raiseFloorWithoutAccount()
        lock.unlock()
        changed()
    }

    /// False when it can't be kept: no account, or not enabled.
    @discardableResult
    func set(_ mode: LegacyCloudMode, for tier: LegacyTier) -> Bool {
        lock.lock()
        guard enabled, let account else { lock.unlock(); return false }
        modes[tier] = mode
        if let data = try? JSONEncoder().encode(modes) { defaults.set(data, forKey: Self.key(account: account)) }
        // Moved: never back to writing iCloud on this device (`off` isn't kept: another account's
        // move reads its own late arrivals again).
        if !mode.writes { raiseFloor(tier) }
        lock.unlock()
        changed()
        return true
    }
}

/// The one place the legacy channels' modes are held, and where every channel asks before it
/// writes iCloud.
enum LegacyCloud {
    /// The key `SpaceSyncLaunch` keeps the mirror's account under.
    static let boundAccountKey = "spaceSyncAccount"

    static let modes = LegacyCloudModeStore(
        defaults: .standard, account: UserDefaults.standard.string(forKey: boundAccountKey),
        enabled: SpaceSyncFlag.isOn)

    static func mode(_ tier: LegacyTier) -> LegacyCloudMode { modes.mode(tier) }
    static func mode(forType type: String) -> LegacyCloudMode { modes.mode(LegacyTier(type: type)) }
    static func mayWrite(_ tier: LegacyTier) -> Bool { mode(tier).writes }
    static func mayRead(_ tier: LegacyTier) -> Bool { mode(tier).reads }

    // MARK: Channels

    private final class WeakChannel {
        weak var channel: (any LegacyChannel)?
        init(_ channel: any LegacyChannel) { self.channel = channel }
    }
    @MainActor private static var registered: [WeakChannel] = []

    /// Every legacy channel this process runs, registered as it starts.
    @MainActor static var channels: [any LegacyChannel] { registered.compactMap(\.channel) }

    @MainActor static func register(_ channel: any LegacyChannel) {
        registered.removeAll { $0.channel == nil || $0.channel === channel }
        registered.append(WeakChannel(channel))
    }

    /// A tier's channels change mode: kept for the account, then each channel reacts.
    @MainActor static func set(_ mode: LegacyCloudMode, for tier: LegacyTier) {
        guard modes.set(mode, for: tier) else { return }
        for channel in channels where channel.tier == tier { channel.setMode(mode) }
    }

    // MARK: The move's drain

    /// The background time the move holds for its drain ran out (`MoveOver.Dependencies.holdBackground`):
    /// a drain under way stops (interrupted) and is tried again at the next step. Being in the
    /// background is no reason to stop otherwise.
    @MainActor static var drainExpired = false

        // MARK: Applying what iCloud brought

    /// What a legacy channel is handing its stores: per type, the ids (nil: every id of the type).
    struct ApplyScope: Sendable {
        var types: [String: Set<String>?]
        /// Everything (a synchronous apply, which nothing can interleave with).
        var everything = false

        init(_ types: [String: Set<String>?]) { self.types = types }

        static let all: ApplyScope = { var scope = ApplyScope([:]); scope.everything = true; return scope }()

        func contains(type: String, id: String) -> Bool {
            if everything { return true }
            guard let ids = types[type] else { return false }
            return ids?.contains(id) ?? true
        }
    }

    @MainActor private static var scopes: [ApplyScope] = []

    /// True while a legacy channel hands its stores what it fetched.
    @MainActor static var isApplyingFromCloud: Bool { !scopes.isEmpty }

    /// Whether a store's report of this item, now, is a legacy arrival rather than this device's
    /// edit: adapters route it to `MoveOver.arrived(type:ids:)` (`MoveOver.changed` does this).
    @MainActor static func isApplyingFromCloud(type: String, id: String) -> Bool {
        scopes.contains { $0.contains(type: type, id: id) }
    }

    /// A synchronous apply: every report made inside it is an arrival (nothing else can run then).
    @MainActor static func applyingFromCloud<T>(_ body: () throws -> T) rethrows -> T {
        scopes.append(.all)
        defer { scopes.removeLast() }
        return try body()
    }

    /// An apply that suspends (a Fitness batch): only the items it hands over count as arrivals, so
    /// an edit or delete made here while it waits is still this device's.
    @MainActor static func applyingFromCloud<T>(_ scope: ApplyScope, _ body: () async throws -> T) async rethrows -> T {
        scopes.append(scope)
        defer { if let index = scopes.lastIndex(where: { $0.types == scope.types && $0.everything == scope.everything }) { scopes.remove(at: index) } }
        return try await body()
    }
}

/// A channel that can't tell what it holds right now (its engine hasn't started yet, though
/// iCloud is there for it): the move waits and asks again.
enum LegacyDrainError: Error {
    case notRunning(String)
}

/// A channel's outgoing queue, behind the mode: every iCloud save or delete a channel queues goes
/// through `queue`, which drops it unless the mode is `readWrite`. Removing queued changes is not
/// a write, and always passes.
struct LegacyOutbox<Change> {
    let mode: () -> LegacyCloudMode
    let add: ([Change]) -> Void
    let remove: ([Change]) -> Void

    /// False: dropped, because this tier no longer writes iCloud.
    @discardableResult
    func queue(_ changes: [Change]) -> Bool {
        guard !changes.isEmpty else { return true }
        guard mode().writes else { return false }
        add(changes)
        return true
    }

    func unqueue(_ changes: [Change]) {
        guard !changes.isEmpty else { return }
        remove(changes)
    }
}

// MARK: - The key-value store

/// What `LegacyKVS` needs of `NSUbiquitousKeyValueStore`; a dictionary stands in for it in tests.
protocol LegacyKeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: LegacyKeyValueStore {}

/// Every iCloud key-value read and write of the stores in DATA-INVENTORY.md goes through here.
///
/// - `readWrite`: straight through, as today.
/// - `readOnly` and `off`: the key lives in this device's own copy (`UserDefaults`, under
///   `legacyKVS.local.<key>`), made from the last value seen in iCloud the first time it's read.
///   Writes go there and never to iCloud. Several stores keep these values nowhere else.
/// - `readOnly`: another device's change (an old build) is taken into the copy as it arrives,
///   even over this device's own write, and the stores hear it as an arrival
///   (`observeExternalChanges`).
/// - `off`: only the copy; another device's change is neither taken nor heard.
///
/// The two keys that stay in iCloud (§5) always go straight through.
final class LegacyKVS: @unchecked Sendable {
    static let keptKeys: Set<String> = ["googleCalendar.accountHint.v1", "podcastPeerGroupToken.v1"]

    static let shared = LegacyKVS(store: NSUbiquitousKeyValueStore.default, local: .standard,
                                  mode: { LegacyCloud.mode($0) }, notifying: NSUbiquitousKeyValueStore.default)

    /// The store `didChangeExternallyNotification` comes from: observers name this, never `shared`.
    static var ubiquitous: NSUbiquitousKeyValueStore { .default }

    private let store: LegacyKeyValueStore
    private let local: UserDefaults
    private let mode: @Sendable (LegacyTier) -> LegacyCloudMode
    /// The object external changes are posted for.
    let notifying: AnyObject
    private var takingChanges: NSObjectProtocol?

    init(store: LegacyKeyValueStore, local: UserDefaults, mode: @escaping @Sendable (LegacyTier) -> LegacyCloudMode,
         notifying: AnyObject) {
        self.store = store
        self.local = local
        self.mode = mode
        self.notifying = notifying
        // First of every observer of this notification (the stores make `shared` before they
        // listen), and on the posting thread: the copies hold the new values before any store reads.
        takingChanges = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: notifying, queue: nil) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            self?.take(keys)
        }
    }

    deinit { if let takingChanges { NotificationCenter.default.removeObserver(takingChanges) } }

    static func localKey(_ key: String) -> String { "legacyKVS.local.\(key)" }

    func mode(forKey key: String) -> LegacyCloudMode {
        guard !Self.keptKeys.contains(key) else { return .readWrite }
        return mode(LegacyInventory.tier(ofKey: key))
    }

    /// Another device changed these keys in iCloud: in `readOnly`, the copies take the new values.
    func take(_ keys: [String]) {
        for key in keys where mode(forKey: key) == .readOnly {
            keep(store.object(forKey: key), forKey: key)
        }
    }

    private func keep(_ value: Any?, forKey key: String) {
        local.set(Self.entry(value), forKey: Self.localKey(key))
    }

    private static func entry(_ value: Any?) -> [String: Any] { value.map { ["v": $0] } ?? ["gone": true] }

    /// Before the purge (`ICloudPurge`) removes a moved key from iCloud: this device's copy is
    /// made from iCloud's value if it doesn't exist yet, so a store that hasn't read the key since
    /// the move keeps what it had.
    static func keepCopyIfMissing(forKey key: String, from store: LegacyKeyValueStore, local: UserDefaults) {
        guard !keptKeys.contains(key), local.dictionary(forKey: localKey(key)) == nil else { return }
        local.set(entry(store.object(forKey: key)), forKey: localKey(key))
    }

    func set(_ value: Any?, forKey key: String) {
        guard let value else { return removeObject(forKey: key) }
        if mode(forKey: key).writes { store.set(value, forKey: key) } else { keep(value, forKey: key) }
    }

    func removeObject(forKey key: String) {
        if mode(forKey: key).writes { store.removeObject(forKey: key) } else { keep(nil, forKey: key) }
    }

    func object(forKey key: String) -> Any? {
        guard !mode(forKey: key).writes else { return store.object(forKey: key) }
        if let kept = local.dictionary(forKey: Self.localKey(key)) { return kept["gone"] != nil ? nil : kept["v"] }
        // First read since the move: the copy starts from the last value seen in iCloud.
        let seen = store.object(forKey: key)
        keep(seen, forKey: key)
        return seen
    }

    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    /// Writes nothing of ours in a mode that doesn't write (nothing new was set in iCloud): it
    /// only exchanges what the system holds.
    @discardableResult func synchronize() -> Bool { store.synchronize() }

    /// Another device changed iCloud key-value data: `handler` runs on the main actor as a legacy
    /// arrival (`LegacyCloud.applyingFromCloud`), and not at all once `tier` is `off`.
    @MainActor @discardableResult
    func observeExternalChanges(tier: LegacyTier, _ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: notifying, queue: .main) { [mode] _ in
            MainActor.assumeIsolated {
                guard mode(tier).reads else { return }
                LegacyCloud.applyingFromCloud { handler() }
            }
        }
    }

    @MainActor @discardableResult
    static func observeExternalChanges(tier: LegacyTier, _ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        shared.observeExternalChanges(tier: tier, handler)
    }
}

// MARK: - What each channel carries

/// DATA-INVENTORY.md as data: which catalog type each legacy record becomes, and so which tier
/// moves it. The ids in a `DrainResult` are the stores' own ids:
/// - Controls and Meals: the item's id (`ControlKind`, unhashed);
/// - Wellness: a meal's or supplement's UUID; a dose's `<supplement UUID>-<yyyyMMdd>`;
/// - Fitness: a workout's or note's UUID; the Health snapshot's `health-cache`;
/// - Progress: the episode's id; Settings: `smart-settings`.
enum LegacyInventory {
    /// Each channel's types (`LegacyChannel.types`).
    static let controls: Set<String> = [
        "plan.routine", "plan.alarm", "plan.wake", "podcast.settings", "podcast.show", "plan.override", "plan.extra",
        "podcast.listen", "podcast.skipPlan", "podcast.adSlots", "podcast.skipCorrection",
        "podcast.narratorReading", "podcast.narratorGender", "podcast.narratorOverride",
    ]
    static let controlsHealth: Set<String> = ["health.workoutPlan", "health.workoutCompletion", "food.correction", "food.myFood"]
    static let meals: Set<String> = ["food.mealInbox", "food.mealPhoto", "food.mealPhotoFound"]
    static let wellness: Set<String> = ["food.meal", "food.supplement", "food.dose"]
    static let progress: Set<String> = ["podcast.progress"]
    static let fitness: Set<String> = ["health.workout", "health.snapshot"]
    static let fitnessNotes: Set<String> = ["notes.voiceNote"]
    static let settings: Set<String> = ["core.smartSettings"]
    static let drive: Set<String> = ["podcast.transcript", "notes.voiceNote"]
    /// Types that never lived in iCloud (booking types, the service's own): no legacy channel
    /// carries them, so no tier's coverage waits for them (`MoveOver` counts only channel types).
    static let withoutLegacy: Set<String> = ["plan.bookingType"]

    /// The key-value keys and their types; `keptKeys` aren't here.
    static let keys: [String: String] = [
        "appSettings": "core.appSettings",
        "modules": "core.modules",
        "smartScheduleSettings.v1": "core.smartSettings",
        "smartWakePlan.v1": "core.wakePlan",
        "hubStatus.v1": "core.hubStatus",
        "hubRequests.v1": "core.hubRequest",
        "healthRemovalRequests.v1": "health.removalRequest",
        "workoutRevertRequests.v1": "health.workoutRevert",
        "taskDurations.v1": "plan.taskDuration",
        "reminderAnchors.v1": "plan.reminderAnchor",
        "reminderAnchors.usual.v1": "plan.reminderAnchorUsual",
        "missedRepeats.v1": "plan.missedRepeat",
        "anchorSuggestions.declined.v1": "plan.declinedSuggestion",
        "reminderToTaken.notNow.v1": "plan.notNow",
        "guestPicks.v1": "core.guestPick",
        "foodSearchPicks.v1": "food.searchPick",
        "mealEstimators.v1": "food.estimatorStatus",
        "mealPhotoScan.reports": "food.photoScanReport",
    ]
    static var kvs: Set<String> { Set(keys.values.filter { !isHealth($0) }) }
    static var kvsHealth: Set<String> { Set(keys.values.filter(isHealth)) }

    /// `ControlKind.rawValue` → type. A listen's route is a field of the listen.
    static let controlKinds: [String: String] = [
        "routine": "plan.routine", "alarm": "plan.alarm", "wake": "plan.wake",
        "podcast": "podcast.settings", "show": "podcast.show",
        "timelineOverride": "plan.override", "timelineExtra": "plan.extra",
        "listen": "podcast.listen", "listenRoute": "podcast.listen",
        "skipPlan": "podcast.skipPlan", "adSlots": "podcast.adSlots", "skipCorrection": "podcast.skipCorrection",
        "narratorReading": "podcast.narratorReading", "narratorGender": "podcast.narratorGender",
        "narratorOverride": "podcast.narratorOverride",
        "workoutPlan": "health.workoutPlan", "workoutCompletion": "health.workoutCompletion",
        "foodCorrection": "food.correction", "myFood": "food.myFood",
        "mealInbox": "food.mealInbox", "mealPhoto": "food.mealPhoto", "mealPhotoFound": "food.mealPhotoFound",
    ]

    /// T2 in the catalog (§5): the health and food modules, and the wake plan, which is worked out
    /// from sleep and recovery ("Recovery: bed 20m earlier"). `LegacyCloudTests` checks this
    /// against `Shared/DataCatalog.json`.
    static func isHealth(_ type: String) -> Bool {
        type.hasPrefix("health.") || type.hasPrefix("food.") || healthElsewhere.contains(type)
    }
    private static let healthElsewhere: Set<String> = ["core.wakePlan"]

    /// A key's tier: unknown keys count as personal data, so they are gated too.
    static func tier(ofKey key: String) -> LegacyTier { LegacyTier(type: keys[key] ?? "core.unknown") }

    static func tier(ofControlKind kind: String) -> LegacyTier { LegacyTier(type: controlKinds[kind] ?? "core.unknown") }
}
