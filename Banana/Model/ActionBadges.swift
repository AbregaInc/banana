import Combine
import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// The counts behind every "needs you" badge (`ActionItems`): the Plan tab (overdue reminders),
/// Nutrition and its Food and Taken tabs, the Mac sidebar, and the app icon — the iPhone's home
/// screen badge, the Mac's Dock. Recounted when the timeline, the meal backlog or the doses change,
/// and each minute while the app runs (a dose's time arrives, a reminder goes overdue); published
/// only when a count moves, so the shell redraws for nothing else.
@MainActor
final class ActionBadges: ObservableObject {
    static let shared = ActionBadges()

    @Published private(set) var counts = ActionItems.Counts()
    private var watches: Set<AnyCancellable> = []
    private var minute: Timer?
    private var started = false

    /// At launch — a background launch too, so the icon is right after one.
    func start() {
        guard !started else { return }
        started = true
        OccurrenceStore.shared.$occurrences.dropFirst().sink { [weak self] _ in self?.recountSoon() }.store(in: &watches)
        MealInboxStore.shared.$items.dropFirst().sink { [weak self] _ in self?.recountSoon() }.store(in: &watches)
        WellnessStore.shared.$supplements.dropFirst().sink { [weak self] _ in self?.recountSoon() }.store(in: &watches)
        WellnessStore.shared.$supplementLogs.dropFirst().sink { [weak self] _ in self?.recountSoon() }.store(in: &watches)
        // A moment came (a workout ended): what waited for it may be due now.
        AnchoredTimingHub.shared.$version.dropFirst().sink { [weak self] _ in self?.recountSoon() }.store(in: &watches)
        ModuleStore.shared.$choice.dropFirst().sink { [weak self] _ in self?.recountSoon() }.store(in: &watches)
        minute = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ActionBadges.shared.recount() }
        }
        // Kept running in the background on purpose, and not stopped with the Google poll: this is
        // the only writer of the home-screen icon badge, where a dose coming due is looked at with
        // the app away. Some of what it counts moves with the clock (a dose's time, midnight) and
        // some it reads without observing (a wake that arrives in `HealthKitStore.trends`), so no
        // next-change time computed from the clock alone could be exact. 10 % lets the system
        // coalesce the wake with others.
        minute?.tolerance = 6
        recount()
    }

    /// `@Published` announces before it stores: count a turn later, from the stored values.
    private func recountSoon() {
        DispatchQueue.main.async { [weak self] in self?.recount() }
    }

    func recount(now: Date = Date()) {
        let wellness = WellnessStore.shared
        // Food switched off: nothing of it waits, on a tab or on the app's icon.
        let food = ModuleStore.shared.includes(.food)
        let dueRoutines = OccurrenceStore.shared.occurrences.filter { occurrence in
            guard occurrence.behavior == .cue,
                  let routine = RoutineStore.shared.routines.first(where: { $0.id == occurrence.routineID }),
                  routine.cueType == .custom || routine.cueType == .workout else { return false }
            return ActionItems.routineDueSince(start: occurrence.start, hasTime: occurrence.hasScheduledTime,
                completed: occurrence.completed, skipped: occurrence.skipped, now: now) != nil
        }.count
        let next = ActionItems.Counts(
            plan: OccurrenceStore.shared.occurrences.filter(\.isOverdueReminder).count + dueRoutines,
            food: food ? ActionItems.food(MealInboxStore.shared.items) : 0,
            taken: food ? ActionItems.dosesDue(wellness.supplements,
                                               marked: { wellness.supplementStatus($0, on: now) != nil },
                                               due: { AnchoredTimingHub.shared.dueDate($0, now: now) }, now: now) : 0)
        guard next != counts else { return }
        counts = next
        showOnIcon(next.total)
    }

    #if os(iOS)
    /// Badge counts go out one after another, off the main thread: `setBadgeCount` waits on the
    /// notification daemon before it returns, and on the main thread that froze the whole app —
    /// 60 s in a Simulator after a meal left the backlog (14 Oct 2026, a UI test's sample).
    private static let iconQueue = DispatchQueue(label: "ActionBadges.icon", qos: .utility)
    #endif

    private func showOnIcon(_ total: Int) {
        #if os(iOS)
        Self.iconQueue.async { UNUserNotificationCenter.current().setBadgeCount(total) { _ in } }
        #else
        NSApp?.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        #endif
    }
}
