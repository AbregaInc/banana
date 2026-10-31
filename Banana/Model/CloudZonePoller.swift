import CloudKit
import Foundation
#if os(iOS)
import UIKit
#endif

/// Asks the server what changed in one sync's zone since last time, and hands it to that sync.
///
/// `CKSyncEngine` only fetches a zone it has been told changed — by a push — and these apps get no
/// pushes, so an explicit `fetchChanges` came back at once with "no need to fetch". A device then
/// heard about another's edits only when it read everything from scratch: shows subscribed on the
/// Mac never reached an iPad that was open. This fetches the zone's changes itself, with its own
/// change token, once a minute while the app is open (`CloudSyncPoll`).
///
/// The first poll has no token. A small zone is read whole (every record goes through the sync's
/// normal merge, so what it already has changes nothing). A big one — workouts carry their
/// recordings — is listed without contents first, and only records newer than what the device
/// has (`isStale`) are fetched in full.
@MainActor
final class CloudZonePoller {
    typealias Ingest = (_ records: [CKRecord], _ deletions: [CKRecord.ID]) async -> Void

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let tokenKey: String
    private let ingest: Ingest
    /// For a big zone: whether a listed record is newer than what this device has. Nil reads the
    /// zone whole on the first poll.
    private let isStale: ((CKRecord) -> Bool)?
    /// May poll with the app in the background: a small zone whose changes a push or background
    /// task has woken the app for (the meal backlog). Big zones never do — a first read of one walks
    /// months of history.
    private let backgroundOK: Bool
    private let runs = CoalescingRun()
    /// The zone listed without contents (the first poll's bootstrap, the move's drain), kept page
    /// by page so an interrupted listing picks up where it stopped (`ResumableZoneListing`).
    private let listing: ResumableZoneListing

    init(database: CKDatabase, zoneName: String, tokenKey: String, backgroundOK: Bool = false,
         isStale: ((CKRecord) -> Bool)? = nil, ingest: @escaping Ingest) {
        self.database = database
        self.zoneID = CKRecordZone.ID(zoneName: zoneName)
        self.tokenKey = tokenKey
        self.backgroundOK = backgroundOK
        self.isStale = isStale
        self.ingest = ingest
        let file = AppSupport.directory.appendingPathComponent("ZoneListings", isDirectory: true)
            .appendingPathComponent("\(tokenKey).json")
        listing = ResumableZoneListing(file: file) { line in
            PlaybackDiagnostics.shared.log("☁️ poll \(zoneName)", line)
        }
    }

