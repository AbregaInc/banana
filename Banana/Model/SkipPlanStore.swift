import Foundation
import os

/// A plan plus the inputs it was built from.
///
/// The inputs matter because a plan is only as good as what Banana knew at the time. A first
/// streamed listen can produce a perfectly valid plan from ad-server headers alone; once that
/// episode has been transcribed overnight, the boilerplate and sponsor-read stages can say more.
/// Recording what went in is what lets the store tell "already answered" from "answered with
/// less", instead of trusting the first answer forever.
struct StoredSkipPlan: Codable, Sendable {
    var plan: EpisodeSkipPlan
    /// Whether a transcript of this episode was available to the builder.
    var usedTranscript: Bool = false
    /// Whether the host's own declared ad slots were available to the builder.
    var usedDeclaredSlots: Bool = false
    /// Whether the whole downloaded file was available, as opposed to headers alone.
    var usedLocalAudio: Bool = false

    /// Whether a rebuild with these inputs would be able to say more than this plan does.
    func improvedBy(transcript: Bool, declaredSlots: Bool, localAudio: Bool) -> Bool {
        (transcript && !usedTranscript)
            || (declaredSlots && !usedDeclaredSlots)
            || (localAudio && !usedLocalAudio)
    }
}

extension StoredSkipPlan {
    /// Tolerant decoder, in an extension so the memberwise init survives.
    ///
    /// Synthesized `Decodable` throws `keyNotFound` for an absent key even when the property
    /// declares a default (see `Shared/SnapshotPersistence.swift`), so adding a field here later
    /// would otherwise invalidate every plan on disk at once — a self-inflicted cache wipe.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(EpisodeSkipPlan.self, forKey: .plan)
        usedTranscript = try c.decodeIfPresent(Bool.self, forKey: .usedTranscript) ?? false
        usedDeclaredSlots = try c.decodeIfPresent(Bool.self, forKey: .usedDeclaredSlots) ?? false
        usedLocalAudio = try c.decodeIfPresent(Bool.self, forKey: .usedLocalAudio) ?? false
    }
}

/// The ad-slot facts a host declared about one copy of an episode's audio.
///
/// Captured rather than derived: these headers ride along on every download already, and a
/// declared byte range is correct by construction in a way no heuristic can be. Kept small and
/// filtered — this is a cache of a handful of header values, not an HTTP transcript.
struct DeclaredAdSlots: Codable, Sendable {
    var episodeID: String
    /// Header name → value, lowercased names, only the ones a detector could act on.
    var headers: [String: String] = [:]
    /// `Content-Length` of the audio these headers described, which is also what makes a plan
    /// built from them checkable against the bytes actually in hand.
    var byteCount: Int64?
    var capturedAt: Date = Date()

    var isEmpty: Bool { headers.isEmpty }

    /// How long a capture stays usable for a STREAM.
    ///
    /// The pods are stitched per request, so headers fetched when a show was opened can describe a
    /// different assembly of ads than the one that streams when play is pressed minutes later. A
    /// download is exempt — the bytes captured and the bytes played are the same fetch — but a
    /// stale prefetch applied to a fresh stream would skip the wrong seconds, which is the one
    /// failure this whole design refuses to risk.
    static let freshness: TimeInterval = 5 * 60

    /// Whether this capture can still be trusted to describe the stream about to play.
    func isFresh(at moment: Date) -> Bool {
        moment.timeIntervalSince(capturedAt) <= Self.freshness
    }

    /// Response headers worth keeping. Everything else on an audio response is transport noise,
    /// and storing it would turn a small cache into a log of where the owner listens.
    static let interestingHeaderPrefixes = [
        "x-megaphone-", "x-adserver-", "x-ad-", "x-cdn-ad", "x-podtrac-", "x-omny-",
    ]

    static func capture(episodeID: String, headers rawHeaders: [AnyHashable: Any],
                        byteCount: Int64?, now: Date = Date()) -> DeclaredAdSlots {
        var kept: [String: String] = [:]
        for (key, value) in rawHeaders {
            guard let name = (key as? String)?.lowercased(), let text = value as? String else { continue }
            guard interestingHeaderPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            kept[name] = text
        }
        return DeclaredAdSlots(episodeID: episodeID, headers: kept, byteCount: byteCount, capturedAt: now)
    }
}

