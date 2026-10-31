import Foundation

/// One page of a zone listed without contents (`CloudZonePoller`), with the change token as data
/// so the listing can be kept on disk and run against fakes.
struct ZoneListingPage: Sendable {
    /// Record names listed (new or changed since the page's starting token).
    var listed: [String] = []
    /// Of those, the ones newer than this device has (`CloudZonePoller.isStale`).
    var stale: [String] = []
    /// Record names deleted since the page's starting token.
    var deleted: [String] = []
    /// Where the listing got to; nil: the zone isn't there.
    var token: Data?
    var moreComing = false
}

/// How far a zone's listing got, kept across interruptions.
struct ZoneListingState: Codable, Equatable, Sendable {
    /// When this listing began from nothing; one older than `ResumableZoneListing.maxAge` starts over.
    var startedAt: Date
    var token: Data?
    var names: Set<String> = []
    /// Listed records newer than this device had, not yet fetched in full (the first poll's bootstrap).
    var stale: Set<String> = []
    /// The last run reached the end of the zone.
    var complete = false
}

enum ZoneListingError: Error, Equatable {
    /// Stopped before the end (background time ran out, the app went to the background).
    case interrupted
    /// The zone isn't there.
    case noZone
    /// A page said there was more without moving the token on.
    case stalled
}

/// A zone's listing of record names, without contents, that picks up where it stopped.
///
/// The fitness zone takes 20–60 s to list on a phone, about what iOS gives a background task, and
/// a listing that starts over each time never ends (the move's drain, §3 seeding rule 1). So each
/// page is kept as it comes (the token and the names so far), and the next run continues from
/// there; deletes on later pages take their names out again. Only a run that reached the end
/// returns: a partial listing is never handed out. A finished listing is kept too, and a later
/// run only reads what changed since (one page, usually). A listing begun more than a day ago
/// starts over. A change token the server no longer takes is the caller's to report (`discard`).
@MainActor
final class ResumableZoneListing {
    static let maxAge: TimeInterval = 86_400

    let file: URL
    private let now: () -> Date
    private let log: (String) -> Void

    init(file: URL, now: @escaping () -> Date = { Date() }, log: @escaping (String) -> Void = { _ in }) {
        self.file = file
        self.now = now
        self.log = log
    }

    /// What is kept on disk, if anything.
    var saved: ZoneListingState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ZoneListingState.self, from: data)
    }

    /// Forget the listing: the next run lists from nothing.
    func discard() {
        try? FileManager.default.removeItem(at: file)
    }

    /// Lists to the end of the zone, from where the last run stopped. `fetch` reads one page from a
    /// token (nil: the start); `stop` is asked before each page. Throws `interrupted` when stopped
    /// (what was read is kept), `noZone` (nothing kept), `stalled`, or `fetch`'s error (kept).
    func run(fetch: (Data?) async throws -> ZoneListingPage, stop: () -> Bool) async throws -> ZoneListingState {
        var listing: ZoneListingState
        if let kept = saved, now().timeIntervalSince(kept.startedAt) < Self.maxAge, kept.token != nil {
            listing = kept
            log(kept.complete ? "listing: catching up a finished listing of \(kept.names.count) name(s)"
                              : "listing: resuming at \(kept.names.count) name(s)")
        } else {
            if saved != nil { log("listing: begun more than a day ago, starting over") }
            listing = ZoneListingState(startedAt: now())
        }
        let fromNothing = listing.token == nil
        var pages = 0
        while true {
            if stop() {
                save(listing)
                throw ZoneListingError.interrupted
            }
            let page = try await fetch(listing.token)
            pages += 1
            guard let next = page.token else {
                // No token: the zone isn't there (or went away). Nothing about it can be said.
                discard()
                throw ZoneListingError.noZone
            }
            if next == listing.token && page.moreComing {
                save(listing)
                throw ZoneListingError.stalled
            }
            listing.names.subtract(page.deleted)
            listing.stale.subtract(page.deleted)
            listing.names.formUnion(page.listed)
            listing.stale.formUnion(page.stale)
            listing.token = next
            listing.complete = !page.moreComing
            save(listing)
            if listing.complete { break }
        }
        log("listing: \(listing.names.count) name(s) after \(pages) page(s)\(fromNothing ? "" : ", resumed")")
        return listing
    }

    /// These stale records were fetched in full: they're no longer owed.
    func fetched(_ names: [String]) {
        guard var listing = saved else { return }
        listing.stale.subtract(names)
        save(listing)
    }

    private func save(_ listing: ZoneListingState) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(listing).write(to: file, options: .atomic)
        } catch {
            log("listing: couldn't keep it: \(error.localizedDescription)")
        }
    }
}
