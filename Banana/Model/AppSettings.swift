import Foundation

// DistanceUnit now lives in DistanceUnit.swift, and WatchAudioQuality in WatchAudioQuality.swift —
// the types from this file that WorkoutComparison.swift and Podcast.swift (and BananaTests)
// actually need, split out so BananaTests can source them without also pulling in AppSettings'
// LaunchClock/CloudBackup dependencies, which aren't otherwise part of the test target's
// dependency chain.

/// Pool length for swim workouts.
///
/// Configured here rather than on the Watch: your pool is the same pool nearly every time, so
/// this is a set-once value, and picking it mid-poolside on a small screen — with water lock
/// about to engage — is the wrong moment to ask.
///
/// The Watch counts lengths and multiplies by this, so a wrong value scales the swim's
/// distance and pace (laps and lap times stay right). A 50 m default once turned months of
/// 25-yard swims into 2.19× their real distance — see Settings › Apple Health › Workout cleanup.
enum PoolLength: String, Codable, CaseIterable, Identifiable {
    case yards25, meters25, meters33, meters50

    var id: String { rawValue }

    var meters: Double {
        switch self {
        case .yards25:  return 22.86     // 25 yd
        case .meters25: return 25
        case .meters33: return 33.33     // 33⅓ m, the common European third-length
        case .meters50: return 50
        }
    }

    var label: String {
        switch self {
        case .yards25:  return "25 yards"
        case .meters25: return "25 meters"
        case .meters33: return "33⅓ meters"
        case .meters50: return "50 meters (long course)"
        }
    }
}

/// App-wide preferences. Small and extensible — add fields as they come up.
@MainActor
final class AppSettings: ObservableObject {
    @Published var distanceUnit: DistanceUnit {
        didSet {
            MetricKind.imperial = distanceUnit == .miles   // weight, height, speed follow it too
            save()
        }
    }
    /// Pool length for swim workouts, pushed to the Watch so a swim needs no setup on the wrist.
    @Published var poolLength: PoolLength { didSet { save() } }
    @Published var watchAudioQuality: WatchAudioQuality { didSet { save() } }
    /// Back up to iCloud: one setting for every device; the phone makes the backups. Nil until a
    /// device that knows seeds it (see `CloudBackup.bind`).
    @Published var backupEnabled: Bool? { didSet { save() } }
    @Published var recordListenLocation: Bool { didSet { save() } }
    /// Skip podcast ads Banana is confident about. On by default: the detectors that reach this
    /// switch are the ones measured at no false positives, so the cost of being wrong here is a
    /// missed ad, not a lost minute of the episode.
    @Published var automaticAdSkip: Bool { didSet { save() } }
    /// Minutes before an event to notify. Empty means no event notifications.
    ///
    /// On by default, at the start and five minutes ahead. That is only safe because events which
    /// already carry their own alert are skipped — see `EventAlertPlan` — so this covers the gap
    /// (invites and video calls with no alert set) rather than doubling what Calendar already says.
    @Published var eventAlertLeads: [Int] { didSet { save() } }
    /// Preferred maps app for the "Directions" button. nil = ask on first use, then remember.
    @Published var mapsProvider: MapsProvider? { didSet { save() } }