extension DeclaredAdSlots {
    /// Same reasoning as `StoredSkipPlan`'s: tolerant, and in an extension so the memberwise
    /// init stays.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeID = try c.decode(String.self, forKey: .episodeID)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        byteCount = try c.decodeIfPresent(Int64.self, forKey: .byteCount)
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
    }
}

/// On-disk home for skip plans, declared ad slots, and the correction book.
///
/// Two very different kinds of data live here and they are deliberately kept in separate files
/// with separate rules:
///
/// - **Plans and declared slots are a cache.** Losing them costs a rebuild. They are keyed to a
///   particular copy of an episode's audio and are thrown away the moment that stops matching.
/// - **The correction book is learned user data.** It is the only record of every time Banana got
///   a skip wrong, it can never be recomputed from anything, and the events that produced it are
///   not repeatable — nobody is going to sit through the same wrong skip again to teach it twice.
///   So it gets the full decode-and-quarantine discipline (see `Shared/SnapshotPersistence.swift`
///   and the sweep it came from): a file that fails to parse is copied aside before anything can
///   overwrite it, and if it could not even be copied, saving is refused outright rather than
///   risking being the data-loss event itself.
@MainActor
final class SkipPlanStore {
    private static let log = Logger(subsystem: "com.boris.banana", category: "adskip")

    private let directory: URL

    private var plans: [String: StoredSkipPlan] = [:]
    private var declared: [String: DeclaredAdSlots] = [:]
    private(set) var corrections = SkipCorrectionBook()

    /// Set when `skip-corrections.json` failed to decode AND could not be quarantined — no backup
    /// of the original exists anywhere, so writing would risk destroying the only copy of what
    /// the feature has learned. Cleared only by resolving the file by hand and relaunching.
    private var correctionsSaveIsUnsafe = false

    private var plansDirty = false
    private var declaredDirty = false

