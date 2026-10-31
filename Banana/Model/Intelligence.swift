import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which model a request should go to.
///
/// iOS 27 gives an app two models rather than one: the rebuilt on-device model, and Apple's server
/// models over Private Cloud Compute (`PrivateCloudComputeLanguageModel`) — no API key, no account,
/// no cost, and a context window Apple documents at 32K against the on-device 4K. The cloud model
/// is the better model. It is also **quota-limited**, which is the whole reason this file exists:
/// "always use the good one" runs the quota down on work the small model does perfectly well, and
/// then the good one is missing for the request that actually needed it.
///
/// So requests are routed by what they NEED, not by what would be nicest:
///
/// - Splitting "two eggs and toast" into two items is mechanical. The small model is fine, and
///   sending it to the cloud buys nothing.
/// - Estimating the calories in "1 cup of homemade dal" is real-world knowledge a ~3B on-device
///   model does not reliably have. This is where the app's accuracy complaint actually lives, and
///   where the quota is worth spending.
/// - Reading a Supplement Facts panel off a photo cannot happen on a model without vision at all.
///
/// Everything below degrades: no iOS 27 → on-device, exactly as iOS 26 behaves today; quota
/// exhausted → on-device; nothing available → the caller's own non-model fallback. There is no
/// path where adopting this makes the app worse than it is now.
enum Intelligence {

    /// What a request needs from a model. The routing input, kept separate from the models
    /// themselves so the decision is testable without either one existing.
    enum Need: Equatable, Sendable {
        /// Restructuring text that is already in hand: splitting a phrase into items, tidying a
        /// product name. No outside knowledge required.
        case structuring
        /// Facts about the world the small model does not reliably hold.
        case knowledge
        /// Must look at an image.
        case vision
    }

    enum Route: Equatable, Sendable {
        case cloud
        case device
        /// No model can serve this. The caller falls back to whatever it does without AI —
        /// Vision OCR, the bundled catalog, or a hand-editable empty row.
        case none
    }

    /// What the runtime can currently offer. Snapshotted into a value so the decision below is a
    /// pure function of it, and so a probe can't change mid-decision.
    struct Availability: Equatable, Sendable {
        var deviceAvailable = false
        var deviceSupportsVision = false
        var cloudAvailable = false
        var cloudQuotaReached = false

        /// iOS 26 with Apple Intelligence on: exactly today's behaviour.
        static let deviceOnly = Availability(deviceAvailable: true)
        static let nothing = Availability()

        var cloudUsable: Bool { cloudAvailable && !cloudQuotaReached }
    }

    /// The routing rule. Pure, so every branch is covered by tests on a machine that has neither
    /// model — which is the only way this could be verified before iOS 27 ships to the device.
    static func route(_ need: Need, given availability: Availability) -> Route {
        switch need {
        case .vision:
            // Vision is a hard capability gate, not a preference: a model without it cannot take
            // the image at all, so there is no "worse but workable" tier to fall back to.
            if availability.cloudUsable { return .cloud }
            if availability.deviceAvailable && availability.deviceSupportsVision { return .device }
            return .none

        case .knowledge:
            // The one worth spending quota on. Falls back rather than failing, because a mediocre
            // estimate the person can correct beats an empty row.
            if availability.cloudUsable { return .cloud }
            if availability.deviceAvailable { return .device }
            return .none

        case .structuring:
            // Deliberately device-first even when the cloud is sitting there available. Quota
            // spent here is quota not available for `.knowledge`, and the small model does this
            // job well — the two-pass food extractor exists precisely because splitting is easy
            // and estimating is not.
            if availability.deviceAvailable { return .device }
            if availability.cloudUsable { return .cloud }
            return .none
        }
    }
}

// MARK: - Saying where the work happens

