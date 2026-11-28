import Combine
import Security
import Foundation
import os

/// Banana's own account (docs/design/ACCOUNTS.md): made by connecting Google, shared by this
/// person's devices, and the way the Banana service knows where to push when a Google calendar
/// changes.
///
/// The session sits in iCloud Keychain next to the Google credentials, so signing in on one
/// device signs in the others; each device then registers itself and its push token. Each device
/// also keeps a watch at Google on every calendar it reads, addressed to the service, which pushes
/// to every device of the account when Google calls.
///
/// Nothing here needs a hand: no button, no switch. What can go wrong on its own (the service
/// unreachable for a moment, a watch that failed to open) is retried, and written to the journal
/// (`☁️ account` lines), never put on screen. The one line Settings shows is the state: whether
/// calendar changes reach this device at once.
///
/// Nothing here runs without `BananaService.isAvailable`: anyone's own build stays as it was.
@MainActor
final class BananaAccount: ObservableObject {
    static let shared = BananaAccount()

    /// The account as the service last described it. Each description also tells
    /// `GoogleCalendarService` which connected accounts the service still has no Google access of
    /// its own for, so those show "Sign in again" where a signed-out account already does.
    @Published private(set) var account: BananaService.Account? {
        didSet {
            if let account {
                FeatureAccessStore.shared.receive(account: account.id, policy: account.featureAccess,
                                                  mailAccounts: account.google.map { $0.email.lowercased() })
            }
            let need = BananaService.accountsToSignInAgain(connected: GoogleCalendarService.shared.accounts.map(\.id), account: account)
            if need != GoogleCalendarService.shared.accountsNeedingServiceSignIn {
                PlaybackDiagnostics.shared.log("☁️ account", need.isEmpty
                    ? "the service has Google access for every connected account"
                    : "the service has no Google access for \(need.count) account(s): sign in again")
            }
            GoogleCalendarService.shared.serviceNeedsSignIn(for: need)
        }
    }
    @Published private(set) var working = false
    /// Something a person has to act on (the Google account belongs to another Banana account; a
    /// delete that didn't go through). Never a passing failure.
    @Published private(set) var lastError: String?
    /// This device's push token is with the service: the service can reach it.
    @Published private(set) var pushRegistered = false

    var isSignedIn: Bool { session != nil }

    /// Whether a change on a Google calendar reaches this device as it happens (a push), rather
    /// than at the next two-minute ask.
    var updatesAreInstant: Bool { BananaService.updatesAreInstant(pushRegistered: pushRegistered, account: account) }

    private static let log = Logger(subsystem: "com.boris.banana", category: "account")
    private static let keychainAccount = "banana-session"
    private static let deviceSecretAccount = "banana-device-secret"
    /// How long after a failed pass the next try is: a minute, then five.
    static let retryDelays: [TimeInterval] = [60, 5 * 60]
    /// How often a running app makes sure its watches at Google are current, with no one touching
    /// it: a Mac left open for a week would otherwise let them lapse (they live seven days).
    static let keepEvery: TimeInterval = 6 * 3_600

    private let defaults = UserDefaults.standard
    private var session: String?
    private var pushToken: String?
    private var started = false
    private var watching: AnyCancellable?
    /// Re-registers the device when what it takes pushes about changes (a module switched).
    private var capabilityWatch: AnyCancellable?
    private var pass: Task<Void, Never>?
    private var passAgain: String?
    private var retry: Task<Void, Never>?
    private var keeping: Task<Void, Never>?
    private var policyRefresh: Task<Void, Never>?
    /// A call didn't reach the service during the current pass.
    private var transportFailed = false

    private init() {
        FeatureAccessStore.shared.reportTransition = { PlaybackDiagnostics.shared.log("feature access", $0) }
        session = SyncedKeychain.read(service: AppVariant.current.googleKeychainService,
                                      account: Self.keychainAccount) { String(data: $0, encoding: .utf8) }
        FeatureAccessStore.shared.bind(session: session, host: BananaService.host)
    }

