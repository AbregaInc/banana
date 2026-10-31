import Combine
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Starts the data platform's engine (docs/design/DATA-PLATFORM.md §6) for the signed-in account,
/// and runs it when it should: coming to the foreground, every minute while open (on the Mac,
/// also with no window), and on the service's `sync` push.
///
/// One account per install (§2): the engine and its mirror are bound to the first account they
/// start for. Signing out stops the engine and deletes nothing; another account signing in starts
/// nothing until the person says to clear this device first (Stage C asks); deleting the account
/// deletes its mirror.
///
/// Once the engine is up and the stores have loaded (`storesReady`), the adapters register
/// (`SyncAdapters`) and the move off iCloud runs (`MoveOver`), a step on every pass.
///
/// On in every build; off only with the launch argument `--no-space-sync` (`SpaceSyncFlag`).
@MainActor
enum SpaceSyncLaunch {
    private(set) static var engine: SpaceSync?
    private static var engineAccount: String?
    private static var starting: Task<Void, Never>?
    private static var watching: AnyCancellable?
    private static var ticking: Task<Void, Never>?
    private static var observers: [NSObjectProtocol] = []
    /// How often a pass runs while the app is open (this replaces `CloudSyncPoll`, in Stage E).
    static let tick: Duration = .seconds(60)
    /// The account this install's mirror belongs to.
    private static let boundKey = LegacyCloud.boundAccountKey
    /// The stores, once `wireUp` has loaded them all.
    private static var stores: SyncStores?
    private static var adapters: [any RecordAdapter]?
    private static var moveOver: MoveOver?
    private static var accountReadAt: Date?
    private static var startingToken: UUID?


    static var boundAccount: String? { UserDefaults.standard.string(forKey: boundKey) }

