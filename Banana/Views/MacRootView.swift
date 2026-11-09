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
    @Published var showsAssistant = false {
        didSet {
            if showsAssistant { inspectedMeeting = nil; showsAvailability = false }
        }
    }
    /// Set by the Morning Briefing menu command (⌘⇧M) and by `MacPayoffPresenter`'s own schedule
    /// check, so both paths open the same sheet instead of each owning a separate `@State`.
    @Published var showMorningBriefing = false
    /// The meeting whose detail drawer (right-hand inspector) is open, if any. Set from any
    /// event row click; the desktop's spare width shows the full event instead of a sheet.
    @Published var inspectedMeeting: MeetingInfo? {
        didSet { if inspectedMeeting != nil { showsAvailability = false; showsAssistant = false } }
    }
    /// The share-availability panel, in the same right-hand slot as the event drawer — the grid
    /// stays in view so the offered times can be seen in place (`offeredSlots`).
    @Published var showsAvailability = false {
        didSet {
            if showsAvailability { inspectedMeeting = nil; showsAssistant = false } else { offeredSlots = [] }
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
            #if BANANA_MODULE_WORKOUTS
            Task { await WorkoutRevertInbox.shared.settle() }   // a Revert asked for on another device
            #endif
        }
    }
}

struct MacRootView: View {
    /// Review; in the layout harness, `--trend <id>` opens one measure.
    @ViewBuilder private var macReview: some View {
        #if DEBUG && BANANA_MODULE_WORKOUTS
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
        #if PI_DEVELOPMENT
        true
        #elseif DEBUG
        MailKeyDriver.requested || ProcessInfo.processInfo.arguments.contains("--ui-audit")
            || ProcessInfo.processInfo.arguments.contains("--snapshot-app-store")
        #else
        false
        #endif
    }

    #if PI_DEVELOPMENT
    @ObservedObject private var chrome = PageChrome.shared
    #endif
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

    #if BANANA_MODULE_PODCASTS
    @EnvironmentObject private var player: PlayerController
    #endif
    @Environment(\.openSettings) private var openSettings

    /// Which Body page the rail's Body opens: the one looked at last.
    @State private var lastBody: AppSection = .workouts

    /// The rail's pages: only the modules that are on (docs/design/BOTTOM-BAR-SHELL.md, Wide).
    private var railPages: [ShellPage] {
        var on = ShellPage.Modules()
        #if BANANA_UNRELEASED
        on.mail = modules.includes(.email)
        #endif
        on.workouts = modules.includes(.workouts)
        on.food = modules.includes(.food)
        on.notes = modules.includes(.notes)
        on.library = modules.includes(.podcasts)
        on.review = AppSection.review.isShown(with: modules.effectiveChoice)
        return ShellPage.listed(on)
    }

    private var railCurrent: ShellPage? {
        switch nav.section {
        case .plan: .plan
        case .mail: .mail
        case .workouts, .nutrition: .body
        case .notes: .notes
        case .library: .library
        case .review, .sleep, .trends: .review
        default: nil
        }
    }

    private func openRailPage(_ page: ShellPage) {
        switch page {
        case .plan: nav.section = .plan
        case .mail: nav.section = .mail
        case .body: nav.section = modules.includes(.workouts) && (lastBody == .workouts || !modules.includes(.food)) ? .workouts : .nutrition
        case .notes: nav.section = .notes
        case .library: nav.section = .library
        case .review: nav.section = .review
        case .settings: openSettings()
        }
    }

