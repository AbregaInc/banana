import CloudKit
import Foundation

/// One small request that says which zones changed since the last one — so a poll fetches only
/// those, and an idle minute costs a single, nearly empty round trip instead of one per sync.
@MainActor
enum CloudChangeCheck {
    private static let tokenKey = "dbChanges.private.token"

    private static var token: CKServerChangeToken? {
        get {
            UserDefaults.standard.data(forKey: tokenKey).flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
            }
        }
        set {
            if let newValue, let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: tokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tokenKey)
            }
        }
    }

    /// The names of zones changed (or deleted) since the last check — every zone, the first time.
    /// Nil when it couldn't tell (offline, an expired token): then everything is polled.
    static func changedZones() async -> Set<String>? {
        // No container without the entitlement: CloudKit ends the process rather than failing.
        guard CloudSyncPoll.isAllowed else { return [] }
        let database = CKContainer(identifier: AppCloud.containerID).privateCloudDatabase
        var current = token
        var zones: Set<String> = []
        do {
            var more = true
            while more {
                let page = try await database.databaseChanges(since: current)
                zones.formUnion(page.modifications.map(\.zoneID.zoneName))
                zones.formUnion(page.deletions.map(\.zoneID.zoneName))
                current = page.changeToken
                more = page.moreComing
            }
            token = current
            return zones
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil
            return nil
        } catch {
            return nil
        }
    }
}
