import SwiftUI
import Combine
import EventKit
import CoreLocation
import UserNotifications

/// Drives the first-run onboarding: tracks whether it's done, and owns the permission
/// requests/statuses that don't already live in a dedicated store (Calendar, Reminders,
/// Location, Notifications). Alarms/Health/Music are handled via their own stores.
@MainActor
final class OnboardingStore: NSObject, ObservableObject {
    @Published var completed: Bool
    @Published var notifStatus: UNAuthorizationStatus = .notDetermined
    /// Mirrors `LocationAccess`, which hears it from the system. `.notDetermined` until then:
    /// reading it here, during launch, held the first screen back (see `LocationAccess`).
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var remindersStatus: EKAuthorizationStatus
    @Published private(set) var calendarErrorMessage: String?
    /// Bumped after an EventKit request so SwiftUI re-reads the (non-observable) status.
    @Published private(set) var tick = 0
    /// Whether the notification permission has been read from the system yet.
    @Published private(set) var notificationsKnown = false
    /// Reminders was asked for and not allowed (kept across launches).
    @Published private(set) var remindersAskedAndNotAllowed = UserDefaults.standard.bool(forKey: "remindersAskedNotAllowed")
    private let remindersAskedKey = "remindersAskedNotAllowed"

    // Where onboarding is, held here rather than in the view: the iOS tree is thrown away a
    // moment after the app backgrounds, and signing in to Google often means a trip to another
    // app (a 2FA prompt, an authenticator). The page and the pending calendar question have to
    // be here when the person comes back.
    @Published var step: OnboardingStep = OnboardingStore.savedStep ?? .welcome {
        didSet { if step != oldValue { UserDefaults.standard.set(step.rawValue, forKey: Self.stepKey) } }
    }
    /// The page last shown, kept across launches: a relaunch, or a sign-in that went to another
    /// app, comes back to it (`OnboardingFlow.resume` checks it still applies).
    static var savedStep: OnboardingStep? {
        UserDefaults.standard.string(forKey: stepKey).flatMap(OnboardingStep.init(rawValue:))
    }
    private static let stepKey = "onboardingStep"

    /// Where the copies page stands. Held here, not in the view, so a failure stays on screen
    /// until it is retried, whatever the view tree does meanwhile.
    enum CopiesState: Equatable {
        case idle
        case loading
        /// The plan to show. `updated`: it changed between being shown and the yes, so it is
        /// shown again and nothing was turned on.
        case ready(BusyCopyPreview, updated: Bool)
        case applying(BusyCopyPreview)
        case failed(String)
    }
    @Published private(set) var copies: CopiesState = .idle

    /// Email on the calendar page: on unless turned off there. Only in builds that have Email.
    @Published var emailWanted = true
    /// Why the last "Continue with Google" didn't connect, kept until a try succeeds.
    @Published private(set) var connectProblem: String?
    /// Working out Email after a sign-in (waiting for the account's feature access).
    @Published private(set) var settlingEmail = false
    /// What became of Email on the calendar page, for the receipt.
    @Published private(set) var emailOutcome: EmailSetup.Outcome?

