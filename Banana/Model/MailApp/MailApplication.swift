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
                let access = try await MailGoogleAccess.configured()
                let (stores, intent) = try await Task.detached(priority: .userInitiated) {
                    let root = AppSupport.directory.appendingPathComponent("BananaMail", isDirectory: true)
                    let directories = try MailDirectories(root: root)
                    return (try MailStores.open(directories, migrations: MailSlices.migrations()),
                            try MailIntentStore(directories: directories))
                }.value
                let source = MailLiveSource(stores: stores, access: access,
                    api: GmailHTTP(networkAllowed: { true }), deliveryAllowed: { account in
                        AppVariant.current.mayCallGoogle(method: "POST", account: account, testAccounts: BetaTestAccounts.all)
                    })
                try await source.prepareActions(intent: intent)
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