    /// The default lives under `AppSupport.directory` like every other store; tests pass a
    /// throwaway temp directory so none of this ever touches real data.
    init(directory: URL? = nil) {
        let dir = directory ?? AppSupport.directory.appendingPathComponent("AdSkip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        loadCorrections()
        loadPlans()
        loadDeclared()
    }

    private var plansURL: URL { directory.appendingPathComponent("skip-plans.json") }
    private var declaredURL: URL { directory.appendingPathComponent("declared-ad-slots.json") }
    private var correctionsURL: URL { directory.appendingPathComponent("skip-corrections.json") }

    // MARK: - Plans

    /// The stored plan for an episode, or nil when there is none or the one on disk was built
    /// against a different copy of the audio.
    ///
    /// The byte check is not a staleness heuristic. Dynamically inserted ads are stitched per
    /// download, so a plan from another copy is a precise description of somebody else's file,
    /// and acting on it cuts content at the offsets where that copy's ads happened to be. A
    /// rejected plan is dropped here and now, so nothing downstream can find it again later.
    func plan(for episodeID: String, audioByteCount: Int64?) -> EpisodeSkipPlan? {
        guard let stored = plans[episodeID] else { return nil }
        guard stored.plan.isValid(forByteCount: audioByteCount) else {
            Self.log.notice("dropping skip plan for \(episodeID, privacy: .public): built against different audio")
            plans[episodeID] = nil
            plansDirty = true
            savePlansSoon()
            return nil
        }
        return stored.plan
    }

    /// The stored record without the validity check, for deciding whether to rebuild.
    func record(for episodeID: String) -> StoredSkipPlan? { plans[episodeID] }

    func store(_ stored: StoredSkipPlan) {
        plans[stored.plan.episodeID] = stored
        plansDirty = true
        savePlansSoon()
        // Every device gets it; one whose copy of the audio differs drops it on first use.
        ControlChangeReporter.changed(.skipPlan, stored.plan.episodeID)
    }

    func forgetPlan(for episodeID: String) {
        guard plans.removeValue(forKey: episodeID) != nil else { return }
        plansDirty = true
        savePlansSoon()
    }

    /// Drop everything for episodes the app no longer has. Plans are keyed to a copy of the
    /// audio, so keeping one for an episode that is gone is keeping a description of nothing.
    func prune(keeping episodeIDs: Set<String>) {
        let goneFromPlans = plans.keys.filter { !episodeIDs.contains($0) }
        let goneFromDeclared = declared.keys.filter { !episodeIDs.contains($0) }
        guard !goneFromPlans.isEmpty || !goneFromDeclared.isEmpty else { return }
        for id in goneFromPlans { plans[id] = nil }
        for id in goneFromDeclared { declared[id] = nil }
        // OR, not assign: a prune that only touched one of the two files must not clear a pending
        // write to the other.
        plansDirty = plansDirty || !goneFromPlans.isEmpty
        declaredDirty = declaredDirty || !goneFromDeclared.isEmpty
        savePlansSoon()
    }

    // MARK: - Declared ad slots

    func declaredSlots(for episodeID: String) -> DeclaredAdSlots? { declared[episodeID] }

    /// Drop a capture that has gone stale, so the next probe fetches the stitch actually about to
    /// be played. Also drops the plan built from it — it describes a copy nobody will hear.
    func forgetDeclaredSlots(for episodeID: String) {
        guard declared.removeValue(forKey: episodeID) != nil else { return }
        forgetPlan(for: episodeID)
        declaredDirty = true
        savePlansSoon()
    }

    func store(_ slots: DeclaredAdSlots) {
        guard !slots.isEmpty else { return }
        // A second capture for the same episode means new bytes (a re-download, or a stream that
        // the ad server stitched fresh), and the old plan describes the old copy.
        if let existing = declared[slots.episodeID], existing.byteCount != slots.byteCount {
            forgetPlan(for: slots.episodeID)
        }
        declared[slots.episodeID] = slots
        declaredDirty = true
        savePlansSoon()
        ControlChangeReporter.changed(.adSlots, slots.episodeID)
    }

    // MARK: - Corrections

    /// Record that the listener rewound into a span, and persist it immediately.
    ///
    /// Immediately, not on a timer: this is the only evidence that a skip was wrong, and the
    /// moment it is generated is exactly the moment someone is annoyed enough to be reaching for
    /// the app — which is also a good moment to be killed.
    func recordCorrection(for span: SkipSpan, podcastID: UUID) {
        corrections.recordCorrection(for: span, podcastID: podcastID)
        saveCorrections()
        ControlChangeReporter.changed(.skipCorrection, SkipCorrectionBook.key(podcastID: podcastID, source: span.source, sponsor: span.sponsor))
        let total = corrections.corrections(for: span, podcastID: podcastID)
        Self.log.notice("correction recorded: \(span.source.rawValue, privacy: .public) on show \(podcastID.uuidString, privacy: .public), now at \(total, privacy: .public)")
    }

    /// What has been retired on one show, for the per-show UI. Empty when nothing has been
    /// learned, so the screen can stay quiet rather than showing an empty section.
    func retiredDetectors(forShow podcastID: UUID) -> [SkipSource] {
        corrections.retiredDetectors(forShow: podcastID)
    }

    // MARK: - Loading

    private func loadCorrections() {
        switch SnapshotLoader.load(from: correctionsURL, as: SkipCorrectionBook.self) {
        case .empty:
            corrections = SkipCorrectionBook()
        case let .loaded(book):
            corrections = book
        case let .corrupt(error, quarantinedTo):
            corrections = SkipCorrectionBook()
            if let quarantinedTo {
                // Starting from no corrections means every detector is automatic again until it
                // misfires afresh. That is only an acceptable direction to fail because a wrong
                // skip stays correctable by hand — one rewind puts it back.
                Self.log.error("skip-corrections.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public). Starting from no corrections.")
            } else {
                correctionsSaveIsUnsafe = true
                Self.log.fault("skip-corrections.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save corrections until this is resolved by hand; the original is untouched at its original path.")
            }
        }
    }

    private func loadPlans() {
        switch SnapshotLoader.load(from: plansURL, as: LossyDictionary<StoredSkipPlan>.self) {
        case .empty:
            plans = [:]
        case let .loaded(lossy):
            if lossy.droppedCount > 0 {
                Self.log.notice("skip-plans.json: dropped \(lossy.droppedCount, privacy: .public) unreadable plan(s); they rebuild on next play")
            }
            plans = lossy.elements
        case let .corrupt(error, quarantinedTo):
            // A plan is a cache. Starting empty costs a rebuild and nothing else, so unlike the
            // correction book there is no reason to refuse to save afterwards — but the original
            // still gets copied aside, because a file that failed to parse is a bug report.
            plans = [:]
            Self.log.notice("skip-plans.json failed to decode (\(String(describing: error), privacy: .public)); \(quarantinedTo?.lastPathComponent ?? "not quarantined", privacy: .public). Plans rebuild on next play.")
        }
    }

    private func loadDeclared() {
        switch SnapshotLoader.load(from: declaredURL, as: LossyDictionary<DeclaredAdSlots>.self) {
        case .empty:
            declared = [:]
        case let .loaded(lossy):
            declared = lossy.elements
        case let .corrupt(error, quarantinedTo):
            declared = [:]
            Self.log.notice("declared-ad-slots.json failed to decode (\(String(describing: error), privacy: .public)); \(quarantinedTo?.lastPathComponent ?? "not quarantined", privacy: .public). Headers are re-read on next download or stream.")
        }
    }

    // MARK: - Saving

    private var saveTask: Task<Void, Never>?

    /// Coalesce cache writes. Plans change on every play and every finished download; the book
    /// does not use this path at all.
    private func savePlansSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.saveTask = nil
            self.savePlansNow()
        }
    }

    func savePlansNow() {
        if plansDirty, let data = try? JSONEncoder().encode(plans) {
            try? data.write(to: plansURL, options: .atomic)
            plansDirty = false
        }
        if declaredDirty, let data = try? JSONEncoder().encode(declared) {
            try? data.write(to: declaredURL, options: .atomic)
            declaredDirty = false
        }
    }

    private func saveCorrections() {
        guard !correctionsSaveIsUnsafe else {
            Self.log.fault("refusing to save skip corrections: no backup of the previously-corrupt file exists, so writing now would risk destroying the only copy. Resolve by hand and relaunch.")
            return
        }
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        try? data.write(to: correctionsURL, options: .atomic)
    }
}