    var body: some View {
        NavigationSplitView {
            // The rail: round page buttons under the traffic lights, in place of the source list.
            // Routines, which had a row, is in each page's "…" (`MoreMenu`).
            ShellRail(pages: railPages, current: railCurrent, open: openRailPage)
                .navigationSplitViewColumnWidth(min: ShellRail.width, ideal: ShellRail.width, max: ShellRail.width)
                .toolbar(removing: .sidebarToggle)
                // The column widths above are only a request: AppKit's sidebar kept its own
                // minimum (and a width saved from before), ~200 pt in Beta 105. Pin the split
                // view's sidebar item itself.
                .background(MacRailColumnPin(width: ShellRail.width))
                .accessibilityIdentifier("app.sidebar")
        } detail: {
            VStack(spacing: 0) {
                if AppSupport.isPiSampleWorkspace {
                    Label("Sample workspace · Fictional data · Fixtures reset when reopened", systemImage: "flask")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(8)
                        .background(.quaternary)
                }
                // The event drawer is a plain in-content panel, NOT `.inspector`: the system
                // inspector splits the window toolbar (trailing items jump above the panel) and
                // clips the content instead of re-laying it out, which threw the week grid's
                // columns out of alignment. A plain HStack keeps the toolbar continuous across
                // the window and gives the content its true remaining width.
                HStack(spacing: 0) {
                    Group {
                        // A section whose module is off shows Plan.
                        switch nav.section.shown(with: modules.effectiveChoice) {
                        case .plan:      PlannerTab()
                        // Mail measures its own column and chooses its columns for it; on a Mac it
                        // is never narrower than the regular class's threshold (MAIL-UX 2.2).
                        case .mail:
                            #if BANANA_UNRELEASED
                            MailSection().frame(minWidth: LayoutClass.regularWidth)
                            #else
                            ContentUnavailableView("Email is coming soon", systemImage: "envelope")
                            #endif
                        #if BANANA_MODULE_WORKOUTS
                        case .workouts:  WideWorkoutsView().syncWaitingNote(.fitness).onAppear { SpaceSyncQuestions.shared.healthUsed() }
                        #endif
                        // Sleep and Trends had rows of their own; both are inside Review.
                        case .sleep, .trends, .review: macReview.syncWaitingNote(.fitness)
                        #if BANANA_MODULE_FOOD
                        case .nutrition: WideNutritionView().syncWaitingNote(.wellness).onAppear { SpaceSyncQuestions.shared.healthUsed() }
                        #endif
                        #if BANANA_MODULE_NOTES
                        case .notes:     NotesView()
                        #endif
                        case .assistant:
                            #if PI_DEVELOPMENT
                            macReview
                            #else
                            #if BANANA_AI
                            AssistantView()
                            #else
                            EmptyView()
                            #endif
                            #endif
                        case .routines:  RoutinesView()
                        // Told how much room it has, so a wide window gets the grid of shows.
                        #if BANANA_MODULE_PODCASTS
                        case .library:   PodcastsView().measuresLayoutClass().syncWaitingNote(.controls)
                        #endif
                        // Settings is its own window (the `Settings` scene); a place kept from
                        // before it moved opens Plan.
                        case .settings:  PlannerTab()
                        #if !(BANANA_MODULE_WORKOUTS && BANANA_MODULE_FOOD && BANANA_MODULE_NOTES && BANANA_MODULE_PODCASTS)
                        // A module's section in a build without it: `shown(with:)` never opens one.
                        default:         PlannerTab()
                        #endif
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onReceive(NotificationCenter.default.publisher(for: .assistantOpenSection)) { notice in
                        guard let raw = notice.object as? String, let section = AppSection(rawValue: raw) else { return }
                        if section == .settings { openSettings() } else { nav.section = section }
                    }
                    // The window's one toolbar: "Search or ask" in the middle and the assistant beside
                    // it, on every page; each page adds its title menu and "…".
                    .toolbar {
                        ToolbarItem(placement: .principal) { ShellToolbarField() }
                        #if BANANA_AI
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                nav.showsAssistant.toggle()
                            } label: { Label("Ask Banana", systemImage: "sparkle") }
                                .keyboardShortcut("j", modifiers: .command)
                                .help(nav.showsAssistant ? "Hide chat (⌘J)" : "Ask a question or add something (⌘J)")
                                .accessibilityValue(nav.showsAssistant ? "Open" : "Closed")
                                .accessibilityIdentifier("app.askBanana")
                        }
                        #endif
                    }
                    .environment(\.wideShell, true)
                    // What the field found, hanging under the toolbar's middle.
                    .overlay(alignment: .top) { ShellWideResults(section: nav.section) }
                    .onReceive(NotificationCenter.default.publisher(for: .shellOpenAssistant)) { _ in
                        nav.showsAssistant = true
                    }
                    .onChange(of: nav.section) { _, section in
                        if section == .workouts || section == .nutrition { lastBody = section }
                    }
                    // A module switched off (here or on another device) takes its section with it.
                    .onChange(of: modules.effectiveChoice, initial: true) { _, choice in
                        if !nav.section.isShown(with: choice) { nav.section = .plan }
                    }
                    // One toast for every section, centred on the content, not the drawer.
                    .toastHost()
                    // "Skipped an ad · Undo", whatever section is showing — as on the phone. It
                    // was only inside the full player, so a skip made while planning went unseen.
                    #if BANANA_MODULE_PODCASTS
                    .overlay(alignment: .bottom) {
                        SkipNoticeBar()
                            .frame(maxWidth: 440)
                            .padding(.bottom, DS.Space.l)
                    }
                    #endif
                    // Pull listening progress each time the Mac is switched to, as the phone does
                    // coming forward. Only a launch or playing here used to fetch it, so a Mac left
                    // running for days kept showing episodes finished on the phone as unplayed.
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        guard !Self.isolatedPreview else { return }
                        #if BANANA_MODULE_PODCASTS
                        CloudProgressSync.shared.flushNow(reason: "foreground")
                        #endif
                        Telemetry.shared.calendarConnected = { !GoogleCalendarService.shared.accounts.isEmpty }
                        Telemetry.shared.setup = { await TelemetryState.signals() }
                        Telemetry.shared.session = { BananaAccount.shared.authorization }
                        BananaAccount.shared.start()
                        Telemetry.shared.cameForward()
                        DiagnosticReports.shared.send()                 // crash and performance reports waiting
                        ProblemReporter.shared.flush()                  // problem reports waiting
                        // Now, then every minute — and it keeps going in the background: a Mac
                        // left open should keep up with the phone too.
                        CloudSyncPoll.resume()
                    }
                    .task { if !Self.isolatedPreview { CloudSyncPoll.resume() } }
                    // Mail's badge on the rail (unread in the Inbox) before Mail has started: the
                    // launch mirror, then one read-only count (`MailBadgeLaunchRead`).
                    .task {
                        #if BANANA_UNRELEASED
                        guard !Self.isolatedPreview, ModuleStore.shared.includes(.email) else { return }
                        if let mirrored = MailBadgeLaunchRead.mirrored() { ActionBadges.shared.setMailInbox(mirrored) }
                        try? await Task.sleep(for: .seconds(2))
                        guard MailApplication.shared.session == nil else { return }
                        if let unread = await MailBadgeLaunchRead.read(), MailApplication.shared.session == nil {
                            ActionBadges.shared.setMailInbox(unread)
                        }
                        #endif
                    }
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
                    #if BANANA_AI
                    if nav.showsAssistant {
                        Divider()
                        AssistantView(panelClose: { nav.showsAssistant = false }, panelAddSection: nav.section)
                            .frame(width: 420)
                            .accessibilityIdentifier("assistant.panel")
                            .transition(.move(edge: .trailing))
                    }
                    #endif
                    if !nav.showsAssistant, let meeting = nav.inspectedMeeting {
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
                .animation(.snappy(duration: 0.2), value: nav.showsAssistant)

                // Playback transport, always present while something is loaded — the iOS shell put
                // this in the tab bar's bottom accessory; the Mac had NO transport at all, so you
                // could start an episode and then lose all control of it. A persistent bottom bar is
                // the Music/Podcasts-app idiom.
                #if BANANA_MODULE_PODCASTS
                if player.currentEpisode != nil {
                    Divider()
                    NowPlayingBar(onExpand: { nav.showFullPlayer = true })
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
                #endif
            }
            #if BANANA_MODULE_PODCASTS
            .sheet(isPresented: $nav.showFullPlayer) { NowPlayingView() }
            #endif
        }
        #if PI_DEVELOPMENT
        .onChange(of: chrome.showAdd) { _, requested in
            guard requested else { return }
            chrome.showAdd = false
            nav.showsAssistant = true
        }
        .onChange(of: chrome.review) { _, section in
            guard section != nil else { return }
            chrome.review = nil
            nav.section = .review
        }
        #endif
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
    #if BANANA_MODULE_WORKOUTS
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore
    #endif
    @EnvironmentObject private var smart: SmartScheduleStore
    @EnvironmentObject private var settings: AppSettings
    #if BANANA_MODULE_WORKOUTS
    @ObservedObject private var review = WorkoutReviewCoordinator.shared
    #endif
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
            #if BANANA_MODULE_WORKOUTS
            // Dismissal clears `pending`.
            .sheet(item: $review.pending) { subject in
                PostWorkoutReviewView(subject: subject)
            }
            #endif
            .task { checkPayoffScreens() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    checkPayoffScreens()
                    adoptGoogleAccountsAddedElsewhere()
                }
            }
            #if BANANA_MODULE_WORKOUTS
            .onChange(of: fitness.summaries.count) { _, _ in checkWorkoutReview() }
            .onChange(of: health.workouts.count) { _, _ in checkWorkoutReview() }
            #endif
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
        #if BANANA_MODULE_WORKOUTS
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
        #endif
        if ProcessInfo.processInfo.arguments.contains("--morning-briefing") { nav.showMorningBriefing = true; return }
        // A store capture photographs the page under it: nothing opens over it by itself.
        if SmartScheduleStore.isStoreCapture { return }
        #if BANANA_MODULE_WORKOUTS
        guard !WorkoutReviewCoordinator.isSuppressedByLaunchArguments else { return }
        #endif
        #endif
        checkMorningBriefing()
        #if BANANA_MODULE_WORKOUTS
        checkWorkoutReview()
        #endif
    }

    private func checkMorningBriefing() {
        guard settings.macMorningBriefing else { return }   // ⌘⇧M still opens it — only the auto-present is gated
        #if BANANA_MODULE_WORKOUTS
        guard review.pending == nil else { return }   // a workout's review first
        #endif
        guard scenePhase == .active, !nav.showMorningBriefing else { return }
        let now = Date()
        let plannedWake = smart.planDay(for: now)?.wake
        guard MorningBriefingSchedule.shouldShow(now: now, plannedWake: plannedWake,
                                                lastShownDay: MorningBriefingSchedule.lastShownDay()) else { return }
        MorningBriefingSchedule.markShown(now)
        nav.showMorningBriefing = true
    }

    #if BANANA_MODULE_WORKOUTS
    /// The briefing owns the morning; a workout that arrives during it is not consumed and shows
    /// the next time the app is used.
    private func checkWorkoutReview() {
        #if DEBUG
        guard !WorkoutReviewCoordinator.isSuppressedByLaunchArguments else { return }
        #endif
        guard scenePhase == .active, !nav.showMorningBriefing else { return }
        review.check(summaries: fitness.summaries, healthWorkouts: health.workouts)
    }
    #endif
}

/// Menu-bar commands: navigate from the keyboard.
struct MacCommands: Commands {
    @ObservedObject private var nav = MacNavigator.shared
    @ObservedObject private var booking = BookingCenter.shared
    @ObservedObject private var modules = ModuleStore.shared

