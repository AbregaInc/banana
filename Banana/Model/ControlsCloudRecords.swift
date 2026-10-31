import CryptoKit
import Foundation

/// The kinds of data that sync as one record each through `CloudControlsSync`: everything you make
/// or change on one device that every other device should have — lists you edit (routines, alarms),
/// your library and what you've listened to, and what the phone works out for each episode (so a
/// new device doesn't redo it).
enum ControlKind: String, CaseIterable, Sendable {
    case routine
    case alarm
    /// One per source slot (sleep, wake, workout).
    case wake
    /// One show's settings, by the podcast's id.
    case podcast
    /// One subscribed show — the library itself.
    case show
    /// A timeline change to one occurrence (skip, move), by its occurrence key.
    case timelineOverride
    /// An extra occurrence of a routine added for one day.
    case timelineExtra
    /// One listening session.
    case listen
    /// The route walked or driven during one listening session.
    case listenRoute
    /// An episode's ad-skip plan, worked out from its transcript or audio.
    case skipPlan
    /// An episode's declared ad slots (from its chapters or show notes).
    case adSlots
    /// A correction to ad skipping ("this wasn't an ad").
    case skipCorrection
    /// The narrator's voice heard in one episode.
    case narratorReading
    /// A narrator's voice, learned across episodes.
    case narratorGender
    /// A narrator's voice as you set it.
    case narratorOverride
    /// A guided workout plan.
    case workoutPlan
    /// A guided workout done.
    case workoutCompletion
    /// A food's macros as you corrected them, by its name.
    case foodCorrection
    /// A meal waiting to be logged: photos and words, and what estimating made of them.
    case mealInbox
    /// A meal photo (a small JPEG), by its id — for the backlog, and kept with the meal logged.
    case mealPhoto
    /// A library photo some device already made into a meal, by its cloud key — so no other
    /// device finds it again, even after the meal was logged or dismissed.
    case mealPhotoFound
    /// A food you scanned (`MyFood`): its label's numbers and the names it stands for.
    case myFood
    // Finished transcripts travel on their own, through iCloud Drive (`TranscriptCloudFiles`).

    /// The zone it syncs through (`ControlChannel`).
    var channel: ControlChannel {
        switch self {
        case .mealInbox, .mealPhoto, .mealPhotoFound: .meals
        default: .controls
        }
    }

    /// Whether an iPad or Mac takes the phone's whole set of this kind the first time it syncs,
    /// dropping what it had of its own. Only for lists every install starts with defaults of (the
    /// default routines would otherwise pile up beside the phone's). Everything else merges: nothing
    /// a device has is dropped for being missing elsewhere.
    var adoptsPhoneSet: Bool {
        switch self {
        case .routine, .alarm, .wake: true
        default: false
        }
    }

    /// The record's name in CloudKit: "routine-<id>". An id that isn't a short plain string — an
    /// episode's id is often a long URL, a narrator's name can be anything — is hashed; the
    /// original travels in the record (`ControlEnvelope.key`).
    func recordName(_ id: String) -> String { "\(rawValue)-\(Self.safeID(id))" }

    static func safeID(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "._:-").union(.alphanumerics)
        let plain = !id.isEmpty && id.count <= 180 && id.unicodeScalars.allSatisfy {
            $0.isASCII && allowed.contains($0)
        }
        guard !plain else { return id }
        return "~" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The kind and (possibly hashed) id a record name stands for, or nil for one this build doesn't
    /// know. The longest matching prefix wins, so no kind can take another's records.
    static func parse(_ recordName: String) -> (kind: ControlKind, id: String)? {
        let match = allCases
            .filter { recordName.hasPrefix($0.rawValue + "-") }
            .max { $0.rawValue.count < $1.rawValue.count }
        guard let kind = match else { return nil }
        return (kind, String(recordName.dropFirst(kind.rawValue.count + 1)))
    }
}

/// What a Controls zone's drain hands the move (`DrainResult`, docs/design/DATA-PLATFORM.md §3
/// seeding rule 1), from the sync's bookkeeping by record name: every record still dirty (edited
/// or deleted here, read-only too, and not confirmed by iCloud) is an edit or, with a tombstone,
/// a delete. A route's tombstone isn't a deleted listen: the route goes with its listen. `keys`:
/// the item id behind a hashed record name.
enum ControlDrain {
    static func result(dirty: Set<String>, tombstones: Set<String>, keys: [String: String]) -> DrainResult {
        var result = DrainResult()
        for name in dirty {
            guard let parsed = ControlKind.parse(name), let type = LegacyInventory.controlKinds[parsed.kind.rawValue] else { continue }
            let id = keys[name] ?? parsed.id
            if tombstones.contains(name) {
                guard parsed.kind != .listenRoute else { continue }
                result.note(\.pendingDeletes, type: type, id: id)
            } else {
                result.note(\.dirty, type: type, id: id)
            }
        }
        return result
    }
}

/// Which zone a kind syncs through. The meal backlog has its own, small and self-contained, so the
/// iPhone can fetch just that when it's woken in the background — to ask about a meal the Mac found
/// — without starting everything else, and a push for it wakes nothing about anything else.
enum ControlChannel: String, CaseIterable, Sendable {
    case controls, meals

