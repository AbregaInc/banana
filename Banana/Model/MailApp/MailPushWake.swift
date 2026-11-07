import Foundation
#if os(iOS)
import UIKit
#endif

/// A silent push from Banana Cloud's mailbox (`b.k == "mail"`, MAIL-CLOUD-SYNC §2a): new mail's
/// text is stored there. One feed pass and a bulk pull of the new messages, inside the window the
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
        if app.session == nil {
            // Woken with no Mail in this process: open its store (the same startup as the tab),
            // waiting a little for it.
            app.start()
            let start = ContinuousClock.now
            while app.session == nil, !app.failed, ContinuousClock.now - start < .seconds(8) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let source = app.session?.source as? MailLiveSource else { return false }
        let ok = await source.catchUpFromPush(budget: budget)
        PlaybackDiagnostics.shared.log("☁️ push", "mail \(ok ? "pulled" : "not pulled")")
        return ok
        #endif
    }

    #if os(iOS)
    /// iOS gives a background push about 30 s: the completion goes at the pass's end or after 25 s,
    /// and the work runs under a background task until then.
    static func handle(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        let window = Window(completion)
        Task { @MainActor in
            let ok = await catchUp(budget: .seconds(20))
            window.finish(ok ? .newData : .noData)
            window.end()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            window.finish(.newData)
        }
    }

    /// The push's completion, called once, and the background task that covers the work.
    @MainActor private final class Window {
        private var completion: ((UIBackgroundFetchResult) -> Void)?
        private var task = UIBackgroundTaskIdentifier.invalid
        init(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
            self.completion = completion
            task = UIApplication.shared.beginBackgroundTask(withName: "mail-push") { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        }
        func finish(_ result: UIBackgroundFetchResult) { completion?(result); completion = nil }
        func end() {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task); task = .invalid
        }
    }
    #endif
}