    /// Sleep timer: the configured fade-out duration, used by the "Play to sleep"
    /// button and the bedtime auto-arm.
    @Published var sleepTimerMinutes: Int { didSet { save() } }
    /// Auto-arm the sleep timer when playback starts late (so a podcast can't run all night).
    @Published var autoSleepTimer: Bool { didSet { save() } }
    /// Hour-of-day (0–23) after which playback counts as bedtime for the auto-arm.
    @Published var autoSleepAfterHour: Int { didSet { save() } }
    /// Whether `MacPayoffPresenter` auto-presents the morning briefing on the Mac. Meaningless on
    /// iOS (the briefing's cue there is the alarm), but it's still a normal synced preference —
    /// harmless for the phone to carry a value it never reads.
    @Published var macMorningBriefing: Bool { didSet { save() } }
    /// "Find meal photos automatically" (docs/design/MEAL-BACKLOG.md, "Scanner"). One synced
    /// switch, the same on every device; only the iPhone looks through its photos. Off until
    /// turned on, since turning it on is what asks for access to the whole library.
    @Published var mealPhotoScanEnabled: Bool { didSet { save(); Self.mealPhotoScanChanged() } }
    /// How far back the scan starts. Set when it's turned on (`setMealPhotoScan`); "Starting from"
    /// moves it.
    @Published var mealPhotoScanSince: Date? { didSet { save(); Self.mealPhotoScanChanged() } }
    /// Ask about meal photos the phone finds in the background: a notification per meal.
    @Published var mealPhotoAskEnabled: Bool { didSet { save(); Self.mealPhotoScanChanged() } }

    /// Posted when any of the meal-photo settings changes, here or from another device: the phone's
    /// `MealPhotoScanner` acts on it without holding on to this object (a background launch has none).
    static let mealPhotoScanDidChange = Notification.Name("AppSettings.mealPhotoScanDidChange")

    /// The app's settings object, while there is one. Code that also runs in a background launch
    /// reads `currentMealPhotoScan` instead of reaching for this.
    private(set) static weak var live: AppSettings?

    /// Fired after any change is persisted (e.g. to push the unit to the Watch).
    var onChange: (() -> Void)?

    static let sleepDurationOptions = [15, 30, 45, 60, 90]

    private static let storageKey = "appSettings"
    private let key = AppSettings.storageKey

    /// iCloud key-value store — the phone↔Mac settings bridge. Small prefs only (well under the
    /// 1 MB KVS budget). The Watch isn't a KVS client; it keeps getting units etc. via
    /// WatchConnectivity through `onChange`.
    private let cloud = LegacyKVS.shared
    /// True while we're applying a change that CAME FROM the cloud, so the property `didSet`s don't
    /// turn around and re-publish it (which would loop devices against each other).
    private var applyingRemote = false

    /// Optional fields → decoding tolerates missing/added keys automatically. Each is one field of
    /// the data platform's `core.appSettings` record (`SettingsAdapters`).
    struct Snapshot: Codable, Equatable {
        var distanceUnit: DistanceUnit?
        var poolLength: PoolLength?
        var watchAudioQuality: WatchAudioQuality?
        var recordListenLocation: Bool?
        var automaticAdSkip: Bool?
        var eventAlertLeads: [Int]?
        var mapsProvider: MapsProvider?
        var sleepTimerMinutes: Int?
        var autoSleepTimer: Bool?
        var autoSleepAfterHour: Int?
        var macMorningBriefing: Bool?
        var backupEnabled: Bool?
        var mealPhotoScanEnabled: Bool?
        var mealPhotoScanSince: Date?
        var mealPhotoAskEnabled: Bool?
    }

