#if !BANANA_PUBLIC
import Foundation
import GRDB

/// Production data adapter under integration. Normal app wiring follows conversation/action
/// coverage; unsupported protocol members still use the explicit not-yet diagnostics.
@MainActor final class MailLiveSource: MailSource {
    private final class Sink: MailChangeSink, @unchecked Sendable {
        let deliver: @Sendable (MailStoreChange) -> Void
        init(_ deliver: @escaping @Sendable (MailStoreChange) -> Void) { self.deliver = deliver }
        func committed(_ change: MailStoreChange) { deliver(change) }
    }
    private struct Subscription {
        var scope: MailScope
        var limit: Int
        var callback: @MainActor (MailListSnapshot) -> Void
        var task: Task<Void, Never>?
        var last: MailListSnapshot?
    }
    private struct ConversationSubscription {
        var id: MailConversationID
        var callback: @MainActor (MailConversation?) -> Void
        var task: Task<Void, Never>?
        var last: MailConversation?
        var delivered = false
    }
    private var conversationSubscriptions: [UUID: ConversationSubscription] = [:]
    let stores: MailStores
    let access: any MailAccountAccess
    let api: any GmailAPI
    var reportReadFailure: (String) -> Void = { _ in }
    private lazy var writer = MailWriter(stores: stores, sink: Sink { [weak self] change in
        Task { @MainActor in self?.committed(change) }
    })
    private lazy var loader = GmailPageLoader(api: api, writer: writer) { [access] account in
        try await access.mailAccessToken(accountID: account).value
    }
    private lazy var conversationLoader = GmailConversationLoader(stores: stores, writer: writer, api: api) { [access] account in
        try await access.mailAccessToken(accountID: account).value
    }
    private enum Download: Hashable {
        case thread(MailConversationID), body(MailMessageID)
        var account: String {
            switch self { case .thread(let id): return id.account; case .body(let id): return id.account }
        }
    }
    private var downloadQueue: [Download] = []
    private var downloads: [Download: Task<Void, Never>] = [:]
    /// Content from Banana Cloud in bulk (MAIL-CLOUD-SYNC §5a); nil without a cloud feed.
    /// Whether local CPU work may run now, and how fast (invariant 31).
    let paceGauge = MailPaceGauge()
    private lazy var cloudPull: MailCloudPull? = cloudFeed.map { [paceGauge] in
        MailCloudPull(stores: stores, loader: conversationLoader, source: $0, pace: { paceGauge.pace() })
    }
    /// Re-prepares stored originals whose prepared body is missing or stale, newest first.
    private lazy var reprepare = MailReprepare(stores: stores, loader: conversationLoader, pace: { [paceGauge] in paceGauge.pace() })
    private var reprepareTask: Task<Void, Never>?
    private var reprepareToken = UUID()
    private var cloudToken = UUID()
    /// What the open path had to prepare because nothing prepared was here (tests, diagnostics).
    func preparationCounts() async -> (onRequest: Int, ahead: Int) {
        (await conversationLoader.preparedOnRequest, await conversationLoader.preparedAhead)
    }
    private var cloudTask: Task<Void, Never>?
    private var screenWork: Task<Void, Never>?
    private var pushCatchUp = 0
    let status = MailStatus(MailNotYet.emptyStatus)
    let badges = MailBadges(MailBadgeCounts(unreadInFirstSplit: 0, needsAnswer: 0))
    private var subscriptions: [UUID: Subscription] = [:]
    private var accountObservers: [UUID: @MainActor ([MailAccount]) -> Void] = [:]
    private var placeObservers: [UUID: @MainActor (MailPlaces) -> Void] = [:]
    private var labelCatalog = MailLabelCatalog.Reading()
    private var labelTasks: [String: Task<Void, Never>] = [:]
    private var labelReadTask: Task<Void, Never>?
    private var pages: [String: GmailPageCursor] = [:]
    private var pageTasks: [String: Task<Void, Never>] = [:]
    private var completed = Set<String>()
    private var failures = Set<String>()
    private var disabled = Set<String>()
    private var forgettingAccess = Set<String>()
    private var firstPages: [MailScope: MailListSnapshot] = [:]
    private var firstPageOrder: [MailScope] = []
    private var active = false
    private var mailboxSync: GmailMailboxSync?
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private var syncOwners: [String: UUID] = [:]
    private var syncRetryAt: [String: Date] = [:]
    private var syncHealth: [String: MailSyncHealth] = [:]
    private var lastSync: [String: Date] = [:]
    private var fillAfter: [String: MailSyncFill.Cursor] = [:]
    private var actionCoordinator: MailActionCoordinator?
    private var nextActionSequence: Int64 = 1
    private var actionThrough: UInt64 = 0
    private var lastFinishedAction: UInt64 = 0
    private var projectionNeedsRepair = false
    private var actionTask: Task<Void, Never>?
    private var eventObservers: [UUID: @MainActor (MailEvent) -> Void] = [:]
    private var savedActions: [UInt64: (change: MailChange, applied: MailActionCoordinator.Applied)] = [:]
    private var savedActionOrder: [UInt64] = []
    private var pendingActions = Set<UInt64>()
    private var undoRequested = Set<UInt64>()
    private var intentStore: MailIntentStore?
    private var removalCoordinator: MailRemovalCoordinator?
    private var removalStatusTask: Task<Void, Never>?
    private var removalNeedsRepair = false
    private var keptCounts: [String: Int] = [:]
    private var delivery: GmailIntentDelivery?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryWake: Task<Void, Never>?
    private var deliveryDirty = false
    private var deliveryRetryAt: [String: Int64] = [:]
    private var refusalTask: Task<Void, Never>?
    private var draftDriver: MailDraftDriver?
    private var draftWork: Task<Void, Never>?
    private var draftWake: Task<Void, Never>?
    private var draftDeliveryTask: Task<Void, Never>?
    private var draftDeliveryDirty = false
    private var draftReadTask: Task<Void, Never>?
    private var draftCache: [MailDraftID: MailDraft] = [:]
    private var draftStates: [MailDraftID: MailDraftRecord.State] = [:]
    private var draftUndo: [UInt64: MailDraftID] = [:]
    private var draftSaveFailures = Set<MailDraftID>()
    private var draftGenerations: [MailDraftID: Int] = [:]
    private var draftCacheOrder: [MailDraftID] = []
    private var durablePendingDraftSends = false
    private let deliveryAllowed: @MainActor @Sendable (String) -> Bool

    /// Banana Cloud's shared mailbox feed, when this app's service offers one (MAIL-CLOUD-SYNC).
    let cloudFeed: (any MailCloudFeedSource)?

    init(stores: MailStores, access: any MailAccountAccess, api: any GmailAPI,
         cloudFeed: (any MailCloudFeedSource)? = nil,
         deliveryAllowed: @escaping @MainActor @Sendable (String) -> Bool = { _ in false }) {
        self.stores = stores; self.access = access; self.api = api; self.cloudFeed = cloudFeed
        self.deliveryAllowed = deliveryAllowed
        self.observedReadAccounts = Set(access.connectedAccountIDs.map { $0.lowercased() })
        status.value.store = .ready
    }
    var syncLimit: MailSyncLimit { .everything }
    var canCompose: Bool { draftDriver != nil && accounts.contains { $0.state == .connected && deliveryAllowed($0.id) } }
    var supportsScheduledSend: Bool { false }
    var supportsAccountSwitching: Bool { false }
    var accounts: [MailAccount] {
        access.connectedAccountIDs.map { account in
            let grant = access.mailGrant(accountID: account)
            let state: MailAccountState
            if disabled.contains(account) { state = .off }
            else if forgettingAccess.contains(account) { state = .needsAccess(.notAllowedHere) }
            else {
                switch grant {
                case .none: state = .needsAccess(.notAllowedHere)
                case .rejected: state = .needsAccess(.withdrawn)
                case .granted: state = .connected
                }
            }
            return MailAccount(id: account, shortName: account.components(separatedBy: "@").first ?? account,
                wantsMail: !disabled.contains(account), state: state, health: syncHealth[account] ?? (failures.contains(account) ? .offline : .catchingUp),
                lastSyncAt: lastSync[account], identities: [MailIdentity(account: account, address: account, name: nil, isDefault: true, hasSignature: false)], keptAfterRemoval: keptCounts[account] ?? 0)
        }
    }
    func activate() {
        guard !active else { return }; active = true
        publishAccounts(); checkNow()
        wants(conversationSubscriptions.values.map(\.id))
        startDownloads()
        kickCloud()
        kickReprepare(restart: true)
    }

    /// Walks stored originals newest first, preparing what the current preparer has not, at the
    /// work pace: after a `MailHTMLPreparer.version` change no open has to wait for it.
    private func kickReprepare(restart: Bool = false) {
        guard reprepareTask == nil, active || pushCatchUp > 0 else { return }
        let pass = reprepare, token = UUID()
        reprepareToken = token
        reprepareTask = Task(priority: .utility) { [weak self] in
            if restart { await pass.restart() }
            while !Task.isCancelled {
                guard let step = try? await pass.step(), step.more else { break }
            }
            // A walk cancelled by hiding Mail must not clear the one started when it came back.
            if self?.reprepareToken == token { self?.reprepareTask = nil }
        }
    }