    static func startIfAsked() {
        guard SpaceSyncFlag.isOn, BananaService.isAvailable, watching == nil else { return }
        watching = BananaAccount.shared.$account.map { $0?.id }.removeDuplicates()
            .sink { accountSeen($0) }
        // A background launch (a push, a refresh) may come before the account is published: the
        // engine starts for the mirror's account now, so whatever woke the app can advance the move.
        Task { _ = await engineStarted() }
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                sync(reason: "foreground")
                startTicking()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { stopTicking() }
        })
        #elseif os(macOS)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sync(reason: "foreground") }
        })
        #endif
    }

    private static func accountSeen(_ id: String?) {
        guard let id else {
            // Signed out: the engine stops; the mirror stays, for when the same account comes back.
            stopEngine(reason: "signed out")
            return
        }
        if let bound = boundAccount, bound != id {
            accountChanged(from: bound, to: id)
            return
        }
        start(account: id)
    }

    /// Another Google account signed in on a device whose mirror is another account's: the engine
    /// stops, and nothing starts for the new account until this device's data is cleared.
    static func accountChanged(from old: String, to new: String) {
        stopEngine(reason: "another account signed in")
        PlaybackDiagnostics.shared.log("☁️ space", "another account signed in: nothing syncs until this device is cleared")
        // Asked once (DATA-PLATFORM.md §2): yes clears this device and syncs for `new`
        // (`clearDeviceThenStart`); no, or no answer yet, seeds and syncs nothing for it.
        SpaceSyncQuestions.shared.accountChanged(from: old, to: new)
    }

    /// The person said to clear this device for the account now signed in. In this order:
    /// 1. no tier writes iCloud any more (read-only, which the device's floor keeps for good), so
    ///    nothing the clear does reaches the other account's iCloud;
    /// 2. this device's data of the other account goes (`SyncAdapters.clearLocalData`: the stores'
    ///    adopt-from-cloud deletes and account-change resets, which tell no sync);
    /// 3. the old account's mirror goes, and the engine starts for `new`.
    /// Waits for the stores.
    static func clearDeviceThenStart(from old: String, to new: String) {
        guard BananaAccount.shared.account?.id == new else { return }   // signed out or changed again
        guard let stores else {
            pendingClear = (old, new)
            return
        }
        pendingClear = nil
        for tier in LegacyTier.allCases where LegacyCloud.mayWrite(tier) { LegacyCloud.set(.readOnly, for: tier) }
        Task { @MainActor in
            guard let cleared = await SyncAdapters.clearLocalData(stores) else {
                PlaybackDiagnostics.shared.log("☁️ space", "another account: iCloud still written here, so nothing was cleared and nothing syncs")
                return
            }
            PlaybackDiagnostics.shared.log("☁️ space", "cleared \(cleared) item(s) of the other account from this device")
            guard BananaAccount.shared.account?.id == new else { return }
            forget(account: old)
            start(account: new)
        }
    }

    /// A clear asked for before the stores had loaded.
    private static var pendingClear: (from: String, to: String)?

    /// After a pass: the health tier waiting for the Health consent here may ask for it.
    private static func askForConsentIfWaiting(_ move: MoveOver?) {
        guard let move, move.state.health.phase == .held else { return }
        SpaceSyncQuestions.shared.healthWaiting()
    }

    /// The account was deleted: its mirror goes, and this install belongs to no account. The
    /// engine stops and its file is closed before the file is deleted.
    static func forget(account: String) {
        let running = engineAccount == account ? engine : nil
        let opening = starting
        if engineAccount == account || boundAccount == account { stopEngine(reason: "account deleted") }
        if boundAccount == account {
            UserDefaults.standard.removeObject(forKey: boundKey)
            LegacyCloud.modes.bind(account: nil)
        }
        UserDefaults.standard.removeObject(forKey: MoveOver.stateKey(account: account))
        Task { @MainActor in
            await opening?.value   // a start under way lets go of its mirror first
            if let running {
                await running.stop()
                try? running.mirror.close()
            }
            let url = RecordMirror.url(account: account)
            var removed = false
            for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"] {
                if (try? FileManager.default.removeItem(atPath: path)) != nil { removed = true }
            }
            if removed { PlaybackDiagnostics.shared.log("☁️ space", "the deleted account's mirror is gone") }
        }
    }

    @discardableResult
    private static func start(account: String) -> Task<Void, Never>? {
        guard engine == nil, let host = BananaService.host else { return starting }
        if let starting { return starting }   // a cancelled start is let go of at once (`stopEngine`)
        UserDefaults.standard.set(account, forKey: boundKey)
        LegacyCloud.modes.bind(account: account)
        let device = BananaAccount.shared.deviceIdentifier
        let token = UUID()
        startingToken = token
        let task = Task { @MainActor in
            // Only this start's own: a newer one may have begun since this one was cancelled.
            defer { if startingToken == token { starting = nil; startingToken = nil } }
            do {
                // The mirror opens and migrates off the main thread.
                let built = try await Task.detached(priority: .utility) { () throws -> SpaceSync in
                    let catalog = try DataCatalog.bundled()
                    var config = SpaceSync.Configuration(device: device, isHub: DeviceRole.current.isHub, catalog: catalog)
                    config.log = { PlaybackDiagnostics.shared.log("☁️ space", $0) }
                    #if os(iOS)
                    // Every pass may finish in the background: a first seed's uploads take a while.
                    config.holdWhilePassing = { reason in
                        let task = await MainActor.run { BackgroundTask(named: "space-sync \(reason)") }
                        return { await MainActor.run { task.end() } }
                    }
                    #endif
                    let transport = HTTPSyncTransport(host: host, account: account, credentials: {
                        await MainActor.run { (BananaAccount.shared.authorization, BananaAccount.shared.account?.id) }
                    })
                    return try SpaceSync(mirror: RecordMirror(url: RecordMirror.url(account: account)),
                                         transport: transport, config: config)
                }.value
                guard !Task.isCancelled, boundAccount == account, startingToken == token else {
                    await built.stop()   // signed out, forgotten or another account while it opened
                    try? built.mirror.close()
                    return
                }
                engine = built
                engineAccount = account
                PlaybackDiagnostics.shared.log("☁️ space", "engine started (\(DeviceRole.current.name))")
                sync(reason: "start")
                startTicking()
                await attachStores()
            } catch {
                PlaybackDiagnostics.shared.log("☁️ space", "engine didn't start: \(error.localizedDescription)")
            }
        }
        starting = task
        return task
    }

    /// Every store has loaded (`BananaApp.wireUp`), and every legacy sync has started.
    static func storesReady(_ ready: SyncStores) {
        guard SpaceSyncFlag.isOn, stores == nil else { return }
        stores = ready
        LegacyCloud.registerChannels()
        if let pendingClear { return clearDeviceThenStart(from: pendingClear.from, to: pendingClear.to) }
        Task { await attachStores() }
    }

    /// With both the engine and the stores: the adapters join, then the move off iCloud starts.
    private static func attachStores() async {
        guard let engine, let account = engineAccount, let stores, adapters == nil else { return }
        await SyncAdapters.prepareEverythingElse()
        guard self.engine === engine, adapters == nil else { return }
        let joining = SyncAdapters.all(stores)
        adapters = joining
        for adapter in joining { await engine.registerAdapter(adapter) }
        guard self.engine === engine else { return }   // stopped meanwhile
        await seedNewTypes(engine, adapters: joining)
        var deps = MoveOver.Dependencies(
            engine: engine, isHub: DeviceRole.current.isHub, channels: LegacyCloud.channels, adapters: joining,
            modes: LegacyCloud.modes, account: { maxAge in await accountSummary(for: account, maxAge: maxAge) },
            stateKey: MoveOver.stateKey(account: account),
            log: { PlaybackDiagnostics.shared.log("☁️ move", $0) },
            purge: { [purge = ICloudPurge.live(account: account)] summary, state in
                await purge.runIfDue(ICloudPurge.Situation(asked: SpaceSyncFlag.isOn, icloud: summary.icloud, move: state))
            })
        #if os(iOS)
        // A step may run with the app in the background (a podcast playing): it holds background
        // time, and a drain stops only when that runs out.
        deps.holdBackground = { name, expired in
            let task = BackgroundTask(named: name, expired: expired)
            return { task.end() }
        }
        #endif
        let move = MoveOver(deps)
        moveOver = move
        PlaybackDiagnostics.shared.log("☁️ space", "\(joining.count) adapter(s) joined; the move off iCloud starts")
        SpaceSyncQuestions.shared.engineStarted(account: account, consent: await engine.healthConsent)
        await move.start()
        askForConsentIfWaiting(move)
    }

    /// Types no legacy channel ever carried (booking types) have nothing to move off iCloud, so
    /// `MoveOver` never seeds them: they are seeded here, once, as their adapter joins.
    private static func seedNewTypes(_ engine: SpaceSync, adapters: [any RecordAdapter]) async {
        let status = await engine.status()
        let registered = Set(adapters.flatMap(\.types))
        let fresh = LegacyInventory.withoutLegacy.filter {
            registered.contains($0) && !status.seeded.contains($0) && !status.waitingToSeed.contains($0)
                && !status.awaitingPhoneSet.contains($0)
        }
        guard !fresh.isEmpty else { return }
        PlaybackDiagnostics.shared.log("☁️ space", "seeding \(fresh.sorted().joined(separator: ", ")), which never lived in iCloud")
        await engine.seed(types: fresh.sorted())
    }

    /// `/v1/account`, read again when older than `maxAge`; nil unless it's the mirror's account.
    private static func accountSummary(for account: String, maxAge: TimeInterval) async -> MoveOver.Account? {
        if BananaAccount.shared.account == nil || accountReadAt.map({ Date().timeIntervalSince($0) >= maxAge }) ?? true {
            // Only an answer counts as read: a failed ask is asked again at the next step.
            if await BananaAccount.shared.refresh() { accountReadAt = Date() }
        }
        guard let summary = BananaAccount.shared.account, summary.id == account else { return nil }
        return MoveOver.Account(summary)
    }

    private static func stopEngine(reason: String) {
        SpaceSyncQuestions.shared.engineStopped()
        moveOver?.stop()
        moveOver = nil
        adapters = nil
        stopTicking()
        starting?.cancel()
        // Let go of it now: a start asked for before its task ends begins afresh.
        starting = nil
        startingToken = nil
        if let engine {
            Task { await engine.stop() }
            PlaybackDiagnostics.shared.log("☁️ space", "engine stopped: \(reason)")
        }
        engine = nil
        engineAccount = nil
    }

    static func sync(reason: String) {
        Task {
            // A cold background launch (a refresh) may not have the engine up yet.
            guard let engine = await engineStarted() else { return }
            let move = moveOver
            await engine.syncNow(reason: reason)
            await move?.advance()
            askForConsentIfWaiting(move)
        }
    }

    private static var lastStepAway: Date?

    /// The periodic look while a podcast plays with the app away from the front: a pass and a
    /// move step, at most every five minutes (`MovePace`); the move's own guard keeps steps apart.
    static func stepWhileAway(now: Date = Date()) {
        guard MovePace.stepDue(last: lastStepAway, now: now) else { return }
        lastStepAway = now
        sync(reason: "while playing")
    }

    /// The engine, started first if this launch hasn't yet (a push or a refresh in a cold
    /// background launch, before the account is published): for the account the mirror belongs to,
    /// once the service confirms it's still the one signed in.
    private static func engineStarted() async -> SpaceSync? {
        if MovePace.startsWithoutAccountYet(flagOn: SpaceSyncFlag.isOn, serviceAvailable: BananaService.isAvailable,
                                            signedIn: BananaAccount.shared.isSignedIn, bound: boundAccount,
                                            engineRunning: engine != nil), let bound = boundAccount {
            if BananaAccount.shared.account == nil { await BananaAccount.shared.refresh() }
            if BananaAccount.shared.account?.id == bound { await start(account: bound)?.value }
        }
        await starting?.value
        return engine
    }

    /// Records of these types that waited for something to arrive are offered to their stores
    /// again (§5): episodes came in, so progress and show settings held for them can go in now.
    static func replay(types: [String]) {
        guard let engine, adapters != nil else { return }
        Task { await engine.replay(types: types) }
    }

    /// A lazy blob, fetched on first use (§3): true once the store has it. False with no engine,
    /// no record, or no answer.
    static func ensureBlob(type: String, id: String, field: String) async -> Bool {
        guard let engine, adapters != nil else { return false }
        return await engine.ensureBlob(type: type, id: id, field: field)
    }

    /// The service's `sync` push. On a cold launch the engine may not be up yet: with a session in
    /// the keychain, the account is read once to make sure it's still the mirror's, and the engine
    /// starts and runs. False when there's no engine to run.
    static func handlePush() async -> Bool {
        guard let engine = await engineStarted() else { return false }
        await engine.syncNow(reason: "push")
        await moveOver?.advance()   // a drain that waited goes again now
        return true
    }

    #if os(iOS)
    /// iOS gives a background push about 30 s. The completion goes at the pass's end or after 25 s,
    /// whichever comes first; the pass goes on under a background task either way.
    static func handlePush(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        let finish = PushCompletion(completion)
        let background = BackgroundTask(named: "space-sync")
        Task { @MainActor in
            let ran = await handlePush()
            finish.call(ran ? .newData : .noData)
            background.end()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            finish.call(.newData)
        }
    }
    #endif

    private static func startTicking() {
        guard ticking == nil, engine != nil else { return }
        ticking = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled else { return }
                sync(reason: "tick")
            }
        }
    }

    private static func stopTicking() {
        ticking?.cancel()
        ticking = nil
    }
}

#if os(iOS)
/// A push's completion, called once.
@MainActor
private final class PushCompletion {
    private var completion: ((UIBackgroundFetchResult) -> Void)?
    init(_ completion: @escaping (UIBackgroundFetchResult) -> Void) { self.completion = completion }

    func call(_ result: UIBackgroundFetchResult) {
        completion?(result)
        completion = nil
    }
}

/// Background time for a pass that outlives the push's completion.
@MainActor
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    /// `expired`: told when iOS takes the time back, before it's let go.
    init(named name: String, expired: (@MainActor () -> Void)? = nil) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                expired?()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
