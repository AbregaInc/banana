import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One findable setting: what it's called, the page it lives on, and the words people reach for
/// when hunting it. Update alongside new settings.
private struct SettingsSearchEntry: Identifiable {
    let title: String
    let page: SettingsView.SettingsPage
    let keywords: [String]
    var id: String { title }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        return ([title, page.title] + keywords).contains { $0.lowercased().contains(q) }
    }
}

struct SettingsView: View {
    fileprivate static let searchIndex: [SettingsSearchEntry] = [
        .init(title: "Modules", page: .modules, keywords: ["modules", "features", "tabs", "hide", "show", "turn off", "food", "workouts", "podcasts", "notes"]),
        .init(title: "Record where I listen", page: .podcasts, keywords: ["location", "gps", "route", "privacy"]),
        .init(title: "Skip ads automatically", page: .podcasts, keywords: ["ads", "advert", "sponsor", "promo", "intro", "skip"]),
        .init(title: "Transcript engine", page: .podcasts, keywords: ["transcription", "parakeet", "speech", "on-device"]),
        .init(title: "Auto-sleep at night", page: .podcasts, keywords: ["bedtime", "fade", "sleep timer"]),
        .init(title: "Units", page: .workouts, keywords: ["metric", "imperial", "miles", "kilometers", "distance"]),
        .init(title: "Pool length", page: .workouts, keywords: ["swim", "yards", "meters", "laps", "pool"]),
        .init(title: "Workout cleanup", page: .workouts, keywords: ["duplicates", "duplicate", "health", "swim", "25 yards"]),
        .init(title: "Apple Health", page: .workouts, keywords: ["workouts", "fitness", "import", "health"]),
        .init(title: "Find meal photos automatically", page: .food, keywords: ["photos", "meals", "library", "nutrition", "food"]),
        .init(title: "Fitness sync", page: .workouts, keywords: ["workouts", "fitness", "icloud", "sync", "mac", "iphone", "raw recording", "waiting", "uploading"]),
        .init(title: "Booking link", page: .booking, keywords: ["booking", "book", "link", "calendly", "schedule", "handle", "share"]),
        .init(title: "Booking types", page: .booking, keywords: ["meeting", "length", "hours", "zoom", "meet", "phone", "in person", "notice", "buffer"]),
        .init(title: "Directions app", page: .calendar, keywords: ["maps", "google maps", "apple maps", "navigation"]),
        .init(title: "Event reminders", page: .calendar, keywords: ["notifications", "alerts", "starting soon"]),
        .init(title: "Google Calendar", page: .accounts, keywords: ["connect", "oauth", "gmail", "account", "sign in", "reconnect"]),
        .init(title: "Calendar visibility", page: .accounts, keywords: ["toggle", "enable", "disable", "exclude", "shared", "wife", "husband", "notifications", "mute", "notify"]),
        .init(title: "Banana account", page: .accounts, keywords: ["account", "delete account", "instant updates", "push", "sync"]),
        .init(title: "Calendar diagnostics", page: .accounts, keywords: ["accounts", "google", "excluded", "permission", "troubleshoot", "calendars"]),
        .init(title: "Task details calendar", page: .calendar, keywords: ["task titles", "private", "write-back"]),
        .init(title: "Busy blocks", page: .calendar, keywords: ["busy", "write-back", "blocks", "availability", "free"]),
        .init(title: "Calendars receiving busy blocks", page: .calendar, keywords: ["shared calendar", "family", "spam", "exclude", "busy blocks"]),
        .init(title: "Reserve time for tasks", page: .calendar, keywords: ["reminders", "tasks", "blockers", "reserve", "busy"]),
        .init(title: "Week starts on", page: .calendar, keywords: ["week start", "monday", "sunday", "saturday", "first day"]),
        .init(title: "Show morning briefing on Mac", page: .calendar, keywords: ["morning briefing", "mac", "wake", "recap"]),
        .init(title: "Plan my wake and bedtime", page: .wake, keywords: ["wake", "alarm", "bedtime", "sleep", "morning", "smart schedule"]),
        .init(title: "Block travel time", page: .travel, keywords: ["travel", "commute", "busy", "calendar"]),
        .init(title: "Usually by", page: .travel, keywords: ["transit", "drive", "walk", "mode", "subway", "car"]),
        .init(title: "Learn from my trips", page: .travel, keywords: ["learn", "visits", "motion", "real times", "pace"]),
        .init(title: "Walk short trips", page: .travel, keywords: ["walk", "walking", "distance", "nearby"]),
        .init(title: "Places", page: .travel, keywords: ["gym", "place", "where", "location", "address", "chelsea"]),
        .init(title: "Home", page: .travel, keywords: ["home", "address", "location", "commute"]),
        .init(title: "Watch audio quality", page: .watch, keywords: ["watch", "bitrate", "sync", "quality", "re-sync"]),
        .init(title: "iCloud backup & restore", page: .icloud, keywords: ["backup", "restore", "snapshot", "icloud"]),
        .init(title: "Permissions", page: .permissions, keywords: ["location", "notifications", "reminders", "health", "music", "alarms", "allow"]),
        .init(title: "Versions", page: .about, keywords: ["version", "build", "watch build"]),
        .init(title: "Playback log", page: .about, keywords: ["diagnostics", "debug", "stall", "log"]),
        .init(title: "Credits", page: .about, keywords: ["licenses", "licences", "attribution", "open source"]),
    ]
    var showsDoneButton = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var backup = CloudBackup.shared
    @StateObject private var fitnessCloud = CloudFitnessSync.shared
    @EnvironmentObject var settings: AppSettings

    private static func eventReminderFooter(leads: [Int]) -> String? {
        leads.isEmpty ? nil : "Your calendar app may alert you too."
    }

    private static func eventLeadLabel(_ lead: Int) -> String {
        lead == 0 ? "At the start" : "\(lead) minutes before"
    }

    /// Turning the last one off is how event reminders get switched off entirely.
    private func eventLeadBinding(_ lead: Int) -> Binding<Bool> {
        Binding(
            get: { settings.eventAlertLeads.contains(lead) },
            set: { on in
                var leads = Set(settings.eventAlertLeads)
                let wasEmpty = leads.isEmpty
                if on { leads.insert(lead) } else { leads.remove(lead) }
                settings.eventAlertLeads = leads.sorted(by: >)
                // Ask at the moment they are switched on, not at launch. Until now the only thing
                // requesting notification permission was the smart schedule, so with that off —
                // its default on the Mac — these would have been scheduled into a queue nothing
                // was allowed to show.
                if wasEmpty, !leads.isEmpty {
                    Task { _ = await NotificationService.requestAuthorization() }
                }
            }
        )
    }
    @EnvironmentObject private var smart: SmartScheduleStore
    // Action-only (the re-sync button) — observing the download manager re-rendered this whole
    // Form on every download percent tick while Settings was open.
    private var downloads: DownloadManager { WakeCoordinator.shared.downloads }
    private var occurrences: OccurrenceStore { .shared }
    @EnvironmentObject var health: HealthKitStore
    @EnvironmentObject var connectivity: PhoneConnectivity
    @EnvironmentObject private var onboarding: OnboardingStore
    @EnvironmentObject private var music: MusicController
    #if os(iOS)
    @EnvironmentObject private var alarms: AlarmStore
    #endif
    @ObservedObject private var calendarWriteBack = CalendarWriteBack.shared
    /// What the phone reports about the jobs only it does, shown under their controls here.
    @ObservedObject private var hubStatus = HubStatusStore.shared
    @StateObject private var googleCalendar = GoogleCalendarService.shared
    @ObservedObject private var bananaAccount = BananaAccount.shared
    @ObservedObject private var spaceQuestions = SpaceSyncQuestions.shared
    /// The move off iCloud on this device, while it's under way (`MoveOver.progress`).
    @ObservedObject private var moveProgress = MoveOver.progress
    @ObservedObject private var modules = ModuleStore.shared
    @ObservedObject private var booking = BookingCenter.shared
    @State private var confirmingAccountDelete = false
    @AppStorage(LocalTranscriptionEngine.defaultsKey)
    private var transcriptionEngine: LocalTranscriptionEngine = .apple
    /// Per device, like the engine above (`SpeakerLabelling`).
    @State private var labelsSpeakers = SpeakerLabelling.enabled
    @State private var showingHomePicker = false
    @State private var settingsSearch = ""