    /// An open: the conversation's stored originals that have no current prepared body are
    /// prepared now, ahead of the walk (counted as preparations on request).
    private func prepareOpened(_ id: MailConversationID) {
        let pass = reprepare
        Task(priority: .userInitiated) { [weak self] in
            let stale = (try? await pass.stale(in: id)) ?? []
            guard let self else { return }
            for message in stale { self.enqueue(.body(message), priority: true) }
        }
    }
    func setVisible(_ visible: Bool) {
        paceGauge.setVisible(visible)
        if visible { activate() }
        else {
            stopSync()
            for task in pageTasks.values { task.cancel() }
            pageTasks.removeAll(); cancelDownloads(); access.cancelMailTokenRequests()
            screenWork?.cancel(); screenWork = nil
            if pushCatchUp == 0 {
                cloudTask?.cancel(); cloudTask = nil
                reprepareTask?.cancel(); reprepareTask = nil
            }
            active = false
            draftWake?.cancel(); draftWake = nil
            draftReadTask?.cancel()
            for task in labelTasks.values { task.cancel() }
            labelTasks.removeAll(); labelReadTask?.cancel()
            deliveryTask?.cancel(); deliveryWake?.cancel(); deliveryWake = nil
        }
    }
    func observeAccounts(_ onChange: @escaping @MainActor ([MailAccount]) -> Void) -> MailObservation {
        let id = UUID(); accountObservers[id] = onChange; onChange(accounts)
        return MailObservation { [weak self] in Task { @MainActor in self?.accountObservers[id] = nil } }
    }
    func observePlaces(_ onChange: @escaping @MainActor (MailPlaces) -> Void) -> MailObservation {
        let id = UUID(); placeObservers[id] = onChange; onChange(places)
        return MailObservation { [weak self] in Task { @MainActor in self?.placeObservers[id] = nil } }
    }
    private var places: MailPlaces {
        MailPlaces(splits: [MailSplit(id: MailSplit.importantID, name: "Important", query: nil),
                           MailSplit(id: MailSplit.calendarID, name: "Calendar", query: nil),
                           MailSplit(id: MailSplit.otherID, name: "Other", query: nil)],
            splitCounts: [:], mailboxCounts: [:], outboxNeedsAnswer: false, labels: labelCatalog.places.filter { readAccounts.contains($0.key.lowercased()) })
    }
    private var observedReadAccounts: Set<String>?
    private var readAccounts: Set<String> { Set(access.connectedAccountIDs.map { $0.lowercased() }) }
    func cachedFirstPage(_ scope: MailScope) -> MailListSnapshot? {
        guard observedReadAccounts == readAccounts else { return nil }
        return firstPages[scope]
    }
    func observeList(_ scope: MailScope, limit: Int, _ onChange: @escaping @MainActor (MailListSnapshot) -> Void) -> MailObservation {
        let id = UUID()
        subscriptions[id] = Subscription(scope: scope, limit: min(MailTuning.listCap, max(1, limit)), callback: onChange)
        refresh(id)
        return MailObservation { [weak self] in Task { @MainActor in
            self?.subscriptions[id]?.task?.cancel(); self?.subscriptions[id] = nil
        } }
    }
    func observeConversation(_ id: MailConversationID, _ onChange: @escaping @MainActor (MailConversation?) -> Void) -> MailObservation {
        let token = UUID()
        conversationSubscriptions[token] = ConversationSubscription(id: id, callback: onChange)
        refreshConversation(token)
        wants([id])
        return MailObservation { [weak self] in Task { @MainActor in
            self?.conversationSubscriptions[token]?.task?.cancel()
            self?.conversationSubscriptions[token] = nil
        } }
    }
    func conversation(_ id: MailConversationID) async -> MailConversation? {
        let through = actionThrough
        do {
            var value = try await MailConversationReader(stores: stores).conversation(id)
            value?.appliedThrough = through
            if let record = try await draftDriver?.forConversation(id) {
                let draft = record.snapshot.value
                if value == nil {
                    value = MailConversation(id: id, subject: draft.subject, labels: [], inInbox: false,
                        isStarred: false, isImportant: false, isMuted: false, snoozedUntil: nil, system: nil,
                        messages: [], invite: nil, unsubscribe: nil, draft: draft.id, newestIsMine: true, appliedThrough: through)
                } else { value?.draft = draft.id }
            }
            return value
        }
        catch { if !Task.isCancelled { status.value.store = .unavailable(.unavailable) }; return nil }
    }
    func originalHTML(_ id: MailMessageID) async throws -> String? {
        try await MailOriginalDocument.load(stores: stores, id: id)
    }
    func body(_ id: MailMessageID) async -> MailBody {
        do { return try await MailBlobStore(stores: stores).prepared(account: id.account, messageID: id.message)?.body ?? .notOnDevice }
        catch { if !Task.isCancelled { status.value.store = .unavailable(.unavailable) }; return .notOnDevice }
    }
    private func refreshConversation(_ token: UUID) {
        guard let subscription = conversationSubscriptions[token] else { return }
        conversationSubscriptions[token]?.task?.cancel()
        let through = actionThrough
        conversationSubscriptions[token]?.task = Task { [weak self] in
            var value = await self?.conversation(subscription.id)
            value?.appliedThrough = through
            guard !Task.isCancelled, let self, let current = self.conversationSubscriptions[token] else { return }
            guard !current.delivered || current.last != value else { return }
            self.conversationSubscriptions[token]?.last = value
            self.conversationSubscriptions[token]?.delivered = true
            current.callback(value)
        }
    }

