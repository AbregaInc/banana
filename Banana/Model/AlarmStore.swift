#if os(iOS)
// AlarmKit is iPhone-only — a sleeping Mac can't wake you.

import AlarmKit
import SwiftUI
import Foundation

/// A one-off alarm the user sets for a specific moment ("wake me at 4pm today"). Unlike the
/// recurring slot/smart alarms, it fires once and is then pruned. Lives alongside — not
/// instead of — Smart Schedule and manual slots.

/// Owns all alarm state: which 15-minute slots are enabled, the mapping from
/// slot → system alarm id (so we can cancel), and the AlarmKit authorization
/// status. This is the single source of truth for the alarm UI.
@MainActor
final class AlarmStore: ObservableObject {
    @Published private(set) var enabled: Set<Int> = []
    @Published private(set) var authorization: AlarmManager.AuthorizationState = .notDetermined {
        didSet {
            defaults.set(authorization == .authorized, forKey: Keys.authWasAuthorized)
            reportStatus()
        }
    }
    @Published private(set) var wakeAlarmTimes: [Date] = [] {   // currently-armed per-day wake one-shots
        didSet { reportStatus() }
    }

    /// What every other device's alarm controls show: permission, and the next alarm armed here.
    private func reportStatus() {
        let next = wakeAlarmTimes.filter { $0 > Date() }.min()
        let allowed = authorization == .authorized
        HubStatusStore.shared.update {
            $0.alarmsAllowed = allowed
            $0.nextAlarm = next
        }
    }
    @Published private(set) var oneOffAlarms: [OneOffAlarm] = []   // user's ad-hoc one-shot alarms
    /// Fired after the one-off alarm set changes, so the timeline can re-materialize them.
    var onOneOffChange: (() -> Void)?
    /// Transient, user-facing error (e.g. hit the system alarm limit). UI shows and clears it.
    @Published var errorMessage: String?
    /// True while any scheduled alarm is currently ringing.
    @Published private(set) var isAlerting = false

    private var lastAlertAt: Date?
    private var consumedAlertAt: Date?

    /// slot (minutes-of-day) → system alarm id. Persisted so toggles survive relaunch.
    private var idMap: [Int: UUID] = [:]

