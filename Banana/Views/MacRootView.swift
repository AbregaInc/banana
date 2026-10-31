#if os(macOS)
import AppKit
import SwiftUI

/// The Mac's shell — a real Mac window, not an iPhone screen stretched wide.
///
/// The iOS shell is a `TabView` with a bottom accessory and a tab bar that collapses on scroll:
/// answers to a phone's constraints. A Mac's idiom is a source list on the left and content on the
/// right, driven from the keyboard and the menu bar. So the *shell* is per-platform — but the
/// content is the same shared views (`PlannerTab`, `RoutinesView`, `PodcastsView`, `SettingsView`),
/// driven by the same occurrence engine and scheduler. Nothing about the day is re-implemented; only
/// the frame around it knows it's on a Mac.
///
/// Workouts is Watch-recorded fitness synced through the phone — the Mac has no Watch of its own,
/// so it reads that synced cache rather than recording anything locally.

/// `AppSection` is shared with the iOS tab bar (`Banana/Model/AppSection.swift`); this alias keeps
/// existing `MacSection` call sites compiling for one release while they migrate.
typealias MacSection = AppSection

/// Shared so menu-bar commands (⌘1…⌘n) can drive the same selection the sidebar shows.
@MainActor
final class MacNavigator: ObservableObject {
    static let shared = MacNavigator()
    @Published var section: AppSection = .plan
    @Published var showFullPlayer = false
    /// Set by the Morning Briefing menu command (⌘⇧M) and by `MacPayoffPresenter`'s own schedule
    /// check, so both paths open the same sheet instead of each owning a separate `@State`.
    @Published var showMorningBriefing = false
    /// The meeting whose detail drawer (right-hand inspector) is open, if any. Set from any
    /// event row click; the desktop's spare width shows the full event instead of a sheet.
    @Published var inspectedMeeting: MeetingInfo? {
        didSet { if inspectedMeeting != nil { showsAvailability = false } }
    }
    /// The share-availability panel, in the same right-hand slot as the event drawer — the grid
    /// stays in view so the offered times can be seen in place (`offeredSlots`).
    @Published var showsAvailability = false {
        didSet {
            if showsAvailability { inspectedMeeting = nil } else { offeredSlots = [] }
        }
    }
    @Published var offeredSlots: [DateInterval] = []

    private init() {
        // `--mac-section workouts|routines|library|settings` opens straight to a surface, so it can
        // be captured with `screencapture -l <windowid>` in the background — no keystrokes fired
        // into whatever the person is actually doing on their screen. The legacy `rhythm` value
        // keeps working for one release.
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if args.contains("--open-availability") { showsAvailability = true }
        #endif
        if let i = args.firstIndex(of: "--mac-section"), i + 1 < args.count {
            let raw = args[i + 1]
            if let sec = AppSection(rawValue: raw) ?? AppSection(legacyRawValue: raw) {
                section = sec
            }
        }
    }
}

/// The Mac's first run is the phone's (`OnboardingView`): a welcome, the calendar for someone
/// starting with their plan, then the app. Nothing has to be connected to get in.
///
/// It used to be its own screen with one button, "Connect Google Calendar", and no way past it,
/// shown again whenever the account dropped out, while the phone said "Nothing is required".
/// A Mac without a calendar now opens like a phone without one: the plan has a "Google Calendar"
/// card with a Connect button above the day (`PlanPromptCard`), which is also what keeps a
/// missing account from reading as an open day.
struct MacGatedRootView: View {
    @EnvironmentObject private var onboarding: OnboardingStore
    @Environment(\.scenePhase) private var scenePhase

    private var showsFirstRun: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--calendar-onboarding") { return true }
        if arguments.contains("--ui-audit") || arguments.contains("--snapshot-app-store") { return false }
        #endif
        return OnboardingFlow.showsFirstRun(completed: onboarding.completed)
    }

    var body: some View {
        Group {
            if showsFirstRun {
                OnboardingView()
                    .frame(minWidth: 760, minHeight: 620)
            } else {
                MacRootView()
            }
        }
        .task { await onboarding.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await onboarding.refresh() }
            Task { await WorkoutRevertInbox.shared.settle() }   // a Revert asked for on another device
        }
    }
}

