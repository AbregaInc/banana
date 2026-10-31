import Foundation
import os

/// The Watch's copy of the ad-skip markers, keyed by episode.
///
/// The Watch never builds a plan. It has no speech framework and no on-device model, and it plays
/// only files that were transferred to it — so the phone, which has all three, computes the plan
/// and the Watch simply obeys it. Everything here is therefore receive-and-apply: there is no
/// detector, no correction book, and no way to be wrong about anything except by acting on a plan
/// the phone did not send.
///
/// Plans arrive three ways, all of which land here: alongside the download instruction, in the
/// metadata of the audio file itself, and as a standalone message when the phone learns something
/// after the episode was already delivered. A missing plan is completely ordinary and means the
/// episode plays exactly as it always has.
@MainActor
final class WatchSkipPlanStore {
    static let shared = WatchSkipPlanStore()

    private static let log = Logger(subsystem: "com.boris.banana", category: "adskip")

    private var plans: [String: EpisodeSkipPlan] = [:]

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var fileURL: URL { dir.appendingPathComponent("skip-plans.json") }

    private init() { load() }

    func plan(for episodeID: String) -> EpisodeSkipPlan? { plans[episodeID] }

    /// Adopt a plan that arrived from the phone.
    ///
    /// Anything that isn't automatic is dropped on arrival: the phone already applied its
    /// correction book before sending, and a span the Watch will never act on is a span it should
    /// not be carrying. The byte count is deliberately not checked — the Watch's copy is usually
    /// transcoded on the way over, so its file is a different size on purpose, while the timings
    /// the plan is made of survive transcoding unchanged.
    func adopt(_ payload: Data, for episodeID: String) {
        guard let decoded = try? JSONDecoder().decode(EpisodeSkipPlan.self, from: payload) else {
            Self.log.notice("watch: unreadable skip plan for \(episodeID, privacy: .public); episode will play normally")
            return
        }
        var plan = decoded
        plan.spans = decoded.automaticSpans
        guard !plan.spans.isEmpty else { plans[episodeID] = nil; save(); return }
        plans[episodeID] = plan
        save()
        Self.log.notice("watch: skip plan for \(episodeID, privacy: .public): \(plan.spans.count, privacy: .public) span(s)")
    }

    func forget(_ episodeID: String) {
        guard plans.removeValue(forKey: episodeID) != nil else { return }
        save()
    }

    /// Keep only plans for episodes still on this Watch. A plan whose audio has been pruned
    /// describes nothing.
    func prune(keeping episodeIDs: Set<String>) {
        let gone = plans.keys.filter { !episodeIDs.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { plans[id] = nil }
        save()
    }

    private func load() {
        // Same discipline as everywhere else: a file that fails to parse is copied aside before
        // the next save can write over it. Cheap here — these are markers, not listening history —
        // but a plan file that stops decoding is a bug worth still having a copy of.
        switch SnapshotLoader.load(from: fileURL, as: LossyDictionary<EpisodeSkipPlan>.self) {
        case .empty:
            plans = [:]
        case let .loaded(lossy):
            plans = lossy.elements
        case let .corrupt(error, quarantinedTo):
            plans = [:]
            Self.log.notice("watch: skip-plans.json failed to decode (\(String(describing: error), privacy: .public)); \(quarantinedTo?.lastPathComponent ?? "not quarantined", privacy: .public)")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