    private let manager = AlarmManager.shared
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "enabledSlots"
        static let idMap = "slotAlarmIDs"
        static let lastAlert = "lastAlertAt"
        static let consumedAlert = "consumedAlertAt"
        static let smartIDs = "smartAlarmIDs"
        static let manualSuspended = "manualSuspended"
        static let oneOff = "oneOffAlarms"
        static let wakeTimes = "wakeAlarmTimes"
        static let authWasAuthorized = "alarmAuthWasAuthorized"
    }

    init() {
        // Seed so the first frame doesn't flash the permission gate. The synchronous
        // `authorizationState` read is itself a daemon round-trip, so the previously-authorized
        // case (every launch after onboarding) seeds from the cached value instantly and lets
        // the deferred refresh below confirm; only the not-yet-authorized case (onboarding, or
        // a rare revocation) pays the synchronous read — where the gate is showing anyway.
        if defaults.bool(forKey: Keys.authWasAuthorized) {
            authorization = .authorized
        } else {
            authorization = manager.authorizationState
        }
        load()
        // Deferred: the orphan reconcile and the initial alerting read are each a synchronous
        // round-trip to the alarm daemon, and this init sits in the first-frame path. One main-
        // actor task runs them right after first paint; correctness is unchanged — RootView
        // reacts to `isAlerting` via onChange, so a wake that was already ringing still triggers
        // the moment the deferred read lands, and `alarmUpdates` keeps it live from then on.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconcileScheduledAlarms()
            await self.armOneOffsFromOtherDevices()
            let live = (try? self.manager.alarms) ?? []
            self.updateAlerting(from: live)
            // Post-restore divergence: UserDefaults (this mirror) survive a device restore; the
            // alarm daemon's schedule does not. If tracked smart alarms are missing from the
            // daemon, clear the mirror — otherwise the re-arm diff would skip a set that looks
            // armed but isn't, and the first morning after a restore would wake nobody.
            if !self.smartAlarmIDs.isEmpty {
                let liveIDs = Set(live.map(\.id))
                if self.smartAlarmIDs.contains(where: { !liveIDs.contains($0) }) {
                    self.wakeAlarmTimes = []
                    self.defaults.set([Date](), forKey: Keys.wakeTimes)
                }
            }
        }
        Task { await refreshAuthorization() }
        observeAuthorization()
        observeAlarms()
        LaunchClock.mark("alarms.init")
    }

    /// Cancel every scheduled AlarmKit alarm that isn't valid for the current mode.
    /// Manual and smart are mutually exclusive: when Smart Schedule owns the alarm
    /// (`manualSuspended`), only the tracked smart wakes are valid; otherwise only
    /// the manual slots are. This removes duplicates AND any cross-mode strays.
    private func reconcileScheduledAlarms() {
        // One-off alarms coexist with either mode, so they're always "expected".
        let base: Set<UUID> = manualSuspended ? Set(smartAlarmIDs) : Set(idMap.values)
        let expected = base.union(oneOffAlarms.map(\.id))
        for alarm in (try? manager.alarms) ?? [] where !expected.contains(alarm.id) {
            try? manager.cancel(id: alarm.id)
        }
    }

    // MARK: - Public API

    var isAuthorized: Bool { authorization == .authorized }

    #if DEBUG
    /// Screenshot seeding only — see the note in OccurrenceStore.
    ///
    /// Sticky, because `refreshAuthorization()` re-reads AlarmKit on appear and a simulator has
    /// granted nothing. Setting the value alone let it be overwritten moments after launch, so
    /// the "Alarms aren't connected" card reappeared before the capture.
    private(set) var auditAuthorized = false
    func markAuthorizedForAudit() {
        auditAuthorized = true
        authorization = .authorized
    }
    #endif
    var enabledCount: Int { enabled.count }

    func isOn(_ slot: Int) -> Bool { enabled.contains(slot) }

    /// Toggle a slot on/off. Scheduling is async and can fail (permission denied,
    /// system alarm limit), in which case `enabled` simply isn't updated so the
    /// UI reverts, and `errorMessage` is set.
    func setEnabled(_ on: Bool, slot: Int) async {
        if on {
            await enable(slot)
        } else {
            disable(slot)
        }
    }

    func requestAuthorization() async {
        _ = await ensureAuthorized()
    }

    // MARK: - Scheduling

    private func enable(_ slot: Int) async {
        guard !enabled.contains(slot) else { return }
        guard await ensureAuthorized() else { return }

        let id = idMap[slot] ?? UUID()
        do {
            _ = try await manager.schedule(id: id, configuration: makeConfiguration(id: id, for: slot))
            idMap[slot] = id
            enabled.insert(slot)
            persist()
        } catch AlarmManager.AlarmError.maximumLimitReached {
            errorMessage = "iOS won't allow any more scheduled alarms right now. Turn some off first."
        } catch {
            errorMessage = "Couldn't set alarm: \(error.localizedDescription)"
        }
    }

    private func disable(_ slot: Int) {
        if let id = idMap[slot] {
            try? manager.cancel(id: id)
            idMap[slot] = nil
        }
        enabled.remove(slot)
        persist()
    }

    private func makeConfiguration(id: UUID, for slot: Int) -> AlarmManager.AlarmConfiguration<BananaMetadata> {
        let everyDay: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        return makeConfiguration(id: id, hour: TimeSlot.hour(slot), minute: TimeSlot.minute(slot),
                                 weekdays: everyDay, title: TimeSlot.formatted(slot))
    }

    private func makeConfiguration(id: UUID, hour: Int, minute: Int, weekdays: [Locale.Weekday],
                                   title: String) -> AlarmManager.AlarmConfiguration<BananaMetadata> {
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        let schedule = Alarm.Schedule.relative(.init(time: time, repeats: .weekly(weekdays)))
        // System provides the Stop button (wired to stopIntent); we add an "Open" secondary.
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            secondaryButton: AlarmButton(text: "Open", textColor: .white, systemImageName: "arrow.up.forward.app"),
            secondaryButtonBehavior: .custom
        )
        let attributes = BananaAlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: BananaMetadata(),
            tintColor: .orange
        )
        // stopIntent → start the wake source (works even from a locked Lock Screen);
        // secondaryIntent → open the app.
        return AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule,
            attributes: attributes,
            stopIntent: WakeStopIntent(alarmID: id.uuidString),
            secondaryIntent: WakeOpenIntent(),
            sound: .default)
    }

    // MARK: - Smart schedule (calendar-driven wake)

    private var smartAlarmIDs: [UUID] = []
    private(set) var manualSuspended = false

    /// Cancel manual slot alarms without forgetting which slots are on, so Smart
    /// Schedule can own the alarm. `enabled` is preserved for later resume.
    func suspendManual() {
        guard !manualSuspended else { return }
        for id in idMap.values { try? manager.cancel(id: id) }
        manualSuspended = true
        defaults.set(true, forKey: Keys.manualSuspended)
    }

    /// Re-schedule the manual slot alarms from the preserved `enabled` set.
    func resumeManual() async {
        guard manualSuspended else { return }
        manualSuspended = false
        defaults.set(false, forKey: Keys.manualSuspended)
        guard await ensureAuthorized() else { return }
        for slot in enabled {
            let id = idMap[slot] ?? UUID()
            if let scheduled = try? await manager.schedule(id: id, configuration: makeConfiguration(id: id, for: slot)) {
                _ = scheduled
                idMap[slot] = id
            }
        }
        persist()
    }

    /// Replace the smart wake alarms with a new set of (time, weekdays) entries.
    func scheduleSmartWakes(_ entries: [(minutes: Int, weekdays: [Int])]) async {
        guard await ensureAuthorized() else { return }
        cancelSmartWakes()
        for entry in entries {
            let weekdays = entry.weekdays.map(Self.localeWeekday)
            guard !weekdays.isEmpty else { continue }
            let id = UUID()
            let title = "Wake · \(SmartScheduler.label(minutesOfDay: entry.minutes))"
            do {
                _ = try await manager.schedule(
                    id: id,
                    configuration: makeConfiguration(id: id, hour: entry.minutes / 60, minute: entry.minutes % 60,
                                                     weekdays: weekdays, title: title))
                smartAlarmIDs.append(id)
            } catch AlarmManager.AlarmError.maximumLimitReached {
                errorMessage = "iOS won't allow any more scheduled alarms right now."
            } catch {
                errorMessage = "Couldn't set the smart wake: \(error.localizedDescription)"
            }
        }
        saveSmartIDs()
    }

    /// Arm the wake alarm as per-day one-shots from the occurrence timeline — so a skipped
    /// day gets no alarm and a moved day fires at the new time (exceptions already applied
    /// upstream). Replaces the weekly-repeat wakes; tracked under the same `smartAlarmIDs`.
    func scheduleWakeOccurrences(_ dates: [Date]) async {
        let now = Date()
        let wanted = dates.filter { $0 > now }
        // Diff before touching the daemon: this runs on EVERY recompute (tab switch, foreground,
        // calendar sync), and a blind cancel+re-arm is up to ~40 XPC round-trips for a set that
        // almost never changed. The count guard matters: `wakeAlarmTimes` only tracks per-day
        // one-shots, so if other smart alarms (the weekly repeats) are still armed, fall through
        // and let the replace clear them.
        if wanted == wakeAlarmTimes, smartAlarmIDs.count == wakeAlarmTimes.count { return }
        guard await ensureAuthorized() else { return }
        cancelSmartWakes()
        var armed: [Date] = []
        for date in wanted {
            let id = UUID()
            let title = "Wake · \(date.formatted(.dateTime.hour().minute()))"
            do {
                _ = try await manager.schedule(id: id, configuration: makeFixedConfiguration(id: id, fire: date, title: title))
                smartAlarmIDs.append(id)
                armed.append(date)
            } catch AlarmManager.AlarmError.maximumLimitReached {
                errorMessage = "iOS won't allow any more scheduled alarms right now."
                break
            } catch {
                errorMessage = "Couldn't set the wake alarm: \(error.localizedDescription)"
            }
        }
        wakeAlarmTimes = armed
        defaults.set(armed, forKey: Keys.wakeTimes)
        saveSmartIDs()
    }

    /// From the background calendar refresh (`WakeFollow`): each new alarm is armed BEFORE the
    /// one it stands in for is cancelled, so a pass that is cut short part-way can leave a day
    /// with two alarms and never with none. Only when already authorized (nothing can be asked
    /// from the background), and only when the bookkeeping pairs every id with its time.
    /// - Returns: how many alarms were armed.
    @discardableResult
    func applyInBackground(_ changes: [WakeFollow.Change]) async -> Int {
        guard DeviceRole.current.isHub, !changes.isEmpty,
              manager.authorizationState == .authorized,
              smartAlarmIDs.count == wakeAlarmTimes.count else { return 0 }
        var ids = smartAlarmIDs
        var times = wakeAlarmTimes
        var armed = 0
        for change in changes {
            let id = UUID()
            let title = "Wake \u{00B7} \(change.new.formatted(.dateTime.hour().minute()))"
            do {
                _ = try await manager.schedule(id: id, configuration: makeFixedConfiguration(id: id, fire: change.new, title: title))
            } catch {
                Log.wake.error("background wake: couldn't arm \(change.new, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            armed += 1
            if let old = change.replacing, let index = times.firstIndex(of: old) {
                try? manager.cancel(id: ids[index])
                ids[index] = id
                times[index] = change.new
            } else {
                ids.append(id)
                times.append(change.new)
            }
            // After each one, so a pass cut short has recorded what it did.
            let order = times.indices.sorted { times[$0] < times[$1] }
            smartAlarmIDs = order.map { ids[$0] }
            wakeAlarmTimes = order.map { times[$0] }
            ids = smartAlarmIDs
            times = wakeAlarmTimes
            defaults.set(wakeAlarmTimes, forKey: Keys.wakeTimes)
            saveSmartIDs()
        }
        return armed
    }

    // MARK: - One-off alarms (ad-hoc, from Today)

    /// Set a one-shot alarm at `fire`. On the phone it's armed first; returns false (and sets
    /// `errorMessage`) if the time is in the past, permission is denied, or the system limit is
    /// hit. On an iPad it's only added to the synced list, and the phone arms it when it syncs.
    @discardableResult
    func addOneOff(at fire: Date, label: String) async -> Bool {
        pruneExpiredOneOffs()
        guard fire > Date() else { errorMessage = "Pick a time in the future."; return false }
        let alarm = OneOffAlarm(fire: fire, label: label)
        if DeviceRole.current.isHub {
            guard await ensureAuthorized() else { return false }
            do {
                _ = try await manager.schedule(id: alarm.id, configuration: makeFixedConfiguration(id: alarm.id, fire: fire, title: alarm.title))
            } catch AlarmManager.AlarmError.maximumLimitReached {
                errorMessage = "iOS won't allow any more scheduled alarms right now."
                return false
            } catch {
                errorMessage = "Couldn't set the alarm: \(error.localizedDescription)"
                return false
            }
        }
        oneOffAlarms = OneOffAlarmList.adding(alarm, to: oneOffAlarms)
        saveOneOffs()
        onOneOffChange?()
        ControlChangeReporter.changed(.alarm, alarm.id.uuidString)
        reportArmedOneOffs()
        return true
    }

    /// - Returns: the alarm that was cancelled, for `restoreOneOff` (Undo).
    @discardableResult
    func cancelOneOff(_ id: UUID) -> OneOffAlarm? {
        if DeviceRole.current.isHub { try? manager.cancel(id: id) }
        guard let alarm = oneOffAlarms.first(where: { $0.id == id }) else { return nil }
        oneOffAlarms.removeAll { $0.id == id }
        saveOneOffs()
        onOneOffChange?()
        ControlChangeReporter.deleted(.alarm, id.uuidString)
        reportArmedOneOffs()
        return alarm
    }

    /// Brings back a cancelled alarm (Undo): the same alarm, listed where it was and, on the
    /// phone, armed again. Never asks for permission; without it the alarm is listed, as one
    /// from another device is. Returns what went wrong, or nil.
    func restoreOneOff(_ alarm: OneOffAlarm) async -> String? {
        guard alarm.fire > Date() else { return "its time has passed" }
        if DeviceRole.current.isHub, manager.authorizationState == .authorized {
            do {
                _ = try await manager.schedule(id: alarm.id, configuration: makeFixedConfiguration(id: alarm.id, fire: alarm.fire, title: alarm.title))
            } catch {
                return error.localizedDescription
            }
        }
        oneOffAlarms = OneOffAlarmList.adding(alarm, to: oneOffAlarms)
        saveOneOffs()
        onOneOffChange?()
        ControlChangeReporter.changed(.alarm, alarm.id.uuidString)
        reportArmedOneOffs()
        return nil
    }

    /// The phone: arm each listed alarm that isn't armed yet — added on the iPad or the Mac, or
    /// changed there. Never asks for permission: this runs on a sync, not on a tap, so without
    /// permission it leaves them listed and says so in its status.
    func armOneOffsFromOtherDevices() async {
        guard DeviceRole.current.isHub, manager.authorizationState == .authorized else {
            reportArmedOneOffs()
            return
        }
        let live = Set(((try? manager.alarms) ?? []).map(\.id))
        let now = Date()
        for alarm in oneOffAlarms where alarm.fire > now && !live.contains(alarm.id) {
            do {
                _ = try await manager.schedule(id: alarm.id, configuration: makeFixedConfiguration(id: alarm.id, fire: alarm.fire, title: alarm.title))
            } catch {
                Log.wake.error("couldn't arm an alarm set on another device: \(error.localizedDescription, privacy: .public)")
            }
        }
        reportArmedOneOffs()
    }

    /// Which of the listed alarms the phone has armed, for the lists on the iPad and the Mac.
    private func reportArmedOneOffs() {
        guard DeviceRole.current.isHub else { return }
        let live = Set(((try? manager.alarms) ?? []).map(\.id))
        let armed = oneOffAlarms.map(\.id).filter(live.contains)
        HubStatusStore.shared.update { $0.armedAlarms = armed }
    }

    /// Drop (and cancel) any one-off alarms whose time has passed — they've fired.
    func pruneExpiredOneOffs() {
        let now = Date()
        let expired = oneOffAlarms.filter { $0.fire <= now }
        guard !expired.isEmpty else { return }
        for a in expired { try? manager.cancel(id: a.id) }
        oneOffAlarms.removeAll { $0.fire <= now }
        saveOneOffs()
        onOneOffChange?()
    }

    private func makeFixedConfiguration(id: UUID, fire: Date, title: String) -> AlarmManager.AlarmConfiguration<BananaMetadata> {
        let schedule = Alarm.Schedule.fixed(fire)
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            secondaryButton: AlarmButton(text: "Open", textColor: .white, systemImageName: "arrow.up.forward.app"),
            secondaryButtonBehavior: .custom)
        let attributes = BananaAlarmAttributes(presentation: AlarmPresentation(alert: alert),
                                                 metadata: BananaMetadata(), tintColor: .orange)
        return AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule, attributes: attributes,
            stopIntent: WakeStopIntent(alarmID: id.uuidString),
            secondaryIntent: WakeOpenIntent(), sound: .default)
    }

    func cancelSmartWakes() {
        for id in smartAlarmIDs { try? manager.cancel(id: id) }
        smartAlarmIDs = []
        wakeAlarmTimes = []   // keep the diff's mirror honest: nothing armed → nothing recorded
        defaults.set([Date](), forKey: Keys.wakeTimes)
        saveSmartIDs()
    }

    private func saveSmartIDs() {
        if let data = try? JSONEncoder().encode(smartAlarmIDs) {
            defaults.set(data, forKey: Keys.smartIDs)
        }
    }

    private static func localeWeekday(_ component: Int) -> Locale.Weekday {
        switch component {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        default: return .saturday
        }
    }

    // MARK: - Authorization

    private func ensureAuthorized() async -> Bool {
        // Alarms ring on the phone (and its Watch). An iPad has AlarmKit too, but arming there
        // would ring a second set; every schedule path asks here first, so this is the one check.
        guard DeviceRole.current.isHub else { return false }
        switch manager.authorizationState {
        case .authorized:
            authorization = .authorized
            return true
        case .denied:
            authorization = .denied
            errorMessage = "Alarm permission is off. Enable it for Banana in Settings."
            return false
        case .notDetermined:
            do {
                let state = try await manager.requestAuthorization()
                authorization = state
                if state != .authorized {
                    errorMessage = "Banana needs alarm permission to wake you up."
                }
                return state == .authorized
            } catch {
                errorMessage = "Couldn't request alarm permission: \(error.localizedDescription)"
                return false
            }
        @unknown default:
            return false
        }
    }

    private func refreshAuthorization() async {
        #if DEBUG
        if auditAuthorized { return }
        #endif
        authorization = manager.authorizationState
    }

    /// Returns true once if an alarm rang within the last 10 minutes and hasn't
    /// been acted on yet — used to auto-start the wake podcast when the app opens.
    func consumeRecentAlarm() -> Bool {
        guard let last = lastAlertAt else {
            Log.wake.notice("consumeRecentAlarm: no recent alarm recorded (lastAlertAt nil)")
            return false
        }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed < 600 else {
            Log.wake.notice("consumeRecentAlarm: last alarm \(Int(elapsed))s ago (>600s) — ignoring")
            return false
        }
        guard consumedAlertAt != last else {
            Log.wake.notice("consumeRecentAlarm: already consumed this alarm")
            return false
        }
        consumedAlertAt = last
        defaults.set(consumedAlertAt, forKey: Keys.consumedAlert)   // relaunch inside the window must not re-fire
        Log.wake.notice("consumeRecentAlarm: OK (\(Int(elapsed))s since alarm)")
        return true
    }

    private func observeAlarms() {
        Task { [weak self] in
            guard let updates = self?.manager.alarmUpdates else { return }
            for await alarms in updates {
                self?.updateAlerting(from: alarms)
            }
        }
    }

    private func updateAlerting(from alarms: [Alarm]) {
        let alerting = alarms.contains { $0.state == .alerting }
        if alerting && !isAlerting {
            lastAlertAt = Date()
            defaults.set(lastAlertAt, forKey: Keys.lastAlert)   // survive a relaunch within the window
            Log.wake.notice("alarm entered alerting state — recorded lastAlertAt")
        }
        // `alarmUpdates` fires once per daemon change even when the value doesn't move — the
        // launch-time wake re-arm alone can push ~40 same-value publishes. Both RootView and
        // WeekView observe this store, so an unconditional assign re-renders the whole shell and
        // the day grid on every one of them (see the WeekView CPU-storm evidence). Guard so a
        // same-value publish never fires.
        if isAlerting != alerting { isAlerting = alerting }
    }

    private func observeAuthorization() {
        Task { [weak self] in
            guard let updates = self?.manager.authorizationUpdates else { return }
            for await state in updates {
                // The live AlarmKit stream bypasses refreshAuthorization()'s guard entirely, so
                // guarding only there left the seed to be overwritten a moment after launch — the
                // card kept coming back. Every writer has to respect the audit flag, not just the
                // one that looked like the obvious source.
                #if DEBUG
                if self?.auditAuthorized == true { continue }
                #endif
                self?.authorization = state
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        lastAlertAt = defaults.object(forKey: Keys.lastAlert) as? Date
        consumedAlertAt = defaults.object(forKey: Keys.consumedAlert) as? Date
        manualSuspended = defaults.bool(forKey: Keys.manualSuspended)
        if let data = defaults.data(forKey: Keys.smartIDs),
           let decoded = try? JSONDecoder().decode([UUID].self, from: data) {
            smartAlarmIDs = decoded
        }
        // The armed-wake mirror persists so the re-arm DIFF survives relaunch: the daemon keeps
        // the alarms armed across our process's death, and without this line every cold launch
        // saw an empty mirror and paid the full ~40-XPC cancel+re-arm for an unchanged set.
        if let times = defaults.array(forKey: Keys.wakeTimes) as? [Date] {
            wakeAlarmTimes = times
        }
        if let raw = defaults.array(forKey: Keys.enabled) as? [Int] {
            enabled = Set(raw)
        }
        if let data = defaults.data(forKey: Keys.idMap),
           let decoded = try? JSONDecoder().decode([Int: UUID].self, from: data) {
            idMap = decoded
        }
        if let data = defaults.data(forKey: Keys.oneOff),
           let decoded = try? JSONDecoder().decode([OneOffAlarm].self, from: data) {
            oneOffAlarms = decoded.filter { $0.fire > Date() }   // drop any that already fired
        }
    }

    private func saveOneOffs() {
        if let data = try? JSONEncoder().encode(oneOffAlarms) {
            defaults.set(data, forKey: Keys.oneOff)
        }
    }

    private func persist() {
        defaults.set(Array(enabled), forKey: Keys.enabled)
        if let data = try? JSONEncoder().encode(idMap) {
            defaults.set(data, forKey: Keys.idMap)
        }
    }
}

// One-off alarms are one list on every device (CloudControlsSync); only the phone rings them.
extension AlarmStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        OneOffAlarmList.cloudItems(oneOffAlarms)
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return true }
        let alarm = item.flatMap { try? JSONDecoder().decode(OneOffAlarm.self, from: $0) }
        if item != nil, alarm == nil { return true }   // a newer build's alarm this one can't read
        let previous = oneOffAlarms.first { $0.id == uuid }
        let next = OneOffAlarmList.applying(alarm, id: uuid, to: oneOffAlarms, now: Date())
        guard next != oneOffAlarms else { return true }
        // Moved, relabelled or deleted elsewhere: whatever the phone armed for it goes; the arm
        // pass below arms the new version.
        if DeviceRole.current.isHub, previous != nil { try? manager.cancel(id: uuid) }
        oneOffAlarms = next
        saveOneOffs()
        onOneOffChange?()
        Task { await armOneOffsFromOtherDevices() }
        return true
    }
}
#endif
