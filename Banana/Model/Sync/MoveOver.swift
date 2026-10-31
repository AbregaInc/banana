import Foundation

/// The move off iCloud on one device, for the account its mirror belongs to
/// (docs/design/DATA-PLATFORM.md §3 "Seeding", §8 steps 1–2 and the gate of step 4).
///
/// Each tier (personal data, health and food) goes through the same steps, on its own:
/// 1. **Covered.** Nothing happens until every type the tier's legacy channels carry has an
///    adapter registered with the engine: a channel that stopped writing iCloud with nothing to
///    take its place would stop that data moving at all. (With no adapters, as in Stage C0, nothing
///    ever moves.)
/// 2. **The hub first.** A spoke (iPad, Mac) waits until `/v1/account` says the account's iPhone
///    has seeded some of the tier's types, or that there's no iPhone active in 30 days. Like every
///    device on this build, it is read-only meanwhile (`LegacyCloudModeStore`: no iCloud without a
///    bound account, then the floor): its edits stay in its stores and its deletes are held
///    (`hold`), for its seed. Health and food without the Health consent don't wait: nothing of
///    theirs is seeded, so there's nothing to wait for.
/// 3. **Drain.** Every channel of the tier fetches to the end (`LegacyChannel.drainToEnd`). In the
///    rare install that still writes iCloud, it sends what waits first. Its result (deletes not
///    sent, items deleted elsewhere) is kept before anything else changes.
/// 4. **Read-only, drop, seed.** The tier's channels are (or go) `readOnly`; the items deleted elsewhere
///    while this device wasn't looking (`DrainResult.absent`) leave the stores through their
///    adapter's `remove`; then the engine seeds the tier's types. Read-only comes before the drop
///    so a store's own delete path can't reach iCloud.
///    **Health and food never stay in iCloud** on this build (§7): without the Health consent
///    (declined or not yet answered) the tier still drains and goes `readOnly`, and is `held`:
///    nothing is seeded, its data stays on the device, and late arrivals stay there too. Once the
///    consent is given (`grantHealthConsent`) it seeds as above.
/// 5. **Deletes still waiting** (the drain's `pendingDeletes`, and every delete made here before the
///    flip, `hold`) are deleted in the space once the seed's pass has pulled, at every step until
///    the flip: if another device's seed brought the item back, it goes again.
/// 6. **Flip.** Once no record of the seed waits for an answer (one refused for good stays here), the
///    tier is flipped: its channels stay `readOnly` for late arrivals from old builds, which enter
///    the mirror with their seed clocks (`arrived`). The device reports `seededAt` at its first
///    flip, and `flippedAt` once no tier of it writes iCloud any more (a held tier doesn't), so a
///    declined consent doesn't hold the purge gate (§8.4).
/// 7. **Off** once `/v1/account` says every device active in 30 days has flipped, or 30 days
///    after the tier stopped writing. Once a tier has moved it never writes iCloud again on this
///    device, whatever account comes next (`LegacyCloudModeStore`'s floor).
///
/// The purge (§8 step 4) is `ICloudPurge`: after each step, `purgeIfAsked` hands it the account's
/// `icloud` and this state, and it decides (its gate, once a launch, weekly).
///
/// Off only with `--no-space-sync` (`SpaceSyncFlag`; `SpaceSyncLaunch` makes it).
@MainActor
final class MoveOver {
    /// What `/v1/account` says of the move (Service/src/sync-routes.js `syncSummary`).
    struct Account: Equatable, Sendable {
        /// Whether the account has an iPhone active in the last 30 days. Nil: the service didn't
        /// say (an older one), so a spoke can't tell yet and waits.
        var hasIPhone: Bool?
        /// The types that iPhone has seeded (acknowledged).
        var seeded: Set<String> = []
        /// Every device active in 30 days has flipped.
        var allFlipped = false
        /// `purge` or `keep`.
        var icloud: String?

        init(hasIPhone: Bool?, seeded: Set<String> = [], allFlipped: Bool = false, icloud: String? = nil) {
            self.hasIPhone = hasIPhone
            self.seeded = seeded
            self.allFlipped = allFlipped
            self.icloud = icloud
        }

        init(_ summary: BananaService.Account) {
            hasIPhone = summary.hasIPhone
            seeded = Set(summary.seeded ?? [])
            // "purge" needs every recent device seeded and flipped (and the account's yes).
            allFlipped = summary.flipped == true || summary.icloud == "purge"
            icloud = summary.icloud
        }

