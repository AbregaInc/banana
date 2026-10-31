import SwiftUI
#if os(macOS)
import AppKit
import Darwin
#endif

#if DEBUG && os(iOS)
/// The one list of launch-argument routes that render the real screen without starting
/// production services (CloudKit, EventKit, notification scheduling, background work). Both
/// `BananaApp` (which view to route to) and `RootView` (whether the scenePhase-active handler
/// may run its production resync) key off this same set — keeping it in one place is what stops
/// a route added to the router from leaving the resync guard stale, the same class of drift as
/// the return-home travel gate this list was introduced alongside.
enum VisualAuditRoute {
    // `--rhythm` stays for one release: RootView routes it to Workouts, and an unlisted
    // route would start the production graph and crash the unsigned Simulator build.
    static let flags: Set<String> = [
        "--src-sleep", "--morning", "--ui-preview", "--listenmap", "--rhythm",
        "--routines", "--trim", "--transcript-demo", "--voicenote-demo", "--day",
        "--week", "--plan", "--smart", "--runmap", "--dummy-health", "--workout",
        "--library", "--library-detail", "--notes", "--new-calendar-event", "--verify-flight-boarding",
        "--workout-review", "--workout-detail", "--wellness", "--widgets", "--availability", "--place-picker", "--settings", "--event-detail", "--event-editor", "--now-playing", "--sleep",
        "--trends", "--trend", "--scan-correct-preview", "--my-foods", "--energy-balance",
        "--food-search", "--booking-preview", "--calendar-settings-preview", "--speech-lab", "--mail"
    ]
    static func matches(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains { flags.contains($0) }
    }
}
#endif

@main
struct BananaApp: App {
    #if os(iOS)
    /// Only for background-download completion — iOS delivers that to a UIApplicationDelegate and
    /// nowhere else. See AppDelegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    /// Pushes from the Banana service. See MacAppDelegate.
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    @StateObject private var store = AlarmStore()
    @StateObject private var health = HealthKitStore()
    // `.shared`, not a bare `SmartScheduleStore()`: the background calendar-refresh task (see
    // `SmartScheduleStore.shared`'s doc comment) falls back to the same singleton whenever
    // `OccurrenceStore.shared.smart` isn't wired yet (a headless background launch skips this
    // `.task`/wireUp entirely). Using `.shared` here too means there is only ever one settings +
    // travel-route-cache object in a live foreground session — a background pass that warms the
    // cache actually stays warm for the next foreground open, instead of the two silently
    // diverging into separate objects with separate caches.
    private let smart = SmartScheduleStore.shared
    private let fitness = FitnessStore.shared
    private let connectivity = PhoneConnectivity.shared
    @StateObject private var settings = AppSettings()
    @StateObject private var history = ListenHistoryStore()
    @StateObject private var onboarding = OnboardingStore()
    @StateObject private var wellness = WellnessStore.shared
    private let routines = RoutineStore.shared

    // Shared with the background AlarmKit stop intent — one graph, one PlayerController.
    private let library = WakeCoordinator.shared.library
    private let player = WakeCoordinator.shared.player
    private let wake = WakeCoordinator.shared.wake
    private let music = WakeCoordinator.shared.music
    private let downloads = WakeCoordinator.shared.downloads
    private let skipPlans = WakeCoordinator.shared.skipPlans

