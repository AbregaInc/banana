#if os(iOS)
// The iOS shell: TabView + tabViewBottomAccessory. The Mac has its own shell (MacRootView).

import Combine
import SwiftUI
import UIKit

/// Top-level shell: onboarding gates the first launch; after that a five-tab layout
/// (Plan / Workouts / Nutrition / Notes / Library) with the now-playing bar. Also runs the
/// "alarm just rang → play wake podcast" hook and offers the post-workout review.
struct RootView: View {
    /// Not observed: the shell only needs "is an alarm ringing" (`alarmRinging`, fed from that one
    /// publisher). Observing the store rebuilt the whole shell on each of its launch publishes
    /// (permission, the armed wake list) for nothing it draws.
    @Environment(\.alarmStore) private var alarmsRef
    private var store: AlarmStore? { alarmsRef.store }
    @State private var alarmRinging = false
    #if BANANA_MODULE_PODCASTS
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var music: MusicController
    #endif
    /// Used for actions only — recompute, sync permission — never to draw. Observed, every one of
    /// its publishes (ten in a launch's first seconds) rebuilt the whole tab shell.
    private var smart: SmartScheduleStore { .shared }
    @EnvironmentObject var onboarding: OnboardingStore
    /// What's waiting on you, for the tab badges. Publishes only when a count moves.
    @ObservedObject private var badges = ActionBadges.shared
    #if BANANA_MODULE_PODCASTS
    /// Actions only (feed refresh, peer serving) — see `smart`.
    private var downloads: DownloadManager { WakeCoordinator.shared.downloads }
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// A Google account connected on another device arrives through iCloud Keychain, but the
    /// credential store is only read at launch — so a device left open never saw it. Coming
    /// forward is the moment someone would expect it to appear.
    private func adoptGoogleAccountsAddedElsewhere() {
        Task { @MainActor in
            guard GoogleCalendarService.shared.adoptAccountsFromStore() else { return }
            await GoogleCalendarService.shared.refresh()
            OccurrenceStore.shared.requestRecompute(reason: "Google account added on another device")
        }
    }
    #if PI_DEVELOPMENT
    #endif
    @State private var showNowPlaying = false
    @State private var showMorningBriefing = false
    /// Remembers that the app went to the background, so only a real return runs the network
    /// half of the foreground cascade — see ForegroundCascadeRules.
    @State private var foregroundCascade = ForegroundCascadeRules()

    @StateObject private var backup = CloudBackup.shared
    @ObservedObject private var visibility = AppVisibility.shared
    /// The selected tab and each tab's open screen. Held outside the tree because `gatedContent`
    /// throws the whole tree away in the background — see ShellNavigation.
    @ObservedObject private var shell = ShellNavigation.shared
    /// Which tabs exist. Its own small store, so this redraws only when a module is switched.
    @ObservedObject private var modules = ModuleStore.shared
    private let chrome = PageChrome.shared