extension Intelligence {
    /// One sentence for copy that tells someone where their words or photo are processed.
    ///
    /// This is not cosmetic. Three screens currently promise "Nothing leaves this iPhone", which
    /// is true on iOS 26 and becomes a false privacy claim the moment a request is routed to
    /// Private Cloud Compute. A promise that silently stops being true is worse than never having
    /// made it, so the sentence is derived from the same availability the routing uses.
    ///
    /// Pure, so the wording is pinned by tests on either OS.
    ///
    /// `device` is the one it is running on ("iPhone", "iPad", "Mac"): the sentence said "this
    /// iPhone" on all three.
    static func privacyNote(for availability: Availability, device: String = DeviceRole.current.name) -> String {
        availability.cloudUsable
            ? "Read on this \(device), or by Apple’s Private Cloud Compute for anything it can’t place on its own."
            : "Nothing leaves this \(device)."
    }

    /// The label under a spinner, for the same reason.
    static func progressNote(for route: Route, device: String = DeviceRole.current.name) -> String {
        route == .cloud ? "Reading that with Apple Intelligence…" : "Reading that on this \(device)…"
    }

    static var privacyNote: String { privacyNote(for: current) }
}

// MARK: - Probing what this device actually has

extension Intelligence {
    /// Asks the system what it can do right now.
    ///
    /// Everything iOS 27 is behind `#available`, so on iOS 26 this returns exactly
    /// `Availability.deviceOnly`-shaped truth and every route lands where it lands today.
    static var current: Availability {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return .nothing }
        var availability = Availability()
        availability.deviceAvailable = SystemLanguageModel.default.availability == .available

        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            availability.deviceSupportsVision =
                SystemLanguageModel.default.capabilities.contains(.vision)
            let cloud = PrivateCloudComputeLanguageModel()
            // Only with the entitlement Apple grants for it, and never on an OS build where it has
            // brought the app down anyway (`CloudModelGuard`). `isAvailable` alone says yes either way.
            availability.cloudAvailable = cloud.isAvailable && CloudModelGuard.entitled && !CloudModelGuard.isBlocked
            // Reading quota is free and local — it is the account's own bookkeeping, not a
            // request — so this costs nothing to check before every routing decision.
            availability.cloudQuotaReached = cloud.quotaUsage.isLimitReached
        }
        return availability
        #else
        return .nothing
        #endif
    }

    /// True when the cloud model is there but close enough to its limit to be worth mentioning.
    /// Surfaced so a UI can explain a sudden drop in quality rather than letting it look like a
    /// regression.
    static var cloudApproachingLimit: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            if case .belowLimit(let below) = PrivateCloudComputeLanguageModel().quotaUsage.status {
                return below.isApproachingLimit
            }
        }
        #endif
        return false
    }
}

// MARK: - Getting a session on the right model

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
extension Intelligence {
    /// A session on whichever model this request should use, and which one that turned out to be.
    ///
    /// The route comes back with the session because callers need it: it decides how big a prompt
    /// may be, whether an image can be attached at all, and what to say when quality drops because
    /// the quota ran out. Returns nil only when no model can serve the request — the caller then
    /// does whatever it does without AI.
    static func session(for need: Need,
                        instructions: String,
                        tools: [any Tool] = [],
                        availability: Availability = Intelligence.current)
    -> (session: LanguageModelSession, route: Route)? {
        switch route(need, given: availability) {
        case .none:
            return nil
        case .cloud:
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
                return (LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools,
                                             instructions: instructions), .cloud)
            }
            // Unreachable: `route` only returns .cloud when the probe found a cloud model, and
            // the probe can only find one on 27. Falling through rather than trapping, because a
            // crash here would be a crash in food logging.
            return (LanguageModelSession(tools: tools, instructions: instructions), .device)
        case .device:
            return (LanguageModelSession(tools: tools, instructions: instructions), .device)
        }
    }

    /// How much room one prompt has, in characters, given a model's context window in tokens.
    ///
    /// Replaces the hand-guessed `prefix(4000)` constants that were reverse-engineered from an
    /// assumed 4,096-token window — a budget that left nothing for the instructions, the schema
    /// or the answer, all of which share that window.
    ///
    /// Pure, and separate from the probe below on purpose: "what is the rule" is the part worth
    /// pinning in a test, and it is the only part that can be pinned on a machine with no iOS 27.
    /// Characters rather than tokens because callers are trimming strings; ~3.5 characters per
    /// token is the usual English figure, and half the window is reserved for everything that
    /// is not the prompt.
    static func promptCharacterBudget(forContextTokens tokens: Int) -> Int {
        max(1_000, (tokens / 2) * 7 / 2)
    }

    /// The context window the chosen route actually has.
    ///
    /// `SystemLanguageModel.contextSize` is back-deployed: a real number on iOS 27, a flat 4,096
    /// below it. The cloud model's own `contextSize` is async and throwing, and this sits on a hot
    /// path where awaiting a round-trip for a budget would be absurd — Apple documents 32K, and
    /// taking a conservative fraction of a documented figure is what a budget is for.
    static func contextTokens(for route: Route) -> Int {
        switch route {
        case .none: return 0
        case .cloud: return 32_768
        case .device: return SystemLanguageModel.default.contextSize
        }
    }

    static func promptCharacterBudget(for route: Route) -> Int {
        guard route != .none else { return 0 }
        return promptCharacterBudget(forContextTokens: contextTokens(for: route))
    }
}
#endif

