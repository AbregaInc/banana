import Combine
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What Banana has learned about when things are done, offered where they're done
/// (docs/design/ANCHORED-TIMING.md, "Learning it, and moving to Taken"):
/// - a Taken item, or a repeating reminder, that follows the same moment on most days is offered
///   that moment (`AnchorSuggestions`) — in Taken, and above Plan's List;
/// - a repeating reminder that's something you take is offered a move into Taken
///   (`ReminderToTaken`), with its ticks as its doses and its repeat ended in Reminders.
///
/// History is read off what Banana already has: Health's workouts and nights, the meal log,
/// Taken, and Reminders' completed reminders (read when the app comes forward, at most every ten
/// minutes). "No" and "Not now" are kept in iCloud key-value storage, so the phone and the Mac
/// each ask once.
@MainActor
final class AnchorSuggestionStore: ObservableObject {
    static let shared = AnchorSuggestionStore()

    /// Moments Taken items have been following, offered in Taken.
    @Published private(set) var taken: [AnchorSuggestions.Suggestion] = []
    /// Moments repeating reminders have been following, offered above List's Overdue.
    @Published private(set) var reminders: [AnchorSuggestions.Suggestion] = []
    /// Repeating reminders that are something taken, offered a move into Taken.
    @Published private(set) var moves: [ReminderToTaken.Offer] = []

    private let service = RemindersService()
    /// The app's Health store: workouts and nights.
    private weak var health: HealthKitStore?
    private var started = false
    private var watching = false
    private var watches: Set<AnyCancellable> = []
    private var pendingRecompute: Task<Void, Never>?
    private var reading = false
    /// Repeating reminders, and the ticks of the last 60 days, as last read from Reminders.
    private var repeating: [TaskInfo] = []
    private var ticks: [TaskInfo] = []
    private var readAt: Date?
    /// Reminders moved to Taken here, hidden at once rather than when Reminders is next read.
    private var moved: Set<String> = []

    private static let declinedKey = "anchorSuggestions.declined.v1"
    private static let notNowKey = "reminderToTaken.notNow.v1"
    /// Suggestions answered "No", by item and moment: a different moment may still be offered.
    private var declined: Set<String> = []
    /// Reminders answered "Not now" to the move.
    private var notNowIDs: Set<String> = []
    #if DEBUG
    /// `--timing-suggestions`: fixed offers for screenshots, and no EventKit.
    private var previewing = false
    #endif

