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
                await GoogleCalendarService.shared.restoreIfNeeded()
                _ = await BananaAccount.shared.refresh()
                let access = MailCloudAccess()
                let (stores, intent) = try await Task.detached(priority: .userInitiated) {
                    let root = AppSupport.directory.appendingPathComponent("BananaMail", isDirectory: true)
                    let directories = try MailDirectories(root: root)
                    return (try MailStores.open(directories, migrations: MailSlices.migrations()),
                            try MailIntentStore(directories: directories))
                }.value
                let api = GmailHTTP(cloudTransport: { path, reference, query, method, body in
                        try await BananaAccount.shared.mailRequest(path: path, reference: reference, query: query, method: method, body: body)
                    }, draftTransport: { reference, body in
                        try await BananaAccount.shared.mailDraftRequest(reference: reference, body: body)
                    }, partTransport: { reference, operation, hash, data in
                        try await BananaAccount.shared.mailAttachmentRequest(reference: reference, operation: operation, hash: hash, data: data)
                    }, networkAllowed: { FeatureAccessStore.network.allows("email") })
                let source = MailLiveSource(stores: stores, access: access, api: api, deliveryAllowed: { account in
                        FeatureAccessStore.shared.allows("email") && AppVariant.current.mayCallGoogle(method: "POST", account: account, testAccounts: BetaTestAccounts.all)
                    })
                try await source.prepareActions(intent: intent)
                if let scope = FeatureAccessStore.shared.mailContext {
                    try await source.prepareDrafts(intent: intent, scope: scope, api: api,
                        contextAllowed: { await MainActor.run { FeatureAccessStore.shared.mailContext == scope } },
                        compose: { snapshot in
                            guard snapshot.format == .banana, snapshot.signature?.complete != false,
                                  snapshot.quote?.complete != false else {
                                throw MailDraftDriver.Failure.attachmentsNotReady
                            }
                            let rendered = MailBodyHTML.message(body: snapshot.body, signature: snapshot.signature?.value, quote: snapshot.quote?.value)
                            let person: (MailPerson) -> GmailDraftComposition.Person = { .init(address: $0.address, name: $0.name) }
                            return GmailDraftComposition(from: .init(address: snapshot.from.address, name: snapshot.from.name),
                                to: snapshot.to.map(person), cc: snapshot.cc.map(person), bcc: snapshot.bcc.map(person),
                                subject: snapshot.subject, plain: rendered.plain, html: rendered.html, attachments: [],
                                inReplyTo: snapshot.inReplyTo, references: snapshot.inReplyTo.map { [$0] },
                                threadID: snapshot.isReply ? snapshot.conversation.thread : nil)
                        })
                }
                session = MailSession.installLive(source)
            } catch {
                // Preserve all files and credentials. Retry never deletes a damaged/newer store.
                failed = true
            }
            loading = false; startup = nil
        }
    }
}

#endif
