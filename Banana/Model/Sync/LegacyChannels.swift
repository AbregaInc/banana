import Foundation

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

/// iCloud Drive: transcripts and voice notes. Writes ask `LegacyCloud` each time; a drain reads
/// the voice notes once more.
#if BANANA_MODULE_PODCASTS && BANANA_MODULE_NOTES
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
#endif

extension LegacyCloud {
    /// Every legacy channel this process runs, for `MoveOver`. Once, after the syncs have started.
    @MainActor static func registerChannels() {
        guard channels.isEmpty else { return }
        #if BANANA_MODULE_PODCASTS && BANANA_MODULE_NOTES
        let drive: any LegacyChannel = DriveLegacyChannel()
        #else
        let drive: any LegacyChannel = UncarriedLegacyChannel("iCloud Drive", .personal, LegacyInventory.drive)
        #endif
        let all: [any LegacyChannel] = [
            KeyValueLegacyChannel(tier: .personal),
            KeyValueLegacyChannel(tier: .health),
            drive,
        ]
        kept = all
        for channel in all { register(channel) }
    }

    /// `register` holds channels weakly; these are the process's own.
    @MainActor private static var kept: [any LegacyChannel] = []
}

/// The channel of a module this build doesn't carry (BANANA_MODULES): its types, and no way to
/// drain them. `MoveOver` counts a tier's types from its channels, so the tier stays uncovered and
/// its iCloud data stays where it is until a build with the module moves it.
@MainActor
final class UncarriedLegacyChannel: LegacyChannel {
    struct NotCarried: Error {}
    let name: String
    let tier: LegacyTier
    let types: Set<String>

    init(_ name: String, _ tier: LegacyTier, _ types: Set<String>) {
        self.name = name + " (module not in this build)"
        self.tier = tier
        self.types = types
    }

    func setMode(_ mode: LegacyCloudMode) {}
    func drainToEnd() async throws -> DrainResult { throw NotCarried() }
}