    init() {
        declined = Self.remembered(Self.declinedKey)
        notNowIDs = Self.remembered(Self.notNowKey)
        LegacyKVS.observeExternalChanges(tier: .personal) {
            let shared = AnchorSuggestionStore.shared
            let declined = shared.declined, notNow = shared.notNowIDs
            shared.declined = Self.remembered(Self.declinedKey)
            shared.notNowIDs = Self.remembered(Self.notNowKey)
            // Late arrivals for the data platform (this runs as one, `LegacyKVS`).
            SyncReport.changed(Self.syncDeclinedType, shared.declined.subtracting(declined).sorted())
            SyncReport.changed(Self.syncNotNowType, shared.notNowIDs.subtracting(notNow).sorted())
            shared.recomputeSoon()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--timing-suggestions") {
            previewing = true
            declined = []
            notNowIDs = []
            watchStores()
            recomputeSoon()
            // `--timing-suggestions-accept` / `-move`: answered on their own, since a Simulator
            // screenshot can't tap — so what follows (the toast, the item) can be looked at.
            let arguments = ProcessInfo.processInfo.arguments
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if arguments.contains("--timing-suggestions-accept"), let first = taken.first ?? reminders.first {
                    accept(first)
                }
                if arguments.contains("--timing-suggestions-move"), let first = moves.first { move(first) }
            }
        }
        #endif
    }

    func start(health: HealthKitStore) {
        guard !started else { return }
        started = true
        self.health = health
        health.$workouts.dropFirst().sink { [weak self] _ in self?.recomputeSoon() }.store(in: &watches)
        health.$trends.dropFirst().sink { [weak self] _ in self?.recomputeSoon() }.store(in: &watches)
        watchStores()
        #if os(iOS)
        let forward = UIApplication.didBecomeActiveNotification
        #else
        let forward = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: forward)
            .sink { [weak self] _ in Task { await self?.refreshIfStale() } }
            .store(in: &watches)
        // Once launch has settled: reading weeks of Reminders can wait a few seconds.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await self?.refreshIfStale()
        }
    }

    private func watchStores() {
        guard !watching else { return }
        watching = true
        let wellness = WellnessStore.shared
        wellness.$supplements.dropFirst().sink { [weak self] _ in self?.recomputeSoon() }.store(in: &watches)
        wellness.$supplementLogs.dropFirst().sink { [weak self] _ in self?.recomputeSoon() }.store(in: &watches)
        wellness.$meals.dropFirst().sink { [weak self] _ in self?.recomputeSoon() }.store(in: &watches)
        ReminderAnchors.shared.$rules.dropFirst().sink { [weak self] _ in self?.recomputeSoon() }.store(in: &watches)
    }

    // MARK: - Reading

    /// Reminders read again when the last read is older than `maxAge`. Everything else is read
    /// off the stores whenever they change.
    func refreshIfStale(maxAge: TimeInterval = 10 * 60) async {
        if let readAt, Date().timeIntervalSince(readAt) < maxAge { return }
        await refresh()
    }

    func refresh(now: Date = Date()) async {
        #if DEBUG
        if previewing { recompute(now: now); return }
        #endif
        guard !reading else { return }
        reading = true
        defer { reading = false }
        if service.authorized {
            let calendar = Calendar.current
            let since = calendar.date(byAdding: .day, value: -ReminderToTaken.historyDays,
                                      to: calendar.startOfDay(for: now)) ?? now
            repeating = await service.dueTasks(within: 14).filter { $0.recurrence != .never && !$0.isCompleted }
            ticks = await service.completedTasks(from: since, to: now)
        } else {
            repeating = []
            ticks = []
        }
        readAt = now
        recompute(now: now)
    }

    /// After the stores have settled: `@Published` announces before it stores, and a sync's burst
    /// of changes is one recompute.
    private func recomputeSoon() {
        pendingRecompute?.cancel()
        pendingRecompute = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    // MARK: - Deciding

    func recompute(now: Date = Date(), calendar: Calendar = .current) {
        #if DEBUG
        if previewing { publishPreview(); return }
        #endif
        let wellness = WellnessStore.shared
        let anchors = ReminderAnchors.shared
        let since = calendar.date(byAdding: .day, value: -AnchorSuggestions.days, to: calendar.startOfDay(for: now)) ?? now
        let recentTicks = ticks.filter { ($0.completedAt ?? .distantPast) >= since }
        let doses = wellness.supplementLogs.filter { $0.date >= since }

        // The moments, in the order a tie goes: what happens, then what's ticked.
        var moments: [AnchorSuggestions.Moment] = [
            .init(.workout, times: (health?.workouts ?? []).map(\.end).filter { $0 >= since }),
            .init(.wake, times: (health?.trends.nights ?? []).map(\.wake).filter { $0 >= since }),
        ]
        let meals = wellness.meals.map(\.date).filter { $0 >= since }
        for part in [MealTextPart.breakfast, .lunch, .dinner] {
            moments.append(.init(.meal(part.rawValue),
                                 times: meals.filter { AnchoredTiming.mealPart(at: $0, calendar: calendar) == part }))
        }
        moments.append(.init(.meal(nil), times: meals))
        let byTitle = Dictionary(grouping: recentTicks) { Self.titleKey($0.title) }
        for key in byTitle.keys.sorted() {
            guard let group = byTitle[key], group.count >= AnchorSuggestions.minimumDays else { continue }
            let live = repeating.first { Self.titleKey($0.title) == key }
            let title = live?.title ?? group[0].title
            moments.append(.init(.reminder(id: live?.externalID ?? group.compactMap(\.externalID).first ?? key, title: title),
                                 times: group.compactMap(\.completedAt),
                                 anchoredTo: anchors.anchor(externalID: live?.externalID, title: title)?.moment))
        }
        for supplement in wellness.supplements {
            moments.append(.init(.dose(id: supplement.id, name: supplement.name),
                                 times: AnchorSuggestions.observed(doses, for: supplement, calendar: calendar),
                                 anchoredTo: supplement.anchor?.moment))
        }

        // The items: every Taken item, every repeating reminder.
        var items = wellness.supplements.map { supplement in
            AnchorSuggestions.Item(subject: .taken(supplement.id), name: supplement.name,
                                   done: AnchorSuggestions.observed(doses, for: supplement, calendar: calendar),
                                   anchored: supplement.anchor != nil)
        }
        for reminder in repeating {
            items.append(.init(subject: .reminder(externalID: reminder.externalID, title: reminder.title),
                               name: reminder.title,
                               done: Self.completions(of: reminder.externalID, title: reminder.title, in: recentTicks),
                               anchored: anchors.anchor(externalID: reminder.externalID, title: reminder.title) != nil))
        }
        let learned = AnchorSuggestions.suggestions(items, moments: moments, now: now, calendar: calendar)
            .filter { !declined.contains($0.id) && !moved.contains(AnchorSuggestions.key($0.subject)) }

        // Reminders that are something taken, unless one by that name is in Taken already.
        let inTaken = Set(wellness.supplements.map { Self.titleKey($0.name) })
        // Something taken by name (`ReminderToTaken`, the bundled vocabulary), or — for a name no
        // list knows — by the on-device model's guess (`TakenGuess`), asked once below.
        let offers = repeating
            .filter { reminder in
                ReminderToTaken.isCandidate(title: reminder.title, recurrence: reminder.recurrence, completed: reminder.isCompleted)
                    || ((reminder.recurrence == .daily || reminder.recurrence == .weekly) && !reminder.isCompleted
                        && !ReminderToTaken.mentionsNotTaken(reminder.title)
                        && TakenGuess.known(reminder.title) == true)
            }
            .map { reminder in
                let subject = AnchorSuggestions.Item.Subject.reminder(externalID: reminder.externalID, title: reminder.title)
                return ReminderToTaken.Offer(
                    reminderID: reminder.id, externalID: reminder.externalID, title: reminder.title,
                    due: reminder.due, hasTime: reminder.hasTime,
                    anchor: anchors.anchor(externalID: reminder.externalID, title: reminder.title)
                        ?? learned.first { $0.subject == subject }?.anchor)
            }
            .filter { !notNowIDs.contains($0.id) && !moved.contains($0.id) && !inTaken.contains(Self.titleKey($0.name)) }

        publish(taken: learned.filter(\.subject.isTaken), reminders: learned.filter { !$0.subject.isTaken },
                moves: offers)

        // Names no list knows, short enough to be a thing rather than a task: ask the model once.
        let unknown = repeating.filter { reminder in
            !ReminderToTaken.readsAsTaken(reminder.title) && !ReminderToTaken.mentionsNotTaken(reminder.title)
                && TakenGuess.known(reminder.title) == nil
                && reminder.title.split(separator: " ").count <= 4
        }.map(\.title)
        if !unknown.isEmpty {
            Task { @MainActor [weak self] in
                if await TakenGuess.ask(unknown) { self?.recompute() }
            }
        }
    }

    /// Only what changed: an unchanged list republished redraws Plan's List for nothing.
    private func publish(taken: [AnchorSuggestions.Suggestion], reminders: [AnchorSuggestions.Suggestion],
                         moves: [ReminderToTaken.Offer]) {
        if taken != self.taken { self.taken = taken }
        if reminders != self.reminders { self.reminders = reminders }
        if moves != self.moves { self.moves = moves }
    }

    /// A reminder's ticks: completed copies under its stable id or its title.
    private static func completions(of externalID: String?, title: String, in list: [TaskInfo]) -> [Date] {
        let key = titleKey(title)
        return list.filter { ($0.externalID != nil && $0.externalID == externalID) || titleKey($0.title) == key }
            .compactMap(\.completedAt)
    }

    private static func titleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Answers

    /// "Make it so": due around the moment from now on, with Undo putting back what it had.
    func accept(_ suggestion: AnchorSuggestions.Suggestion) {
        let message = "\(suggestion.name) is now due \(ReminderToTaken.lowercasedFirst(AnchoredTiming.label(suggestion.anchor)))"
        switch suggestion.subject {
        case .taken(let id):
            let wellness = WellnessStore.shared
            guard var item = wellness.supplements.first(where: { $0.id == id }) else { return }
            let before = item.anchor
            item.anchor = suggestion.anchor
            wellness.upsertSupplement(item)
            recompute()
            offerUndo(message) {
                guard var item = WellnessStore.shared.supplements.first(where: { $0.id == id }) else {
                    return "it has been deleted"
                }
                item.anchor = before
                WellnessStore.shared.upsertSupplement(item)
                return nil
            }
        case .reminder(let externalID, let title):
            let rules = ReminderAnchors.shared
            let before = rules.anchor(externalID: externalID, title: title)
            rules.set(suggestion.anchor, externalID: externalID, title: title)
            recompute()
            offerUndo(message) {
                ReminderAnchors.shared.set(before, externalID: externalID, title: title)
                return nil
            }
        }
    }

    /// "No": not asked again for this item and moment, here or on the other devices.
    func decline(_ suggestion: AnchorSuggestions.Suggestion) {
        declined.insert(suggestion.id)
        remember(declined, Self.declinedKey)
        SyncReport.changed(Self.syncDeclinedType, [suggestion.id])
        recompute()
    }

    /// "Move to Taken…" on any repeating reminder, whatever its name says — the lists and the
    /// model only decide what's offered unasked.
    func move(reminder occurrence: Occurrence) {
        guard let id = occurrence.reminderID else { return }
        let anchors = ReminderAnchors.shared
        let external = occurrence.reminderExternalID
        var due = occurrence.schedule.constraints?.deadline ?? occurrence.start
        // Tied, today's due may have moved to its moment: its own time is what Taken keeps.
        if let usual = anchors.usualMinutes(externalID: external, title: occurrence.title),
           let own = Calendar.current.date(bySettingHour: usual / 60, minute: usual % 60, second: 0, of: due) {
            due = own
        }
        let subject = AnchorSuggestions.Item.Subject.reminder(externalID: external, title: occurrence.title)
        move(ReminderToTaken.Offer(
            reminderID: id, externalID: external, title: occurrence.title, due: due,
            hasTime: occurrence.hasScheduledTime || occurrence.waitingFor != nil
                || anchors.usualMinutes(externalID: external, title: occurrence.title) != nil,
            anchor: anchors.anchor(externalID: external, title: occurrence.title)
                ?? reminders.first { $0.subject == subject }?.anchor))
    }

    /// "Not now" to a move: not asked again for this reminder.
    func notNow(_ offer: ReminderToTaken.Offer) {
        notNowIDs.insert(offer.id)
        remember(notNowIDs, Self.notNowKey)
        SyncReport.changed(Self.syncNotNowType, [offer.id])
        recompute()
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `KeyValueAdapters`): one record per answer

    static let syncDeclinedType = "plan.declinedSuggestion"
    static let syncNotNowType = "plan.notNow"

    var syncDeclined: Set<String> { declined }
    var syncNotNow: Set<String> { notNowIDs }

    /// Other devices' answers (false: taken back there), kept the usual way.
    func applySynced(declined changes: [String: Bool]) {
        let next = changes.reduce(into: declined) { set, change in
            if change.value { set.insert(change.key) } else { set.remove(change.key) }
        }
        guard next != declined else { return }
        declined = next
        remember(declined, Self.declinedKey)
        recomputeSoon()
    }

    func applySynced(notNow changes: [String: Bool]) {
        let next = changes.reduce(into: notNowIDs) { set, change in
            if change.value { set.insert(change.key) } else { set.remove(change.key) }
        }
        guard next != notNowIDs else { return }
        notNowIDs = next
        remember(notNowIDs, Self.notNowKey)
        recomputeSoon()
    }

    /// Moves a reminder into Taken, shown at once: the Taken item (with its anchor), its ticks of
    /// the last 60 days as doses taken, and then — in Reminders — its repeat ended and it ticked,
    /// so it stops coming back. If Reminders won't take the change, the Taken item goes again.
    /// Undo puts the reminder back exactly and removes the Taken item and its doses.
    func move(_ offer: ReminderToTaken.Offer, now: Date = Date()) {
        let wellness = WellnessStore.shared
        let schedule = ReminderToTaken.schedule(for: offer)
        let logs = ReminderToTaken.logs(for: schedule.id,
                                        completions: Self.completions(of: offer.externalID, title: offer.title, in: ticks),
                                        now: now)
        moved.insert(offer.id)
        wellness.upsertSupplement(schedule)
        wellness.importSupplementLogs(logs)
        recompute()

        let ended: RemindersService.EndedRepeat?
        do {
            ended = try endRepeat(offer)
        } catch {
            Log.sync.error("move to Taken failed: \(error.localizedDescription, privacy: .public)")
            wellness.deleteSupplement(schedule.id)
            moved.remove(offer.id)
            recompute()
            ToastCenter.shared.notify("Couldn\u{2019}t move \(offer.name) to Taken \u{2014} Reminders didn\u{2019}t save the change")
            return
        }
        Log.sync.notice("moved a reminder to Taken doses=\(logs.count, privacy: .public)")
        OccurrenceStore.shared.requestRecompute(reason: "moved to Taken")
        let service = service
        offerUndo("Moved \(offer.name) to Taken") { [weak self] in
            // The reminder first: if it can't come back, the Taken item stays, so nothing is lost.
            if let ended {
                do { try service.restoreRepeat(ended) } catch { return "Reminders didn\u{2019}t save the change" }
            }
            WellnessStore.shared.deleteSupplement(schedule.id)
            self?.moved.remove(offer.id)
            OccurrenceStore.shared.requestRecompute(reason: "move to Taken undone")
            await self?.refresh()
            return nil
        }
    }

    private func endRepeat(_ offer: ReminderToTaken.Offer) throws -> RemindersService.EndedRepeat? {
        #if DEBUG
        if previewing { return nil }
        #endif
        return try service.endRepeat(offer.reminderID)
    }

    private func offerUndo(_ message: String, undo: @escaping () async -> String?) {
        Task { await ToastCenter.shared.offerUndo(message, undo: undo) }
    }

    // MARK: - Remembered answers

    private static func remembered(_ key: String) -> Set<String> {
        Set((LegacyKVS.shared.array(forKey: key) as? [String])
            ?? UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// Kept to the most recent few hundred: an answer about an item long gone needn't travel.
    private func remember(_ answers: Set<String>, _ key: String) {
        #if DEBUG
        if previewing { return }
        #endif
        let list = Array(answers.sorted().suffix(300))
        LegacyKVS.shared.set(list, forKey: key)
        UserDefaults.standard.set(list, forKey: key)
    }

    // MARK: - Preview

    #if DEBUG
    /// What the cards look like with a habit found: a Taken item that follows breakfast, and
    /// Creatine, a reminder, after the workout — offered as an anchor in Plan and a move in Taken.
    private func publishPreview() {
        let wellness = WellnessStore.shared
        let anchors = ReminderAnchors.shared
        var taken: [AnchorSuggestions.Suggestion] = []
        if let item = wellness.supplements.first(where: { $0.anchor == nil && $0.kind == .supplement }) {
            taken.append(.init(subject: .taken(item.id), name: item.name,
                               anchor: TimingAnchor(moment: .meal(MealTextPart.breakfast.rawValue), minutes: 15),
                               followed: 9, together: 12, spread: 4))
        }
        let creatine = TimingAnchor(moment: .workout, minutes: 15)
        let subject = AnchorSuggestions.Item.Subject.reminder(externalID: "preview-creatine", title: "Creatine")
        var reminders: [AnchorSuggestions.Suggestion] = []
        if anchors.anchor(externalID: "preview-creatine", title: "Creatine") == nil {
            reminders.append(.init(subject: subject, name: "Creatine", anchor: creatine, followed: 6, together: 8, spread: 5))
        }
        let evening = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())
        let offer = ReminderToTaken.Offer(reminderID: "preview-creatine", externalID: "preview-creatine",
                                          title: "Creatine", due: evening, hasTime: true, anchor: creatine)
        let inTaken = wellness.supplements.contains { Self.titleKey($0.name) == "creatine" }
        publish(taken: taken.filter { !declined.contains($0.id) },
                reminders: reminders.filter { !declined.contains($0.id) },
                moves: [offer].filter { !notNowIDs.contains($0.id) && !moved.contains($0.id) && !inTaken })
    }
    #endif
}