    var body: some View {

        let _ = RenderStats.note("RootView")
        let _ = LaunchClock.mark("root.body")
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--src-sleep") {
                NavigationStack { WakeSourceView(slot: .sleep) }   // picker verification
            } else if ProcessInfo.processInfo.arguments.contains("--morning") {
                MorningBriefingView()   // briefing layout verification
            } else if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
                // Header/layout verification (bypasses the alarm gate). Keeps the background
                // blank, so coming back from another app rebuilds the tree exactly as it does
                // for real — the path that used to lose the tab and the open note.
                if visibility.rendersContent {
                    mainTabs
                        // Mail's badge (unread in the Inbox) before Mail has started: the engine's
                        // launch mirror at once, then one read-only count a moment later, off the
                        // first frame (`MailBadgeLaunchRead`). Mail itself starts when it is shown.
                        .task {
                            #if DEBUG
                            LaunchTiming.firstFrame()
                            #endif
                            #if BANANA_UNRELEASED
                            await Self.readMailBadge()
                            #endif
                        }
                        .task {
                            // Where the shared toast sits above the tab bar and accessory.
                            if ProcessInfo.processInfo.arguments.contains("--toast-preview") {
                                ToastCenter.shared.showPreview("Deleted \u{201C}Lunch with Sam\u{201D}")
                            }
                            // `--sample-episode`: a sample episode loaded (not playing), for the
                            // player above the bar; `--player-hidden` starts it folded away.
                            let args = ProcessInfo.processInfo.arguments
                            if args.contains("--sample-episode") {
                                let library = WakeCoordinator.shared.library
                                library.injectSampleForPreview()
                                if let podcast = library.podcasts.first, let episode = podcast.ordered().first {
                                    player.loadForPreview(episode, in: podcast)
                                    player.duration = max(player.duration, 2_400)
                                    player.currentTime = player.duration * 0.42
                                }
                                if args.contains("--player-hidden") { ShellChrome.shared.playerHidden = true }
                            }
                            // `--shell-switcher-open`, `--shell-query <words>`: the switcher open, or
                            // the field with words in it, for screenshots of the bottom-bar shell.
                            if args.contains("--shell-switcher-open") { ShellChrome.shared.switcherOpen = true }
                            if let i = args.firstIndex(of: "--shell-query"), i + 1 < args.count {
                                let words = args[i + 1]
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1.5))
                                    ShellSearch.shared.text = words
                                    ShellSearch.shared.focusRequests.send(true)
                                    ShellSearch.shared.textChanged()
                                }
                            }
                            // `--shell-tick`: the playhead moves once a second, as in playback,
                            // so a test can count what that redraws (`RenderStats`).
                            if args.contains("--shell-tick") {
                                Task { @MainActor in
                                    while !Task.isCancelled {
                                        try? await Task.sleep(for: .seconds(1))
                                        player.currentTime += 1
                                    }
                                }
                            }
                        }
                } else {
                    Color.black.ignoresSafeArea()
                }
            } else if ProcessInfo.processInfo.arguments.contains("--listenmap") {
                NavigationStack { ListenMapView() }   // listen-map verification
            } else if ProcessInfo.processInfo.arguments.contains("--widgets") {
                WidgetGalleryView()
            } else if ProcessInfo.processInfo.arguments.contains("--availability") {
                AvailabilitySheet()
            } else if ProcessInfo.processInfo.arguments.contains("--now-playing") {
                NowPlayingPreviewHost()
            } else if ProcessInfo.processInfo.arguments.contains("--event-detail") {
                EventDetailView(meeting: .detailPreview)
            } else if ProcessInfo.processInfo.arguments.contains("--event-editor") {
                // `--event-editor-invite`: someone else's invitation, editable only for alerts.
                let invitation = ProcessInfo.processInfo.arguments.contains("--event-editor-invite")
                EventEditorPreviewHost(event: GoogleCalendarEvent.preview(
                    invitation: invitation,
                    withGuests: ProcessInfo.processInfo.arguments.contains("--event-editor-guests")))
            } else if ProcessInfo.processInfo.arguments.contains("--booking-preview") {
                // Settings › Booking on sample types and a stand-in service (`BookingCenter`);
                // `--booking-linked` with a handle taken, `--booking-editor` on the first type.
                NavigationStack { BookingSettingsView() }.toastHost()
            } else if ProcessInfo.processInfo.arguments.contains("--calendar-settings-preview") {
                NavigationStack {
                    IndividualCalendarsView(previewCalendars: [
                        GoogleCalendar(accountEmail: "me@example.com", id: "me@example.com", summary: "Personal", summaryOverride: nil, backgroundColor: nil, accessRole: "owner", primary: true, hidden: false, deleted: false),
                        GoogleCalendar(accountEmail: "me@example.com", id: "wife@example.com", summary: "Family", summaryOverride: nil, backgroundColor: nil, accessRole: "reader", primary: false, hidden: false, deleted: false),
                        GoogleCalendar(accountEmail: "work@example.com", id: "work@example.com", summary: "Work", summaryOverride: nil, backgroundColor: nil, accessRole: "owner", primary: true, hidden: false, deleted: false)
                    ])
                }
            } else if ProcessInfo.processInfo.arguments.contains("--settings") {
                SettingsView()
            } else if ProcessInfo.processInfo.arguments.contains("--place-picker") {
                PlacePickerView(locationText: "Chelsea", context: "Lap Swim at 7:45 PM", eventTitle: "Lap Swim")
            } else if ["--wellness", "--scan-correct-preview", "--my-foods", "--energy-balance", "--food-search"].contains(where: { ProcessInfo.processInfo.arguments.contains($0) }) {
                // `--wide-nutrition`: the iPad and Mac page, in the phone's width.
                Group {
                    if ProcessInfo.processInfo.arguments.contains("--wide-nutrition") {
                        NavigationStack { WideNutritionView() }
                    } else {
                        NavigationStack { WellnessView() }
                    }
                }
                    // With the toasts the Nutrition tab has, so an Undo can be seen here too.
                    .toastHost()
                    .onAppear {
                        WellnessStore.shared.injectPreviewData()
                        // `--nutrition-week`: a week of meals for the day strip; not in the App
                        // Store set, which stays one meal. `--nutrition-yesterday` opens a past day.
                        let args = ProcessInfo.processInfo.arguments
                        if args.contains("--nutrition-week") { WellnessStore.shared.injectWeekPreview() }
                        #if DEBUG
                        if args.contains("--meal-backlog") { MealInboxStore.shared.injectPreview() }
                        // `--energy-balance [measured|over|off|gathering]`: four weeks of meals for
                        // the logs-against-weight card; HealthKitStore seeds the weight and energy.
                        if let preview = EnergyBalance.Preview.requested(args) {
                            WellnessStore.shared.injectPreviewMeals(preview.sample().meals)
                        }
                        #endif
                        if args.contains("--nutrition-yesterday") {
                            ShellNavigation.shared.state.nutritionDay = Calendar.current.date(byAdding: .day, value: -1, to: Date())
                        }
                    }
            } else if ProcessInfo.processInfo.arguments.contains("--routines") {
                RoutinesView().toastHost()
            } else if ProcessInfo.processInfo.arguments.contains("--mail") {
                // The sample inbox on its own, with the toast it has in the shell. Modifiers:
                // `--mail-open <key>`, `--mail-cursor <key>`, `--mail-state done` (MailSession+App).
                // Blank in the background as the shell is, so that coming back rebuilds the tree
                // exactly as it does for real: what he was writing, the open conversation and the
                // cursor must all come back from the session, never from a view.
                if visibility.rendersContent {
                    #if !BANANA_PUBLIC
                    MailSection()
                        .measuresLayoutClass()
                        .toastHost()
                    #endif
                } else {
                    Color.black.ignoresSafeArea()
                }
            } else if ProcessInfo.processInfo.arguments.contains("--library-detail") {
                FirstPodcastDetailHost()   // episode-list verification (folded listened runs)
            } else if ProcessInfo.processInfo.arguments.contains("--library") {
                PodcastsView()
            } else if ProcessInfo.processInfo.arguments.contains("--notes") {
                NotesView()
            } else if ProcessInfo.processInfo.arguments.contains("--trim") {
                TrimPreviewHost()
            } else if ProcessInfo.processInfo.arguments.contains("--transcript-demo") || ProcessInfo.processInfo.arguments.contains("--voicenote-demo") {
                TranscriptDemoView()
            } else if ProcessInfo.processInfo.arguments.contains("--verify-flight-boarding") {
                FlightBoardingVerificationView()
            } else if ProcessInfo.processInfo.arguments.contains("--new-calendar-event")
                        || ProcessInfo.processInfo.arguments.contains("--new-task") {
                // The plan's Day with that sheet already open, for the sheets' own tests.
                NewItemSheetHost(task: ProcessInfo.processInfo.arguments.contains("--new-task"))
            } else if ProcessInfo.processInfo.arguments.contains("--plan") {
                // With the toasts the Plan tab has, so an Undo can be seen and tapped here too.
                PlannerTab().toastHost()
            } else if ProcessInfo.processInfo.arguments.contains("--week") {
                WeekView().toastHost()
            } else if ProcessInfo.processInfo.arguments.contains("--day") {
                WeekView(dayMode: true).toastHost()
            } else if ProcessInfo.processInfo.arguments.contains("--smart") {
                NavigationStack { SmartScheduleView() }
                    .onAppear { smart.settings.enabled = true
                                smart.settings.accountForTravel = true
                                smart.settings.commuteAlerts = true }
            } else if ProcessInfo.processInfo.arguments.contains("--runmap") {
                FitnessDebugDetail()   // podcast-colored run route verification
            } else if ProcessInfo.processInfo.arguments.contains("--workout-review") {
                PostWorkoutReviewDebugHost()   // the post-workout payoff screen
            } else if ProcessInfo.processInfo.arguments.contains("--workout-detail") {
                WorkoutDetailDebugHost()   // WorkoutDetailScreen audit against a real workout
            } else if ProcessInfo.processInfo.arguments.contains("--sleep") {
                NavigationStack { SleepView() }   // Sleep page, with two weeks of sample nights
            } else if let kind = MetricKind.launchArgument {
                NavigationStack { TrendDetailView(kind: kind, window: .month) }   // `--trend steps`
            } else if ProcessInfo.processInfo.arguments.contains("--review") {
                // Review, as the chart button on Workouts opens it: a sheet, with its Done.
                ReviewView(from: .workouts, showsDoneButton: true)
            } else if ProcessInfo.processInfo.arguments.contains("--trends") {
                NavigationStack { TrendsView() }   // every metric, two years of sample data
            } else if ProcessInfo.processInfo.arguments.contains("--dummy-health")
                        || ProcessInfo.processInfo.arguments.contains("--workout")
                        || ProcessInfo.processInfo.arguments.contains("--rhythm") {
                // `--rhythm` opened the retired Rhythm tab; it lands on Workouts for one release so
                // old scripts keep working. Guided plans now live under Workouts, so this route
                // seeds the same wellness fixtures `--wellness` does or "Saved plans" is empty.
                Group {
                    if ProcessInfo.processInfo.arguments.contains("--wide-workouts") {
                        WideWorkoutsView()
                    } else {
                        NavigationStack { FitnessView() }
                    }
                }   // layout-verification harness
                    .onAppear { WellnessStore.shared.injectPreviewData() }
            } else {
                gatedContent
            }
            #else
            gatedContent
            #endif
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--library-publish-regression")
                || ProcessInfo.processInfo.arguments.contains("--storm-selftest")
                || ProcessInfo.processInfo.arguments.contains("--smart-publish-regression")
                || ProcessInfo.processInfo.arguments.contains("--offscreen-recompute-regression")
                || ProcessInfo.processInfo.arguments.contains("--calendar-move-render-probe")
                || ProcessInfo.processInfo.arguments.contains("--calendar-artwork-test-probe")
                || ProcessInfo.processInfo.arguments.contains("--tab-reentry-probe")
                || ProcessInfo.processInfo.arguments.contains("--perf-trace") {
                DayPerformanceRenderProbe()
            }
        }
        #endif
        // (dummy-health branch above bypasses the gate for layout checks)
        // A fresh install found a backup in iCloud. Never applied without a yes — a deliberate
        // clean slate is a legitimate thing to want.
        .alert("Restore from iCloud?", isPresented: .constant(backup.pendingRestore != nil)) {
            Button("Restore") { if let snap = backup.pendingRestore { backup.restore(snap) } }
            Button(backup.restoreDeclineTitle, role: .cancel) { backup.discardPendingRestore() }
        } message: {
            if let snap = backup.pendingRestore {
                let _ = snap
                Text(backup.restoreQuestion)
            }
        }
        // Leaving onboarding is the one transition guaranteed to have changed permissions, and
        // it never raises a scenePhase event — the system prompts arrive as `.inactive`, which
        // is deliberately ignored. MacRootView already refreshes here; iOS did not.
        .onChange(of: onboarding.completed) { _, done in
            if done { Task { await smart.syncCalendarAuthorization() } }
        }
        .onAppear {
            LaunchClock.mark("root.appear")   // ≈ first frame on screen
            #if BANANA_MODULE_PODCASTS
            #if !PI_DEVELOPMENT
            if scenePhase == .active {
                downloads.setPeerServingAllowed(true)
            }
            #endif
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantOpenSection)) { notice in
            guard let raw = notice.object as? String, let section = AppSection(rawValue: raw) else { return }
            if showsSidebarSections { shell.state.tab = section }
            else {
                switch section {
                case .settings: PageChrome.shared.showSettings = true
                case .routines: PageChrome.shared.showRoutines = true
                case .review: PageChrome.shared.review = shell.state.tab
                case .assistant: PageChrome.shared.showAssistant = true
                default: shell.state.tab = section
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            ImageCache.shared.clearMemory()
        }
        .fullScreenCover(isPresented: $showMorningBriefing) {
            MorningBriefingView()
        }
        #if BANANA_MODULE_WORKOUTS
        // The workout payoff lives in its own zero-size view: it watches FitnessStore and
        // HealthKitStore, and those must never be observed from the shell itself (see
        // WorkoutReviewPresenter).
        .background {
            WorkoutReviewPresenter(suppressed: showMorningBriefing || alarmRinging)
        }
        #endif
        .onReceive(store?.$isAlerting.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()) {
            if alarmRinging != $0 { alarmRinging = $0 }
        }
        .onChange(of: alarmRinging) { _, alerting in
            // Wake audio begins after the system alarm stops. Starting it on →true raced the
            // Stop intent against the same SystemMusicPlayer queue; →false is the UI fallback
            // when the Stop intent did not run (for example, the alarm was stopped elsewhere).
            Log.wake.notice("isAlerting → \(alerting); re-checking wake trigger")
            if !alerting { handleWakeIfNeeded() }
        }
        .onChange(of: scenePhase) { previous, phase in
            #if PI_DEVELOPMENT
            // The local Pi build has no production service startup or cloud restore.
            // Keep the drawing lifecycle without starting those services on foreground.
            AppVisibility.shared.set(active: phase != .background)
            #else
            #if DEBUG
            // Screenshot routes render the real screen but intentionally do not start the
            // production CloudKit/background graph (the unsigned Simulator cannot construct
            // that container, and a scene transition would otherwise crash the audit harness).
            //
            // This used to check only "--ui-audit", which is the macOS route's own flag
            // (MacRootView.swift) and is never passed on an iOS launch — so on iOS this guard
            // could never fire, and every iOS visual-audit route (--today, --week, --day, …) hit
            // the full production EventKit/CloudKit resync below within roughly a second of
            // launch, overwriting the route's injected fixture data with real (empty-on-Simulator)
            // state right out from under it. VisualAuditRoute is the actual, complete set of
            // iOS screenshot-route flags — see its doc comment for why it's shared with BananaApp.
            if ProcessInfo.processInfo.arguments.contains("--ui-preview")
                || ProcessInfo.processInfo.arguments.contains("--mail") {
                // Only the drawing gate: the rest of this handler starts services the unsigned
                // Simulator build can't construct. Mail's own backgrounding note is what the
                // shell does too, and it writes nothing of the production graph.
                AppVisibility.shared.set(active: phase != .background)
                #if !BANANA_PUBLIC
                if phase == .background { MailSession.noteBackgrounding() }
                #endif
            }
            guard !VisualAuditRoute.matches() else { return }
            #endif
            // `.active` is also what Control Center, the shade and a permission alert return
            // through: the network half below waits for a real return from `.background`.
            var cascade = foregroundCascade
            let plan = cascade.phaseChanged(from: previous, to: phase)
            if cascade != foregroundCascade { foregroundCascade = cascade }   // a glance writes nothing
            switch phase {
            case .active:
                Log.wake.notice("scenePhase → active; checking wake trigger")
                AppVisibility.shared.set(active: true)
                TripLearningService.shared.appBecameActive()   // turned on elsewhere: ask here
                if plan.runsNetworkAndSync {
                HubStatusStore.shared.handleRequests()          // asked for on another device
                #if BANANA_MODULE_WORKOUTS
                Task { await HealthRemovalInbox.shared.settle() }   // and a workout removed on one
                #endif
                Telemetry.shared.calendarConnected = { !GoogleCalendarService.shared.accounts.isEmpty }
                Telemetry.shared.setup = { await TelemetryState.signals() }
                Telemetry.shared.session = { BananaAccount.shared.authorization }
                BananaAccount.shared.start()                   // signed in elsewhere; this device; calendars to watch
                Telemetry.shared.cameForward()                  // opened today; what's counted goes
                DiagnosticReports.shared.send()                 // crash and performance reports waiting
                ProblemReporter.shared.flush()                  // problem reports waiting
                #if BANANA_MODULE_WORKOUTS
                Task {                                               // or trimmed, or reverted
                    await WorkoutRevertInbox.shared.settle()
                    await WorkoutHealthFollow.shared.settle()
                }
                #endif
                CloudSyncPoll.resume()                          // other devices' changes, now and every minute
                }
                #if BANANA_MODULE_PODCASTS
                HubStatusStore.shared.update { $0.watchEpisodesPending = downloads.watchPendingCount }
                // In front means polling: stopped only by `.background`, so a no-op unless it was.
                downloads.setPeerServingAllowed(true)
                player.setInterfaceActive(true)
                PlaybackDiagnostics.shared.log("app → foreground", "playing=\(player.isPlaying)")
                #endif
                if plan.runsNetworkAndSync { adoptGoogleAccountsAddedElsewhere() }   // keychain read, then a Google refresh
                #if BANANA_MODULE_PODCASTS
                music.reconcileWakeState()   // drop a stale music-wake bar if it was stopped while suspended
                #endif
                handleWakeIfNeeded()
                // Permissions change outside the app — in Settings, or via onboarding's own
                // EventKit store. Re-read on every foreground so a granted calendar can never
                // leave Today showing "Calendar isn't connected". No-ops unless it moved.
                if plan.rereadsPermissions {
                    Task { await smart.syncCalendarAuthorization() }
                    Task { await OccurrenceStore.shared.syncRemindersAuthorization() }
                    #if BANANA_MODULE_PODCASTS
                    Task { await music.syncAuthorization() }
                    #endif
                    // Write-back reads its own EventKit status; refreshCalendars is what updates it.
                    CalendarWriteBack.shared.refreshCalendars()
                    Task { await onboarding.refresh() }   // location + notification status
                }
                if plan.runsNetworkAndSync {
                    Task { await smart.recomputeIfStale() }   // keep the wake plan fresh; skip when it already is
                    #if BANANA_MODULE_PODCASTS
                    // Manual-cadence sync fetches only when told to — foreground is when another
                    // device's session is worth picking up. No-op while sync is off.
                    CloudProgressSync.shared.flushNow(reason: "foreground")
                    // Keep feeds and auto-downloads moving on the app people actually open.
                    // Throttled inside (4h) so this is free on rapid app switches.
                    Task { await downloads.refreshFeedsAndReconcile() }
                    #endif
                }
            case .inactive:
                // Still on screen. `.inactive` fires for Control Center, notification center,
                // permission alerts (including onboarding's own), the app switcher, and incoming
                // call banners — treating it as "invisible" blanked the app to black behind every
                // one of those and paid a full tree rebuild (+ a progress commit + a backup pass)
                // per glance. Only `.background` means nobody can see us. In particular, the
                // return path may be background → inactive → active; restore at inactive so the
                // app-switcher transition never exposes our deliberate black CPU guard.
                AppVisibility.shared.set(active: true)
            case .background:
                CloudSyncPoll.pause()
                Telemetry.shared.send()
                // Stamped so a gap in the journal is legible: if the app is suspended mid-episode,
                // the last line before the silence is this one.
                AppVisibility.shared.set(active: false)
                #if BANANA_UNRELEASED
                MailSession.noteBackgrounding()   // the open conversation, if Mail has one
                #endif
                ShellNavigation.shared.save()   // `savedAt` = when they left, for a cold relaunch
                #if BANANA_MODULE_PODCASTS
                downloads.setPeerServingAllowed(false)
                player.setInterfaceActive(false)
                PlaybackDiagnostics.shared.log("app → background", "playing=\(player.isPlaying)")
                player.commitProgress()
                CloudProgressSync.shared.flushNow(reason: "background")
                #endif
                // Progress saves during playback deliberately skip the iCloud upload (they run
                // every 30s and each one re-reads and uploads the whole library). Leaving the app
                // is the natural point to push the latest state up.
                Task { await CloudBackup.shared.backUpNow(userInitiated: false) }
                // Keep a calendar write-back window on the books so a meeting Calendly books (or
                // a return-home hold it creates room for) while the app is closed still gets a
                // busy block before the person is back to open Banana themselves.
                CalendarWriteBackRefresh.schedule()
            @unknown default:
                break
            }
            #endif
        }
    }

    @ViewBuilder private var gatedContent: some View {
        // Off-screen → render NOTHING. This is a background-AUDIO app, so it keeps running with the
        // screen locked; the crash reports prove it also kept RENDERING there, pinning a core at 99%
        // in a continuous SwiftUI/AttributeGraph update loop until iOS killed it for exceeding the
        // background CPU budget (cpu_resource_fatal) — which is what stopped playback mid-episode.
        // Gating only PlannerTab wasn't enough: the whole TabView, the now-playing bar, and every
        // tab's body stayed live. With the entire tree replaced by a static view while backgrounded,
        // there is simply nothing for SwiftUI to re-evaluate, so no loop can burn CPU. Audio is
        // AVPlayer + the lock-screen now-playing center, both independent of this view tree, so
        // playback and its controls are unaffected. The tree rebuilds on return to foreground.
        if !visibility.rendersContent {
            // `rendersContent`, not `isActive`: this lags backgrounding by a beat so iOS's
            // app-switcher snapshot catches the real screen instead of this black rectangle.
            Color.black.ignoresSafeArea()
        } else if Self.isOnboardingPreview && !onboarding.completed {
            // A routed page shows until the first run is finished from it, then the app.
            OnboardingView()
        } else if Self.isLocalPiBuild || onboarding.completed {
            // No permission gates the app. Alarms are one feature of many, and blocking the
            // calendar timeline, tasks, notes, and the podcast library behind an alarm grant
            // means a person who simply doesn't want us setting alarms can never get in.
            // The ask now lives where it pays off — see AlarmStore.isAuthorized checks in the
            // wake surfaces — instead of in front of the door.
            // The same app whichever way the phone is held. Landscape used to swap it for a
            // bedside clock, so nothing could be used on its side.
            mainTabs
        } else if !backup.initialRestoreCheckFinished {
            ReturningUserCheckView()
        } else {
            OnboardingView()
        }
    }

    private static var isLocalPiBuild: Bool {
        #if PI_DEVELOPMENT
        true
        #else
        false
        #endif
    }

    /// DEBUG: show onboarding regardless of whether it was completed (see OnboardingView).
    private static var isOnboardingPreview: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--onboarding-step")
            || arguments.contains("--writeback-setup-preview")
        #else
        return false
        #endif
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Sleep, Trends, Routines and Settings get sidebar rows when there's a sidebar to put them
    /// in. A tab bar would push them into a "More" overflow (and `.tabPlacement(.sidebarOnly)`
    /// doesn't keep them out of an iPhone's), so they're added only where a sidebar can exist —
    /// iPad-class devices, which is what the OS allows — and there's room for one.
    private var showsSidebarSections: Bool {
        horizontalSizeClass == .regular && DeviceRole.current != .phone
    }

    /// Which navigation layer the shell's width calls for (`ShellLayout`); nil until measured.
    @State private var rootShell: ShellLayout?

    /// The bottom-bar shell (docs/design/BOTTOM-BAR-SHELL.md): a phone either way up, an iPad
    /// upright, any split or Slide Over. The rail only where a landscape iPad's room is. Decided
    /// by width, never by device.
    #if BANANA_UNRELEASED
    /// The shell's Mail badge before Mail has started (`MailBadgeLaunchRead`); the sample mailbox
    /// (`--mail-fresh`) is its own session and badges itself.
    static func readMailBadge() async {
        // `--no-mail-badge-read`: none of this, for a launch comparison.
        guard ModuleStore.shared.includes(.email),
              !ProcessInfo.processInfo.arguments.contains("--no-mail-badge-read") else { return }
        if MailSession.shared != nil { return }
        if let mirrored = MailBadgeLaunchRead.mirrored() { ActionBadges.shared.setMailInbox(mirrored) }
        try? await Task.sleep(for: .seconds(2))
        guard MailApplication.shared.session == nil else { return }
        #if DEBUG
        let began = Date()
        #endif
        if let unread = await MailBadgeLaunchRead.read(), MailApplication.shared.session == nil {
            ActionBadges.shared.setMailInbox(unread)
        }
        #if DEBUG
        LaunchTiming.note("mail_badge_read_ms", Date().timeIntervalSince(began) * 1000)
        #endif
    }
    #endif

    private var bottomBarShell: Bool {
        (rootShell ?? ShellLayout.of(width: Double(UIScreen.main.bounds.width))) == .bottomBar
    }

    /// The tab bar or sidebar with its bottom accessory: no width has it now (the bar at the
    /// bottom, or the rail); kept as the one switch should a width go back to it.
    private var classicShell: Bool { false }

    /// The pages the switcher lists: only the modules that are on.
    private var shellPages: [ShellPage] {
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

    /// The switcher's page for the section showing.
    private var currentShellPage: ShellPage? {
        if shell.state.tab == .settings { return .settings }
        if shell.state.tab == .review, showsSidebarSections { return .review }
        return switch shell.state.tab.tabBarHome {
        case .plan: .plan
        case .mail: .mail
        case .workouts, .nutrition: .body
        case .notes: .notes
        case .library: .library
        default: nil
        }
    }

    private func openShellPage(_ page: ShellPage) {
        switch page {
        case .plan: shell.state.tab = .plan
        case .mail: shell.state.tab = .mail
        case .body: shell.state.tab = bodyShowing
        case .notes: shell.state.tab = .notes
        case .library: shell.state.tab = .library
        case .review: PageChrome.shared.review = shell.state.tab.tabBarHome
        case .settings: PageChrome.shared.showSettings = true
        }
    }

    /// A sidebar-only section open when the sidebar goes (an iPad narrowed into a split) shows
    /// the tab it lives under instead of nothing.
    private var tabSelection: Binding<ShellTab> {
        Binding(
            get: {
                // A section whose module is off has no tab: it opens Plan.
                let tab = shell.state.tab.shown(with: modules.effectiveChoice)
                let home = showsSidebarSections ? tab.sidebarHome : tab.tabBarHome
                return addOpensList && BodyPage.holds(home) ? .body : .section(home)
            },
            set: {
                switch $0 {
                case .section(let section): shell.state.tab = section
                case .body: shell.state.tab = bodyShowing
                }
            })
    }

    /// The + is on the tab bar's row where the bar is at the bottom of the screen: a phone, and
    /// an iPad narrowed into a split. (With a sidebar the bar is at the top, and a page's own +
    /// stays at the bottom right.)
    private var addOpensList: Bool { !showsSidebarSections }

    /// Which of its two pages the Body tab shows: the one last looked at.
    private var bodyShowing: AppSection {
        // Only ever a page whose module is on.
        if !modules.includes(.workouts) { return .nutrition }
        if !modules.includes(.food) { return .workouts }
        let open = shell.state.tab.tabBarHome
        return BodyPage.holds(open) ? open : lastBody
    }

    /// The Body tab's label: with one of its two pages switched off, the other's own name.
    private var bodyLabel: (title: String, symbol: String) {
        switch (modules.includes(.workouts), modules.includes(.food)) {
        case (true, false): (AppSection.workouts.title, AppSection.workouts.symbol)
        case (false, true): (AppSection.nutrition.title, AppSection.nutrition.symbol)
        default: (BodyPage.title, BodyPage.symbol)
        }
    }
    @State private var lastBody = AppSection.workouts

    /// Each tab hosts the toast itself (not the TabView): inside a tab the bottom safe area already
    /// clears the tab bar and the now-playing accessory, so the toast sits just above them.
    @ViewBuilder private var mainTabs: some View {
        // The fixed app is home in every build; the agent is a way in (the +) and out (Review),
        // not a screen of its own. Where a landscape iPad's room is, the rail of pages at the left
        // edge (docs/design/BOTTOM-BAR-SHELL.md, Wide); anywhere narrower, the bar at the bottom.
        HStack(spacing: 0) {
            if !bottomBarShell {
                ShellRail(pages: shellPages, current: currentShellPage, open: openShellPage)
            }
            browseTabs
        }
        // The whole shell's width, rail included: measured inside it, the rail's own width would
        // flip the class back and forth at the line.
        .onGeometryChange(for: ShellLayout.self) { ShellLayout.of(width: Double($0.size.width)) } action: { layout in
            if rootShell != layout { rootShell = layout }
        }
    }

    private var tabs: some View {
        // One shell for every width: a tab bar when narrow (iPhone, a narrow iPad split, a folded
        // phone), a sidebar with every section when there's room (iPad, an unfolded phone) —
        // the sections the Mac sidebar lists, from the same `AppSection`. Each section measures
        // its own column and lays itself out for it (docs/design/ADAPTIVE-LAYOUT.md).
        TabView(selection: tabSelection) {
            Tab(AppSection.plan.title, systemImage: AppSection.plan.symbol, value: ShellTab.section(.plan)) {
                // The shell legitimately observes playback, permissions, backup, and sync state.
                // None of those changes the calendar subtree. Keep their launch-time publication
                // bursts from rebuilding the expensive day grid.
                PlannerTab().equatable()
                    .measuresLayoutClass()
                    .toastHost()
                    .shellPage(bottomBar: bottomBarShell).erasedTab()
            }
            // Overdue reminders.
            .badge(badges.counts.plan)
            #if BANANA_UNRELEASED
            if modules.includes(.email) {
                Tab(AppSection.mail.title, systemImage: AppSection.mail.symbol, value: ShellTab.section(.mail)) {
                    MailSection().measuresLayoutClass().toastHost()
                        .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
            }
            #endif
            #if BANANA_MODULE_WORKOUTS || BANANA_MODULE_FOOD
            if addOpensList, BodyPage.isShown(with: modules.effectiveChoice) {
                // The + takes a place on the row and a phone's bar holds five: Workouts and
                // Nutrition share one, with one switch across both at the top (`BodySwitch`).
                Tab(bodyLabel.title, systemImage: bodyLabel.symbol, value: ShellTab.body) {
                    Group {
                        #if BANANA_MODULE_WORKOUTS && BANANA_MODULE_FOOD
                        if bodyShowing == .nutrition {
                            NutritionSection()
                                .measuresLayoutClass()
                                .syncWaitingNote(.wellness)
                                .toastHost()
                        } else {
                            WorkoutsSection(path: $shell.state.workouts)
                                .measuresLayoutClass()
                                .syncWaitingNote(.fitness)
                                .toastHost()
                        }
                        #elseif BANANA_MODULE_FOOD
                        NutritionSection().measuresLayoutClass().syncWaitingNote(.wellness).toastHost()
                        #else
                        WorkoutsSection(path: $shell.state.workouts).measuresLayoutClass().syncWaitingNote(.fitness).toastHost()
                        #endif
                    }
                    .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
                // Meals to log or check, and doses due and not yet marked.
                .badge(badges.counts.nutrition)
                .accessibilityIdentifier("tab.body")
            } else if !addOpensList {
                // The two things used daily — the workout just done, logging a meal — are tabs,
                // not cards at the bottom of a weekly review. Routines is configuration edited
                // weekly at most; it lives under Plan's "…" menu on a phone.
                #if BANANA_MODULE_WORKOUTS
                if modules.includes(.workouts) {
                    Tab(AppSection.workouts.title, systemImage: AppSection.workouts.symbol, value: ShellTab.section(.workouts)) {
                        WorkoutsSection(path: $shell.state.workouts)
                            .measuresLayoutClass()
                            .syncWaitingNote(.fitness)
                            .toastHost()
                            .shellPage(bottomBar: bottomBarShell).erasedTab()
                    }
                }
                #endif
                #if BANANA_MODULE_FOOD
                if modules.includes(.food) {
                    Tab(AppSection.nutrition.title, systemImage: AppSection.nutrition.symbol, value: ShellTab.section(.nutrition)) {
                        NutritionSection()
                            .measuresLayoutClass()
                            .syncWaitingNote(.wellness)
                            .toastHost()
                            .shellPage(bottomBar: bottomBarShell).erasedTab()
                    }
                    // Meals to log or check, and doses due and not yet marked.
                    .badge(badges.counts.nutrition)
                }
                #endif
            }
            #endif
            #if BANANA_MODULE_NOTES
            if modules.includes(.notes) {
                Tab(AppSection.notes.title, systemImage: AppSection.notes.symbol, value: ShellTab.section(.notes)) {
                    NotesView()
                        .measuresLayoutClass()
                        .toastHost()
                        .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
            }
            #endif
            if showsSidebarSections {
                // In the iPad's tab bar as well as its sidebar: sidebar-only, it was nowhere to be
                // seen with the bar showing, and read as gone. (A phone keeps it under Plan's "…".)
                Tab(AppSection.routines.title, systemImage: AppSection.routines.symbol, value: ShellTab.section(.routines)) {
                    RoutinesView()
                        .measuresLayoutClass()
                        .toastHost()
                        .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
            }
            #if BANANA_MODULE_PODCASTS
            if modules.includes(.podcasts) {
                Tab(AppSection.library.title, systemImage: AppSection.library.symbol, value: ShellTab.section(.library)) {
                    PodcastsView()
                        .measuresLayoutClass()
                        .syncWaitingNote(.controls)
                        .toastHost()
                        .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
            }
            #endif
            #if BANANA_MODULE_WORKOUTS || BANANA_MODULE_FOOD || BANANA_MODULE_PODCASTS
            if showsSidebarSections, AppSection.review.isShown(with: modules.effectiveChoice) {
                // Looking back, in the sidebar where there is one. (On a phone it opens from the
                // chart button at the top left of every tab.) Sleep and Trends were rows here.
                Tab(AppSection.review.title, systemImage: AppSection.review.symbol, value: ShellTab.section(.review)) {
                    ReviewView(from: chrome.reviewFrom)
                        .measuresLayoutClass()
                        .syncWaitingNote(.fitness)
                        .toastHost()
                        .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
                .tabPlacement(.sidebarOnly)
            }
            #endif
            if showsSidebarSections {
                #if BANANA_AI && !PI_DEVELOPMENT
                Tab(AppSection.assistant.title, systemImage: AppSection.assistant.symbol, value: ShellTab.section(.assistant)) {
                    AssistantView().measuresLayoutClass()
                        .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
                .tabPlacement(.sidebarOnly)
                #endif
                Tab(AppSection.settings.title, systemImage: AppSection.settings.symbol, value: ShellTab.section(.settings)) {
                    SettingsView()
                        .measuresLayoutClass()
                        .toastHost()
                        .shellPage(bottomBar: bottomBarShell).erasedTab()
                }
                .tabPlacement(.sidebarOnly)
            }
            // No + in the bar: it was the search tab's slot, which is a page to iOS, so a tap slid
            // the selection across, showed that empty page for a moment and snapped back before
            // the list came up. The + is each page's own, in its top bar (`PageChrome`).
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)   // collapse to a pill on scroll, tap to expand
        #if BANANA_MODULE_PODCASTS
        .tabViewBottomAccessory(isEnabled: classicShell && (player.currentEpisode != nil || music.wakePlaying != nil)) {
            // An Apple Music wake plays in the Music app, so the podcast bar has nothing to
            // show — without this branch the ONLY way to stop wake music was the Lock Screen.
            if player.currentEpisode != nil {
                NowPlayingBar(onExpand: { showNowPlaying = true })
            } else {
                MusicWakeBar()
            }
        }
        #endif
    }

    /// The tab view, with what both shells add around it: the bar or the rail's results, the
    /// player, the sheets, the toast and the voice note host.
    private var browseTabs: some View {
        tabs
        .environment(\.addOpensList, addOpensList)
        .onChange(of: shell.state.tab) { _, tab in
            if BodyPage.holds(tab.tabBarHome), tab.tabBarHome.isShown(with: modules.effectiveChoice) { lastBody = tab.tabBarHome }
        }
        #if DEBUG
        // `--tab <section>`: open on that section (layout audits on any device).
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let section = AppSection(rawValue: args[i + 1]) {
                shell.state.tab = section
            }
            if args.contains("--meal-backlog") { MealInboxStore.shared.injectPreview() }
            // `--telemetry-probe <file>`: the day's setup facts as they would be counted, written out.
            if let i = args.firstIndex(of: "--telemetry-probe"), i + 1 < args.count {
                try? await Task.sleep(for: .seconds(3))
                let lines = await TelemetryState.signals().map { "\($0.name)=\($0.detail)" }
                try? lines.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            }
            // `--tick-self-check <file>`: the store's handling of a ticked reminder, written out.
            if let i = args.firstIndex(of: "--tick-self-check"), i + 1 < args.count {
                let lines = await OccurrenceStore.shared.tickSelfCheck()
                try? lines.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            }
        }
        #endif
        .tint(DS.Palette.accent)
        // The bottom-bar shell: one bar for every page, with the player above it. The pages
        // scroll under it (it is their bottom safe area), and it rides up with the keyboard.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bottomBarShell {
                ShellBarHost(section: shell.state.tab.tabBarHome, pages: shellPages,
                             open: openShellPage, expandPlayer: { showNowPlaying = true })
            }
        }
        // What the field found, over the page; then the switcher's column over everything.
        .overlay {
            if bottomBarShell {
                ShellResultsOverlay(section: shell.state.tab.tabBarHome)
                ShellSwitcherOverlay(pages: shellPages, current: currentShellPage, open: openShellPage)
            }
        }
        #if BANANA_MODULE_PODCASTS
        // Wide: the player at the foot of the page, as the Mac has it (no bar to sit above).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !bottomBarShell, player.currentEpisode != nil || music.wakePlaying != nil {
                Group {
                    if player.currentEpisode != nil {
                        NowPlayingBar(onExpand: { showNowPlaying = true })
                    } else {
                        MusicWakeBar()
                    }
                }
                .padding(.vertical, DS.Space.xs)
                .frame(maxWidth: 560)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, DS.Space.s)
            }
        }
        #endif
        // Wide: what the field in a page's toolbar found, hanging under the toolbar.
        .overlay(alignment: .top) {
            if !bottomBarShell {
                ShellWideResults(section: shell.state.tab.tabBarHome)
                    .padding(.top, 52)
            }
        }
        // Floats just above the bottom accessory: visible without covering anything, and it
        // clears itself after a few seconds whether or not anyone was looking.
        #if BANANA_MODULE_PODCASTS
        .overlay(alignment: .bottom) {
            SkipNoticeBar().padding(.bottom, 96)
        }
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        #endif
        #if BANANA_MODULE_NOTES
        .modifier(VoiceCaptureHost(playerOpen: showNowPlaying))
        #endif
        .modifier(PageChromeHost(sidebar: showsSidebarSections))
    }

    /// When the app becomes active shortly after an alarm rang, start the
    /// chosen wake source automatically.
    private func handleWakeIfNeeded() {
        guard let store else { return }
        guard !store.isAlerting else {
            Log.wake.notice("wake trigger deferred while alarm is still ringing")
            return
        }
        guard store.consumeRecentAlarm() else { return }
        #if BANANA_MODULE_PODCASTS
        Task { await WakeCoordinator.shared.startWake(reason: "on-open") }
        #endif
        showMorningBriefing = true   // the wake payoff screen
    }

}

#if BANANA_MODULE_WORKOUTS
/// Presents the post-workout review the first time the app is used after a workout arrives.
///
/// It is a separate zero-size view on purpose. The stores it watches — FitnessStore and
/// HealthKitStore — publish in bursts (a sync, the launch-time series backfill), and an
/// `@EnvironmentObject` on RootView would have re-rendered the whole TabView on every one of
/// them: the phone journal showed RootView×91 and WeekView×104 in fifteen seconds, 123 % CPU,
/// thermal state "serious". Here a publish invalidates a view with no body to speak of.
///
/// `suppressed` is true while something else owns the screen (the morning briefing, a ringing
/// alarm); the review is then left un-consumed and offered at the next opportunity.
private struct WorkoutReviewPresenter: View {
    let suppressed: Bool
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore
    @ObservedObject private var visibility = AppVisibility.shared
    @ObservedObject private var review = WorkoutReviewCoordinator.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Dismissing the cover clears `pending`.
            .fullScreenCover(item: $review.pending) { subject in
                PostWorkoutReviewView(subject: subject)
            }
            .onAppear { check() }
            .onChange(of: visibility.isActive) { _, active in if active { check() } }
            .onChange(of: suppressed) { _, now in if !now { check() } }
            .onChange(of: fitness.summaries.count) { _, _ in check() }
            .onChange(of: health.workouts.count) { _, _ in check() }
    }

    private func check() {
        #if DEBUG
        guard !WorkoutReviewCoordinator.isSuppressedByLaunchArguments else { return }
        #endif
        // The review is the phone's moment, just after the workout; an iPad would otherwise pop
        // it full-screen for every workout that syncs over.
        guard DeviceRole.current.isHub, visibility.isActive, !suppressed else { return }
        review.check(summaries: fitness.summaries, healthWorkouts: health.workouts)
    }
}
#endif

#if DEBUG
/// Test-only probe kept in its own subtree so sampling diagnostics never invalidates RootView or
/// the calendar it is measuring.
private struct DayPerformanceRenderProbe: View {
    @State private var counts: [String: Int] = [:]
    private let probes = [
        ("day.performance.renderCount", "WeekView"),
        ("calendar.performance.preparations", "Calendar.prepareDays"),
        ("calendar.performance.appearances", "Calendar.appear"),
        ("notes.performance.renderCount", "NotesView"),
        ("notes.performance.loads", "Notes.loadPage"),
        ("notes.performance.appearances", "Notes.appear"),
        ("shell.performance.bar", "ShellBottomBar"),
        ("shell.performance.capsule", "ShellPlayerCapsule"),
        ("shell.performance.line", "ShellPlaybackLine"),
        ("shell.performance.root", "RootView")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(probes, id: \.0) { identifier, metric in
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(identifier)
                    .accessibilityValue("\(counts[metric, default: 0])")
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-artwork-test-probe") {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("calendar.artwork.mounted")
                    .accessibilityValue(artworkMounts)
            }
        }
        .task {
            while !Task.isCancelled {
                counts = RenderStats.lifetimeSnapshot()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var artworkMounts: String {
        let mounted = counts.filter { $0.key.hasPrefix("Calendar.artwork.") }
        return (try? JSONSerialization.data(withJSONObject: mounted, options: .sortedKeys))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
#endif

#if DEBUG
private struct FlightBoardingVerificationView: View {
    private let failures = FlightParser.boardingVerificationFailures()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.largeTitle)
                .foregroundStyle(failures.isEmpty ? .green : .red)
            Text(failures.isEmpty ? "BOARDING PARSER PASS" : "BOARDING PARSER FAIL")
                .font(.headline)
            ForEach(failures, id: \.self) { Text($0).font(.caption) }
        }
        .padding()
    }
}
#endif

/// A returning install may need a moment to discover the predecessor's iCloud snapshot. Keeping
/// the new-user tour behind this small launch state prevents it from appearing and then vanishing.
private struct ReturningUserCheckView: View {
    var body: some View {
        VStack(spacing: 18) {
            BrandMark()
            ProgressView()
            Text("Checking iCloud…")
                .font(.headline)
            Text("If you use Banana on another device, your setup comes across.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("returning-user-check")
    }
}

#endif

#if DEBUG && os(iOS)
/// `--trim`: the trim sheet on the sample workout, once the store has loaded. (It read the first
/// workout at the first render, before there was one, and showed nothing.)
struct TrimPreviewHost: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var ready = false
    var body: some View {
        Group {
            if ready, let summary = fitness.summaries.first { TrimWorkoutView(summary: summary) } else { ProgressView() }
        }
        .task {
            await fitness.whenLoaded()
            fitness.injectSampleForPreview()
            ready = true
        }
    }
}

/// `--library-detail`: straight to the first preview podcast's episode list, so the
/// folded listened runs can be screenshot-verified without navigation taps.
struct FirstPodcastDetailHost: View {
    @EnvironmentObject var library: PodcastLibrary
    var body: some View {
        if let first = library.podcasts.first {
            NavigationStack { PodcastDetailView(podcastID: first.id) }
        } else {
            ProgressView()
        }
    }
}
#if DEBUG
/// `--now-playing`: the full player on a sample episode (no audio), for screenshots.
private struct NowPlayingPreviewHost: View {
    @EnvironmentObject private var library: PodcastLibrary
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        NowPlayingView()
            .task {
                library.injectSampleForPreview()
                if let podcast = library.podcasts.first, let episode = podcast.ordered().first {
                    player.loadForPreview(episode, in: podcast)
                }
            }
    }
}
#endif
#endif

#if os(iOS) && BANANA_MODULE_NOTES
/// The one place a voice note's recording screen is shown — except over the full player, which
/// shows its own because it's on top. The now-playing bar, Notes and the player each used to
/// present it; iOS shows one sheet at a time, so with a podcast loaded (the bar on screen) two of
/// them fought over it, each re-presenting the moment the other won.
///
/// A modifier with its own observer, so a note changing doesn't re-render the whole shell.
private struct VoiceCaptureHost: ViewModifier {
    @ObservedObject private var notes = VoiceNoteStore.shared
    let playerOpen: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { notes.isRecording && !playerOpen }, set: { _ in })) {
            VoiceCaptureView()
        }
    }
}
#endif

