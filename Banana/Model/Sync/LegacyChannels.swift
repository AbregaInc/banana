import CloudKit
import Foundation

/// Today's iCloud channels (DATA-INVENTORY.md) as `MoveOver` drives them (`LegacyChannel`). Each
/// is a thin view of one sync: the sync reads its tier's mode wherever it writes or fetches, and
/// these say when the mode changed and ask for the complete fetch. A zone with both tiers'
/// data (Controls, Fitness) is two channels over one sync, each draining the zone and keeping
/// its own types' part.
@MainActor
final class ControlsLegacyChannel: LegacyChannel {
    let name: String
    let tier: LegacyTier
    let types: Set<String>
    private let sync: CloudControlsSync

    init(_ sync: CloudControlsSync, tier: LegacyTier) {
        self.sync = sync
        self.tier = tier
        if sync.channel == .meals {
            name = "meals zone"
            types = LegacyInventory.meals
        } else {
            name = tier == .health ? "controls zone (health)" : "controls zone"
            types = tier == .health ? LegacyInventory.controlsHealth : LegacyInventory.controls
        }
    }

    func setMode(_ mode: LegacyCloudMode) { sync.modeChanged() }
    func drainToEnd() async throws -> DrainResult { try await drained { try await self.sync.drainToEnd() }.only(types) }
}

@MainActor
final class WellnessLegacyChannel: LegacyChannel {
    let name = "wellness zone"
    let tier = LegacyTier.health
    let types = LegacyInventory.wellness

    func setMode(_ mode: LegacyCloudMode) { CloudWellnessSync.shared.modeChanged() }
    func drainToEnd() async throws -> DrainResult { try await drained { try await CloudWellnessSync.shared.drainToEnd() }.only(types) }
}

@MainActor
final class ProgressLegacyChannel: LegacyChannel {
    let name = "progress zone"
    let tier = LegacyTier.personal
    let types = LegacyInventory.progress

    func setMode(_ mode: LegacyCloudMode) { CloudProgressSync.shared.modeChanged() }
    func drainToEnd() async throws -> DrainResult { try await drained { try await CloudProgressSync.shared.drainToEnd() }.only(types) }
}

@MainActor
final class FitnessLegacyChannel: LegacyChannel {
    let name: String
    let tier: LegacyTier
    let types: Set<String>

    init(tier: LegacyTier) {
        self.tier = tier
        name = tier == .health ? "fitness zone" : "fitness zone (voice notes)"
        types = tier == .health ? LegacyInventory.fitness : LegacyInventory.fitnessNotes
    }

    func setMode(_ mode: LegacyCloudMode) { CloudFitnessSync.shared.modeChanged() }
    func drainToEnd() async throws -> DrainResult { try await drained { try await CloudFitnessSync.shared.drainToEnd() }.only(types) }
    func drainKept() { CloudFitnessSync.shared.drainKept(tier: tier) }
}

@MainActor
final class SettingsLegacyChannel: LegacyChannel {
    let name = "settings zone"
    let tier = LegacyTier.personal
    let types = LegacyInventory.settings

    func setMode(_ mode: LegacyCloudMode) { CloudSettingsSync.shared.modeChanged() }
    func drainToEnd() async throws -> DrainResult { try await drained { try await CloudSettingsSync.shared.drainToEnd() }.only(types) }
}

/// The key-value store's keys (`LegacyKVS`, which reads the mode on every call). A drain is one
/// exchange with the system; the stores apply what changed as they always do.
@MainActor
final class KeyValueLegacyChannel: LegacyChannel {
    let name: String
    let tier: LegacyTier
    let types: Set<String>

    init(tier: LegacyTier) {
        self.tier = tier
        name = tier == .health ? "key-value store (health)" : "key-value store"
        types = tier == .health ? LegacyInventory.kvsHealth : LegacyInventory.kvs
    }

    func setMode(_ mode: LegacyCloudMode) {}

    func drainToEnd() async throws -> DrainResult {
        LegacyKVS.shared.synchronize()
        return DrainResult()
    }
}

/// iCloud Drive: transcripts and voice-note files (the backup is held back by either tier, in
/// `CloudBackup`). Writes ask `LegacyCloud` each time; a drain reads the voice notes once more.
@MainActor
final class DriveLegacyChannel: LegacyChannel {
    let name = "iCloud Drive"
    let tier = LegacyTier.personal
    let types = LegacyInventory.drive

    func setMode(_ mode: LegacyCloudMode) {}

    func drainToEnd() async throws -> DrainResult {
        await VoiceNoteStore.shared.refreshFromCloud(force: true)
        return DrainResult()
    }
}

extension LegacyCloud {
    /// Every legacy channel this process runs, for `MoveOver`. Once, after the syncs have started.
    @MainActor static func registerChannels() {
        guard channels.isEmpty else { return }
        let all: [any LegacyChannel] = [
            ControlsLegacyChannel(.shared, tier: .personal),
            ControlsLegacyChannel(.shared, tier: .health),
            ControlsLegacyChannel(.meals, tier: .health),
            WellnessLegacyChannel(),
            ProgressLegacyChannel(),
            FitnessLegacyChannel(tier: .health),
            FitnessLegacyChannel(tier: .personal),
            SettingsLegacyChannel(),
            KeyValueLegacyChannel(tier: .personal),
            KeyValueLegacyChannel(tier: .health),
            DriveLegacyChannel(),
        ]
        kept = all
        for channel in all { register(channel) }
    }

    /// `register` holds channels weakly; these are the process's own.
    @MainActor private static var kept: [any LegacyChannel] = []
}

/// A zone's drain, where a device signed out of iCloud holds nothing there to drain: iCloud
/// can't be written from it either, so the move goes on. Any other failure waits.
@MainActor
private func drained(_ drain: () async throws -> DrainResult) async throws -> DrainResult {
    do {
        return try await drain()
    } catch let error as CKError where error.code == .notAuthenticated {
        return DrainResult()
    }
}