// What ad skipping has worked out, and every correction you've made to it, on every device
// (CloudControlsSync). A plan or ad-slot capture describes one copy of an episode's audio; a
// device whose copy differs drops it the first time it looks (`plan(for:audioByteCount:)`).
extension SkipPlanStore: CloudControlSource {
    func cloudItemIDs(_ kind: ControlKind) -> [String] {
        switch kind {
        case .skipPlan: Array(plans.keys)
        case .adSlots: Array(declared.keys)
        case .skipCorrection: Array(corrections.allCounts.keys)
        default: []
        }
    }

    func cloudItem(_ kind: ControlKind, id: String) -> Data? {
        let encoder = JSONEncoder()
        switch kind {
        case .skipPlan: return plans[id].flatMap { try? encoder.encode($0) }
        case .adSlots: return declared[id].flatMap { try? encoder.encode($0) }
        case .skipCorrection: return corrections.allCounts[id].flatMap { try? encoder.encode($0) }
        default: return nil
        }
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        let decoder = JSONDecoder()
        switch kind {
        case .skipPlan:
            if let item {
                guard let stored = try? decoder.decode(StoredSkipPlan.self, from: item) else { return true }
                plans[id] = stored
            } else {
                plans[id] = nil
            }
            plansDirty = true
            savePlansSoon()
        case .adSlots:
            if let item {
                guard let slots = try? decoder.decode(DeclaredAdSlots.self, from: item) else { return true }
                declared[id] = slots
            } else {
                declared[id] = nil
            }
            declaredDirty = true
            savePlansSoon()
        case .skipCorrection:
            let count = item.flatMap { try? decoder.decode(Int.self, from: $0) }
            if item != nil, count == nil { return true }
            corrections.setCount(count, forKey: id)
            saveCorrections()
        default:
            break
        }
        return true
    }
}

