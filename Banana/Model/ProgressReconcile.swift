import Foundation

/// Which episodes' progress still needs to reach CloudKit: those changed here more recently than
/// the last version CloudKit confirmed. Asked at launch and each time the app comes forward, so a
/// change that was lost on the way — a failed send, the app killed before the sync engine saved
/// its queue — is sent again, instead of that episode staying unplayed on every other device.
///
/// Only an episode with a real local timestamp qualifies: one without is of unknown age, and
/// sending it as "now" could overwrite newer progress from another device.
enum ProgressReconcile {
    static func needsUpload(localStamp: Date?, confirmed: Date?) -> Bool {
        guard let localStamp else { return false }
        guard let confirmed else { return true }
        return localStamp > confirmed
    }
}

/// Two copies of an episode's progress stamped at the same moment: which one stands.
///
/// Last-write-wins alone leaves a tie undecided, and each device then keeps its own copy for
/// good — an episode finished on the phone stayed at 41 minutes on the Mac, both stamped alike,
/// and nothing ever re-sends a record both sides have already seen. So a tie has a rule, the same
/// on every device: a finish beats a position, and of two positions the further one wins.
enum ProgressTie {
    struct Copy: Equatable {
        var completed: Bool
        var position: Double?
    }

    /// Stamps this close are one moment: CloudKit keeps a date to the millisecond.
    static func isTie(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 0.001
    }

    /// Whether `a` beats `b` when they're stamped alike. Never both ways, and never for equal
    /// copies, so every device settles on the same one.
    static func beats(_ a: Copy, _ b: Copy) -> Bool {
        if a.completed != b.completed { return a.completed }
        if a.completed { return false }
        return (a.position ?? 0) > (b.position ?? 0)
    }
}

/// Progress from another device for an episode this device doesn't have yet — a show subscribed
/// elsewhere whose feed hasn't loaded here. Kept (on disk) instead of dropped, and handed over
/// once the episode appears; dropping it meant a new iPad showed every finished episode unplayed.
struct ParkedProgress: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var position: Double
        var completed: Bool
        var at: Date
    }

    private(set) var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// Keep an episode's progress until it can be applied; of two for the same episode, the later.
    mutating func park(_ episodeID: String, _ entry: Entry) {
        if let kept = entries[episodeID], kept.at >= entry.at { return }
        entries[episodeID] = entry
    }

    /// The parked progress for episodes this device now has, removed from the waiting list.
    mutating func release(known: (String) -> Bool) -> [(episodeID: String, entry: Entry)] {
        let ready = entries.filter { known($0.key) }
        for id in ready.keys { entries[id] = nil }
        return ready.map { ($0.key, $0.value) }.sorted { $0.episodeID < $1.episodeID }
    }
}