struct MacRootView: View {
    /// Review; in the layout harness, `--trend <id>` opens one measure.
    @ViewBuilder private var macReview: some View {
        #if DEBUG
        if let kind = MetricKind.launchArgument {
            NavigationStack { TrendDetailView(kind: kind, window: .month) }
        } else {
            ReviewView()
        }
        #else
        ReviewView()
        #endif
    }

    /// Offscreen drivers and visual audits must not start foreground sync.
    private static var isolatedPreview: Bool {
        #if DEBUG
        MailKeyDriver.requested || ProcessInfo.processInfo.arguments.contains("--ui-audit")
            || ProcessInfo.processInfo.arguments.contains("--snapshot-app-store")
        #else
        false
        #endif
    }

    @ObservedObject private var nav = MacNavigator.shared
    @ObservedObject private var backup = CloudBackup.shared
    @ObservedObject private var commands = MacCommandCenter.shared
    @ObservedObject private var badges = ActionBadges.shared
    @ObservedObject private var modules = ModuleStore.shared

    /// What's waiting on you in a section: overdue reminders in Plan; meals to log and doses due
    /// in Nutrition.
    private func badgeCount(_ section: AppSection) -> Int {
        switch section {
        case .plan: badges.counts.plan
        case .nutrition: badges.counts.nutrition
        default: 0
        }
    }

