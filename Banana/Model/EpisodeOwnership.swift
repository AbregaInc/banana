import Foundation

/// An episode's id is the publisher's guid (or its audio URL), and the per-episode stores (downloads,
/// transcripts, progress, skip plans) are keyed by that id alone. Two shows claiming one id would
/// share one download and one transcript. The first show to bring an id keeps it: another feed's
/// item with the same id is left out of that feed's episodes. (Audit run-1, 26 Oct 2026.)
enum EpisodeOwnership {
    /// `episodes` from the feed at `feedURL`, without those whose id another subscribed show already
    /// holds: in its episode list, or only in its progress (an episode that has since left that
    /// show's feed still owns its progress and download). `dropped` is how many were left out.
    static func unclaimed(_ episodes: [Episode], feedURL: URL, among others: [Podcast]) -> (kept: [Episode], dropped: Int) {
        var claimed = Set<String>()
        for other in others where other.feedURL != feedURL {
            claimed.formUnion(other.episodeIDs())
            claimed.formUnion(other.positions.keys)
            claimed.formUnion(other.completed)
        }
        guard !claimed.isEmpty else { return (episodes, 0) }
        let kept = episodes.filter { !claimed.contains($0.id) }
        return (kept, episodes.count - kept.count)
    }
}
