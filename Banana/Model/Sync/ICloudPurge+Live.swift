import CloudKit
import Foundation

/// The purge as the app runs it (`SpaceSyncLaunch` hands it to `MoveOver`): CloudKit, iCloud Drive
/// and the key-value store themselves. Everything it decides is in `ICloudPurge`.
extension ICloudPurge {
    static func live(account: String) -> ICloudPurge {
        ICloudPurge(Dependencies(
            cloudKit: LiveICloudPurgeCloudKit(), drive: LiveICloudPurgeDrive(),
            keyValues: NSUbiquitousKeyValueStore.default, keyValueCopies: .standard,
            container: AppCloud.containerID, legacyContainer: AppCloud.legacyContainerID,
            // CloudKit ends the process for a container it isn't entitled to (`CloudSyncPoll.isAllowed`).
            iCloudAllowed: CloudSyncPoll.isAllowed,
            localDefaults: .standard, supportDirectory: AppSupport.directory,
            account: account, defaults: .standard,
            mode: { LegacyCloud.mode($0) }, turnOff: { LegacyCloud.set(.off, for: $0) },
            log: { PlaybackDiagnostics.shared.log("☁️ purge", $0) }))
    }
}

@MainActor
struct LiveICloudPurgeCloudKit: ICloudPurgeCloudKit {
    private func database(_ container: String) -> CKDatabase { CKContainer(identifier: container).privateCloudDatabase }

    func zoneNames(container: String) async throws -> Set<String> {
        Set(try await database(container).allRecordZones().map(\.zoneID.zoneName))
    }

    func deleteZones(_ names: [String], container: String) async throws -> [String: ICloudPurgeOutcome] {
        let (_, results) = try await database(container).modifyRecordZones(
            saving: [], deleting: names.map { CKRecordZone.ID(zoneName: $0) })
        return Dictionary(uniqueKeysWithValues: results.map { id, result in
            (id.zoneName, Self.outcome(result, missing: [.zoneNotFound, .userDeletedZone]))
        })
    }

    func subscriptionIDs(container: String) async throws -> Set<String> {
        Set(try await database(container).allSubscriptions().map(\.subscriptionID))
    }

    func deleteSubscriptions(_ ids: [String], container: String) async throws -> [String: ICloudPurgeOutcome] {
        let (_, results) = try await database(container).modifySubscriptions(saving: [], deleting: ids)
        return Dictionary(uniqueKeysWithValues: results.map { id, result in
            (id, Self.outcome(result, missing: [.unknownItem]))
        })
    }

    private static func outcome(_ result: Result<Void, Error>, missing: Set<CKError.Code>) -> ICloudPurgeOutcome {
        switch result {
        case .success: return .deleted
        case .failure(let error as CKError) where missing.contains(error.code): return .missing
        case .failure(let error): return .failed(error.localizedDescription)
        }
    }
}

@MainActor
struct LiveICloudPurgeDrive: ICloudPurgeDrive {
    /// `url(forUbiquityContainerIdentifier:)` can block: off the main thread. Nil for a container
    /// this build isn't entitled to.
    func documents(container: String) async -> URL? {
        guard !container.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: container)?
                .appendingPathComponent("Documents", isDirectory: true)
        }.value
    }

    func remove(_ url: URL) async throws -> Int {
        try await Task.detached(priority: .utility) { try Self.removeCoordinated(url) }.value
    }

    /// The item, or its not-yet-downloaded placeholder (`.<name>.icloud`), deleted through a file
    /// coordinator so iCloud Drive deletes it everywhere.
    private nonisolated static func removeCoordinated(_ url: URL) throws -> Int {
        let manager = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard let target = [url, placeholder].first(where: { manager.fileExists(atPath: $0.path) }) else { return 0 }
        var isDirectory: ObjCBool = false
        manager.fileExists(atPath: target.path, isDirectory: &isDirectory)
        var files = 1
        if isDirectory.boolValue {
            files = (manager.enumerator(at: target, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }.count
        }
        var coordinatorError: NSError?
        var removeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forDeleting,
                                                         error: &coordinatorError) { coordinated in
            do {
                try manager.removeItem(at: coordinated)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                files = 0   // gone meanwhile: done
            } catch {
                removeError = error
            }
        }
        if let error = coordinatorError ?? removeError { throw error }
        return files
    }
}