    @State private var purgedCount = 0
    @State private var showPurgeResult = false
    @State private var confirmPurge = false
    @State private var confirmDisableWriteBack = false
    @State private var confirmDisconnectAll = false
    @State private var accountPendingDisconnect: String?
    @State private var betaTestAccounts = BetaTestAccounts.all
    /// Permissions whose Connect came back without a yes: their button becomes Open Settings.
    @State private var askedWithoutAnswer: Set<String> = []
    @Environment(\.openURL) private var openURL
    @AppStorage(Telemetry.shareUsageKey) private var sharesUsage = false
    #if os(macOS)
    @AppStorage(MenuBarAgendaSetting.key) private var showsMenuBarAgenda = true
    @AppStorage(TripTimeZone.enabledKey) private var showsTripTimeZone = true
    @AppStorage(TripTimeZone.homeKey) private var homeTimeZoneID = ""
    #endif

    /// The room this screen has (docs/design/ADAPTIVE-LAYOUT.md): pages beside their list where
    /// there's room for both, pushed where there isn't. A sheet on the phone is always the latter.
    @Environment(\.layoutClass) private var layoutClass

    /// Whether the pages sit beside their list (the Mac always; an iPad with the room).
    private var usesTwoPanes: Bool {
        #if os(macOS)
        true
        #else
        layoutClass == .regular && !showsDoneButton
        #endif
    }

    var body: some View {
        let _ = RenderStats.note("SettingsView")
        #if os(macOS)
        macBody
        #else
        if usesTwoPanes {
            padBody
        } else {
            phoneBody
        }
        #endif
    }

    /// The page shown on the right of the two-pane arrangement; the narrow one pushes pages.
    @State private var macPage: SettingsPage? = .accounts

    /// The pages, account first: the list both two-pane arrangements choose from.
    @ViewBuilder private var pageRows: some View {
        Section {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(accountTitle).lineLimit(1)
                    HStack(spacing: DS.Space.xs) {
                        StatusDot(status: accountStatus.status)
                        Text(accountStatus.word).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, DS.Space.xs)
            .tag(SettingsPage.accounts)
        }
        Section("Features") {
            ForEach([SettingsPage.modules, .calendar, .booking, .travel, .wake, .podcasts, .workouts, .food].filter(isShown), id: \.self) { sidebarRow($0) }
        }
        Section("General") {
            // Apple Watch too, as on the phone: here it holds the audio quality the
            // phone syncs at. It was reachable only through the search field.
            ForEach([SettingsPage.watch, .icloud, .permissions].filter { $0 != .icloud || !backup.retired },
                    id: \.self) { sidebarRow($0) }
        }
        Section { sidebarRow(.about) }
    }

    /// The chosen page, or what the search found, with its own navigation so links inside a
    /// page still push.
    private var pagePane: some View {
        NavigationStack {
            if !settingsSearch.isEmpty {
                Form { searchResults }.settingsFormStyle()
            } else if let macPage {
                // No title over the page: in the detail column it narrowed the tab bar above
                // until Library fell behind its overflow arrow. The selected row names it.
                page(macPage).toolbar(removing: .title)
            }
        }
        .id(settingsSearch.isEmpty ? macPage?.rawValue ?? "" : "search")
    }