    @EnvironmentObject private var player: PlayerController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            // Selected by the rows' own ids, which a List gives them whatever modifiers follow.
            // It was `.tag(section)` with `.badge` after it: the badge hid the tag, the rows fell
            // back to their ids, and no click on the sidebar matched a section — it did nothing
            // anywhere, and nothing was ever highlighted.
            List(AppSection.macSidebar(with: modules.choice), selection: Binding<AppSection.ID?>(
                get: { nav.section.id },
                set: { nav.section = AppSection.chosen($0, current: nav.section) }
            )) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(badgeCount(section))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            .navigationTitle("Banana")
        } detail: {
            VStack(spacing: 0) {
                // The event drawer is a plain in-content panel, NOT `.inspector`: the system
                // inspector splits the window toolbar (trailing items jump above the panel) and
                // clips the content instead of re-laying it out, which threw the week grid's
                // columns out of alignment. A plain HStack keeps the toolbar continuous across
                // the window and gives the content its true remaining width.
                HStack(spacing: 0) {
                    Group {
                        // A section whose module is off shows Plan.
                        switch nav.section.shown(with: modules.choice) {
                        case .plan:      PlannerTab()
                        // Mail measures its own column and chooses its columns for it; on a Mac it
                        // is never narrower than the regular class's threshold (MAIL-UX 2.2).
                        case .mail:
                            #if BANANA_UNRELEASED
                            MailSection().frame(minWidth: LayoutClass.regularWidth)
                            #else
                            ContentUnavailableView("Email is coming soon", systemImage: "envelope")
                            #endif
                        case .workouts:  WideWorkoutsView().syncWaitingNote(.fitness).onAppear { SpaceSyncQuestions.shared.healthUsed() }
                        // Sleep and Trends had rows of their own; both are inside Review.
                        case .sleep, .trends, .review: macReview.syncWaitingNote(.fitness)
                        case .nutrition: WideNutritionView().syncWaitingNote(.wellness).onAppear { SpaceSyncQuestions.shared.healthUsed() }
                        case .notes:     NotesView()
                        case .routines:  RoutinesView()
                        // Told how much room it has, so a wide window gets the grid of shows.
                        case .library:   PodcastsView().measuresLayoutClass().syncWaitingNote(.controls)
                        // Settings is its own window (the `Settings` scene); a place kept from
                        // before it moved opens Plan.
                        case .settings:  PlannerTab()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A module switched off (here or on another device) takes its section with it.
                    .onChange(of: modules.choice, initial: true) { _, choice in
                        if !nav.section.isShown(with: choice) { nav.section = .plan }
                    }
                    // One toast for every section, centred on the content, not the drawer.
                    .toastHost()
                    // "Skipped an ad · Undo", whatever section is showing — as on the phone. It
                    // was only inside the full player, so a skip made while planning went unseen.
                    .overlay(alignment: .bottom) {
                        SkipNoticeBar()
                            .frame(maxWidth: 440)
                            .padding(.bottom, DS.Space.l)
                    }
                    // Pull listening progress each time the Mac is switched to, as the phone does
                    // coming forward. Only a launch or playing here used to fetch it, so a Mac left
                    // running for days kept showing episodes finished on the phone as unplayed.
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        guard !Self.isolatedPreview else { return }
                        CloudProgressSync.shared.flushNow(reason: "foreground")
                        Telemetry.shared.calendarConnected = { !GoogleCalendarService.shared.accounts.isEmpty }
                        Telemetry.shared.setup = { await TelemetryState.signals() }
                        Telemetry.shared.session = { BananaAccount.shared.authorization }
                        BananaAccount.shared.start()
                        Telemetry.shared.cameForward()
                        DiagnosticReports.shared.send()                 // crash and performance reports waiting
                        // Now, then every minute — and it keeps going in the background: a Mac
                        // left open should keep up with the phone too.
                        CloudSyncPoll.resume()
                    }
                    .task { if !Self.isolatedPreview { CloudSyncPoll.resume() } }
                    #if DEBUG
                    // `--open-settings`: the Settings window open beside the main one, to look at
                    // and to photograph (it has no sidebar row to open it by).
                    .task {
                        if ProcessInfo.processInfo.arguments.contains("--open-settings") { openSettings() }
                    }
                    .task {
                        if ProcessInfo.processInfo.arguments.contains("--toast-preview") {
                            ToastCenter.shared.showPreview("Deleted \u{201C}Client review\u{201D}")
                        }
                    }
                    #endif
                    if let meeting = nav.inspectedMeeting {
                        Divider()
                        MacEventInspectorView(meeting: meeting)
                            .frame(width: 350)
                            .transition(.move(edge: .trailing))
                    } else if nav.showsAvailability {
                        Divider()
                        MacAvailabilityPanel()
                            .frame(width: 340)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.snappy(duration: 0.2), value: nav.inspectedMeeting != nil)
                .animation(.snappy(duration: 0.2), value: nav.showsAvailability)

                // Playback transport, always present while something is loaded — the iOS shell put
                // this in the tab bar's bottom accessory; the Mac had NO transport at all, so you
                // could start an episode and then lose all control of it. A persistent bottom bar is
                // the Music/Podcasts-app idiom.
                if player.currentEpisode != nil {
                    Divider()
                    NowPlayingBar(onExpand: { nav.showFullPlayer = true })
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .sheet(isPresented: $nav.showFullPlayer) { NowPlayingView() }
        }
        // The iCloud snapshot restore prompt only lived in the iOS RootView, so on the Mac a backup
        // found by checkForRestore() was detected but never offered — which is why nothing from the
        // phone carried over here. Mirror the prompt. Never applied without an explicit yes.
        .alert("Restore from iCloud?", isPresented: .constant(backup.pendingRestore != nil)) {
            Button("Restore") { if let snap = backup.pendingRestore { backup.restore(snap) } }
            Button(backup.restoreDeclineTitle, role: .cancel) { backup.discardPendingRestore() }
        } message: {
            if let snap = backup.pendingRestore {
                let _ = snap
                Text(backup.restoreQuestion)
            }
        }
        // The wake payoff and the workout payoff live in a zero-size child (MacPayoffPresenter):
        // it watches the fitness/health/schedule stores, and those must not invalidate the
        // shell that hosts every section.
        .background { MacPayoffPresenter() }
        // ⌘K floats over everything, like Spotlight; clicking outside dismisses it.
        .overlay {
            if commands.showsCommandMenu {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                        .onTapGesture { commands.showsCommandMenu = false }
                    MacCommandMenu()
                        .padding(.top, 90)
                }
            }
        }
        .sheet(isPresented: $commands.showsShortcuts) { MacShortcutsSheet() }
        #if DEBUG
        // `--mac-window-size 1320x840`: the window at a known size, for the store's screenshots.
        // It otherwise opens wherever it was last left, at whatever size.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "--mac-window-size"), i + 1 < args.count else { return }
            let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            window.setContentSize(NSSize(width: parts[0], height: parts[1]))
            window.center()
        }
        #endif
        .onAppear { MacKeyMonitor.shared.install() }
    }
}