#if os(iOS)
/// What every page's chrome opens that belongs to the whole app (`PageChrome`): Review from the
/// chart button, Routines and Settings from "…". Sheets where there's a tab bar; where there's a
/// sidebar they are sections in it, so the same buttons go there. Its own view, so the shell
/// doesn't redraw every tab when one opens.
/// What the tab bar can select: a section, or Body.
private enum ShellTab: Hashable {
    case section(AppSection)
    /// Workouts and Nutrition in one place, on a bar at the bottom of the screen.
    case body
}

private struct PageChromeHost: ViewModifier {
    let sidebar: Bool
    @ObservedObject private var chrome = PageChrome.shared
    @ObservedObject private var shell = ShellNavigation.shared
    @ObservedObject private var modules = ModuleStore.shared

    /// With Pi, Review is where questions are asked and answers pushed: a sheet on every device,
    /// so the iPad's tab strip stays as it is and each level has one way back.
    private static var reviewIsASheet: Bool {
        #if PI_DEVELOPMENT
        true
        #else
        false
        #endif
    }

    func body(content: Content) -> some View {
        content
            #if BANANA_AI
            .sheet(isPresented: Binding(get: { (Self.reviewIsASheet || !sidebar) && chrome.showAssistant }, set: { chrome.showAssistant = $0 }), onDismiss: {
                if let destination = chrome.assistantDestination {
                    chrome.assistantDestination = nil
                    AssistantWorkspace.open(destination)
                }
                startPicked()
            }) {
                #if PI_DEVELOPMENT
                AssistantView(showsDoneButton: true, panelAddSection: shell.state.tab, pickAdd: { kind in
                    chrome.pickedAdd = kind
                    chrome.showAssistant = false
                })
                #else
                AssistantView(showsDoneButton: true)
                #endif
            }
            #endif
            .sheet(item: Binding(get: { (sidebar && !Self.reviewIsASheet) || !AppSection.review.isShown(with: modules.effectiveChoice) ? nil : chrome.review }, set: { chrome.review = $0 })) { from in
                // Its own toast host, as Routines below: clearing the listening history offers Undo.
                ReviewView(from: from, showsDoneButton: true).toastHost()
            }
            .sheet(isPresented: Binding(get: { !sidebar && chrome.showSettings }, set: { chrome.showSettings = $0 })) {
                // Its own toast host: deleting a booking type offers Undo.
                SettingsView(showsDoneButton: true).toastHost()
            }
            // Its own toast host: a sheet covers the page's, and "Started …" has to be seen.
            .sheet(isPresented: Binding(get: { !sidebar && chrome.showRoutines }, set: { chrome.showRoutines = $0 })) {
                RoutinesView(showsDoneButton: true).toastHost()
            }
            #if PI_DEVELOPMENT
            .onChange(of: chrome.showAdd) { _, requested in
                guard requested else { return }
                chrome.showAdd = false
                chrome.showAssistant = true
            }
            #else
            .sheet(isPresented: $chrome.showAdd, onDismiss: startPicked) {
                AddList(current: shell.state.tab.tabBarHome) { kind in
                    chrome.pickedAdd = kind
                    chrome.showAdd = false
                }
            }
            #endif
            .onChange(of: chrome.review) { _, from in
                guard sidebar, !Self.reviewIsASheet, let from else { return }
                chrome.reviewFrom = from
                chrome.review = nil
                shell.state.tab = .review
            }
            .onChange(of: chrome.showSettings) { _, show in
                guard sidebar, show else { return }
                chrome.showSettings = false
                shell.state.tab = .settings
            }
            .onChange(of: chrome.showRoutines) { _, show in
                guard sidebar, show else { return }
                chrome.showRoutines = false
                shell.state.tab = .routines
            }
            .onChange(of: chrome.showAssistant) { _, show in
                guard show, sidebar, !Self.reviewIsASheet else { return }
                chrome.showAssistant = false
                shell.state.tab = .assistant
            }
    }

