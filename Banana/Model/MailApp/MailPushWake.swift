import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// A silent push from Banana Cloud's mailbox (`b.k == "mail"`, MAIL-CLOUD-SYNC §2a): new mail's
/// text is stored there, or a snooze woke a conversation (its labels changed in the feed). One feed pass and a bulk pull of the new messages, inside the window the
/// push gives (no new background mode: the app's existing `remote-notification` handling).
/// Nothing runs on a device where Mail was never opened (MAIL-ENGINE invariant 16), and nothing is
/// shown: a visible new-mail notice is the owner's product decision, not made here.
@MainActor enum MailPushWake {
    /// Whether Mail has ever been opened on this device: its store exists.
    static var mailWasOpened: Bool {
        FileManager.default.fileExists(atPath: AppSupport.directory.appendingPathComponent("BananaMail", isDirectory: true).path)
    }

    /// Pulls what the push announced. True when a pass got through.
    static func catchUp(budget: Duration = .seconds(20)) async -> Bool {
        #if BANANA_PUBLIC
        return false
        #else
        guard mailWasOpened else { return false }
        let app = MailApplication.shared
        // A push needs live credentials as well as the local session. Keep both inside
        // the same launch window; opening the UI can use saved membership sooner.
        let deadline = ContinuousClock.now + budget
        app.start()
        if BananaAccount.shared.account == nil {
            Task { await app.refreshAccount() }
        }
        let readyBy = min(deadline, ContinuousClock.now + .seconds(8))
        let source = await withTaskGroup(of: MailLiveSource?.self) { group in
            group.addTask { @MainActor in
                for await (session, failed, account) in app.$session.combineLatest(app.$failed, BananaAccount.shared.$account).values {
                    if failed || Task.isCancelled { return nil }
                    if let session, account != nil { return session.source as? MailLiveSource }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(until: readyBy, clock: .continuous)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        guard let source, !Task.isCancelled else { return false }
        let ok = await source.catchUpFromPush(budget: ContinuousClock.now.duration(to: deadline))
        PlaybackDiagnostics.shared.log("☁️ push", "mail \(ok ? "pulled" : "not pulled")")
        return ok
        #endif
    }

    #if os(iOS)
    /// iOS gives a background push about 30 s: the completion goes at the pass's end or after 25 s,
    /// and the work runs under a background task until then.
    static func handle(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Window(completion).start()
    }

    @MainActor private final class Window {
        private var completion: ((UIBackgroundFetchResult) -> Void)?
        private var assertion: AppBackgroundTask?
        private var worker: Task<Void, Never>?
        private var timeout: Task<Void, Never>?

        init(_ completion: @escaping (UIBackgroundFetchResult) -> Void) { self.completion = completion }

        func start() {
            assertion = AppBackgroundTask(named: "mail-push") { [weak self] in self?.finish(.failed) }
            worker = Task {
                let ok = await MailPushWake.catchUp()
                finish(ok ? .newData : .noData)
            }
            timeout = Task {
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                finish(.failed)
            }
        }

        private func finish(_ result: UIBackgroundFetchResult) {
            guard let callback = completion else { return }
            completion = nil
            worker?.cancel()
            worker = nil
            timeout?.cancel()
            timeout = nil
            assertion?.end()
            assertion = nil
            callback(result)
        }
    }
    #endif
}