    #if os(iOS)
    /// The iPad's two panes: the system's own split view, as the Settings app is built. It was
    /// the Mac's hand-made row of a 240 pt list and a page, which on an iPad came out as a
    /// squeezed strip with the search field wedged under the status bar. The split view gives
    /// the list its width, its title and its search field, and keeps clear of the tab bar.
    private var padBody: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $macPage) { pageRows }
                .listStyle(.insetGrouped)
                .navigationTitle("Settings")
                .searchable(text: $settingsSearch, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search settings")
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
                // Always beside its page: there is nothing to see with the list hidden.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            pagePane
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: modules.choice) { leaveHiddenPage() }
        .task { refreshWriteBack() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshWriteBack() }
        }
        .sheet(isPresented: $showingHomePicker) {
            HomeLocationPicker()
        }
    }
    #endif

    #if os(macOS)
    /// The Mac's Settings window (the `Settings` scene): each page a tab, its symbol and name in
    /// the window's toolbar, the way Apple's own apps do it. It was a page of the main window,
    /// with a list of pages beside the app's own sidebar: three columns.
    private var macBody: some View {
        TabView(selection: Binding(get: { macPage ?? .accounts }, set: { macPage = $0 })) {
            ForEach(SettingsPage.allCases.filter(isShown), id: \.self) { page in
                // Booking's page makes the default type when it opens: built only while its tab
                // is the one chosen, so the window's other tabs never open it.
                NavigationStack {
                    if page != .booking || macPage == .booking { self.page(page) }
                }
                    .tabItem { Label(page.title, systemImage: page.symbol) }
                    .tag(page)
            }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 520, idealHeight: 620)
        .onChange(of: modules.choice) { leaveHiddenPage() }
        .task { refreshWriteBack() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshWriteBack() }
        }
        .sheet(isPresented: $showingHomePicker) {
            HomeLocationPicker()
        }
    }
    #endif

    /// A page that belongs to a module switched off is hidden with it.
    private func isShown(_ page: SettingsPage) -> Bool {
        // The backup's page goes once the service is the copy (`CloudBackup.isRetired`).
        if page == .icloud, backup.retired { return false }
        return page.module.map(modules.includes) ?? true
    }

    /// The page beside the list went with its module: show Accounts instead.
    private func leaveHiddenPage() {
        if let macPage, !isShown(macPage) { self.macPage = .accounts }
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        HStack(spacing: DS.Space.s) {
            IconTile(systemImage: page.symbol, tint: page.tint, size: 22)
            Text(page.title)
        }
        .tag(page)
        .accessibilityIdentifier("settings.page.\(page.rawValue)")
    }

    #if os(iOS)
    private var phoneBody: some View {
        NavigationStack {
            Form {
                // Search replaces the list with a locator: each hit names the setting and the page
                // it lives on, and opens that page.
                if !settingsSearch.isEmpty {
                    searchResults
                } else {
                    accountSection
                    featuresSection
                    generalSection
                    aboutSection
                }
            }
            .searchable(text: $settingsSearch, prompt: "Search settings")
            .settingsFormStyle()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task {
                refreshWriteBack()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshWriteBack() }
            }
            .sheet(isPresented: $showingHomePicker) {
                HomeLocationPicker()
            }
        }
    }
    #endif

    // MARK: - Structure
    //
    // Account first, then one row per feature showing its current value, then the device-wide
    // things, then About — the order people look in. Each row opens a page built from the
    // sections below, so a setting has one home and search can take you straight to it.

    enum SettingsPage: String, Hashable, CaseIterable {
        case accounts, modules, calendar, booking, travel, wake, podcasts, workouts, food, watch, icloud, permissions, about

        /// The module a page belongs to, if any.
        var module: AppModule? {
            switch self {
            case .podcasts: .podcasts
            case .workouts: .workouts
            case .food: .food
            default: nil
            }
        }

        var title: String {
            switch self {
            case .accounts: "Accounts & calendars"
            case .modules: "Modules"
            case .calendar: "Calendar"
            case .booking: "Booking"
            case .travel: "Travel"
            case .wake: "Wake & bedtime"
            case .podcasts: "Podcasts"
            case .workouts: "Workouts"
            case .food: "Food"
            case .watch: "Apple Watch"
            case .icloud: "iCloud"
            case .permissions: "Permissions"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .accounts: "person.crop.circle"
            case .modules: "square.grid.2x2.fill"
            case .calendar: "calendar"
            case .booking: "link"
            case .travel: "car.fill"
            case .wake: "alarm.fill"
            case .podcasts: "headphones"
            case .workouts: "figure.run"
            case .food: "fork.knife"
            case .watch: "applewatch"
            case .icloud: "icloud.fill"
            case .permissions: "hand.raised.fill"
            case .about: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .calendar: DS.Palette.Feature.calendar
            case .booking: DS.Palette.Feature.booking
            case .travel: DS.Palette.Feature.travel
            case .wake: DS.Palette.Feature.wake
            case .podcasts: DS.Palette.Feature.podcasts
            case .workouts: DS.Palette.Feature.workouts
            case .food: DS.Palette.Feature.food
            case .icloud: DS.Palette.Feature.icloud
            case .accounts, .modules, .watch, .permissions, .about: DS.Palette.Feature.system
            }
        }
    }

    /// Type-erased on purpose. Built as one `switch` of concrete types, every page's sections
    /// were one enormous nested view type — repeated inside each row that links to a page — and
    /// an optimized build evaluated it in a stack frame bigger than an iPhone or iPad main thread
    /// has: Settings crashed on open (stack overflow). Each page now carries only its own sections.
    private func page(_ page: SettingsPage) -> AnyView {
        if page == .wake {
            // Its own screen, with its own list and sheets.
            return AnyView(SmartScheduleView().navigationTitle(page.title))
        }
        if page == .booking {
            // Its own screen: the link, and the types with their editor.
            return AnyView(BookingSettingsView())
        }
        return AnyView(pageForm(page))
    }

    private func pageForm(_ page: SettingsPage) -> some View {
        Form { pageSections(page) }
            .settingsFormStyle()
            .navigationTitle(page.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    private func pageSections(_ page: SettingsPage) -> AnyView {
        switch page {
        case .accounts:
            AnyView(Group {
                googleCalendarSection
                bananaAccountSection
                calendarCoverageSection
            })
        case .calendar:
            AnyView(Group {
                availabilitySection
                eventRemindersSection
                plannerSection
                meetingsSection
                macMenuBarSection
                tripTimeZoneSection
            })
        case .modules:
            AnyView(modulesSection)
        case .travel:
            AnyView(travelSection)
        case .podcasts:
            AnyView(Group {
                podcastsSection
                transcriptsSection
                autoSleepSection
            })
        case .workouts:
            AnyView(Group {
                fitnessUnitsSection
                appleHealthSection
                fitnessSyncSection
            })
        case .food:
            AnyView(Group {
                MealPhotoScanSettingsSection()
                // Said once, here, rather than under every list of what you take.
                Section {} footer: {
                    Text("Taken recommends no supplement or dose.")
                }
            })
        case .watch:
            AnyView(watchSection)
        case .icloud:
            AnyView(Group {
                icloudSection
                SyncStatusSection()
            })
        case .permissions:
            AnyView(permissionsSection)
        case .about:
            AnyView(Group {
                Section { DemoEntryButton() }
                versionsSection
                privacySection
                diagnosticsSection
                creditsSection
            })
        case .wake, .booking:
            AnyView(EmptyView())   // shown by `page(_:)` as its own screen
        }
    }

    private var searchResults: some View {
        var hits = Self.searchIndex.filter { $0.matches(settingsSearch) && isShown($0.page) }
        return Section(hits.isEmpty ? "No matches" : "Results") {
            if hits.isEmpty {
                Text("No settings match \u{201C}\(settingsSearch)\u{201D}.")
                    .foregroundStyle(.secondary)
            }
            ForEach(hits) { hit in
                // Beside the list, a hit shows its page on the right; pushed, it opens it.
                if usesTwoPanes {
                    Button {
                        macPage = hit.page
                        settingsSearch = ""
                    } label: { searchHitLabel(hit) }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink { page(hit.page) } label: { searchHitLabel(hit) }
                }
            }
        }
    }

    private func searchHitLabel(_ hit: SettingsSearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title)
            Text("Settings \u{203A} \(hit.page.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    /// The account, first: who Banana is signed in as and whether it's working.
    private var accountSection: some View {
        Section {
            NavigationLink { page(.accounts) } label: {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: DS.Row.avatar))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.Row.glyphTile, height: DS.Row.glyphTile)
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(accountTitle)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: DS.Space.xs + 2) {
                            StatusDot(status: accountStatus.status)
                            Text(accountStatus.word)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, DS.Space.xs)
            }
            .accessibilityIdentifier("settings.accounts")
        }
    }

    private var accountTitle: String {
        guard let first = googleCalendar.accounts.first else { return "Connect Google Calendar" }
        let others = googleCalendar.accounts.count - 1
        return others > 0 ? "\(first.email) + \(others) more" : first.email
    }

    private var accountStatus: (status: ConnectionStatus, word: String) {
        if !googleCalendar.isConnected { return (.off, "Not connected") }
        if !googleCalendar.accountsToSignInAgain.isEmpty { return (.attention, "Sign in again") }
        if googleCalendar.isWorking { return (.working, "Syncing") }
        let calendars = googleCalendar.calendars.count
        return (.ok, "Live \u{00B7} \(calendars) calendar\(calendars == 1 ? "" : "s")")
    }

    private var featuresSection: some View {
        Section("Features") {
            featureRow(.modules, value: modules.choice.isEverything ? "All on" : "\(modules.choice.enabled.count) on")
            featureRow(.calendar, value: calendarWriteBack.enabled ? "Busy blocks on" : "Busy blocks off")
            featureRow(.booking, value: bookingSummary)
            featureRow(.travel, value: travelSummary)
            featureRow(.wake, value: smart.settings.enabled ? "On" : "Off")
            if isShown(.podcasts) {
                featureRow(.podcasts, value: settings.automaticAdSkip ? "Ad skip on" : "Ad skip off")
            }
            if isShown(.workouts) {
                featureRow(.workouts, value: settings.poolLength.label)
            }
            if isShown(.food) {
                featureRow(.food, value: settings.mealPhotoScanEnabled ? "Finding photos" : "Photos off")
            }
        }
    }

    /// Plan, always on, then a switch per module.
    private var modulesSection: some View {
        Section {
            HStack(spacing: DS.Space.m) {
                IconTile(systemImage: AppSection.plan.symbol, tint: DS.Palette.Brand.yellow, glyph: DS.Palette.Brand.ink)
                Text("Plan")
                Spacer(minLength: DS.Space.s)
                Text("Always on").foregroundStyle(.secondary)
            }
            ForEach(AppModule.selectable) { module in
                Toggle(isOn: Binding(get: { modules.includes(module) },
                                     set: { modules.set(module, on: $0) })) {
                    HStack(spacing: DS.Space.m) {
                        IconTile(systemImage: module.symbol, tint: module.tint)
                        Text(module.title)
                        Spacer(minLength: DS.Space.s)
                        if let status = module.statusLabel {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!module.isAvailable)
                .accessibilityIdentifier("settings.module.\(module.rawValue)")
            }
        }
    }

    private var missingPermissions: Int {
        var granted = [smart.calendarAuthorized, occurrences.remindersAuthorized,
                       onboarding.locationGranted, onboarding.notificationsGranted, music.isAuthorized]
        #if os(iOS)
        if DeviceRole.current.isHub {   // elsewhere they're the phone's, shown under "Your iPhone"
            granted.append(alarms.isAuthorized)
            granted.append(health.setupState == .done)
        }
        #endif
        return granted.filter { !$0 }.count
    }

    /// The link's name, or nothing yet.
    private var bookingSummary: String? {
        booking.handle.map { "/\($0)" }
    }

    private var travelSummary: String {
        let places = smart.settings.savedPlaces.count
        return smart.settings.transitMode.label + (places > 0 ? " \u{00B7} \(places) place\(places == 1 ? "" : "s")" : "")
    }

    private var generalSection: some View {
        Section("General") {
            featureRow(.watch, value: settings.watchAudioQuality.label)
            // The backup's job is the Banana service's once this device has moved (§6).
            if !backup.retired { featureRow(.icloud, value: backup.enabled ? "Backing up" : "Off") }
            featureRow(.permissions, value: missingPermissions == 0 ? "All allowed" : "\(missingPermissions) off")
        }
    }

    private var aboutSection: some View {
        Section {
            featureRow(.about, value: Self.bundleVersion)
        }
    }

    private func featureRow(_ page: SettingsPage, value: String?) -> some View {
        NavigationLink { self.page(page) } label: {
            settingsRow(page.title, symbol: page.symbol, tint: page.tint, value: value)
        }
    }

    /// Icon tile · title · the setting's current value (DESIGN-SYSTEM.md, "Rows").
    private func settingsRow(_ title: String, symbol: String, tint: Color, value: String?) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: symbol, tint: tint)
            Text(title)
            Spacer(minLength: DS.Space.s)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// One synced setting, the same toggle on every device (docs/design/ADAPTIVE-LAYOUT.md, rule
    /// 5). Learning itself is the phone's — it has the visits and the motion sensor — so the phone
    /// acts on the setting, and says under the toggle, everywhere, how it's going.
    @ViewBuilder private var learnFromTripsRow: some View {
        let wanted = smart.settings.learnFromTrips
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Toggle(isOn: Binding(
                get: { wanted },
                set: { on in
                    smart.settings.learnFromTrips = on
                    #if os(iOS)
                    // Here on the phone, ask iOS for "Always" location right away.
                    if DeviceRole.current.isHub { Task { await TripLearningService.shared.apply(prompting: true) } }
                    #endif
                }
            )) {
                Text("Learn from my trips")
            }
            if let caption = hubStatus.status.tripLearning.caption(wanted: wanted, onHub: DeviceRole.current.isHub) {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var learnedSummary: String {
        let learned = smart.settings.learnedTravel
        var parts = ["Learned from \(learned.tripsLearned) trip\(learned.tripsLearned == 1 ? "" : "s")"]
        for mode in TransitMode.allCases {
            guard let factor = learned.factors[mode.rawValue],
                  (learned.factorSamples[mode.rawValue] ?? 0) >= TripLearning.minimumFactorSamples else { continue }
            parts.append("\(mode.label): \(String(format: "%.2g", factor))\u{00D7} Apple Maps")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// How trips are timed. Separate from "Block travel time", which only decides whether the
    /// trips are also written to your calendars: leave-by nudges use these either way.
    private var travelSection: some View {
        Section {
            Picker(selection: $smart.settings.transitMode) {
                ForEach(TransitMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            } label: {
                Text("Usually by")
            }
            Toggle(isOn: $smart.settings.walkShortTrips) {
                Text("Walk short trips")
            }
            NavigationLink {
                SavedPlacesView()
            } label: {
                HStack {
                    Text("Places")
                    Spacer()
                    Text(smart.settings.savedPlaces.isEmpty ? "None yet" : "\(smart.settings.savedPlaces.count)")
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                showingHomePicker = true
            } label: {
                HStack {
                    Text("Home")
                    Spacer()
                    Text(smart.settings.homeLabel ?? "Set\u{2026}").foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
            Toggle(isOn: $smart.settings.blockTravelTime) {
                Text("Block travel time")
            }
            .disabled(!calendarWriteBack.enabled)
            learnFromTripsRow
            if smart.settings.learnedTravel.tripsLearned > 0 {
                Text(learnedSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(calendarWriteBack.enabled
                 ? "Anything under \(PlaceDistance.text(Double(smart.settings.walkShortTripMeters))) is a walk."
                 : "Block travel time needs Busy blocks, under Calendar.")
        }
    }

    // MARK: - Sections

    @ViewBuilder private var podcastsSection: some View {
            Section {
                Toggle(isOn: $settings.recordListenLocation) {
                    Text("Record where I listen")
                }
                Toggle(isOn: $settings.automaticAdSkip) {
                    Text("Skip ads automatically")
                }
                .accessibilityIdentifier("settings.automaticAdSkip")
            } footer: {
                // Written to be true rather than impressive: the design trades recall for
                // precision, so "no more ads" is the one claim it is sure to break.
                Text("Misses some ads. Rewind into a skip to hear it.")
            }
    }
    @ViewBuilder private var eventRemindersSection: some View {
            Section {
                // Several can be on at once, so these are toggles rather than a picker: the
                // default is two notifications per event, one as it starts and one five
                // minutes ahead.
                ForEach(EventAlertPlan.offeredLeads, id: \.self) { lead in
                    Toggle(Self.eventLeadLabel(lead), isOn: eventLeadBinding(lead))
                        .accessibilityIdentifier("settings.eventAlert.\(lead)")
                }
            } header: {
                Text("Event reminders")
            } footer: {
                // The obvious worry is being told twice about the same meeting.
                if let footer = Self.eventReminderFooter(leads: settings.eventAlertLeads) { Text(footer) }
            }
    }
    @ViewBuilder private var transcriptsSection: some View {
            Section {
                Picker("Local fallback", selection: $transcriptionEngine) {
                    ForEach(LocalTranscriptionEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .onChange(of: transcriptionEngine) { _, engine in
                    LocalTranscriptionEngine.selected = engine
                    TranscriptCoordinator.shared.scheduleOvernight()
                }
                if transcriptionEngine == .parakeet {
                    Text("Downloads 565 MB on first use")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if SpeakerLabelling.available {
                    Toggle("Label who\u{2019}s speaking", isOn: $labelsSpeakers)
                        .onChange(of: labelsSpeakers) { _, on in SpeakerLabelling.enabled = on }
                        .accessibilityIdentifier("settings.speakerLabels")
                    if labelsSpeakers {
                        Text("Downloads 21 MB on first use")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Podcast transcripts")
            } footer: {
                Text("Used when a show has no transcript. Set per device.")
            }
    }
    @ViewBuilder private var autoSleepSection: some View {
            Section {
                Picker("Fade-out after", selection: $settings.sleepTimerMinutes) {
                    ForEach(AppSettings.sleepDurationOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle(isOn: $settings.autoSleepTimer) {
                    Text("Auto-start at bedtime")
                }
                if settings.autoSleepTimer {
                    Picker("Bedtime after", selection: $settings.autoSleepAfterHour) {
                        ForEach([20, 21, 22, 23], id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                }
            } header: {
                Text("Auto-sleep at night")
            }
    }
    @ViewBuilder private var fitnessUnitsSection: some View {
            Section {
                Picker("Distance", selection: $settings.distanceUnit) {
                    ForEach(DistanceUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Pool length", selection: $settings.poolLength) {
                    ForEach(PoolLength.allCases) { length in
                        Text(length.label).tag(length)
                    }
                }
            } footer: {
                // Set here, not on the Watch: poolside, with water lock about to engage, is the
                // wrong moment to be asked. The Watch receives it and a swim starts with one hold.
                Text("Your Apple Watch uses these.")
            }
    }
    @ViewBuilder private var meetingsSection: some View {
            Section {
                Picker("Directions app", selection: $settings.mapsProvider) {
                    Text("Ask the first time").tag(MapsProvider?.none)
                    Text("Apple Maps").tag(MapsProvider?.some(.apple))
                    Text("Google Maps").tag(MapsProvider?.some(.google))
                }
            } header: {
                Text("Meetings")
            }
    }
    @ViewBuilder private var googleCalendarSection: some View {
            Section {
                if googleCalendar.isConnected {
                    // One row per connected account. Swipe to remove just that one — the old
                    // single "Disconnect" signed you out of everything, which was the only
                    // option when only one account could be connected at a time.
                    ForEach(googleCalendar.accounts) { account in
                        let owned = googleCalendar.calendars.filter {
                            $0.accountEmail.lowercased() == account.id
                        }
                        // Rejected by Google, or the Banana service has no access of its own for it
                        // yet (it needs one sign-in with a code to read events and send alerts).
                        let needsReconnect = googleCalendar.accountsToSignInAgain.contains(account.id)
                        // An account card: who, whether it's working (a dot and a word), and
                        // the actions in one quiet menu. A signed-out account stays listed rather
                        // than vanishing — silently dropping it is how a calendar stops being
                        // covered with nothing on screen to explain why.
                        let broken = needsReconnect || owned.isEmpty
                        HStack(spacing: DS.Space.m) {
                            ZStack {
                                Circle().fill(Color.primary.opacity(DS.Tint.soft))
                                Text(String(account.email.prefix(1)).uppercased())
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(width: DS.Row.avatar, height: DS.Row.avatar)
                            VStack(alignment: .leading, spacing: DS.Space.hair) {
                                Text(account.email).lineLimit(1)
                                HStack(spacing: DS.Space.xs + 2) {
                                    StatusDot(status: broken ? .attention : .ok)
                                    Text(broken
                                         ? (owned.isEmpty && !needsReconnect ? "No calendars \u{2014} sign in again" : "Sign in again")
                                         : "Live \u{00B7} \(owned.count) calendar\(owned.count == 1 ? "" : "s")"
                                            + (AppVariant.current == .beta
                                               ? (betaTestAccounts.contains(account.id) ? " \u{00B7} Test account" : " \u{00B7} Read only")
                                               : ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: DS.Space.s)
                            if broken {
                                Button("Sign in") { reconnect(account.email) }
                                    .buttonStyle(.secondary)
                            }
                            Menu {
                                // Available on every account, not just broken ones: a credential
                                // can start failing between syncs.
                                Button { reconnect(account.email) } label: {
                                    Label("Reconnect", systemImage: "arrow.clockwise")
                                }
                                // Beta only: until an account is marked, Beta reads it and changes nothing.
                                if AppVariant.current == .beta {
                                    Toggle("Test account", isOn: Binding(
                                        get: { betaTestAccounts.contains(account.id) },
                                        set: {
                                            BetaTestAccounts.set(account.id, isTest: $0)
                                            betaTestAccounts = BetaTestAccounts.all
                                        }))
                                    .accessibilityIdentifier("settings.google.testAccount")
                                }
                                Button(role: .destructive) { accountPendingDisconnect = account.email } label: {
                                    Label("Disconnect", systemImage: "person.crop.circle.badge.minus")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .iconButton()
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Actions for \(account.email)")
                        }
                        .padding(.vertical, DS.Space.xs)
                        .swipeActions {
                            Button("Reconnect") { reconnect(account.email) }
                                .tint(DS.Palette.accent)
                            Button("Disconnect", role: .destructive) {
                                accountPendingDisconnect = account.email
                            }
                        }
                        if needsReconnect, let reason = googleCalendar.reconnectReasons[account.id] {
                            // Google's own words: "expired or revoked" on a consumer account is
                            // usually an OAuth app still in Testing (7-day tokens); a Workspace
                            // domain's session-control policy reads differently.
                            Text("Google said: \(reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !googleCalendar.accountsNeedingReconnect.isEmpty {
                        Text("Banana can't read one of these accounts, so it is leaving your busy blocks alone rather than removing coverage it can't verify. Reconnect to resume.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            await googleCalendar.connect()
                            await smart.refreshCalendarAuthorization()
                            await occurrences.recompute()
                        }
                    } label: {
                        Text("Add another Google account")
                    }
                    .accessibilityIdentifier("settings.addGoogleAccount")
                    Button {
                        Task {
                            await googleCalendar.refresh()
                            await smart.refreshCalendarAuthorization()
                            await occurrences.recompute()
                        }
                    } label: {
                        Text("Refresh Google calendars")
                    }
                    .confirmationDialog(
                        "Disconnect \(accountPendingDisconnect ?? "this account")?",
                        isPresented: Binding(
                            get: { accountPendingDisconnect != nil },
                            set: { if !$0 { accountPendingDisconnect = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("Disconnect, on every device", role: .destructive) {
                            guard let email = accountPendingDisconnect else { return }
                            Task {
                                await googleCalendar.disconnect(email: email)
                                await smart.refreshCalendarAuthorization()
                                await occurrences.recompute()
                            }
                        }
                    } message: {
                        Text("Accounts are shared across your devices, so this removes it from your iPhone and Mac too. Its calendars stop counting toward your availability until you sign in again.")
                    }
                    Button(role: .destructive) {
                        confirmDisconnectAll = true
                    } label: {
                        Text("Disconnect all Google accounts")
                    }
                    // Connected accounts sync through iCloud Keychain, so disconnecting here
                    // disconnects every device at once — and nothing in Banana can bring an
                    // account back except signing in again. One stray tap must not do that.
                    .confirmationDialog(
                        "Disconnect every Google account?",
                        isPresented: $confirmDisconnectAll,
                        titleVisibility: .visible
                    ) {
                        Button("Disconnect all, on every device", role: .destructive) {
                            Task {
                                await googleCalendar.disconnect()
                                await smart.refreshCalendarAuthorization()
                                await occurrences.recompute()
                            }
                        }
                    } message: {
                        Text("Your accounts are shared across your devices, so this signs Banana out of Google on your iPhone and Mac too. Banana stops reading your calendars and stops protecting your availability until you sign in again.")
                    }
                } else {
                    if let email = googleCalendar.suggestedAccountEmail {
                        HStack {
                            Text("Used on another device")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(email)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Button {
                        Task {
                            await googleCalendar.connect()
                            await smart.refreshCalendarAuthorization()
                            await occurrences.recompute()
                        }
                    } label: {
                        if let email = googleCalendar.suggestedAccountEmail {
                            Text("Continue as \(email)")
                        } else {
                            Text("Connect Google Calendar")
                        }
                    }
                }

                if googleCalendar.isWorking {
                    HStack {
                        ProgressView()
                        Text("Contacting Google…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = googleCalendar.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                }
            } header: {
                // Not over a lone "Connect Google Calendar", which already names it.
                if googleCalendar.isConnected { Text("Google Calendar") }
            }
    }
    @ViewBuilder private var calendarCoverageSection: some View {
            Section {
                NavigationLink {
                    IndividualCalendarsView()
                } label: {
                    Text("Calendar visibility")
                }
                .accessibilityIdentifier("settings.individualCalendars")
                NavigationLink {
                    AllDayCalendarsView()
                } label: {
                    Text("All-day events")
                }
                .accessibilityIdentifier("settings.allDayEvents")
                NavigationLink {
                    CalendarColorsView()
                } label: {
                    Text("Calendar colours")
                }
                .accessibilityIdentifier("settings.calendarColors")
                NavigationLink {
                    CalendarDiagnosticsView()
                } label: {
                    Text("Calendar diagnostics")
                }
            } header: {
                Text("Calendar coverage")
            }
    }
    @ViewBuilder private var macMenuBarSection: some View {
        #if os(macOS)
            Section {
                Toggle(isOn: $showsMenuBarAgenda) {
                    Text("Next meeting in the menu bar")
                }
            } footer: {
                Text("⌃⌘J joins the next meeting from any app.")
            }
        #endif
    }
    @ViewBuilder private var tripTimeZoneSection: some View {
        #if os(macOS)
            Section {
                Toggle(isOn: $showsTripTimeZone) {
                    Text("Second time zone while traveling")
                }
                LabeledContent("Home time zone") {
                    HStack(spacing: 8) {
                        Text(TimeZone(identifier: homeTimeZoneID)?.identifier ?? TripTimeZone.home.identifier)
                            .foregroundStyle(.secondary)
                        if homeTimeZoneID != TimeZone.current.identifier {
                            Button("Use \(TimeZone.current.identifier)") {
                                homeTimeZoneID = TimeZone.current.identifier
                            }
                        }
                    }
                }
            } footer: {
                Text("Shows the other zone\u{2019}s hours beside yours on a trip.")
            }
        #endif
    }
    @ViewBuilder private var plannerSection: some View {
            Section {
                Picker("Week starts on", selection: $smart.settings.weekStartWeekday) {
                    Text("Monday").tag(2)
                    Text("Saturday").tag(7)
                    Text("Sunday").tag(1)
                }
                #if os(macOS)
                Toggle("Show morning briefing on Mac", isOn: $settings.macMorningBriefing)
                #endif
            } header: {
                Text("Planner")
            }
    }
    @ViewBuilder private var appleHealthSection: some View {
            if !DeviceRole.current.isHub {
                Section {
                    LabeledContent("Status") {
                        HStack(spacing: DS.Space.xs + 2) {
                            StatusDot(status: hubStatus.status.healthConnected == true ? .ok : .off)
                            Text(phoneStatus.healthLine)
                        }
                    }
                    LabeledContent("Workouts synced", value: "\(WorkoutEntry.merge(summaries: [], health: health.workouts).count)")
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Access and Workout cleanup are on your iPhone.")
                }
            }
            #if os(iOS)
            if DeviceRole.current.isHub {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: DS.Space.xs + 2) {
                        StatusDot(status: health.hasData ? .ok : .off)
                        Text(health.hasData ? "Connected" : "No data")
                    }
                }
                if health.hasData {
                    LabeledContent("Workouts", value: "\(WorkoutEntry.merge(summaries: [], health: health.workouts).count)")
                }
                NavigationLink {
                    WorkoutCleanupView()
                } label: {
                    Text("Workout cleanup")
                }
                Button {
                    Task { await health.connect() }
                } label: {
                    Text(health.isImporting ? "Checking…" : "Check / reconnect access")
                }
                .disabled(health.isImporting)
                #if os(iOS)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open iOS Settings")
                }
                #endif
            } header: {
                Text("Apple Health")
            } footer: {
                Text("Workouts missing? Allow them in Settings › Privacy & Security › Health.")
            }
            }
            #endif
    }
    // The Watch sync is a phone↔Watch transfer; a Mac or iPad has neither the Watch nor the
    // WatchConnectivity link, so away from the phone the page is the one setting that syncs.
    @ViewBuilder private var watchSection: some View {
            if !DeviceRole.current.isHub {
                Section {
                    Picker("Audio quality", selection: $settings.watchAudioQuality) {
                        ForEach(WatchAudioQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    LabeledContent("Apple Watch", value: phoneStatus.watchLine)
                    Button {
                        HubStatusStore.shared.request(.watchResync)
                        ToastCenter.shared.notify("Your iPhone will send them to the Watch")
                    } label: {
                        Text("Send downloads to Apple Watch")
                    }
                } footer: {
                    Text("Your iPhone sends them next time it\u{2019}s open.")
                }
            }
            #if os(iOS)
            if DeviceRole.current.isHub {
            Section {
                Picker("Audio quality", selection: $settings.watchAudioQuality) {
                    ForEach(WatchAudioQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                if connectivity.episodesInFlight > 0 {
                    HStack {
                        ProgressView()
                        Text("Syncing \(connectivity.episodesInFlight) episode\(connectivity.episodesInFlight == 1 ? "" : "s") to Apple Watch…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if downloads.watchPendingCount > 0 {
                        Text("\(downloads.watchPendingCount) episode\(downloads.watchPendingCount == 1 ? "" : "s") not yet confirmed on the Watch")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        downloads.resyncWatch()
                        connectivity.refreshTransferCount()
                    } label: {
                        Text("Send downloads to Apple Watch")
                    }
                }
            } footer: {
                Text("Speech is fine at 32\u{2013}48 kbps.")
            }
            }
            #endif
    }
    @ViewBuilder private var icloudSection: some View {
            Section {
                Toggle("Back up to iCloud", isOn: $backup.enabled)
                if backup.enabled {
                    HStack {
                        // The backup is the phone's: on an iPad or the Mac, say when the phone
                        // last made it. (Each showed a status of its own, "Not backed up yet".)
                        Text(DeviceRole.current.isHub
                             ? backup.status
                             : "On your iPhone: \(ReminderToTaken.lowercasedFirst(BackupRules.restingStatus(lastBackup: hubStatus.status.lastBackup)))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if backup.busy { ProgressView() }
                    }
                    .font(.footnote)
                    Button("Back up now") {
                        if DeviceRole.current.isHub {
                            Task { await backup.backUpNow(userInitiated: true) }
                        } else {
                            // One backup file, the phone's: ask it. (A Mac's or an iPad's own
                            // snapshot would replace the phone's.)
                            HubStatusStore.shared.request(.backUpNow)
                            ToastCenter.shared.notify("Your iPhone will back up next time it's open")
                        }
                    }
                    .disabled(backup.busy)
                    Button("Restore from iCloud backup…") { Task { await backup.offerRestore() } }
                        .disabled(backup.busy)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Downloaded podcast audio isn\u{2019}t included.")
            }
    }
    @ViewBuilder private var diagnosticsSection: some View {
            Section {
                NavigationLink("Diagnostics") { PlaybackLogView() }
            } footer: {
                Text("If audio stops on its own, open this straight after.")
            }
    }
    /// Optional usage counts (`Telemetry`): off until enabled here. Only the official app has
    /// anywhere to send them, so a build without one doesn't show the switch.
    @ViewBuilder private var privacySection: some View {
        Section {
            if Telemetry.shared.canSend {
                Toggle("Share usage", isOn: $sharesUsage)
                    .onChange(of: sharesUsage) { _, on in if !on { Telemetry.shared.turnedOff(); DiagnosticReports.shared.turnedOff() } }
                    .accessibilityIdentifier("settings.shareUsage")
            }
            Link("Privacy Policy", destination: Telemetry.privacyURL)
            Link("Terms", destination: Telemetry.termsURL)
        } footer: {
            if Telemetry.shared.canSend {
                Text("Counts of what's used, never what's in it.")
            }
        }
    }

    @ViewBuilder private var creditsSection: some View {
            ForEach(Credits.groups) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        Link(entry.title, destination: entry.url)
                    }
                }
            }
    }

    // MARK: - Permissions
    //
    // One place that shows every permission and can ask for any of them.
    //
    // Before this, onboarding was the only code that requested Reminders, Location or
    // Notifications — and onboarding never runs again once completed, a flag that survives an
    // iCloud restore. Decline once, or lose a grant to a reinstall, and the feature was gone
    // with no way back: iOS doesn't even list an app under Settings › Privacy for a permission
    // whose status is still notDetermined, so there was nothing to toggle there either. The
    // failures are silent by nature — tasks simply don't appear — so nothing pointed at the cause.

    /// What each device is actually running.
    ///
    /// A Watch app arrives by three different routes — Xcode directly, TestFlight via the Watch
    /// app on iPhone, or as a companion of a phone install — and they do not stay in step. With
    /// nothing showing the pair, a stale Watch presented as a bug in whatever you tried next:
    /// missing episodes, a feature that "didn't ship", sync that looked broken. Now the mismatch
    /// names itself.
    /// PhoneConnectivity is iOS-only, so the shared version string lives here.
    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// One place to see the whole fitness-sync picture — see `CloudFitnessSync.syncState`
    /// (`FitnessSyncState`, `Shared/FitnessModels.swift`) for what each state means and why it
    /// never claims delivery to the OTHER device, only that a recording left this one. This is
    /// the one place it's shown, matching the "Cross-device sync"/"iCloud backup & restore" entries
    /// right above it rather than duplicating their content.
    private var fitnessSyncSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                fitnessSyncGlyph
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fitnessSyncTitle)
                    if let detail = fitnessSyncDetail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if fitnessCloud.pendingWorkoutCount > 0 {
                LabeledContent("Workouts waiting to sync", value: "\(fitnessCloud.pendingWorkoutCount)")
            }
            if fitnessCloud.pendingRawRecordingCount > 0 {
                LabeledContent("Raw recordings still uploading", value: "\(fitnessCloud.pendingRawRecordingCount)")
            }
        } header: {
            Text("Fitness sync")
        } footer: {
            Text("Sent to iCloud isn\u{2019}t yet on every device.")
        }
    }

    @ViewBuilder
    private var fitnessSyncGlyph: some View {
        switch fitnessCloud.syncState {
        case .syncing:
            ProgressView().controlSize(.small)
        case .unavailable:
            Image(systemName: "icloud.slash").foregroundStyle(.secondary)
        case .upToDate:
            Image(systemName: "icloud.and.arrow.up.fill").foregroundStyle(DS.Palette.success)
        case .waiting:
            Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
        }
    }

    private var fitnessSyncTitle: String {
        switch fitnessCloud.syncState {
        case .unavailable:
            return "iCloud sync unavailable"
        case .syncing:
            return "Syncing…"
        case .upToDate:
            return "Up to date"
        case .waiting(let count, _):
            return "\(count) item\(count == 1 ? "" : "s") waiting to sync"
        }
    }

    private var fitnessSyncDetail: String? {
        switch fitnessCloud.syncState {
        case .unavailable:
            // Workout sync runs on CloudKit, which needs an iCloud account with Banana enabled
            // for it. It does NOT need iCloud Drive: that governs the ubiquity container, which
            // this app reserves for the backup snapshot and note audio (see CloudProgressSync's
            // own note). Telling someone to toggle iCloud Drive here would send them to a switch
            // that cannot fix this.
            return "Banana can't reach iCloud right now. Check that you're signed in to iCloud, and that Banana is switched on under iCloud in System Settings."
        case .syncing:
            return nil
        case .upToDate(let date):
            return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        case .waiting(_, let lastSuccess):
            guard let lastSuccess else { return "Hasn't finished a first sync yet" }
            return "Last synced \(lastSuccess.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private var versionsSection: some View {
        Section {
            // Named for what it's on: an iPad said "This iPhone".
            LabeledContent("This \(DeviceRole.current.name)", value: Self.bundleVersion)
            #if os(iOS)
            // Only the phone is paired with the Watch: an iPad has nothing to report here.
            if !DeviceRole.current.isHub {
                EmptyView()
            } else if let watch = connectivity.watchVersion {
                LabeledContent("Apple Watch", value: watch)
                if watch != Self.bundleVersion {
                    // The mark warns; the words stay readable (the warning colour is a yellow).
                    Label {
                        Text("The Watch is running a different build. Reinstall it from the Watch app on iPhone so both sides match.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
                    }
                    .font(.footnote)
                }
            } else {
                LabeledContent("Apple Watch", value: "Not reported yet")
                    .foregroundStyle(.secondary)
            }
            #endif
        } header: {
            Text("Versions")
        } footer: {
            Text("The Watch reports its build when its app next opens.")
        }
    }

    /// Busy-block write-back: where blocks go, whether they are on, and the two moments it needs
    /// the person — taking over blocks written the old way, and confirming a large removal.
    @ViewBuilder private var availabilitySection: some View {
        Section {
            if !calendarWriteBack.calendarAuthorized {
                // Connecting is under Accounts, and on the Settings list itself.
                Text("Needs a Google account")
                    .foregroundStyle(.secondary)
            } else if calendarWriteBack.writableCalendars.isEmpty {
                Text("No writable calendars available")
                    .foregroundStyle(.secondary)
            } else {
                legacyAdoptionRows
                heldRemovalRows
                writeBackControls
            }

            if let error = calendarWriteBack.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.danger)
            }
        } header: {
            Text("Busy blocks")
        } footer: {
            Text("Banana never edits events it didn\u{2019}t create.")
        }
    }

    /// Blocks written through Apple Calendar before Banana wrote through Google. Their Google
    /// copies carry no ownership marker, so they are found once — by the UID Apple Calendar gave
    /// them — and tagged. Write-back waits for this so new blocks are not stacked on stale ones.
    @ViewBuilder private var legacyAdoptionRows: some View {
        switch calendarWriteBack.adoption {
        case .awaitingConfirmation(let report):
            VStack(alignment: .leading, spacing: 6) {
                Label("Take over \(report.adopted) older busy block\(report.adopted == 1 ? "" : "s")?", systemImage: "arrow.triangle.merge")
                Text("Found in Google and ready to tag as Banana’s: \(report.adopted). Nothing else about them changes. Left alone: \(report.examined - report.adopted - report.alreadyAdopted) (already gone \(report.goneFromAppleCalendar), not on a connected Google calendar \(report.notOnGoogle), not found \(report.notFoundInGoogle), failed a safety check \(report.failedChecks)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await calendarWriteBack.confirmLegacyAdoption()
                    occurrences.requestRecompute(reason: "legacy blocks adopted")
                }
            } label: {
                Label("Take them over", systemImage: "checkmark.circle")
            }
            Button("Skip — leave them as they are", role: .destructive) {
                calendarWriteBack.skipLegacyAdoption()
                occurrences.requestRecompute(reason: "legacy adoption skipped")
            }
        case .running(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("Taking over older busy blocks: \(done) of \(total). If you leave, Banana picks up where it stopped.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        ProgressView()
                        Text("Finding older busy blocks in Google…").foregroundStyle(.secondary)
                    }
                }
            }
        case .finished(let report) where report.examined > 0:
            Text("Older blocks: \(report.adopted + report.alreadyAdopted) taken over, \(report.examined - report.adopted - report.alreadyAdopted) left alone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// A large removal waits for a person. See `MassRemovalGuard`.
    @ViewBuilder private var heldRemovalRows: some View {
        if calendarWriteBack.heldRemovalCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("\(calendarWriteBack.heldRemovalCount) busy blocks waiting to be removed")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
                }
                Text("Banana would remove a large share of its blocks at once, so it is holding them until you confirm. If a calendar or account recently stopped showing meetings, fix that first — removing these would make that time bookable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Remove them", role: .destructive) {
                calendarWriteBack.approveHeldRemovals()
                occurrences.requestRecompute(reason: "held removals approved")
            }
        }
    }

    @ViewBuilder private var writeBackControls: some View {
        Picker("Task details calendar", selection: Binding(
            get: { calendarWriteBack.liveCalendarID },
            set: { id in
                calendarWriteBack.selectLiveCalendar(id)
                if calendarWriteBack.enabled {
                    occurrences.requestRecompute(reason: "write-back calendar changed")
                }
            }
        )) {
            Text("Hide task titles everywhere").tag(String?.none)
            ForEach(calendarWriteBack.writableCalendars) { calendar in
                Text(calendar.displayName).tag(String?.some(calendar.id))
            }
        }

        Toggle(isOn: Binding(
            get: { calendarWriteBack.enabled },
            set: { enabled in
                if enabled {
                    if calendarWriteBack.setEnabled(true) {
                        occurrences.requestRecompute(reason: "write-back changed")
                    }
                } else {
                    confirmDisableWriteBack = true
                }
            }
        )) {
            Text("Busy blocks")
        }
        .confirmationDialog("Turn off busy blocks?", isPresented: $confirmDisableWriteBack,
                            titleVisibility: .visible) {
            Button("Turn off and remove Banana’s blocks", role: .destructive) {
                calendarWriteBack.setEnabled(false)
            }
        } message: {
            Text("Every busy block Banana wrote is removed from your calendars, on every device’s behalf. That time becomes bookable.")
        }

        if calendarWriteBack.enabled {
            // Calendars you own are on unless excluded; someone else's calendar is opt-in, since a
            // block written to it notifies everyone it is shared with.
            DisclosureGroup {
                WriteBackCalendarPicker()
            } label: {
                Text("Calendars receiving busy blocks")
            }

            Button {
                confirmPurge = true
            } label: {
                Text("Rebuild busy blocks")
            }
            .accessibilityIdentifier("settings.rebuildBusyBlocks")
            // Rebuild = remove, then rewrite on the next pass. While write-back is paused for the
            // older-block takeover there is no next pass, so it would only remove.
            .disabled(!calendarWriteBack.adoptionPermitsWriting)
            .confirmationDialog("Rebuild busy blocks?", isPresented: $confirmPurge,
                                titleVisibility: .visible) {
                Button("Remove and rewrite", role: .destructive) {
                    Task {
                        purgedCount = await calendarWriteBack.purgeMarkedBlocks()
                        showPurgeResult = true
                        occurrences.requestRecompute(reason: "busy blocks rebuilt")
                    }
                }
            } message: {
                Text("Removes every busy block Banana has written, on every calendar, then writes them again from your current schedule. For a moment that time is bookable.")
            }
            .alert("Busy blocks rebuilt", isPresented: $showPurgeResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(purgedCount == 0
                     ? "No Banana busy blocks were found to remove. Your calendars will be rewritten from your current schedule."
                     : "Removed \(purgedCount) block\(purgedCount == 1 ? "" : "s"). They will be written again from your current schedule.")
            }

            Toggle(isOn: $smart.settings.reserveTaskTime) {
                Text("Reserve time for tasks")
            }
            if !smart.settings.reserveTaskTime {
                Text("Tasks make no busy blocks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Status") {
                HStack(spacing: DS.Space.xs + 2) {
                    StatusDot(status: .ok)
                    Text("Active")
                }
            }
        }
    }

    @ViewBuilder private var permissionsSection: some View {
        Section {
            permissionRow(
                title: "Google Calendar", icon: "calendar",
                granted: smart.calendarAuthorized,
                detail: "Meetings, free time and travel on your timeline"
            ) { await smart.requestCalendarAccess() }

            permissionRow(
                title: "Reminders", icon: "checklist",
                granted: occurrences.remindersAuthorized,
                detail: "Your tasks on the timeline"
            ) { await occurrences.requestRemindersAccess() }

            if DeviceRole.current.isHub {
            permissionRow(
                title: "Health", icon: "heart.fill",
                // Connected only when something proves it. It read "Allowed" as soon as Health's
                // sheet had been shown, whatever was answered on it.
                granted: health.setupState == .done,
                detail: "Workouts, sleep and recovery",
                asked: health.setupState == .asked
            ) { await health.connect() }
            }

            permissionRow(
                title: "Location", icon: "location.fill",
                granted: onboarding.locationGranted,
                detail: "Local weather and travel times",
                blocked: onboarding.locationDenied,
                settings: .location
            ) { onboarding.requestLocation() }

            permissionRow(
                title: "Notifications", icon: "bell.badge.fill",
                granted: onboarding.notificationsGranted,
                detail: "Leave-by nudges and routine cues",
                blocked: onboarding.notificationsDenied,
                settings: .notifications
            ) { _ = await onboarding.requestNotifications() }

            permissionRow(
                title: "Apple Music", icon: "music.note",
                granted: music.isAuthorized,
                detail: "Start a routine with your own music"
            ) { await music.requestAuthorization() }

            #if os(iOS)
            if DeviceRole.current.isHub {
            permissionRow(
                title: "Alarms", icon: "alarm.waves.left.and.right.fill",
                granted: alarms.isAuthorized,
                detail: "Wake cues that ring through Silent Mode"
            ) { await alarms.requestAuthorization() }
            }
            #endif
        } header: {
            Text(DeviceRole.current.isHub ? "Permissions" : "This \(DeviceRole.current.name)")
        } footer: {
            Text("iOS asks only the first time.")
        }
        .task { await onboarding.refresh() }
        if !DeviceRole.current.isHub { phoneStatusSection }
    }

    /// What the phone reports about the jobs only it does — Health, alarms, its notifications,
    /// trip learning, the Watch, backups — so they can be checked from here.
    private var phoneStatus: PhoneStatusText { PhoneStatusText(status: hubStatus.status) }

    @ViewBuilder private var phoneStatusSection: some View {
        let text = phoneStatus
        Section {
            LabeledContent("Apple Health", value: text.healthLine)
            LabeledContent("Alarms", value: text.alarmsLine)
            LabeledContent("Notifications", value: text.notificationsLine)
            LabeledContent("Apple Watch", value: text.watchLine)
            if !backup.retired { LabeledContent("iCloud backup", value: text.backupLine) }
        } header: {
            Text("Your iPhone")
        } footer: {
            Text("Change them on your iPhone.")
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        icon: String,
        granted: Bool,
        detail: String,
        blocked: Bool = false,
        settings: SystemSettingsLink = .app,
        asked: Bool = false,
        connect: @escaping () async -> Void
    ) -> some View {
        // A dot and a word (DESIGN-SYSTEM.md, "Status"): the word carries the meaning.
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: icon, tint: granted ? DS.Palette.Feature.system : DS.Palette.accent,
                     glyph: granted ? nil : DS.Palette.onAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            if granted {
                HStack(spacing: DS.Space.xs + 2) {
                    StatusDot(status: .ok)
                    Text("Allowed").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title) allowed")
            } else if asked {
                // Health was asked and won't say what was answered: the Health app can.
                Button("Open Health") {
                    if let url = URL(string: "x-apple-health://") { openURL(url) }
                }
                .buttonStyle(.secondary)
            } else if blocked || askedWithoutAnswer.contains(title) {
                // Asking again can't work once the system says no — and on the Mac a request can
                // be held back silently (a Focus mode hides the prompt). The settings screen can.
                Button("Open Settings") { openURL(settings.url) }
                    .buttonStyle(.secondary)
            } else {
                Button("Connect") {
                    Task {
                        await connect()
                        await onboarding.refresh()
                        try? await Task.sleep(for: .milliseconds(600))
                        await onboarding.refresh()
                        if !permissionGranted(title) {
                            askedWithoutAnswer.insert(title)
                            ToastCenter.shared.notify("\(title) didn\u{2019}t turn on \u{2014} use Open Settings to allow it")
                        }
                    }
                }
                .buttonStyle(.secondary)
            }
        }
    }

    /// The Banana account (docs/design/ACCOUNTS.md): which Google accounts it holds, so their
    /// calendar changes reach every device at once, and deleting it. Only in a build with the
    /// Banana service. Shown while Banana is signed in, Google connected or not, so disconnecting
    /// the last Google account never hides Delete account.
    @ViewBuilder private var bananaAccountSection: some View {
        if BananaService.isAvailable, bananaAccount.isSignedIn {
            Section {
                // The account and its calendar watches look after themselves (BananaAccount);
                // there is nothing to turn on. One line says what that gives: changes as they
                // happen, or at the next ask. Deleting is the one thing to do here.
                LabeledContent("Calendar changes", value: bananaAccount.updatesAreInstant ? "Instant" : "Every 2 minutes")
                    .accessibilityIdentifier("settings.bananaAccount.updates")
                // The move off iCloud, while it's under way here: one line, nothing to press.
                if SpaceSyncFlag.isOn, let line = moveProgress.line {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.bananaAccount.moving")
                }
                // The Health consent (DATA-PLATFORM.md §7): the one switch to give or withdraw it.
                if SpaceSyncFlag.isOn, spaceQuestions.engineRunning {
                    Toggle("Sync Health", isOn: Binding(get: { spaceQuestions.consentGiven },
                                                        set: { spaceQuestions.setConsent($0) }))
                        .disabled(spaceQuestions.sending)
                        .accessibilityIdentifier("settings.bananaAccount.healthSync")
                } else if SpaceSyncFlag.isOn, spaceQuestions.declinedChange != nil {
                    // "Don't sync" for another account, taken back.
                    Button("Sync this device") { spaceQuestions.askAgain() }
                        .accessibilityIdentifier("settings.bananaAccount.syncDevice")
                }
                Button("Delete account", role: .destructive) { confirmingAccountDelete = true }
                    .disabled(bananaAccount.working)
                    .accessibilityIdentifier("settings.bananaAccount.delete")
                if let error = bananaAccount.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Banana account")
            }
            .confirmationDialog("Delete your Banana account?", isPresented: $confirmingAccountDelete,
                                titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    Task { _ = await bananaAccount.deleteAccount() }
                }
            } message: {
                Text("Confirm by signing in with Google.")
            }
            .task { await bananaAccount.refresh() }
            .task { if SpaceSyncFlag.isOn { await moveProgress.watch() } }
        }
    }

    private func reconnect(_ email: String) {
        Task {
            await googleCalendar.reconnect(email: email)
            await smart.refreshCalendarAuthorization()
            await occurrences.recompute()
        }
    }

    /// Re-read after a Connect, by row title, so a request that came back empty-handed can offer
    /// the settings screen instead.
    private func permissionGranted(_ title: String) -> Bool {
        switch title {
        case "Notifications": onboarding.notificationsGranted
        case "Location": onboarding.locationGranted
        case "Reminders": occurrences.remindersAuthorized
        case "Apple Music": music.isAuthorized
        case "Google Calendar": smart.calendarAuthorized
        default: true   // Health never says; don't send anyone to settings over it
        }
    }

    private func refreshWriteBack() {
        let wasEnabled = calendarWriteBack.enabled
        calendarWriteBack.refreshCalendars()
        Task { await smart.refreshCalendarAuthorization() }
        if !wasEnabled, calendarWriteBack.enabled {
            occurrences.requestRecompute(reason: "write-back default enabled")
        }
    }


    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }
}

extension View {
    /// The Mac's native grouped form at a readable width; iOS keeps its inset-grouped list, as a
    /// readable column where the screen is wider than one.
    @ViewBuilder func settingsFormStyle() -> some View {
        #if os(macOS)
        self.formStyle(.grouped)
            .formControls()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        #else
        self.readableColumn().formControls()
        #endif
    }
}

/// Where a permission is changed once the app can no longer ask for it.
enum SystemSettingsLink {
    case app, notifications, location

    var url: URL {
        #if os(macOS)
        let id = Bundle.main.bundleIdentifier ?? "com.boris.banana"
        switch self {
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        case .location:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        case .app:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        }
        #else
        // iOS has one page per app, with every permission on it.
        return URL(string: UIApplication.openSettingsURLString)!
        #endif
    }
}
