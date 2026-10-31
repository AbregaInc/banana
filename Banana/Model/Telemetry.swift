import Foundation
#if os(iOS)
import UIKit
#endif

/// Banana's own usage counts (docs/design/TELEMETRY.md): how many copies are opened each day, how
/// far the first run gets, and which features are used — counted on the device, sent once in a
/// while as one small batch to the Banana service (`Service/`), never what's in them. No names,
/// amounts, times, places or health data: an event is one word from a fixed list, sometimes with a
/// second. The service drops anything else. Signed in to a Banana account (`BananaAccount`), the
/// batch carries the session and is also counted for the account (docs/design/ACCOUNTS.md).
///
/// Only the official app sends: the service's host comes from the private config
/// (`BANANA_SERVICE_HOST`), so a build without it sends nothing. Usage and diagnostic uploads
/// require an affirmative Share usage choice in Settings; an absent choice means no consent.
@MainActor
final class Telemetry {
    static let shared = Telemetry()

    /// One counted thing. The words are the service's allow-list (`Service/src/usage.js`).
    struct Signal: Hashable, Codable, Sendable {
        var event: String
        var name: String = ""
        var detail: String = ""

        static let active = Signal(event: "active")

        enum Step: String, CaseIterable { case welcome, wake, winddown, calendar, otherCalendar, done }
        enum StepAction: String, CaseIterable { case shown, continued, skipped }
        static func onboarding(_ step: Step, _ action: StepAction) -> Signal {
            Signal(event: "onboarding", name: step.rawValue, detail: action.rawValue)
        }

        enum Feature: String, CaseIterable {
            case mealLogged, labelRead, groceriesScanned, eventCreated, eventEdited, reminderCreated, routineStarted
            case podcastPlayed, noteCreated, workoutOpened, reviewOpened, calendarConnected
        }
        enum Detail: String, CaseIterable {
            case none = "", photo, describe, search, scan, byHand, groceries, parser, model, failed, voice, written
        }
        static func feature(_ feature: Feature, _ detail: Detail = .none) -> Signal {
            Signal(event: "feature", name: feature.rawValue, detail: detail.rawValue)
        }

        enum Failure: String, CaseIterable { case googleSignIn, mealEstimate, labelRead, calendarWrite }
        static func failure(_ failure: Failure) -> Signal { Signal(event: "failure", name: failure.rawValue) }

        /// How the copy is set up, once a day (`TelemetryState`). Each fact is a separate
        /// count; signed-in batches are also kept per account. No health/food inventory.
        enum Setup: String, CaseIterable {
            case googleAccounts, calendars, busyBlocks, reminders, notifications, location, watch, appleIntelligence
            case routines, podcasts, notes
            /// Which modules are on (17 Oct 2026): which front door people pick.
            case allModules, workoutsModule, foodModule, notesModule, podcastsModule
            case os, region, language, textSize, appearance
        }
        /// The answers a setup fact can have; `os`, `region` and `language` are a number or a code.
        enum Answer: String, CaseIterable {
            case zero = "0", one = "1", two = "2", few = "3-5", several = "6-10", many = "11-20", lots = "21+"
            case on, off, granted, denied, notAsked, paired, none
            case standard, smaller, larger, accessibility, light, dark
        }
        static func setup(_ fact: Setup, _ answer: Answer) -> Signal {
            Signal(event: "setup", name: fact.rawValue, detail: answer.rawValue)
        }
        static func setup(_ fact: Setup, count: Int) -> Signal { setup(fact, Telemetry.bucket(count)) }
        /// An OS major version ("27"), a region ("US") or a language ("en").
        static func setup(_ fact: Setup, code: String) -> Signal? {
            let valid: Bool
            switch fact {
            case .os: valid = code.count <= 3 && code.allSatisfy(\.isNumber)
            case .region: valid = code.count == 2 && code.allSatisfy { $0.isASCII && $0.isUppercase }
            case .language: valid = (2...3).contains(code.count) && code.allSatisfy { $0.isASCII && $0.isLowercase }
            default: valid = false
            }
            return valid ? Signal(event: "setup", name: fact.rawValue, detail: code) : nil
        }

        var key: String { [event, name, detail].joined(separator: "|") }
        init(event: String, name: String = "", detail: String = "") {
            (self.event, self.name, self.detail) = (event, name, detail)
        }
        init?(key: String) {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            // Old installs may have queued inventory derived from health/food stores.
            // Never serialize those counts, even after upgrading with a pending batch.
            guard !(parts[0] == "setup" && ["workouts7d", "meals7d", "supplements", "myFoods"].contains(parts[1])) else { return nil }
            (event, name, detail) = (parts[0], parts[1], parts[2])
        }
    }

    static let shareUsageKey = "shareAnonymousUsage"
    static let privacyURL = URL(string: "https://bananatheapp.com/privacy")!
    static let termsURL = URL(string: "https://bananatheapp.com/terms")!

    private let defaults = UserDefaults.standard
    private let host: String?
    /// Whether a calendar is connected, asked when a batch is made.
    var calendarConnected: () -> Bool = { false }
    /// How the copy is set up (`TelemetryState.signals`), counted with the day's first opening.
    var setup: (() async -> [Signal])?
    /// The Banana account's session, when signed in (`BananaAccount`).
    var session: () -> String? = { nil }
    private var sending = false

