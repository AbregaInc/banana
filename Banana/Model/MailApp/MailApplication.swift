#if !BANANA_PUBLIC
import Foundation
import Combine

/// One asynchronous startup for every Mail window. Disk migration never runs on the UI queue.
@MainActor final class MailApplication: ObservableObject {
    static let shared = MailApplication()
    @Published private(set) var session: MailSession?
    @Published private(set) var failed = false
    @Published private(set) var loading = false
    private var startup: Task<Void, Never>?
    private var accessObservation: AnyCancellable?
    private var accessRefresh: Task<Void, Never>?

    func refreshAccount() async {
        await BananaAccount.shared.refreshShared()
    }

    /// At launch, after the first frame: when the last run left sends or actions queued
    /// (`MailOutgoingMirror`), start the engine so they go out without Mail being opened.
    /// Nothing queued means nothing is opened.
    func startIfOutgoingWorkWaits() {
        guard session == nil, MailOutgoingMirror.isSet(), MailPushWake.mailWasOpened else { return }
        start()
    }

    func start() {
        guard session == nil, startup == nil else { return }
        #if DEBUG && targetEnvironment(simulator)
        if MailRemovalReviewFixture.enabled {
            loading = true; failed = false
            startup = Task {
                do { session = MailSession.installLive(try await MailRemovalReviewFixture.make()) }
                catch { failed = true }
                loading = false; startup = nil
            }
            return
        }
        #endif
        if let fixture = MailSession.shared { session = fixture; return }
        loading = true; failed = false
        startup = Task {
            do {
                let account = BananaAccount.shared
                let needsMembership = account.account == nil && FeatureAccessStore.shared.cachedMailAccounts == nil
                let refresh = Task { await refreshAccount() }
                let access = MailCloudAccess()
                let (stores, intent) = try await Task.detached(priority: .userInitiated) {
                    let root = AppSupport.directory.appendingPathComponent("BananaMail", isDirectory: true)
                    let directories = try MailDirectories(root: root)
                    return (try MailStores.open(directories, migrations: MailSlices.migrations()),
                            try MailIntentStore(directories: directories))
                }.value
                // An older cache needs one authenticated lookup to scope the local index.
                if needsMembership { await refresh.value }
                let api = GmailHTTP(cloudTransport: { path, reference, query, method, body in
                        try await BananaAccount.shared.mailRequest(path: path, reference: reference, query: query, method: method, body: body)
                    }, draftTransport: { reference, body in
                        try await BananaAccount.shared.mailDraftRequest(reference: reference, body: body)
                    }, partTransport: { reference, operation, hash, data in
                        try await BananaAccount.shared.mailAttachmentRequest(reference: reference, operation: operation, hash: hash, data: data)
                    }, networkAllowed: { FeatureAccessStore.network.allows("email") })
                let feed = CloudMailFeed(reference: { account in try await access.mailAccessToken(accountID: account).value },
                    transport: { kind, reference, body in
                        guard FeatureAccessStore.network.allows("email") else { throw GmailError.networkDisabled }
                        return try await BananaAccount.shared.mailFeedRequest(kind: kind, reference: reference, body: body)
                    })
                let source = MailLiveSource(stores: stores, access: access, api: api, cloudFeed: feed,
                    senderPolicyAPI: CloudMailSenderPolicy(feed: feed), deliveryAllowed: { _ in
                        FeatureAccessStore.shared.allows("email")
                    })
                try await source.prepareActions(intent: intent)
                if let scope = FeatureAccessStore.shared.mailContext {
                    try await source.prepareDrafts(intent: intent, scope: scope, api: api,
                        contextAllowed: { await MainActor.run { FeatureAccessStore.shared.mailContext == scope } },
                        compose: { try GmailDraftComposition(snapshot: $0) })
                }
                source.reportReadFailure = { PlaybackDiagnostics.shared.log("mail read", $0) }
                accessObservation = BananaAccount.shared.$account.map { $0?.google }.removeDuplicates().dropFirst().map { _ in () }
                    .merge(with: FeatureAccessStore.shared.$emailAvailable.removeDuplicates().dropFirst().map { _ in () })
                    .sink { [weak self, weak source] _ in
                        guard let self, self.accessRefresh == nil else { return }
                        // Both publishers send before their stored value changes. Coalesce them
                        // and read after the synchronous account/policy update has completed.
                        self.accessRefresh = Task { @MainActor [weak self, weak source] in
                            self?.accessRefresh = nil
                            source?.accessChanged()
                        }
                    }
                session = MailSession.installLive(source)
                // A log an older version let grow is emptied once, after Mail is up.
                Task.detached(priority: .utility) { stores.checkpointOversizedLogs() }
            } catch {
                // Preserve all files and credentials. Log no SQL, account, subject or payload.
                let reason = (error as? MailStoreError).map(String.init(describing:))
                    ?? "\(String(reflecting: type(of: error))); code=\((error as NSError).code)"
                PlaybackDiagnostics.shared.log("mail startup", "failed: \(reason)")
                failed = true
            }
            loading = false; startup = nil
        }
    }

    func readySession() async -> MailSession? {
        start()
        await startup?.value
        return session
    }
}

#endif