        var presence: SpaceSync.HubPresence {
            switch hasIPhone {
            case nil: .unknown
            case false?: .none
            case true?: .seeded(seeded)
            }
        }
    }

    enum Phase: String, Codable, Sendable {
        /// Legacy `readWrite`, as today: not covered, or waiting for the hub.
        case waiting
        /// Health and food without the Health consent: drained, `readOnly`, not seeded. The data
        /// stays on the device until the consent is given.
        case held
        /// Drained; `readOnly`; seeding, until the engine has the seed acknowledged.
        case seeding
        /// Seed acknowledged: no iCloud writes ever again; reading late arrivals.
        case flipped
        /// Done: the tier's channels neither read nor write.
        case off
    }

    struct TierState: Codable, Equatable, Sendable {
        var phase: Phase = .waiting
        /// When the tier stopped writing iCloud for good: the seed acknowledged, or held.
        var flippedAt: Date?
        /// When its seed was acknowledged.
        var seededAt: Date?
        /// Deletes the drain couldn't send (`DrainResult.pendingDeletes`), until the flip.
        var pendingDeletes: [String: Set<String>] = [:]
        /// Items deleted elsewhere (`DrainResult.absent`), kept until they're out of the stores.
        var absent: [String: Set<String>] = [:]
        /// A held tier's legacy readers are off (every device flipped, or 30 days).
        var readersOff = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .waiting
            flippedAt = try c.decodeIfPresent(Date.self, forKey: .flippedAt)
            seededAt = try c.decodeIfPresent(Date.self, forKey: .seededAt)
            pendingDeletes = try c.decodeIfPresent([String: Set<String>].self, forKey: .pendingDeletes) ?? [:]
            absent = try c.decodeIfPresent([String: Set<String>].self, forKey: .absent) ?? [:]
            readersOff = try c.decodeIfPresent(Bool.self, forKey: .readersOff) ?? false
        }
    }

    /// What was last said in `PUT /v2/devices/:id/sync-state`.
    struct Report: Codable, Equatable, Sendable {
        var seededAt: Date?
        var flippedAt: Date?
        var seeded: [String]
    }

    struct State: Codable, Equatable, Sendable {
        var personal = TierState()
        var health = TierState()
        /// The first pull answered whether this person is coming back (§6 "Returning person").
        var returningChecked = false
        var reported: Report?
        /// The most seed records seen waiting for an answer while a tier seeds: the "of" in the
        /// progress line. Nil once nothing seeds.
        var seedTotal: Int?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            personal = try c.decodeIfPresent(TierState.self, forKey: .personal) ?? TierState()
            health = try c.decodeIfPresent(TierState.self, forKey: .health) ?? TierState()
            returningChecked = try c.decodeIfPresent(Bool.self, forKey: .returningChecked) ?? false
            reported = try c.decodeIfPresent(Report.self, forKey: .reported)
            seedTotal = try c.decodeIfPresent(Int.self, forKey: .seedTotal)
        }

        subscript(tier: LegacyTier) -> TierState {
            get { tier == .personal ? personal : health }
            set { if tier == .personal { personal = newValue } else { health = newValue } }
        }
    }

    struct Dependencies {
        var engine: SpaceSync
        var isHub: Bool
        /// The legacy channels this process runs (`LegacyCloud.channels`).
        var channels: [any LegacyChannel]
        /// Every adapter registered with the engine (`SyncAdapters`).
        var adapters: [any RecordAdapter]
        var modes: LegacyCloudModeStore
        /// `/v1/account`, as fresh as `maxAge` asks; nil when it can't be had.
        var account: (_ maxAge: TimeInterval) async -> Account?
        var defaults: UserDefaults = .standard
        /// Where this account's progress is kept.
        var stateKey: String
        var now: () -> Date = { Date() }
        var log: (String) -> Void = { _ in }
        /// A new device's first pull found the space in use (§6): the same as
        /// `CloudBackup.onReturningUserDetected` today, onboarding done.
        var returningPerson: @MainActor () -> Void = { MoveOver.onReturningPerson?() }
        /// Background time for a step (on iOS, a background task): a drain goes on with the app in
        /// the background, a podcast playing. `expired` is called if the time runs out; what it
        /// returns lets go. Nil: none needed (the Mac, tests).
        var holdBackground: (@MainActor (_ name: String, _ expired: @escaping @MainActor () -> Void) -> @MainActor () -> Void)? = nil
        /// How long one channel's drain may take before the step gives up on it (it's tried again
        /// at the next step); a fetch stalled while the app was suspended mustn't hold the move.
        var drainTimeout: TimeInterval = 5 * 60
        /// The purge (`ICloudPurge.runIfDue`), after each step; nil: none (tests of the move).
        var purge: (@MainActor (Account, State) async -> Void)? = nil
    }

    /// What a returning person's device does (`BananaApp.wireUp` sets it: onboarding is done).
    static var onReturningPerson: (() -> Void)?

    // MARK: - The Health consent (§7), for Stage C's screen and switch

    /// Hears the Health consent change, as the engine learns it: given or withdrawn here, or by an
    /// answer from the service (another device's yes or withdrawal).
    static var onHealthConsentChanged: ((Bool) -> Void)?

    /// The person said yes and the service has it (`PUT /v2/consents/health` answered): health and
    /// food now seed. Send it to the service first, then call this.
    static func grantHealthConsent() async {
        guard let current else { return }
        await current.deps.engine.setHealthConsent(true)
        await current.advance()
    }

    /// The person withdrew it and the service has it (`DELETE /v2/consents/health` answered):
    /// health and food stop leaving this device and leave the mirror; the stores keep them.
    static func withdrawHealthConsent() async {
        guard let current else { return }
        let engine = current.deps.engine
        await engine.setHealthConsent(false)
        await engine.consentWithdrawalConfirmed()
        await current.advance()
    }

    /// How long a flipped tier keeps reading late arrivals when not every device has flipped.
    static let drainWindow: TimeInterval = 30 * 86_400

    /// The move under way in this process, for the hooks below.
    private(set) static var current: MoveOver?

    let deps: Dependencies
    private(set) var state: State
    private var running = false
    private var again = false

    init(_ deps: Dependencies) {
        self.deps = deps
        state = deps.defaults.data(forKey: deps.stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    static func stateKey(account: String) -> String { "moveOver.\(account)" }

    /// Becomes the process's move, hears the engine (seed acknowledged, the consent: unless
    /// `listening` is false, for tests that take every step themselves), and takes its first step.
    func start(listening: Bool = true) async {
        Self.current = self
        if listening {
            await deps.engine.setSeedAcknowledgedHandler { [weak self] in await self?.kick() }
            await deps.engine.setHealthConsentHandler { [weak self] granted in await self?.consentChanged(granted) }
        }
        await advance()
    }

    /// No longer this process's move (signed out, another account).
    func stop() {
        if Self.current === self {
            Self.current = nil
            Self.progress.publish(nil)
        }
    }

    func kick() { Task { await advance() } }

    private func consentChanged(_ granted: Bool) {
        Self.onHealthConsentChanged?(granted)
        kick()
    }

    /// One step of the sequence, as far as it can go now. Idempotent; calls that come while one
    /// runs share the next.
    func advance() async {
        guard !running else { again = true; return }
        running = true
        LegacyCloud.drainExpired = false
        let letGo = deps.holdBackground?("move over") { [weak self] in
            LegacyCloud.drainExpired = true
            self?.log("background time ran out: a drain under way stops, and goes again at the next step")
        }
        defer {
            letGo?()
            LegacyCloud.drainExpired = false
            running = false
        }
        var rounds = 0
        repeat {
            again = false
            await step()
            rounds += 1
        } while again && rounds < 3
        refreshProgress()
    }

    struct DrainTimedOut: Error {}

    /// One channel's drain, logged with what it found and how long it took, and given up on after
    /// `drainTimeout` (a late answer is let go).
    private func drain(_ channel: any LegacyChannel, _ tier: LegacyTier) async throws -> DrainResult {
        let began = Date()
        log("\(tier.rawValue): \(channel.name) drain started")
        reading[tier] = channel.name
        refreshProgress()
        do {
            let result = try await withTimeLimit(deps.drainTimeout) { try await channel.drainToEnd() }
            let count = { (part: [String: Set<String>]) in part.values.reduce(0) { $0 + $1.count } }
            reading[tier] = nil
            log("\(tier.rawValue): \(channel.name) drained in \(String(format: "%.1f", Date().timeIntervalSince(began))) s: "
                + "\(count(result.dirty)) edited, \(count(result.pendingDeletes)) deleted here, \(count(result.absent)) gone elsewhere")
            return result
        } catch {
            log("\(tier.rawValue): \(channel.name) didn't drain after \(String(format: "%.1f", Date().timeIntervalSince(began))) s, "
                + "trying again at the next step: \(error)")
            throw error
        }
    }

    private func withTimeLimit<T>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            let timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { once.resume(.failure(DrainTimedOut())) }
            }
            Task { @MainActor in
                do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
                timer.cancel()
            }
        }
    }

    // MARK: - The steps

    /// How fresh `/v1/account` must be for the next step: a minute while a seed waits to be
    /// acknowledged, ten while a spoke waits for the iPhone's seed, else a few hours.
    private var accountAge: TimeInterval {
        if LegacyTier.allCases.contains(where: { state[$0].phase == .seeding }) { return 60 }
        if !waitingForHub.isEmpty { return 10 * 60 }
        return 6 * 3_600
    }
    /// The tiers that waited for the iPhone at the last step.
    private var waitingForHub: Set<LegacyTier> = []

    private func step() async {
        // A minute's answer while something is still to do; otherwise a few hours'.
        guard let account = await deps.account(accountAge) else {
            logOnce("waiting for /v1/account")
            return
        }
        await deps.engine.setHubPresence(account.presence)
        if !state.returningChecked {
            guard await checkReturning() else { return }
        }
        let consent = await deps.engine.healthConsent
        for tier in LegacyTier.allCases {
            await step(tier, account: account, consent: consent)
            refreshProgress()
        }
        await report()
        await purgeIfAsked(account)
    }

    private func step(_ tier: LegacyTier, account: Account, consent: Bool) async {
        let types = tierTypes(tier)
        // Health and food seed only with the Health consent; without it they still leave iCloud.
        let seeds = tier != .health || consent
        if state[tier].phase == .waiting {
            guard covered(types) else { return }
            if seeds { guard mayStartBeforeHub(tier, types: types, account: account) else { return } }
            var drained = DrainResult()
            for channel in channels(tier) {
                do {
                    drained.merge(try await drain(channel, tier))
                } catch {
                    return   // logged; the next step (a pass, the foreground, a push, a refresh) tries again
                }
            }
            drained = drained.only(types)
            reading[tier] = nil
            // Kept before anything changes: a tier past this point never drains again, so a crash
            // can't leave a later drain judging items made here while read-only.
            state[tier].phase = seeds ? .seeding : .held
            if !seeds { state[tier].flippedAt = deps.now() }
            for (type, ids) in drained.pendingDeletes { state[tier].pendingDeletes[type, default: []].formUnion(ids) }
            state[tier].absent = drained.absent
            save()
            for channel in channels(tier) { channel.drainKept() }
            log(seeds ? "\(tier.rawValue): drained, read-only; seeding \(types.count) type(s)"
                      : "\(tier.rawValue): drained, read-only; no Health consent, so it stays on this device")
        }
        // Past the drain (now, or before a relaunch): read-only, nothing deleted elsewhere left here.
        if state[tier].phase != .waiting {
            if deps.modes.mode(tier) == .readWrite { setMode(.readOnly, tier) }
            if (state[tier].phase == .off || state[tier].readersOff), deps.modes.mode(tier) != .off { setMode(.off, tier) }
            if !state[tier].absent.isEmpty {
                dropBeforeSeed(state[tier].absent)
                state[tier].absent = [:]
                save()
            }
        }
        if state[tier].phase == .held {
            if consent {
                // The engine waits for the iPhone's seed, type by type, on a spoke.
                state[tier].phase = .seeding
                save()
                log("\(tier.rawValue): the Health consent is given; seeding \(types.count) type(s)")
            } else {
                if !state[tier].readersOff, readersMayStop(tier, account: account) {
                    setMode(.off, tier)
                    state[tier].readersOff = true
                    save()
                    log("\(tier.rawValue): legacy readers off")
                }
                return
            }
        }
        if state[tier].phase == .seeding, !seeds {
            // The Health consent was withdrawn before the seed was acknowledged: health and food
            // stay on this device, and as nothing of them writes iCloud, the tier stopped writing now.
            state[tier].phase = .held
            state[tier].flippedAt = deps.now()
            save()
            log("\(tier.rawValue): the Health consent was withdrawn while seeding; it stays on this device")
            return
        }
        if state[tier].phase == .seeding {
            // Asked once; again after a relaunch that came before the engine kept the wish.
            let status = await deps.engine.status()
            let asked = status.seeded.union(status.waitingToSeed).union(status.awaitingPhoneSet)
            if !types.isSubset(of: asked) { await deps.engine.seed(types: types.subtracting(asked).sorted()) }
            await sendPendingDeletes(tier)
            if !(await acknowledged(types)) {
                await deps.engine.syncNow(reason: "move over")
                guard await acknowledged(types) else { return }
            }
            let now = deps.now()
            state[tier].phase = state[tier].readersOff ? .off : .flipped
            state[tier].seededAt = now
            state[tier].flippedAt = state[tier].flippedAt ?? now
            state[tier].pendingDeletes = [:]
            save()
            log("\(tier.rawValue): seed acknowledged; this device no longer writes it to iCloud")
        }
        if state[tier].phase == .flipped, readersMayStop(tier, account: account) {
            setMode(.off, tier)
            state[tier].phase = .off
            save()
            log("\(tier.rawValue): legacy readers off (\(account.allFlipped ? "every device flipped" : "30 days since the flip"))")
        }
    }

    /// Every device active in 30 days has flipped, or 30 days have passed since this tier stopped
    /// writing iCloud.
    private func readersMayStop(_ tier: LegacyTier, account: Account) -> Bool {
        guard let flippedAt = state[tier].flippedAt else { return false }
        return account.allFlipped || deps.now().timeIntervalSince(flippedAt) >= Self.drainWindow
    }

    private func covered(_ types: Set<String>) -> Bool {
        !types.isEmpty && types.isSubset(of: registeredTypes)
    }

    private func mayStartBeforeHub(_ tier: LegacyTier, types: Set<String>, account: Account) -> Bool {
        let may: Bool
        if deps.isHub {
            may = true
        } else {
            switch account.presence {
            case .unknown:
                may = false
            case .none:
                may = true
            case .seeded(let seeded):
                may = !seeded.isDisjoint(with: types)
                if !may { logOnce("\(tier.rawValue): waiting for the iPhone's seed") }
            }
        }
        if may { waitingForHub.remove(tier) } else { waitingForHub.insert(tier) }
        return may
    }

    /// Every type of the tier seeded here, and no record of any seed still waiting for an answer.
    /// A record the service refused for good doesn't hold the flip: it stays on this device, the
    /// report leaves its type out and `seededAt` waits (`report`), so the purge does too.
    private func acknowledged(_ types: Set<String>) async -> Bool {
        let status = await deps.engine.status()
        guard types.isSubset(of: status.seeded), status.waitingToSeed.isDisjoint(with: types) else { return false }
        guard let counts = try? deps.engine.mirror.read({ try $0.seedCounts() }) else { return false }
        return counts.waiting == 0
    }

    /// Types with a record of the seed the service refused for good.
    private func refusedTypes() -> Set<String> {
        (try? deps.engine.mirror.read { try $0.refusedSeedTypes() }) ?? []
    }

    /// Items deleted elsewhere before this device fetched (§3 seeding rule 1): out of the stores
    /// before the seed reads them. The tier is `readOnly` by now, so nothing reaches iCloud.
    private func dropBeforeSeed(_ absent: [String: Set<String>]) {
        for (type, ids) in absent.sorted(by: { $0.key < $1.key }) {
            guard let adapter = adapter(for: type) else { continue }
            let here = Set(adapter.snapshot(type).keys).intersection(ids)
            guard !here.isEmpty else { continue }
            adapter.remove(type, ids: here.sorted())
            log("\(type): dropped \(here.count) item(s) deleted elsewhere before the seed")
        }
    }

    /// Deletes made here that iCloud never got: deleted in the space, and again from the store
    /// if another device's seed brought them back. Until the flip, at every step.
    private func sendPendingDeletes(_ tier: LegacyTier) async {
        let pending = state[tier].pendingDeletes
        guard !pending.isEmpty else { return }
        for (type, ids) in pending.sorted(by: { $0.key < $1.key }) {
            guard let adapter = adapter(for: type) else { continue }
            let back = Set(adapter.snapshot(type).keys).intersection(ids)
            if !back.isEmpty { adapter.remove(type, ids: back.sorted()) }
            deps.engine.deleted(type: type, ids: ids.sorted())
        }
        await deps.engine.syncNow(reason: "deletes from before the move")
    }

    /// §6: a new device whose first pull finds the space in use belongs to someone coming back.
    /// False while the first pull hasn't been answered.
    private func checkReturning() async -> Bool {
        var status = await deps.engine.status()
        if status.epoch == nil {
            await deps.engine.syncNow(reason: "first pull")
            status = await deps.engine.status()
        }
        guard status.epoch != nil else { return false }   // no answer yet: offline
        state.returningChecked = true
        save()
        if status.cursor > 0, state.personal.phase == .waiting, state.health.phase == .waiting {
            log("the space already has data: someone coming back")
            deps.returningPerson()
        }
        return true
    }

    /// `PUT /v2/devices/:id/sync-state`, whenever what it would say changes:
    /// - `seeded`: the types seeded here and acknowledged, which spokes wait for; a type with a
    ///   record the service refused for good is left out;
    /// - `seededAt`: the first acknowledged seed, only while no record was refused (§8.4: the
    ///   purge gate needs every seed whole);
    /// - `flippedAt`: once no tier writes iCloud (each flipped, held or off). A tier still waiting
    ///   (not covered, or a spoke before the hub) still writes, so the purge gate stays shut.
    private func report() async {
        let seededTiers = LegacyTier.allCases.filter { state[$0].seededAt != nil }
        let noneWrites = LegacyTier.allCases.allSatisfy { tier in
            tierTypes(tier).isEmpty || [.flipped, .held, .off].contains(state[tier].phase)
        }
        guard !seededTiers.isEmpty || noneWrites else { return }
        let refused = refusedTypes()
        if !refused.isEmpty {
            logOnce("⚠️ the service refused records of \(refused.sorted().joined(separator: ", ")) for good: they stay on this device, and the purge waits")
        }
        let status = await deps.engine.status()
        let seeded = seededTiers.flatMap { tierTypes($0) }.filter { status.seeded.contains($0) && !refused.contains($0) }
        let first = seededTiers.compactMap { state[$0].seededAt }.min()
        let next = Report(seededAt: refused.isEmpty ? first : nil,
                          flippedAt: noneWrites ? LegacyTier.allCases.compactMap { state[$0].flippedAt }.max() : nil,
                          seeded: Array(Set(seeded)).sorted())
        guard next != state.reported else { return }
        do {
            try await deps.engine.transport.reportSyncState(device: deps.engine.config.device, seededAt: next.seededAt,
                                                            flippedAt: next.flippedAt, seeded: next.seeded)
            state.reported = next
            save()
            log("reported: \(next.seeded.count) type(s) seeded\(next.seededAt == nil ? " (not whole)" : "")\(next.flippedAt != nil ? ", flipped" : "")")
        } catch {
            log("couldn't report the move, trying again later: \(error)")
        }
    }

    /// §8 step 4: when `/v1/account` says `"icloud": "purge"`, `ICloudPurge` deletes everything
    /// Banana left in iCloud (behind its own gate), and again every week while the flag stands.
    func purgeIfAsked(_ account: Account) async {
        guard account.icloud == "purge", let purge = deps.purge else { return }
        await purge(account, state)
    }

    // MARK: - Hooks for the adapters

    /// A legacy channel applied these items after the seed (§3 seeding rule 6): they enter the
    /// mirror with their seed clocks, never a fresh one. Before the tier has seeded they're
    /// ignored, as the seed reads the store whole; once it's off nothing arrives.
    static func arrived(type: String, ids: [String]) {
        guard let current, !ids.isEmpty else { return }
        switch current.state[LegacyTier(type: type)].phase {
        case .seeding, .flipped:
            let engine = current.deps.engine
            Task { await engine.seedArrived(type: type, ids: ids) }
        case .waiting, .held, .off:
            break   // held: no consent, so late arrivals stay on this device
        }
    }

    /// What a store reports of its items, for the engine: this device's edit, or, while a legacy
    /// channel applies what it fetched, a late arrival (`LegacyCloud.isApplyingFromCloud`).
    /// Adapters call these from the stores' reports instead of the engine's own.
    static func changed(type: String, ids: [String]) {
        let (arriving, own) = split(type, ids)
        arrived(type: type, ids: arriving)
        guard !own.isEmpty else { return }
        current?.unhold(type, own)
        current?.deps.engine.changed(type: type, ids: own)
    }

    static func offered(type: String, ids: [String]) {
        let (arriving, own) = split(type, ids)
        arrived(type: type, ids: arriving)
        guard !own.isEmpty else { return }
        current?.unhold(type, own)
        current?.deps.engine.offered(type: type, ids: own)
    }

    /// The ids a legacy channel is applying now, and the rest (this device's own).
    private static func split(_ type: String, _ ids: [String]) -> (arriving: [String], own: [String]) {
        guard LegacyCloud.isApplyingFromCloud else { return ([], ids) }
        var arriving: [String] = [], own: [String] = []
        for id in ids {
            if LegacyCloud.isApplyingFromCloud(type: type, id: id) { arriving.append(id) } else { own.append(id) }
        }
        return (arriving, own)
    }

    /// A delete a legacy channel applied is not sent: the engine has no delete at a given clock,
    /// and a fresh one would outrank later edits made elsewhere. The space keeps the item.
    /// Never an arrival: this device's delete goes to the space; one a legacy channel applies
    /// (an old build's, §8 step 2) stays here.
    static func deleted(type: String, ids: [String]) {
        let (legacy, own) = split(type, ids)
        if !legacy.isEmpty { current?.log("\(type): \(legacy.count) delete(s) from an old build not carried to the space") }
        guard !own.isEmpty else { return }
        current?.hold(type, own)
        current?.deps.engine.deleted(type: type, ids: own)
    }

    /// This device's deletes until its tier flips: kept in the move's state, so neither the wait
    /// for the iPhone nor a relaunch before the seed loses them (the engine keeps a type's edits
    /// in memory until it seeds), and sent again after the seed (`sendPendingDeletes`).
    private func hold(_ type: String, _ ids: [String]) {
        let tier = LegacyTier(type: type)
        guard [.waiting, .held, .seeding].contains(state[tier].phase), tierTypes(tier).contains(type) else { return }
        state[tier].pendingDeletes[type, default: []].formUnion(ids)
        save()
    }

    /// Made again here: a delete held for it no longer stands. Not for the echo of the engine
    /// handing a store a record from the space (`SpaceSync.isApplying`): that's no edit of this device's.
    private func unhold(_ type: String, _ ids: [String]) {
        let tier = LegacyTier(type: type)
        let engine = deps.engine
        let ids = ids.filter { !engine.isApplying(type: type, id: $0) }
        guard var held = state[tier].pendingDeletes[type], !held.isDisjoint(with: ids) else { return }
        held.subtract(ids)
        state[tier].pendingDeletes[type] = held.isEmpty ? nil : held
        save()
    }

    // MARK: - Progress (Settings › Banana account)

    /// Where the move stands on this device, for the one line under the account.
    struct Progress: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            /// A spoke waiting for the iPhone's seed.
            case waitingForIPhone
            /// A drain: what it reads, in plain words (`zone(forChannel:)`).
            case reading(String)
            /// The seed going up: records answered of all seeded.
            case uploading(done: Int, of: Int)
            /// Under way, nothing countable to say (a seed asked for, not yet sent).
            case moving
        }

        var stage: Stage

        /// The line itself: fewest words.
        func text(locale: Locale = .current) -> String {
            let lead = "Moving to Banana"
            switch stage {
            case .waitingForIPhone: return "\(lead) · waiting for your iPhone"
            case .reading(let zone): return "\(lead) · reading \(zone)"
            case .uploading(let done, let total):
                let number = { (n: Int) in n.formatted(.number.locale(locale)) }
                return "\(lead) · uploading \(number(done)) of \(number(total))"
            case .moving: return lead
            }
        }

        /// A legacy channel's data in plain words (`LegacyChannel.name`).
        static func zone(forChannel name: String) -> String {
            switch name {
            case "controls zone", "controls zone (health)": "plans"
            case "meals zone": "meals"
            case "wellness zone": "wellness"
            case "progress zone": "progress"
            case "fitness zone": "workouts"
            case "fitness zone (voice notes)", "iCloud Drive": "voice notes"
            case "settings zone", "key-value store", "key-value store (health)": "settings"
            default: "your data"
            }
        }
    }

    /// The line, published on the main actor at most once a second, for whichever move is this
    /// process's (`current`); nil when nothing moves (flipped, held, off, no account, the flag off).
    @MainActor
    final class ProgressModel: ObservableObject {
        @Published private(set) var value: Progress?
        /// The gap between two publishes.
        var interval: TimeInterval = 1
        private var lastPublished = Date.distantPast
        private var pending: Progress?
        private var scheduled: Task<Void, Never>?

        /// The line, or nil.
        var line: String? { value?.text() }

        func publish(_ next: Progress?) {
            pending = next
            guard scheduled == nil else { return }
            let wait = interval - Date().timeIntervalSince(lastPublished)
            guard wait > 0 else { apply(); return }
            scheduled = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.apply()
            }
        }

        private func apply() {
            scheduled = nil
            lastPublished = Date()
            guard value != pending else { return }
            #if os(iOS)
            // While the move runs, the screen stays on: iOS pauses a locked app within a minute,
            // and the move is the thing to finish.
            if value == nil, pending != nil { KeepAwake.acquire() }
            if value != nil, pending == nil { KeepAwake.release() }
            #endif
            value = pending
        }

        /// While a screen shows the line: the seed's counts are read again every second (they
        /// change with the engine's passes, not the move's steps). Nobody watching, nothing is read.
        func watch() async {
            while !Task.isCancelled {
                MoveOver.current?.refreshProgress()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    static let progress = ProgressModel()

    /// Where the move stands here now (also published, for this process's move).
    private(set) var progressNow: Progress?
    /// The channel each tier's drain is reading, or last stopped at (it goes again from there).
    private var reading: [LegacyTier: String] = [:]

    func refreshProgress() {
        progressNow = computeProgress()
        if Self.current === self { Self.progress.publish(progressNow) }
    }

    private func computeProgress() -> Progress? {
        let seeding = LegacyTier.allCases.contains { state[$0].phase == .seeding }
        if seeding {
            let waiting = (try? deps.engine.mirror.read { try $0.seedCounts() })?.waiting ?? 0
            if waiting > (state.seedTotal ?? 0) {
                state.seedTotal = waiting
                save()
            }
            let total = state.seedTotal ?? 0
            if waiting > 0, total > 0 { return Progress(stage: .uploading(done: total - waiting, of: total)) }
        } else if state.seedTotal != nil {
            state.seedTotal = nil
            save()
        }
        // A drain under way, or stopped part-way: the tier is still to drain.
        for tier in LegacyTier.allCases where state[tier].phase == .waiting {
            if let channel = reading[tier] { return Progress(stage: .reading(Progress.zone(forChannel: channel))) }
        }
        if seeding { return Progress(stage: .moving) }
        if !waitingForHub.isEmpty { return Progress(stage: .waitingForIPhone) }
        return nil
    }

    // MARK: - Plumbing

    private var registeredTypes: Set<String> { Set(deps.adapters.flatMap(\.types)) }

    private func adapter(for type: String) -> (any RecordAdapter)? {
        deps.adapters.first { $0.types.contains(type) }
    }

    private func channels(_ tier: LegacyTier) -> [any LegacyChannel] {
        deps.channels.filter { $0.tier == tier }
    }

    func tierTypes(_ tier: LegacyTier) -> Set<String> {
        Set(channels(tier).flatMap(\.types))
    }

    private func setMode(_ mode: LegacyCloudMode, _ tier: LegacyTier) {
        deps.modes.set(mode, for: tier)
        for channel in channels(tier) { channel.setMode(mode) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { deps.defaults.set(data, forKey: deps.stateKey) }
    }

    private func log(_ line: String) { deps.log(line) }

    /// Lines said once a launch: a wait is checked every minute.
    private var said: Set<String> = []
    private func logOnce(_ line: String) {
        guard said.insert(line).inserted else { return }
        log(line)
    }
}

/// A continuation resumed once, whichever comes first.
@MainActor
private final class ResumeOnce<T> {
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// When the move gets a step with the app away from the front (docs/design/DATA-PLATFORM.md §8):
/// overnight with a podcast playing, the only other triggers are pushes and rare background
/// refreshes. Pure, for `SpaceSyncLaunch`.
enum MovePace {
    /// A step while playing, at most this often (the periodic calendar look while playing).
    static let whileAway: TimeInterval = 5 * 60

    static func stepDue(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= whileAway } ?? true
    }

    /// Whether a launch with no account published yet (a cold background launch: a push, a
    /// refresh) starts the engine for the account the mirror belongs to.
    static func startsWithoutAccountYet(flagOn: Bool, serviceAvailable: Bool, signedIn: Bool, bound: String?,
                                       engineRunning: Bool) -> Bool {
        flagOn && serviceAvailable && signedIn && bound != nil && !engineRunning
    }
}