    /// Whether this build has Email (Beta, development); Stable compiles it out. Debug's
    /// `--onboarding-stable` shows the Stable page in a build that has it.
    static var emailInBuild: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--onboarding-stable") { return false }
        #endif
        return AppModule.email.isAvailable
    }
    /// The answer given on the copies page, for the receipt.
    @Published private(set) var copiesAnswer: OnboardingReceipt.Copies?
    /// When the person's day starts and winds down, as answered on the way in.
    @Published var anchors = DayAnchors()
    /// What Banana looks after, as ticked on the welcome: the choice already made on another
    /// device when there is one, else Plan alone. Saved to `ModuleStore` on "Get started".
    @Published var modules: ModuleChoice = ModuleStore.shared.hasChoice ? ModuleStore.shared.choice : .planOnly

    private let key = "onboardingCompleted"
    private var locationWatch: AnyCancellable?
    /// Keep one store alive for the lifetime of onboarding. Besides avoiding repeated daemon
    /// setup, this guarantees the async permission request isn't tied to a temporary store.
    private let eventStore = EKEventStore()

    override init() {
        completed = UserDefaults.standard.bool(forKey: key)
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        super.init()
        locationWatch = LocationAccess.shared.$status.sink { [weak self] status in
            guard let self, self.locationStatus != status else { return }
            self.locationStatus = status
        }
    }

    func finish() {
        completed = true
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
    }

    // MARK: - Calendar and email

    /// "Continue with Google": one consent for the calendar and, when wanted, Gmail. Then Email is
    /// settled from what Google granted and what the account is offered.
    func connectCalendarAndEmail() async -> ConnectAttempt {
        connectProblem = nil
        let extra = EmailSetup.extraScopes(inBuild: Self.emailInBuild, wanted: emailWanted)
        let google = GoogleCalendarService.shared
        await google.restoreIfNeeded()
        let granted = await google.connect(extraScopes: extra)
        tick += 1
        guard granted != nil, calendarGranted else {
            let attempt: ConnectAttempt = google.lastError.map { .failed($0) } ?? .cancelled
            connectProblem = attempt.problem
            return attempt
        }
        CalendarWriteBack.shared.refreshCalendars()
        Log.sync.notice("google calendar connect finished connected=true")
        await settleEmail()
        return .connected
    }

    /// Email from what is connected now: on when Gmail was granted and the account is offered
    /// Email, off otherwise, quietly. Also what Continue does after a relaunch mid-consent.
    func settleEmail(waiting timeout: Duration = .seconds(6)) async {
        settlingEmail = true
        defer { settlingEmail = false }
        let gmailGranted = Self.gmailGrantedAccounts.isEmpty == false
        var eligible: Bool? = Self.sampleEligibility
        if eligible == nil, Self.emailInBuild, emailWanted, gmailGranted {
            let access = FeatureAccessStore.shared
            let deadline = ContinuousClock.now + timeout
            while !access.policyLoaded, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            eligible = access.policyLoaded ? access.emailAvailable : nil
        }
        let outcome = EmailSetup.outcome(inBuild: Self.emailInBuild, wanted: emailWanted,
                                         gmailGranted: gmailGranted, eligible: eligible)
        emailOutcome = outcome
        if Self.emailInBuild {
            let on = outcome == .on
            if modules.includes(.email) != on || ModuleStore.shared.choice.includes(.email) != on {
                modules = modules.setting(.email, on: on)
                ModuleStore.shared.set(modules)
            }
        }
        if EmailSetup.releasesGrant(outcome, gmailGranted: gmailGranted) { releaseMailGrants() }
    }

    /// Accounts whose Google grant on this device includes Gmail.
    private static var gmailGrantedAccounts: [String] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--onboarding-sample") {
            return ProcessInfo.processInfo.arguments.contains("--onboarding-gmail-unticked") ? [] : ["noor@plan.example"]
        }
        #endif
        guard !EmailSetup.gmailScope.isEmpty else { return [] }
        return GoogleCalendarService.shared.accounts
            .filter { $0.grantedScopes.contains(EmailSetup.gmailScope) }.map(\.email)
    }

    /// Debug sample accounts say whether they are offered Email; real ones ask the service.
    private static var sampleEligibility: Bool? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--onboarding-sample") { return arguments.contains("--onboarding-email-eligible") }
        #endif
        return nil
    }

    /// An account not offered Email keeps no Mail grant: the service forgets it (Mail only; its
    /// Google consent is not revoked, which would take the calendar with it).
    private func releaseMailGrants() {
        #if !BANANA_PUBLIC
        guard Self.sampleEligibility == nil else { return }
        for email in Self.gmailGrantedAccounts {
            Task {
                do { try await BananaAccount.shared.disconnectMail(email: email) } catch {
                    Log.sync.notice("first run: unused Mail grant not released yet: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        #endif
    }

    // MARK: - Busy copies

    /// Plan copies with the pass that would write them (`CalendarWriteBack.previewCopies`).
    func loadCopyPreview() async {
        if case .applying = copies { return }
        copies = .loading
        switch await CalendarWriteBack.shared.previewCopies() {
        case .success(let preview): copies = .ready(preview, updated: false)
        case .failure(let failure): copies = .failed(failure.message)
        }
    }

    /// The yes. True once copies are on; otherwise the page shows why, or the changed plan.
    func turnOnCopies() async -> Bool {
        guard case .ready(let shown, _) = copies else { return false }
        copies = .applying(shown)
        switch await CalendarWriteBack.shared.turnOnCopies(shown: shown) {
        case .enabled:
            copiesAnswer = .on(count: shown.creates, to: shown.changing.map(\.title))
            copies = .ready(shown, updated: false)
            return true
        case .changed(let fresh):
            copies = .ready(fresh, updated: true)
            return false
        case .failed(let message):
            copies = .failed(message)
            return false
        }
    }

    func keepViewingOnly() {
        CalendarWriteBack.shared.keepViewingOnly()
        copiesAnswer = .off
    }

    /// Put the answers on the plan: the Wake and Wind down routines take those times, and the
    /// wake time is what a smart wake falls back to on a day without meetings. Called as each
    /// question is left, so an answer holds even if the first run is not finished.
    func applyAnchors() {
        let anchors = anchors.clamped
        let store = RoutineStore.shared
        for routine in store.routines {
            let kind: DayAnchors.Kind = routine.cueType == .wake ? .wake : routine.cueType == .windDown ? .windDown : .other
            guard let time = anchors.time(for: kind),
                  routine.hour != time.hour || routine.minute != time.minute else { continue }
            var moved = routine
            moved.hour = time.hour
            moved.minute = time.minute
            store.upsert(moved)
        }
        if SmartScheduleStore.shared.settings.defaultWakeMinutes != anchors.wakeMinutes {
            SmartScheduleStore.shared.settings.defaultWakeMinutes = anchors.wakeMinutes
        }
    }

    /// A signed-in iCloud backup can prove this person already completed onboarding in the
    /// predecessor app. Carry that fact across the bundle migration before presenting any
    /// permission UI; permissions that did not transfer are handled individually by RootView.
    func completeForReturningUser() {
        guard !completed else { return }
        finish()
    }

    /// Re-read the statuses that aren't published by their own APIs.
    ///
    /// Every assignment below is guarded by equality: this runs on every refresh path (tab
    /// switch, foreground, calendar sync poke), and an unconditional publish re-renders every
    /// observer of this store on each call even when nothing changed (see the WeekView CPU-storm
    /// evidence — the same unconditional-assign pattern in AlarmStore.updateAlerting).
    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if notifStatus != settings.authorizationStatus { notifStatus = settings.authorizationStatus }
        if !notificationsKnown { notificationsKnown = true }
        // Location may have been changed in Settings while the app was away.
        LocationAccess.shared.recheck()
        // The calendar is Google now: whether it is "granted" is whether an account is connected,
        // which is only known once the synced credentials have been read.
        await GoogleCalendarService.shared.restoreIfNeeded()
        refreshEventKitAuthorization()
        let allowed = notificationsGranted
        HubStatusStore.shared.update { $0.notificationsAllowed = allowed }   // the phone only
    }

    /// EventKit authorization is a synchronous local lookup. Keep it separate so a Calendar
    /// button never waits on the unrelated notification daemon before it can respond.
    func refreshEventKitAuthorization() {
        let newRemindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        if remindersStatus != newRemindersStatus { remindersStatus = newRemindersStatus }
        // `tick` stays unconditional: MacRootView's `.onChange(of: onboarding.tick)` uses it to
        // re-check the *computed* `calendarGranted` (which reads live calendar-list access, not
        // just `calendarStatus`) after every refresh — that can change even when the raw
        // EKAuthorizationStatus enum doesn't, so a same-value guard here would drop real signals.
        tick += 1
    }

    // MARK: - Requests

    /// Connect the calendar — a Google account, through Google's own sign-in.
    @discardableResult
    func requestCalendar() async -> Bool {
        calendarErrorMessage = nil
        let google = GoogleCalendarService.shared
        await google.restoreIfNeeded()
        if !google.isConnected { await google.connect() }
        tick += 1
        let connected = calendarGranted
        if connected {
            CalendarWriteBack.shared.refreshCalendars()
        } else {
            calendarErrorMessage = google.lastError
        }
        Log.sync.notice("google calendar connect finished connected=\(connected, privacy: .public)")
        return connected
    }

    @discardableResult
    func requestReminders() async -> Bool {
        let granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        let allowed = granted || remindersGranted
        // The status alone can't be trusted to say no (`RemindersAccess`): remember having asked.
        if remindersAskedAndNotAllowed == allowed {
            remindersAskedAndNotAllowed = !allowed
            UserDefaults.standard.set(!allowed, forKey: remindersAskedKey)
        }
        tick += 1
        return allowed
    }

    /// Where Reminders stands for the setup list, given whether its reminders can be read.
    func remindersState(authorized: Bool) -> SetupState {
        let recorded: RemindersAccess.Recorded = authorized || remindersGranted ? .allowed
            : [.denied, .restricted].contains(remindersStatus) ? .refused : .notDetermined
        return RemindersAccess.state(recorded: recorded, askedAndNotAllowed: remindersAskedAndNotAllowed)
    }

    @discardableResult
    func requestNotifications() async -> Bool {
        let granted = await NotificationService.requestAuthorization()
        await refresh()
        return granted || notificationsGranted
    }
    func requestLocation() {
        LocationAccess.shared.ask()
    }

    // MARK: - Statuses (EventKit isn't observable; `tick` forces a re-read)

    /// A Google account is connected. Banana's calendar is Google; Apple Calendar access is only
    /// ever asked for once, to take over blocks written the old way (see CalendarWriteBack).
    var calendarGranted: Bool {
        GoogleCalendarService.shared.isConnected
    }
    var remindersGranted: Bool { remindersStatus == .fullAccess }
    /// Asked and refused (or blocked by restrictions): only Settings can change it now.
    var locationDenied: Bool { locationStatus == .denied || locationStatus == .restricted }
    var locationGranted: Bool {
        // macOS has no "when in use" — a Mac isn't in your pocket. `.authorizedAlways` is the only
        // granted state it has.
        #if os(iOS)
        return locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways
        #else
        return locationStatus == .authorizedAlways || locationStatus == .authorized
        #endif
    }
    var notificationsGranted: Bool { notifStatus == .authorized || notifStatus == .provisional }
    /// Turned off for Banana in the system's settings: asking again returns "no" at once, with no
    /// prompt — only the settings screen can change it.
    var notificationsDenied: Bool { notifStatus == .denied }
    /// Never asked, and known to be: until the system has been read, "not determined" is only
    /// this store's starting value. A card that asks from the plan must not show on that guess,
    /// or someone who said no would see it again at every launch.
    var notificationsNeverAsked: Bool { notificationsKnown && notifStatus == .notDetermined }
}
