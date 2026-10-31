import Combine
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
    private var pass: Task<Void, Never>?
    private var passAgain: String?
    private var retry: Task<Void, Never>?
    private var keeping: Task<Void, Never>?
    /// A call didn't reach the service during the current pass.
    private var transportFailed = false

    private init() {
        session = SyncedKeychain.read(service: AppVariant.current.googleKeychainService,
                                      account: Self.keychainAccount) { String(data: $0, encoding: .utf8) }
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
        if !started {
            started = true
            // The Google accounts, their calendars, or the ones set not to count changed: join any
            // new account and bring the watches in line.
            watching = GoogleCalendarService.shared.$calendars.map { _ in () }
                .merge(with: SmartScheduleStore.shared.$settings.map(\.excludedCalendarIDs).removeDuplicates().map { _ in () })
                .debounce(for: .seconds(3), scheduler: RunLoop.main)
                .sink { [weak self] in self?.runPass(reason: "calendars changed") }
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
            if self.isSignedIn { await self.refresh() }     // which Google accounts are linked already
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
        let google = GoogleCalendarService.shared
        let linked = Set((account?.google ?? []).map { $0.email.lowercased() })
        let missing = BananaService.accountsToLink(connected: google.accounts.map(\.id), linked: linked, signedIn: isSignedIn)
        for email in missing {
            let idToken: String
            do { idToken = try await google.identityToken(forEmail: email) }
            catch {
                Self.log.error("no Google identity token for an account: \(error.localizedDescription, privacy: .public)")
                PlaybackDiagnostics.shared.log("☁️ account", "no identity token for a Google account: \(error.localizedDescription)")
                continue
            }
            guard case let (data, status)? = await send(.identity(idToken: idToken, device: device())) else { continue }
            if status == 200, let answer = try? JSONDecoder().decode(BananaService.SignInAnswer.self, from: data) {
                if let new = answer.session { keep(session: new) }
                account = answer.account
                lastError = nil
                PlaybackDiagnostics.shared.log("☁️ account", "joined: \(answer.account.google.count) Google account(s), \(answer.account.devices) device(s)")
            } else if status == 409 {
                lastError = "A Google account here belongs to another Banana account."
            } else {
                Self.log.error("identity sign-in for an account answered \(status, privacy: .public)")
            }
        }
    }

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
        case 409:
            lastError = "That Google account belongs to another Banana account."
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

    /// True when the service answered with the account.
    @discardableResult
    func refresh() async -> Bool {
        guard isSignedIn, case let (data, status)? = await send(.account) else { return false }
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
            signedOut()
            // The data platform's mirror of the deleted account goes with it.
            if let deleted { SpaceSyncLaunch.forget(account: deleted) }
            lastError = nil
            return true
        case 404, 409:
            lastError = "That Google account isn\u{2019}t part of this Banana account."
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
        PlaybackDiagnostics.shared.log("☁️ push", "token from Apple (\(Telemetry.channel == "dev" ? "development" : "production"))")
        Task { await registerDevice() }
    }

    private func registerDevice() async {
        guard isSignedIn else { return }
        let device = device()
        guard case let (_, status)? = await send(.device(device)) else { return }
        guard status == 204 else { return }
        pushRegistered = device.push != nil
        PlaybackDiagnostics.shared.log("☁️ account", "device registered, push \(device.push == nil ? "no" : "yes") (\(device.pushEnv))")
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

    private func device() -> BananaService.Device {
        BananaService.Device(id: deviceID, platform: Telemetry.platform, push: pushToken,
                             pushEnv: Telemetry.channel == "dev" ? "development" : "production",
                             bundle: Bundle.main.bundleIdentifier ?? "com.boris.banana")
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

    /// An alert dismissed, opened or answered here: the other devices stop showing it.
    func clearAlert(_ id: String) async {
        guard isSignedIn else { return }
        _ = await send(.clearAlert(id: id, device: deviceID))
    }

    // MARK: - Plumbing

    private func keep(session new: String) {
        session = new
        SyncedKeychain.write(Data(new.utf8), service: AppVariant.current.googleKeychainService,
                             account: Self.keychainAccount)
    }

    private func signedOut() {
        session = nil
        account = nil
        pushRegistered = false
        reportedHeld = nil
        reportedAlertSettings = nil
        SyncedKeychain.delete(service: AppVariant.current.googleKeychainService, account: Self.keychainAccount)
        defaults.removeObject(forKey: "bananaWatchLists")   // what build 56 kept; no longer used
        PlaybackDiagnostics.shared.log("☁️ account", "signed out")
    }

    /// One call. Nil when the service couldn't be reached. A 401 on a signed-in call means the
    /// account is gone (deleted on another device): this device signs out too.
    private func send(_ call: BananaService.Call) async -> (Data, Int)? {
        guard let host = BananaService.host else { return nil }
        let request = BananaService.request(call, host: host, session: session)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, BananaService.failure(in: data) == "signed_out" { signedOut() }
            if status >= 400 {
                PlaybackDiagnostics.shared.log("☁️ account", "\(request.httpMethod ?? "") \(request.url?.path ?? "") answered \(status) \(BananaService.failure(in: data) ?? "")")
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
