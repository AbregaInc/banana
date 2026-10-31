import Combine
import Foundation

/// How the phone is getting on with the things only it does, so every device's controls can say.
///
/// A setting is one synced value with the same control everywhere (docs/design/ADAPTIVE-LAYOUT.md,
/// rule 5); the phone acts on it. This is the other half: what came of it — learning your trips,
/// or waiting for "Always" location. Kept apart from the settings on purpose: the settings sync as
/// one blob, last writer wins, and the phone writing its status into them would overwrite a change
/// just made on another device.
///
/// Every field is optional and an unknown value reads as nil, so a newer phone's status never
/// fails to decode on an older iPad or Mac.
struct HubStatus: Codable, Equatable, Sendable {
    enum TripLearning: String, Codable, Sendable {
        case running
        case needsAlwaysLocation
        case off

        init(from decoder: Decoder) throws {
            self = TripLearning(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .off
        }
    }

    var updatedAt: Date = .distantPast
    var tripLearning: TripLearning?
    /// Apple Health connected on the phone, and when it last read it.
    var healthConnected: Bool?
    var healthReadAt: Date?
    /// Alarm permission on the phone, and the next alarm it has armed.
    var alarmsAllowed: Bool?
    var nextAlarm: Date?
    /// Whether the phone may show notifications.
    var notificationsAllowed: Bool?
    /// The Watch app's version as it last reported it ("1.0 (51)"), and episodes still on their
    /// way to it.
    var watchVersion: String?
    var watchEpisodesPending: Int?
    /// The phone's last iCloud backup.
    var lastBackup: Date?
    /// The one-off alarms the phone has armed, of the synced list — so an alarm added on the iPad
    /// or the Mac can say whether it will actually ring yet.
    var armedAlarms: [UUID]?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? .distantPast
        tripLearning = try? c.decodeIfPresent(TripLearning.self, forKey: .tripLearning)
        healthConnected = try? c.decodeIfPresent(Bool.self, forKey: .healthConnected)
        healthReadAt = try? c.decodeIfPresent(Date.self, forKey: .healthReadAt)
        alarmsAllowed = try? c.decodeIfPresent(Bool.self, forKey: .alarmsAllowed)
        nextAlarm = try? c.decodeIfPresent(Date.self, forKey: .nextAlarm)
        notificationsAllowed = try? c.decodeIfPresent(Bool.self, forKey: .notificationsAllowed)
        watchVersion = try? c.decodeIfPresent(String.self, forKey: .watchVersion)
        watchEpisodesPending = try? c.decodeIfPresent(Int.self, forKey: .watchEpisodesPending)
        lastBackup = try? c.decodeIfPresent(Date.self, forKey: .lastBackup)
        armedAlarms = try? c.decodeIfPresent([UUID].self, forKey: .armedAlarms)
    }
}

/// Things another device asks the phone to do — the controls for its jobs, pressed on an iPad or
/// the Mac. Each is the moment it was asked; the phone does it once for each new moment.
struct HubRequests: Codable, Equatable, Sendable {
    var watchResync: Date?
    var backUpNow: Date?

    enum Kind: CaseIterable, Sendable { case watchResync, backUpNow }

    subscript(kind: Kind) -> Date? {
        get {
            switch kind {
            case .watchResync: watchResync
            case .backUpNow: backUpNow
            }
        }
        set {
            switch kind {
            case .watchResync: watchResync = newValue
            case .backUpNow: backUpNow = newValue
            }
        }
    }

    /// The requests newer than the ones already done.
    func pending(after handled: HubRequests) -> [Kind] {
        Kind.allCases.filter { kind in
            guard let asked = self[kind] else { return false }
            return asked > (handled[kind] ?? .distantPast)
        }
    }
}

/// The phone's `HubStatus`: written there, read everywhere, over iCloud's key-value store (the
/// same road the phone's wake plan takes).
@MainActor
final class HubStatusStore: ObservableObject {
    static let shared = HubStatusStore()

    @Published private(set) var status = HubStatus()

    private let cloud = LegacyKVS.shared
    private static let key = "hubStatus.v1"
    private static let requestsKey = "hubRequests.v1"
    private static let handledKey = "hubRequestsHandled.v1"
    private var observer: NSObjectProtocol?

    /// The phone's hands for requests from other devices; set at launch.
    var onRequest: ((HubRequests.Kind) -> Void)? {
        didSet { handleRequests() }
    }

    private init() {
        read()
        observer = LegacyKVS.observeExternalChanges(tier: .personal) { [weak self] in
            guard let self else { return }
            let requests = self.storedRequests
            if self.read() { SyncReport.changed(Self.syncStatusType, [Self.syncStatusID]) }
            // Late arrivals for the data platform (this runs as one, `LegacyKVS`).
            if self.storedRequests != requests { SyncReport.changed(Self.syncRequestType, [Self.syncRequestID]) }
            self.handleRequests()
        }
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `SettingsAdapters`)

    static let syncStatusType = "core.hubStatus"
    static let syncStatusID = "hubStatus"
    static let syncRequestType = "core.hubRequest"
    static let syncRequestID = "requests"

    /// Another account signed in on this device and the person said to clear it first
    /// (docs/design/DATA-PLATFORM.md §2): the other account's phone status is forgotten here.
    /// This device only: nothing is reported or published, and iCloud's key-value store isn't
    /// written.
    func resetForAccountChange() {
        status = HubStatus()
    }

    /// What the iPad and the Mac have asked the phone to do.
    var syncRequests: HubRequests { storedRequests }

    /// The phone's status, on an iPad or the Mac: kept as iCloud's was, when it's newer.
    func adoptSynced(_ remote: HubStatus) {
        guard remote.updatedAt > status.updatedAt, let data = try? JSONEncoder().encode(remote) else { return }
        status = remote
        cloud.set(data, forKey: Self.key)   // this device's own copy once it no longer writes iCloud
    }