    private init() {
        host = BananaService.host
    }

    /// Whether this build has a collector to send to: the official app.
    var canSend: Bool { host != nil }

    /// An untouched install has not consented to optional analytics. Shared by usage and
    /// diagnostic sending through `enabled`; account/Health sync has separate consent.
    static func hasUsageConsent(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: shareUsageKey) as? Bool == true
    }

    /// Whether this copy counts anything at all.
    var enabled: Bool {
        guard host != nil, Self.hasUsageConsent(in: defaults) else { return false }
        #if targetEnvironment(simulator)
        return false
        #else
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] == nil && !process.arguments.contains("--ui-audit")
        #endif
    }

    func record(_ signal: Signal) {
        guard enabled else { return }
        var pending = defaults.dictionary(forKey: "telemetryPending") as? [String: Int] ?? [:]
        pending[signal.key, default: 0] += 1
        defaults.set(pending, forKey: "telemetryPending")
    }

    /// Opened today: counted once a day, whenever the app comes forward. Then whatever has piled
    /// up goes.
    func cameForward(now: Date = Date()) {
        guard enabled else { return }
        if defaults.object(forKey: "telemetryFirstOpened") == nil { defaults.set(now, forKey: "telemetryFirstOpened") }
        let today = TelemetryBatch.dayKey(now)
        guard defaults.string(forKey: "telemetryLastActive") != today else { return send(now: now) }
        defaults.set(today, forKey: "telemetryLastActive")
        record(.active)
        Task {
            for signal in await setup?() ?? [] { record(signal) }
            send(now: now)
        }
    }

    /// Sends what's counted, if anything, and forgets it once the collector has it.
    func send(now: Date = Date()) {
        guard enabled, !sending, let host,
              let pending = defaults.dictionary(forKey: "telemetryPending") as? [String: Int], !pending.isEmpty
        else { return }
        let firstOpened = defaults.object(forKey: "telemetryFirstOpened") as? Date ?? now
        let batch = TelemetryBatch(platform: Self.platform, channel: Self.channel, version: Self.version,
                                   firstOpened: firstOpened, now: now, calendar: calendarConnected(),
                                   pending: pending)
        guard let body = try? JSONEncoder().encode(batch) else { return }
        let request = BananaService.request(.usage(body), host: host, session: session())
        sending = true
        Task {
            let sent = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 204 } ?? false
            sending = false
            guard sent else { return }
            // Only what was sent is taken off: anything counted while it was on its way stays.
            var left = defaults.dictionary(forKey: "telemetryPending") as? [String: Int] ?? [:]
            for (key, count) in pending { left[key] = max(0, (left[key] ?? 0) - count) }
            defaults.set(left.filter { $0.value > 0 }, forKey: "telemetryPending")
        }
    }

    /// Turned off: nothing more is counted, and what's waiting is thrown away.
    func turnedOff() {
        defaults.removeObject(forKey: "telemetryPending")
    }

    /// A number as a range: exact counts would help single a copy out.
    nonisolated static func bucket(_ count: Int) -> Signal.Answer {
        switch count {
        case ..<1: .zero
        case 1: .one
        case 2: .two
        case 3...5: .few
        case 6...10: .several
        case 11...20: .many
        default: .lots
        }
    }

    // MARK: - What a batch says about the copy

    static var platform: String {
        #if os(macOS)
        return "mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    /// Installed from the App Store, from TestFlight, or by a developer (Xcode, our own installs).
    static var channel: String {
        #if os(iOS)
        if Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil { return "dev" }
        #else
        if FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile").path),
           Bundle.main.appStoreReceiptURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            return "dev"
        }
        #endif
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "testflight" : "appstore"
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "0") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }
}

/// One batch as the collector takes it. Pure, for tests.
struct TelemetryBatch: Encodable, Equatable {
    struct Event: Encodable, Equatable {
        var event: String
        var name: String
        var detail: String
        var count: Int
    }

    var platform: String
    var channel: String
    var version: String
    /// The ISO week the copy was first opened ("2026-W42") and the days since: enough to tell how
    /// many come back, without anything that singles one out.
    var cohort: String
    var since: Int
    var calendar: Bool
    var events: [Event]

    init(platform: String, channel: String, version: String, firstOpened: Date, now: Date, calendar: Bool,
         pending: [String: Int], utc: Calendar = TelemetryBatch.utc) {
        self.platform = platform
        self.channel = channel
        self.version = version
        let week = utc.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstOpened)
        cohort = String(format: "%04d-W%02d", week.yearForWeekOfYear ?? 2026, week.weekOfYear ?? 1)
        since = max(0, utc.dateComponents([.day], from: utc.startOfDay(for: firstOpened), to: utc.startOfDay(for: now)).day ?? 0)
        self.calendar = calendar
        events = pending.compactMap { key, count in
            guard count > 0, let signal = Telemetry.Signal(key: key) else { return nil }
            return Event(event: signal.event, name: signal.name, detail: signal.detail, count: min(count, 500))
        }
        .sorted { ($0.event, $0.name, $0.detail) < ($1.event, $1.name, $1.detail) }
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension CaseIterable where Self: RawRepresentable, RawValue == String {
    /// Every word of one of `Telemetry.Signal`'s lists.
    static var allCasesRaw: [String] { allCases.map(\.rawValue) }
}