    /// The list is gone: go to the page that owns what was picked, and hand it over.
    private func startPicked() {
        guard let kind = chrome.pickedAdd else { return }
        chrome.pickedAdd = nil
        if let half = kind.nutritionSection { shell.state.nutritionSection = half }
        shell.state.tab = kind.section
        chrome.pendingAdd = kind
        // Never left waiting for a page that has no answer, to fire on some later visit.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if chrome.pendingAdd == kind { chrome.pendingAdd = nil }
        }
    }
}

/// Workouts, laid out for the column it has: the phone's list — latest workout, trends, the
/// period's sessions — when narrow; the wide arrangement the Mac uses, with its columns and
/// detail, when there's room. Trends and Sleep have their own sidebar rows then.
#if BANANA_MODULE_WORKOUTS
private struct WorkoutsSection: View {
    @Binding var path: [ShellState.WorkoutsRoute]
    @Environment(\.layoutClass) private var layout

    var body: some View {
        Group {
            switch layout {
            case .compact: NavigationStack(path: $path) { FitnessView() }
            case .regular: WideWorkoutsView()
            }
        }
        .onAppear { SpaceSyncQuestions.shared.healthUsed() }
    }
}

#endif

#if BANANA_MODULE_FOOD
/// Nutrition, laid out for the column it has — see `WorkoutsSection`.
private struct NutritionSection: View {
    @Environment(\.layoutClass) private var layout

