import Foundation
import Combine
import CoreLocation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// The unified timeline. Merges the three occurrence producers (authored cues, derived
/// blocks, external calendar events) across a rolling horizon into one sorted list, and
/// (later) drives write-back and arming. Modeled on `SmartScheduleStore.recompute()`.
@MainActor
final class OccurrenceStore: ObservableObject {
    static let shared = OccurrenceStore()

    @Published private(set) var occurrences: [Occurrence] = [] {
        didSet {
            rangeIndex = nil
            // Build once per snapshot. Event rendering must not scan retained history for
            // each outbound/return band, especially when the history contains no travel.
            var outbound: [(date: Date, value: Occurrence)] = []
            var inbound: [(date: Date, value: Occurrence)] = []
            for item in occurrences where item.behavior == .block {
                if item.title.hasPrefix("Travel to ") { outbound.append((item.resolvedEnd, item)) }
                if item.title == "Travel home" { inbound.append((item.start, item)) }
            }
            outboundTravelIndex = MinuteMatchIndex(outbound)
            returnTravelIndex = MinuteMatchIndex(inbound)
        }
    }
    private var rangeIndex: TimeRangeIndex<Occurrence>?
    private var outboundTravelIndex = MinuteMatchIndex<Occurrence>()
    private var returnTravelIndex = MinuteMatchIndex<Occurrence>()

    func outboundTravel(endingAt date: Date) -> Occurrence? { outboundTravelIndex.first(near: date) }
    func returnTravel(startingAt date: Date) -> Occurrence? { returnTravelIndex.first(near: date) }

    private func indexedOccurrences(from start: Date, to end: Date) -> [Occurrence] {
        if rangeIndex == nil {
            rangeIndex = TimeRangeIndex(occurrences, start: \.start, end: { occurrence in
                // Untimed reminders are points belonging to the day of their start.
                occurrence.hasScheduledTime ? occurrence.resolvedEnd
                    : Date(timeIntervalSinceReferenceDate: occurrence.start.timeIntervalSinceReferenceDate.nextUp)
            })
        }
        return rangeIndex!.overlapping(from: start, to: end)
    }

    /// Takes an all-day event off what's shown at once, by title (`AllDayHiding`); the read the
    /// settings change starts leaves it out from then on.
    func hideAllDay(titleKey: String) {
        occurrences.removeAll { $0.behavior == .allDay && AllDayEvents.titleKey($0.title) == titleKey }
        for (key, entry) in planningWindows {
            guard let allDay = entry.googleAllDay,
                  allDay.contains(where: { AllDayEvents.titleKey($0.title) == titleKey }) else { continue }
            var next = entry
            next.googleAllDay = allDay.filter { AllDayEvents.titleKey($0.title) != titleKey }
            publishPlanningWindow(next, key: key)
        }
    }

    /// Shows an event Busy or Free at once, before Google has answered (`AllDayBlocking`); the
    /// next read replaces it with what Google holds.
    func showAvailability(eventID: String, busy: Bool) {
        for index in occurrences.indices where occurrences[index].meeting?.eventID == eventID {
            occurrences[index].meeting?.showsAsFree = !busy
        }
    }

    /// Events the user has created that no calendar has confirmed yet.
    ///
    /// Deliberately NOT merged into `occurrences`: that list is snapshotted for first paint, and a
    /// placeholder baked into it would return on the next launch looking like a real event, beside
    /// the pending store's own copy. Placeholders are overlaid in `planningWindow(from:to:)`, which
    /// is what the calendar grids read.
    let pendingWrites = PendingCalendarWriteStore()
    /// Identity and state of the pending set at the last publish, so a change in it republishes
    /// even when the timeline itself is byte-identical.
    private var lastPendingSignature = ""
    /// Edits sent to Google and not yet read back, drawn as edited (`PendingEventEditStore`).
    let pendingEdits = PendingEventEditStore()
    /// The occurrences an edit is drawn over, as read — what comes back if the save fails.
    private var editOriginals: [AppItemID: Occurrence] = [:]

    @Published private(set) var planningWindowRevision = 0
    #if DEBUG
    /// Hardware regression probe for a large-calendar timing race. Production never increments it.
    @Published private(set) var performanceRecomputeCount = 0
    #endif

    // MARK: - First-paint snapshot (stale-while-revalidate)
    //
    // The timeline used to start EMPTY every launch — "Your day" was a blank card until the
    // first recompute finished. The last computed list persists (display only!) and loads
    // instantly; `lastComputed` stays nil so the staleness path still runs a fresh recompute,
    // which replaces it within seconds. Alarm arming and calendar write-back happen ONLY in
    // recompute(), never off the snapshot.

    private static let snapshotURL: URL = {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("occurrences-snapshot.json")
    }()
    private var lastSnapshotData: Data?

    // MARK: - Shared planning-window cache

    /// Week navigation is display-only, just like the first-paint occurrence snapshot. Keep its
    /// bounded windows here instead of in platform views so Mac and iPhone load, reconcile, and
    /// persist the same data in the same order.
    private struct PlanningWindowEntry: Codable {
        let start: Date
        let end: Date
        var base: [Occurrence]
        var localMeetings: [MeetingInfo]
        var googleMeetings: [MeetingInfo]
        var localExtras: [Occurrence]
        /// Travel blocks another device wrote, recovered from the Google calendars.
        var googleExtras: [Occurrence] = []
        /// All-day events (`AllDayEvents`). Optional so a cache written before them still reads.
        var googleAllDay: [MeetingInfo]?
        var localUpdatedAt: Date?
        var googleUpdatedAt: Date?

        var mostRecentUpdate: Date {
            max(localUpdatedAt ?? .distantPast, googleUpdatedAt ?? .distantPast)
        }
    }

    private struct PlanningWindowCacheFile: Codable {
        let version: Int
        let entries: [PlanningWindowEntry]
    }