    private var token: CKServerChangeToken? {
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

    /// Forget where the last poll got to, so the next one reads the whole zone again — for records
    /// that came before this device could use them (progress for a show that hadn't arrived).
    func startOver() {
        token = nil
        caughtUp = false
        listing.discard()
    }

    /// Whether a poll has read to the end of the zone's changes. Until then it has to keep going
    /// whether or not anything new changed — a first read walks the zone's whole history, a batch
    /// at a time (`CloudChangeCheck` only says what changed since the last look).
    private(set) var caughtUp: Bool {
        get { UserDefaults.standard.bool(forKey: tokenKey + ".caughtUp") }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey + ".caughtUp") }
    }

    /// Fetch everything that changed since the last poll. Returns how many records came in.
    @discardableResult
    func poll() async -> Int {
        // Never with the phone in the background (a pause during background playback flushes):
        // a first poll pages through the zone's whole history, and background work is what gets
        // playback killed. Coming forward polls again and picks up where it stopped.
        #if os(iOS)
        guard backgroundOK || UIApplication.shared.applicationState != .background else {
            // Not read, and the check that sent us here has used up the zone's notice: owed.
            caughtUp = CloudPollRules.caughtUp(after: .notRun)
            return 0
        }
        #endif
        return await runs.run { await pollOnce() }
    }

    // MARK: - The move off iCloud

    /// The drain's wish, honoured by whichever pass runs next, and how it went.
    private var drainWanted: Bool?
    /// A drain under way: its pages go at the priority of something the person is waiting for.
    private var draining = false
    private var drained: Result<Set<String>?, Error>?

    enum DrainError: Error {
        /// The app went to the background, or the server stopped moving on.
        case interrupted
        /// The zone isn't there: nothing can be said about what it holds.
        case noZone
    }

    /// Reads to the end, for the move off iCloud (docs/design/DATA-PLATFORM.md §3 seeding rule 1):
    /// every change since the last poll (the whole zone with no token yet), through the sync's
    /// usual ingest. With `listing`, also the name of every record the zone holds now, read without
    /// contents. Throws when it didn't get to the end; a partial listing is never returned.
    func drainToEnd(listing: Bool) async throws -> Set<String>? {
        drainWanted = listing
        _ = await runs.run { await pollOnce() }
        guard let outcome = drained else { throw DrainError.interrupted }
        drained = nil
        return try outcome.get()
    }

    private func drainAll(listing: Bool) async throws -> Set<String>? {
        do {
            if token == nil, isStale != nil {
                _ = try await bootstrapByListing(strict: true)
            } else {
                _ = try await fetchChanges(strict: true)
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil
            caughtUp = CloudPollRules.caughtUp(after: .failed)
            throw error
        }
        guard listing else { return nil }
        return try await listNames()
    }

    /// The names of every record in the zone now, without their contents. Resumes a listing an
    /// earlier drain began (or catches up a finished one); returns only once it reached the end.
    private func listNames() async throws -> Set<String> {
        let listed: ZoneListingState
        do {
            // In the background is fine for the move's drain (it holds background time); only that
            // time running out stops it.
            listed = try await listing.run(fetch: listingPage, stop: { LegacyCloud.drainExpired })
        } catch ZoneListingError.noZone {
            throw DrainError.noZone
        } catch ZoneListingError.interrupted, ZoneListingError.stalled {
            throw DrainError.interrupted
        }
        PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "drain: the zone holds \(listed.names.count) record(s)")
        return listed.names
    }

    /// One page of the zone without contents, for `listing`. A token the server no longer takes,
    /// or a zone gone, ends the kept listing: the next one starts from nothing.
    private func listingPage(_ from: Data?) async throws -> ZoneListingPage {
        let since = from.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        let page: Page
        do {
            page = try await fetchPage(since: since, desiredKeys: [])
        } catch let error as CKError where [.changeTokenExpired, .zoneNotFound, .userDeletedZone].contains(error.code) {
            listing.discard()
            throw error
        }
        return ZoneListingPage(
            listed: page.records.map(\.recordID.recordName),
            stale: page.records.filter { isStale?($0) ?? false }.map(\.recordID.recordName),
            deleted: page.deletions.map(\.recordName),
            token: page.token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) },
            moreComing: page.moreComing)
    }

    private func pollOnce() async -> Int {
        if let listing = drainWanted {
            drainWanted = nil
            draining = true
            defer { draining = false }
            do { drained = .success(try await drainAll(listing: listing)) } catch { drained = .failure(error) }
            return 0
        }
        do {
            if token == nil, isStale != nil {
                return try await bootstrapByListing()
            }
            return try await fetchChanges()
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil
            caughtUp = CloudPollRules.caughtUp(after: .failed)
            PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "change token expired; reading the zone again")
            return 0
        } catch {
            // Owed: the next check fetches again, though the zone won't be named again
            // (`CloudPollRules`). It used to wait for the zone's next change.
            caughtUp = CloudPollRules.caughtUp(after: .failed)
            PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "deferred: \(error.localizedDescription)")
            return 0
        }
    }

    /// Changes since the stored token, page by page, each page handed over as it arrives.
    private func fetchChanges(strict: Bool = false) async throws -> Int {
        var total = 0
        var pages = 0
        var deleted = 0
        var failed = 0
        var current = token
        var more = true
        while more {
            #if os(iOS)
            if strict {
                // The move's drain holds background time: only its end stops it.
                if LegacyCloud.drainExpired { throw DrainError.interrupted }
            } else if !backgroundOK && UIApplication.shared.applicationState == .background {
                break   // resumes from `token`
            }
            #endif
            let page = try await fetchPage(since: current, desiredKeys: nil)
            pages += 1
            if !page.records.isEmpty || !page.deletions.isEmpty {
                await ingest(page.records, page.deletions)
            }
            total += page.records.count
            deleted += page.deletions.count
            failed += page.failures
            if let why = page.firstFailure, failed == page.failures {
                PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "a record couldn't be fetched — \(why)")
            }
            if pages % 20 == 0 {
                PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "page \(pages): \(total) changed, \(deleted) deleted, \(failed) failed so far")
            }
            // No token: the zone isn't there yet (a first launch, before this device or another
            // made it). Nothing to read; its creation is a change the next check will report.
            guard let next = page.token else {
                more = false
                break
            }
            // A page that doesn't move the token on while saying there's more would be fetched
            // again forever. (With nothing new, the server hands back the same token — normal.)
            guard next != current || !page.moreComing else {
                PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "stopped: page \(pages) didn't advance")
                if strict { throw DrainError.interrupted }
                break
            }
            current = next
            token = next
            more = page.moreComing
        }
        caughtUp = CloudPollRules.caughtUp(after: more ? .moreToCome : .readToTheEnd)
        if total > 0 { PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "\(total) changed record(s) in \(pages) page(s)") }
        return total
    }

    /// A big zone's first poll: list it without contents to get a token, then fetch in full only
    /// what this device doesn't have yet. Stopped part-way, it picks up where it stopped next time
    /// (`listing`): its token is taken only once the listing reached the end and every record
    /// newer than here came in, as a partial listing's token would make the next poll fetch the
    /// rest of the history in full, recordings and all.
    private func bootstrapByListing(strict: Bool = false) async throws -> Int {
        #if os(iOS)
        let backgroundOK = backgroundOK
        let stop: () -> Bool = {
            strict ? LegacyCloud.drainExpired : !backgroundOK && UIApplication.shared.applicationState == .background
        }
        #else
        let stop: () -> Bool = { strict && LegacyCloud.drainExpired }
        #endif
        let listed: ZoneListingState
        do {
            listed = try await listing.run(fetch: listingPage, stop: stop)
        } catch ZoneListingError.noZone {
            // Nothing to read; its creation is a change the next check will report.
            token = nil
            caughtUp = true
            return 0
        } catch ZoneListingError.interrupted {
            if strict { throw DrainError.interrupted }
            return 0
        } catch ZoneListingError.stalled {
            PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "listing stopped: a page didn't advance")
            if strict { throw DrainError.interrupted }
            caughtUp = CloudPollRules.caughtUp(after: .failed)
            return 0
        }
        var total = 0
        let stale = listed.stale.sorted()
        for chunk in stride(from: 0, to: stale.count, by: 50).map({ Array(stale[$0..<min($0 + 50, stale.count)]) }) {
            if stop() {
                if strict { throw DrainError.interrupted }
                return total
            }
            let records = try await fetchRecords(chunk.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
            if !records.isEmpty { await ingest(records, []) }
            listing.fetched(chunk)
            total += records.count
        }
        token = listed.token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        caughtUp = true
        PlaybackDiagnostics.shared.log("☁️ poll \(zoneID.zoneName)", "first read: \(total) record(s) newer than here")
        return total
    }

    private struct Page {
        var records: [CKRecord] = []
        var deletions: [CKRecord.ID] = []
        var token: CKServerChangeToken?
        var moreComing = false
        /// Records the server listed but couldn't hand over, with the first reason.
        var failures = 0
        var firstFailure: String?
    }

    /// CloudKit calls an operation's blocks on its own queue; the page is filled under a lock.
    private final class PageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var page = Page()
        func update(_ change: (inout Page) -> Void) { lock.lock(); change(&page); lock.unlock() }
        var value: Page { lock.lock(); defer { lock.unlock() }; return page }
    }

    private func fetchPage(since token: CKServerChangeToken?, desiredKeys: [CKRecord.FieldKey]?) async throws -> Page {
        let zoneID = zoneID
        let priority: QualityOfService = draining ? .userInitiated : .utility
        let page = PageBox()
        return try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: token, resultsLimit: nil, desiredKeys: desiredKeys)
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
            operation.fetchAllChanges = false   // one page per call; the caller loops
            operation.recordWasChangedBlock = { id, result in
                switch result {
                case .success(let record): page.update { $0.records.append(record) }
                case .failure(let error):
                    page.update {
                        $0.failures += 1
                        if $0.firstFailure == nil { $0.firstFailure = "\(id.recordName): \(error.localizedDescription)" }
                    }
                }
            }
            operation.recordWithIDWasDeletedBlock = { id, _ in page.update { $0.deletions.append(id) } }
            operation.recordZoneFetchResultBlock = { _, result in
                if case .success(let done) = result {
                    page.update {
                        $0.token = done.serverChangeToken
                        $0.moreComing = done.moreComing
                    }
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: continuation.resume(returning: page.value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            operation.qualityOfService = priority
            database.add(operation)
        }
    }

    private func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        let results = try await database.records(for: ids)
        return results.values.compactMap { try? $0.get() }
    }
}
