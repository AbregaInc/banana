import Combine
import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// Keeps a person's availability covered across their included writable Google calendars.
/// Scheduled Banana work, travel, and real meetings are mirrored as privacy-safe busy blocks; an
/// existing foreign event that already covers the interval (including Reclaim/Motion-style
/// placeholders) is reused instead of creating another layer.
///
/// Every block is written through Google's API and carries Banana's ownership in its private
/// extended properties (`GoogleBusyBlocks`). That marker is stored by Google and reads back
/// identically on every device, which is what the Apple Calendar path never had: a block written
/// through CalDAV came back with its marker stripped, so no device could prove it owned it.
///
/// SAFETY RULES — enforced in code, not just intent (learned from real data loss):
///  1. **Never touch a foreign event.** Only events carrying this variant's private marker are
///     ever updated or deleted. The marker is set by Banana alone.
///  2. **Never remove on partial data.** Removal needs every source readable (`sourcesHealthy`),
///     every owned-block read on that calendar to have succeeded, and two healthy passes at least
///     `BlockRemovalGate.confirmationDelay` apart agreeing (`BlockRemovalGate`).
///  3. **Hold mass removals.** A pass that would remove a large share of Banana's blocks is held
///     until the person confirms it (`MassRemovalGuard`).
///  4. **Private mirrors.** Cross-calendar copies are titled “Busy”; a scheduled task keeps its
///     title only on the selected task calendar.
///  5. **Someone else's calendar is opt-in.** See `WriteBackDestinations.destinations`.
@MainActor
final class CalendarWriteBack: ObservableObject {
    static let shared = CalendarWriteBack()

    /// Master switch. Automatically enabled on first Google connection; user changes persist.
    @Published private(set) var cleanupRunning = false
    @Published private(set) var cleanupRemovedCount = 0
    @Published private(set) var cleanupPending = UserDefaults.standard.bool(forKey: "banana.busyCleanupPending")

    @Published var enabled = false {
        didSet { defaults.set(enabled, forKey: DefaultsKey.enabled) }
    }
    /// When false, writes target the dedicated "Banana" test calendar only. Production is true;
    /// the false path remains for testing against a throwaway calendar.
    @Published var goLive = false {
        didSet { defaults.set(goLive, forKey: DefaultsKey.goLive) }
    }
    /// The calendar where scheduled tasks keep their title. A Google calendar info id.
    @Published var liveCalendarID: String? {
        didSet {
            if let liveCalendarID {
                defaults.set(liveCalendarID, forKey: DefaultsKey.calendarID)
            } else {
                defaults.removeObject(forKey: DefaultsKey.calendarID)
            }
        }
    }
    /// A Google account is connected, so there is somewhere to write.
    @Published private(set) var calendarAuthorized = false
    @Published private(set) var writableCalendars: [WritableCalendar] = []
    #if DEBUG
    /// Snapshot fixtures only: the harness never starts the Google graph.
    func injectPreviewCalendars(_ calendars: [WritableCalendar]) { writableCalendars = calendars }
    #endif
    /// Latest "Reserve time for tasks" setting, captured per sync (see desiredBlocks).
    private var reserveTaskTime = true
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncDate: Date?

    /// Removals the last pass held back for confirmation (`MassRemovalGuard`). Zero when none.
    @Published private(set) var heldRemovalCount = 0
    /// Where legacy (Apple-Calendar-written) blocks stand. Write-back waits for this.
    @Published private(set) var adoption: AdoptionState = .notStarted

    private var approveHeldRemovalsOnNextPass = false
    /// Writes the service refused, not sent again until something changed (`BusyCopyRefusals`).
    private var refusals = BusyCopyRefusals()
    /// One pass at a time. Google calls suspend, so without this a recompute arriving mid-pass
    /// would run a second reconcile against the same server state — both see a block missing and
    /// both create it. (The EventKit path was synchronous and could not overlap.)
    private var passInFlight = false
    private var passRequestedWhileBusy = false
    private var removalGate: BlockRemovalGate {
        didSet {
            if let data = try? JSONEncoder().encode(removalGate) {
                defaults.set(data, forKey: DefaultsKey.removalGate)
            }
        }
    }

    /// The same two-pass rule for the sweep of copies at every date (`sweepCopies`).
    private var sweepRemovalGate: BlockRemovalGate {
        didSet {
            if let data = try? JSONEncoder().encode(sweepRemovalGate) {
                defaults.set(data, forKey: DefaultsKey.sweepRemovalGate)
            }
        }
    }

    private let defaults = UserDefaults.standard
    private nonisolated static let log = Logger(subsystem: "com.boris.banana", category: "calendarWriteBack")
    private var ledger: [AppItemID: LedgerEntry] = [:] { didSet { ledgerDirty = true } }
    /// Set by every `ledger` mutation (via `didSet`, which fires for subscript writes too).
    /// `saveLedger()` clears it only after a successful write, so a sync that changed nothing
    /// skips the encode+atomic-write, while a transient write failure still self-heals.
    private var ledgerDirty = false
    /// Set when `calendar-writeback-ledger.json` failed to decode AND could not even be
    /// quarantined. `saveLedger()` then refuses to run rather than overwrite the only copy.
    private var ledgerSaveIsUnsafe = false
    private var hasWriteBackPreference = false
    /// Whether the busy-block question has been answered on this device (`WriteBackStart`).
    @Published private(set) var questionAnswered = false

    struct WritableCalendar: Identifiable, Hashable {
        let id: String
        let title: String
        let sourceTitle: String
        var provider: CalendarSourceInfo.Provider = .google
        /// Owned by the connected account, as opposed to someone else's calendar it may edit.
        var isOwner = true

        var displayName: String {
            sourceTitle.isEmpty ? title : "\(title) — \(sourceTitle)"
        }
    }

    enum AdoptionState: Equatable {
        case notStarted
        /// A dry run found what adoption would do; waiting for the person to confirm it.
        case awaitingConfirmation(LegacyAdoptionReport)
        case running(done: Int, total: Int)
        case finished(LegacyAdoptionReport)
        /// The person chose to leave old blocks unmanaged.
        case skipped
    }

    /// A name-based exclusion made against Apple Calendar, kept so it can be carried over to the
    /// same calendar reached through Google. See `migratedExclusionIdentities`.
    private struct CalendarIdentity: Codable, Hashable {
        let sourceTitle: String
        let calendarTitle: String
    }

    /// Kept for SmartScheduleStore's change debounce; Google has no change notification, so there
    /// are no self-authored echoes to wait out any more.
    private(set) var lastSelfCommit: Date?
    var eventStoreChangeDebounceDelay: TimeInterval {
        CalendarChangeEchoPolicy.debounceDelay(lastSelfCommit: lastSelfCommit)
    }

    /// Every field is load-bearing identity; see `loadLedger()` for why the decoder stays strict.
    /// For a Google block `eventIdentifier` is the Google event id and `calendarID` the Google
    /// calendar info id. Entries whose `calendarID` is an EventKit id are legacy, waiting for
    /// adoption; nothing but adoption reads them.
    struct LedgerEntry: Codable {
        var appItemID: AppItemID
        var eventIdentifier: String
        var calendarID: String
        var writtenHash: Int
        var writtenETag: String? = nil
    }

    private static let variant = CalendarWriteBackVariant.current
    private static var scheme: String { variant.markerScheme }
    private static let coverageTolerance: TimeInterval = 60

    private enum DefaultsKey {
        static let enabled = "calendarWriteBack.enabled"
        static let goLive = "calendarWriteBack.goLive"
        static let calendarID = "calendarWriteBack.calendarID"
        static let userConfigured = "calendarWriteBack.userConfigured"
        /// The person has seen "Keep your calendars in step" and pressed Continue.
        static let questionAnswered = "calendarWriteBack.questionAnswered"
        static let excludedCalendarIdentities = "calendarWriteBack.excludedCalendarIdentities"
        static let removalGate = "calendarWriteBack.removalGate.v1"
        static let sweepRemovalGate = "calendarWriteBack.sweepRemovalGate.v1"
        static let lastSweep = "calendarWriteBack.lastSweep.v1"
        static let adoption = "calendarWriteBack.legacyAdoption.v1"
        static let adoptionCalendars = "calendarWriteBack.legacyAdoption.calendars.v1"
        /// Set the moment the person confirms. Adoption that is interrupted — the app suspended or
        /// killed part way — resumes from here on the next pass without asking again.
        static let adoptionConfirmed = "calendarWriteBack.legacyAdoption.confirmed.v1"
    }