    var body: some Commands {
        #if BANANA_DIRECT
        CommandGroup(after: .appInfo) {
            DirectMacUpdateButton()
        }
        #endif
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
            ForEach(Array(AppSection.macShortcuts.filter { $0.isShown(with: modules.effectiveChoice) }.prefix(9).enumerated()), id: \.element) { index, section in
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
        // Report a problem (docs/design/PROBLEM-REPORTS.md): Help, and ⌘⇧R from anywhere.
        CommandGroup(after: .help) {
            Button("Report a Problem\u{2026}") { ProblemReportCenter.shared.open() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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
/// Holds the window's sidebar column at the rail's width: no wider, no narrower, no collapsing,
/// whatever AppKit's sidebar defaults or a saved divider position say (`ShellLayout.railColumn`).
private struct MacRailColumnPin: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> NSView { Probe(width: width) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Probe)?.width = width
        (view as? Probe)?.pin()
    }

    final class Probe: NSView {
        var width: CGFloat
        init(width: CGFloat) { self.width = width; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        func pin() {
            var ancestor = superview
            while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
            guard let split = ancestor as? NSSplitView,
                  let controller = split.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first else { return }
            if sidebar.minimumThickness != width { sidebar.minimumThickness = width }
            if sidebar.maximumThickness != width { sidebar.maximumThickness = width }
            if sidebar.canCollapse { sidebar.canCollapse = false }
            if sidebar.isCollapsed { sidebar.isCollapsed = false }
            if let column = split.arrangedSubviews.first, abs(column.frame.width - width) > 0.5 {
                split.setPosition(width, ofDividerAt: 0)
            }
        }
    }
}

#endif
