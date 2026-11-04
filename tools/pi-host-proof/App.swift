import Foundation
import JavaScriptCore
import UIKit

@main
final class ProofApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Pi Proof", sessionRole: session.role)
        configuration.delegateClass = ProofScene.self
        return configuration
    }
}

final class ProofScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var context: AppleRuntimeHost?
    private var timeout: Timer?
    private var completed = false
    private let output = UITextView()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wasBackgrounded = false

    private var lifecycleEnabled: Bool { argument("--mode", fallback: "memory") == "lifecycle-live" }

    func sceneWillResignActive(_ scene: UIScene) {
        guard lifecycleEnabled, !completed, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Close Pi durable session") { [weak self] in
            MainActor.assumeIsolated {
                self?.context?.stop()
                self?.context = nil
                self?.endBackgroundTask()
            }
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard lifecycleEnabled, !completed else { return }
        wasBackgrounded = true
        let assertion = backgroundTask
        context?.setForeground(false) { [weak self] result, passed in
            if !passed { print("Pi background close failed: \(result)") }
            if self?.backgroundTask == assertion { self?.endBackgroundTask() }
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        endBackgroundTask()
        guard lifecycleEnabled, wasBackgrounded, !completed else { return }
        wasBackgrounded = false
        // If the OS expired cleanup, a new runtime reopens the same Pi database.
        if let context {
            context.setForeground(true) { result, passed in
                if !passed { print("Pi foreground resume failed: \(result)") }
            }
        } else { run() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let controller = UIViewController()
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        output.text = "Pi Durable — native Apple host proof\n"
        output.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(output)
        NSLayoutConstraint.activate([
            output.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            output.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            output.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            output.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async { self.run() }
    }

    private func argument(_ name: String, fallback: String) -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return fallback }
        return args[index + 1]
    }

    private func run() {
        timeout?.invalidate()
        let mode = argument("--mode", fallback: "memory")
        UIApplication.shared.isIdleTimerDisabled = true
        let group = argument("--case", fallback: "default")
        guard group.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil else {
            finish("Invalid case identifier", passed: false, mode: mode, group: "invalid")
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let database = documents.appendingPathComponent("\(group)-\(mode.hasPrefix("crash") ? "crash" : "persist").sqlite")
        output.text += "Mode: \(mode)\nDevice: \(UIDevice.current.model), \(UIDevice.current.systemVersion)\n"
        timeout = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish("Timed out after 90 seconds", passed: false, mode: mode, group: group) }
        }
        do {
            context = try startPiProof(mode: mode, databasePath: database.path,
                                      sourceDirectory: Bundle.main.resourceURL!, bundleURL: Bundle.main.url(forResource: "pi", withExtension: "js")!) {
                [weak self] result, passed in
                self?.finish(result, passed: passed, mode: mode, group: group)
            }
        } catch {
            finish(String(describing: error), passed: false, mode: mode, group: group)
        }
    }

    private func finish(_ result: String, passed: Bool, mode: String, group: String) {
        guard !completed else { return }
        completed = true
        timeout?.invalidate()
        endBackgroundTask()
        output.text += "\(passed ? "PASS" : "FAIL")\n\(result)\n"
        let report: [String: Any] = ["mode": mode, "passed": passed, "result": result,
                                   "platform": UIDevice.current.model, "os": UIDevice.current.systemVersion]
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destination = documents.appendingPathComponent("\(group)-\(mode).json")
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: destination, options: .atomic)
        } catch { print("Could not persist report: \(error)") }
        print("PI_PROOF_\(passed ? "PASS" : "FAIL") \(mode) \(result)")
        fflush(stdout)
        if ProcessInfo.processInfo.arguments.contains("--headless") {
            DispatchQueue.main.async { exit(passed ? 0 : 1) }
        }
    }
}