    var body: some View {
        Group {
            switch layout {
            case .compact: NavigationStack { WellnessView() }
            case .regular: NavigationStack { WideNutritionView() }
            }
        }
        .onAppear { SpaceSyncQuestions.shared.healthUsed() }
    }
}
#endif
#endif

#if DEBUG && os(iOS)
/// `--event-editor`: the editor as it's really shown — a sheet over the app, with the toast host
/// below it — so closing it and the Undo toast that follows can be checked too.
private struct EventEditorPreviewHost: View {
    let event: GoogleCalendarEvent
    @State private var showing = true

    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .overlay { Text("Day").accessibilityIdentifier("eventEditorPreview.behind") }
            .toastHost()
            .sheet(isPresented: $showing) {
                GoogleCalendarEventView(
                    meeting: MeetingInfo(start: event.start, end: event.end, coordinate: nil, address: nil,
                                         isVirtual: false, title: event.title, eventID: event.id),
                    preloaded: event)
            }
    }
}
#endif

#if DEBUG && os(iOS)
/// `--new-calendar-event` / `--new-task`: the plan's Day with the new-event or new-reminder
/// sheet open over it, as the "+" menu opens it.
private struct NewItemSheetHost: View {
    let task: Bool
    @State private var showing = true

    var body: some View {
        NavigationStack { PlannerTab() }
            .toastHost()
            .sheet(isPresented: $showing) {
                if task {
                    NewTaskSheet()
                } else {
                    // `--new-calendar-event-text "…"`: the form with words already typed.
                    NewCalendarEventSheet(initialTitle: CommandLine.arguments.firstIndex(of: "--new-calendar-event-text")
                        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "")
                }
            }
    }
}
#endif