/// Presents the morning briefing (Mac edition) and the post-workout review.
///
/// iOS shows the briefing when the alarm rang; a Mac has no alarm, so the cue is the first time
/// the app is used in the morning (MorningBriefingSchedule). The review shows the first time the
/// app is used after a workout synced here — and straight away if it lands while the app is in
/// front. Both live in this separate view so FitnessStore / HealthKitStore / SmartScheduleStore
/// publishes invalidate a view with no body, not MacRootView and every section under it.
private struct MacPayoffPresenter: View {
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var smart: SmartScheduleStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var review = WorkoutReviewCoordinator.shared
    @ObservedObject private var nav = MacNavigator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Sleep, HRV and resting HR come from the phone's synced Health cache. Bound to
            // `MacNavigator.showMorningBriefing` (not local @State) so the ⌘⇧M menu command opens
            // the same sheet this schedule check does, instead of each owning its own flag.
            .sheet(isPresented: $nav.showMorningBriefing) {
                MorningBriefingView()
                    .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
            }
            // Dismissal clears `pending`.
            .sheet(item: $review.pending) { subject in
                PostWorkoutReviewView(subject: subject)
            }
            .task { checkPayoffScreens() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    checkPayoffScreens()
                    adoptGoogleAccountsAddedElsewhere()
                }
            }
            .onChange(of: fitness.summaries.count) { _, _ in checkWorkoutReview() }
            .onChange(of: health.workouts.count) { _, _ in checkWorkoutReview() }
    }

    /// A Google account connected on the phone arrives here through iCloud Keychain, but the
    /// credential store is only read at launch — so a Mac left open all day never saw it.
    private func adoptGoogleAccountsAddedElsewhere() {
        Task { @MainActor in
            guard GoogleCalendarService.shared.adoptAccountsFromStore() else { return }
            await GoogleCalendarService.shared.refresh()
            OccurrenceStore.shared.requestRecompute(reason: "Google account added on another device")
        }
    }

    private func checkPayoffScreens() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--workout-review") {
            Task {
                await fitness.whenLoaded()   // the index decode sweeps preview fixtures it beats
                fitness.injectSampleForPreview()
                if let summary = fitness.summaries.first, review.pending == nil {
                    review.pending = WorkoutReviewSubject(summary: summary, health: nil)
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--morning-briefing") { nav.showMorningBriefing = true; return }
        guard !WorkoutReviewCoordinator.isSuppressedByLaunchArguments else { return }
        #endif
        checkMorningBriefing()
        checkWorkoutReview()
    }

    private func checkMorningBriefing() {
        guard settings.macMorningBriefing else { return }   // ⌘⇧M still opens it — only the auto-present is gated
        guard scenePhase == .active, !nav.showMorningBriefing, review.pending == nil else { return }
        let now = Date()
        let plannedWake = smart.planDay(for: now)?.wake
        guard MorningBriefingSchedule.shouldShow(now: now, plannedWake: plannedWake,
                                                lastShownDay: MorningBriefingSchedule.lastShownDay()) else { return }
        MorningBriefingSchedule.markShown(now)
        nav.showMorningBriefing = true
    }

    /// The briefing owns the morning; a workout that arrives during it is not consumed and shows
    /// the next time the app is used.
    private func checkWorkoutReview() {
        #if DEBUG
        guard !WorkoutReviewCoordinator.isSuppressedByLaunchArguments else { return }
        #endif
        guard scenePhase == .active, !nav.showMorningBriefing else { return }
        review.check(summaries: fitness.summaries, healthWorkouts: health.workouts)
    }
}