    /// At launch, and each time the app comes forward: pick up a session signed in on another
    /// device, join any Google account not yet in the Banana account, register this device, and
    /// keep the watched calendars current.
    func start() {
        guard BananaService.isAvailable else { return }
        if session == nil {
            session = SyncedKeychain.read(service: AppVariant.current.googleKeychainService,
                                          account: Self.keychainAccount) { String(data: $0, encoding: .utf8) }
        }
        FeatureAccessStore.shared.bind(session: session, host: BananaService.host)
        if !started {
            started = true
            // The Google accounts, their calendars, or the ones set not to count changed: join any
            // new account and bring the watches in line.
            watching = GoogleCalendarService.shared.$calendars.map { _ in () }
                .merge(with: SmartScheduleStore.shared.$settings.map(\.excludedCalendarIDs).removeDuplicates().map { _ in () })
                .debounce(for: .seconds(3), scheduler: RunLoop.main)
                .sink { [weak self] in self?.runPass(reason: "calendars changed") }
            // Email switched on or off here or on another device: the service hears it at once, so
            // its mail pushes reach only the devices that show Mail.
            capabilityWatch = ModuleStore.shared.$choice.map(BananaService.deviceCapabilities(modules:))
                .removeDuplicates().dropFirst()
                .sink { [weak self] _ in Task { await self?.registerDevice() } }
            policyRefresh = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10 * 60)) } catch { return }
                    guard let self else { return }
                    await self.refresh()
                }
            }
            keeping = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.keepEvery))
                    guard !Task.isCancelled else { return }
                    self?.runPass(reason: "keep")
                }
            }
        }
        runPass(reason: "start")
    }

    /// One pass over everything, one at a time. A pass the service couldn't be reached during is
    /// tried again on its own (`retryDelays`); after that the next start does.
    private func runPass(reason: String, attempt: Int = 0) {
        retry?.cancel()
        guard pass == nil else { passAgain = reason; return }   // follows the one under way
        pass = Task { [weak self] in
            guard let self else { return }
            defer {
                self.pass = nil
                if let again = self.passAgain { self.passAgain = nil; self.runPass(reason: again) }
            }
            self.transportFailed = false
            if self.isSignedIn { await self.refreshShared() }     // which Google accounts are linked already
            await self.signInByIdentity()
            if self.isSignedIn {
                await self.registerDevice()
                await self.sendWatchLists()
                // The booking link, or the handle to suggest, so the calendar's Share works on its
                // first tap. Once it's known, Booking and sharing read it again themselves.
                await BookingCenter.shared.refreshIfUnknown()
            }
            guard self.transportFailed, attempt < Self.retryDelays.count else { return }
            let delay = Self.retryDelays[attempt]
            PlaybackDiagnostics.shared.log("☁️ account", "\(reason): service unreachable, trying again in \(Int(delay)) s")
            self.retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.runPass(reason: "retry", attempt: attempt + 1)
            }
        }
    }

    /// Every connected Google account joins the Banana account by itself: the app mints Google's
    /// identity token with the refresh token it already holds and hands it to the service. No
    /// sign-in sheet, no button, every account (The author, 18 Oct 2026: "Why is it not just auto
    /// triggered?"). Only the accounts not yet in the Banana account are sent.
    private func signInByIdentity() async {
        // The account was deleted, here or on another device: nothing signs in again by itself,
        // which would start a new account and upload this device's data to it. A sign-in the
        // person makes (googleSignedIn) does.
        if !isSignedIn && deletedHere { return }
        let google = GoogleCalendarService.shared
        let linked = Set((account?.google ?? []).map { $0.email.lowercased() })
        let missing = BananaService.accountsToLink(connected: google.accounts.map(\.id), linked: linked, signedIn: isSignedIn)
        var disconnected = false
        for email in missing {
            let idToken: String
            do { idToken = try await google.identityToken(forEmail: email) }
            catch {
                Self.log.error("no Google identity token for an account: \(error.localizedDescription, privacy: .public)")
                PlaybackDiagnostics.shared.log("☁️ account", "no identity token for a Google account: \(error.localizedDescription)")
                continue
            }
            guard case var (data, status)? = await send(.identity(idToken: idToken, device: device())) else { continue }
            if status == 409, BananaService.failure(in: data) == "device_taken" {
                // This device's id is another account's, and not this install's: a new id, once.
                newDeviceIdentity()
                guard case let (retried, again)? = await send(.identity(idToken: idToken, device: device())) else { continue }
                (data, status) = (retried, again)
            }
            if status == 200, let answer = try? JSONDecoder().decode(BananaService.SignInAnswer.self, from: data) {
                if let new = answer.session { keep(session: new) }
                account = answer.account
                lastError = nil
                PlaybackDiagnostics.shared.log("☁️ account", "joined: \(answer.account.google.count) Google account(s), \(answer.account.devices) device(s)")
            } else if status == 403, BananaService.failure(in: data) == "disconnected" {
                // Disconnected from the Banana account, which still has another Google account.
                disconnected = true
            } else if status == 409 {
                lastError = "A Google account here belongs to another Banana account."
            } else {
                Self.log.error("identity sign-in for an account answered \(status, privacy: .public)")
            }
        }
        if disconnected && !isSignedIn { lastError = Self.disconnectedMessage }
    }

    static let disconnectedMessage = "That Google account was disconnected from Banana. Sign in with one still connected."

    #if DEBUG
    /// `--settings --account-disconnected-preview`: Settings as it is after a refused sign-in.
    func showRefusalForPreview() { lastError = Self.disconnectedMessage }
    #endif

    // MARK: - Signing in

    /// Google's sign-in finished with a one-time code for the service: sign in with it, or link
    /// this Google account to the account already signed in. The code lasts minutes, so this
    /// follows the sign-in at once.
    func googleSignedIn(code: String?) async {
        guard BananaService.isAvailable else { return }
        guard let code else {
            // Google hands over a code only when the service's client is right; without one the
            // service never gets access, so it is written down rather than passed over in silence.
            PlaybackDiagnostics.shared.log("☁️ account", "Google gave no code for the service at a sign-in")
            return
        }
        working = true
        defer { working = false }
        guard case let (data, status)? = await send(.signIn(code: code, device: device())) else { return }
        switch status {
        case 200:
            deletedHere = false   // signed in on purpose: joining by itself is fine again
            guard let answer = try? JSONDecoder().decode(BananaService.SignInAnswer.self, from: data) else { return }
            if let new = answer.session { keep(session: new) }
            account = answer.account
            lastError = nil
            if answer.account.google.contains(where: { $0.access == false }) {
                // A sign-in with a code should leave the service with a token. Google leaves it
                // out when this web client was granted before: then its grant has to be revoked
                // for the next sign-in to bring one (see docs/design/ACCOUNTS.md).
                PlaybackDiagnostics.shared.log("☁️ account", "signed in with a code, but the service still lacks Google access for an account")
            }
            await sendWatchLists()
        case 409 where BananaService.failure(in: data) == "device_taken":
            // The code is spent; with a new device id the identity sign-in joins at once.
            newDeviceIdentity()
            runPass(reason: "new device id")
        case 409:
            lastError = "That Google account belongs to another Banana account."
        case 403 where BananaService.failure(in: data) == "disconnected":
            lastError = Self.disconnectedMessage
        default:
            // Passing: the identity sign-in at the next pass joins the account anyway.
            PlaybackDiagnostics.shared.log("☁️ account", "sign-in with a code answered \(status)")
        }
    }

    /// A Google account disconnected in Banana: the service stops watching it and gives up its
    /// access.
    func googleDisconnected(email: String) async {
        guard isSignedIn else { return }
        // Close its watches at Google while this device can still reach the account.
        if case let (data, 200)? = await send(.channels),
           let channels = try? JSONDecoder().decode(BananaService.ChannelsAnswer.self, from: data).channels {
            for channel in channels where channel.email.lowercased() == email.lowercased() { await close(channel) }
        }
        _ = await send(.unlink(email: email))
        await refresh()
    }

    private var sharedRefresh: Task<Bool, Never>?
    private var sharedRefreshFailedAt: Date?

    /// One refresh for everyone waiting on the account at the same moment: at launch the account
    /// pass, Mail and Calendar each needed it, and each asked the service on its own. For a minute
    /// after one fails it answers at once, so work that waits on it offline is not held each time.
    @discardableResult
    func refreshShared() async -> Bool {
        if let sharedRefresh { return await sharedRefresh.value }
        if let failed = sharedRefreshFailedAt, Date().timeIntervalSince(failed) < 60 { return false }
        let task = Task { await self.refresh() }
        sharedRefresh = task
        let answered = await task.value
        sharedRefresh = nil
        sharedRefreshFailedAt = answered ? nil : Date()
        return answered
    }

    /// True when the service answered with the account.
    @discardableResult
    func refresh() async -> Bool {
        guard isSignedIn, let requestedSession = session,
              case let (data, status)? = await send(.account), session == requestedSession else { return false }
        guard status == 200, let described = try? JSONDecoder().decode(BananaService.Account.self, from: data) else { return false }
        account = described
        return true
    }

    /// Deletes the account on the service: every calendar watch, Google's access, every row.
    /// Proof first: a fresh Google sign-in with one of the account's Google accounts, whose
    /// one-time code goes along; a session alone never deletes. The Google accounts stay connected
    /// in the app; connecting one again starts a new account.
    func deleteAccount() async -> Bool {
        guard BananaService.isAvailable else { return true }
        let hint = account?.google.first?.email ?? GoogleCalendarService.shared.accounts.first?.email
        let code: String
        do { code = try await GoogleCalendarService.shared.freshSignInCode(hint: hint) }
        catch is CancellationError { return false }
        catch {
            lastError = "Google didn\u{2019}t confirm it\u{2019}s you. Try again."
            return false
        }
        working = true
        defer { working = false }
        guard case let (data, status)? = await send(.deleteAccount(code: code)) else {
            lastError = "Couldn\u{2019}t reach the Banana service. Try again."
            return false
        }
        switch status {
        case 204:
            let deleted = account?.id
            deletedHere = true
            signedOut()
            // The data platform's mirror of the deleted account goes with it.
            if let deleted { SpaceSyncLaunch.forget(account: deleted) }
            lastError = nil
            return true
        case 404, 409:
            lastError = "That Google account isn\u{2019}t part of this Banana account."
        case 403 where BananaService.failure(in: data) == "disconnected":
            lastError = "That Google account was disconnected from Banana. Use one still connected."
        case 401 where BananaService.failure(in: data) == "google_refused":
            lastError = "Google didn\u{2019}t confirm it\u{2019}s you. Try again."
        default:
            lastError = "Couldn\u{2019}t delete the account. Try again."
        }
        return false
    }

    // MARK: - This device

    func pushTokenArrived(_ token: Data) {
        let hex = BananaService.hex(token)
        guard hex != pushToken else { return }
        pushToken = hex
        pushRegistered = false
        PlaybackDiagnostics.shared.log("☁️ push", "token from Apple (\(pushEnvironment))")
        Task { await registerDevice() }
    }

    /// What the service last accepted from this device, under which session, and when.
    private var registered: (device: BananaService.Device, session: String, at: Date)?
    private var registering: Task<Void, Never>?
    private func registerDevice() async {
        guard isSignedIn, let session else { return }
        if let inFlight = registering {
            await inFlight.value
            return await registerDevice()
        }
        let device = device()
        guard BananaService.registrationDue(device, session: session, last: registered, now: Date()) else { return }
        let task = Task { [weak self] in
            guard let self, case let (_, status)? = await self.send(.device(device)), status == 204 else { return }
            self.registered = (device, session, Date())
            self.pushRegistered = device.push != nil
            PlaybackDiagnostics.shared.log("☁️ account", "device registered, push \(device.push == nil ? "no" : "yes") (\(device.pushEnv))")
        }
        registering = task
        await task.value
        registering = nil
    }

    /// This install's id, as the service knows the device; the data platform's clocks carry it.
    var deviceIdentifier: String { deviceID }

    /// This install's id: random, this device only.
    private var deviceID: String {
        if let id = defaults.string(forKey: "bananaDeviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "bananaDeviceID")
        return id
    }

    /// This install's secret: 32 random bytes, in this device's keychain only (never synced, not
    /// restored to another device). The service moves this device's row to another account only
    /// for the install that holds it.
    private var deviceSecret: String? {
        let service = AppVariant.current.googleKeychainService
        if let stored = DeviceKeychain.read(service: service, account: Self.deviceSecretAccount) { return stored }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard DeviceKeychain.write(secret, service: service, account: Self.deviceSecretAccount) else { return nil }
        return secret
    }

    /// The service said this device's id belongs to another account and isn't this install's: a
    /// new id and secret.
    private func newDeviceIdentity() {
        defaults.removeObject(forKey: "bananaDeviceID")
        DeviceKeychain.delete(service: AppVariant.current.googleKeychainService, account: Self.deviceSecretAccount)
        PlaybackDiagnostics.shared.log("☁️ account", "this device's id was taken: a new one")
    }

    private var pushEnvironment: String {
        PushEnvironment.current(isDevelopmentInstall: Telemetry.channel == "dev")
    }

    private func device() -> BananaService.Device {
        BananaService.Device(id: deviceID, platform: Telemetry.platform, push: pushToken,
                             pushEnv: pushEnvironment,
                             bundle: Bundle.main.bundleIdentifier ?? "com.boris.banana", providerProtocol: 1,
                             capabilities: BananaService.deviceCapabilities(modules: ModuleStore.shared.choice),
                             secret: deviceSecret)
    }

    // MARK: - Calendars to watch

    private var keepingWatches = false

    /// Calendars Google won't send change notices for, on this device.
    private var unwatchable: Set<String> {
        get { Set(defaults.stringArray(forKey: "bananaUnwatchableCalendars") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "bananaUnwatchableCalendars") }
    }

    /// Makes sure every calendar this device reads has a live watch at Google that tells the
    /// service when it changes: opens the missing ones and renews the ones ending within a day with
    /// this device's own Google access, and closes the ones no longer wanted. Any device of the
    /// account may do it; the plan settles on one watch per calendar.
    private func sendWatchLists() async {
        guard isSignedIn, let account, !keepingWatches else { return }
        let google = GoogleCalendarService.shared
        // Only after a full calendar list: a list missing an account's calendars would close its watches.
        guard !google.calendars.isEmpty, google.accountsWithUnreadableCalendars.isEmpty else {
            PlaybackDiagnostics.shared.log("☁️ account", "watches wait for a full calendar list")
            return
        }
        keepingWatches = true
        defer { keepingWatches = false }
        let linked = Set(account.google.filter { $0.status == "ok" }.map { $0.email.lowercased() })
        let wanted = BananaService.watchLists(
            calendars: google.calendars.filter { !$0.isDeleted }.map { ($0.accountEmail, $0.id, $0.isHidden) },
            excluded: SmartScheduleStore.shared.settings.excludedCalendarIDs.union(unwatchable))
            .filter { linked.contains($0.key) }
        if FeatureAccessStore.shared.calendarReadContext != nil {
            // Existing service watch reconciliation owns renewals and alert reads. Old native
            // channels expire naturally; keeping them briefly avoids a notification gap.
            for (email, ids) in wanted { _ = await send(.serverCalendars(email: email, ids: ids)) }
            return
        }
        for email in wanted.keys {
            // Revocation/sign-out cannot silently return provider ownership to this device.
            if (try? await Self.requiresCloudCalendar(email: email)) != false { return }
        }
        guard case let (data, status)? = await send(.channels), status == 200,
              let channels = try? JSONDecoder().decode(BananaService.ChannelsAnswer.self, from: data).channels else { return }
        let plan = BananaService.watchPlan(wanted: wanted, channels: channels, now: Date())
        var opened = 0, failed = 0, newlyUnwatchable = 0
        for item in plan.open {
            guard case let (openedData, made)? = await send(.openChannel(email: item.email, calendarID: item.calendarID)), made == 201,
                  let channel = try? JSONDecoder().decode(BananaService.OpenedChannel.self, from: openedData) else { continue }
            do {
                let watch = try await google.openWatch(calendarID: item.calendarID, email: item.email, channelID: channel.id,
                                                       token: channel.token, address: channel.address,
                                                       ttlSeconds: channel.ttlSeconds)
                _ = await send(.confirmChannel(id: channel.id, resourceID: watch.resourceID, expiration: watch.expiration))
                opened += 1
                for old in plan.replaced["\(item.email)\n\(item.calendarID)"] ?? [] { await close(old) }
            } catch {
                // Some calendars (holidays, subscribed feeds) can't be watched: remembered, so they
                // aren't asked for again at every start. The two-minute ask still reads them.
                if error is CalendarWatchUnsupported {
                    unwatchable.insert(item.calendarID)
                    newlyUnwatchable += 1
                } else {
                    failed += 1
                    Self.log.error("couldn't open a calendar watch: \(error.localizedDescription, privacy: .public)")
                    PlaybackDiagnostics.shared.log("☁️ account", "a calendar watch didn't open: \(error.localizedDescription)")
                }
                _ = await send(.closeChannel(id: channel.id))
            }
        }
        for old in plan.close { await close(old) }
        if opened + failed + newlyUnwatchable + plan.close.count > 0 || account.google.allSatisfy({ $0.watching == 0 }) {
            PlaybackDiagnostics.shared.log(
                "☁️ account",
                "watches: opened \(opened), closed \(plan.close.count), failed \(failed), unwatchable \(newlyUnwatchable) new; "
                + "wanted \(wanted.values.map(\.count).reduce(0, +)) across \(wanted.count) Google account(s)")
            await refresh()
        }
    }

    private func close(_ channel: BananaService.Channel) async {
        if let resource = channel.resourceId {
            await GoogleCalendarService.shared.closeWatch(channelID: channel.id, resourceID: resource, email: channel.email)
        }
        _ = await send(.closeChannel(id: channel.id))
    }

    // MARK: - Event alerts (docs/design/EVENT-ALERTS.md)

    private var reportedHeld: BananaService.HeldReport?
    private var reportedAlertSettings: (leads: [Int], zone: String)?

    /// The local alerts this device holds now (the service won't push those to it), the calendars
    /// it rings for and the events it skips (the service rings for nothing else). Sent only when it
    /// changed since last time.
    func reportHeldAlerts(_ ids: [String], quiet: [String]) async {
        guard isSignedIn else { return }
        let report = BananaService.HeldReport(ids: ids, calendars: alertCalendars, quiet: quiet)
        guard report != reportedHeld else { return }
        guard case let (_, 204)? = await send(.heldAlerts(device: deviceID, report: report)) else { return }
        reportedHeld = report
        PlaybackDiagnostics.shared.log("🔔 alert", "told the service this device holds \(report.ids.count) alert(s), rings for \(report.calendars?.count ?? 0) calendar(s), skips \(report.quiet.count)")
    }

    /// The calendars this device's event alerts come from: the ones it reads and watches. Nil until
    /// the calendar list is whole, so a partial list never silences a calendar.
    private var alertCalendars: [String]? {
        let google = GoogleCalendarService.shared
        guard !google.calendars.isEmpty, google.accountsWithUnreadableCalendars.isEmpty else { return nil }
        return BananaService.watchLists(
            calendars: google.calendars.filter { !$0.isDeleted }.map { ($0.accountEmail, $0.id, $0.isHidden) },
            excluded: SmartScheduleStore.shared.settings.excludedCalendarIDs
                .union(SmartScheduleStore.shared.settings.mutedCalendarIDs))
            .values.flatMap { $0 }
    }

    /// The lead times (and this device's zone) the service words its alerts with.
    func alertSettingsChanged(leads: [Int]) async {
        guard isSignedIn else { return }
        let zone = TimeZone.current.identifier
        let settings = (leads: leads.sorted(by: >), zone: zone)
        if let last = reportedAlertSettings, last.leads == settings.leads, last.zone == settings.zone { return }
        guard case let (_, 204)? = await send(.alertSettings(leads: settings.leads, timeZone: zone)) else { return }
        reportedAlertSettings = settings
    }

    /// The Health consent given or withdrawn (`PUT`/`DELETE /v2/consents/health`). True once the
    /// service has it; both are safe to send again.
    func setHealthConsent(_ granted: Bool, version: String) async -> Bool {
        guard isSignedIn else { return false }
        guard case let (_, status)? = await send(.healthConsent(granted: granted, version: version, device: deviceID)) else {
            return false
        }
        return status == 204 || status == 200
    }

    /// A booking call (`BookingCenter`): nil when not signed in, or when the service couldn't be
    /// reached.
    func bookingCall(_ call: BananaService.Call) async -> (data: Data, status: Int)? {
        guard isSignedIn, let (data, status) = await send(call) else { return nil }
        return (data, status)
    }

    private var providerOperationContext: String? {
        guard let account, let host = BananaService.host else { return nil }
        return CloudProviderOperationJournal.context(account: account.id, host: host)
    }

    /// The pause provider changes keep after the service says it is full. Mail, Calendar and drafts share
    /// the service's limit, so one 429 pauses them all: the change stays in its journal and goes when the
    /// pause ends, instead of every queued change asking in turn and being refused.
    private var operationBackoff = OperationBackoff()

    /// Seconds left of the pause, nil when none.
    private func operationPause() -> TimeInterval? { operationBackoff.remaining(at: Date()) }

    private func noteOperationAnswer(_ status: Int) {
        if status == 429 {
            let before = operationBackoff.streak
            operationBackoff.refused(at: Date(), jitter: RetryPause.jitter())
            if before == 0 {
                PlaybackDiagnostics.shared.log("☁️ account", "service is full: provider changes wait \(Int(operationBackoff.remaining(at: Date()) ?? 0)) s, then go again")
            }
        } else if (200..<300).contains(status), operationBackoff.streak > 0 {
            operationBackoff.accepted()
            PlaybackDiagnostics.shared.log("☁️ account", "service accepts provider changes again")
        }
    }

    #if !BANANA_PUBLIC
    private static let mailJournal = CloudProviderOperationJournal(
        directory: AppSupport.directory.appendingPathComponent("mail-cloud-operations", isDirectory: true))

    func mailAttachmentRequest(reference: String, operation: String, hash: String, data: Data) async throws {
        let route = try CloudMailReference(value: reference)
        guard data.count <= 1024 * 1024, UUID(uuidString: operation) != nil,
              hash.count == 64, hash.allSatisfy({ $0.isASCII && "0123456789abcdef".contains($0) }),
              let requestSession = session, FeatureAccessStore.shared.mailContext == route.context else { throw GmailError.networkDisabled }
        try Task.checkCancellation()
        guard let answer = await send(.mailAttachment(email: route.email, operation: operation, hash: hash, data: data)) else { throw GmailError.unknownOutcome }
        guard session == requestSession, FeatureAccessStore.shared.mailContext == route.context else { throw GmailError.networkDisabled }
        guard answer.1 == 204 else { throw GmailDraftRejection(status: answer.1, body: answer.0) }
    }

    func mailDraftRequest(reference: String, body: Data) async throws -> Data {
        let route = try CloudMailReference(value: reference)
        let request = try JSONDecoder().decode(GmailDraftMutation.self, from: body)
        guard request.email.lowercased() == route.email,
              let requestSession = session, FeatureAccessStore.shared.mailContext == route.context else {
            throw GmailError.networkDisabled
        }
        try Task.checkCancellation()
        guard let answer = await send(.mailDraft(body)) else { throw GmailError.unknownOutcome }
        guard session == requestSession, FeatureAccessStore.shared.mailContext == route.context else {
            throw GmailError.networkDisabled
        }
        guard (200..<300).contains(answer.1) else {
            throw GmailDraftRejection(status: answer.1, body: answer.0)
        }
        return answer.0
    }

    /// The shared cloud mailbox's feed or catch-up check (`kind` "feed" or "check"); its status is the caller's.
    func mailFeedRequest(kind: String, reference: String, body: Data) async throws -> (Data, Int) {
        let route = try CloudMailReference(value: reference)
        guard let requestSession = session, FeatureAccessStore.shared.mailContext == route.context,
              (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["email"] as? String == route.email else {
            throw GmailError.networkDisabled
        }
        try Task.checkCancellation()
        let call: BananaService.Call = kind == "sender-policy" ? .mailSenderPolicy(body)
            : kind == "check" ? .mailCheck(body) : kind == "content" ? .mailContent(body) : .mailFeed(body)
        guard let answer = await send(call) else { throw GmailError.unknownOutcome }
        guard session == requestSession, FeatureAccessStore.shared.mailContext == route.context else { throw GmailError.networkDisabled }
        return answer
    }

    /// Sender images, for `MailSenderImages`: never the account's state, never a sign-out. Nil
    /// when there is no session or Mail is not allowed here, or the service could not be reached.
    func senderImagesRequest(_ call: BananaService.Call) async -> (Data, Int)? {
        guard let host = BananaService.host, let session, FeatureAccessStore.shared.allows("email") else { return nil }
        var request = BananaService.request(call, host: host, session: session)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func mailRequest(path: [String], reference: String, query: [URLQueryItem], method: String, body: Data?) async throws -> Data {
        let route = try CloudMailReference(value: reference)
        guard let requestSession = session, FeatureAccessStore.shared.mailContext == route.context else { throw GmailError.networkDisabled }
        let envelope = try CloudMailRequest.body(path: path, email: route.email, query: query, method: method, body: body)
        let ticket: CloudProviderOperationJournal.Ticket?
        if method == "GET" { ticket = nil }
        else {
            guard let operationContext = providerOperationContext else { throw GmailError.networkDisabled }
            ticket = try await Self.mailJournal.prepare(envelope: envelope, context: operationContext)
        }
        try Task.checkCancellation()
        guard session == requestSession, FeatureAccessStore.shared.mailContext == route.context else { throw GmailError.networkDisabled }
        let call: BananaService.Call = ticket.map { .mailOperation($0.body) } ?? .mailRead(envelope)
        // A change is only sent outside a pause; its journal entry is already saved, so it is not lost.
        if ticket != nil, let wait = operationPause() { throw GmailError.limited(.user, retryAfter: wait) }
        guard let answer = await send(call) else { throw GmailError.unknownOutcome }
        guard session == requestSession, FeatureAccessStore.shared.mailContext == route.context else { throw GmailError.networkDisabled }
        if ticket != nil { noteOperationAnswer(answer.1) }
        if (200..<300).contains(answer.1) {
            if let ticket { try? await Self.mailJournal.acknowledged(ticket) }
            return answer.0
        }
        if let ticket, CloudProviderOperationJournal.isTerminal(status: answer.1, response: answer.0, ticket: ticket) {
            try? await Self.mailJournal.acknowledged(ticket)
        }
        throw GmailHTTPRules.failure(status: answer.1, data: answer.0, retryAfter: nil)
    }
    #endif

    private static let calendarJournal = CloudProviderOperationJournal(
        directory: AppSupport.directory.appendingPathComponent("calendar-cloud-operations", isDirectory: true))

    static func requiresCloudCalendar(email: String) async throws -> Bool {
        guard let host = BananaService.host else { return false }
        return try await calendarJournal.requiresCloud(email: email, host: host)
    }

    func calendarOperation(url: URL, method: String, body: Data?, ifMatch: String?,
                           email: String, context: String) async throws -> (Data, Int) {
        try Task.checkCancellation()
        guard let requestSession = session, FeatureAccessStore.shared.calendarReadContext == context else {
            throw CloudCalendarSnapshot.Failure.contextChanged
        }
        guard let host = BananaService.host else { throw CloudCalendarSnapshot.Failure.unavailable }
        try await Self.calendarJournal.claim(email: email, host: host)
        guard let operationContext = providerOperationContext else { throw CloudCalendarSnapshot.Failure.contextChanged }
        let ticket = try await Self.calendarJournal.prepare(url: url, method: method, body: body,
            ifMatch: ifMatch, email: email, context: operationContext)
        try Task.checkCancellation()
        guard session == requestSession, FeatureAccessStore.shared.calendarReadContext == context else {
            throw CloudCalendarSnapshot.Failure.contextChanged
        }
        // The change is in its journal; it goes when the pause ends. Same as the service being unreachable.
        if operationPause() != nil { throw CloudCalendarSnapshot.Failure.unavailable }
        guard let answer = await send(.calendarOperation(ticket.body)) else {
            throw CloudCalendarSnapshot.Failure.unavailable
        }
        guard session == requestSession, FeatureAccessStore.shared.calendarReadContext == context else {
            throw CloudCalendarSnapshot.Failure.contextChanged
        }
        noteOperationAnswer(answer.1)
        if CloudProviderOperationJournal.isTerminal(status: answer.1, response: answer.0, ticket: ticket) {
            try? await Self.calendarJournal.acknowledged(ticket)
        }
        return answer
    }

    func calendarRead(url: URL, email: String, context: String) async throws -> (Data, Int) {
        try Task.checkCancellation()
        guard let requestSession = session, FeatureAccessStore.shared.calendarReadContext == context else {
            throw CloudCalendarSnapshot.Failure.contextChanged
        }
        guard let host = BananaService.host else { throw CloudCalendarSnapshot.Failure.unavailable }
        try await Self.calendarJournal.claim(email: email, host: host)
        guard session == requestSession, FeatureAccessStore.shared.calendarReadContext == context else {
            throw CloudCalendarSnapshot.Failure.contextChanged
        }
        let read = try CloudCalendarRequest(url: url, email: email)
        guard let answer = await send(.calendarRead(read)) else { throw CloudCalendarSnapshot.Failure.unavailable }
        try Task.checkCancellation()
        guard session == requestSession, FeatureAccessStore.shared.calendarReadContext == context else {
            throw CloudCalendarSnapshot.Failure.contextChanged
        }
        if (200..<300).contains(answer.1) {
            try GoogleCalendarService.shared.retireDirectAccessAfterCloudRead(email: email)
        }
        return answer
    }

    /// Read through the service's Google grant. This does not change native cache/write ownership.
    /// A response from an earlier session must never enter the current account's calendar.
    func calendarSnapshot(from: Date, to: Date) async throws -> CloudCalendarSnapshot {
        let bounds = try CloudCalendarSnapshot.bounds(from: from, to: to)
        guard let requestSession = session, let accountID = account?.id,
              FeatureAccessStore.shared.allows("calendarCloud") else { throw CloudCalendarSnapshot.Failure.unavailable }
        guard let (data, status) = await send(.calendarSnapshot(from: bounds.from, to: bounds.to)) else {
            throw CloudCalendarSnapshot.Failure.unavailable
        }
        guard session == requestSession, account?.id == accountID,
              FeatureAccessStore.shared.allows("calendarCloud") else { throw CloudCalendarSnapshot.Failure.contextChanged }
        guard status == 200 else { throw CloudCalendarSnapshot.Failure.unavailable }
        // Large weeks decode away from input/rendering. Recheck the session after suspension too.
        let result = try await Task.detached(priority: .userInitiated) {
            try CloudCalendarSnapshot.decode(data, from: bounds.from, to: bounds.to)
        }.value
        guard session == requestSession, account?.id == accountID,
              FeatureAccessStore.shared.allows("calendarCloud") else { throw CloudCalendarSnapshot.Failure.contextChanged }
        return result
    }

    /// An alert dismissed, opened or answered here: the other devices stop showing it.
    func clearAlert(_ id: String) async {
        guard isSignedIn else { return }
        _ = await send(.clearAlert(id: id, device: deviceID))
    }

    // MARK: - Plumbing

    private func keep(session new: String) {
        session = new
        FeatureAccessStore.shared.bind(session: new, host: BananaService.host)
        SyncedKeychain.write(Data(new.utf8), service: AppVariant.current.googleKeychainService,
                             account: Self.keychainAccount)
    }

    private var provingAgain = false

    /// The account was deleted (here, or on another device that told this one through the service):
    /// until the person signs in on purpose, the app doesn't sign in again by itself.
    private var deletedHere: Bool {
        get { defaults.bool(forKey: "bananaAccountDeleted") }
        set { defaults.set(newValue, forKey: "bananaAccountDeleted") }
    }

    /// The session ended while the account stays (its Google account was disconnected or refused,
    /// or its proof is old): sign in again at once, by identity, with a Google account still
    /// linked. Nothing on screen unless none can.
    private func proveAgain(after ended: String) {
        guard !provingAgain else { return }
        // Another device may have proven the account again already: its session is in the keychain.
        if let stored = SyncedKeychain.read(service: AppVariant.current.googleKeychainService, account: Self.keychainAccount,
                                            { String(data: $0, encoding: .utf8) }), stored != ended {
            session = stored
            FeatureAccessStore.shared.bind(session: stored, host: BananaService.host)
            return
        }
        provingAgain = true
        session = nil
        FeatureAccessStore.shared.bind(session: nil, host: BananaService.host)
        PlaybackDiagnostics.shared.log("☁️ account", "session ended: proving it again")
        Task { [weak self] in
            guard let self else { return }
            await self.signInByIdentity()
            self.provingAgain = false
            if self.isSignedIn { self.runPass(reason: "proved again") } else { self.signedOut() }
        }
    }

    private func signedOut() {
        session = nil
        FeatureAccessStore.shared.bind(session: nil, host: BananaService.host)
        account = nil
        pushRegistered = false
        registered = nil
        reportedHeld = nil
        reportedAlertSettings = nil
        SyncedKeychain.delete(service: AppVariant.current.googleKeychainService, account: Self.keychainAccount)
        defaults.removeObject(forKey: "bananaWatchLists")   // what build 56 kept; no longer used
        PlaybackDiagnostics.shared.log("☁️ account", "signed out")
    }

    #if BANANA_AI && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
    func desktopRelaySocket(link: String, hostChallenge: String? = nil) -> URLRequest? {
        guard let session, let host = BananaService.host,
              var url = URLComponents(string: host), url.scheme == "https" else { return nil }
        url.scheme = "wss"
        url.path = "/v1/desktop/" + link + (hostChallenge == nil ? "/client" : "/host")
        url.queryItems = hostChallenge.map { [URLQueryItem(name: "nonce", value: $0)] }
        guard let endpoint = url.url else { return nil }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + session, forHTTPHeaderField: "Authorization")
        return request
    }
    #endif

    /// One call. Nil when the service couldn't be reached. A 401 on a signed-in call means the
    /// account is gone (deleted on another device): this device signs out too.
    private func send(_ call: BananaService.Call) async -> (Data, Int)? {
        guard let host = BananaService.host else { return nil }
        let requestSession = session
        let request = BananaService.request(call, host: host, session: requestSession)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, let requestSession, session == requestSession, BananaService.failure(in: data) == "signed_out" {
                if BananaService.reproves(in: data) { proveAgain(after: requestSession) }
                else {
                    if BananaService.wasDeleted(in: data) { deletedHere = true }
                    signedOut()
                }
            }
            if status >= 400 {
                PlaybackDiagnostics.shared.log("☁️ account", "\(request.httpMethod ?? "") \(request.url?.path ?? "") answered \(status) \(BananaService.failureForLog(in: data) ?? "")")
            }
            return (data, status)
        } catch {
            transportFailed = true
            Self.log.error("service call failed: \(error.localizedDescription, privacy: .public)")
            PlaybackDiagnostics.shared.log("☁️ account", "\(request.httpMethod ?? "") \(request.url?.path ?? "") failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The session for other calls to the service (`Telemetry`).
    var authorization: String? { session }
}