    init() {
        #if STRESS_DEVICE_AUDIT
        PhysicalStressReview.requireValidLaunch()
        #endif
        #if DEBUG && (targetEnvironment(simulator) || os(macOS) || STRESS_DEVICE_AUDIT)
        // Seed the persisted preference, not NSArgumentDomain: a -planMode launch argument
        // overrides subsequent picker writes and makes mode-switching tests misleading.
        if ScaleStress.days != nil,
           let initialMode = ProcessInfo.processInfo.environment["STRESS_INITIAL_PLAN_MODE"],
           PlanMode(rawValue: initialMode) != nil {
            UserDefaults.standard.set(initialMode, forKey: "planMode")
        }
        #endif
        #if DEBUG && os(macOS)
        // `--mail-key-script`: the offscreen key driver. A process nobody is meant to see, before any
        // window can exist (MailKeyDriver.swift).
        if MailKeyDriver.requested { MainActor.assumeIsolated { MailKeyDriver.prepareProcess() } }
        #endif
        #if os(iOS)
        // A page's switch in the top bar (`PageSwitch`) gives each word its own width, padded
        // alike. Split evenly, "Workouts" filled its third edge to edge while "Food" sat in
        // space. Only in the bar: a form's two-choice switch keeps its even halves.
        UISegmentedControl.appearance(whenContainedInInstancesOf: [UINavigationBar.self])
            .apportionsSegmentWidthsByContent = true
        #endif
        #if os(macOS)
        // One-time carry-over from the retired Mac identities (`<id>.mac`, and Beta's
        // `<id>.mac.beta` until 18 Oct 2026). The Mac bundle id now matches iOS (shared App Store
        // record, one App ID, one Google client); without this, every per-bundle-id preference
        // would silently reset on the identity change.
        let macDefaultsMigrationKey = "didMigrateMacBundleDefaults"
        if !UserDefaults.standard.bool(forKey: macDefaultsMigrationKey),
           let legacyDomain = AppVariant.legacyMacBundleID(Bundle.main.bundleIdentifier) {
            for (key, value) in UserDefaults.standard.persistentDomain(forName: legacyDomain) ?? [:]
            where UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value, forKey: key)
            }
            UserDefaults.standard.set(true, forKey: macDefaultsMigrationKey)
        }
        // After the carry-over above, so a value that arrived from the old identity moves too;
        // before any view reads the key.
        MenuBarAgendaSetting.migrateLegacyKey()
        #endif
        DiagnosticJournal.shared.startProcessSession(attributes: [
            "app": "Banana",
            "version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        ])
        // All @StateObject property initializers above have already run by this line — the
        // store-level marks (alarms.init, settings.init, …) land before this one, so the gaps
        // between consecutive marks attribute the cost of each construction.
        LaunchClock.mark("app.init.body")
        // Activate WatchConnectivity + wire the receive path at LAUNCH (not in the UI
        // task), so a watch→phone workout transfer is delivered even when the app is
        // background-launched to receive it.
        #if !STRESS_DEVICE_AUDIT
        MainActor.assumeIsolated {
            // A cloud-model call that never came back took the app down: not again on this OS
            // build (`CloudModelGuard`). Before anything can ask a model anything.
            if CloudModelGuard.checkAtLaunch() {
                PlaybackDiagnostics.shared.log("🧠 cloud model", "took the app down last time; on-device only on iOS \(CloudModelGuard.osBuild)")
            }
            // Every store's edits go to the sync from the first one.
            ControlChangeReporter.connectToCloud()
            // The meal backlog's own zone. Its stores need no window, so it starts here, at launch
            // — a push or a background task can then fetch it on its own (`MealBacklogWake`).
            MealBacklogWake.startSync()
            PhoneConnectivity.shared.fitnessStore = FitnessStore.shared
            PhoneConnectivity.shared.activate()
            // BG task registration must happen before launch finishes.
            TranscriptCoordinator.shared.registerBackgroundTasks()
            OvernightRefresh.register()
            CalendarWriteBackRefresh.register()
            // Taken's reminders: "Taken" on the notification, and where a tap goes.
            DoseReminders.register()
            // Event alerts (docs/design/EVENT-ALERTS.md): their dismissal is heard, invitations offer Accept / Decline.
            EventAlerts.register()
            #if os(iOS)
            // Meal photos (docs/design/MEAL-BACKLOG.md, "Scanner"): the library scan — its BG
            // refresh task, and passes on coming to the front, which it follows itself — and the
            // notification delegate + category the iPhone's "What did you eat?" questions are
            // answered through.
            MealPhotoScanner.register()
            MealPhotoNotifications.register()
            // Meals still waiting when the app closes: estimated on the next charge.
            MealEstimateCatchUp.register()
            // A reply to "What did you eat?" can wake the app in the background, before launch has
            // started the estimating: start it here if so.
            MealPhotoNotifications.onAnswered = {
                Task { @MainActor in
                    await WellnessStore.shared.whenLoaded()
                    MealBacklogProcessor.shared.startIfNeeded(wellness: .shared)
                }
            }
            #else
            // The Mac looks for meal photos too — on power, it does most of the looking.
            MealPhotoScanner.register()
            #endif
        }
        #endif
        PlaybackDiagnostics.shared.noteLaunch()   // says so out loud if the last run was killed mid-episode
        // The "needs you" counts behind the tab, sidebar and app-icon badges.
        MainActor.assumeIsolated { ActionBadges.shared.start() }
        // A copy from before modules existed keeps showing everything, and says so for the others.
        MainActor.assumeIsolated {
            ModuleStore.shared.settleForExistingInstall(
                onboardingCompleted: UserDefaults.standard.bool(forKey: "onboardingCompleted"))
        }
        MainActor.assumeIsolated { PerfWatchdog.start() }   // names the view that's burning the CPU
        #if os(iOS)
        Metrics.start()   // MetricKit: daily CPU/battery + cpu_resource_fatal diagnostics → the journal
        #endif
        MainActor.assumeIsolated { DiagnosticReports.start() }   // and the same reports, anonymously, to the service
        #if DEBUG && os(iOS)
        // `--frame-probe`: a real CADisplayLink-driven fps/hitch reading for the "is this view
        // actually dropping frames" class of investigation (see `FrameProbe`'s doc comment) —
        // runs for the whole session once armed, so whatever's on screen shows up in the journal.
        if FrameProbe.isRequested {
            MainActor.assumeIsolated { FrameProbe.start(label: "session") }
        }
        #endif
        #if DEBUG
        // `--storm-selftest`: fake a runaway publisher so the storm detector can be proven to catch
        // it and name it — an instrument that has never fired is not evidence of anything.
        if ProcessInfo.processInfo.arguments.contains("--storm-selftest") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                for _ in 0..<800 {
                    OccurrenceStore.shared.objectWillChange.send()
                    try? await Task.sleep(for: .milliseconds(8))   // ~125/s, like the bike ride
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--library-publish-regression") {
            // Reproduce the exact source named by a production journal without touching a
            // real feed or account. The Plan subtree must remain stable while unrelated catalogue
            // state changes rapidly above it.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<120 {
                    WakeCoordinator.shared.library.objectWillChange.send()
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--reset-day-scroll-offset") {
            UserDefaults.standard.set(0.0, forKey: "mobileDayScrollOffset")
        }
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--day-cache-backfill-regression") {
            MainActor.assumeIsolated {
                OccurrenceStore.shared.injectDayCacheBackfillRegression()
            }
        }
        #endif
        #endif
        #if DEBUG && os(macOS)
        // A visible WindowServer capture can happen before a root-view `.task` runs. Seed explicit
        // audit launches here so screenshots never leak personal state or catch an empty library.
        if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
            MainActor.assumeIsolated {
                injectMacVisualAuditSamples()
                OccurrenceStore.shared.injectSampleForPreview(
                    meetings: smart.todayMeetings,
                    lateCueHour: 20)
            }
        }
        #endif

        #if DEBUG && os(iOS)
        TimelineVerification.runIfRequested()   // --verify-timeline: L1–L4 assumption checks
        TranscribeVerification.runIfRequested()   // --verify-transcribe: where does on-device ASR stall?
        CPUVerification.runIfRequested()          // --verify-cpu: what does a second of playback cost?
        PlaybackVerification.runIfRequested()     // --verify-stall: does playback survive a dead stream?
        FitnessBatchVerification.runIfRequested() // --verify-fitness-batch: publishes-per-batch, not per-record
        #endif
        #if DEBUG
        // Background downloads are iPhone-specific, but the peer fixture provider intentionally
        // runs on Mac so a phone/simulator can prove the LAN path without a second physical phone.
        DownloadVerification.runIfRequested()
        // Cross-platform for the same reason: the Mac is the easiest Apple-Intelligence host to
        // measure on, and the numbers this reports are platform-independent.
        #endif
        #if os(macOS)
        // Before any window exists, so it can be run on a machine nobody is sitting at.
        GoogleRoundTripProbe.runIfRequested()
        #endif
        #if os(macOS)
        if !CalendarWriteBack.isDiagnosticLaunch {
            // After launch has finished, not during it: SwiftUI's MenuBarExtra hung the whole app
            // inside AppKit's status-item sizing at launch (2026-09-25), so the item is plain
            // AppKit, created once the run loop is going.
            DispatchQueue.main.async {
                JoinMeetingHotKey.shared.register()
                MenuBarAgendaItem.shared.start(smart: SmartScheduleStore.shared)
            }
        }
        #endif
        LaunchClock.mark("app.init.done")
    }

    var body: some Scene {
        mainScene
        #if os(macOS)
        // Settings is its own window on the Mac, the system's: ⌘, and the app menu open it, its
        // sections are the toolbar's (DESIGN-SYSTEM.md, the standard, 5).
        Settings {
            // Its own toast host: deleting a booking type offers Undo.
            configured(SettingsView().toastHost())
        }
        #endif
    }

    private var mainScene: some Scene {
        #if DEBUG && os(macOS)
        let _ = scheduleHeadlessAppStoreSnapshotIfNeeded()
        // The key driver hosts the real shell in a window of its own that is never shown; this
        // scene's own window is not made (`defaultLaunchBehavior` below). It is not `configuredRoot`:
        // nothing here starts the production graph.
        let _ = MailKeyDriver.startIfNeeded(root: AnyView(configuredPlatformRoot))
        #endif
        #if os(macOS)
        let _ = wireUpEvenWithoutAWindow()
        #endif
        let group = WindowGroup {
            #if PERFORMANCE_TESTING && os(iOS)
            if PerformanceScenarioRunner.isRequested {
                configured(PerformanceScenarioView())
                    .task {
                        // The silent control deliberately avoids the production service startup:
                        // restored smart alarms or notifications must never fire during an
                        // overnight no-audio baseline. Playback still wires the real graph.
                        if PerformanceScenarioRunner.requestedScenarioID == "playback.local" {
                            await wireUp()
                        }
                        await PerformanceScenarioRunner.runRequested(
                            library: library,
                            player: player,
                            downloads: downloads,
                            smart: smart,
                            routines: routines,
                            health: health,
                            occurrences: OccurrenceStore.shared)
                    }
            } else {
                configuredRoot
            }
            #elseif DEBUG && os(iOS)
            if ProcessInfo.processInfo.arguments.contains("--verify-timeline") {
                VerificationView()   // isolated harness UI; RootView/wireUp stays out of the way
            } else if ProcessInfo.processInfo.arguments.contains("--occurrences") {
                OccurrenceDebugView()   // L1 occurrence-engine inspector
            } else if ProcessInfo.processInfo.arguments.contains("--day-real-calendar") {
                // Physical-device validation: real EventKit data, but no service startup,
                // fixture injection, CloudKit restore UI, notifications, or write-back.
                configured(WeekView(dayMode: true))
            } else if isVisualAuditLaunch {
                configuredPlatformRoot
                    .task {
                        injectVisualAuditSamples()
                        #if targetEnvironment(simulator) || STRESS_DEVICE_AUDIT
                        await ScaleStress.shared.prepare(library: library, clock: player.clock, smart: smart)
                        #endif
                    }
                    #if targetEnvironment(simulator) || STRESS_DEVICE_AUDIT
                    .overlay(alignment: .bottomTrailing) { ScaleStressBadge() }
                    #endif
            } else {
                configuredRoot
            }
            #elseif DEBUG && os(macOS)
            if MailKeyDriver.requested {
                Color.clear
            } else if let outputURL = routineEditorSnapshotURL {
                configured(MacRoutineEditorSnapshotHarness(outputURL: outputURL))
            } else if let outputURL = appStoreSnapshotURL {
                // A named view is captured by the offscreen path alone; the on-screen harness
                // would otherwise win the race whenever the display is awake and capture the root.
                if ProcessInfo.processInfo.arguments.contains("--snapshot-view") {
                    Color.clear
                } else {
                    configured(MacAppStoreSnapshotHarness(outputURL: outputURL))
                }
            } else if let outputURL = debugOutputURL(after: "--snapshot-workout-review") {
                configured(MacWorkoutReviewSnapshotHarness(outputURL: outputURL))
            } else if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
                configuredPlatformRoot
                    // `@StateObject` access from `App.init` is only an early best-effort seed:
                    // SwiftUI has not installed those objects in the scene yet and can vend a
                    // transient instance. Seed again from the installed view hierarchy so the
                    // capture and its environment objects are guaranteed to be the same graph.
                    .task {
                        injectInstalledMacVisualAuditSamples()
                        await ScaleStress.shared.prepare(library: library, clock: player.clock, smart: smart)
                    }
                    .overlay(alignment: .bottomTrailing) { ScaleStressBadge() }
            } else {
                configuredRoot
            }
            #else
            configuredRoot
            #endif
        }
        #if os(macOS)
        #if DEBUG
        return group
            .defaultSize(width: 1120, height: 780)
            .windowResizability(.contentMinSize)
            .commands { MacCommands() }
            .defaultLaunchBehavior(MailKeyDriver.requested ? .suppressed : .automatic)
        #else
        return group
            .defaultSize(width: 1120, height: 780)
            .windowResizability(.contentMinSize)
            .commands { MacCommands() }
        #endif
        #else
        return group
        #endif
    }

    #if DEBUG && os(macOS)
    private static var appStoreSnapshotScheduled = false

    private var routineEditorSnapshotURL: URL? {
        debugOutputURL(after: "--snapshot-routine-editor")
    }

    private var appStoreSnapshotURL: URL? {
        debugOutputURL(after: "--snapshot-app-store")
    }

    /// Produce Mac App Store artwork even when the login session is locked.
    ///
    /// A normal `WindowGroup` does not open a visible scene behind the lock screen, so a
    /// view-level `.task` never runs. This constructs the same configured root hierarchy in
    /// an offscreen AppKit window and captures its backing store directly.
    @MainActor
    private func scheduleHeadlessAppStoreSnapshotIfNeeded() {
        guard let outputURL = appStoreSnapshotURL,
              !Self.appStoreSnapshotScheduled else { return }
        Self.appStoreSnapshotScheduled = true
        // `--appearance light|dark`: judge both appearances without changing the system's.
        if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--appearance"),
           ProcessInfo.processInfo.arguments.indices.contains(flag + 1) {
            NSApp.appearance = NSAppearance(named: ProcessInfo.processInfo.arguments[flag + 1] == "light" ? .aqua : .darkAqua)
        }
        injectMacVisualAuditSamples()
        OccurrenceStore.shared.injectSampleForPreview(meetings: smart.todayMeetings)

        Task { @MainActor in
            let arguments = ProcessInfo.processInfo.arguments
            let compactWindow = arguments.contains("--compact-window")
            let captureWidth: CGFloat = compactWindow ? 942 : 1120
            var captureHeight: CGFloat = compactWindow ? 655 : 780
            // DEBUG harness override, verification-only: a long scrollable surface (e.g. the
            // Settings form) only shows its first `captureHeight` points in one capture — there is
            // no scroll interaction in this headless flow. Rather than script a scroll gesture into
            // a running window, let a capture ask for a taller offscreen window instead so the
            // whole surface renders in one shot. Clamped like `--snapshot-delay` so a typo can't
            // hang or corrupt the capture.
            if let flag = arguments.firstIndex(of: "--capture-height"),
               arguments.indices.contains(flag + 1), let override = Double(arguments[flag + 1]) {
                captureHeight = CGFloat(min(max(override, 200), 6000))
            }
            let content: AnyView
            if let flag = arguments.firstIndex(of: "--snapshot-view"), arguments.indices.contains(flag + 1),
               let view = MacDebugSnapshotViews.view(named: arguments[flag + 1], smart: smart) {
                content = AnyView(
                    ZStack {
                        Color(.windowBackgroundColor)
                        configured(view)
                    }
                    .frame(width: captureWidth, height: captureHeight)
                )
            } else if arguments.contains("--mac-new-event") {
                content = AnyView(
                    ZStack {
                        Color(.windowBackgroundColor)
                        configured(NewCalendarEventSheet())
                    }
                    .frame(width: captureWidth, height: captureHeight)
                )
            } else {
                content = AnyView(configuredPlatformRoot.frame(width: captureWidth, height: captureHeight))
            }
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: captureWidth, height: captureHeight),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Banana"
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // The publisher-storm audit needs to keep the real view tree alive through both
            // five-second watchdog samples. Ordinary artwork captures should remain fast.
            let captureDelay: Int
            if arguments.contains("--storm-selftest") {
                captureDelay = 11_000
            } else if let flag = arguments.firstIndex(of: "--snapshot-delay"),
                      arguments.indices.contains(flag + 1), let override = Int(arguments[flag + 1]) {
                // DEBUG harness override: the 1000 ms default is tuned for fast, static artwork
                // captures, but a view whose content depends on real on-device analysis of a large
                // dataset (e.g. `HandPathView` on a 70-lap swim's motion analysis) can take
                // noticeably longer than that to settle, and a capture taken before it settles is
                // just a loading spinner. Clamped so a typo can't hang the harness indefinitely or
                // capture before the window has even laid out.
                captureDelay = min(max(override, 0), 60_000)
            } else {
                captureDelay = 1_000
            }
            try? await Task.sleep(for: .milliseconds(captureDelay))
            window.displayIfNeeded()

            guard let contentView = window.contentView,
                  let view = contentView.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fputs("App Store snapshot failed: no offscreen backing store\n", stderr)
                exit(EXIT_FAILURE)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fputs("App Store snapshot failed: PNG encoding\n", stderr)
                exit(EXIT_FAILURE)
            }
            do {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try png.write(to: outputURL, options: .atomic)
                fputs("App Store snapshot: \(outputURL.path)\n", stderr)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("App Store snapshot failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
    }

    private func debugOutputURL(after flagName: String) -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: flagName),
              arguments.indices.contains(flag + 1) else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1])
    }

    /// Render the shipping Mac views without starting services that can present permission alerts.
    /// Seed only the stores needed to make the selected App Store surfaces legible.
    @MainActor
    private func injectMacVisualAuditSamples() {
        routines.injectSampleForPreview()
        fitness.injectSampleForPreview()
        // And again once the store has read its index: that read replaces what's there, and on a
        // Mac it finishes after this, which left the Workouts page with nothing on it.
        Task { [fitness] in
            await fitness.whenLoaded()
            fitness.injectSampleForPreview()
        }
        history.injectSampleForPreview()
        library.injectSampleForPreview()
        WeatherStore.shared.injectSampleForPreview()
        smart.injectSampleAgenda(anchoredToBusinessHours: true)
        if ProcessInfo.processInfo.arguments.contains("--event-states-sample") {
            smart.injectEventStateSamples()
        }
        if ProcessInfo.processInfo.arguments.contains("--trip-sample") {
            smart.injectTripSample()
        }
        VoiceNoteStore.shared.injectSampleForPreview()
        wellness.injectPreviewData()
        // `--energy-balance`: four weeks of meals for the logs-against-weight card instead of the
        // week (they'd double up); HealthKitStore seeds the weight and energy it reads.
        if let preview = EnergyBalance.Preview.requested() {
            wellness.injectPreviewMeals(preview.sample().meals)
        } else {
            wellness.injectWeekPreview()
        }
    }

    /// Run after SwiftUI installs this App's StateObjects. This is the authoritative Mac visual
    /// fixture; the early App.init seed merely reduces first-frame placeholder flashes.
    @MainActor
    private func injectInstalledMacVisualAuditSamples() {
        injectMacVisualAuditSamples()
        OccurrenceStore.shared.injectSampleForPreview(
            meetings: smart.todayMeetings + smart.tomorrowMeetings + smart.storeCaptureOtherDays(),
            lateCueHour: 20,
            anchoredToBusinessHours: true)
    }
    #endif

    #if DEBUG && os(iOS)
    /// Deterministic UI routes must not start CloudKit, EventKit, notification scheduling, or
    /// other production services. Besides making screenshots flaky, those services can put a
    /// system permission alert over the very screen the route exists to verify.
    private var isVisualAuditLaunch: Bool { VisualAuditRoute.matches() }

    @MainActor
    private func injectVisualAuditSamples() {
        let arguments = ProcessInfo.processInfo.arguments
        // Seed CONNECTION STATE, not just content.
        //
        // A simulator has granted nothing, so every permission-gated card renders its "not
        // connected" variant no matter how much sample data is loaded around it. That is how the
        // App Store's first screenshot came to lead with three red CTAs — "Calendar isn't
        // connected", "Reminders isn't connected", "Alarms aren't connected" — pushing the actual
        // plan below the fold and telling every visitor the app does not work.
        //
        // These flags are what the cards read, so the fixtures have to set them too.
        smart.calendarAuthorized = true
        OccurrenceStore.shared.markRemindersAuthorizedForAudit()
        store.markAuthorizedForAudit()
        // Before the day's sample below, which draws its routine moments from these.
        if arguments.contains("--wake-following-sample") { routines.injectSampleForPreview() }
        if arguments.contains("--custom-routine-completion-preview") {
            var therapy = CueType.custom.makeRoutine()
            therapy.id = UUID(uuidString: "6A2DB1AA-6A1B-47CF-AEE1-2159EFDA51BA")!
            therapy.name = "Physical therapy"
            therapy.triggerKind = .time
            therapy.hour = 0; therapy.minute = 0
            routines.upsert(therapy)
            if arguments.contains("--reset-routine-completion") {
                ExceptionStore.shared.clearOverride("\(therapy.id.uuidString)|main|\(Occurrence.dayKey(Date()))")
            }
        }
        // `--routine-start-sample`: a Manual routine with a show to play, for the Start button.
        if arguments.contains("--routine-start-sample") {
            Task { @MainActor [library, routines] in
                await library.whenLoaded()
                if library.podcasts.isEmpty { library.injectSampleForPreview() }
                if let first = library.podcasts.first { routines.injectStartableSample(podcastID: first.id) }
            }
        }
        if arguments.contains("--dummy-health") || arguments.contains("--workout") || arguments.contains("--trim") {
            fitness.injectSampleForPreview()
            // And again once the store has read its index, as on the Mac: that read replaces
            // what's there, which left the list with symbols and no route thumbnails.
            Task { [fitness] in
                await fitness.whenLoaded()
                fitness.injectSampleForPreview()
            }
        }
        if arguments.contains("--listenmap") {
            history.injectSampleForPreview()
        }
        // `--plan`: the whole Plan tab, its List · Day · Week switch included, on the week's sample.
        let week = arguments.contains("--week") || arguments.contains("--plan")
        if week || arguments.contains("--day") {
            // The paging audit needs the same three meetings during overnight test runs.
            smart.injectSampleAgenda(anchoredToBusinessHours: arguments.contains("--calendar-business-hours-sample"))
            // `--trip-sample`: a flight out this week and home next, for the second time zone.
            if ProcessInfo.processInfo.arguments.contains("--trip-sample") { smart.injectTripSample() }
            if arguments.contains("--event-states-sample") { smart.injectEventStateSamples() }
        }
        if week || arguments.contains("--day") {
            var meetings = week
                ? smart.todayMeetings + smart.tomorrowMeetings
                : smart.todayMeetings
            if arguments.contains("--back-to-back-sample") {
                // A 15-minute blocker straight before a long event (DayBlockHeightUITest).
                let cal = Calendar.current
                let at = { (h: Int, m: Int) in cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
                meetings += [
                    MeetingInfo(start: at(15, 30), end: at(15, 45), coordinate: nil, address: nil,
                                isVirtual: false, title: "Blocker"),
                    MeetingInfo(start: at(15, 45), end: at(17, 15), coordinate: nil, address: nil,
                                isVirtual: false, title: "Swim"),
                ]
            }
            if arguments.contains("--shared-busy-preview") {
                let calendar = Calendar.current
                let start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
                let end = start.addingTimeInterval(3600)
                let format = ISO8601DateFormatter()
                let payload: [String: Any] = ["id": "shared-private-busy", "summary": "Busy",
                    "start": ["dateTime": format.string(from: start)], "end": ["dateTime": format.string(from: end)],
                    "location": "Private work address", "hangoutLink": "https://meet.google.com/private",
                    "extendedProperties": ["private": ["bananaVariant": "banana", "bananaItemID": "other-person-work"]]]
                if let bytes = try? JSONSerialization.data(withJSONObject: payload),
                   let event = try? JSONDecoder().decode(GoogleEvent.self, from: bytes) {
                    meetings += GoogleEventWindowBuilder.window(from: [GoogleFetchedEvent(calendarID: "person-one.shared", event: event)],
                        ownedCalendarIDs: ["person-two.personal"]).meetings
                    meetings.append(MeetingInfo(start: start, end: end, coordinate: nil, address: nil, isVirtual: false,
                        title: "My dentist", eventID: "preview-dentist", calendarID: "person-two.personal"))
                }
            }
            if arguments.contains("--shared-mirror-preview") {
                let start = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
                let end = start.addingTimeInterval(3600)
                let format = ISO8601DateFormatter()
                let mirror = GoogleBusyBlocks.mirrorID(title: "Dinner", start: start, end: end)
                let fetched = ["viewer", "personal", "fitness", "work"].compactMap { calendarID -> GoogleFetchedEvent? in
                    let detailed = calendarID == "viewer" || calendarID == "personal"
                    var payload: [String: Any] = ["id": "preview-" + calendarID, "summary": detailed ? "Dinner" : "Busy",
                        "start": ["dateTime": format.string(from: start)], "end": ["dateTime": format.string(from: end)]]
                    if detailed { payload["iCalUID"] = "shared-dinner-instance" }
                    else { payload["extendedProperties"] = ["private": ["bananaVariant": "banana", "bananaItemID": mirror]] }
                    guard let bytes = try? JSONSerialization.data(withJSONObject: payload),
                          let event = try? JSONDecoder().decode(GoogleEvent.self, from: bytes) else { return nil }
                    return GoogleFetchedEvent(calendarID: calendarID, event: event)
                }
                meetings = GoogleEventWindowBuilder.window(from: fetched, ownedCalendarIDs: ["viewer"],
                    calendarOwners: ["viewer": "viewer@example.com", "personal": "owner@example.com",
                                     "fitness": "owner@example.com", "work": "owner@example.com"]).meetings
            }
            if arguments.contains("--lane-expansion-preview") {
                let calendar = Calendar.current
                let day = calendar.startOfDay(for: Date())
                func event(_ title: String, _ hour: Double, _ duration: Double) -> MeetingInfo {
                    let start = day.addingTimeInterval(hour * 3600)
                    return MeetingInfo(start: start, end: start.addingTimeInterval(duration * 3600),
                        coordinate: nil, address: nil, isVirtual: false, title: title,
                        eventID: "lane-preview-\(title)", calendarID: "lane-preview")
                }
                meetings = [event("Long event", 0, 24), event("First overlap", 9, 1),
                            event("Second overlap", 9, 1), event("Expanded event", 11, 1)]
            }
            if week { meetings += smart.storeCaptureOtherDays() }   // empty but for a marketing capture
            var previewNow = Date()
            if arguments.contains("--reminder-grid-preview") {
                // Fixed midday geometry: late-night runs must not collide with Wind down or
                // move the reminder to tomorrow. The later task overlaps this one meeting.
                routines.injectSampleForPreview()
                let calendar = Calendar.current
                previewNow = calendar.date(bySettingHour: 10, minute: 10, second: 0, of: previewNow) ?? previewNow
                let overlap = calendar.date(bySettingHour: 13, minute: 45, second: 0, of: previewNow) ?? previewNow
                meetings = [MeetingInfo(start: overlap, end: overlap.addingTimeInterval(45 * 60),
                    isVirtual: false, title: "Reminder overlap fixture", eventID: "reminder-grid-overlap")]
            }
            OccurrenceStore.shared.injectSampleForPreview(
                meetings: meetings,
                denseDayEventCount: arguments.contains("--dense-day-regression") ? 60 : 0,
                now: previewNow)
            // Geometry/mirror fixtures exclude the live-clock demo visit and reminder filler.
            if arguments.contains("--lane-expansion-preview") || arguments.contains("--shared-mirror-preview") {
                OccurrenceStore.shared.injectStress(meetings)
            }
        }
        if week || arguments.contains("--day") {
            WeatherStore.shared.injectSampleForPreview()
        }
        if arguments.contains("--library") || arguments.contains("--library-detail") {
            library.injectSampleForPreview()
            // A couple of shows with downloads, so the row's download count is on screen too.
            downloads.markDownloadedForPreview(library.podcasts.prefix(2).flatMap { $0.episodes.prefix(3).map(\.id) })
        }
        if arguments.contains("--notes") {
            VoiceNoteStore.shared.injectSampleForPreview()
        }
        // `--ui-preview --tab nutrition --wellness`: the Nutrition tab inside the real tabs — the
        // wide page on an iPad — on the sample the standalone `--wellness` route loads for itself.
        // The same sample has the guided plan the Workouts tab's `--workouts-route plan` opens.
        if arguments.contains("--wellness"), arguments.contains("--ui-preview") {
            wellness.injectPreviewData()
            wellness.injectWeekPreview()
        }
    }
    #endif

    @ViewBuilder private var platformRoot: some View {
        #if os(iOS)
        RootView()
        #else
        MacGatedRootView()
        #endif
    }

    private var configuredRoot: some View {
        configuredPlatformRoot
            .task { await wireUp() }
            .spaceSyncQuestions()
    }

    /// The real production view tree and environment, without service startup side effects.
    /// Debug screenshot routes use this so visual verification cannot be blocked by CloudKit,
    /// EventKit, or background-service initialization.
    private var configuredPlatformRoot: some View {
        configured(platformRoot)
    }

    private func configured<Content: View>(_ content: Content) -> some View {
        content
            .environmentObject(store)
            .environmentObject(library)
            .environmentObject(player)
            .environmentObject(player.clock)
            .environmentObject(wake)
            .environmentObject(music)
            .environmentObject(fitness)
            .environmentObject(health)
            .environmentObject(downloads)
            .environmentObject(skipPlans)
            .environmentObject(smart)
            .environmentObject(settings)
            .environmentObject(history)
            .environmentObject(routines)
            .environmentObject(connectivity)
            .environmentObject(OccurrenceStore.shared)
            .environmentObject(WeatherStore.shared)
            .environmentObject(onboarding)
            .environmentObject(wellness)
            // WeekView uses explicit publishers for its four visible Smart Schedule inputs. Pass
            // the installed instance without subscribing the whole calendar to every status bit.
            .environment(\.weekSmartStore, WeekSmartStoreReference(smart))
            .environment(\.alarmStore, AlarmStoreReference(store))
            .modifier(SyncedCalendarWeekStart(store: smart))
            .onOpenURL { url in
                let beta = AppVariant.current == .beta
                guard url.scheme == NoteReminderLink.scheme(beta: beta) else {
                    GoogleCalendarService.handleOpenURL(url)
                    return
                }
                guard AppSection.notes.isShown(with: ModuleStore.shared.choice) else {
                    ToastCenter.shared.notify("Enable Notes in Settings > Modules to open this note.")
                    return
                }
                guard let id = NoteReminderLink.noteID(url, beta: beta), VoiceNoteStore.shared.note(id) != nil else {
                    ToastCenter.shared.notify("This note is not available on this device.")
                    return
                }
                ShellNavigation.shared.state.tab = .notes
                ShellNavigation.shared.state.notes = [id]
            }
            .bananaToggleStyle()
    }

    private static var wiring: Task<Void, Never>?

    /// Connect the object graph once per launch, whoever asks first: a window's view, or the app
    /// itself on a Mac started with no window (`wireUpEvenWithoutAWindow`). A second asker waits
    /// for the first.
    private func wireUp() async {
        if let wiring = Self.wiring { return await wiring.value }
        let task = Task { @MainActor in await connectObjectGraph() }
        Self.wiring = task
        await task.value
    }

    #if os(macOS)
    private static var windowlessWiringArmed = false

    /// Whether this launch shows the production root (and so runs `wireUp` from its window): the
    /// snapshot and preview routes below don't, and must not start services.
    private var showsProductionRoot: Bool {
        #if DEBUG
        if routineEditorSnapshotURL != nil || appStoreSnapshotURL != nil
            || debugOutputURL(after: "--snapshot-workout-review") != nil
            || ProcessInfo.processInfo.arguments.contains("--ui-audit") { return false }
        #endif
        return true
    }

    /// A Mac app started with no window (reopened in the background after an update, at login,
    /// behind the lock screen) builds its scenes and opens none, so no view's `.task` ever runs
    /// `wireUp`. On 8 Oct 2026 an updated Banana ran that way for hours: its calendar reads went on
    /// (they start with their store), none of its iCloud syncs had started, and a workout trimmed
    /// on the iPad never reached it. The app's duties aren't a window's: a few seconds in, they
    /// start here if no window has started them.
    private func wireUpEvenWithoutAWindow() {
        guard !Self.windowlessWiringArmed, showsProductionRoot else { return }
        Self.windowlessWiringArmed = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if Self.wiring == nil { PlaybackDiagnostics.shared.log("launch", "no window: starting the app's duties without one") }
            await wireUp()
        }
    }
    #endif

    private func connectObjectGraph() async {
        LaunchClock.mark("wireUp.start")
        defer { LaunchClock.mark("wireUp.done") }
        // Close the blind spot that let AlarmStore's same-value `isAlerting` republishes go
        // uncounted (09-01 WeekView storm): these four are @StateObjects, not singletons, so
        // PerfWatchdog.start() (a static context from App.init) couldn't reach them earlier.
        PerfWatchdog.registerLateSinks(alarms: store, smart: smart, onboarding: onboarding, settings: settings)
        CalendarSignals.shared.start(health: health, fitness: fitness, player: player)
        Task.detached(priority: .utility) { FlightParser.warmUp() }   // the airport table, before it's needed
        // player↔library↔downloads are already wired inside WakeCoordinator.
        player.history = history
        #if os(iOS)
        WidgetAgendaPublisher.shared.start(smart: smart)   // Lock Screen + Home Screen widgets
        VoiceNoteStore.shared.player = player   // capture context + pause/resume around a voice note
        VoiceNoteStore.shared.connectivity = connectivity   // cross-device pause/resume sync
        #endif
        player.settings = settings
        history.settings = settings
        WeatherStore.shared.smart = smart   // so the travel-weather fetch honors excluded calendars
        downloads.connectivity = connectivity
        downloads.settings = settings
        connectivity.downloads = downloads     // send paths (fitnessStore + activate done in init)
        connectivity.wake = wake
        connectivity.library = library
        downloads.observeCompletions()
        connectivity.player = player
        player.onStateChange = { [weak connectivity] in connectivity?.sendNowPlaying() }
        // Current can move with no local playback — a CloudKit merge from the Mac does exactly
        // that — and the Watch only reaches the rest of the world through this device.
        library.onCurrentEpisodeChanged = { [weak connectivity] in connectivity?.syncCurrentEpisode() }
        connectivity.sendNowPlaying()
        player.onProgressCommit = { [weak connectivity] id, pos, dur, done in
            connectivity?.sendListenProgress(episodeID: id, position: pos, duration: dur, completed: done)
        }
        player.onTakeOver = { [weak connectivity] in connectivity?.stopWatchPlayback() }
        connectivity.settings = settings
        connectivity.syncSettings()                                   // push units to the Watch now
        connectivity.skipPlans = skipPlans
        player.setAutomaticSkipEnabled(settings.automaticAdSkip)
        // `onChange` also fires for a settings blob adopted from another device, so the ad-skip
        // switch has to be re-read here rather than only where the toggle is drawn.
        let adSkipSettings = settings
        settings.onChange = { [weak connectivity, weak player, weak adSkipSettings] in
            connectivity?.syncSettings()
            if let adSkipSettings { player?.setAutomaticSkipEnabled(adSkipSettings.automaticAdSkip) }
        }
        #if os(iOS)
        // wellness.load() now happens off-main (WellnessStore.init); wait for it so this doesn't
        // push an empty plan to the Watch and prune the real one before the decode lands.
        await wellness.whenLoaded()
        connectivity.syncWorkoutPlan()
        wellness.onWorkoutPlansChanged = { [weak connectivity] in connectivity?.syncWorkoutPlan() }
        #endif
        // Automatic downloads wait for Wi-Fi; start them the moment it's back.
        NetworkMonitor.shared.onWiFiAvailable = { [weak downloads] in downloads?.startWaitingForWiFi() }

        // Fast settings sync, three tiers: LAN peer channel (instant, co-located, no iCloud
        // needed), CloudKit push (seconds, anywhere, entitled builds), KVS (legacy fallback).
        let smartStore = smart
        smart.onSettingsBroadcast = { [weak downloads] data in
            downloads?.broadcastPeerSettings(data)
            CloudSettingsSync.shared.push(data)
        }
        downloads.onPeerSettings = { [weak smartStore] in smartStore?.adoptSettingsSnapshot($0) }
        CloudSettingsSync.shared.onSnapshot = { [weak smartStore] in smartStore?.adoptSettingsSnapshot($0) }
        CloudSettingsSync.shared.startIfPossible()
        smart.primePeerSettings()
        // Busy blocks on/off and their calendar: the same synced choice on every device.
        CalendarWriteBack.shared.bindToSyncedSettings(smart)
        // Back up to iCloud: likewise one synced switch; the phone makes the backups.
        CloudBackup.shared.bind(to: settings)
        // The phone's jobs pressed on an iPad or the Mac (docs/design/ADAPTIVE-LAYOUT.md, rule 5).
        HubStatusStore.shared.onRequest = { [weak downloads, weak connectivity] kind in
            switch kind {
            case .watchResync:
                downloads?.resyncWatch()
                connectivity?.refreshTransferCount()
            case .backUpNow:
                // The service is the copy once this device has moved off iCloud (§6).
                guard !CloudBackup.isRetired else { return }
                Task { await CloudBackup.shared.backUpNow(userInitiated: true) }
            }
        }

        // A workout deleted or hidden on an iPad or the Mac: the phone, which owns Apple Health,
        // finishes it there.
        HealthRemovalInbox.shared.attach(fitness: fitness, health: health)
        // A workout trimmed or reverted, here or on another device: Apple Health's copy follows.
        WorkoutHealthFollow.shared.attach(fitness: fitness, health: health)
        // On every device: a Revert asked for where the original isn't, carried out where it is.
        WorkoutRevertInbox.shared.attach(fitness: fitness)

        // Keep the Watch's Workout source in sync with the Workout cue.
        let conn = connectivity
        conn.syncWorkoutSource()
        RoutineStore.shared.onChange = { conn.syncWorkoutSource() }

        smart.alarms = store
        smart.health = health

        // Unified timeline (L1): merge cues + derived + calendar into one occurrence list.
        OccurrenceStore.shared.settings = settings
        OccurrenceStore.shared.routines = routines
        OccurrenceStore.shared.smart = smart
        OccurrenceStore.shared.alarms = store
        OccurrenceStore.shared.health = health   // so a workout already done isn't re-booked
        let occ = OccurrenceStore.shared
        #if os(iOS)
        connectivity.bindCalendarComplication(to: occ)
        #endif
        // Coalesced: editing a routine fires onChange per field commit, and a burst of edits
        // used to cost a full recompute (EventKit + Reminders + alarm re-arm) per callback.
        RoutineStore.shared.onChange = { conn.syncWorkoutSource(); occ.requestRecompute(reason: "routines") }
        store.onOneOffChange = { occ.requestRecompute(reason: "one-off alarms") }   // one-off alarms → timeline

        // Transcripts: point the coordinator at the library + downloads, then ask the OS
        // to run the overnight (charger-only) batch transcription.
        TranscriptCoordinator.shared.library = library
        TranscriptCoordinator.shared.downloads = downloads
        TranscriptCoordinator.shared.scheduleOvernight()
        OvernightRefresh.schedule()   // feeds + auto-downloads + Watch backfill on the charger
        CalendarWriteBackRefresh.schedule()   // also re-armed on every background transition

        // Hub-and-spoke: the phone is the sole HealthKit writer — save each new
        // Watch-recorded session as the single HKWorkout (with route).
        AnchoredTimingHub.shared.start(health: health)
        // What things are done after, learned from Health, meals, Taken and Reminders' ticks.
        AnchorSuggestionStore.shared.start(health: health)
        fitness.onIngest = { [health] session in
            Task {
                await health.writeWorkout(session)
                // A Watch workout just ended: what's due after a workout is due from now.
                AnchoredTimingHub.shared.workoutEnded()
            }
        }
        // The data platform (docs/design/DATA-PLATFORM.md), unless `--no-space-sync` (`SpaceSyncFlag`):
        // once the stores it reads have loaded, the adapters join the engine and the move off iCloud
        // may start (`MoveOver`). Not behind the rest of this launch (restoring the smart schedule,
        // starting each iCloud sync): a legacy channel that hasn't started yet makes the move wait
        // for the next step, it doesn't hold the adapters back. A new device that finds the
        // account's space in use belongs to someone coming back, as a backup found today says.
        MoveOver.onReturningPerson = { [onboarding] in onboarding.completeForReturningUser() }
        let syncStores = SyncStores(
            routines: routines, alarms: store, wake: wake, exceptions: ExceptionStore.shared,
            taskDurations: TaskDurationStore.shared, reminderAnchors: ReminderAnchors.shared,
            missedRepeats: MissedRepeats.shared, anchorSuggestions: AnchorSuggestionStore.shared,
            bookingTypes: BookingTypeStore.shared,
            library: library, listenHistory: history, skipPlans: skipPlans.store, narratorVoices: NarratorVoiceStore.shared,
            voiceNotes: VoiceNoteStore.shared,
            fitness: fitness, health: health, removalInbox: HealthRemovalInbox.shared, revertInbox: WorkoutRevertInbox.shared,
            wellness: wellness, myFoods: MyFoodsStore.shared, mealInbox: MealInboxStore.shared,
            mealPhotos: MealPhotoStore.shared, mealPhotoLedger: MealPhotoLedger.shared,
            mealPhotoScanReports: MealPhotoScanReports.shared, mealEstimators: MealEstimators.shared,
            smart: smart, settings: settings, modules: ModuleStore.shared, hubStatus: HubStatusStore.shared)
        Task { @MainActor [library, history, wellness, fitness] in
            await library.whenLoaded()
            await history.whenLoaded()
            await wellness.whenLoaded()
            await fitness.whenLoaded()
            SpaceSyncLaunch.storesReady(syncStores)
        }
        // A restored smart schedule can need Notifications and Location. Never let launch-time
        // restoration get ahead of onboarding and present an unexplained system permission sheet.
        if onboarding.completed {
            await smart.apply()   // restore smart schedule if it was on
        }
        // Day can already be running this real-calendar pass while wireUp awaits Smart Schedule.
        // Join it instead of forcing a second complete 31-day traversal on a large calendar.
        // A changed wake plan has its own requestRecompute trigger and still earns the one trailing
        // pass required to make a pass that began with the old plan final.
        //
        // Not awaited: nothing below needs the timeline, and awaiting it held everything else —
        // the iCloud restore check a first launch waits on, and every sync's start — behind a
        // pass of Google reads and route lookups (16 s on the phone; on a new iPad it never
        // finished, and the app sat on its "checking iCloud" screen).
        Task { await occ.recomputeIfStale(maxAge: 0, reason: "launch") }

        // iCloud backup: an app's container dies with the app, so this is the only thing standing
        // between a reinstall and your listening history.
        CloudBackup.shared.onRestore = { [library, history, connectivity] in
            library.reloadFromDisk()
            RoutineStore.shared.reloadFromDisk()
            history.reloadFromDisk()
            ExceptionStore.shared.reloadFromDisk()
            WellnessStore.shared.reloadFromDisk()
            #if os(iOS)
            connectivity.syncWorkoutPlan()
            #endif
            Task { await OccurrenceStore.shared.recompute() }
        }
        CloudBackup.shared.onReturningUserDetected = { [onboarding] in
            onboarding.completeForReturningUser()
        }
        Task { await CloudBackup.shared.checkForRestore() }

        // Everything below reads the library's contents, and the catalogue now decodes off-main
        // (see PodcastLibrary.init) — running these against a not-yet-loaded library would resend
        // nothing to the Watch, push an empty manifest (pruning real episodes!), and seed CloudKit
        // from an empty progress set.
        await library.whenLoaded()

        // An install, jetsam, or crash terminates AVPlayer without a pause callback. Rebuild that
        // item after its feed exists again, but leave it paused: recovery must never surprise the
        // person by starting audio on launch.
        if let interrupted = PlaybackDiagnostics.shared.takeInterruptedPlayback() {
            _ = player.restorePaused(interrupted)
        }

        downloads.backfillWatch()      // resend anything that didn't make it to the Watch
        downloads.removePlayedDownloads()   // played anywhere: free this device's copy (pushes the manifest)

        // Advance the catalogue and downloads without requiring a manual per-podcast refresh.
        // Detached from the launch path — six feed fetches must not delay the rest of
        // wire-up. reconcile() starting new downloads is what ultimately feeds the Watch
        // (finishDownload sends each completed episode of a synced feed).
        Task { [downloads] in
            await downloads.refreshFeedsAndReconcile()
        }

        // Operational sync: per-episode progress records over CloudKit, phone↔Mac. Local JSON stays
        // the source of truth; this mirrors changes up and applies remote ones through the library's
        // existing last-write-wins merge.
        CloudProgressSync.shared.start(library: library)
        // Routines, one-off alarms, wake sounds and each show's settings: the same on every
        // device. After the library has loaded, so the phone never offers an empty catalogue.
        let controls = CloudControlsSync.shared
        controls.register(routines, for: .routine)
        controls.register(wake, for: .wake)
        controls.register(store, for: .alarm)
        controls.register(library, for: .podcast)
        controls.register(library, for: .show)
        controls.register(ExceptionStore.shared, for: .timelineOverride)
        controls.register(ExceptionStore.shared, for: .timelineExtra)
        ExceptionStore.shared.onCloudChange = { OccurrenceStore.shared.requestRecompute(reason: "timeline change from another device") }
        controls.register(history, for: .listen)
        controls.register(history, for: .listenRoute)
        controls.register(skipPlans.store, for: .skipPlan)
        controls.register(skipPlans.store, for: .adSlots)
        controls.register(skipPlans.store, for: .skipCorrection)
        controls.register(NarratorVoiceStore.shared, for: .narratorReading)
        controls.register(NarratorVoiceStore.shared, for: .narratorGender)
        controls.register(NarratorVoiceStore.shared, for: .narratorOverride)
        controls.register(wellness, for: .workoutPlan)
        controls.register(wellness, for: .workoutCompletion)
        controls.register(wellness, for: .foodCorrection)
        MyFoodsStore.shared.follow(wellness.$meals)
        controls.register(MyFoodsStore.shared, for: .myFood)
        ScannedNumbersRepair.run(foods: MyFoodsStore.shared, wellness: wellness, inbox: MealInboxStore.shared)
        library.onCloudSettingsApplied = { [weak downloads] old, new in
            if old.downloadRule != new.downloadRule { downloads?.reconcile(new) }
            if new.syncToWatch, !old.syncToWatch { downloads?.backfillWatch() }
        }
        // Subscribed on another device: read the feeds for their episodes, then read progress and
        // show settings again — anything that came before the shows did had nothing to apply to.
        library.onShowsArrivedFromCloud = { [weak library, weak downloads] ids in
            Task { @MainActor in
                guard let library else { return }
                for id in ids { _ = await library.refresh(id) }
                for id in ids { if let podcast = library.podcast(id) { downloads?.reconcile(podcast) } }
                CloudProgressSync.shared.fetchLibraryProgress(why: "new shows arrived")
                CloudControlsSync.shared.refetchAll()
            }
        }
        // Unsubscribed on another device: the same as unsubscribing here.
        library.onShowRemovedFromCloud = { [weak downloads, weak wake] podcast in
            downloads?.removeAllDownloads(for: podcast)
            wake?.clearIfPodcast(podcast.id)
        }
        // Everything it offers must have loaded first: an empty list mid-decode is not the truth.
        await history.whenLoaded()
        await wellness.whenLoaded()
        controls.start()
        // Fitness has a separate zone and is always on: unlike playback progress it changes only
        // when a workout or the compact Health cache changes, so it is safe to push immediately.
        // Its local index also decodes off-main; never seed CloudKit from the temporary empty list.
        await fitness.whenLoaded()
        CloudFitnessSync.shared.start(fitness: fitness, health: health, notes: VoiceNoteStore.shared)
        // Meals, supplements and doses, phone↔Mac. Same rule as fitness: seed only from the
        // decoded file, never from the empty list it starts as.
        await wellness.whenLoaded()
        CloudWellnessSync.shared.start(wellness: wellness)
        // Every sync can fetch now: the once-a-minute "what changed?" may be asked. Asked earlier
        // (it was, by the first frame), its answer named zones no sync was there to fetch.
        CloudSyncPoll.syncsHaveStarted()
        #if os(macOS)
        // Other devices' changes, now and every minute, for as long as the app runs. The window
        // starts this too when it appears; with no window, nothing else would.
        CloudSyncPoll.resume()
        #endif
        // The meal backlog: estimate what's ready here, and drop this device's copies of photos
        // nothing refers to any more.
        MealBacklogProcessor.shared.start(wellness: wellness)
        GroundedEstimateProbe.runIfRequested()
        MealPhotoRepeatProbe.runIfRequested(wellness: wellness)
        EstimatorBench.runIfRequested(wellness: wellness)
        MealDepthProbe.runIfRequested()
        let mealPhotos = Set(MealInboxStore.shared.items.flatMap { $0.photos.map(\.id) }).union(wellness.meals.flatMap(\.photoIDs))
        MealPhotoStore.shared.pruneOrphans(keeping: mealPhotos)
        // And the prints made of them here (`MealPhotoPrints`), off the main actor.
        Task { await MealPhotoPrints.shared.prune(keeping: mealPhotos) }
        #if DEBUG && os(macOS)
        // --purge-fitness-zone-dry-run / --purge-fitness-zone-apply: deliberate, operator-run
        // cleanup of the Fitness zone's phantom `workout-<uuid>` records, from an on-disk delete
        // list rather than a CloudKit query (see CloudFitnessZonePurgeTool). Needs both the sync
        // engine and the local index (the live real-workout safety check) already live, hence
        // right here rather than earlier in App.init.
        await CloudFitnessZonePurgeTool.runIfRequested()
        #endif

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--dummy-health")
            || ProcessInfo.processInfo.arguments.contains("--workout")
            || ProcessInfo.processInfo.arguments.contains("--trim") { fitness.injectSampleForPreview() }
        if ProcessInfo.processInfo.arguments.contains("--listenmap") { history.injectSampleForPreview() }
        // (--runmap injects in FitnessDebugDetail.onAppear so listens anchor to the workout)
        MemoryLog.extraInfo = { [weak player, weak library, weak fitness] in
            let p = player?.debugSummary ?? "player:-"
            let feeds = library?.podcasts.count ?? 0
            let eps = library?.podcasts.reduce(0) { $0 + $1.episodeCount } ?? 0
            let sess = fitness?.summaries.count ?? 0
            let smp = fitness?.summaries.reduce(0) { $0 + $1.sampleCount } ?? 0
            return "\(p)  lib:\(feeds)f/\(eps)ep  fit:\(sess)s/\(smp)smp"
        }
        // Memory sampling is a developer instrument, not normal app behavior. Leaving this timer
        // on in every Debug install kept waking the daily-driver phone forever with no consumer.
        if ProcessInfo.processInfo.arguments.contains("--memory-trace") {
            MemoryLog.startPeriodicLogging()
        }
        #endif
    }
}

private extension View {
    @ViewBuilder
    func bananaToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.switch)
        #else
        self
        #endif
    }
}