/// Menu-bar commands: navigate from the keyboard.
struct MacCommands: Commands {
    @ObservedObject private var nav = MacNavigator.shared
    @ObservedObject private var booking = BookingCenter.shared
    @ObservedObject private var modules = ModuleStore.shared

    var body: some Commands {
        // Replace the default "New Window" with real navigation — a single-window app doesn't want
        // ⌘N spawning empties.
        // ⌘, opens the Settings window: the `Settings` scene puts it in the app menu itself.
        CommandGroup(replacing: .newItem) {
            // File › New makes the thing the section in front makes (MAIL-UX 4.3): a message in
            // Mail, an event everywhere else.
            Button(nav.section == .mail ? "New Message" : "New Event") {
                #if BANANA_UNRELEASED
                if nav.section == .mail {
                    MailSession.existing?.compose()
                    return
                }
                #endif
                nav.section = .plan
                NotificationCenter.default.post(name: .macNewEventRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Task") {
                nav.section = .plan
                NotificationCenter.default.post(name: .macNewTaskRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            // `CommandGroup`'s content closure is a `@ViewBuilder` (menu commands are just Views
            // under the hood), so `ForEach` over `AppSection.macShortcuts` works here — the
            // numbers come from that array's order, not a hand-typed list, so inserting a section
            // renumbers everything after it automatically.
            // Only the sections shown, numbered without gaps.
            ForEach(Array(AppSection.macShortcuts.filter { $0.isShown(with: modules.choice) }.prefix(9).enumerated()), id: \.element) { index, section in
                Button(section.title) { nav.section = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Refresh Calendar") {
                // ⌘R is the universal Mac "reload" shortcut: a real force-refresh, handled by
                // `MacWeekView`.
                nav.section = .plan
                DiagnosticJournal.shared.record(
                    operation: "calendar.manualRefresh",
                    name: "manual refresh",
                    attributes: ["source": "cmd-r"])
                NotificationCenter.default.post(name: .macForceRefreshRequested, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
            Button("Morning Briefing") {
                nav.showMorningBriefing = true
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Command Menu…") {
                // With words selected in a message he is writing, ⌘K is a link (MAIL-UX 4.2.6).
                #if BANANA_UNRELEASED
                if MailSession.existing?.composer?.format.requestLink() == true { return }
                #endif
                MacCommandCenter.shared.showsCommandMenu.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("Keyboard Shortcuts") {
                MacCommandCenter.shared.showsShortcuts = true
            }
            .keyboardShortcut("/", modifiers: .command)
            Button("Join Next Meeting") {
                MacCommandCenter.shared.perform(.joinNextMeeting)
            }
        }
        // The calendar's sharing: the booking link (copied, with the shortcut BOOKING.md §12 names)
        // and the availability panel.
        CommandMenu("Calendar") {
            Button("Copy Booking Link") { booking.copyLink() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!booking.canShare)
            Button("Share Availability\u{2026}") { MacCommandCenter.shared.perform(.shareAvailability) }
        }
    }
}

extension Notification.Name {
    /// Was ⌘R's target; its only receiver (TodayView) is never mounted on macOS
    /// (RootView.swift, TodayView's sole caller, is `#if os(iOS)`), so this notification
    /// is no longer posted anywhere. Left in place because TodayView.swift still observes
    /// it — that observer is inert on the Mac either way.
    /// ⌘R from the menu bar → the visible Plan view (MacWeekView or WeekView) force-refreshes
    /// calendar sources and recomputes, exactly like iOS pull-to-refresh.
    static let macForceRefreshRequested = Notification.Name("macForceRefreshRequested")
    static let macNewEventRequested = Notification.Name("macNewEventRequested")
    static let macNewTaskRequested = Notification.Name("macNewTaskRequested")
}
#endif