    var zoneName: String {
        switch self {
        case .controls: "Controls"
        case .meals: "Meals"
        }
    }

    var kinds: [ControlKind] { ControlKind.allCases.filter { $0.channel == self } }
}

/// What a control record carries: when it was last edited, and the item — or that it was deleted.
/// A deletion is kept as a record (a tombstone) rather than removed from CloudKit, so it has a time
/// to compare: "deleted on the Mac" can beat an older edit made on the phone, and lose to a newer one.
struct ControlEnvelope: Codable, Equatable, Sendable {
    var editedAt: Date
    var deleted: Bool
    var item: Data?
    /// The item's id as the store knows it, for a record whose name had to be hashed.
    var key: String?
    /// `item` is LZFSE-compressed (a transcript, a long route).
    var packed: Bool?

    /// The edit time of an item offered in the phone's first sync: older than any real edit, so
    /// one made on another device before the phone got round to it still wins.
    static let unedited = Date(timeIntervalSince1970: 0)
    /// Items bigger than this are compressed.
    static let packAbove = 16 * 1024
    /// A record bigger than this isn't sent (CloudKit's limit is 1 MB for the whole record).
    static let largestPayload = 900 * 1024

    static func edit(_ item: Data, at: Date, key: String? = nil) -> ControlEnvelope {
        guard item.count > packAbove, let packed = try? (item as NSData).compressed(using: .lzfse) as Data,
              packed.count < item.count else {
            return ControlEnvelope(editedAt: at, deleted: false, item: item, key: key)
        }
        return ControlEnvelope(editedAt: at, deleted: false, item: packed, key: key, packed: true)
    }

    static func tombstone(at: Date, key: String? = nil) -> ControlEnvelope {
        ControlEnvelope(editedAt: at, deleted: true, item: nil, key: key)
    }

    /// The item as the store wrote it.
    var unpackedItem: Data? {
        guard let item else { return nil }
        guard packed == true else { return item }
        return try? (item as NSData).decompressed(using: .lzfse) as Data
    }
}

enum ControlMerge {
    /// Another device's version wins only when it's newer than what this device last had.
    static func remoteWins(remote: Date, local: Date?) -> Bool {
        guard let local else { return true }
        return remote > local
    }

    /// The first time the iPad or Mac hears from the phone, it takes the phone's set for each kind
    /// the phone has published, rather than adding its own older copies (a routine deleted on the
    /// phone mustn't come back from the Mac). Returns the local ids to drop.
    static func localOnly(local: Set<String>, server: Set<String>) -> Set<String> {
        guard !server.isEmpty else { return [] }   // nothing published yet: keep what's here
        return local.subtracting(server)
    }
}

/// A store whose items sync through `CloudControlsSync`: it hands over what it has, by id, and
/// takes another device's newer version of one item.
///
/// A small store implements `cloudItems`; a big one (transcripts, a long history) implements
/// `cloudItemIDs` and `cloudItem`, so one item is encoded at a time as uploads go.
@MainActor
protocol CloudControlSource: AnyObject {
    /// Every item of `kind` on this device now, encoded, by id.
    func cloudItems(_ kind: ControlKind) -> [String: Data]
    /// The ids of every item of `kind` on this device now.
    func cloudItemIDs(_ kind: ControlKind) -> [String]
    /// One item, encoded, or nil if it's gone.
    func cloudItem(_ kind: ControlKind, id: String) -> Data?
    /// Another device's version of one item, or nil when it was deleted there. Only called when
    /// that version is the newer edit. A store may apply it through its ordinary mutators: what
    /// they report back to the sync while this runs is ignored, so nothing echoes.
    ///
    /// Returns false when it can't be applied yet — settings for a show that hasn't arrived here.
    /// It isn't counted as seen then, so reading everything again later (`refetchAll`) applies it.
    @discardableResult
    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool
}

extension CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] { [:] }
    func cloudItemIDs(_ kind: ControlKind) -> [String] { Array(cloudItems(kind).keys) }
    func cloudItem(_ kind: ControlKind, id: String) -> Data? { cloudItems(kind)[id] }
}

/// Where stores report their own edits for syncing. The app connects it to `CloudControlsSync` at
/// launch (`connectToCloud`); anywhere else — the unit tests compile some stores on their own — it
/// goes nowhere.
@MainActor
enum ControlChangeReporter {
    static var changed: (ControlKind, String) -> Void = { _, _ in }
    static var deleted: (ControlKind, String) -> Void = { _, _ in }
    /// Offered rather than edited: something this device found for itself that another device may
    /// have already made — the same library photo, found twice. It goes up as if unedited, so any
    /// real edit made elsewhere (an answer, a dismissal, a meal logged) beats it everywhere.
    static var offered: (ControlKind, String) -> Void = { _, _ in }

    /// While a store takes the data platform's records, or the account-change clear takes items
    /// out (`ControlsAdapter`): what the store reports then is no edit of its own for the Controls
    /// sync, which notes nothing of it (no edit time, no tombstone, nothing to send).
    private(set) static var applyingFromSpace = 0
    static var isApplyingFromSpace: Bool { applyingFromSpace > 0 }

    static func fromSpace<T>(_ body: () throws -> T) rethrows -> T {
        applyingFromSpace += 1
        defer { applyingFromSpace -= 1 }
        return try body()
    }
}