    /// 2: meetings come only from Google; version 1 caches carried Apple Calendar copies that
    /// would duplicate them until replaced.
    private static let planningWindowCacheVersion = 2
    private static let maxPersistedPlanningWindows = 12
    #if DEBUG
    /// Launch-only latency injection for exercising stale-while-revalidate on hardware.
    /// Release builds cannot delay providers, and invalid values leave normal behavior unchanged.
    private static var simulatedPlanningProviderDelayMilliseconds: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--simulate-planning-provider-delay-ms"),
              arguments.indices.contains(flag + 1),
              let value = Int(arguments[flag + 1]),
              value > 0 else { return nil }
        return min(value, 30_000)
    }
    #endif
    private static let planningWindowCacheURL: URL = {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("planning-windows.json")
    }()
    private var planningWindows: [String: PlanningWindowEntry] = [:]
    private var planningWindowTasks: [String: Task<Void, Never>] = [:]
    private var planningWindowCacheWriteTask: Task<Void, Never>?

    #if DEBUG
    /// `--redraw-churn`: the store republishes several times a second, as a live phone's
    /// calendar refreshes and recomputes do — the condition the time picker broke under, which a
    /// quiet screenshot route never has.
    private var churnTimer: Timer?
    private func startChurnIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--redraw-churn") else { return }
        churnTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { OccurrenceStore.shared.planningWindowRevision &+= 1 }
        }
    }
    #endif

    /// Redraws everything reading the day when an Undo window opens or closes
    /// (`ToastCenter.hiddenIDs`): what `occurrences(on:)` leaves out has changed.
    private var hiddenWatch: AnyCancellable?

    private init() {
        #if DEBUG
        defer { startChurnIfRequested() }
        #endif
        defer {
            hiddenWatch = ToastCenter.shared.$hiddenIDs.dropFirst().removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.planningWindowRevision &+= 1
                }
        }
        // Synchronous, deliberately: the snapshot is bounded (a 31-day horizon is under a
        // thousand occurrences — tens of KB, single-digit milliseconds) and loading it inline
        // means the FIRST frame already shows the day. The async version painted an empty "Your day" card
        // that popped ~100 ms later — cheaper on paper, worse to look at.
        if let data = try? Data(contentsOf: Self.snapshotURL),
           let decoded = try? JSONDecoder().decode([Occurrence].self, from: data) {
            lastSnapshotData = data
            occurrences = decoded
            byDay = Dictionary(grouping: decoded) { Calendar.current.startOfDay(for: $0.start) }
            LaunchClock.mark("occurrences.snapshot")
        }
        if let data = try? Data(contentsOf: Self.planningWindowCacheURL),
           let decoded = try? JSONDecoder().decode(PlanningWindowCacheFile.self, from: data),
           decoded.version == Self.planningWindowCacheVersion {
            planningWindows = Dictionary(
                uniqueKeysWithValues: decoded.entries
                    .filter { $0.end > $0.start }
                    .map { (Self.planningWindowKey(from: $0.start, to: $0.end), $0) }
            )
            LaunchClock.mark("planningWindows.snapshot")
        }
    }

    private func saveSnapshot(_ data: Data) {
        let url = Self.snapshotURL
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func savePlanningWindowCache() {
        let entries = planningWindows.values
            .sorted { $0.mostRecentUpdate > $1.mostRecentUpdate }
            .prefix(Self.maxPersistedPlanningWindows)
        guard let data = try? JSONEncoder().encode(PlanningWindowCacheFile(
            version: Self.planningWindowCacheVersion,
            entries: Array(entries)
        )) else { return }
        let url = Self.planningWindowCacheURL
        let previousWrite = planningWindowCacheWriteTask
        planningWindowCacheWriteTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            try? data.write(to: url, options: .atomic)
        }
    }

    weak var routines: RoutineStore?
    weak var smart: SmartScheduleStore?
    weak var alarms: AlarmStore?
    weak var health: HealthKitStore?
    /// Read for the event-notification lead time. Weak and optional like the rest: a headless
    /// background launch wires none of these, and must still recompute.
    weak var settings: AppSettings?

    /// Apple Reminders reader (wraps the shared authorization; no new prompt).
    private let reminders = RemindersService()

    /// Whether Apple Reminders is readable. A stored `@Published` mirror, not a computed
    /// property: EventKit authorization is not observable, so a computed value never tells
    /// SwiftUI anything changed and the access card stayed on screen after a successful grant
    /// until the app was relaunched.
    @Published private(set) var remindersAuthorized: Bool = RemindersService.isAuthorized

    #if DEBUG
    /// Screenshot seeding only. A simulator has granted nothing, so every permission-gated card
    /// renders in its "not connected" state — which is how three red CTAs ended up being the most
    /// prominent thing on the App Store's first screenshot.
    func markRemindersAuthorizedForAudit() { remindersAuthorized = true }
    #endif

    /// Re-read the recorded status; recompute only when it actually moved. Cheap enough for
    /// every foreground, which is what makes a grant given in Settings self-correct.
    func syncRemindersAuthorization() async {
        let current = reminders.authorized
        guard current != remindersAuthorized else { return }
        remindersAuthorized = current
        await recompute()
    }

    /// Ask for Reminders access from inside the app.
    ///
    /// Onboarding used to be the ONLY caller of `requestAccess`, and it never runs again once
    /// `onboardingCompleted` is set — so declining once, or losing the grant (a reinstall drops
    /// it), left tasks permanently invisible with no way back. iOS won't even list the app under
    /// Settings › Privacy › Reminders while the status is notDetermined, so there was nothing to
    /// toggle there either. The app has to be able to ask.
    @discardableResult
    func requestRemindersAccess() async -> Bool {
        _ = await reminders.requestAccess()
        // Trust the recorded status, and refresh whatever it says. Gating the refresh on the
        // request's return value is what made a granted permission still show "not connected".
        let granted = reminders.authorized
        remindersAuthorized = granted
        await recompute()
        return granted
    }

    /// Rolling materialization horizon (days). 31 so calendar write-back advertises
    /// availability a month out (it mirrors exactly what's materialized here); recompute
    /// and snapshot cost scale linearly with this, so don't raise it casually.
    var horizonDays = 31

    /// Route calculation is network-backed and scales with every located meeting. Widening this
    /// to a month used to make <redacted>'s real-calendar pass take ~31 seconds in the foreground —
    /// but that cost was every located meeting getting a *cold* geocode+ETA on the main actor.
    /// Calendly can book a meeting anywhere inside the 31-day materialization window, so a busy
    /// block (and its travel holds) has to exist that far out or the gap this constant used to
    /// protect just reopens three weeks later. What actually makes the wider horizon affordable:
    /// TravelService caches both geocodes (by address) and routes (by origin→destination→arrival
    /// quarter-hour, 1h TTL) — see TravelService.swift — and the background refresh task (below)
    /// keeps that cache warm every ~2h so a foreground open usually hits it instead of paying for
    /// it cold. CalendarWriteBack's writtenHash ledger separately skips re-writing any block whose
    /// content hasn't changed, so a warm pass touches EventKit only for what actually moved.
    /// Day, Week, and wake planning follow this same widened window; travel *notifications* (the
    /// "leave now" alerts) stay short — see `SmartScheduleStore.commuteHorizonDays`, a separate
    /// constant that was already isolated from this one before this change.
    static let writeBackTravelHorizonDays = 31

    /// When `occurrences` was last fully recomputed, and whether one is in flight. A recompute reads
    /// the whole calendar horizon + Reminders + does write-back — too heavy to run on every view
    /// appearance. Flipping Day↔Week recreates the view each time; without this guard that meant a
    /// full recompute per switch (an empty pane until it finished). Views now render from the cached
    /// `occurrences` immediately and only trigger a recompute when the data has actually aged.
    private(set) var lastComputed: Date?
    private var recomputeTask: Task<Void, Never>?
    private var recomputeAgain = false
    private var pendingTaskCompletions: [String: Bool] = [:]
    /// Repeating reminders to move to the day being ticked before they're completed.
    private var pendingTaskDueMoves: [String: Date] = [:]
    private var taskCompletionFlush: Task<Void, Never>?
    private var taskCompletionReconcile: Task<Void, Never>?
    @Published private(set) var settlingTaskCompletionIDs: Set<String> = []
    private var taskCompletionGeneration = 0

    /// Recompute only if the last one was long enough ago (or we have nothing yet). Cheap no-op
    /// otherwise, so switching views / re-appearing is instant.
    func recomputeIfStale(maxAge: TimeInterval = 45, reason: String = "stale") async {
        if let recomputeTask {
            await recomputeTask.value
            return
        }
        if let last = lastComputed, Date().timeIntervalSince(last) < maxAge, !occurrences.isEmpty { return }
        await recompute(reason: reason)
    }

    /// Coalesced entry point for callback-driven triggers (routine edits, one-off alarm changes,
    /// the smart-plan refresh). A mutation burst — toggling three cues, a replan touching five
    /// series — collapses to ONE recompute instead of one per callback. User-initiated paths
    /// that need a fresh derived result (pull-to-refresh, a context-menu exception) still await
    /// `recompute()` directly. Task completion has its own optimistic, batched path below.
    private var pendingRequest: Task<Void, Never>?

    func requestRecompute(reason: String = "") {
        pendingRequest?.cancel()
        pendingRequest = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Clear the handle before entering recompute(). Otherwise recompute() sees this
            // debounce task as "pending" and cancels the task that is currently calling it.
            // The unstructured recompute child happened to survive that cancellation, but the
            // self-cancel made ordering and future cancellation checks needlessly fragile.
            self?.pendingRequest = nil
            await self?.recompute(reason: reason.isEmpty ? "request" : reason)
        }
    }

    /// Calendar access and account changes invalidate the display-only week windows as well as
    /// the rolling timeline. Without this, a week opened while EventKit was unavailable keeps
    /// rendering its cached empty EventKit slice after access is restored.
    func calendarSourceDidChange() {
        planningWindows.removeAll()
        planningWindowRevision &+= 1
        savePlanningWindowCache()
        requestRecompute(reason: "calendar source changed")
    }

    // MARK: - Recompute

    /// Why the passes still to run were asked for — logged with each pass, so a launch's passes
    /// can be told apart (a request landing mid-pass earns a whole second one).
    private var queuedReasons: [String] = []
    /// How long each part of the last pass took, for the same journal line.
    private var lastPassPhases = ""
    /// The parts of the pass under way finished so far — for the line a stuck pass writes.
    private var currentPassPhases = ""

    /// Milliseconds per part of a recompute pass, in order: "google 5210 · reminders 80 · …".
    /// "shown" is the moment the fresh agenda reaches the screen.
    private struct RecomputePhases {
        private var last = Date()
        private var parts: [String] = []

        mutating func mark(_ name: String) {
            let now = Date()
            parts.append("\(name) \(Int(now.timeIntervalSince(last) * 1000))")
            last = now
        }

        var summary: String { parts.joined(separator: " · ") }
    }

    // MARK: - Reminders due around a moment (docs/design/ANCHORED-TIMING.md)

    /// When a reminder tied to a moment (`ReminderAnchors`) is due today: the day's moments from
    /// `AnchoredTimingHub`, with today's ticks taken from the reminders just read rather than the
    /// last timeline — a tick on the Mac counts here the moment Reminders has it.
    func reminderAnchoring(_ tasks: [TaskInfo], now: Date) -> (TaskInfo, Date) -> AnchoredTiming.Due? {
        let rules = ReminderAnchors.shared
        guard !rules.rules.isEmpty else { return { _, _ in nil } }
        let calendar = Calendar.current
        var signals = AnchoredTimingHub.shared.signals(now: now)
        for task in tasks where task.isCompleted {
            guard let at = task.completedAt, calendar.isDate(at, inSameDayAs: now) else { continue }
            for key in [task.externalID, task.title.lowercased()].compactMap({ $0 }) {
                signals.ticked[key] = signals.ticked[key].map { min($0, at) } ?? at
            }
        }
        let frozen = signals
        return { task, due in
            guard let anchor = rules.anchor(externalID: task.externalID, title: task.title) else { return nil }
            let usual = rules.usualMinutes(externalID: task.externalID, title: task.title)
                .flatMap { calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: due) } ?? due
            return AnchoredTiming.due(anchor, usual: usual, signals: frozen, now: now, calendar: calendar)
        }
    }

    /// Reminders kept agreeing with Banana: a tied reminder's own time noted the first time it's
    /// seen; today's moved to its moment once that comes (and rung, from here — Reminders only
    /// knows its time); any other day put back to its own time (`AnchoredTiming.reminderMove`).
    private func keepRemindersInStep(_ tasks: [TaskInfo], anchoring: (TaskInfo, Date) -> AnchoredTiming.Due?, now: Date) {
        let rules = ReminderAnchors.shared
        guard !rules.rules.isEmpty else { return }
        let calendar = Calendar.current
        for task in tasks where !task.isCompleted && task.hasTime {
            guard let stored = task.due, let anchor = rules.anchor(externalID: task.externalID, title: task.title) else { continue }
            if rules.usualMinutes(externalID: task.externalID, title: task.title) == nil {
                // Seen for the first time since it was tied: before anything moves it.
                rules.setUsual(calendar.component(.hour, from: stored) * 60 + calendar.component(.minute, from: stored),
                               externalID: task.externalID, title: task.title)
            }
            let today = calendar.isDate(stored, inSameDayAs: now) ? anchoring(task, stored) : nil
            guard let target = AnchoredTiming.reminderMove(
                storedDue: stored, hasTime: true,
                usualMinutes: rules.usualMinutes(externalID: task.externalID, title: task.title),
                today: today, now: now, calendar: calendar) else { continue }
            reminders.reschedule(task.id, to: target)
            let toMoment: Bool
            if case .at(let moment)? = today { toMoment = moment == target } else { toMoment = false }
            if toMoment { Self.ring(task.title, label: AnchoredTiming.label(anchor), at: target, now: now) }
            PlaybackDiagnostics.shared.log("⏱ anchored", "\(task.title): \(toMoment ? "due at its moment" : "back to its own time"), \(target.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    /// A tied reminder due because its moment came: rung from Banana, at once if that was already.
    private static func ring(_ title: String, label: String, at: Date, now: Date) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = label
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let when = max(at, now.addingTimeInterval(2))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
        let id = "banana.reminderAnchor.\(title.lowercased()).\(Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        #endif
    }

    /// A skip or a restore shown at once (`CueSkip`), ahead of the recompute that makes it so.
    /// The grids draw from cached windows, which `withCurrentSkips` brings up to date as they're
    /// read; this publishes the change so they redraw.
    func markSkipped(key: String, _ skipped: Bool) {
        let updated = occurrences.map { occurrence in
            guard occurrence.occurrenceKey == key else { return occurrence }
            var marked = occurrence
            marked.skipped = skipped
            return marked
        }
        occurrences = updated
        byDay = Dictionary(grouping: updated) { Calendar.current.startOfDay(for: $0.start) }
    }

    /// Skips as they stand now, not as of the last recompute: a skip or a restore shows the moment
    /// it's made, on every grid, while the recompute that settles it runs behind.
    private func withCurrentSkips(_ base: [Occurrence]) -> [Occurrence] {
        let overrides = ExceptionStore.shared.overrides
        guard !overrides.isEmpty || base.contains(where: \.skipped) else { return base }
        return base.map { occurrence in
            guard let key = occurrence.occurrenceKey else { return occurrence }
            let skipped = overrides[key] == .skip
            guard occurrence.skipped != skipped else { return occurrence }
            var current = occurrence
            current.skipped = skipped
            return current
        }
    }

    func recompute(reason: String = "direct") async {
        #if DEBUG
        // A visual-audit capture seeded the timeline; a live recompute would paint whatever the
        // build's own stores hold over it moments before the capture.
        if previewPinned { return }
        #endif
        let completionGenerationAtStart = taskCompletionGeneration
        // A refresh must not race ahead of completion writes that are waiting for the burst
        // debounce; otherwise it would briefly paint the old Reminders state over the optimistic
        // checkmark.
        taskCompletionFlush?.cancel()
        taskCompletionFlush = nil
        flushTaskCompletions()
        taskCompletionReconcile?.cancel()
        taskCompletionReconcile = nil

        // A direct refresh supersedes a not-yet-fired debounce. Without this, a smart-plan update
        // could queue a trailing recompute, the launch path would immediately perform the same
        // work, then the debounce would wake 300 ms later and run the EventKit/Reminders/alarm
        // cascade a second time.
        pendingRequest?.cancel()
        pendingRequest = nil
        recomputeAgain = true
        queuedReasons.append(reason)
        if let recomputeTask {
            await recomputeTask.value
            if taskCompletionGeneration == completionGenerationAtStart {
                settlingTaskCompletionIDs = []
            }
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainRecomputeRequests()
        }
        recomputeTask = task
        await task.value
        if taskCompletionGeneration == completionGenerationAtStart {
            settlingTaskCompletionIDs = []
        }
    }

    private func drainRecomputeRequests() async {
        while recomputeAgain {
            recomputeAgain = false
            let reasons = Set(queuedReasons).sorted().joined(separator: ", ")
            queuedReasons.removeAll()
            let started = Date()
            // A pass that hasn't finished after 20 s says how far it got. One on a new iPad never
            // finished, and left no line at all to say where it stopped.
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                let progress = self.currentPassPhases.isEmpty ? "still in the Google read" : self.currentPassPhases
                PlaybackDiagnostics.shared.log("📅 recompute slow", "20 s in — \(reasons) — done so far: \(progress)")
            }
            await performRecompute()
            watchdog.cancel()
            PlaybackDiagnostics.shared.log("📅 recompute",
                                           "\(Int(Date().timeIntervalSince(started) * 1000))ms — \(reasons) — \(lastPassPhases)")
        }
        // No suspension between deciding the queue is empty and clearing the task, so a new
        // request cannot attach to a completed task and get lost.
        recomputeTask = nil
    }

    #if os(iOS)
    /// Entry point for `CalendarWriteBackRefresh`, the `com.boris.banana.calendar.refresh`
    /// BGAppRefreshTask. Runs the same materialization + write-back pass as a foreground
    /// `recompute()`, with the `AppVisibility.isActive` gate explicitly bypassed — see
    /// `performRecompute`'s `bypassForegroundGate` doc comment for why that's safe here and only
    /// here. Deliberately does NOT go through `recompute()`'s debounce/coalescing queue: a
    /// background task gets one bounded execution window and must not wait behind, or be silently
    /// dropped by, an unrelated foreground recompute request landing at the same moment. Any
    /// foreground recompute already in flight is joined first so the two passes can't write to
    /// the calendar ledger concurrently.
    ///
    /// - Returns: the number of calendar blocks actually created or updated this pass, for the
    ///   background task's journal line.
    @discardableResult
    func performBackgroundWriteBack() async -> Int {
        if let recomputeTask {
            await recomputeTask.value
        }
        return await performRecompute(bypassForegroundGate: true)
    }
    #endif

    #if PERFORMANCE_TESTING && os(iOS)
    /// Exercise the planner's real Calendar/Reminders/materialization path on a personal device
    /// without writing busy blockers or arming alarms. The normal recompute path remains unchanged.
    func recomputeReadOnlyForPerformance() async {
        await performRecompute(allowsExternalWrites: false)
    }
    #endif

    /// - Parameter bypassForegroundGate: iOS confines travel routing, calendar write-back, and
    ///   alarm arming to the foreground (see the `AppVisibility.isActive` guards below) because
    ///   that work is heavy and used to run needlessly the instant EventKit fired a background
    ///   change notification. The background calendar-refresh task (`CalendarWriteBackRefresh`)
    ///   is the one legitimate exception — its whole purpose is doing that work while backgrounded
    ///   — so it passes `true` here instead of flipping `AppVisibility` itself, which is a
    ///   process-wide signal other code reads. Alarm arming stays foreground-only either way (see
    ///   the un-bypassed guard right before `armWake` below): AlarmKit scheduling and any future
    ///   notification side effects of recompute must not fire from a background task.
    /// - Returns: the number of calendar blocks `CalendarWriteBack.sync` actually created or
    ///   updated this pass (0 when write-back didn't run, or nothing needed to change).
    @discardableResult
    private func performRecompute(
        allowsExternalWrites: Bool = true,
        bypassForegroundGate: Bool = false
    ) async -> Int {
        let sp = Signpost.begin("recompute")
        var completedFullPass = false
        var writtenBlockCount = 0
        var phases = RecomputePhases() {
            didSet { currentPassPhases = phases.summary }
        }
        currentPassPhases = ""
        defer {
            if completedFullPass { lastComputed = Date() }
            lastPassPhases = phases.summary
            Signpost.end(sp)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slow-occurrence-recompute-regression") {
            performanceRecomputeCount += 1
            /<redacted>'s real pass is ~40 ms; <redacted>'s large calendar held it open for seconds, which
            // let startup, wake-plan, and EventKit callbacks keep extending recomputeAgain.
            try? await Task.sleep(for: .seconds(5))
        }
        #endif
        #if PERFORMANCE_TESTING && os(iOS)
        // A performance build must be incapable of touching a person's calendars, reminders, or
        // alarms—even if an EventKit callback queues a normal recompute beside the explicit
        // read-only scenario call.
        let externalWritesEnabled = allowsExternalWrites
            && !ProcessInfo.processInfo.arguments.contains("--perf-scenario")
        #else
        let externalWritesEnabled = allowsExternalWrites
        #endif
        let now = Date()
        let cal = Calendar.current
        let routineList = routines?.routines ?? RoutineStore.shared.routines
        // Same headless-background fallback as `routineList` above (see `SmartScheduleStore.shared`'s
        // doc comment): settings-derived reads (exclusions, travel, write-back knobs) use this so a
        // background write-back pass respects the user's real settings instead of the all-defaults
        // behavior plain `smart?.` chaining would silently fall back to. The live wake `plan` is left
        // on `smart?.` below — it depends on HealthKit/AlarmKit machinery this background path
        // deliberately doesn't touch, so it's fine for it to simply be absent in that pass.
        let effectiveSmart = smart ?? SmartScheduleStore.shared

        // Wake time per day from the smart plan → times the `.earliestMeeting` cues.
        var wakeByDay: [Date: Date] = [:]
        if let plan = smart?.plan {
            for d in plan.days where d.wake != nil { wakeByDay[cal.startOfDay(for: d.date)] = d.wake }
        }

        // Authored cues, with L2 exceptions applied (skip/reschedule), plus any extras.
        var authored = OccurrenceProducers.authored(routines: routineList, wakeByDay: wakeByDay,
                                                    horizonDays: horizonDays, now: now)
        authored = ExceptionStore.shared.apply(to: authored)
        authored += ExceptionStore.shared.extraOccurrences(routines: routineList)

        var result = authored
        result += OccurrenceProducers.derived(plan: smart?.plan)
        result += OccurrenceProducers.oneOffAlarms(alarms?.oneOffAlarms ?? [])
        let excludedCalendarIDs = effectiveSmart.settings.excludedCalendarIDs
        var existingBusyIntervals: [CalendarBusyInterval] = []
        var travelMeetings: [MeetingInfo] = []
        var travelEvents: [TravelEvent] = []
        var syncedTravelBlocks: [CalendarSyncedTravelBlock] = []
        // Whether every calendar this pass planned from was actually read. Write-back removes
        // nothing unless it was: a calendar that failed to load is not a calendar with no meetings.
        var calendarSourcesHealthy = false

        // External calendar meetings across the horizon. Banana's own blocks are recognised by
        // their Google ownership marker and never come back as meetings.
        let horizonStart = cal.startOfDay(for: now)
        if let horizonEnd = cal.date(byAdding: .day, value: horizonDays, to: horizonStart) {
            let fetch = await GoogleCalendarService.shared.windowFetch(
                from: horizonStart,
                to: horizonEnd,
                excluding: excludedCalendarIDs,
                allDay: effectiveSmart.settings.allDayChoice
            )
            phases.mark("google")
            let window = fetch.window
            // Before `publish` below retires the placeholder of an event this read found.
            refreshPlanningWindows(withMainRead: window, from: horizonStart, to: horizonEnd)
            calendarSourcesHealthy = fetch.isComplete
            let meetings = window.meetings
            travelMeetings = meetings
            travelEvents = window.travelEvents
            syncedTravelBlocks = window.syncedTravelBlocks
            existingBusyIntervals = window.busyIntervals
            result += OccurrenceProducers.external(meetings: meetings)
            result += OccurrenceProducers.allDay(window.allDayEvents)
            // A calendar this read knows nothing new about (it failed and has no saved copy that
            // reaches today) keeps the events already on screen, rather than losing them until a
            // read succeeds. Only when the read was incomplete: a clean read that returns no
            // events for a calendar means it has none.
            if !fetch.isComplete {
                result += Self.carriedOver(from: occurrences, covered: fetch.covered,
                                           keeping: Set(result.map(\.id)),
                                           from: horizonStart, to: horizonEnd)
            }
            // Calendar-bound cues: fire alongside matching events (exceptions applied).
            let bound = OccurrenceProducers.calendarBoundCues(routines: routineList, meetings: meetings)
            result += ExceptionStore.shared.apply(to: bound)

            // A second device recovers these immediately as read-only planner occupancy. They are
            // also the stale-while-revalidate travel view on the calculating device: route lookup
            // below never makes the fresh calendar/reminder agenda wait for the network.
            result += OccurrenceProducers.syncedTravelBlocks(
                Self.validSyncedTravelBlocks(window.syncedTravelBlocks, meetings: window.meetings))
        }

        // Tasks from Apple Reminders (due within the horizon — the predicate is bounded to it).
        // Permission prompts belong to onboarding (or an explicit Settings action). A timeline
        // refresh can run during app startup, before the welcome screen has explained anything.
        if reminders.authorized {
            var tasks = await reminders.dueTasks(within: horizonDays)
            tasks += await reminders.completedTodayTasks()   // keep done tasks visible, checked
            let anchoring = reminderAnchoring(tasks, now: now)
            result += OccurrenceProducers.tasks(tasks, horizonDays: horizonDays, now: now, anchored: anchoring)
            keepRemindersInStep(tasks, anchoring: anchoring, now: now)
        }
        phases.mark("reminders")

        // Publish the no-network result first. Existing synced travel remains in this base list,
        // so refreshing its route never opens a transient hole in either the UI or Re-plan.
        var sorted = await publish(result, calendar: cal)
        phases.mark("shown")
        refreshRecentPlanningWindows()

        #if os(iOS)
        // A visible refresh may finish its bounded EventKit/Reminders read after the person has
        // already left. The cached base timeline is useful, but route networking, hundreds of
        // EventKit reconciliation lookups, and AlarmKit work must wait for foreground — unless
        // this IS the background write-back task, whose entire job is doing that work while
        // backgrounded (see `bypassForegroundGate`'s doc comment above).
        guard bypassForegroundGate || AppVisibility.shared.isActive else { return writtenBlockCount }
        #endif

        // Calculate deterministic travel holds once from the same calendar window. The resulting
        // occurrences (including the return-home leg) drive local display regardless of whether
        // real-calendar write-back is on -- CalendarWriteBack.sync() has its own `enabled` guard
        // that protects the user's actual calendar, so this local computation doesn't need to
        // duplicate that check. Gating on it here used to also suppress on-screen display whenever
        // write-back was off, which is a different concern than "may this write to Calendar.app".
        if externalWritesEnabled {
            let travelCutoff = cal.date(
                byAdding: .day,
                value: Self.writeBackTravelHorizonDays,
                to: horizonStart
            ) ?? horizonStart
            let localTravel = await effectiveSmart.calendarTravelOccurrences(
                meetings: travelMeetings.filter { $0.start < travelCutoff },
                travelEvents: travelEvents.filter { $0.start < travelCutoff },
                fallingBackTo: syncedTravelBlocks.filter { $0.start < travelCutoff }
            )
            if !localTravel.isEmpty {
                let localTravelIDs = Set(localTravel.map(\.id))
                result.removeAll { localTravelIDs.contains($0.id) }
                result += localTravel
                sorted = await publish(result, calendar: cal)
            }
            phases.mark("travel")
        }

        #if os(iOS)
        guard bypassForegroundGate || AppVisibility.shared.isActive else { return writtenBlockCount }
        #endif
        if externalWritesEnabled {
            // Keep availability covered across every included writable calendar. The raw
            // intervals came from the same Google read as the agenda, so Reclaim-style blocker
            // detection does not add another horizon query.
            // Write exclusions are read exclusions PLUS calendars opted out of busy blocks
            // (shared calendars: every app-written block notifies the other members).
            writtenBlockCount = await CalendarWriteBack.shared.sync(
                sorted,
                existingBusyIntervals: existingBusyIntervals,
                excluding: excludedCalendarIDs.union(
                    effectiveSmart.settings.writeBackExcludedCalendarIDs),
                includingShared: effectiveSmart.settings.writeBackSharedCalendarIDs,
                reserveTaskTime: effectiveSmart.settings.reserveTaskTime,
                // An account Google has signed out, a calendar list or a calendar read that
                // failed: each contributes no meetings, which must never be read as "those
                // blocks are unwanted".
                sourcesHealthy: calendarSourcesHealthy
            )
            phases.mark("write-back")

            // Alarm arming (AlarmKit) is a foreground-only side effect even when write-back
            // itself is running in the background — see `bypassForegroundGate`'s doc comment.
            if !bypassForegroundGate {
                await armWake(sorted)
                phases.mark("alarms")
            }
        }
        completedFullPass = true
        return writtenBlockCount
    }

    @discardableResult
    /// Hand the timeline's real calendar events to the notification scheduler.
    ///
    /// Driven from here rather than from the calendar layer because this is the one place that
    /// already knows every event across every connected calendar, deduplicated and in order. The
    /// scheduler fingerprints its input and does nothing when it has not changed, so calling it on
    /// every publish costs a hash rather than a rewrite of the notification queue.
    /// Drop "Travel home" blocks left on the calendar that the schedule has since outgrown.
    ///
    /// Synced travel blocks are drawn whether or not write-back is on, and before the generator
    /// runs — they are how a second device shows travel it never calculated. That also means a
    /// reservation written when the day looked different survives every later refresh: a trip home
    /// booked after a 4pm meeting kept being drawn even once a 4:45 meeting appeared, giving a
    /// "go home" band between two places minutes apart. Outbound blocks are left alone; only a
    /// trip home can be contradicted by what comes next.
    /// Calendar events from the timeline on screen, for calendars an incomplete read has no data
    /// for — so an unreadable calendar shows what it last showed instead of nothing.
    static func carriedOver(from previous: [Occurrence], covered: Set<String>, keeping existing: Set<AppItemID>,
                            from start: Date, to end: Date) -> [Occurrence] {
        previous.filter { occurrence in
            guard occurrence.source == .external, let meeting = occurrence.meeting else { return false }
            return GoogleEventSync.keepsThroughIncompleteRead(
                calendarID: meeting.calendarID, covered: covered, replaced: existing.contains(occurrence.id),
                start: occurrence.start, end: occurrence.end, window: (start, end))
        }
    }

    static func validSyncedTravelBlocks(
        _ blocks: [CalendarSyncedTravelBlock],
        meetings: [MeetingInfo]
    ) -> [CalendarSyncedTravelBlock] {
        let physicalStarts = meetings
            .filter { $0.hasPhysicalLocation }
            .map(\.start)
            .sorted()
        return blocks.filter { block in
            guard block.title == "Travel home" else { return true }
            let next = physicalStarts.first { $0 > block.start }
            return TravelBlockPolicy.syncedReturnHomeIsStillValid(
                blockStart: block.start, blockEnd: block.end, nextMeetingStart: next)
        }
    }

    private func scheduleEventAlerts(from occurrences: [Occurrence]) {
        let leads = settings?.eventAlertLeads ?? EventAlertPlan.defaultLeads
        let candidates = occurrences.compactMap { occurrence -> EventAlertPlan.Candidate? in
            guard occurrence.source == .external, occurrence.behavior == .event,
                  occurrence.hasScheduledTime, !occurrence.skipped else { return nil }
            return EventAlertPlan.Candidate(
                id: occurrence.externalEventID ?? occurrence.id,
                title: occurrence.title,
                start: occurrence.start)
        }
        Task { await NotificationService.scheduleEventAlerts(candidates, leads: leads) }
    }

    /// Repaint after the pending set changes, without recomputing the timeline.
    ///
    /// Overlays placeholders on `occurrences` as well as bumping the planning-window revision,
    /// because different surfaces read different things: the calendar grids go through
    /// `planningWindow(from:to:)`, while the agenda and the debug launch routes read `occurrences`
    /// directly. Missing either one means an event the user just created is drawn nowhere.
    ///
    /// The real timeline is derived from the currently published list rather than from a cached
    /// copy. An earlier version kept its own `lastRealOccurrences`, which was still empty the
    /// first time this ran and republished nothing — blanking the entire grid.
    func pendingWritesDidChange() {
        let calendar = Calendar.current
        let real = occurrences.filter { $0.pendingWriteID == nil }
        let merged = pendingEdits.applied(to: (real + pendingWrites.optimisticOccurrences))
            .sorted { $0.start < $1.start }
        occurrences = merged
        byDay = Dictionary(grouping: merged) { calendar.startOfDay(for: $0.start) }
        planningWindowRevision &+= 1
    }

    /// An edit is drawn at once, before Google has it (`SmartScheduleStore.saveEventEdit`).
    func beginEventEdit(_ edit: PendingEventEdit) {
        pendingEdits.begin(edit)
        eventEditsDidChange()
    }

    /// The save is done (the next read draws the real thing) or failed (what was read comes back).
    func endEventEdit(_ eventID: String) {
        pendingEdits.end(eventID)
        eventEditsDidChange()
    }

    private func eventEditsDidChange() {
        let calendar = Calendar.current
        let restored = occurrences.map { editOriginals[$0.id] ?? $0 }
        rememberEditOriginals(in: restored)
        let overlaid = pendingEdits.applied(to: restored).sorted { $0.start < $1.start }
        occurrences = overlaid
        byDay = Dictionary(grouping: overlaid) { calendar.startOfDay(for: $0.start) }
        planningWindowRevision &+= 1
    }

    private func rememberEditOriginals(in list: [Occurrence]) {
        editOriginals = [:]
        for occurrence in list {
            if let id = occurrence.externalEventID, pendingEdits.edits[id] != nil {
                editOriginals[occurrence.id] = occurrence
            }
        }
    }

    private func publish(_ result: [Occurrence], calendar: Calendar) async -> [Occurrence] {
        let sorted = result.sorted { $0.start < $1.start }
        // Retire any placeholder whose real event has now been read back, BEFORE merging, so a
        // confirmed event is never drawn twice for a frame.
        pendingWrites.reconcile(against: sorted)
        scheduleEventAlerts(from: sorted)
        let encoded = await Task.detached(priority: .utility) {
            try? JSONEncoder().encode(sorted)
        }.value
        // Republish when the timeline changed OR when the set of unconfirmed events did. The
        // second half is not an optimisation detail: on a launch where the timeline is unchanged,
        // the first branch never runs, and events restored from the pending store would be held in
        // memory and drawn nowhere — which is precisely the case they exist to survive.
        let pendingSignature = pendingWrites.pending
            .map { "\($0.id.uuidString)|\($0.state.rawValue)" }
            .joined(separator: ",") + "|" + pendingEdits.signature
        if encoded != lastSnapshotData || pendingSignature != lastPendingSignature {
            lastPendingSignature = pendingSignature
            // `sorted` (real only) is what gets snapshotted; placeholders are overlaid on top for
            // display. Baking one into the first-paint cache would bring it back on the next
            // launch looking like a real event, beside the pending store's own copy.
            rememberEditOriginals(in: sorted)
            let merged = pendingEdits.applied(to: sorted + pendingWrites.optimisticOccurrences)
                .sorted { $0.start < $1.start }
            occurrences = merged
            byDay = Dictionary(grouping: merged) { calendar.startOfDay(for: $0.start) }
            if let encoded, encoded != lastSnapshotData {
                lastSnapshotData = encoded
                saveSnapshot(encoded)
            }
        }
        return sorted
    }

    /// Arm the wake alarm from the wake cue's occurrences (per-day one-shots that honor
    /// skip/move exceptions). Only while Smart Schedule is on; otherwise SmartScheduleStore
    /// owns the manual-slot alarms.
    private func armWake(_ currentOccurrences: [Occurrence]) async {
        guard let alarms else { return }
        guard smart?.settings.enabled == true else { return }
        let list = routines?.routines ?? RoutineStore.shared.routines
        let wakeIDs = Set(list.filter { $0.triggerKind == .earliestMeeting && $0.enabled }.map(\.id))
        guard !wakeIDs.isEmpty else { await alarms.scheduleWakeOccurrences([]); return }
        let cal = Calendar.current
        let now = Date()
        // Only arm on days the plan actually wants a wake (skip the nominal display fallback).
        let wakeDays = Set((smart?.plan?.days ?? []).filter { $0.wake != nil }.map { cal.startOfDay(for: $0.date) })
        let dates = currentOccurrences
            .filter { $0.behavior == .cue && !$0.skipped && ($0.routineID.map(wakeIDs.contains) ?? false) }
            .map(\.start)
            .filter { $0 > now && wakeDays.contains(cal.startOfDay(for: $0)) }
            .sorted()
        await alarms.scheduleWakeOccurrences(Array(dates.prefix(20)))
    }

    /// Tick one instance of a reminder. For a repeating one that's the day ticked: the reminder is
    /// moved to that day in Reminders first, so completing it marks that day done and Reminders
    /// moves on to the next. Ticking the reminder as a whole completed whatever instance Reminders
    /// held — yesterday's, when that one was missed — and today's then came due already late.
    func toggleTask(_ occurrence: Occurrence) {
        guard let id = occurrence.reminderID else { return }
        guard occurrence.id.hasPrefix("task:\(id):"), !occurrence.completed,
              let due = occurrence.schedule.constraints?.deadline else {
            return toggleTask(reminderID: id)
        }
        pendingTaskDueMoves[id] = due
        completeTask(reminderID: id, completed: true, onlyOccurrence: occurrence.id)
    }

    /// Toggle from the store's current optimistic state, not a row's captured value. That keeps
    /// repeated taps on the same reminder correct even when they land before SwiftUI's next frame.
    func toggleTask(reminderID: String) {
        guard let current = occurrences.first(where: { $0.reminderID == reminderID })?.completed
        else { return }
        completeTask(reminderID: reminderID, completed: !current)
    }

    /// Mark a task complete immediately in the visible timeline, then coalesce the EventKit commit
    /// and expensive full reconciliation across the whole tap burst.
    /// `onlyOccurrence`: one instance of a repeating reminder — the others aren't done.
    func completeTask(reminderID: String, completed: Bool = true, onlyOccurrence: String? = nil) {
        taskCompletionGeneration += 1
        settlingTaskCompletionIDs.insert(reminderID)
        var updated = occurrences
        var changed = false
        for index in updated.indices where updated[index].reminderID == reminderID
            && (onlyOccurrence == nil || updated[index].id == onlyOccurrence) {
            guard updated[index].completed != completed else { continue }
            updated[index].completed = completed
            // Ticked now: what's due after it can be due from now, before Reminders says so.
            updated[index].completedAt = completed ? Date() : nil
            changed = true
        }
        if changed {
            occurrences = updated
            byDay = Dictionary(grouping: updated) {
                Calendar.current.startOfDay(for: $0.start)
            }
        }

        pendingTaskCompletions[reminderID] = completed
        scheduleTaskCompletionFlush()
    }

    private func scheduleTaskCompletionFlush() {
        taskCompletionFlush?.cancel()
        taskCompletionFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            taskCompletionFlush = nil
            flushTaskCompletions()
        }

        taskCompletionReconcile?.cancel()
        taskCompletionReconcile = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            taskCompletionReconcile = nil
            await recompute()
        }
    }

    private func flushTaskCompletions() {
        guard !pendingTaskCompletions.isEmpty else { return }
        let changes = pendingTaskCompletions
        pendingTaskCompletions.removeAll(keepingCapacity: true)
        // A repeating reminder ticked for a later day than Reminders holds is moved to it first.
        for (id, due) in pendingTaskDueMoves where changes[id] == true {
            reminders.moveDue(id, to: due)
        }
        pendingTaskDueMoves.removeAll()
        _ = reminders.setCompleted(changes)
    }

    func taskCompletionIsSettling(_ reminderID: String?) -> Bool {
        reminderID.map(settlingTaskCompletionIDs.contains) ?? false
    }

    /// Change a task's due date (writes back to Reminders), then refresh.
    func rescheduleTask(reminderID: String, to newDue: Date) async {
        reminders.reschedule(reminderID, to: newDue)
        await recompute()
    }

    /// Create a reminder-backed task from Banana, record its scheduling duration, then refresh.
    /// If it has a time and calendar write-back is enabled, this recompute also creates its block.
    @discardableResult
    func createTask(
        title: String,
        due: Date,
        hasTime: Bool,
        durationMinutes: Int,
        listID: String? = nil,
        notes: String? = nil,
        priority: Int = 0,
        recurrence: CalendarItemRecurrence = .never
    ) async throws -> String {
        let created = try await reminders.createTask(
            title: title,
            due: due,
            hasTime: hasTime,
            listID: listID,
            notes: notes,
            priority: priority,
            recurrence: recurrence
        )
        TaskDurationStore.shared.set(
            created.id,
            externalID: created.externalID,
            minutes: durationMinutes
        )
        requestRecompute(reason: "task created")
        return created.id
    }

    /// Every calendar a new event can be created in.
    var writableEventCalendars: [CalendarSourceInfo] {
        GoogleCalendarService.shared.writableCalendarInfos
    }

    var writableReminderLists: [RemindersService.ReminderListInfo] {
        reminders.writableLists()
    }

    func editableTask(_ reminderID: String) -> RemindersService.EditableTask? {
        reminders.editableTask(reminderID)
    }

    func updateTask(
        reminderID: String,
        title: String,
        due: Date,
        hasTime: Bool,
        durationMinutes: Int,
        listID: String?,
        notes: String?,
        priority: Int,
        recurrence: CalendarItemRecurrence
    ) async throws {
        let updated = try reminders.updateTask(
            reminderID,
            title: title,
            due: due,
            hasTime: hasTime,
            listID: listID,
            notes: notes,
            priority: priority,
            recurrence: recurrence
        )
        if updated.id != reminderID {
            TaskDurationStore.shared.set(reminderID, minutes: nil)
        }
        TaskDurationStore.shared.set(
            updated.id,
            externalID: updated.externalID,
            minutes: durationMinutes
        )
        await recompute()
    }

    /// Frequent event shapes for authoring autocomplete, from six months of Google history.
    /// Cached (memory and disk) so opening the composer never waits on that read.
    func eventAuthoringTemplates() async -> [CalendarEventTemplate] {
        let now = Date()
        let defaults = UserDefaults.standard
        if let cached = templateCache, now.timeIntervalSince(cached.loadedAt) < 10 * 60 {
            return cached.templates
        }
        if let loadedAt = defaults.object(forKey: Self.templateCacheDateKey) as? Date,
           now.timeIntervalSince(loadedAt) < 6 * 60 * 60,
           let data = defaults.data(forKey: Self.templateCacheKey),
           let persisted = try? JSONDecoder().decode([CalendarEventTemplate].self, from: data) {
            templateCache = (loadedAt, persisted)
            return persisted
        }
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .month, value: -6, to: now),
              let end = cal.date(byAdding: .day, value: 14, to: now) else { return [] }
        let google = GoogleCalendarService.shared
        let fetch = await google.windowFetch(from: start, to: end, excluding: [])
        let templates = CalendarEventTemplate.build(
            from: fetch.window.meetings,
            writableCalendarIDs: Set(google.writableCalendarInfos.map(\.id)))
        guard fetch.isComplete || !templates.isEmpty else { return templateCache?.templates ?? [] }
        templateCache = (now, templates)
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: Self.templateCacheKey)
            defaults.set(now, forKey: Self.templateCacheDateKey)
        }
        return templates
    }

    private var templateCache: (loadedAt: Date, templates: [CalendarEventTemplate])?
    // Distinct from the Apple Calendar era's keys, whose templates named Apple calendar ids.
    private static let templateCacheKey = "eventAuthoringTemplates.google.v1"
    private static let templateCacheDateKey = "eventAuthoringTemplatesLoadedAt.google.v1"

    @discardableResult
    func createCalendarEvent(
        input: CalendarEventInput,
        calendarID: String?
    ) async throws -> String {
        let id = try await writeCalendarEvent(input: input, calendarID: calendarID)
        requestRecompute(reason: "calendar event created")
        return id
    }

    private func writeCalendarEvent(
        input: CalendarEventInput,
        calendarID: String?
    ) async throws -> String {
        let google = GoogleCalendarService.shared
        // No calendar chosen means the default: the primary calendar of a connected account.
        guard let target = calendarID.flatMap({ GoogleCalendarService.isGoogleCalendarInfoID($0) ? $0 : nil })
                ?? google.writableCalendarInfos.first(where: \.isDefault)?.id
                ?? google.writableCalendarInfos.first?.id else {
            throw CalendarEventCreationError.noDefaultCalendar
        }
        return try await google.createEvent(input, calendarInfoID: target)
    }

    /// Create an event and show it straight away, rather than after the write, the debounce and a
    /// full recompute have all finished — which for a Google calendar means a network round trip
    /// before the event even exists to read back.
    ///
    /// Returns as soon as the intent is recorded, so the composer can close immediately. The write
    /// happens behind that. If it fails, the event is not lost and no error is thrown into a sheet
    /// that has already gone: it stays on the grid marked as failed, carrying everything the user
    /// typed, and can be retried or discarded from there.
    func createCalendarEventOptimistically(input: CalendarEventInput, calendarID: String?) {
        let ticket = pendingWrites.enqueue(input: input, calendarID: calendarID)
        pendingWritesDidChange()
        Task { @MainActor [weak self] in
            await self?.performPendingWrite(ticket)
        }
    }

    /// Retry a write that failed. Same path as the original attempt, so there is one place where
    /// an event actually reaches a calendar.
    func retryPendingWrite(_ ticket: UUID) {
        guard pendingWrites.entry(ticket) != nil else { return }
        pendingWrites.markRetrying(ticket)
        pendingWritesDidChange()
        Task { @MainActor [weak self] in
            await self?.performPendingWrite(ticket)
        }
    }

    func discardPendingWrite(_ ticket: UUID) {
        pendingWrites.discard(ticket)
        pendingWritesDidChange()
    }

    private func performPendingWrite(_ ticket: UUID) async {
        guard let entry = pendingWrites.entry(ticket) else { return }
        do {
            let remoteID = try await writeCalendarEvent(input: entry.input,
                                                        calendarID: entry.calendarID)
            pendingWrites.markWritten(ticket, remoteID: remoteID)
            pendingWritesDidChange()
            requestRecompute(reason: "calendar event created")
        } catch {
            pendingWrites.markFailed(ticket, error: error)
            pendingWritesDidChange()
        }
    }

    // MARK: - L4 Re-plan

    /// Compute a proposed placement of today's moveable tasks into open time (preview only).
    /// The working window runs from your wake time to bedtime (from the smart plan).
    func replanToday(now: Date = Date()) -> Scheduler.Result {
        let cal = Calendar.current
        let planDay = smart?.plan?.days.first { cal.isDate($0.date, inSameDayAs: now) }

        // A plan day's `bedtime` is that day's WAKE minus a night's sleep — so it's the bedtime
        // that came *before* that morning: last night, already in the past. Passing it in as the
        // end of today's working window closed the window before it opened, and Re-plan told you
        // it was past your bedtime at two in the afternoon.
        //
        // Tonight's bedtime is the one that precedes TOMORROW's wake. (NotificationService gets
        // this right by only ever looking at bedtimes still in the future.)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let tonight = smart?.plan?.days.first { cal.isDate($0.date, inSameDayAs: tomorrow) }?.bedtime

        // A workout you've already done is not a workout to book. The cue reads as done from
        // Health (the Watch writes the session through the phone), so drop it from the pool rather
        // than offering to schedule the run you just came back from.
        var today = occurrences(on: now)
        var excluded: [Scheduler.Excluded] = []
        if didWorkoutToday(now: now, calendar: cal) {
            let done = today.filter { $0.behavior == .cue && $0.schedule.moveable }
            excluded = done.map { .init(title: $0.title, reason: "already done today") }
            today.removeAll { $0.behavior == .cue && $0.schedule.moveable }
        }

        var result = Scheduler.replan(occurrences: today, day: now, now: now,
                                      wake: planDay?.wake, bedtime: tonight)
        result.excluded += excluded
        return result
    }

    private func didWorkoutToday(now: Date, calendar cal: Calendar) -> Bool {
        health?.workouts.contains { cal.isDate($0.start, inSameDayAs: now) } ?? false
    }

    /// Apply a re-plan. Tasks are Apple Reminders, so their due date moves in Reminders itself.
    /// A booked cue isn't ours to rewrite wholesale — it's one day's exception to a repeating
    /// series, which is exactly what ExceptionStore is for (and it sets `hasScheduledTime`, so the
    /// workout stops reading "On start" and starts reading 4:00 PM).
    func applyReplan(_ result: Scheduler.Result) async {
        for placement in result.placements {
            let occ = placement.occurrence
            switch occ.behavior {
            case .cue:
                if let key = occ.occurrenceKey { ExceptionStore.shared.reschedule(key, to: placement.start) }
            default:
                if let id = occ.reminderID { reminders.reschedule(id, to: placement.start) }
            }
        }
        await recompute()
    }

    // MARK: - Queries

    /// Day-bucketed index, rebuilt whenever `occurrences` is (recompute is the only writer).
    /// TodayView's body asks for "today" several times per pass; this makes each ask a
    /// dictionary hit instead of a full-array `Calendar.isDate` scan.
    private var byDay: [Date: [Occurrence]] = [:]

    /// Occurrences that fall on a given calendar day.
    /// The day's occurrences, without any waiting on an Undo to be removed (a delete, a decline).
    func occurrences(on day: Date, calendar cal: Calendar = .current) -> [Occurrence] {
        let day = withCurrentSkips(byDay[cal.startOfDay(for: day)] ?? [])
        return PendingRemovals.visible(day, id: { $0.meeting?.eventID }, start: \.start,
                                       hiding: ToastCenter.shared.hiddenIDs)
    }

    /// The next upcoming occurrence at/after `now`.
    func next(after now: Date = Date()) -> Occurrence? {
        occurrences.first { $0.start >= now }
    }

    /// The best currently-known value for one visible planning window. A persisted entry wins;
    /// otherwise fall back to the rolling occurrence snapshot so a first-ever load is never blank.
    func planningWindow(from start: Date, to end: Date) -> [Occurrence] {
        // Unconfirmed events are overlaid here as well as on `occurrences`, because the calendar
        // grids read this and not that. Without it an event the user just created is held in the
        // pending store, drawn nowhere, and looks exactly like the delay this was meant to remove.
        withPendingWrites(in: start, to: end, withCurrentSkips(planningWindowBody(from: start, to: end)))
    }

    private func withPendingWrites(in start: Date, to end: Date, _ base: [Occurrence]) -> [Occurrence] {
        let edited = pendingEdits.applied(to: base)
        let pending = pendingWrites.optimisticOccurrences.filter { $0.start < end && $0.resolvedEnd > start }
        guard !pending.isEmpty else { return pendingEdits.edits.isEmpty ? base : edited.sorted { $0.start < $1.start } }
        return (edited + pending).sorted { $0.start < $1.start }
    }

    private func planningWindowBody(from start: Date, to end: Date) -> [Occurrence] {
        guard end > start else { return [] }
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let key = Self.planningWindowKey(from: startDay, to: end)
        if let entry = planningWindows[key] {
            return renderedPlanningWindow(entry)
        }
        let fallback = indexedOccurrences(from: startDay, to: end)
        let overlapping = planningWindows.values
            .filter { $0.start < end && $0.end > startDay }
            .sorted { $0.mostRecentUpdate < $1.mostRecentUpdate }
        guard !overlapping.isEmpty else { return fallback }

        // Day moves its four-day request by one day per page. Requiring an exact range key threw
        // away the three cached days that still overlap, so the adjacent page looked empty until
        // EventKit/Google returned. Merge those display-only snapshots by stable occurrence ID;
        // later/more recently refreshed windows win, and the exact fresh window replaces this on
        // publication. None of this cache can drive writes or alarms.
        var merged: [AppItemID: Occurrence] = [:]
        for occurrence in fallback { merged[occurrence.id] = occurrence }
        for entry in overlapping {
            for occurrence in renderedPlanningWindow(entry)
            where occurrence.start < end
                && (occurrence.hasScheduledTime
                    ? occurrence.resolvedEnd > startDay
                    : occurrence.start >= startDay) {
                merged[occurrence.id] = occurrence
            }
        }
        return merged.values.sorted { $0.start < $1.start }
    }

    /// Refresh a selected range once for every caller, shared by Mac and iPhone. Internal state is
    /// published immediately; local Calendar + Reminders and direct Google then run concurrently
    /// and replace only their own slices as each finishes. The cache is display-only and never
    /// drives alarm arming or calendar write-back.
    func refreshPlanningWindow(from start: Date, to end: Date) async {
        guard end > start else { return }
        let startDay = Calendar.current.startOfDay(for: start)
        let key = Self.planningWindowKey(from: startDay, to: end)
        recentPlanningRequests.removeAll { $0.key == key }
        recentPlanningRequests.append((key, startDay, end))
        if recentPlanningRequests.count > 3 { recentPlanningRequests.removeFirst() }
        if let task = planningWindowTasks[key] {
            await task.value
            return
        }
        let task = Task { @MainActor in
            await self.performPlanningWindowRefresh(from: startDay, to: end, key: key)
        }
        planningWindowTasks[key] = task
        await task.value
        planningWindowTasks[key] = nil
    }

    /// Compatibility for callers that need the final array rather than observing window updates.
    func loadPlanningWindow(from start: Date, to end: Date) async -> [Occurrence] {
        await refreshPlanningWindow(from: start, to: end)
        return planningWindow(from: start, to: end)
    }

    private func performPlanningWindowRefresh(from startDay: Date, to end: Date, key: String) async {
        #if DEBUG
        let cacheBackfillRegression = ProcessInfo.processInfo.arguments
            .contains("--day-cache-backfill-regression")
        if cacheBackfillRegression, planningWindows[key] != nil { return }
        #endif
        // Keep the best overlapping provider slices visible until each provider replaces its own
        // slice. Publishing an empty exact-key entry here used to blank the cache immediately,
        // defeating stale-while-revalidate during the slow part of a page change.
        let existing = planningWindows[key]
            ?? bestOverlappingPlanningWindow(from: startDay, to: end)
        let initial = PlanningWindowEntry(
            start: startDay,
            end: end,
            base: planningWindowBase(from: startDay, to: end),
            localMeetings: existing?.localMeetings ?? [],
            googleMeetings: existing?.googleMeetings ?? [],
            localExtras: existing?.localExtras ?? [],
            googleExtras: existing?.googleExtras ?? [],
            localUpdatedAt: existing?.localUpdatedAt,
            googleUpdatedAt: existing?.googleUpdatedAt
        )
        publishPlanningWindow(initial, key: key)

        #if DEBUG
        if cacheBackfillRegression {
            await performDayCacheBackfillRegression(from: startDay, key: key)
            return
        }
        #endif

        let excluded = smart?.settings.excludedCalendarIDs ?? []
        #if DEBUG
        let simulatedDelayMilliseconds = Self.simulatedPlanningProviderDelayMilliseconds ?? 0
        #endif
        let localTask = Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            if simulatedDelayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(simulatedDelayMilliseconds))
                guard !Task.isCancelled else { return }
            }
            #endif
            let tasks = await self.reminders.dueTasks(from: startDay, to: end)
            self.applyLocalPlanningWindow(
                tasks: tasks,
                from: startDay,
                to: end,
                key: key
            )
        }
        let googleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            if simulatedDelayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(simulatedDelayMilliseconds))
                guard !Task.isCancelled else { return }
            }
            #endif
            let fetch = await GoogleCalendarService.shared.windowFetch(
                from: startDay,
                to: end,
                excluding: excluded,
                allDay: (self.smart ?? SmartScheduleStore.shared).settings.allDayChoice
            )
            // Published even when incomplete: a failed calendar is served from its last good read
            // where there is one, and holding back every other calendar's events for it would leave
            // the week blank for as long as one account stays signed out. Display only — nothing
            // here feeds write-back.
            guard var entry = self.planningWindows[key] else { return }
            entry.googleMeetings = fetch.window.meetings
            entry.googleAllDay = fetch.window.allDayEvents
            entry.googleExtras = OccurrenceProducers.syncedTravelBlocks(fetch.window.syncedTravelBlocks)
            entry.googleUpdatedAt = Date()
            self.publishPlanningWindow(entry, key: key)
            self.savePlanningWindowCache()
        }

        await localTask.value
        await googleTask.value
        savePlanningWindowCache()
    }

    private func planningWindowBase(from startDay: Date, to end: Date) -> [Occurrence] {
        let cal = Calendar.current
        let dayCount = max(1, cal.dateComponents([.day], from: startDay, to: end).day ?? 7)
        let routineList = routines?.routines ?? RoutineStore.shared.routines

        var wakeByDay: [Date: Date] = [:]
        if let plan = smart?.plan {
            for day in plan.days where day.wake != nil {
                wakeByDay[cal.startOfDay(for: day.date)] = day.wake
            }
        }

        var base = OccurrenceProducers.authored(
            routines: routineList,
            wakeByDay: wakeByDay,
            horizonDays: dayCount,
            now: startDay
        )
        base = ExceptionStore.shared.apply(to: base)
        base += ExceptionStore.shared.extraOccurrences(routines: routineList)
        base += OccurrenceProducers.derived(plan: smart?.plan)
        base += OccurrenceProducers.oneOffAlarms(alarms?.oneOffAlarms ?? [])
        return base
            .filter { $0.start >= startDay && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    private func applyLocalPlanningWindow(
        tasks: [TaskInfo],
        from startDay: Date,
        to end: Date,
        key: String
    ) {
        guard var entry = planningWindows[key] else { return }
        let dayCount = max(
            1,
            Calendar.current.dateComponents([.day], from: startDay, to: end).day ?? 7
        )
        entry.localMeetings = []
        entry.localExtras = OccurrenceProducers.tasks(tasks, horizonDays: dayCount, now: startDay,
                                                      anchored: reminderAnchoring(tasks, now: Date()))
        entry.localUpdatedAt = Date()
        publishPlanningWindow(entry, key: key)
        savePlanningWindowCache()
    }

    private func renderedPlanningWindow(_ entry: PlanningWindowEntry) -> [Occurrence] {
        let routineList = routines?.routines ?? RoutineStore.shared.routines
        // `localMeetings` only ever holds debug fixtures now; real meetings all come from Google.
        let meetings = MeetingInfo.merging(
            primary: entry.googleMeetings,
            additional: entry.localMeetings
        )
        var result = entry.base + entry.localExtras + entry.googleExtras
        result += OccurrenceProducers.external(meetings: meetings)
        result += OccurrenceProducers.allDay(entry.googleAllDay ?? [])
        result += ExceptionStore.shared.apply(to:
            OccurrenceProducers.calendarBoundCues(routines: routineList, meetings: meetings)
        )
        return result
            .filter {
                $0.start < entry.end
                    && ($0.hasScheduledTime ? $0.resolvedEnd > entry.start : $0.start >= entry.start)
            }
            .sorted { $0.start < $1.start }
    }

    /// The windows the grids asked for most recently — the ones on screen, or a page away.
    private var recentPlanningRequests: [(key: String, start: Date, end: Date)] = []

    /// A pass has just read Google across its horizon, newer than any display-only window cached
    /// over the same days — and the Day and Week grids draw from those windows, not from the
    /// timeline. Copy the read into each window it overlaps, before the pass retires the
    /// placeholder of an event it just read back. Without this a blocker you'd just added
    /// vanished: its placeholder retired while the grid's window still predated it, and only
    /// paging away and back (which re-reads the window) brought it back.
    private func refreshPlanningWindows(withMainRead window: CalendarEventWindow, from start: Date, to end: Date) {
        let travel = OccurrenceProducers.syncedTravelBlocks(window.syncedTravelBlocks)
        var changed = false
        for (key, entry) in planningWindows where entry.start < end && entry.end > start {
            // Only the days this read covered are replaced; the rest of the window stays as it was.
            let lo = max(entry.start, start)
            let hi = min(entry.end, end)
            var next = entry
            next.googleMeetings = PlanningWindowSlice.replacing(
                entry.googleMeetings, with: window.meetings.filter { $0.start < entry.end }, from: lo, to: hi,
                span: { ($0.start, $0.end) })
            next.googleExtras = PlanningWindowSlice.replacing(
                entry.googleExtras, with: travel, from: lo, to: hi,
                span: { ($0.start, $0.resolvedEnd) })
            next.googleAllDay = PlanningWindowSlice.replacing(
                entry.googleAllDay ?? [], with: window.allDayEvents.filter { $0.start < entry.end }, from: lo, to: hi,
                span: { ($0.start, $0.end) })
            next.googleUpdatedAt = Date()
            publishPlanningWindow(next, key: key)
            changed = true
        }
        if changed { savePlanningWindowCache() }
    }

    /// After a pass, re-read the windows on screen through their own path, so what the pass
    /// changed beyond Google — a task created, moved or ticked, a routine, an alarm — reaches the
    /// grid too, instead of waiting for a page change. The Google read it just made is reused.
    private func refreshRecentPlanningWindows() {
        let windows = recentPlanningRequests
        guard !windows.isEmpty else { return }
        Task { @MainActor [weak self] in
            for window in windows { await self?.refreshPlanningWindow(from: window.start, to: window.end) }
        }
    }

    private func publishPlanningWindow(_ entry: PlanningWindowEntry, key: String) {
        // Refresh timestamps are bookkeeping, not visible state. Publishing them rebuilt the
        // large Day tree three times even when local and Google data were byte-for-byte unchanged.
        let previous = planningWindows[key].flatMap {
            try? JSONEncoder().encode(renderedPlanningWindow($0))
        }
        planningWindows[key] = entry
        let current = try? JSONEncoder().encode(renderedPlanningWindow(entry))
        if previous != current { planningWindowRevision &+= 1 }
    }

    private func bestOverlappingPlanningWindow(
        from start: Date,
        to end: Date
    ) -> PlanningWindowEntry? {
        planningWindows.values
            .filter { $0.start < end && $0.end > start }
            .max { lhs, rhs in
                let lhsOverlap = min(lhs.end, end).timeIntervalSince(max(lhs.start, start))
                let rhsOverlap = min(rhs.end, end).timeIntervalSince(max(rhs.start, start))
                if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
                return lhs.mostRecentUpdate < rhs.mostRecentUpdate
            }
    }

    private static func planningWindowKey(from start: Date, to end: Date) -> String {
        "\(Int(start.timeIntervalSinceReferenceDate)):\(Int(end.timeIntervalSinceReferenceDate))"
    }

    #if DEBUG
    func injectDayCacheBackfillRegression() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -1, to: today),
              let end = cal.date(byAdding: .day, value: 3, to: today),
              let neighbor = cal.date(byAdding: .hour, value: 4,
                                      to: cal.date(byAdding: .day, value: 1, to: today) ?? today)
        else { return }
        let cached = MeetingInfo(
            start: neighbor,
            end: neighbor.addingTimeInterval(45 * 60),
            coordinate: nil,
            address: nil,
            isVirtual: true,
            title: "Cached neighbor",
            eventID: "cache-neighbor"
        )
        let entry = PlanningWindowEntry(
            start: start,
            end: end,
            base: [],
            localMeetings: [cached],
            googleMeetings: [],
            localExtras: [],
            localUpdatedAt: Date(),
            googleUpdatedAt: nil
        )
        planningWindows = [Self.planningWindowKey(from: start, to: end): entry]
        planningWindowRevision &+= 1
    }

    private func performDayCacheBackfillRegression(
        from startDay: Date,
        key: String
    ) async {
        let delayMilliseconds = Self.simulatedPlanningProviderDelayMilliseconds ?? 1_250
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        guard !Task.isCancelled, var entry = planningWindows[key] else { return }
        let cal = Calendar.current
        let visibleDay = cal.date(byAdding: .day, value: 1, to: startDay) ?? startDay
        let freshStart = cal.date(byAdding: .hour, value: 5, to: visibleDay) ?? visibleDay
        entry.localMeetings.append(MeetingInfo(
            start: freshStart,
            end: freshStart.addingTimeInterval(45 * 60),
            coordinate: nil,
            address: nil,
            isVirtual: false,
            title: "Fresh neighbor",
            eventID: "fresh-neighbor"
        ))
        entry.localUpdatedAt = Date()
        publishPlanningWindow(entry, key: key)
    }

    /// Permission-free, deterministic-enough timeline data for visual audits and marketing
    /// captures. This uses the production occurrence adapters, then adds one fictional flexible
    /// task so the home screen demonstrates the actual mixed calendar/cue/task product instead
    /// of an empty fresh-install shell.
    func injectSampleForPreview(
        meetings: [MeetingInfo],
        lateCueHour: Int? = nil,
        anchoredToBusinessHours: Bool = false,
        denseDayEventCount: Int = 0
    ) {
        let now = Date()
        let cal = Calendar.current
        var seeded = OccurrenceProducers.authored(
            routines: routines?.routines ?? RoutineStore.shared.routines,
            wakeByDay: [:],
            horizonDays: 7,
            now: now)
        // A 9 PM fixture lands exactly on the lower edge of a full-height Mac screenshot when the
        // grid opens near the current hour. Move only the visual-audit copy earlier; production
        // routines and iPhone fixtures retain their real times.
        if let lateCueHour {
            seeded = seeded.map { occurrence in
                guard occurrence.title == "Wind down",
                      let shiftedStart = cal.date(
                        bySettingHour: lateCueHour,
                        minute: cal.component(.minute, from: occurrence.start),
                        second: 0,
                        of: occurrence.start)
                else { return occurrence }
                var shifted = occurrence
                let duration = occurrence.resolvedEnd.timeIntervalSince(occurrence.start)
                shifted.start = shiftedStart
                shifted.end = shiftedStart.addingTimeInterval(duration)
                return shifted
            }
        }
        var previewMeetings = meetings
        if denseDayEventCount > 0 {
            for dayOffset in -2...2 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                let dayStart = cal.startOfDay(for: day)
                for index in 0..<denseDayEventCount {
                    let minute = 6 * 60 + (index * 17) % (16 * 60)
                    let start = cal.date(byAdding: .minute, value: minute, to: dayStart) ?? dayStart
                    previewMeetings.append(MeetingInfo(
                        start: start,
                        end: start.addingTimeInterval(Double(20 + index % 5 * 10) * 60),
                        coordinate: nil,
                        address: nil,
                        isVirtual: index.isMultiple(of: 2),
                        title: "Dense calendar item \(dayOffset)-\(index)",
                        eventID: "dense-\(dayOffset)-\(index)"
                    ))
                }
            }
        }
        // Demonstrate the return-home travel hold (SmartScheduleStore.returnHomeTravelOccurrences)
        // in previews/screenshots too. Production computes this live from EventKit via
        // calendarTravelOccurrences, a path this fixture intentionally bypasses (same reason
        // injectSampleAgenda hand-seeds outbound-only commute legs) -- so without a stand-in here,
        // no visual-audit route ever shows what a return leg looks like on-screen. The badge that
        // renders it (TodayView/WeekView's `returnLeg(for:)`) only shows once the anchoring
        // meeting itself is under way -- before that, the outbound "leave by" badge takes the
        // slot -- and injectSampleAgenda's own physical meetings are always offset into the
        // future, so a route captured moments after launch would never actually show it. Add one
        // already-under-way onsite meeting here, scoped to this preview only, so every route
        // demonstrates the feature regardless of when it happens to be captured.
        let onsiteMeetings = previewMeetings.filter { $0.hasPhysicalLocation && cal.isDate($0.start, inSameDayAs: now) }
        var travelHomeMeetings = previewMeetings
        var anchorMeeting = onsiteMeetings.first {
            let departure = $0.end ?? $0.start
            return departure <= now && departure.addingTimeInterval(20 * 60) > now
        }
        if anchorMeeting == nil {
            let demo = MeetingInfo(
                start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(-5 * 60),
                coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937),
                address: "1 Ferry Building", isVirtual: false,
                title: "Vendor walkthrough", eventID: "preview-demo-onsite")
            travelHomeMeetings.append(demo)
            anchorMeeting = demo
        }
        seeded += OccurrenceProducers.external(meetings: travelHomeMeetings)
        #if DEBUG
        // `--all-day-preview`: a day blocked all day (Busy), a Free birthday, and a two-day offsite.
        if ProcessInfo.processInfo.arguments.contains("--all-day-preview") {
            let today = cal.startOfDay(for: now)
            func days(_ from: Int, _ count: Int) -> (Date, Date) {
                let start = cal.date(byAdding: .day, value: from, to: today) ?? today
                return (start, cal.date(byAdding: .day, value: count, to: start) ?? start)
            }
            let (tripStart, tripEnd) = days(0, 1)
            let (offsiteStart, offsiteEnd) = days(1, 2)
            seeded += OccurrenceProducers.allDay([
                MeetingInfo(start: tripStart, end: tripEnd, isVirtual: false, title: "<redacted> <redacted> Fun Day Trip",
                            eventID: "preview-allday-trip", calendarID: "google:preview", showsAsFree: false,
                            myResponse: .accepted, isAllDay: true),
                MeetingInfo(start: tripStart, end: tripEnd, isVirtual: false, title: "Sergio Nunez\u{2019}s birthday",
                            eventID: "preview-allday-birthday", showsAsFree: true, isAllDay: true),
                MeetingInfo(start: offsiteStart, end: offsiteEnd, isVirtual: false, title: "Team offsite",
                            eventID: "preview-allday-offsite", showsAsFree: true, isAllDay: true),
            ], calendar: cal)
            // `--all-day-crowded`: more on the blocked day — a second Busy one and three Free.
            if ProcessInfo.processInfo.arguments.contains("--all-day-crowded") {
                seeded += OccurrenceProducers.allDay([
                    MeetingInfo(start: tripStart, end: tripEnd, isVirtual: false, title: "Out of office",
                                eventID: "preview-allday-ooo", calendarID: "google:preview-work", showsAsFree: false,
                                myResponse: .accepted, isAllDay: true),
                    MeetingInfo(start: tripStart, end: tripEnd, isVirtual: false, title: "Rosh Hashanah",
                                eventID: "preview-allday-holiday", showsAsFree: true, isAllDay: true),
                    MeetingInfo(start: tripStart, end: tripEnd, isVirtual: false, title: "Mum\u{2019}s birthday",
                                eventID: "preview-allday-mum", showsAsFree: true, isAllDay: true),
                    MeetingInfo(start: tripStart, end: tripEnd, isVirtual: false, title: "Bins out",
                                eventID: "preview-allday-bins", showsAsFree: true, isAllDay: true),
                ], calendar: cal)
            }
        }
        #endif
        if let anchorMeeting {
            let departure = anchorMeeting.end ?? anchorMeeting.start
            seeded.append(Occurrence(
                id: "preview:travel-home",
                seriesID: nil, slotID: nil,
                source: .derived, behavior: .block,
                schedule: OccurrenceSchedule(mode: .derived, moveable: false),
                writePolicy: .busy,
                title: "Travel home", icon: "car.fill", tint: .orange,
                start: departure, end: departure.addingTimeInterval(20 * 60),
                hasScheduledTime: true))
        }

        let previewTasks = [
            ("launch-notes", "Review launch notes"),
            ("send-recap", "Send project recap"),
            ("book-travel", "Book team travel"),
        ]
        for (index, task) in previewTasks.enumerated() {
            let businessHours = [(10, 0), (13, 30), (16, 30)]
            let taskStart: Date
            if anchoredToBusinessHours {
                let (hour, minute) = businessHours[index]
                taskStart = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            } else {
                taskStart = now.addingTimeInterval((2.25 + Double(index) * 0.5) * 3600)
            }
            seeded.append(Occurrence(
                id: "preview:task:\(task.0)",
                seriesID: nil,
                slotID: nil,
                source: .authored,
                behavior: .task,
                schedule: OccurrenceSchedule(
                    mode: .flexible,
                    moveable: true,
                    constraints: OccurrenceConstraints(duration: 30 * 60)),
                writePolicy: .none,
                title: task.1,
                icon: "checklist",
                tint: .green,
                start: taskStart,
                end: taskStart.addingTimeInterval(30 * 60),
                reminderID: "preview-reminder-\(task.0)"))
        }

        // `--untimed-reminders`: reminders with no time — one due yesterday, one due earlier today
        // and not done, one not yet due — the ones the iPhone's calendar had nowhere to draw.
        if ProcessInfo.processInfo.arguments.contains("--untimed-reminders") {
            let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
            let earlierToday = cal.startOfDay(for: now)
            let reminders: [(String, Date?)] = [("Creatine", yesterday), ("Workout", earlierToday), ("Water the plants", nil)]
            for (index, (title, due)) in reminders.enumerated() {
                seeded.append(Occurrence(
                    id: "preview:untimed:\(index)", seriesID: nil, slotID: nil,
                    source: .authored, behavior: .task,
                    schedule: OccurrenceSchedule(mode: .flexible, moveable: true,
                                                 constraints: due.map { OccurrenceConstraints(duration: 30 * 60, deadline: $0) }),
                    writePolicy: .none, title: title, icon: "checklist", tint: .green,
                    start: now, end: nil, hasScheduledTime: false, overdue: due != nil,
                    reminderID: "preview-untimed-\(index)"))
            }
        }

        // `--outstanding-reminders`: reminders past their time and not done that aren't on today
        // at all — one from two days ago, one from last week — and one timed for early today.
        if ProcessInfo.processInfo.arguments.contains("--outstanding-reminders") {
            let today = cal.startOfDay(for: now)
            let late: [(String, Date)] = [
                ("Call the plumber", cal.date(byAdding: .hour, value: -39, to: today) ?? now),
                ("Renew passport", cal.date(byAdding: .day, value: -8, to: today) ?? now),
                ("Take vitamin D", cal.date(byAdding: .minute, value: 5, to: today) ?? now),
            ]
            for (index, (title, due)) in late.enumerated() {
                seeded.append(Occurrence(
                    id: "preview:outstanding:\(index)", seriesID: nil, slotID: nil,
                    source: .authored, behavior: .task,
                    schedule: OccurrenceSchedule(mode: .flexible, moveable: true,
                                                 constraints: OccurrenceConstraints(duration: 15 * 60, deadline: due)),
                    writePolicy: .none, title: title, icon: "checklist", tint: .green,
                    start: due, end: due.addingTimeInterval(15 * 60), hasScheduledTime: true, overdue: true,
                    reminderID: "preview-outstanding-\(index)"))
            }
        }

        let sorted = seeded.sorted { $0.start < $1.start }
        occurrences = sorted
        byDay = Dictionary(grouping: sorted) { cal.startOfDay(for: $0.start) }
        previewPinned = true
    }

    #if targetEnvironment(simulator) || os(macOS)
    func injectStress(_ meetings: [MeetingInfo]) {
        occurrences = OccurrenceProducers.external(meetings: meetings).sorted { $0.start < $1.start }
        byDay = Dictionary(grouping: occurrences) { Calendar.current.startOfDay(for: $0.start) }
        planningWindows.removeAll()
        previewPinned = true
    }
    #endif

    /// Set once preview data is injected; `recompute()` then leaves it alone.
    private(set) var previewPinned = false
    #endif
}