    init() {
        let snapshot = Self.load(key: key)
        distanceUnit = snapshot?.distanceUnit ?? Self.localeDefault()
        poolLength = snapshot?.poolLength ?? .yards25
        watchAudioQuality = snapshot?.watchAudioQuality ?? .original
        backupEnabled = snapshot?.backupEnabled
        MetricKind.imperial = (snapshot?.distanceUnit ?? Self.localeDefault()) == .miles
        recordListenLocation = snapshot?.recordListenLocation ?? false
        automaticAdSkip = snapshot?.automaticAdSkip ?? true
        eventAlertLeads = snapshot?.eventAlertLeads ?? EventAlertPlan.defaultLeads
        mapsProvider = snapshot?.mapsProvider
        sleepTimerMinutes = snapshot?.sleepTimerMinutes ?? 45
        autoSleepTimer = snapshot?.autoSleepTimer ?? true
        autoSleepAfterHour = snapshot?.autoSleepAfterHour ?? 21
        macMorningBriefing = snapshot?.macMorningBriefing ?? true
        mealPhotoScanEnabled = snapshot?.mealPhotoScanEnabled ?? false
        mealPhotoScanSince = snapshot?.mealPhotoScanSince
        mealPhotoAskEnabled = snapshot?.mealPhotoAskEnabled ?? true

        // React to settings changed on another device, then pull whatever the cloud already holds.
        LegacyKVS.observeExternalChanges(tier: .personal) { [weak self] in self?.applyFromCloud() }
        // Deferred: the KVS daemon round-trip + initial adoption were on the first-frame path,
        // and a settings value arriving one runloop turn after first paint is indistinguishable
        // from arriving before it.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cloud.synchronize()
            self.applyFromCloud()
        }
        LaunchClock.mark("settings.init")
        Self.live = self
    }

    // MARK: - Meal photos

    var mealPhotoScan: MealPhotoScanPrefs {
        MealPhotoScanPrefs(enabled: mealPhotoScanEnabled, since: mealPhotoScanSince, ask: mealPhotoAskEnabled)
    }

    /// Turns "Find meal photos automatically" on or off. Turning it on starts it `lookBack` before
    /// today — every time, so switching it back on after a few months doesn't send the phone
    /// through every photo taken while it was off. "Starting from" moves it after.
    func setMealPhotoScan(_ on: Bool, now: Date = Date()) {
        guard on != mealPhotoScanEnabled else { return }
        // The date first, so whatever reacts to the switch already sees where it starts.
        if on { mealPhotoScanSince = MealPhotoScanPrefs.defaultSince(now: now) }
        mealPhotoScanEnabled = on
    }

    /// The meal-photo setting for code that runs without the app's settings object — a background
    /// launch for the scan, a question answered from the lock screen. The live object when there is
    /// one; otherwise what was last saved: iCloud's copy first (it carries a change made on another
    /// device), then this device's.
    static var currentMealPhotoScan: MealPhotoScanPrefs {
        if let live { return live.mealPhotoScan }
        let cloud = LegacyKVS.shared.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        let local = load(key: storageKey)
        return MealPhotoScanPrefs(
            enabled: cloud?.mealPhotoScanEnabled ?? local?.mealPhotoScanEnabled ?? false,
            since: cloud?.mealPhotoScanSince ?? local?.mealPhotoScanSince,
            ask: cloud?.mealPhotoAskEnabled ?? local?.mealPhotoAskEnabled ?? true)
    }

    private static func mealPhotoScanChanged() {
        NotificationCenter.default.post(name: mealPhotoScanDidChange, object: nil)
    }

    private func save() {
        // A cloud adoption assigns up to six properties; each didSet lands here. Skip entirely —
        // applyFromCloud persists once and fires ONE onChange (one Watch push) at the end,
        // instead of a defaults write + push per property.
        guard !applyingRemote else { return }
        let snapshot = Snapshot(distanceUnit: distanceUnit, poolLength: poolLength,
                                watchAudioQuality: watchAudioQuality,
                                recordListenLocation: recordListenLocation,
                                automaticAdSkip: automaticAdSkip,
                                eventAlertLeads: eventAlertLeads,
                                mapsProvider: mapsProvider,
                                sleepTimerMinutes: sleepTimerMinutes, autoSleepTimer: autoSleepTimer,
                                autoSleepAfterHour: autoSleepAfterHour, macMorningBriefing: macMorningBriefing,
                                backupEnabled: backupEnabled,
                                mealPhotoScanEnabled: mealPhotoScanEnabled,
                                mealPhotoScanSince: mealPhotoScanSince,
                                mealPhotoAskEnabled: mealPhotoAskEnabled)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
            // Only real local edits go to iCloud.
            cloud.set(data, forKey: key)
            cloud.synchronize()
        }
        CloudBackup.shared.schedule()   // the snapshot digests UserDefaults — a settings change dirties it
        SyncReport.changed(Self.syncType, [Self.syncID])
        onChange?()
    }

    /// Adopt the cloud's settings blob if it differs from ours. Sets `applyingRemote` so the
    /// property `didSet`s that fire during assignment are coalesced into one persist + notify.
    private func applyFromCloud() {
        guard let data = cloud.data(forKey: key),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        applyingRemote = true
        var changed = false
        if let v = snap.distanceUnit, v != distanceUnit { distanceUnit = v; changed = true }
        if let v = snap.poolLength, v != poolLength { poolLength = v; changed = true }
        if let v = snap.watchAudioQuality, v != watchAudioQuality { watchAudioQuality = v; changed = true }
        if let v = snap.backupEnabled, v != backupEnabled { backupEnabled = v; changed = true }
        if let v = snap.recordListenLocation, v != recordListenLocation { recordListenLocation = v; changed = true }
        if let v = snap.automaticAdSkip, v != automaticAdSkip { automaticAdSkip = v; changed = true }
        if let v = snap.eventAlertLeads, v != eventAlertLeads { eventAlertLeads = v; changed = true }
        if let v = snap.mapsProvider, v != mapsProvider { mapsProvider = v; changed = true }
        if let v = snap.sleepTimerMinutes, v != sleepTimerMinutes { sleepTimerMinutes = v; changed = true }
        if let v = snap.autoSleepTimer, v != autoSleepTimer { autoSleepTimer = v; changed = true }
        if let v = snap.autoSleepAfterHour, v != autoSleepAfterHour { autoSleepAfterHour = v; changed = true }
        if let v = snap.macMorningBriefing, v != macMorningBriefing { macMorningBriefing = v; changed = true }
        // The start date before the switch, as `setMealPhotoScan` does it.
        if let v = snap.mealPhotoScanSince, v != mealPhotoScanSince { mealPhotoScanSince = v; changed = true }
        if let v = snap.mealPhotoScanEnabled, v != mealPhotoScanEnabled { mealPhotoScanEnabled = v; changed = true }
        if let v = snap.mealPhotoAskEnabled, v != mealPhotoAskEnabled { mealPhotoAskEnabled = v; changed = true }
        applyingRemote = false
        guard changed else { return }
        // Mirror into local defaults so a later offline launch has the adopted values; one
        // notification carries all of it to the Watch.
        UserDefaults.standard.set(data, forKey: key)
        // Another device's settings, through iCloud: a late arrival for the data platform.
        LegacyCloud.applyingFromCloud { SyncReport.changed(Self.syncType, [Self.syncID]) }
        onChange?()
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `SettingsAdapters`)

    static let syncType = "core.appSettings"
    static let syncID = "appSettings"

    /// Every setting as it is now: one field each.
    var syncSnapshot: Snapshot {
        Snapshot(distanceUnit: distanceUnit, poolLength: poolLength, watchAudioQuality: watchAudioQuality,
                 recordListenLocation: recordListenLocation, automaticAdSkip: automaticAdSkip,
                 eventAlertLeads: eventAlertLeads, mapsProvider: mapsProvider,
                 sleepTimerMinutes: sleepTimerMinutes, autoSleepTimer: autoSleepTimer,
                 autoSleepAfterHour: autoSleepAfterHour, macMorningBriefing: macMorningBriefing,
                 backupEnabled: backupEnabled, mealPhotoScanEnabled: mealPhotoScanEnabled,
                 mealPhotoScanSince: mealPhotoScanSince, mealPhotoAskEnabled: mealPhotoAskEnabled)
    }

    /// What a new install starts with (`init`): only settings that differ from it are seeded.
    static var syncDefault: Snapshot {
        Snapshot(distanceUnit: localeDefault(), poolLength: .yards25, watchAudioQuality: .original,
                 recordListenLocation: false, automaticAdSkip: true, eventAlertLeads: EventAlertPlan.defaultLeads,
                 mapsProvider: nil, sleepTimerMinutes: 45, autoSleepTimer: true, autoSleepAfterHour: 21,
                 macMorningBriefing: true, backupEnabled: nil, mealPhotoScanEnabled: false,
                 mealPhotoScanSince: nil, mealPhotoAskEnabled: true)
    }

    /// Another account signed in on this device and the person said to clear it first
    /// (docs/design/DATA-PLATFORM.md §2): every setting back to what a new install starts with.
    /// This device only: nothing is reported and iCloud's key-value store isn't written.
    func resetForAccountChange() {
        let fresh = Self.syncDefault
        applyingRemote = true
        distanceUnit = fresh.distanceUnit ?? Self.localeDefault()
        poolLength = fresh.poolLength ?? .yards25
        watchAudioQuality = fresh.watchAudioQuality ?? .original
        backupEnabled = nil
        recordListenLocation = fresh.recordListenLocation ?? false
        automaticAdSkip = fresh.automaticAdSkip ?? true
        eventAlertLeads = fresh.eventAlertLeads ?? EventAlertPlan.defaultLeads
        mapsProvider = nil
        sleepTimerMinutes = fresh.sleepTimerMinutes ?? 45
        autoSleepTimer = fresh.autoSleepTimer ?? true
        autoSleepAfterHour = fresh.autoSleepAfterHour ?? 21
        macMorningBriefing = fresh.macMorningBriefing ?? true
        mealPhotoScanSince = nil
        mealPhotoScanEnabled = fresh.mealPhotoScanEnabled ?? false
        mealPhotoAskEnabled = fresh.mealPhotoAskEnabled ?? true
        applyingRemote = false
        UserDefaults.standard.removeObject(forKey: key)
        onChange?()
    }

    /// The record as it merged, field by field: a field that's there is taken; one cleared
    /// (`null`) is cleared here too, for the settings that can be unset.
    func applySynced(_ snap: Snapshot, cleared: Set<String>) {
        applyingRemote = true
        var changed = false
        func take<T: Equatable>(_ value: T?, _ current: inout T) {
            if let value, value != current { current = value; changed = true }
        }
        func take<T: Equatable>(_ value: T?, _ current: inout T?, _ key: String) {
            if let value { if value != current { current = value; changed = true } }
            else if cleared.contains(key), current != nil { current = nil; changed = true }
        }
        take(snap.distanceUnit, &distanceUnit)
        take(snap.poolLength, &poolLength)
        take(snap.watchAudioQuality, &watchAudioQuality)
        take(snap.backupEnabled, &backupEnabled, "backupEnabled")
        take(snap.recordListenLocation, &recordListenLocation)
        take(snap.automaticAdSkip, &automaticAdSkip)
        take(snap.eventAlertLeads, &eventAlertLeads)
        take(snap.mapsProvider, &mapsProvider, "mapsProvider")
        take(snap.sleepTimerMinutes, &sleepTimerMinutes)
        take(snap.autoSleepTimer, &autoSleepTimer)
        take(snap.autoSleepAfterHour, &autoSleepAfterHour)
        take(snap.macMorningBriefing, &macMorningBriefing)
        // The start date before the switch, as `setMealPhotoScan` does it.
        take(snap.mealPhotoScanSince, &mealPhotoScanSince, "mealPhotoScanSince")
        take(snap.mealPhotoScanEnabled, &mealPhotoScanEnabled)
        take(snap.mealPhotoAskEnabled, &mealPhotoAskEnabled)
        applyingRemote = false
        guard changed else { return }
        save()
    }

    private static func load(key: String) -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func localeDefault() -> DistanceUnit {
        Locale.current.measurementSystem == .metric ? .kilometers : .miles
    }
}

extension MealPhotoScanPrefs {
    /// See `AppSettings.currentMealPhotoScan`.
    @MainActor static var current: MealPhotoScanPrefs { AppSettings.currentMealPhotoScan }
}