    init() {
        let storedCalendarID = defaults.string(forKey: DefaultsKey.calendarID)
        hasWriteBackPreference = defaults.bool(forKey: DefaultsKey.userConfigured)
            || storedCalendarID != nil
        questionAnswered = defaults.bool(forKey: DefaultsKey.questionAnswered)
        enabled = defaults.bool(forKey: DefaultsKey.enabled)
        goLive = defaults.bool(forKey: DefaultsKey.goLive)
        liveCalendarID = storedCalendarID
        removalGate = defaults.data(forKey: DefaultsKey.removalGate)
            .flatMap { try? JSONDecoder().decode(BlockRemovalGate.self, from: $0) } ?? BlockRemovalGate()
        sweepRemovalGate = defaults.data(forKey: DefaultsKey.sweepRemovalGate)
            .flatMap { try? JSONDecoder().decode(BlockRemovalGate.self, from: $0) } ?? BlockRemovalGate()
        loadLedger()
        adoption = loadAdoptionState()
        refreshCalendars()
        // The same as tapping "Remove them" in Settings, for a launch made on the person's
        // behalf: the next pass may carry out removals the mass-removal guard is holding. Still
        // only what two healthy passes agreed on — this lifts the size check, nothing else.
        if ProcessInfo.processInfo.arguments.contains("--approve-held-removals") {
            approveHeldRemovalsOnNextPass = true
        }
    }

    var selectedCalendar: WritableCalendar? {
        guard let liveCalendarID else { return nil }
        return writableCalendars.first { $0.id == liveCalendarID }
    }