// MARK: - Shared safety net

extension Intelligence {
    /// Races a model call against a deadline.
    ///
    /// There is no timeout case in the framework's own errors, and on-device there is no network
    /// to time out — but a cloud request genuinely can hang, and a wedged call on either tier
    /// means a person staring at a spinner after typing their lunch. On trip the underlying call
    /// is cancelled and the caller's own fallback runs, which every call site already has.
    static func withTimeout<T: Sendable>(
        seconds: UInt64, route: Route = .device, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await guardingCloud(route) { try await withTimeout(seconds: seconds, operation) }
    }

    /// Notes a call to the cloud model as in flight, so a launch after it took the app down knows
    /// (`CloudModelGuard`). Every call to the cloud model goes through here.
    static func guardingCloud<T>(_ route: Route, _ call: () async throws -> T) async rethrows -> T {
        guard route == .cloud else { return try await call() }
        CloudModelGuard.begin()
        defer { CloudModelGuard.end() }
        return try await call()
    }

    private static func withTimeout<T: Sendable>(
        seconds: UInt64, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimedOut() }
            return result
        }
    }

    struct TimedOut: Error {}
}

// MARK: - When the cloud model takes the app down

/// Apple's cloud model (`PrivateCloudComputeLanguageModel`) needs a managed entitlement,
/// `com.apple.developer.private-cloud-compute`, which Apple grants on request (App Store Small
/// Business Program, under 2 million first-time downloads). Without it, `isAvailable` still says
/// true — and the first request ends in an assertion inside FoundationModels that takes the app
/// down: a crash, not an error a caller can catch. That's what happened on 30 Sep 2026.
///
/// So the cloud model is used only when the app is built with the entitlement — marked by the
/// `BananaPrivateCloudCompute` Info.plist flag, set together with the entitlement in project.yml —
/// and, as a backstop for anything else that brings it down, a call to it is noted while in
/// flight (a file, written before the call, so it survives the crash): a launch that finds the
/// note stops using it on that OS build.
enum CloudModelGuard {
    /// Whether this build carries the cloud model's entitlement (`BananaPrivateCloudCompute`).
    static var entitled: Bool { isEntitled(flag: Bundle.main.object(forInfoDictionaryKey: "BananaPrivateCloudCompute")) }

    static func isEntitled(flag: Any?) -> Bool { (flag as? Bool) == true }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private static var inFlightURL: URL { directory.appendingPathComponent("cloud-model-call-in-flight") }
    private static var blockedURL: URL { directory.appendingPathComponent("cloud-model-blocked-os") }

    static var osBuild: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Whether the cloud model took the app down on this OS build before.
    static var isBlocked: Bool {
        (try? String(contentsOf: blockedURL, encoding: .utf8)) == osBuild
    }

    /// At launch: a call still noted as in flight never came back — it took the app down.
    /// Returns true when that just happened.
    @discardableResult
    static func checkAtLaunch() -> Bool {
        guard FileManager.default.fileExists(atPath: inFlightURL.path) else { return false }
        try? FileManager.default.removeItem(at: inFlightURL)
        try? osBuild.write(to: blockedURL, atomically: true, encoding: .utf8)
        return true
    }

    static func begin() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: inFlightURL)
    }

    static func end() {
        try? FileManager.default.removeItem(at: inFlightURL)
    }
}