#if DEBUG && os(iOS)
extension MeetingInfo {
    /// An invitation with a place, a call and a reply owed: `--event-detail`, `--open-event`.
    static var detailPreview: MeetingInfo {
        let start = Date().addingTimeInterval(3_600)
        var meeting = MeetingInfo(start: start, end: start.addingTimeInterval(45 * 60), coordinate: nil,
                                  address: "Chelsea Piers Fitness, 62 Chelsea Piers, New York, NY 10011",
                                  isVirtual: false, title: "Design review with Sam",
                                  joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), platform: .meet)
        meeting.myResponse = .needsAction
        return meeting
    }
}

#if DEBUG

/// `--launch-timing <file>` (Debug): when the first frame came, in milliseconds from the
/// process's start, and what came after it, one `name value` line each, for launch comparisons.
enum LaunchTiming {
    static var file: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--launch-timing"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static func processStart() -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// From the root's first appearance, on the next turn of the run loop: the frame is drawn.
    static func firstFrame() {
        guard file != nil, let start = processStart() else { return }
        DispatchQueue.main.async { note("first_frame_ms", Date().timeIntervalSince(start) * 1000) }
    }

    static func note(_ name: String, _ value: Double) {
        guard let file else { return }
        let line = "\(name) \(Int(value.rounded()))\n"
        if let handle = FileHandle(forWritingAtPath: file) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }
}
#endif

#endif

#if os(iOS)
private extension View {
    /// Each tab's content behind one type: twelve tabs of chained modifiers made the TabView's
    /// generic type deep enough that building it overflowed the main thread's stack (8 Nov 2026,
    /// a Debug crash in `TabView.init` once the plan toolbar and problem reports were merged).
    /// A tab's content type never changes, so this costs no identity or diffing.
    func erasedTab() -> AnyView { AnyView(self) }
}
#endif
