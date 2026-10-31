import Foundation

/// One episode's progress as the library keeps it.
struct EpisodeProgressRecord: Codable, Equatable, Sendable {
    var position: Double
    var completed: Bool
    /// The library's last-write-wins stamp, kept with the value: the Watch's reports are compared
    /// with it, so it travels too. Nil for progress of unknown age (no stamp, no last play): it
    /// seeds at the low clock and loses to any stamped copy, never posing as new.
    var updatedAt: Date?
}

/// What the progress adapter needs of the library (`PodcastLibrary`).
@MainActor
protocol ProgressSyncSource: AnyObject {
    /// Every episode with progress here.
    func syncProgressEpisodeIDs() -> [String]
    func syncProgress(_ episodeID: String) -> EpisodeProgressRecord?
    /// Whether the episode is here (in a feed, or with progress of its own).
    func knowsEpisode(_ id: String) -> Bool
    /// Another device's progress through the library's own rule (last stamp wins, ties by
    /// `ProgressTie`); false when the library's copy stands.
    func applySyncedProgress(_ episodeID: String, _ progress: EpisodeProgressRecord) -> Bool
    /// Many at once, saved and announced once.
    func applyingSyncedBatch(_ body: () -> Void)
}

/// `podcast.progress` (§3, §5): `whole`, one field `v` = `{position, completed, updatedAt}` per
/// episode. Podcast progress is precious and must never go back:
/// - **Seeds** at the library's own stamp, a completed copy at counter 1 and a position-only copy
///   at 0 (today's `ProgressTie` rule written into the clock, §3 seeding rule 7).
/// - **Applying** goes through the library's last-write-wins rule. When the library's copy is
///   later (or wins the tie), it stays, and goes up as this device's edit (`keptOwn`), so a
///   position-only copy with an older stamp never replaces a newer one anywhere.
/// - **An episode not here yet** (its show's feed hasn't loaded): `apply` says not yet, and the
///   mirror keeps it until `SpaceSyncLaunch.replay` offers it again once episodes arrive. This
///   takes the place of `cloudProgressParked` for the space.
/// - **Nothing is deleted**: progress has no delete, as today.
enum PodcastProgressAdapter {
    static let type = "podcast.progress"

    @MainActor
    static func binding(_ source: ProgressSyncSource, now: @escaping @Sendable () -> Date = { Date() }) -> SyncBinding {
        weak var weakSource = source
        func items(_ ids: [String]) -> [String: any Encodable & Sendable] {
            guard let source = weakSource else { return [:] }
            var found: [String: any Encodable & Sendable] = [:]
            for id in ids {
                if let progress = source.syncProgress(id) {
                    found[id] = PreparedItem { try SyncShape.wrapped.encode(progress) }
                }
            }
            return found
        }
        var binding = SyncBinding(
            type: type,
            snapshot: { items(weakSource?.syncProgressEpisodeIDs() ?? []) },
            items: { ids in items(Array(ids)) },
            apply: { records in
                guard let source = weakSource else { return [:] }
                var results: [String: SyncApplied] = [:]
                source.applyingSyncedBatch {
                    for record in records {
                        guard let incoming = try? SyncShape.wrapped.decode(EpisodeProgressRecord.self, from: record.fields) else {
                            results[record.id] = .taken   // a newer build's: nothing to apply
                            continue
                        }
                        guard source.knowsEpisode(record.id) else {
                            results[record.id] = .notYet
                            continue
                        }
                        if source.applySyncedProgress(record.id, incoming) {
                            results[record.id] = .taken
                        } else if let own = source.syncProgress(record.id), !same(own, incoming),
                                  !isFutureStamped(own, now: now()) {
                            results[record.id] = .keptOwn
                        } else {
                            // The library's copy stands but doesn't go up: the same, or stamped
                            // ahead of this device's clock (skew), which must not win everywhere.
                            results[record.id] = .taken
                        }
                    }
                }
                return results
            },
            remove: { _ in })
        binding.seedClock = { weakSource?.syncProgress($0)?.updatedAt }
        binding.seedRank = { weakSource?.syncProgress($0)?.completed == true ? 1 : 0 }
        return binding
    }

    /// A copy stamped further ahead of now than clock jitter allows (`PlaybackSyncClock`): its own
    /// device's clock was wrong when it was stamped.
    static func isFutureStamped(_ progress: EpisodeProgressRecord, now: Date) -> Bool {
        guard let at = progress.updatedAt else { return false }
        return PlaybackSyncClock.isSkewed(at, now: now)
    }

    /// The same progress, as far as a listener can tell: a finish is a finish wherever it stopped.
    static func same(_ a: EpisodeProgressRecord, _ b: EpisodeProgressRecord) -> Bool {
        if a.completed || b.completed { return a.completed == b.completed }
        return abs(a.position - b.position) < 0.5
    }
}