    private func refresh(_ id: UUID) {
        guard let subscription = subscriptions[id] else { return }
        subscriptions[id]?.task?.cancel()
        let reader = MailIndexReader(stores: stores)
        subscriptions[id]?.task = Task { [weak self] in
            guard let self else { return }
            let scope = subscription.scope
            let allowedAccounts = self.readAccounts
            // Capture before the read; never tag old rows with a newer action's receipt.
            let through = self.actionThrough
            if let driver = self.draftDriver, scope.place == .mailbox(.drafts) || scope.place == .mailbox(.outbox) {
                do {
                    let records = try await driver.page(account: scope.account, outbox: scope.place == .mailbox(.outbox), before: scope.before, limit: subscription.limit + 1)
                    guard !Task.isCancelled else { return }
                    let shown = Array(records.prefix(subscription.limit))
                    let rows = scope.filters.isEmpty ? shown.map(Self.draftRow) : []
                    self.deliver(MailListSnapshot(scope: scope, rows: rows,
                        total: MailCount(value: rows.count, isAtLeast: records.count > subscription.limit || scope.before != nil),
                        hasMore: records.count > subscription.limit, stillLoading: 0, isRebuilding: false,
                        remote: nil, coverage: nil, appliedThrough: through), to: id)
                } catch {
                    self.deliver(MailListSnapshot(scope: scope, rows: [], total: MailCount(value: 0, isAtLeast: true),
                        hasMore: false, stillLoading: 0, isRebuilding: false, remote: .failed, coverage: nil, appliedThrough: through), to: id)
                }
                return
            }
            if case .search(let text) = scope.place {
                do {
                    let rows = try await reader.search(MailLocalSearchQuery(text: text, account: scope.account,
                        filters: scope.filters, before: scope.before, limit: subscription.limit, allowedAccounts: allowedAccounts))
                    guard !Task.isCancelled else { return }
                    guard allowedAccounts == self.readAccounts else { return }
                    self.deliver(MailListSnapshot(scope: scope,
                        rows: rows.map { row in MailRowMapper.row(row, labels: row.labelPKs.compactMap { self.labelCatalog.refs[$0] }, reason: nil, in: scope) },
                        total: MailCount(value: rows.count, isAtLeast: rows.count == subscription.limit),
                        hasMore: rows.count == subscription.limit, stillLoading: 0, isRebuilding: false,
                        remote: nil, coverage: nil, appliedThrough: through), to: id)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.deliver(MailListSnapshot(scope: scope, rows: [], total: MailCount(value: 0, isAtLeast: true),
                        hasMore: false, stillLoading: 0, isRebuilding: false, remote: .failed, coverage: nil, appliedThrough: through), to: id)
                }
                return
            }
            guard let view = Self.view(for: scope) else {
                self.deliver(MailListSnapshot(scope: scope, rows: [], total: MailCount(value: 0, isAtLeast: true),
                    hasMore: false, stillLoading: 0, isRebuilding: false, remote: .failed, coverage: nil, appliedThrough: through), to: id)
                return
            }
            do {
                let request = PageRequest(view: view, account: Self.account(for: scope), filters: scope.filters, before: scope.before, limit: subscription.limit, allowedAccounts: allowedAccounts)
                let rows = try await reader.page(request)
                let counts = try await reader.counts(request)
                let localMore: Bool
                if scope.before != nil {
                    if rows.count == subscription.limit, let last = rows.last {
                        localMore = !(try await reader.page(PageRequest(view: view, account: request.account,
                            filters: scope.filters,
                            before: MailOrderKey(group: 0, sortKey: last.sortKey, tie: last.tie), limit: 1, allowedAccounts: allowedAccounts))).isEmpty
                    } else { localMore = false }
                } else { localMore = rows.count < counts.total.value }
                guard !Task.isCancelled, allowedAccounts == self.readAccounts else { return }
                let connected = self.accounts.filter { $0.state == .connected && (Self.account(for: scope) == nil || Self.account(for: scope) == $0.id) }
                let pending = connected.contains { self.pageTasks[$0.id] != nil }
                let more = connected.contains { !self.completed.contains($0.id) }
                let failed = connected.contains { self.failures.contains($0.id) }
                self.deliver(MailListSnapshot(scope: scope,
                    rows: rows.map { row in MailRowMapper.row(row, labels: row.labelPKs.compactMap { self.labelCatalog.refs[$0] }, reason: nil, in: scope) },
                    total: MailCount(value: counts.total.value, isAtLeast: counts.total.isAtLeast || more),
                    hasMore: localMore || more, stillLoading: counts.stillLoading,
                    isRebuilding: false, remote: pending ? .pending : failed ? .failed : nil, coverage: nil, appliedThrough: through), to: id)
            } catch {
                guard !Task.isCancelled else { return }
                self.status.value.store = .unavailable(.unavailable)
            }
        }
    }
    private func deliver(_ snapshot: MailListSnapshot, to id: UUID) {
        guard let subscription = subscriptions[id], subscription.last != snapshot else { return }
        subscriptions[id]?.last = snapshot
        var first = snapshot; first.rows = Array(snapshot.rows.prefix(MailTuning.firstPageRows))
        first.hasMore = snapshot.hasMore || snapshot.rows.count > first.rows.count
        firstPages[snapshot.scope] = first
        firstPageOrder.removeAll { $0 == snapshot.scope }; firstPageOrder.append(snapshot.scope)
        while firstPageOrder.count > 8 { firstPages[firstPageOrder.removeFirst()] = nil }
        subscription.callback(snapshot)
    }
    private func committed(_ change: MailStoreChange) {
        if change.labelsChanged { refreshLabelCatalog() }
        guard !change.viewKeys.isEmpty || !change.conversations.isEmpty else { return }
        for (token, subscription) in conversationSubscriptions where change.conversations.contains(subscription.id) {
            refreshConversation(token)
        }
        firstPages.removeAll(); firstPageOrder.removeAll()
        for id in subscriptions.keys { refresh(id) }
    }
    func checkNow() {
        publishAccounts()
        refreshDrafts()
        resumeDraftDelivery()
        refreshRemovalStatus()
        refreshLabelCatalog()
        repairActionProjection()
        refreshRefusals()
        kickDelivery()
        for account in accounts where account.state == .connected {
            startSync(account.id)
            loadLabels(account.id)
            pageTasks[account.id]?.cancel(); pageTasks[account.id] = nil
            pages[account.id] = nil; completed.remove(account.id)
            loadPage(account.id)
        }
    }
    func askGmail(_ scope: MailScope) {
        // Search-specific membership is not wired yet; never pass an unrelated page off as a search.
        if case .search = scope.place { return }
        for account in accounts where account.state == .connected && (Self.account(for: scope) == nil || Self.account(for: scope) == account.id) {
            loadPage(account.id)
        }
    }
    private func loadLabels(_ account: String) {
        guard active, !disabled.contains(account), !forgettingAccess.contains(account), access.mailGrant(accountID: account) == .granted,
              (syncRetryAt[account] ?? .distantPast) <= Date(),
              labelTasks[account] == nil else { return }
        labelTasks[account] = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.access.mailAccessToken(accountID: account).value
                try await MailLabelCatalog.fetch(account: account, api: self.api, token: token, writer: self.writer)
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
                self.recordReadFailure(error, account: account)
                self.publishAccounts()
            }
            self.labelTasks[account] = nil
        }
    }

    private func refreshLabelCatalog() {
        labelReadTask?.cancel()
        labelReadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reading = try await self.stores.index.read { try MailLabelCatalog.read(in: $0) }
                guard !Task.isCancelled, reading != self.labelCatalog else { return }
                self.labelCatalog = reading
                let places = self.places
                for callback in self.placeObservers.values { callback(places) }
                for id in self.subscriptions.keys { self.refresh(id) }
            } catch {
                guard !Task.isCancelled else { return }
                self.status.value.store = .unavailable(.unavailable)
            }
        }
    }

    private func loadPage(_ account: String) {
        guard access.mailGrant(accountID: account) == .granted, !disabled.contains(account), !forgettingAccess.contains(account),
              (syncRetryAt[account] ?? .distantPast) <= Date(), pageTasks[account] == nil, !completed.contains(account) else { return }
        failures.remove(account)
        let loader = self.loader, cursor = pages[account]
        pageTasks[account] = Task { [weak self] in
            do {
                let result = try await loader.load(GmailPageScope(account: account, includeSpamTrash: true), after: cursor)
                guard !Task.isCancelled, let self else { return }
                self.pages[account] = result.next
                if result.next == nil { self.completed.insert(account) }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.recordReadFailure(error, account: account)
            }
            guard let self else { return }
            self.pageTasks[account] = nil; self.publishAccounts()
            for id in self.subscriptions.keys { self.refresh(id) }
        }
        for id in subscriptions.keys { refresh(id) }
    }
    func wants(_ ids: [MailConversationID]) {
        for id in ids.prefix(8) { prepareOpened(id) }
        guard let pull = cloudPull else {
            for id in ids.prefix(8) { enqueue(.thread(id), priority: true) }
            return
        }
        for id in ids.prefix(8) {
            Task { [weak self] in
                // A conversation this device holds, on an account the cloud mailbox serves: its
                // text comes from the cloud first, ahead of everything else. The feed keeps its
                // messages current, so no thread read is needed; anything the cloud lacks comes
                // the per-message way at once.
                let cloud = (try? await pull.isCloud(id.account)) ?? false
                let holds = cloud ? ((try? await pull.holds(id)) ?? false) : false
                guard let self else { return }
                guard cloud, holds else { self.enqueue(.thread(id), priority: true); return }
                let fallback = (try? await pull.open(id)) ?? []
                for item in fallback { self.enqueue(.body(item.id), priority: true) }
                // The opened conversation's pull runs now, at the person's priority, beside any
                // utility-priority batch already in flight.
                Task(priority: .userInitiated) { _ = try? await pull.step(fill: false) }
                self.kickCloud()
            }
        }
    }

    func onScreen(_ ids: [MailConversationID]) {
        // Rows change at scroll speed; the reading happens once things settle, off this thread.
        screenWork?.cancel()
        let pull = cloudPull
        screenWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if let pull {
                let fallback = (try? await pull.onScreen(ids)) ?? []
                guard !Task.isCancelled, let self else { return }
                for item in fallback.prefix(16) { self.enqueue(.body(item.id), priority: false) }
                self.kickCloud()
            } else {
                // No cloud: the newest message of each visible conversation, the per-message way,
                // below anything opened. Ids already here cost a local read only.
                guard let self else { return }
                let newest = (try? await self.stores.index.read { db in try Self.newestMissing(ids, in: db) }) ?? []
                guard !Task.isCancelled else { return }
                for id in newest.prefix(16) { self.enqueue(.body(id), priority: false) }
            }
        }
    }

    /// The newest message of each conversation, where its text is not here.
    nonisolated private static func newestMissing(_ ids: [MailConversationID], in db: Database) throws -> [MailMessageID] {
        try ids.compactMap { conversation in
            let account = conversation.account.lowercased()
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.gmail_id, (m.fetch_state<2 OR m.prep_state=0) FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
                JOIN account a ON a.account_pk=t.account_pk
                WHERE a.email=? AND t.gmail_id=? AND m.vis!=4 ORDER BY m.internal_date DESC, m.msg_pk DESC LIMIT 1
                """, arguments: [account, conversation.thread]) else { return nil }
            let owed: Bool = row[1]
            return owed ? MailMessageID(account: account, message: row[0]) : nil
        }
    }

    /// Runs bulk pulls until there is nothing to pull: opened, then on screen, then (while Mail is
    /// in use or a push's window is open) the rest newest first. One request at a time.
    private func kickCloud() {
        guard let pull = cloudPull, cloudTask == nil, active || pushCatchUp > 0 else { return }
        let token = UUID()
        cloudToken = token
        cloudTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let step: MailCloudPull.Step
                do { step = try await pull.step(fill: self.active || self.pushCatchUp > 0) }
                catch { break }
                guard !Task.isCancelled else { break }
                for item in step.fallback { self.enqueue(.body(item.id), priority: item.urgent) }
                if !step.worked { break }
            }
            if self?.cloudToken == token { self?.cloudTask = nil }
        }
    }

    /// A silent push said new mail is here (MAIL-CLOUD-SYNC §2a): one feed pass for each account,
    /// then the new messages' text, within `budget`. Runs inside the push's background window;
    /// returns whether the pass got through.
    func catchUpFromPush(budget: Duration = .seconds(20)) async -> Bool {
        guard let sync = mailboxSync else { return false }
        pushCatchUp += 1
        paceGauge.enterWindow()
        defer { pushCatchUp -= 1; paceGauge.leaveWindow() }
        let start = ContinuousClock.now
        var ok = false
        for account in accounts where account.state == .connected {
            do {
                _ = try await sync.pass(account: account.id, nowMS: Int64(Date().timeIntervalSince1970 * 1000))
                ok = true
            } catch GmailMailboxSync.Failure.busy {
                ok = true   // a pass is running already; it brings the same
            } catch {
                recordReadFailure(error, account: account.id)
            }
        }
        guard let pull = cloudPull else { return ok }
        while ContinuousClock.now - start < budget, !Task.isCancelled {
            guard let step = try? await pull.step(fill: true), step.worked else { break }
            for item in step.fallback where item.urgent { enqueue(.body(item.id), priority: true) }
        }
        publishAccounts()
        return ok
    }
    func fetchBody(_ id: MailMessageID) { enqueue(.body(id), priority: true) }
    private func enqueue(_ item: Download, priority: Bool) {
        guard access.mailGrant(accountID: item.account) == .granted, !disabled.contains(item.account), !forgettingAccess.contains(item.account),
              (syncRetryAt[item.account] ?? .distantPast) <= Date(), downloads[item] == nil else { return }
        downloadQueue.removeAll { $0 == item }
        if priority { downloadQueue.insert(item, at: 0) } else { downloadQueue.append(item) }
        if downloadQueue.count > 64 { downloadQueue.removeLast(downloadQueue.count - 64) }
        startDownloads()
    }
    private func startDownloads() {
        guard active else { return }
        while downloads.count < 2, !downloadQueue.isEmpty {
            let item = downloadQueue.removeFirst()
            guard access.mailGrant(accountID: item.account) == .granted, !disabled.contains(item.account), !forgettingAccess.contains(item.account),
                  (syncRetryAt[item.account] ?? .distantPast) <= Date() else { continue }
            let loader = conversationLoader
            downloads[item] = Task { [weak self] in
                do {
                    switch item {
                    case .thread(let id):
                        let messages = try await loader.thread(id)
                        guard !Task.isCancelled, let self else { return }
                        if let pull = self.cloudPull, (try? await pull.isCloud(id.account)) == true {
                            // The conversation is here now: its text from the cloud, first in line.
                            let fallback = (try? await pull.open(id)) ?? []
                            for item in fallback { self.enqueue(.body(item.id), priority: true) }
                            self.kickCloud()
                        } else {
                            // Older bodies remain reachable through explicit Load message controls.
                            for message in messages.suffix(8) { self.enqueue(.body(message), priority: false) }
                        }
                    case .body(let id): try await loader.body(id)
                    }
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.failures.insert(item.account)
                    if error as? GmailError == .unauthorized { self.access.dropMailAccessToken(accountID: item.account) }
                    if case GmailError.limited = error {
                        self.recordReadFailure(error, account: item.account, minimumDelay: 30)
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.downloads[item] = nil
                // Also refresh after a warm cache hit or crash recovery that needed no import.
                for token in self.conversationSubscriptions.keys { self.refreshConversation(token) }
                self.publishAccounts(); self.startDownloads()
            }
        }
    }
    private func cancelDownloads(account: String? = nil) {
        let keys = downloads.keys.filter { account == nil || $0.account == account }
        for key in keys { downloads[key]?.cancel(); downloads[key] = nil }
        downloadQueue.removeAll { account == nil || $0.account == account }
    }

    func requestPermission(account: String) async -> MailPermissionResult {
        guard !forgettingAccess.contains(account) else { return .cancelled }
        let outcome = await access.requestMailAccess(accountID: account)
        publishAccounts()
        switch outcome {
        case .granted:
            disabled.remove(account)
            publishAccounts()
            completed.remove(account); loadPage(account); loadLabels(account); startSync(account); kickDelivery()
            wants(conversationSubscriptions.values.filter { $0.id.account == account }.map(\.id))
            return .granted
        case .declined: return .notGranted
        case .cancelled: return .cancelled
        case .differentAccount: return .differentAccount
        case .noWindow: return .noWindow
        case .failed: return .failed
        }
    }
    func forgetPermission(account: String) {
        guard forgettingAccess.insert(account).inserted else { return }
        stopSync(account: account)
        cancelDownloads(account: account)
        pageTasks[account]?.cancel(); pageTasks[account] = nil
        labelTasks[account]?.cancel(); labelTasks[account] = nil
        publishAccounts()
        Task { [weak self] in
            guard let self else { return }
            defer { self.forgettingAccess.remove(account); self.publishAccounts() }
            do { try await self.access.forgetMailAccess(accountID: account) }
            catch {
                self.disabled.insert(account)
                self.status.value.store = .cannotSave(.unavailable)
            }
        }
    }
    func setWantsMail(_ on: Bool, account: String) {
        if on {
            disabled.remove(account); loadPage(account); loadLabels(account)
            startSync(account)
            wants(conversationSubscriptions.values.filter { $0.id.account == account }.map(\.id))
        }
        else {
            stopSync(account: account)
            disabled.insert(account); cancelDownloads(account: account)
            pageTasks[account]?.cancel(); pageTasks[account] = nil
            labelTasks[account]?.cancel(); labelTasks[account] = nil
        }
        publishAccounts()
        kickDelivery()
    }
    private func publishAccounts() {
        let current = readAccounts
        if observedReadAccounts != current {
            observedReadAccounts = current
            firstPages.removeAll(); firstPageOrder.removeAll()
            for id in subscriptions.keys { refresh(id) }
            let value = places
            for callback in placeObservers.values { callback(value) }
        }
        let value = accounts
        for callback in accountObservers.values { callback(value) }
    }

    private static func account(for scope: MailScope) -> String? {
        if case .label(let account, _) = scope.place { return account }
        return scope.account
    }

    static func view(for scope: MailScope) -> MailViewKey? {
        switch scope.place {
        case .split(let id): return .split(id: id)
        case .label(let account, let id): return .label(account: account, labelID: id)
        case .mailbox(let mailbox):
            switch mailbox {
            case .inbox: return .unified(.inbox)
            case .starred: return .unified(.starred)
            case .important: return .unified(.important)
            case .drafts: return .unified(.draft)
            case .sent: return .unified(.sent)
            case .spam: return .unified(.spam)
            case .trash: return .unified(.trash)
            case .done: return .done(account: scope.account)
            case .all: return .allMail(account: scope.account)
            case .snoozed: return .snoozed
            case .muted: return .muted
            case .outbox: return nil
            }
        case .search, .heldRemoval: return nil
        }
    }
}


extension MailLiveSource {
    /// Complete before installing a live session; recovery performs no provider writes.
    func prepareActions(intent: MailIntentStore) async throws {
        guard actionCoordinator == nil else { return }
        let coordinator = MailActionCoordinator(stores: stores, intent: intent, writer: writer)
        try await intent.discardUncommittedStages()
        let removals = MailRemovalCoordinator(stores: stores, intent: intent, writer: writer)
        removalCoordinator = removals
        do { try await removals.recover(at: Int64(Date().timeIntervalSince1970 * 1000)) }
        catch { removalNeedsRepair = true; status.value.store = .cannotSave(.unavailable) }
        try await coordinator.recover()
        nextActionSequence = try await intent.nextSequence()
        actionCoordinator = coordinator
        intentStore = intent
        mailboxSync = GmailMailboxSync(stores: stores, writer: writer, api: api,
            token: { [access] account in try await access.mailAccessToken(accountID: account).value },
            recovery: MailRemovalRecovery(stores: stores, intents: intent), feed: cloudFeed)
        let writer = self.writer
        delivery = GmailIntentDelivery(store: intent, api: api, token: { [access] account in
            try await access.mailAccessToken(accountID: account).value
        }, allowed: { [weak self] account in
            await self?.canDeliver(account) ?? false
        }, accept: { account, value in
            guard let message = value.id, let history = value.historyId else { throw GmailIntentDelivery.Failure.malformedConfirmation }
            _ = try await writer.transact { db in
                let previous = try String.fetchOne(db, sql: "SELECT m.history_id FROM message m JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id=?", arguments: [account, message]).flatMap(GmailNumber.unsigned)
                if let previous, previous > history { throw GmailIntentDelivery.Failure.staleConfirmation }
                let change = try MailMessageImporter.apply(FetchedMessage(wire: value, floor: history, headers: MessageHeaders(payload: value.payload), structure: nil), account: account, myAddresses: [account], in: db)
                guard !change.conversations.isEmpty else { throw GmailIntentDelivery.Failure.staleConfirmation }
                return change
            }
        }, settled: { [weak self] account, message, keys, outcome in
            await self?.deliverySettled(account: account, message: message, keys: keys, outcome: outcome)
        })
        refreshRefusals()
        // Publish recovered review state before this source is handed to the UI.
        // A background refresh here races the caller's initial status read and activation.
        do { try await loadRemovalStatus() }
        catch {
            if Task.isCancelled { throw error }
            status.value.store = .unavailable(.unavailable)
        }
        kickDelivery()
    }

    func observeEvents(_ onEvent: @escaping @MainActor (MailEvent) -> Void) -> MailObservation {
        let token = UUID()
        eventObservers[token] = onEvent
        return MailObservation { [weak self] in
            Task { @MainActor in self?.eventObservers[token] = nil }
        }
    }
    private func emit(_ event: MailEvent) {
        for observer in Array(eventObservers.values) { observer(event) }
    }
    private func refreshAfterAction() {
        firstPages.removeAll(); firstPageOrder.removeAll()
        for id in subscriptions.keys { refresh(id) }
        for token in conversationSubscriptions.keys { refreshConversation(token) }
    }

    @discardableResult func apply(_ change: MailChange, to target: MailTarget) -> MailReceipt {
        guard nextActionSequence > 0, nextActionSequence < Int64.max else {
            status.value.store = .cannotSave(.unavailable)
            return MailReceipt(sequence: 0, count: 0)
        }
        let sequence = nextActionSequence
        nextActionSequence += 1
        let readings: [MailActionReading]?
        let count: Int?
        switch target {
        case .reading(let values): readings = values; count = Set(values.map(\.id)).count
        case .conversations(let ids):
            let rows = subscriptions.values.flatMap { $0.last?.rows ?? [] }
            let found = ids.compactMap { id in rows.first { $0.id == id } }
            if found.count == ids.count, case .reading(let values) = MailTarget.asShown(found) { readings = values }
            else { readings = nil }
            count = ids.count
        case .message: readings = nil; count = 1
        case .scope: readings = nil; count = nil
        }
        let receipt = MailReceipt(sequence: UInt64(sequence), count: count)
        pendingActions.insert(receipt.sequence)
        let prior = actionTask
        actionTask = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            defer { self.pendingActions.remove(receipt.sequence) }
            do {
                guard let coordinator = self.actionCoordinator else { throw MailIntentStore.Failure.invalidGroup }
                if case .scope(let scope, let from) = target {
                    let selection: MailActionCoordinator.Selection
                    if case .search(let text) = scope.place {
                        selection = .search(MailLocalSearchQuery(text: text, account: scope.account, filters: scope.filters, before: from))
                    } else if let view = Self.view(for: scope) {
                        selection = .list(view: view, account: Self.account(for: scope), filters: scope.filters, from: from)
                    } else { throw MailIntentStore.Failure.invalidGroup }
                    let result = try await coordinator.apply(change, selection: selection, sequence: sequence,
                        at: Int64(Date().timeIntervalSince1970 * 1000))
                    self.finishedAction(result, receipt: receipt, remember: change)
                    return
                }
                let resolved: [MailActionReading]
                if let readings { resolved = readings }
                else if case .message(let message) = target {
                    resolved = try await self.stores.index.read { db in
                        guard let row = try Row.fetchOne(db, sql: """
                            SELECT t.gmail_id AS thread, m.internal_date, m.arrival_seq
                            FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
                            JOIN account a ON a.account_pk=m.account_pk
                            WHERE a.email=? AND m.gmail_id=?
                            """, arguments: [message.account, message.message]) else {
                            throw MailActionCoordinator.Failure.missingConversation
                        }
                        return [MailActionReading(id: MailConversationID(account: message.account, thread: row["thread"]),
                            asOf: row["internal_date"], arrivalSequence: row["arrival_seq"])]
                    }
                } else { throw MailIntentStore.Failure.invalidGroup }
                let targets = resolved.map {
                    MailActionCoordinator.Target(id: $0.id, asOf: $0.asOf, messageArrivalCeiling: $0.arrivalSequence)
                }
                let result = try await coordinator.apply(change, to: targets, sequence: sequence,
                    at: Int64(Date().timeIntervalSince1970 * 1000))
                self.finishedAction(result, receipt: receipt, remember: change)
            } catch {
                self.failedAction(error, receipt: receipt)
            }
        }
        return receipt
    }

    private func finishedAction(_ result: MailActionCoordinator.Applied, receipt: MailReceipt, remember change: MailChange? = nil) {
        lastFinishedAction = receipt.sequence
        if let change, result.sequence != nil {
            savedActions[receipt.sequence] = (change, result)
            savedActionOrder.append(receipt.sequence)
            while savedActionOrder.count > 50 { savedActions[savedActionOrder.removeFirst()] = nil }
        }
        if result.projectionError != nil {
            projectionNeedsRepair = true
            status.value.store = .unavailable(.unavailable)
        }
        if !projectionNeedsRepair {
            actionThrough = receipt.sequence
            if result.sequence != nil { status.value.store = .ready }
        }
        emit(.applied(receipt, count: result.count))
        refreshAfterAction()
        refreshRefusals()
        kickDelivery()
    }
    private func failedAction(_ error: any Error, receipt: MailReceipt) {
        lastFinishedAction = receipt.sequence
        if !projectionNeedsRepair { actionThrough = receipt.sequence }
        let problem: MailStoreProblem = (error as? DatabaseError)?.resultCode == .SQLITE_FULL ? .diskFull : .unavailable
        status.value.store = .cannotSave(problem)
        emit(.notSaved(receipt, problem))
        refreshAfterAction()
    }

    @discardableResult func undo(_ original: MailReceipt) -> MailReceipt {
        if let id = draftUndo.removeValue(forKey: original.sequence), let driver = draftDriver {
            let receipt = draftReceipt()
            enqueueDraftWork { [weak self] in
                do { try await driver.restore(id); self?.emit(.applied(receipt, count: 1)); try await driver.flush(id) }
                catch { self?.emit(.notSaved(receipt, .unavailable)) }
            }
            return receipt
        }
        guard (pendingActions.contains(original.sequence) || savedActions[original.sequence] != nil),
              !undoRequested.contains(original.sequence), nextActionSequence > 0, nextActionSequence < Int64.max else {
            return MailReceipt(sequence: 0, count: 0)
        }
        let sequence = nextActionSequence
        nextActionSequence += 1
        let receipt = MailReceipt(sequence: UInt64(sequence), count: original.count)
        undoRequested.insert(original.sequence)
        let prior = actionTask
        actionTask = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            defer { self.undoRequested.remove(original.sequence) }
            do {
                guard let saved = self.savedActions[original.sequence], let coordinator = self.actionCoordinator else {
                    self.finishedAction(.init(sequence: nil, count: 0, before: [], projectionError: nil), receipt: receipt)
                    return
                }
                let result = try await coordinator.undo(saved.applied, change: saved.change, sequence: sequence,
                    at: Int64(Date().timeIntervalSince1970 * 1000))
                self.savedActions[original.sequence] = nil
                self.savedActionOrder.removeAll { $0 == original.sequence }
                self.finishedAction(result, receipt: receipt)
            } catch {
                // Keep the original inverse so Undo can be tried again after a save failure.
                self.failedAction(error, receipt: receipt)
            }
        }
        return receipt
    }

    func permitsAccountChanges(_ account: String) -> Bool { deliveryAllowed(account) }

    /// UI policy only; delivery independently rechecks permission before every provider write.
    func permitsChanges(to target: MailTarget) -> Bool {
        let accounts: Set<String>
        switch target {
        case .reading(let rows): accounts = Set(rows.map { $0.id.account })
        case .conversations(let ids): accounts = Set(ids.map(\.account))
        case .message(let id): accounts = [id.account]
        case .scope(let scope, _):
            if let account = Self.account(for: scope) { accounts = [account] }
            else { accounts = Set(access.connectedAccountIDs) }
        }
        return !accounts.isEmpty && accounts.allSatisfy(deliveryAllowed)
    }

    private func canDeliver(_ account: String) -> Bool {
        active && !removalNeedsRepair && !disabled.contains(account) && !forgettingAccess.contains(account) && access.mailGrant(accountID: account) == .granted && deliveryAllowed(account)
    }

    private func kickDelivery() {
        deliveryWake?.cancel(); deliveryWake = nil
        guard active, delivery != nil else { return }
        if deliveryTask != nil { deliveryDirty = true; return }
        deliveryTask = Task { [weak self] in await self?.runDelivery() }
    }

    private func runDelivery() async {
        guard let delivery, let intentStore else { deliveryTask = nil; return }
        defer {
            deliveryTask = nil
            // Reactivation can arrive while a cancelled HTTP pass is unwinding.
            // Its queued wake must survive until this pass releases the worker.
            if active && deliveryDirty { kickDelivery() }
        }
        while active && !Task.isCancelled {
            deliveryDirty = false
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let eligible = access.connectedAccountIDs.filter { canDeliver($0) }
            var worked = false, next: Int64?
            for account in eligible {
                if let retry = deliveryRetryAt[account], retry > now {
                    next = min(next ?? retry, retry); continue
                }
                do {
                    let outcome = try await delivery.deliverNext(account: account, at: now)
                    if outcome != .idle { worked = true }
                    deliveryRetryAt[account] = nil
                    if let due = try await intentStore.nextAttempt(account: account) { next = min(next ?? due, due) }
                } catch is CancellationError { return }
                catch {
                    let retry = now + 30_000
                    deliveryRetryAt[account] = retry
                    next = min(next ?? retry, retry)
                    failures.insert(account); publishAccounts()
                }
            }
            if Task.isCancelled || !active { return }
            if worked || deliveryDirty { continue }
            if let next {
                let delay = max(0.05, Double(next - now) / 1000)
                deliveryWake = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    self?.kickDelivery()
                }
            }
            return
        }
    }

    private func deliverySettled(account: String, message: String, keys: [SentKey], outcome: GmailIntentDelivery.Outcome) async {
        guard let coordinator = actionCoordinator, let intentStore else { return }
        do {
            try await coordinator.refresh(account: account, messages: [message])
            if outcome == .refused {
                // A superseded in-flight response cannot refuse a newer user action.
                let current = try await intentStore.assertions(account: account, messages: [message])
                let sent = Set(keys.map { "\($0.sentSeq):\($0.labelRef)" })
                var emitted = Set<Int64>()
                for row in current where row.state == .refused && sent.contains("\(row.seq):\(row.assertion.labelRef)") {
                    if emitted.insert(row.groupSeq).inserted, let failure = row.failure {
                        emit(.refused(MailReceipt(sequence: UInt64(row.groupSeq), count: nil), failure))
                    }
                }
            }
            refreshAfterAction()
            refreshRefusals()
        } catch {
            projectionNeedsRepair = true
            status.value.store = .unavailable(.unavailable)
        }
    }

    private func refreshRefusals() {
        guard let intentStore else { return }
        refusalTask?.cancel()
        refusalTask = Task { [weak self] in
            do {
                let page = try await intentStore.refused()
                guard !Task.isCancelled, let self else { return }
                self.status.value.refused = Array(page.prefix(50))
                self.status.value.refusedHasMore = page.count > 50
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.status.value.store = .unavailable(.unavailable)
            }
        }
    }

    func refusedChanges(after receipt: MailReceipt? = nil) async throws -> [MailRefusedChange] {
        guard let intentStore else { return [] }
        guard (receipt?.sequence ?? 0) <= UInt64(Int64.max) else { throw MailIntentStore.Failure.invalidGroup }
        return try await intentStore.refused(after: Int64(receipt?.sequence ?? 0))
    }

    /// The review sheet waits for local persistence, not network delivery.
    func retryAndWait(_ receipt: MailReceipt) async {
        retry(receipt)
        await actionTask?.value
    }

    func retry(_ receipt: MailReceipt) {
        guard receipt.sequence <= UInt64(Int64.max), let coordinator = actionCoordinator else { return }
        let prior = actionTask
        actionTask = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            do {
                try await coordinator.retry(group: Int64(receipt.sequence))
                self.refreshAfterAction(); self.refreshRefusals(); self.kickDelivery()
            } catch MailActionCoordinator.Failure.projectionAfterCommit {
                self.projectionNeedsRepair = true
                self.status.value.store = .unavailable(.unavailable)
                self.refreshRefusals()
            } catch { self.status.value.store = .cannotSave(.unavailable) }
        }
    }

    private func repairActionProjection() {
        guard projectionNeedsRepair, let coordinator = actionCoordinator else { return }
        let prior = actionTask
        actionTask = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            do {
                try await coordinator.recover(resetDelivery: false)
                self.projectionNeedsRepair = false
                self.actionThrough = self.lastFinishedAction
                self.status.value.store = .ready
                self.refreshAfterAction()
            } catch {
                self.status.value.store = .unavailable(.unavailable)
            }
        }
    }
}

extension MailLiveSource {
    /// In-flight readers can finish out of order. No later error may shorten a
    /// provider deadline already installed by another reader for this account.
    private func recordReadFailure(_ error: Error, account: String, minimumDelay: TimeInterval? = nil) {
        // Never log account identifiers, SQL, provider bodies or message content.
        let detail: String
        if let gmail = error as? GmailError { detail = String(describing: gmail) }
        else if let database = error as? DatabaseError { detail = "sqlite code=\(database.extendedResultCode.rawValue)" }
        else { detail = "\(String(reflecting: type(of: error))); code=\((error as NSError).code)" }
        reportReadFailure(detail)
        failures.insert(account)
        if error as? GmailError == .unauthorized { access.dropMailAccessToken(accountID: account) }
        let rateLimited: Bool
        if case GmailError.limited = error { rateLimited = true } else { rateLimited = false }
        // An unrelated failed page/label read must not stall a usable reader.
        // Only the sync loop requests transient-error backoff for its own work.
        guard rateLimited || minimumDelay != nil else { return }
        let now = Date()
        var delay = minimumDelay ?? 5
        var health: MailSyncHealth = .offline
        if case .limited = syncHealth[account], let previous = syncRetryAt[account], previous > now {
            health = .limited(until: previous)
        }
        if let gmail = error as? GmailError {
            switch gmail {
            case .limited(_, let hint):
                delay = max(delay, hint.flatMap { $0.isFinite ? $0 : nil } ?? 30)
                health = .limited(until: now)
            case .apiDisabled: health = .apiDisabled
            case .domainPolicy: health = .notAllowedByAdmin
            default: break
            }
        }
        let retry = max(syncRetryAt[account] ?? .distantPast, now.addingTimeInterval(delay))
        if case .limited = health { health = .limited(until: retry) }
        syncRetryAt[account] = retry
        syncHealth[account] = health
    }

    private func stopSync(account: String? = nil) {
        for key in Array(syncTasks.keys) where account == nil || account == key {
            syncTasks[key]?.cancel(); syncTasks[key] = nil; syncOwners[key] = nil
        }
    }

    private func startSync(_ account: String) {
        guard active, !disabled.contains(account), !forgettingAccess.contains(account), access.mailGrant(accountID: account) == .granted,
              syncTasks[account] == nil, let worker = mailboxSync else { return }
        let owner = UUID()
        syncOwners[account] = owner
        syncTasks[account] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.syncOwners[account] == owner {
                    self.syncTasks[account] = nil; self.syncOwners[account] = nil
                }
            }
            var attempts = 0
            while !Task.isCancelled, self.active, !self.disabled.contains(account),
                  self.access.mailGrant(accountID: account) == .granted {
                do {
                    while let retry = self.syncRetryAt[account], retry > Date() {
                        try await Task.sleep(for: .seconds(max(0, retry.timeIntervalSinceNow)))
                    }
                    try Task.checkCancellation()
                    let progress = try await worker.pass(account: account, nowMS: Int64(Date().timeIntervalSince1970 * 1000))
                    try Task.checkCancellation()
                    if let retry = self.syncRetryAt[account], retry > Date() {
                        // A concurrent body request may have been rate-limited
                        // while this pass was in flight. Its deadline still wins.
                        self.syncHealth[account] = .limited(until: retry)
                        self.publishAccounts()
                        continue
                    }
                    self.syncRetryAt[account] = nil
                    let moreFill = try await self.queueSyncFill(account)
                    try Task.checkCancellation()
                    attempts = 0
                    self.failures.remove(account)
                    self.lastSync[account] = Date()
                    let more = progress.hasMore || moreFill
                    self.syncHealth[account] = more ? .catchingUp : .live
                    try await self.loadRemovalStatus()
                    self.publishAccounts()
                    try await Task.sleep(for: .seconds(more ? 2 : 30))
                } catch {
                    guard !Task.isCancelled else { return }
                    switch error {
                    case GmailHistorySync.Failure.wrongAccount, GmailReconcileSync.Failure.wrongAccount,
                         GmailVerificationSync.Failure.wrongAccount:
                        self.syncHealth[account] = .wrongAccount
                        self.publishAccounts()
                        return
                    default: break
                    }
                    attempts = min(attempts + 1, 6)
                    let delay = min(300, 5 * pow(2, Double(attempts - 1)))
                    self.recordReadFailure(error, account: account, minimumDelay: delay)
                    self.publishAccounts()
                    // The next iteration honors this deadline, including after
                    // hiding/reopening Mail or a manual Check mail request.
                }
            }
        }
    }

    private func queueSyncFill(_ account: String) async throws -> Bool {
        // An account on the cloud mailbox is filled by the cloud and pulled in bulk; the
        // per-message fill below is for a service without it.
        if let pull = cloudPull, try await pull.isCloud(account) { kickCloud(); return false }
        let after = fillAfter[account]
        var rows = try await stores.index.read { try MailSyncFill.page(account: account, after: after, in: $0) }
        if rows.isEmpty, after != nil {
            rows = try await stores.index.read { try MailSyncFill.page(account: account, after: nil, in: $0) }
        }
        try Task.checkCancellation()
        fillAfter[account] = rows.last?.cursor
        for row in rows { enqueue(.body(row.id), priority: false) }
        return !rows.isEmpty
    }

    private func refreshRemovalStatus() {
        removalStatusTask?.cancel()
        removalStatusTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.loadRemovalStatus() }
            catch {
                guard !Task.isCancelled else { return }
                self.status.value.store = .unavailable(.unavailable)
            }
        }
    }

    func loadRemovalStatus() async throws {
        let counts = try await stores.index.read { db -> ([String: Int], [String: Int]) in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.email,h.kept,count(*) FROM held_removal h JOIN message m ON m.msg_pk=h.msg_pk
                JOIN account a ON a.account_pk=m.account_pk GROUP BY a.email,h.kept
                """)
            var held: [String: Int] = [:], kept: [String: Int] = [:]
            for row in rows {
                let account: String = row[0], isKept: Bool = row[1], count: Int = row[2]
                if isKept { kept[account] = count } else { held[account] = count }
            }
            return (held, kept)
        }
        var held = counts.0
        if let intentStore {
            for id in try await intentStore.pendingRemovalReviews() {
                if let review = try await intentStore.removalReview(id) { held[review.account] = max(held[review.account] ?? 0, review.count) }
            }
        }
        try Task.checkCancellation()
        let other = status.value.questions.filter { if case .removalHeld = $0.kind { return false }; return true }
        let questions = other + held.keys.sorted().map { account in
            MailQuestion(id: .init(raw: "removal:" + account), kind: .removalHeld(account: account, count: held[account]!), choices: [.keepHere, .remove])
        }
        if status.value.questions != questions { status.value.questions = questions }
        if keptCounts != counts.1 { keptCounts = counts.1; publishAccounts() }
    }

    func beginRemovalReview(account: String) async throws -> MailRemovalReview {
        guard let intentStore, let removalCoordinator else { throw MailRemovalCoordinator.Failure.invalidReview }
        for id in try await intentStore.pendingRemovalReviews() {
            if let review = try await intentStore.removalReview(id), review.account == account { return review }
        }
        return try await removalCoordinator.review(account: account, at: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func removalReviewInfo(_ id: String) async throws -> MailRemovalReview? {
        try await intentStore?.removalReview(id)
    }

    func removalReviewPage(_ id: String, after: String?) async throws -> MailRemovalReviewPage {
        guard let intentStore, let review = try await intentStore.removalReview(id) else { throw MailRemovalCoordinator.Failure.invalidReview }
        let ids = try await intentStore.removalReviewMessages(id, after: after, limit: 51)
        let shown = Array(ids.prefix(50))
        guard !shown.isEmpty else { return MailRemovalReviewPage(rows: [], next: nil) }
        let rows = try await stores.index.read { db -> [String: MailRemovalReviewRow] in
            let slots = Array(repeating: "?", count: shown.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.gmail_id,t.gmail_id,coalesce(m.subject,t.subject,''),m.internal_date,coalesce(m.from_addr,'')
                FROM message m JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=m.account_pk
                WHERE a.email=? AND m.gmail_id IN (\(slots))
                """, arguments: StatementArguments([review.account] + shown))
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let message: String = row[0], thread: String = row[1], milliseconds: Int64 = row[3]
                return (message, MailRemovalReviewRow(id: message, conversation: MailConversationID(account: review.account, thread: thread),
                    subject: row[2], sender: row[4], date: milliseconds > 0 ? Date(timeIntervalSince1970: Double(milliseconds) / 1000) : nil))
            })
        }
        return MailRemovalReviewPage(rows: shown.map { rows[$0] ?? MailRemovalReviewRow(id: $0, conversation: nil,
            subject: "Message no longer cached", sender: "", date: nil) }, next: ids.count > 50 ? shown.last : nil)
    }

    func applyRemovalAnswer(_ id: String, choice: MailChoice) async throws {
        guard let removalCoordinator else { throw MailRemovalCoordinator.Failure.invalidReview }
        removalNeedsRepair = true
        do {
            try await removalCoordinator.answer(id, choice: choice, at: Int64(Date().timeIntervalSince1970 * 1000))
            try await loadRemovalStatus()
            let pending = try await intentStore?.pendingRemovalReviews() ?? []
            removalNeedsRepair = !pending.isEmpty
            if !removalNeedsRepair {
                if !projectionNeedsRepair { status.value.store = .ready }
                kickDelivery()
            }
        } catch {
            status.value.store = .cannotSave(.unavailable)
            if let pending = try? await intentStore?.pendingRemovalReviews() { removalNeedsRepair = !pending.isEmpty }
            try? await loadRemovalStatus()
            if !removalNeedsRepair { kickDelivery() }
            throw error
        }
    }

    func discardRemovalReview(_ id: String) async {
        try? await intentStore?.discardRemovalReview(id)
    }

    func resolveDraftQuestion(_ id: MailDraftID, choice: MailChoice) async throws -> MailDraft? {
        await draftWork?.value
        guard let driver = draftDriver else { throw MailDraftDriver.Failure.notFound }
        switch choice {
        case .keepAsDraft: try await driver.keepLegacyAsDraft(id)
        case .checkAgain: try await driver.flush(id)
        case .keepMine, .useOther: try await driver.resolveConflict(id, keepMine: choice == .keepMine)
        default: throw MailDraftDriver.Failure.notEditable
        }
        guard let record = try await driver.record(id) else { return nil }
        draftCache.removeValue(forKey: id)
        draftChanged(record)
        resumeDraftDelivery()
        return [.sent, .deleted].contains(record.state) ? nil : draftCache[id]
    }

    func answer(_ question: MailQuestion.ID, _ choice: MailChoice) {
        if question.raw.hasPrefix("draft:"), let driver = draftDriver {
            let id = MailDraftID(raw: String(question.raw.dropFirst(6)))
            enqueueDraftWork { [weak self] in
                do {
                    switch choice {
                    case .keepAsDraft: try await driver.keepLegacyAsDraft(id)
                    case .checkAgain: try await driver.flush(id)
                    case .keepMine, .useOther:
                        try await driver.resolveConflict(id, keepMine: choice == .keepMine)
                        self?.resumeDraftDelivery()
                    default: return
                    }
                } catch { self?.emit(.draftNotSaved(id, .unavailable)) }
            }
            return
        }
        // Review handles refer to exact staged ids; an account-level notice is not
        // enough authority to include messages that arrived after it was displayed.
        Task { [weak self] in try? await self?.applyRemovalAnswer(question.raw, choice: choice) }
    }
}

extension MailLiveSource {
    func prepareDrafts(intent: MailIntentStore, scope: String, api: any GmailDraftAPI,
                       contextAllowed: @escaping @Sendable () async -> Bool,
                       compose: @escaping @Sendable (MailDraftRecord.Snapshot) throws -> GmailDraftComposition) async throws {
        guard draftDriver == nil else { return }
        try await intent.importLegacyDrafts(scope: scope, accounts: Set(access.connectedAccountIDs))
        let driver = MailDraftDriver(scope: scope, store: intent, api: api,
            token: { [access] account in try await access.mailAccessToken(accountID: account).value },
            allowed: { [weak self] account in
                guard await contextAllowed() else { return false }
                return await self?.canDeliver(account) ?? false
            }, compose: compose, changed: { [weak self] record in
                Task { @MainActor in self?.draftChanged(record) }
            })
        draftDriver = driver
        durablePendingDraftSends = try await driver.hasPendingSends()
        // Bounded startup window. Additional records remain in the durable store.
        for record in try await driver.records() { draftChanged(record) }
        refreshDrafts()
    }
    private func enqueueDraftWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = draftWork
        draftWork = Task { await previous?.value; await work() }
    }
    private static func draftRow(_ record: MailDraftRecord) -> MailRow {
        let draft = record.snapshot, snippet = draft.body.blocks.flatMap(\.runs).map(\.text).joined(separator: " ")
        return MailRow(id: draft.conversation, key: MailOrderKey(group: 0,
            sortKey: Int64(draft.editedAt.timeIntervalSince1970 * 1000), tie: MailMessageImporter.tie(account: draft.account, thread: draft.conversation.thread)),
            date: draft.editedAt, people: draft.to, peopleTotal: draft.to.count, messageCount: 1,
            subject: draft.subject, snippet: String(snippet.prefix(300)), isUnread: false, isStarred: false,
            isImportant: false, hasAttachment: !draft.attachments.isEmpty, isInvitation: false,
            inInbox: false, isMuted: false, hasPendingChange: record.needsDelivery, fromGmailSearch: false,
            labels: [], reason: .draft(firstLine: String(snippet.prefix(100))))
    }
    private func draftReceipt() -> MailReceipt {
        let sequence = nextActionSequence; nextActionSequence += 1
        return MailReceipt(sequence: UInt64(sequence), count: 1)
    }
    private func draftChanged(_ record: MailDraftRecord) {
        let id = record.snapshot.id, previous = draftStates[id]
        if let generation = draftGenerations[id], generation > record.generation { return }
        draftGenerations[id] = record.generation
        draftCacheOrder.removeAll { $0 == id }; draftCacheOrder.append(id)
        while draftCacheOrder.count > 100 {
            guard let victim = draftCacheOrder.first(where: { !draftSaveFailures.contains($0) && $0 != id }) else { break }
            draftCacheOrder.removeAll { $0 == victim }
            draftCache.removeValue(forKey: victim); draftStates.removeValue(forKey: victim); draftGenerations.removeValue(forKey: victim)
        }
        if let driver = draftDriver {
            Task { [weak self] in
                if let pending = try? await driver.hasPendingSends() { self?.durablePendingDraftSends = pending }
            }
        }
        var draft = record.snapshot.value
        switch record.state {
        case .held: draft.delivery = .held(until: record.sendAt ?? Date())
        case .sending: draft.delivery = .sending
        case .uncertain: draft.delivery = .checking
        case .failed: draft.delivery = .failed(.other)
        default: break
        }
        if record.deliveryFailed == true, record.state != .uncertain { draft.delivery = .failed(.other) }
        if let cached = draftCache[id], cached.editedAt > draft.editedAt {
            var newer = cached; newer.delivery = draft.delivery; draftCache[id] = newer
        } else { draftCache[id] = draft }
        draftStates[id] = record.state
        let questionID = MailQuestion.ID(raw: "draft:" + id.raw)
        status.value.questions.removeAll { $0.id == questionID }
        if record.conflict {
            status.value.questions.append(MailQuestion(id: questionID, kind: .draftChangedElsewhere(id), choices: [.keepMine, .useOther]))
        } else if record.state == .uncertain {
            status.value.questions.append(MailQuestion(id: questionID, kind: .sendUnconfirmed(id, draftStillInGmail: nil), choices: record.legacyReview == true ? [.keepAsDraft] : [.checkAgain]))
        }
        if record.state == .sent && previous != nil && previous != .sent {
            emit(.sent(id, draft.conversation))
            if record.thenDone { _ = apply(.done, to: .conversations([draft.conversation])) }
        }
        if record.state == .failed && previous != nil && previous != .failed { emit(.sendFailed(id, .other)) }
        for (token, subscription) in conversationSubscriptions where subscription.id == draft.conversation { refreshConversation(token) }
        for token in subscriptions.keys { refresh(token) }
    }
    func newDraft(_ kind: MailDraftKind) async -> MailDraft {
        let account: String
        switch kind {
        case .new(let selected): account = selected ?? accounts.first(where: { $0.state == .connected && deliveryAllowed($0.id) })?.id ?? ""
        case .reply(let message), .replyAll(let message), .forward(let message): account = message.account
        case .toAddress: account = accounts.first(where: { $0.state == .connected && deliveryAllowed($0.id) })?.id ?? ""
        }
        let id = MailDraftID(raw: UUID().uuidString.lowercased())
        var draft = MailDraft(id: id, conversation: .init(account: account, thread: "local:" + id.raw), account: account,
            isReply: false, isForward: false, from: .init(account: account, address: account, name: nil, isDefault: true, hasSignature: false),
            to: [], cc: [], bcc: [], subject: "", body: .init(blocks: []), signature: nil, quote: nil, attachments: [],
            format: .banana, schedule: nil, remindIfNoReply: nil, delivery: nil, encodedBytes: 0, editedAt: Date())
        var replyID: String?, forwardMessageID: String?
        do {
            guard let driver = draftDriver, !account.isEmpty else { throw MailDraftDriver.Failure.notFound }
            switch kind {
            case .new: break
            case .toAddress(let addresses, let subject):
                draft.to = addresses.map { MailPerson(name: nil, address: $0, isMe: false, isKnown: false, fromTheirMail: false) }
                draft.subject = subject ?? ""
            case .reply(let message), .replyAll(let message), .forward(let message):
                let identity = try await stores.index.read { db -> (String, String?)? in
                    guard let row = try Row.fetchOne(db, sql: "SELECT t.gmail_id,m.rfc_message_id FROM message m JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=m.account_pk WHERE a.email=? AND m.gmail_id=?", arguments: [account, message.message]) else { return nil }
                    return (row[0], row[1])
                }
                guard let identity, let conversation = await conversation(.init(account: account, thread: identity.0)),
                      var original = conversation.messages.first(where: { $0.id == message }) else { throw MailDraftDriver.Failure.notFound }
                let forward: Bool; if case .forward = kind { forward = true } else { forward = false }
                if !forward, let existing = try await driver.forConversation(conversation.id), existing.state == .editing { return existing.snapshot.value }
                try await conversationLoader.body(message)
                if let hydrated = await self.conversation(conversation.id)?.messages.first(where: { $0.id == message }) { original = hydrated }
                let originalBody = await body(message)
                draft.conversation = conversation.id; draft.isReply = !forward; draft.isForward = forward
                let recipients = MailReplyRules.recipients(for: kind, original: original, myAddresses: Set(accounts.map { $0.id.lowercased() }))
                draft.to = recipients.to; draft.cc = recipients.cc
                draft.subject = MailReplyRules.subject(for: kind, original: conversation.subject)
                draft.quote = MailReplyRules.quote(message: original, body: originalBody, subject: conversation.subject, forward: forward)
                replyID = forward ? nil : identity.1
                if forward {
                    forwardMessageID = message.message
                    draft.attachments = original.attachments.map {
                        MailDraftAttachment(id: $0.id.part, name: $0.name, bytes: $0.bytes, file: nil, isExecutable: $0.isExecutable)
                    }
                }
            }
            try await driver.create(draft, inReplyTo: replyID, forwardMessageID: forwardMessageID)
            draftCache[id] = draft; draftStates[id] = .editing
        } catch {
            // The composer retains this value and receives an explicit save failure.
            draftCache[id] = draft; status.value.store = .cannotSave(.unavailable); emit(.draftNotSaved(id, .unavailable))
        }
        return draft
    }
    func draft(_ id: MailDraftID) async -> MailDraft? {
        if let cached = draftCache[id] { return cached }
        guard let record = try? await draftDriver?.record(id) else { return nil }
        draftChanged(record); return draftCache[id]
    }
    func save(_ draft: MailDraft) {
        draftCache[draft.id] = draft
        guard let driver = draftDriver else { emit(.draftNotSaved(draft.id, .unavailable)); return }
        enqueueDraftWork { [weak self] in
            do { try await driver.save(draft); self?.draftSaveFailures.remove(draft.id) }
            catch { self?.draftCache[draft.id] = draft; self?.draftSaveFailures.insert(draft.id); self?.status.value.store = .cannotSave(.unavailable); self?.emit(.draftNotSaved(draft.id, .unavailable)); return }
            self?.resumeDraftDelivery()
        }
    }
    @discardableResult func send(_ id: MailDraftID, _ options: MailSendOptions) -> MailReceipt {
        guard let driver = draftDriver else { return MailReceipt(sequence: 0, count: 0) }
        let receipt = draftReceipt(), expectedEditToken = draftCache[id]?.editToken
        enqueueDraftWork { [weak self] in
            guard self?.draftSaveFailures.contains(id) == false else { self?.emit(.notSaved(receipt, .unavailable)); return }
            do { try await driver.queueSend(id, options: options, expectedEditToken: expectedEditToken); self?.emit(.applied(receipt, count: 1)) }
            catch { self?.emit(.notSaved(receipt, .unavailable)); return }
            self?.resumeDraftDelivery()
        }
        return receipt
    }
    func cancelSend(_ id: MailDraftID) async -> Bool {
        await draftWork?.value
        return (try? await draftDriver?.cancelSend(id)) ?? false
    }
    func rewriteAsText(_ id: MailDraftID) async -> MailDraft? {
        await draftWork?.value
        do {
            let value = try await draftDriver?.rewriteAsText(id)
            if let value { draftCache[id] = value; resumeDraftDelivery() }
            return value
        } catch { emit(.draftNotSaved(id, .unavailable)); return nil }
    }
    func addAttachment(_ file: URL, to id: MailDraftID) async -> MailDraftAttachment? {
        await draftWork?.value
        do { return try await draftDriver?.addAttachment(file, to: id) }
        catch { emit(.draftNotSaved(id, .unavailable)); return nil }
    }
    func removeAttachment(_ attachment: String, from id: MailDraftID) {
        guard let driver = draftDriver else { return }
        enqueueDraftWork { [weak self] in
            do { try await driver.removeAttachment(attachment, from: id) }
            catch { self?.emit(.draftNotSaved(id, .unavailable)) }
        }
    }
    func retrySend(_ id: MailDraftID) { guard let driver = draftDriver else { return }; enqueueDraftWork { try? await driver.retry(id) } }
    @discardableResult func discard(_ id: MailDraftID) -> MailReceipt {
        guard let driver = draftDriver else { return MailReceipt(sequence: 0, count: 0) }
        let receipt = draftReceipt(); draftUndo[receipt.sequence] = id
        enqueueDraftWork { [weak self] in
            do { try await driver.discard(id); self?.emit(.applied(receipt, count: 1)); try await driver.flush(id) }
            catch { self?.emit(.notSaved(receipt, .unavailable)) }
        }
        return receipt
    }
    var hasUnfinishedSends: Bool { durablePendingDraftSends || draftStates.values.contains { [.held, .sending, .uncertain].contains($0) } }
    func finishSends(within limit: TimeInterval) async {
        await draftWork?.value
        guard let driver = draftDriver else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var cursor = ""
                repeat {
                    guard !Task.isCancelled else { return }
                    let records = (try? await driver.pendingRecords(after: cursor)) ?? []
                    guard let last = records.last else { return }
                    for record in records where [.held, .sending, .uncertain].contains(record.state) {
                        guard !Task.isCancelled else { return }
                        try? await driver.flush(record.snapshot.id, now: Date())
                    }
                    cursor = last.snapshot.id.raw
                } while true
            }
            group.addTask { try? await Task.sleep(for: .seconds(max(0, limit))) }
            await group.next(); group.cancelAll()
        }
    }

    private func refreshDrafts() {
        guard active, draftReadTask == nil, let driver = draftDriver else { return }
        let connected = accounts.filter { $0.state == .connected }.map(\.id)
        draftReadTask = Task { [weak self] in
            defer { self?.draftReadTask = nil }
            for account in connected {
                let scan = UUID().uuidString
                var cursor: String?, seen = Set<String>(), complete = true
                repeat {
                    guard !Task.isCancelled, self?.active == true else { return }
                    do { cursor = try await driver.syncPage(account: account, pageToken: cursor, scan: scan) }
                    catch { complete = false; break } // Preserve cached drafts and local intent on incomplete reads.
                    if let cursor, !seen.insert(cursor).inserted { complete = false; break }
                } while cursor != nil
                if complete { try? await driver.finishScan(account: account, scan: scan) }
            }
        }
    }
    private func resumeDraftDelivery() {
        guard active, let driver = draftDriver else { return }
        if draftDeliveryTask != nil { draftDeliveryDirty = true; return }
        draftWake?.cancel(); draftWake = nil
        draftDeliveryTask = Task { [weak self] in
            var cursor = "", nextWake = Date().addingTimeInterval(30)
            repeat {
                guard !Task.isCancelled else { break }
                let records = (try? await driver.pendingRecords(after: cursor)) ?? []
                guard let last = records.last else { break }
                for record in records {
                    if record.state == .held, let due = record.sendAt, due > Date() { nextWake = min(nextWake, due) }
                    try? await driver.flush(record.snapshot.id)
                }
                cursor = last.snapshot.id.raw
            } while true
            guard let self else { return }
            self.draftDeliveryTask = nil
            if self.draftDeliveryDirty { self.draftDeliveryDirty = false; self.resumeDraftDelivery(); return }
            guard self.active else { return }
            let delay = max(0.1, nextWake.timeIntervalSinceNow)
            self.draftWake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.resumeDraftDelivery()
            }
        }
    }
}

#endif