    /// Requests from another device; on the phone, done at once.
    func adoptSynced(_ remote: HubRequests) {
        guard remote != storedRequests, let data = try? JSONEncoder().encode(remote) else { return }
        cloud.set(data, forKey: Self.requestsKey)
        handleRequests()
    }

    /// From an iPad or the Mac: ask the phone to do one of its jobs. On the phone itself, just do it.
    func request(_ kind: HubRequests.Kind) {
        if DeviceRole.current.isHub {
            onRequest?(kind)
            return
        }
        var requests = storedRequests
        requests[kind] = Date()
        guard let data = try? JSONEncoder().encode(requests) else { return }
        cloud.set(data, forKey: Self.requestsKey)
        cloud.synchronize()
        SyncReport.changed(Self.syncRequestType, [Self.syncRequestID])
    }

    /// The phone: do what's been asked since last time — on a sync from another device, and when
    /// the app comes to the front.
    func handleRequests() {
        guard DeviceRole.current.isHub, let onRequest else { return }
        let handled = (UserDefaults.standard.data(forKey: Self.handledKey))
            .flatMap { try? JSONDecoder().decode(HubRequests.self, from: $0) } ?? HubRequests()
        let requests = storedRequests
        let pending = requests.pending(after: handled)
        guard !pending.isEmpty else { return }
        if let data = try? JSONEncoder().encode(requests) {
            UserDefaults.standard.set(data, forKey: Self.handledKey)
        }
        for kind in pending { onRequest(kind) }
    }

    private var storedRequests: HubRequests {
        cloud.data(forKey: Self.requestsKey).flatMap { try? JSONDecoder().decode(HubRequests.self, from: $0) }
            ?? HubRequests()
    }

    /// The phone only: change its status and publish it. Anywhere else, nothing happens — the
    /// status is the phone's to report.
    func update(_ change: (inout HubStatus) -> Void) {
        guard DeviceRole.current.isHub else { return }
        var next = status
        change(&next)
        guard next != status else { return }
        // Only Health's read time moved: that's the phone's heartbeat, not news. The data
        // platform hears it at most every 10 minutes (every other change at once).
        var heartbeat = next
        heartbeat.healthReadAt = status.healthReadAt
        let onlyHeartbeat = heartbeat == status
        next.updatedAt = Date()
        status = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        cloud.set(data, forKey: Self.key)
        cloud.synchronize()
        if !onlyHeartbeat || next.updatedAt.timeIntervalSince(reportedAt ?? .distantPast) >= Self.heartbeatReport {
            reportedAt = next.updatedAt
            SyncReport.changed(Self.syncStatusType, [Self.syncStatusID])
        }
    }

    /// When the status last went to the data platform, and how often a heartbeat alone may.
    private var reportedAt: Date?
    private static let heartbeatReport: TimeInterval = 10 * 60

    @discardableResult
    private func read() -> Bool {
        guard let data = cloud.data(forKey: Self.key),
              let remote = try? JSONDecoder().decode(HubStatus.self, from: data),
              remote.updatedAt > status.updatedAt else { return false }
        status = remote
        return true
    }
}

extension HubStatus.TripLearning? {
    /// What a "Learn from my trips" control says under itself, given whether it's on, and whether
    /// this device is the phone doing the learning.
    func caption(wanted: Bool, onHub: Bool) -> String? {
        guard wanted else { return nil }
        switch self {
        case .running?:
            return onHub ? nil : "Learning on your iPhone."
        case .needsAlwaysLocation?:
            return onHub
                ? "Needs \u{201C}Always\u{201D} location \u{2014} iOS Settings \u{203A} Banana \u{203A} Location."
                : "Needs \u{201C}Always\u{201D} location on your iPhone."
        case .off?, nil:
            return onHub ? nil : "Starts on your iPhone next time it\u{2019}s open."
        }
    }
}

/// The phone's status in words, for the rows on an iPad or the Mac.
struct PhoneStatusText {
    let status: HubStatus
    var now = Date()

    private func ago(_ date: Date?) -> String? {
        date.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
    }

    var healthLine: String {
        switch status.healthConnected {
        case true?: ["Connected", ago(status.healthReadAt).map { "read \($0)" }].compactMap { $0 }.joined(separator: " \u{00B7} ")
        case false?: "Not connected"
        case nil: "Not reported yet"
        }
    }

    var alarmsLine: String {
        switch status.alarmsAllowed {
        case true?:
            if let next = status.nextAlarm, next > now {
                return "Next \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
            }
            return "Allowed \u{00B7} none armed"
        case false?: return "Not allowed"
        case nil: return "Not reported yet"
        }
    }

    var notificationsLine: String {
        switch status.notificationsAllowed {
        case true?: "Allowed"
        case false?: "Off"
        case nil: "Not reported yet"
        }
    }

    var watchLine: String {
        guard let version = status.watchVersion else { return "Not reported yet" }
        let pending = status.watchEpisodesPending ?? 0
        return pending > 0 ? "\(version) \u{00B7} \(pending) to send" : "Banana \(version)"
    }

    var backupLine: String {
        ago(status.lastBackup).map { "Backed up \($0)" } ?? "Not reported yet"
    }

    /// Under a one-off alarm on the iPad or the Mac: whether the phone has it armed.
    /// There's no push to the phone, so one added here is armed the next time Banana opens there.
    func alarmLine(_ id: UUID) -> String {
        if status.armedAlarms?.contains(id) == true { return "Rings on your iPhone" }
        if status.alarmsAllowed == false { return "Alarms aren\u{2019}t allowed on your iPhone" }
        return "Armed next time Banana opens on your iPhone"
    }
}