    /// Re-read the destinations from the Google calendar list. Cheap: no network.
    func refreshCalendars() {
        let google = GoogleCalendarService.shared
        calendarAuthorized = google.isConnected
        guard calendarAuthorized else {
            writableCalendars = []
            return
        }
        let infos = Dictionary(google.allCalendarInfos.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        let candidates = google.writeBackCandidates
        writableCalendars = candidates.map {
            WritableCalendar(
                id: $0.infoID,
                title: infos[$0.infoID]?.title ?? $0.titles.first ?? "Calendar",
                sourceTitle: infos[$0.infoID]?.sourceTitle ?? "Google · \($0.accountEmail)",
                provider: .google,
                isOwner: $0.isOwner)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }


        // The task-title calendar used to be an Apple Calendar id. Carry it to the same calendar in
        // Google when the name identifies it; otherwise fall back like a lost destination.
        if let current = liveCalendarID, !GoogleCalendarIDs.isCalendarInfoID(current) {
            liveCalendarID = nil
        }
        enableDefaultWriteBackIfNeeded()
        if enabled, selectedCalendar == nil,
           let fallback = writableCalendars.first(where: { $0.isOwner && isPrimary($0.id) })
            ?? writableCalendars.first(where: \.isOwner) {
            liveCalendarID = fallback.id
            goLive = true
        }
    }

    private func isPrimary(_ infoID: String) -> Bool {
        GoogleCalendarService.shared.allCalendarInfos.first { $0.id == infoID }?.isDefault == true
    }

    /// Kept for the screens that ask for "calendar access": for Google that is connecting an
    /// account, which happens through the Google sign-in flow.
    func requestCalendarAccess() async {
        if !GoogleCalendarService.shared.isConnected {
            await GoogleCalendarService.shared.connect()
        }
        refreshCalendars()
    }

    func selectLiveCalendar(_ id: String?) {
        recordUserPreference()
        liveCalendarID = id
        goLive = true
        lastError = nil
        SmartScheduleStore.shared.settings.writeBackCalendarID = id.flatMap(Self.syncableCalendarID)
    }

    private var syncedObserver: AnyCancellable?

    /// On/off and the task calendar are one synced setting for every device
    /// (`SmartScheduleSettings.writeBackEnabled/writeBackCalendarID`); every device writes and
    /// reconciles. Seeds the synced value from this device when it's unset and this device has
    /// been set up; from then on adopts whatever any device sets.
    func bindToSyncedSettings(_ smart: SmartScheduleStore) {
        // Seed only "on": seeding "off" would have every other device withdraw its blocks on first
        // contact, just because this one happened to launch first. And only a Google calendar id —
        // an older build's Apple Calendar id means nothing on another device (or, soon, here).
        if smart.settings.writeBackEnabled == nil, enabled {
            smart.settings.writeBackEnabled = true
            smart.settings.writeBackCalendarID = liveCalendarID.flatMap(Self.syncableCalendarID)
        }
        syncedObserver = smart.$settings
            .map { WriteBackChoice(enabled: $0.writeBackEnabled, calendarID: $0.writeBackCalendarID) }
            .removeDuplicates()
            .sink { [weak self] in self?.adopt($0) }
    }

    /// A task calendar worth syncing: a Google calendar info id, the same on every device.
    private static func syncableCalendarID(_ id: String) -> String? {
        GoogleCalendarIDs.isCalendarInfoID(id) ? id : nil
    }

    private struct WriteBackChoice: Equatable {
        var enabled: Bool?
        var calendarID: String?
    }

    /// Another device's choice. Turned off elsewhere: withdraw the blocks here too — every device
    /// reconciles, and deleting one another device already removed counts as done. Turned on
    /// elsewhere: write here too.
    private func adopt(_ choice: WriteBackChoice) {
        if let calendarID = choice.calendarID.flatMap(Self.syncableCalendarID), calendarID != liveCalendarID {
            liveCalendarID = calendarID
            goLive = true
        }
        guard let wanted = choice.enabled else { return }
        recordUserPreference()   // a choice exists; never auto-enable over it
        // Live, as production always is: left in test mode, a device that adopted "on" would
        // write only to a calendar named "Banana" — or nowhere.
        if wanted && (cleanupPending || cleanupRunning) { return }
        if wanted { goLive = true }
        if wanted != enabled {
            enabled = wanted
            if wanted {
                lastError = nil
            } else {
                markCleanupPending()
                Task { await retryCleanup() }
            }
        }
    }

    /// Turning sync off removes the blocks Banana wrote — an explicit request to withdraw them.
    @discardableResult
    func setEnabled(_ newValue: Bool) -> Bool {
        recordUserPreference()
        if !newValue {
            enabled = false
            lastError = nil
            // Off everywhere: every device withdraws the blocks, whichever gets there first — a
            // block another already deleted counts as done.
            SmartScheduleStore.shared.settings.writeBackEnabled = false
            markCleanupPending()
            Task { await retryCleanup() }
            return true
        }
        guard !cleanupPending && !cleanupRunning else {
            lastError = "Finish removing Banana’s old busy copies before enabling copying again."
            return false
        }
        refreshCalendars()
        guard calendarAuthorized else {
            lastError = "Connect a Google account before enabling write-back."
            enabled = false
            return false
        }
        guard !writableCalendars.isEmpty else {
            lastError = "No writable Google calendars are available."
            enabled = false
            return false
        }
        if selectedCalendar == nil {
            liveCalendarID = writableCalendars.first(where: { isPrimary($0.id) })?.id
                ?? writableCalendars.first?.id
        }
        goLive = true
        enabled = true
        SmartScheduleStore.shared.settings.writeBackEnabled = true
        SmartScheduleStore.shared.settings.writeBackCalendarID = liveCalendarID.flatMap(Self.syncableCalendarID)
        return true
    }

    /// Remove every busy block this variant wrote, on every writable Google calendar, then let
    /// the next sync write them again. Found by the private marker, so it covers blocks written by
    /// any of this person's devices.
    ///
    /// - Returns: how many blocks were removed.
    @discardableResult
    func purgeMarkedBlocks() async -> Int {
        // "Remove and rewrite" is only safe when the rewrite will happen. While write-back is
        // paused for adoption nothing is rewritten, so a rebuild then is a pure deletion — which
        // is how 85 blocks on bo@acme.example went on 2026-09-25 and stayed gone.
        guard adoptionPermitsWriting else {
            lastError = "Busy blocks can’t be rebuilt until older blocks have been taken over (or skipped) — nothing would write them back."
            return 0
        }
        guard !passInFlight else {
            lastError = "Busy blocks are being updated — try again in a moment."
            return 0
        }
        passInFlight = true
        defer { passInFlight = false }
        let removed = await removeEveryOwnedBlock(reason: "rebuild")
        ledger = ledger.filter { !GoogleCalendarIDs.isCalendarInfoID($0.value.calendarID) }
        removalGate = BlockRemovalGate()
        heldRemovalCount = 0
        saveLedger()
        return removed
    }

    /// Let the removals held by `MassRemovalGuard` go ahead on the next pass.
    func approveHeldRemovals() {
        approveHeldRemovalsOnNextPass = true
        heldRemovalCount = 0
    }

    private func markCleanupPending() {
        cleanupPending = true
        UserDefaults.standard.set(true, forKey: "banana.busyCleanupPending")
    }

    /// Explicit recovery remains available after restart or reconnect, while copying stays off.
    func retryCleanup() async {
        guard !enabled, !cleanupRunning else { return }
        markCleanupPending()
        guard !passInFlight else {
            lastError = "A calendar update is finishing. Retry cleanup in a moment."
            return
        }
        guard GoogleCalendarService.shared.isConnected else {
            lastError = "Reconnect the affected Google accounts, then retry cleanup. Busy copying stays off."
            return
        }
        cleanupRunning = true
        passInFlight = true
        defer { cleanupRunning = false; passInFlight = false }
        lastError = nil
        await GoogleCalendarService.shared.refresh()
        if GoogleCalendarService.shared.hasDegradedSources {
            lastError = "Some calendars could not be read. Reconnect the affected accounts and retry cleanup."
            return
        }
        if let error = GoogleCalendarService.shared.lastError {
            lastError = "Calendar refresh failed: \(error). Retry cleanup after reconnecting."
            return
        }
        guard !GoogleCalendarService.shared.writeBackCandidates.isEmpty else {
            lastError = "No writable calendars were loaded. Reconnect the affected accounts and retry."
            return
        }
        cleanupRemovedCount = await removeEveryOwnedBlock(reason: "requested cleanup")
        if lastError == nil {
            cleanupPending = false
            UserDefaults.standard.set(false, forKey: "banana.busyCleanupPending")
        }
    }

    @discardableResult
    private func removeEveryOwnedBlock(reason: String) async -> Int {
        let google = GoogleCalendarService.shared
        let (windowStart, windowEnd) = Self.ownershipWindow()
        var removed = 0
        for calendar in google.writeBackCandidates {
            guard let raw = GoogleCalendarIDs.rawCalendarID(from: calendar.infoID) else { continue }
            let owned: [String: [GoogleCalendarService.OwnedBlock]]
            do {
                owned = try await google.ownedBusyBlockDetails(
                    calendarID: raw, variant: Self.scheme, from: windowStart, to: windowEnd, allDates: true)
            } catch {
                lastError = "Couldn’t read Banana’s blocks on \(calendar.titles.first ?? "a calendar"): \(error.localizedDescription)"
                continue
            }
            for (itemID, blocks) in owned {
                var removedAllCopies = true
                for block in blocks {
                    let eventID = block.eventID
                    // Shared manager access does not prove this account wrote a marked block.
                    // On someone else's calendar, only remove the exact locally recorded copy.
                    guard BusyBlockCleanupPolicy.mayDelete(calendarIsOwner: calendar.isOwner,
                        recordedEventID: ledger[ledgerKey(appItemID: itemID, calendarID: calendar.infoID)]?.eventIdentifier,
                        eventID: eventID, creatorEmail: block.creatorEmail,
                        accountEmails: Set(google.accounts.map(\.email))) else { continue }
                    do {
                        try await google.deleteBusyBlock(calendarID: raw, eventID: eventID, expectedETag: block.etag)
                        removed += 1
                    } catch {
                        removedAllCopies = false
                        lastError = "Couldn’t remove a Banana busy block: \(error.localizedDescription)"
                    }
                }
                if removedAllCopies {
                    ledger[ledgerKey(appItemID: itemID, calendarID: calendar.infoID)] = nil
                }
            }
        }
        saveLedger()
        Log.writeBack.notice("[writeback] \(reason, privacy: .public): removed \(removed, privacy: .public) owned block(s)")
        return removed
    }

    private func recordUserPreference() {
        hasWriteBackPreference = true
        defaults.set(true, forKey: DefaultsKey.userConfigured)
    }

    /// Whether busy blocks already have an answer (`WriteBackStart.settled`).
    var questionSettled: Bool {
        WriteBackStart.settled(questionAnswered: questionAnswered,
                               hasPreference: hasWriteBackPreference,
                               sharedChoice: SmartScheduleStore.shared.settings.writeBackEnabled)
    }

    /// Whether the plan should ask which calendars keep each other busy.
    var needsAnswer: Bool {
        WriteBackStart.needsAnswer(connected: calendarAuthorized,
                                   ownsACalendar: writableCalendars.contains(where: \.isOwner),
                                   questionAnswered: questionAnswered,
                                   hasPreference: hasWriteBackPreference,
                                   sharedChoice: SmartScheduleStore.shared.settings.writeBackEnabled)
    }

    /// The person pressed Continue on "Keep your calendars in step": busy blocks may start, on
    /// the calendars left ticked there.
    func answerQuestion() {
        questionAnswered = true
        defaults.set(true, forKey: DefaultsKey.questionAnswered)
        refreshCalendars()
    }

    /// A first connection syncs availability once the person has said yes to it (it used to
    /// start the moment an account connected). The primary calendar is the one place scheduled
    /// tasks may retain their title; mirrors elsewhere remain private.
    private func enableDefaultWriteBackIfNeeded() {
        // Only when no device has chosen yet: otherwise that choice stands (see `adopt`).
        guard WriteBackStart.mayStartByDefault(questionAnswered: questionAnswered,
                                               hasPreference: hasWriteBackPreference,
                                               sharedChoice: SmartScheduleStore.shared.settings.writeBackEnabled),
              calendarAuthorized else { return }
        guard let destination = writableCalendars.first(where: { $0.isOwner && isPrimary($0.id) })
                ?? writableCalendars.first(where: \.isOwner) else { return }
        hasWriteBackPreference = true
        liveCalendarID = destination.id
        goLive = true
        enabled = true
        lastError = nil
        SmartScheduleStore.shared.settings.writeBackEnabled = true
        SmartScheduleStore.shared.settings.writeBackCalendarID = destination.id
    }

    // MARK: - Sync

    private struct DesiredBlock {
        let appItemID: AppItemID
        let calendarID: String
        let title: String
        let start: Date
        let end: Date
        /// The copy of a day blocked all day: written as an all-day Busy event on its date, not
        /// a 24-hour bar.
        var isAllDay = false
        /// The calendar the copied meeting is on; nil for Banana's own work. Not written: it only
        /// names the source on the first run's preview.
        var sourceCalendarID: String? = nil

        var ledgerKey: String { "\(appItemID)\u{1F}\(calendarID)" }
    }

    /// Reconcile privacy-safe busy coverage across every included writable Google calendar.
    /// Foreign busy intervals come from the occurrence engine's calendar read: if Reclaim (or a
    /// real duplicate event) already covers a destination, our block there is omitted/removed.
    ///
    /// - Parameter sourcesHealthy: every calendar the occurrences were computed from was read
    ///   successfully. When false, this pass creates and updates but removes nothing.
    /// - Returns: blocks created or updated this pass.
    @discardableResult
    func sync(
        _ occurrences: [Occurrence],
        existingBusyIntervals: [CalendarBusyInterval] = [],
        excluding excludedCalendarIDs: Set<String> = [],
        includingShared includedSharedCalendarIDs: Set<String> = [],
        reserveTaskTime: Bool = true,
        sourcesHealthy: Bool,
        sourceExcluding sourceExcludedCalendarIDs: Set<String>? = nil
    ) async -> Int {
        self.reserveTaskTime = reserveTaskTime
        // What a pass would plan from, kept whether or not it writes: the first run's preview
        // plans from exactly these (`previewCopies`).
        capture(PlanInputs(occurrences: occurrences, existingBusyIntervals: existingBusyIntervals,
                           excluded: excludedCalendarIDs, includedShared: includedSharedCalendarIDs,
                           reserveTaskTime: reserveTaskTime, sourcesHealthy: sourcesHealthy))
        guard enabled else { return 0 }
        // A diagnostic launch reads; it never writes to a real calendar as a side effect.
        guard !Self.isDiagnosticLaunch else { return 0 }
        guard !passInFlight else {
            // Coalesce: the running pass finishes on its own inputs, then one more recompute runs
            // with whatever changed meanwhile.
            passRequestedWhileBusy = true
            return 0
        }
        passInFlight = true
        defer {
            passInFlight = false
            if passRequestedWhileBusy {
                passRequestedWhileBusy = false
                OccurrenceStore.shared.requestRecompute(reason: "write-back pass coalesced")
            }
        }
        guard !cleanupPending && !cleanupRunning else {
            lastError = "Finish removing Banana’s old busy copies before enabling copying again."
            return 0
        }
        refreshCalendars()
        guard calendarAuthorized else { return 0 }

        // Old blocks first: until they are adopted they are invisible to ownership, and writing
        // alongside them only stacks new blocks on top of stale ones.
        await adoptLegacyBlocksIfNeeded()
        guard adoptionPermitsWriting else {
            Log.writeBack.notice("[writeback] paused — legacy blocks need adopting first")
            return 0
        }

        let trace = Signpost.begin("calendarWriteBack")
        defer { Signpost.end(trace) }
        let destinations = targetCalendarIDs(excluding: excludedCalendarIDs,
                                             includingShared: includedSharedCalendarIDs)
        guard !destinations.isEmpty else {
            lastError = goLive
                ? "No included writable calendars are available."
                : "Create a calendar named “Banana” to enable write-back (test mode writes only there)."
            DiagnosticJournal.shared.record(
                operation: "calendar.writeBack",
                name: "no_writable_calendars",
                attributes: ["go_live": goLive ? "true" : "false"])
            return 0
        }
        lastError = nil

        let desired = desiredBlocks(
            from: occurrences,
            destinations: destinations,
            existingBusyIntervals: existingBusyIntervals)
        let diagnostic = DiagnosticJournal.shared.startSpan(
            "calendar.writeBack",
            attributes: [
                "occurrence_count": String(occurrences.count),
                "calendar_count": String(destinations.count),
                "desired_block_count": String(desired.count),
                "existing_busy_count": String(existingBusyIntervals.count),
                "sources_healthy": sourcesHealthy ? "true" : "false",
            ])
        let written = await reconcile(desired, destinations: destinations,
                                      sourcesHealthy: sourcesHealthy)
        DiagnosticJournal.shared.finish(
            diagnostic,
            status: lastError == nil ? .succeeded : .failed,
            reason: lastError == nil ? (written > 0 ? "google_written" : "already_reconciled")
                : "write_back_failed",
            attributes: ["written": String(written), "error": lastError ?? ""])
        if lastError == nil { lastSyncDate = Date() }
        if lastError == nil, sourcesHealthy, goLive, let sourceExcludedCalendarIDs {
            await sweepCopiesIfDue(sourceExcluding: sourceExcludedCalendarIDs)
        }
        return written
    }

    // MARK: - Copies whose source no longer qualifies, at any date

    /// How often the whole history is swept when nothing is waiting for a second look.
    private static let sweepInterval: TimeInterval = 6 * 3600

    /// Removes this person's Busy copies of events, at every date, whose event no longer calls for
    /// a copy (`BusyCopySweep`): a calendar that stopped blocking time, an event made Free,
    /// deleted or renamed. The pass already does this for copies that are current or ahead; this
    /// covers the ones whose event is over, which the pass never judges because it plans from
    /// today on.
    ///
    /// Same safety as the pass: only this person's copies (`ours`), only after two complete reads
    /// at least `BlockRemovalGate.confirmationDelay` apart agree, and a removal that is a large
    /// share of every copy is held for the person to confirm (`MassRemovalGuard`). No date limit:
    /// copies are found with one filtered query per calendar over all dates, and the events are
    /// read back to the earliest copy judged. It runs every `sweepInterval`, and on the next pass
    /// while removals wait for their second look.
    private func sweepCopiesIfDue(sourceExcluding excluded: Set<String>) async {
        let now = Date()
        let last = defaults.object(forKey: DefaultsKey.lastSweep) as? Date
        guard !sweepRemovalGate.pendingSince.isEmpty || last.map({ now.timeIntervalSince($0) >= Self.sweepInterval }) ?? true
        else { return }
        let google = GoogleCalendarService.shared
        var copies: [String: [BusyCopyPlanner.Owned]] = [:]
        var calendarOf: [String: String] = [:]   // event id → calendar info id
        var ownedTotal = 0
        for calendarID in google.writeBackCandidates.map(\.infoID).sorted() {
            guard let raw = GoogleCalendarIDs.rawCalendarID(from: calendarID) else { continue }
            let owned: [String: [GoogleCalendarService.OwnedBlock]]
            do {
                owned = try await ours(google.ownedBusyBlockDetails(calendarID: raw, variant: Self.scheme,
                                                                    from: now, to: now, allDates: true), on: calendarID)
            } catch where GoogleCalendarService.isCalendarGone(error) {
                continue
            } catch {
                Log.writeBack.notice("[writeback] sweep skipped: a calendar's copies could not be read")
                return
            }
            for (itemID, blocks) in owned {
                ownedTotal += blocks.count
                for block in blocks {
                    calendarOf[block.eventID] = calendarID
                    copies[itemID, default: []].append(BusyCopyPlanner.Owned(
                        eventID: block.eventID, etag: block.etag, end: block.end, start: block.start))
                }
            }
        }
        var qualifying = Set<String>()
        if let earliest = BusyCopySweep.earliestStart(copies: copies, now: now) {
            let read = await google.windowFetch(from: Calendar.current.startOfDay(for: earliest), to: now,
                                                excluding: excluded,
                                                allDay: SmartScheduleStore.shared.settings.allDayChoice)
            // A calendar that could not be read would make its events' copies look unwanted.
            guard read.isComplete else {
                Log.writeBack.notice("[writeback] sweep skipped: the events could not all be read")
                return
            }
            qualifying = MirrorSources.qualifying(meetings: read.window.meetings, allDay: read.window.allDayEvents)
        }
        let unwanted = BusyCopySweep.unwanted(copies: copies, qualifying: qualifying, now: now)
        var byKey: [String: (calendarID: String, blocks: [BusyCopyPlanner.Owned])] = [:]
        for (itemID, blocks) in unwanted {
            for block in blocks {
                guard let calendarID = calendarOf[block.eventID] else { continue }
                byKey[ledgerKey(appItemID: itemID, calendarID: calendarID), default: (calendarID, [])].blocks.append(block)
            }
        }
        var confirmed = sweepRemovalGate.review(unwanted: Set(byKey.keys), sourcesHealthy: true, now: now)
        if !confirmed.isEmpty, MassRemovalGuard.shouldHold(removing: confirmed.count, owned: ownedTotal),
           !approveHeldRemovalsOnNextPass {
            heldRemovalCount = confirmed.count
            Log.writeBack.notice("[writeback] sweep HOLDING \(confirmed.count, privacy: .public) removal(s) of \(ownedTotal, privacy: .public) copies — waiting for confirmation")
            confirmed = []
        } else if !confirmed.isEmpty {
            approveHeldRemovalsOnNextPass = false
        }
        var removed = 0
        for key in confirmed.sorted() {
            guard let target = byKey[key], let raw = GoogleCalendarIDs.rawCalendarID(from: target.calendarID) else { continue }
            var allGone = true
            for block in target.blocks {
                do {
                    try await google.deleteBusyBlock(calendarID: raw, eventID: block.eventID, expectedETag: block.etag)
                    removed += 1
                    lastSelfCommit = Date()
                } catch {
                    allGone = false
                    lastError = "Couldn’t remove a busy block from a Google calendar: \(error.localizedDescription)"
                }
            }
            if allGone { ledger[key] = nil }
        }
        sweepRemovalGate.forget(confirmed)
        saveLedger()
        if !byKey.isEmpty || removed > 0 {
            Log.writeBack.notice("[writeback] sweep: \(byKey.count, privacy: .public) unwanted at any date, removed \(removed, privacy: .public), awaiting confirmation \(self.sweepRemovalGate.pendingSince.count, privacy: .public)")
            PlaybackDiagnostics.shared.log("writeback: sweep", "\(byKey.count) copies no longer called for, removed \(removed), \(sweepRemovalGate.pendingSince.count) waiting for a second look")
        }
        if sweepRemovalGate.pendingSince.isEmpty { defaults.set(now, forKey: DefaultsKey.lastSweep) }
    }

    /// The window blocks are looked for in: a week back to beyond the travel horizon. Must cover
    /// everything `desiredBlocks` can produce, or a wanted block outside it would be re-created
    /// every pass.
    private static func ownershipWindow(now: Date = Date()) -> (Date, Date) {
        (now.addingTimeInterval(-7 * 86_400),
         now.addingTimeInterval(Double(OccurrenceStore.writeBackTravelHorizonDays + 14) * 86_400))
    }

    /// Create, update and remove, per calendar, against what Google says Banana owns there.
    ///
    /// Ownership is read from the server every pass, so it does not depend on this device's ledger
    /// being complete — a block written by the phone is updated or removed by the Mac, and vice
    /// versa. The ledger only remembers what was last written, to skip unchanged blocks.
    private func reconcile(_ desired: [DesiredBlock], destinations: [String],
                           sourcesHealthy: Bool) async -> Int {
        let google = GoogleCalendarService.shared
        let variant = Self.scheme
        let byCalendar = Dictionary(grouping: desired, by: \.calendarID)
        // Every writable calendar, not just destinations: an excluded calendar still holds the
        // blocks written before it was excluded, and those are ours to clean up.
        var calendarIDs = Set(destinations)
        calendarIDs.formUnion(google.writeBackCandidates.map(\.infoID))
        // Calendars the ledger remembers but Google no longer lists — deleted, or no longer
        // shared — are gone, and so are the blocks on them. Asking about them only fails, and a
        // failed read suspends every removal. Forget them, but only when the list is complete: a
        // signed-out account's calendars are missing from it without being gone.
        let ledgerCalendars = Set(ledger.values.map(\.calendarID).filter(GoogleCalendarIDs.isCalendarInfoID))
        let listed = Set(google.allCalendarInfos.map(\.id))
        let vanished = WriteBackDestinations.vanishedCalendars(
            remembered: ledgerCalendars, listed: listed, listIsComplete: !google.hasDegradedSources)
        if !vanished.isEmpty {
            let before = ledger.count
            ledger = ledger.filter { !vanished.contains($0.value.calendarID) }
            Log.writeBack.notice("[writeback] \(vanished.count, privacy: .public) calendar(s) no longer exist in Google; forgot \(before - self.ledger.count, privacy: .public) ledger entries")
        }
        calendarIDs.formUnion(ledgerCalendars.subtracting(vanished).intersection(listed))
        if !goLive {
            // Test mode never looks beyond the test calendars.
            calendarIDs = Set(destinations)
        }
        let (windowStart, windowEnd) = Self.ownershipWindow()

        var writtenCount = 0
        var everyOwnedReadSucceeded = true
        var unwanted: [String: (calendarID: String, blocks: [GoogleCalendarService.OwnedBlock])] = [:]
        var ownedTotal = 0
        let now = Date()

        for calendarID in calendarIDs.sorted() {
            guard let raw = GoogleCalendarIDs.rawCalendarID(from: calendarID) else { continue }
            let ownedDetails: [String: [GoogleCalendarService.OwnedBlock]]
            do {
                ownedDetails = try await ours(google.ownedBusyBlockDetails(
                    calendarID: raw, variant: variant, from: windowStart, to: windowEnd), on: calendarID)
            } catch where GoogleCalendarService.isCalendarGone(error) {
                // Deleted between the list and this read. Nothing of ours can be on a calendar
                // that does not exist, so this is an answer, not a failure.
                google.noteCalendarGone()
                ledger = ledger.filter { $0.value.calendarID != calendarID }
                continue
            } catch {
                // Without knowing what is already there, writing risks a duplicate and removing
                // is out of the question. Skip the calendar for this pass.
                everyOwnedReadSucceeded = false
                lastError = "Couldn’t read Banana’s blocks on a Google calendar: \(error.localizedDescription)"
                continue
            }
            // The share a removal is measured against: blocks still protecting time.
            ownedTotal += ownedDetails.values.reduce(0) { $0 + $1.filter { $0.end > now }.count }

            // What to do here comes from the planner the first run's preview uses too
            // (`BusyCopyPlanner`), so what a person was shown is what a pass does.
            let wanted = byCalendar[calendarID] ?? []
            let plan = Self.plan(wanted, owned: ownedDetails, recorded: recordedWrites(on: calendarID), now: now)
            // Any extra copies of a wanted block — two devices writing it at once, or copies
            // adopted from Apple Calendar — go. Every device keeps the SAME copy: keeping "the one
            // my ledger knows" let the phone keep A and delete B while the iPad kept B and
            // deleted A, and the block vanished.
            for extra in plan.duplicates {
                do {
                    try await google.deleteBusyBlock(calendarID: raw, eventID: extra.eventID, expectedETag: extra.etag)
                } catch {
                    lastError = "Couldn’t remove a duplicate busy block: \(error.localizedDescription)"
                }
            }
            // Already as wanted: remember the version so a later pass need not read it again.
            for match in plan.matches {
                let block = wanted[match.index]
                let known = ledger[block.ledgerKey]
                if known?.eventIdentifier == match.eventID, known?.writtenETag == match.etag,
                   known?.writtenHash == Self.hash(block) { continue }
                ledger[block.ledgerKey] = LedgerEntry(appItemID: block.appItemID, eventIdentifier: match.eventID,
                                                      calendarID: calendarID, writtenHash: Self.hash(block),
                                                      writtenETag: match.etag)
            }
            for write in plan.writes {
                let (index, versionWritten): (Int, String?) = switch write {
                case .update(let index, _, let etag): (index, etag)
                case .create(let index): (index, nil)
                }
                let refusalKey = wanted[index].ledgerKey
                let fingerprint = Self.hash(wanted[index])
                if refusals.holds(refusalKey, fingerprint: fingerprint, etag: versionWritten, now: now) { continue }
                do {
                    switch write {
                    case .update(let index, let keep, let etag):
                        let block = wanted[index]
                        let writtenETag = try await google.updateBusyBlock(
                            calendarID: raw, eventID: keep,
                            title: block.title, start: block.start, end: block.end, isAllDay: block.isAllDay,
                            appItemID: block.appItemID, variant: variant, expectedETag: etag)
                        ledger[block.ledgerKey] = LedgerEntry(appItemID: block.appItemID, eventIdentifier: keep,
                                                              calendarID: calendarID, writtenHash: Self.hash(block), writtenETag: writtenETag)
                    case .create(let index):
                        let block = wanted[index]
                        let created = try await google.createBusyBlockWithVersion(
                            calendarID: raw, title: block.title,
                            start: block.start, end: block.end, isAllDay: block.isAllDay,
                            appItemID: block.appItemID, variant: variant)
                        ledger[block.ledgerKey] = LedgerEntry(appItemID: block.appItemID, eventIdentifier: created.id,
                                                              calendarID: calendarID, writtenHash: Self.hash(block), writtenETag: created.etag)
                    }
                    writtenCount += 1
                    lastSelfCommit = Date()
                    refusals.clear(refusalKey)
                } catch {
                    if let status = GoogleCalendarService.refusalStatus(error), BusyCopyRefusals.isRefusal(status: status) {
                        refusals.refuse(refusalKey, fingerprint: fingerprint, etag: versionWritten, now: now)
                    }
                    lastError = "Couldn’t write a busy block to a Google calendar: \(error.localizedDescription)"
                }
            }

            // Only current and future blocks go: every removal is a chance to be wrong.
            for itemID in plan.unwanted.keys {
                let current = (ownedDetails[itemID] ?? []).filter { $0.end > now }
                guard !current.isEmpty else { continue }
                unwanted[ledgerKey(appItemID: itemID, calendarID: calendarID)] = (calendarID, current)
            }
        }

        // Removal: only what two healthy passes agree on, and never a suspiciously large share.
        let healthy = sourcesHealthy && everyOwnedReadSucceeded
        var confirmed = removalGate.review(unwanted: Set(unwanted.keys), sourcesHealthy: healthy,
                                           now: Date())
        if !healthy {
            Log.writeBack.notice("[writeback] a calendar source is unreadable — creating/updating only, removing nothing this pass")
        }
        if !confirmed.isEmpty,
           MassRemovalGuard.shouldHold(removing: confirmed.count, owned: ownedTotal),
           !approveHeldRemovalsOnNextPass {
            heldRemovalCount = confirmed.count
            Log.writeBack.notice("[writeback] HOLDING \(confirmed.count, privacy: .public) removal(s) of \(ownedTotal, privacy: .public) owned — waiting for confirmation")
            confirmed = []
        } else if !confirmed.isEmpty {
            heldRemovalCount = 0
            approveHeldRemovalsOnNextPass = false
        }

        var removedIDs: [String] = []
        for key in confirmed.sorted() {
            guard let target = unwanted[key],
                  let raw = GoogleCalendarIDs.rawCalendarID(from: target.calendarID) else { continue }
            var allGone = true
            for block in target.blocks {
                do {
                    try await google.deleteBusyBlock(calendarID: raw, eventID: block.eventID, expectedETag: block.etag)
                    lastSelfCommit = Date()
                } catch {
                    allGone = false
                    lastError = "Couldn’t remove a busy block from a Google calendar: \(error.localizedDescription)"
                }
            }
            if allGone {
                ledger[key] = nil
                removedIDs.append(key.components(separatedBy: "\u{1F}").first ?? key)
            }
        }
        removalGate.forget(confirmed)
        if !unwanted.isEmpty || !removedIDs.isEmpty {
            // WHICH items, not just how many: a count cannot distinguish cleaning up after deleted
            // meetings from creating and deleting the same block forever.
            Log.writeBack.notice("[writeback] unwanted \(unwanted.count, privacy: .public), removed \(removedIDs.count, privacy: .public), awaiting confirmation \(self.removalGate.pendingSince.count, privacy: .public)")
            if !removedIDs.isEmpty {
                Log.writeBack.notice("[writeback] removed item ids: \(Array(Set(removedIDs)).sorted().joined(separator: ","), privacy: .public)")
            }
        }
        saveLedger()
        return writtenCount
    }

    /// What Google says Banana owns on `calendarID`, kept to this person's copies
    /// (`BusyBlockCleanupPolicy`). On a calendar the account doesn't own, another person's Banana
    /// carries the same marker: its copies are theirs, never updated, merged or removed here.
    private func ours(_ owned: [String: [GoogleCalendarService.OwnedBlock]],
                      on calendarID: String) -> [String: [GoogleCalendarService.OwnedBlock]] {
        let google = GoogleCalendarService.shared
        if google.writeBackCandidates.first(where: { $0.infoID == calendarID })?.isOwner == true { return owned }
        let recorded = Set(ledger.values.filter { $0.calendarID == calendarID }.map(\.eventIdentifier))
        let accounts = Set(google.accounts.map(\.email))
        return owned.compactMapValues { blocks in
            let mine = blocks.filter {
                BusyBlockCleanupPolicy.isOurs(calendarIsOwner: false, eventID: $0.eventID, recordedEventIDs: recorded,
                                              creatorEmail: $0.creatorEmail, accountEmails: accounts)
            }
            return mine.isEmpty ? nil : mine
        }
    }

    /// The planner's view of one calendar: what is wanted there, what Google says Banana owns
    /// there (with what each copy says), and what this device last wrote.
    private static func plan(_ wanted: [DesiredBlock], owned: [String: [GoogleCalendarService.OwnedBlock]],
                             recorded: [String: BusyCopyPlanner.Recorded], now: Date) -> BusyCopyPlanner.CalendarPlan {
        BusyCopyPlanner.plan(
            desired: wanted.map {
                BusyCopyPlanner.Desired(appItemID: $0.appItemID, ledgerKey: $0.ledgerKey, fingerprint: hash($0),
                                        content: GoogleBusyBlocks.content(title: $0.title, start: $0.start,
                                                                          end: $0.end, isAllDay: $0.isAllDay))
            },
            owned: owned.mapValues {
                $0.map { BusyCopyPlanner.Owned(eventID: $0.eventID, etag: $0.etag, end: $0.end, content: $0.content) }
            },
            recorded: recorded,
            now: now)
    }

    private static func hash(_ block: DesiredBlock) -> Int {
        // Swift's Hasher is randomized per process; FNV-1a gives a stable cross-launch fingerprint.
        let fingerprint = [
            block.title,
            String(block.start.timeIntervalSinceReferenceDate.bitPattern),
            String(block.end.timeIntervalSinceReferenceDate.bitPattern),
            block.calendarID,
        ].joined(separator: "\u{1F}") + (block.isAllDay ? "\u{1F}allDay" : "")
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in fingerprint.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return Int(bitPattern: UInt(value))
    }

    /// What this device last wrote on `calendarID`, by ledger key, as the planner reads it.
    private func recordedWrites(on calendarID: String) -> [String: BusyCopyPlanner.Recorded] {
        var recorded: [String: BusyCopyPlanner.Recorded] = [:]
        for (key, entry) in ledger where entry.calendarID == calendarID {
            recorded[key] = BusyCopyPlanner.Recorded(eventID: entry.eventIdentifier,
                                                     fingerprint: entry.writtenHash, etag: entry.writtenETag)
        }
        return recorded
    }

    // MARK: - The first run's preview

    /// The inputs of a pass, whether or not it wrote: what `previewCopies` plans from.
    struct PlanInputs {
        let occurrences: [Occurrence]
        let existingBusyIntervals: [CalendarBusyInterval]
        let excluded: Set<String>
        let includedShared: Set<String>
        let reserveTaskTime: Bool
        let sourcesHealthy: Bool
    }

    /// Why there is no preview, in the words the consent screen shows. Each comes with Retry.
    enum PreviewFailure: Error, Equatable {
        case notConnected, noCalendars, notReady, unreadable

        var message: String {
            switch self {
            case .notConnected: "Connect a Google calendar first."
            case .noCalendars: "None of your calendars can take copies."
            case .notReady: "Your calendars are still loading."
            case .unreadable: "Some calendars couldn\u{2019}t be read."
            }
        }
    }

    enum CopyAnswer: Equatable {
        /// Copies are on: the next pass writes what the preview showed.
        case enabled
        /// The plan changed since it was shown: show this one and ask again.
        case changed(BusyCopyPreview)
        case failed(String)
    }

    private var waitingForInputs: [UUID: CheckedContinuation<PlanInputs?, Never>] = [:]

    private func capture(_ inputs: PlanInputs) {
        guard !waitingForInputs.isEmpty else { return }
        let waiting = waitingForInputs
        waitingForInputs = [:]
        for continuation in waiting.values { continuation.resume(returning: inputs) }
    }

    /// The inputs of the next pass, after asking for one: the settings just chosen on the
    /// calendar step (which calendars show and count as busy) are in them. Nil after `timeout`.
    private func nextInputs(timeout: Duration) async -> PlanInputs? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waitingForInputs[id] = continuation
            OccurrenceStore.shared.requestRecompute(reason: "busy copy preview")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.waitingForInputs.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    /// What turning copies on would do now, planned by the pass that would do it
    /// (`BusyCopyPlanner` over `desiredBlocks`, against what Google says Banana owns on each
    /// calendar). Reads Google; writes nothing.
    func previewCopies() async -> Result<BusyCopyPreview, PreviewFailure> {
        #if DEBUG
        if let sample = Self.samplePreview { return .success(sample) }
        #endif
        refreshCalendars()
        guard calendarAuthorized else { return .failure(.notConnected) }
        guard let inputs = await nextInputs(timeout: .seconds(20)) else { return .failure(.notReady) }
        guard inputs.sourcesHealthy else { return .failure(.unreadable) }
        // Copies are written live once on: plan for that, not for the test calendar.
        let destinations = targetCalendarIDs(excluding: inputs.excluded, includingShared: inputs.includedShared, live: true)
        guard !destinations.isEmpty else { return .failure(.noCalendars) }
        let desired = desiredBlocks(from: inputs.occurrences, destinations: destinations,
                                    existingBusyIntervals: inputs.existingBusyIntervals)
        let byCalendar = Dictionary(grouping: desired, by: \.calendarID)
        let google = GoogleCalendarService.shared
        let titles = Dictionary(google.allCalendarInfos.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let (windowStart, windowEnd) = Self.ownershipWindow()
        let now = Date()
        var preview = BusyCopyPreview(destinations: [], sources: [])
        var sourceIDs: [String?] = []
        for calendarID in Set(destinations).union(google.writeBackCandidates.map(\.infoID)).sorted() {
            guard let raw = GoogleCalendarIDs.rawCalendarID(from: calendarID) else { continue }
            let owned: [String: [GoogleCalendarService.OwnedBlock]]
            do {
                owned = try await ours(google.ownedBusyBlockDetails(calendarID: raw, variant: Self.scheme,
                                                                    from: windowStart, to: windowEnd), on: calendarID)
            } catch where GoogleCalendarService.isCalendarGone(error) {
                continue
            } catch {
                return .failure(.unreadable)
            }
            let wanted = byCalendar[calendarID] ?? []
            let plan = Self.plan(wanted, owned: owned, recorded: recordedWrites(on: calendarID), now: now)
            for write in plan.writes {
                let block: DesiredBlock
                switch write {
                case .create(let index), .update(let index, _, _): block = wanted[index]
                }
                preview.start = min(preview.start ?? block.start, block.start)
                preview.end = max(preview.end ?? block.end, block.end)
                if !sourceIDs.contains(block.sourceCalendarID) { sourceIDs.append(block.sourceCalendarID) }
            }
            guard destinations.contains(calendarID) || plan.removals > 0 else { continue }
            preview.destinations.append(BusyCopyPreview.Destination(
                id: calendarID, title: titles[calendarID] ?? "Calendar",
                creates: plan.creates, updates: plan.updates, removals: plan.removals))
        }
        preview.sources = sourceIDs.map { $0.flatMap { titles[$0] } ?? "Banana" }
        return .success(preview)
    }

    /// The yes on the consent screen. The plan is made again first; if it is not what was
    /// shown, nothing is turned on and the new plan comes back to be shown.
    func turnOnCopies(shown: BusyCopyPreview) async -> CopyAnswer {
        #if DEBUG
        if Self.samplePreview != nil { questionAnswered = true; return .enabled }
        #endif
        switch await previewCopies() {
        case .failure(let failure):
            return .failed(failure.message)
        case .success(let fresh):
            guard shown.agrees(with: fresh) else { return .changed(fresh) }
        }
        guard setEnabled(true) else { return .failed(lastError ?? PreviewFailure.noCalendars.message) }
        answerQuestion()
        return .enabled
    }

    /// "Keep viewing only": an answer, and a success. Nothing was ever written here, so there is
    /// nothing to withdraw; copies that are already on elsewhere are turned off the usual way.
    func keepViewingOnly() {
        if enabled {
            setEnabled(false)
        } else {
            recordUserPreference()
            if SmartScheduleStore.shared.settings.writeBackEnabled != false {
                SmartScheduleStore.shared.settings.writeBackEnabled = false
            }
        }
        answerQuestion()
    }

    #if DEBUG
    /// A simulator has no Google account: `--onboarding-sample` shows the consent screen with
    /// this plan, labelled as the sample it is everywhere it is used.
    static var samplePreview: BusyCopyPreview? {
        guard ProcessInfo.processInfo.arguments.contains("--onboarding-sample") else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        return BusyCopyPreview(
            destinations: [.init(id: "sample-work", title: "Work", creates: 12)],
            sources: ["Personal"], start: start,
            end: Calendar.current.date(byAdding: .day, value: 28, to: start))
    }
    #endif

    // MARK: - Coverage plan and target calendars

    static let testCalendarTitles: Set<String> = [
        "Banana", "Banana (test)",
        "Daypart", "Daypart (test)",
        "Quarters", "Quarters (test)",
    ]

    /// Google calendar info ids blocks are written to this pass.
    private func targetCalendarIDs(excluding excludedCalendarIDs: Set<String>,
                                   includingShared includedShared: Set<String>,
                                   live: Bool? = nil) -> [String] {
        let candidates = GoogleCalendarService.shared.writeBackCandidates
        if !(live ?? goLive) {
            return candidates
                .filter { $0.titles.contains(where: Self.testCalendarTitles.contains) }
                .map(\.infoID)
        }
        return WriteBackDestinations.destinations(
            candidates, excludedIDs: excludedCalendarIDs,
            excludedIdentities: migratedExclusionIdentities, includedShared: includedShared)
    }

    /// Exclusions recorded against Apple Calendar by name — `(account, calendar title)` — which
    /// is how the Family calendar and colleagues' shared calendars stay excluded now that they are
    /// reached through Google under different identifiers.
    private var migratedExclusionIdentities: Set<WriteBackDestinations.Identity> {
        guard let data = defaults.data(forKey: DefaultsKey.excludedCalendarIdentities),
              let stored = try? JSONDecoder().decode(Set<CalendarIdentity>.self, from: data)
        else { return [] }
        return Set(stored.map {
            WriteBackDestinations.Identity(sourceTitle: $0.sourceTitle, calendarTitle: $0.calendarTitle)
        })
    }

    /// Turn the name-based exclusions carried over from Apple Calendar into Google calendar ids,
    /// removing each identity once it has found its calendar — after that the id in the person's
    /// exclusion list is the single source of truth, so turning the calendar back on in the
    /// picker actually turns it on. Identities that match nothing yet (their account is not
    /// connected) are kept and tried again later.
    func consumeLegacyExclusionIdentities(_ candidates: [WriteBackDestinations.Calendar]) -> Set<String> {
        guard let data = defaults.data(forKey: DefaultsKey.excludedCalendarIdentities),
              let stored = try? JSONDecoder().decode(Set<CalendarIdentity>.self, from: data),
              !stored.isEmpty else { return [] }
        var matched = Set<String>()
        var remaining = Set<CalendarIdentity>()
        for identity in stored {
            let hits = WriteBackDestinations.excluded(
                candidates, ids: [],
                identities: [WriteBackDestinations.Identity(sourceTitle: identity.sourceTitle,
                                                            calendarTitle: identity.calendarTitle)])
            if hits.isEmpty { remaining.insert(identity) } else { matched.formUnion(hits) }
        }
        if remaining != stored, let encoded = try? JSONEncoder().encode(remaining) {
            defaults.set(encoded, forKey: DefaultsKey.excludedCalendarIdentities)
        }
        return matched
    }

    private func desiredBlocks(
        from occurrences: [Occurrence],
        destinations: [String],
        existingBusyIntervals: [CalendarBusyInterval]
    ) -> [DesiredBlock] {
        var byExactSlot: [String: DesiredBlock] = [:]
        let reusableCoverageByCalendar = Dictionary(
            grouping: existingBusyIntervals.filter {
                Self.variant.reusesCoverage(
                    markerScheme: $0.appMarkerScheme,
                    appItemID: $0.appItemID
                )
            },
            by: \.calendarID
        )

        for occurrence in occurrences {
            var isAuthoredWork = occurrence.isWritable && occurrence.writePolicy == .busy
            // "Reserve time for tasks" off: tasks stay visual-only in Banana — no real
            // calendar blocks. Reconciliation then deletes any previously written ones.
            if !reserveTaskTime && occurrence.behavior == .task { isAuthoredWork = false }
            // A free-marked event is visible on the timeline but must never be mirrored as a busy
            // block: that would contradict the availability the person set on their own event.
            let isExternalMeeting = occurrence.source == .external
                && occurrence.behavior == .event
                && occurrence.hasScheduledTime
                && occurrence.meeting?.shouldMirrorBusyTime != false
            // A day blocked all day on one calendar is blocked on the others too — Calendly reads
            // one of them. Only one marked Busy: a Free all-day event blocks nothing anywhere.
            let isBlockedDay = occurrence.source == .external && occurrence.blocksWholeDay
            guard isAuthoredWork || isExternalMeeting || isBlockedDay else { continue }

            let sourceCalendarID = isExternalMeeting || isBlockedDay ? occurrence.meeting?.calendarID : nil
            let appItemID = isExternalMeeting || isBlockedDay
                ? externalMirrorID(for: occurrence)
                : WriteBackItemID.forOccurrence(id: occurrence.id, reminderID: occurrence.reminderID,
                                                reminderExternalID: occurrence.reminderExternalID)
            let end = occurrence.resolvedEnd
            guard end > occurrence.start else { continue }

            for calendarID in destinations {
                if calendarID == sourceCalendarID { continue }
                // Already covered there: the same event (an invitation that reached two accounts).
                if isExternalMeeting || isBlockedDay, occurrence.meeting?.alsoOnCalendarIDs.contains(calendarID) == true { continue }
                if hasForeignCoverage(
                    start: occurrence.start,
                    end: end,
                    intervals: reusableCoverageByCalendar[calendarID] ?? []
                ) { continue }

                let keepsTaskTitle = isAuthoredWork && calendarID == liveCalendarID
                let block = DesiredBlock(
                    appItemID: appItemID,
                    calendarID: calendarID,
                    title: keepsTaskTitle ? occurrence.title : "Busy",
                    start: occurrence.start,
                    end: end,
                    isAllDay: isBlockedDay,
                    sourceCalendarID: sourceCalendarID
                )
                let slotKey = [
                    calendarID,
                    String(occurrence.start.timeIntervalSinceReferenceDate.bitPattern),
                    String(end.timeIntervalSinceReferenceDate.bitPattern),
                ].joined(separator: "\u{1F}")
                if let existing = byExactSlot[slotKey] {
                    // One block covers simultaneous commitments. Prefer the titled task on its
                    // task calendar; every other exact duplicate remains a single private Busy.
                    if existing.title == "Busy", block.title != "Busy" {
                        byExactSlot[slotKey] = block
                    } else if existing.title == block.title,
                              block.appItemID < existing.appItemID {
                        byExactSlot[slotKey] = block
                    }
                } else {
                    byExactSlot[slotKey] = block
                }
            }
        }
        return byExactSlot.values.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.ledgerKey < $1.ledgerKey
        }
    }

    private func hasForeignCoverage(
        start: Date,
        end: Date,
        intervals: [CalendarBusyInterval]
    ) -> Bool {
        intervals.contains { interval in
            interval.start <= start.addingTimeInterval(Self.coverageTolerance)
                && interval.end >= end.addingTimeInterval(-Self.coverageTolerance)
        }
    }

    private func externalMirrorID(for occurrence: Occurrence) -> AppItemID {
        GoogleBusyBlocks.mirrorID(title: occurrence.title, start: occurrence.start, end: occurrence.resolvedEnd)
    }

    private func ledgerKey(appItemID: AppItemID, calendarID: String) -> String {
        "\(appItemID)\u{1F}\(calendarID)"
    }

    /// Launch arguments that run a headless probe and exit. The app around the probe still starts
    /// up, so without this a probe launch would reconcile the real calendars as a side effect.
    nonisolated static let diagnosticArguments: Set<String> = ["--google-roundtrip", "--google-window", "--google-dump", "--google-sharing", "--snapshot-app-store",
                                                   "--adopt-legacy-blocks", "--google-sync", "--google-repeat",
                                                   // The offscreen key driver (MailKeyDriver.swift): no write, no hot key, no menu-bar item.
                                                   "--mail-key-script", "--assistant-test", "--assistant-test-navigation", "--assistant-real-test"]
    nonisolated static var isDiagnosticLaunch: Bool {
        #if PI_DEVELOPMENT
        true
        #else
        !diagnosticArguments.isDisjoint(with: ProcessInfo.processInfo.arguments)
        #endif
    }

    // MARK: - Legacy blocks written through Apple Calendar

    /// Whether write-back may run: old blocks have been adopted, there were none, or the person
    /// chose to leave them.
    var adoptionPermitsWriting: Bool {
        switch adoption {
        case .finished, .skipped: return true
        case .notStarted, .awaitingConfirmation, .running: return false
        }
    }

    /// Ledger entries for blocks written through Apple Calendar that have not been adopted.
    private var legacyEntries: [(key: String, entry: LedgerEntry)] {
        ledger.filter { !GoogleCalendarIDs.isCalendarInfoID($0.value.calendarID) }
            .map { ($0.key, $0.value) }
            .sorted { $0.key < $1.key }
    }

    /// Leave old blocks unmanaged and start writing through Google anyway.
    func skipLegacyAdoption() {
        defaults.removeObject(forKey: DefaultsKey.adoptionConfirmed)
        adoption = .skipped
        saveAdoptionState()
    }

    /// The person confirmed the dry run: tag the blocks for real.
    func confirmLegacyAdoption() async {
        guard case .awaitingConfirmation = adoption else { return }
        defaults.set(true, forKey: DefaultsKey.adoptionConfirmed)
        let report = await adoptLegacyBlocks(dryRun: false)
        defaults.set(GoogleCalendarService.shared.writeBackCandidates.map(\.infoID).sorted()
            .joined(separator: ","), forKey: DefaultsKey.adoptionCalendars)
        adoption = .finished(report)
        saveAdoptionState()
    }

    /// Adopt before writing. Runs once, and again whenever the set of Google calendars changes
    /// while unadopted blocks remain — a block on a calendar whose account was signed out when
    /// adoption first ran is adopted when that account comes back, before anything is written to
    /// that calendar.
    private func adoptLegacyBlocksIfNeeded() async {
        let google = GoogleCalendarService.shared
        let signature = google.writeBackCandidates.map(\.infoID).sorted().joined(separator: ",")
        if case .finished = adoption {
            // Not gated on every account being healthy: blocks on a signed-out account's
            // calendars stay pending, and the signature changes when it returns.
            guard !legacyEntries.isEmpty,
                  defaults.string(forKey: DefaultsKey.adoptionCalendars) != signature else { return }
            let report = await adoptLegacyBlocks(dryRun: false)
            guard report.errors.isEmpty else { adoption = .finished(report); return }
            defaults.set(signature, forKey: DefaultsKey.adoptionCalendars)
            adoption = .finished(report)
            saveAdoptionState()
            return
        }
        guard case .notStarted = adoption else { return }
        let pending = legacyEntries.count
        guard pending > 0 else {
            adoption = .finished(LegacyAdoptionReport())
            saveAdoptionState()
            return
        }
        if defaults.bool(forKey: DefaultsKey.adoptionConfirmed) {
            // Confirmed earlier and interrupted before it finished: carry on. Blocks already
            // tagged are recognised as ours and simply re-pointed, so resuming repeats nothing.
            let report = await adoptLegacyBlocks(dryRun: false)
            guard report.errors.isEmpty else { adoption = .notStarted; return }
            defaults.set(signature, forKey: DefaultsKey.adoptionCalendars)
            adoption = .finished(report)
            saveAdoptionState()
            return
        }
        // First time: a dry run only. Nothing is tagged until the person has seen what would be.
        adoption = .running(done: 0, total: 0)
        let preview = await adoptLegacyBlocks(dryRun: true)
        guard preview.errors.isEmpty else { adoption = .notStarted; return }
        // A question is only for something a yes would change. A dry run that would tag nothing
        // (every old block already gone from Google) is finished: asking about it kept both Macs
        // paused, writing and removing nothing, from 3 Nov 2026 until someone found the prompt.
        if LegacyAdoptionDecision.isNothingToConfirm(preview) {
            defaults.set(signature, forKey: DefaultsKey.adoptionCalendars)
            adoption = .finished(preview)
            saveAdoptionState()
            return
        }
        adoption = .awaitingConfirmation(preview)
    }

    /// Find the Google copy of every block written through Apple Calendar, and tag it with
    /// Banana's ownership marker so the Google path manages it from here on.
    ///
    /// Needs no Apple Calendar access: each ledger entry's EventKit identifier ends in the event's
    /// iCalendar UID, which CalDAV carried to Google unchanged, so the Google copy is found by
    /// matching UIDs against one read of the writable calendars (`LegacyBlockMatcher`). The only
    /// change made to Google is adding the two private ownership properties — nothing is moved,
    /// retitled or deleted. An event with attendees, another build's marker, or a UID naming more
    /// than one event is left alone and counted.
    ///
    /// - Parameter foreignLedger: another device's ledger entries (its file, copied here). Their
    ///   blocks are tagged, but this device's ledger is not changed for them. Ownership lives on
    ///   the server, so whichever device tags a block, every device manages it afterwards.
    /// With `dryRun` nothing is written anywhere; the report says what would happen.
    func adoptLegacyBlocks(dryRun: Bool, foreignLedger: [LedgerEntry]? = nil) async -> LegacyAdoptionReport {
        var report = LegacyAdoptionReport()
        report.dryRun = dryRun
        let google = GoogleCalendarService.shared
        let read = await google.writableCalendarEvents()
        guard read.complete else {
            // A calendar we could not read would turn its blocks into "not found" — and a later
            // run would find them. Nothing is decided on a partial read.
            report.errors.append("Not every writable Google calendar could be read; try again when all accounts are connected")
            return report
        }
        let index = LegacyBlockMatcher.index(read.events)
        let entries: [(key: String?, entry: LedgerEntry)] = foreignLedger.map { entries in
            entries.filter { !GoogleCalendarIDs.isCalendarInfoID($0.calendarID) }.map { (nil, $0) }
        } ?? legacyEntries.map { ($0.key, $0.entry) }

        #if os(iOS)
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Busy block takeover")
        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
        #endif
        var toTag: [(key: String?, entry: LedgerEntry, calendarID: String, eventID: String)] = []
        for (key, entry) in entries {
            report.examined += 1
            switch LegacyBlockMatcher.match(eventKitIdentifier: entry.eventIdentifier, in: index,
                                            variant: Self.scheme) {
            case .notFound:
                // Most often a block whose time has passed out of the window read.
                report.notFoundInGoogle += 1
            case .unsafe:
                report.failedChecks += 1
            case .otherVariant:
                report.otherVariant += 1
            case .alreadyOurs(let raw, let eventID, let appItemID):
                report.alreadyAdopted += 1
                if !dryRun, let key {
                    let infoID = GoogleCalendarIDs.calendarInfoID(raw)
                    ledger[key] = nil
                    ledger[ledgerKey(appItemID: appItemID, calendarID: infoID)] =
                        LedgerEntry(appItemID: appItemID, eventIdentifier: eventID,
                                    calendarID: infoID, writtenHash: 0)
                }
            case .adopt(let raw, let eventID):
                if dryRun { report.adopted += 1 } else { toTag.append((key, entry, raw, eventID)) }
            }
        }
        guard !dryRun else {
            Log.writeBack.notice("[adopt] \(report.summary, privacy: .public)")
            return report
        }

        // In batches, several requests in flight at once, the ledger saved after every batch, so
        // an interrupted run loses nothing: a block already tagged is "already ours" next time.
        adoption = .running(done: 0, total: toTag.count)
        let batchSize = 8
        for batchStart in stride(from: 0, to: toTag.count, by: batchSize) {
            let batch = Array(toTag[batchStart..<min(batchStart + batchSize, toTag.count)])
            let tags = batch.map { item in
                Task { @MainActor in
                    try await google.tagAsOwnedBusyBlock(
                        calendarID: item.calendarID, eventID: item.eventID,
                        appItemID: item.entry.appItemID, variant: Self.scheme)
                }
            }
            for (item, tag) in zip(batch, tags) {
                do {
                    try await tag.value
                    report.adopted += 1
                    if let key = item.key {
                        let infoID = GoogleCalendarIDs.calendarInfoID(item.calendarID)
                        ledger[key] = nil
                        // Hash 0: the first sync rewrites it once through Google, which also
                        // applies the private visibility and empty reminders Apple never set.
                        ledger[ledgerKey(appItemID: item.entry.appItemID, calendarID: infoID)] =
                            LedgerEntry(appItemID: item.entry.appItemID, eventIdentifier: item.eventID,
                                        calendarID: infoID, writtenHash: 0)
                    }
                } catch {
                    report.errors.append(error.localizedDescription)
                }
            }
            saveLedger()
            adoption = .running(done: min(batchStart + batchSize, toTag.count), total: toTag.count)
        }
        Log.writeBack.notice("[adopt] \(report.summary, privacy: .public)")
        return report
    }

    /// For the headless probe, after it has run the takeover on this device's own ledger.
    func recordAdoptionFinished(_ report: LegacyAdoptionReport) {
        defaults.set(true, forKey: DefaultsKey.adoptionConfirmed)
        defaults.set(GoogleCalendarService.shared.writeBackCandidates.map(\.infoID).sorted()
            .joined(separator: ","), forKey: DefaultsKey.adoptionCalendars)
        adoption = .finished(report)
        saveAdoptionState()
    }

    private func loadAdoptionState() -> AdoptionState {
        guard let data = defaults.data(forKey: DefaultsKey.adoption),
              let stored = try? JSONDecoder().decode(StoredAdoption.self, from: data)
        else { return .notStarted }
        return stored.skipped ? .skipped : .finished(stored.report)
    }

    private func saveAdoptionState() {
        let stored: StoredAdoption
        switch adoption {
        case .finished(let report): stored = StoredAdoption(skipped: false, report: report)
        case .skipped: stored = StoredAdoption(skipped: true, report: LegacyAdoptionReport())
        default: return
        }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: DefaultsKey.adoption)
        }
    }

    private struct StoredAdoption: Codable {
        let skipped: Bool
        let report: LegacyAdoptionReport
    }

    // MARK: - Ledger persistence

    private var ledgerURL: URL {
        AppSupport.directory.appendingPathComponent("calendar-writeback-ledger.json")
    }

    /// One corrupt entry costs one entry; a wholly unparseable file is quarantined before anything
    /// can overwrite it (`SnapshotLoader`/`LossyArray`). Losing the ledger loses the only record of
    /// which Apple-Calendar-written blocks this device owns — the input to adoption.
    private func loadLedger() {
        switch SnapshotLoader.load(from: ledgerURL, as: LossyArray<LedgerEntry>.self) {
        case .empty:
            break
        case let .loaded(lossy):
            if lossy.droppedCount > 0 {
                Self.log.error("calendar-writeback-ledger.json: dropped \(lossy.droppedCount, privacy: .public) corrupt entry/entries on load; everything else loaded normally")
            }
            ledger = Dictionary(lossy.elements.map {
                (ledgerKey(appItemID: $0.appItemID, calendarID: $0.calendarID), $0)
            }, uniquingKeysWith: { first, _ in first })
        case let .corrupt(error, quarantinedTo):
            if let quarantinedTo {
                Self.log.error("calendar-writeback-ledger.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public). Starting empty.")
            } else {
                ledgerSaveIsUnsafe = true
                Self.log.fault("calendar-writeback-ledger.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save the ledger until this is resolved by hand.")
            }
        }
        ledgerDirty = false
    }

    private func saveLedger() {
        guard ledgerDirty else { return }
        guard !ledgerSaveIsUnsafe else {
            Self.log.fault("saveLedger() refused: no backup of a previously-corrupt calendar-writeback-ledger.json exists yet.")
            return
        }
        guard let data = try? JSONEncoder().encode(Array(ledger.values)) else { return }
        do {
            try data.write(to: ledgerURL, options: .atomic)
            ledgerDirty = false
        } catch {
            // Leave ledgerDirty set so the next sync retries the write.
        }
    }
}
