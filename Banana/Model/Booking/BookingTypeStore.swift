import Combine
import Foundation

/// One booking type as this device keeps it: the record's id, its fields, and when it was last
/// changed here (its seed clock).
struct BookingTypeEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var type: BookingType
    var editedAt: Date
    /// The default type made when Booking was first opened here, not yet changed: shown, and
    /// never sent. The service offers the same type by itself to an account with none, so a
    /// device that opens Booking before the account's types have arrived can't overwrite them.
    /// Changed, it becomes a record: at once when this device has pulled what the space holds of
    /// the type, else once it has (`held` meanwhile), laid over the account's own default if that
    /// arrives first.
    var unsent: Bool = false
    /// The unsent default was changed here before the space's types were pulled: it goes up then.
    var held: Bool = false
    /// The zone the shown default was made in: what a change to it is measured from, so a zone
    /// changed here counts as changed.
    var madeInZone: String?

    init(id: String, type: BookingType, editedAt: Date, unsent: Bool = false, held: Bool = false, madeInZone: String? = nil) {
        self.id = id
        self.type = type
        self.editedAt = editedAt
        self.unsent = unsent
        self.held = held
        self.madeInZone = madeInZone
    }

    private enum CodingKeys: String, CodingKey { case id, type, editedAt, unsent, held, madeInZone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(BookingType.self, forKey: .type)
        editedAt = try c.decode(Date.self, forKey: .editedAt)
        unsent = try c.decodeIfPresent(Bool.self, forKey: .unsent) ?? false
        held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
        madeInZone = try c.decodeIfPresent(String.self, forKey: .madeInZone)
    }
}

/// What the sync adapter needs of the store (`BookingTypeAdapter`).
@MainActor
protocol BookingTypeSyncSource: AnyObject {
    /// Every type that is a record (not the unsent default), by id.
    var syncTypes: [String: BookingTypeEntry] { get }
    /// Another device's version of a type: it replaces this one's. True when the store kept its
    /// own copy instead (the held default, laid over it): that copy goes up as this device's edit.
    func applySynced(_ id: String, _ type: BookingType) -> Bool
    func removeSynced(_ ids: [String])
    /// What the space holds of the type has been pulled.
    func pullCompleted()
}

/// The booking types (`plan.bookingType`): a small JSON file in Application Support, edited in
/// Settings › Booking on any device and synced through the data platform, which the service reads
/// them from. Every change shows at once and goes up on the engine's next pass.
@MainActor
final class BookingTypeStore: ObservableObject, BookingTypeSyncSource {
    static let shared: BookingTypeStore = {
        let store = BookingTypeStore(directory: AppSupport.directory)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--booking-preview") { store.injectPreview() }
        #endif
        return store
    }()
    static let syncType = "plan.bookingType"
    /// The default type's record id, the same on every device: two devices that make it at once
    /// make one record, not two types with the same link.
    static let defaultID = "default"

    @Published private(set) var entries: [BookingTypeEntry] = []
    /// This launch has pulled what the space holds of the type (`pullCompleted`).
    private(set) var pulled = false

    private let file: URL
    /// Where changes are reported (the engine, through `SyncReport`); tests listen here.
    var report: (_ changed: [String], _ deleted: [String]) -> Void = { changed, deleted in
        SyncReport.changed(BookingTypeStore.syncType, changed)
        SyncReport.deleted(BookingTypeStore.syncType, deleted)
    }
    var now: () -> Date = Date.init

    init(directory: URL) {
        file = directory.appendingPathComponent("booking-types.json")
        load()
    }

    /// In profile order: `order`, then title.
    var types: [BookingTypeEntry] {
        entries.sorted { ($0.type.order, $0.type.title, $0.id) < ($1.type.order, $1.type.title, $1.id) }
    }

    func entry(_ id: String) -> BookingTypeEntry? { entries.first { $0.id == id } }

    // MARK: - The default type

    /// Booking was opened: with no type at all, the service's default is shown, in this device's
    /// zone. Made here only, never at launch, and not sent until it's changed (`unsent`).
    func openedBooking(zone: String = BookingType.deviceZone()) {
        guard entries.isEmpty else { return }
        entries = [BookingTypeEntry(id: Self.defaultID, type: .standard(zone: zone), editedAt: now(), unsent: true,
                                    madeInZone: zone)]
        save()
    }

    // MARK: - Changes

    /// A new type: its slug from its title, unique among the others, and it sits last.
    @discardableResult
    func add(_ type: BookingType) -> String {
        var type = type
        type.slug = BookingSlug.make(from: type.title, taken: Set(entries.map(\.type.slug)))
        type.order = (entries.map(\.type.order).max() ?? -1) + 1
        let id = UUID().uuidString.lowercased()
        entries.append(BookingTypeEntry(id: id, type: type, editedAt: now()))
        sendDefaultIfUnsent()
        save()
        report([id], [])
        return id
    }

    /// Changes a type. Its slug stays what it was made with: a guest's link to it keeps working.
    func update(_ id: String, _ change: (inout BookingType) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var type = entries[index].type
        let slug = type.slug
        change(&type)
        type.slug = slug
        guard type != entries[index].type else { return }
        entries[index].type = type
        entries[index].editedAt = now()
        if entries[index].unsent && !pulled {
            entries[index].held = true   // goes up once the space's types are here
            save()
            return
        }
        entries[index].unsent = false
        entries[index].held = false
        save()
        report([id], [])
    }

    func remove(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let gone = entries.remove(at: index)
        save()
        if !gone.unsent { report([], [id]) }
    }

    /// Puts back a type removed a moment ago (Undo).
    func restore(_ entry: BookingTypeEntry) {
        guard self.entry(entry.id) == nil else { return }
        var entry = entry
        entry.editedAt = now()
        entries.append(entry)
        save()
        if !entry.unsent { report([entry.id], []) }
    }

    /// Adding a second type makes the shown default a real record: from then on the service
    /// lists what is here, and the default must be among it.
    private func sendDefaultIfUnsent() {
        guard let index = entries.firstIndex(where: \.unsent) else { return }
        entries[index].editedAt = now()
        guard pulled else { entries[index].held = true; return }
        entries[index].unsent = false
        entries[index].held = false
        report([entries[index].id], [])
    }

    // MARK: - Sync (`BookingTypeSyncSource`)

    var syncTypes: [String: BookingTypeEntry] {
        Dictionary(entries.filter { !$0.unsent }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func applySynced(_ id: String, _ type: BookingType) -> Bool {
        // The account has types: the shown default gives way to them, unless it's the one arriving
        // or it was changed here (it goes up once the pull is whole).
        entries.removeAll { $0.unsent && !$0.held && $0.id != id }
        var keptOwn = false
        if let index = entries.firstIndex(where: { $0.id == id }) {
            if entries[index].held {
                // Changed here before the account's own arrived: what was changed here, over theirs.
                let base = BookingType.standard(zone: entries[index].madeInZone ?? entries[index].type.timeZone)
                entries[index].type = Self.overlay(entries[index].type, changedFrom: base, onto: type)
                keptOwn = entries[index].type != type
            } else {
                entries[index].type = type
            }
            entries[index].unsent = false
            entries[index].held = false
        } else {
            entries.append(BookingTypeEntry(id: id, type: type, editedAt: now()))
        }
        save()
        return keptOwn
    }

    func pullCompleted() {
        pulled = true
        let held = entries.indices.filter { entries[$0].held }
        guard !held.isEmpty else { return }
        for index in held {
            entries[index].unsent = false
            entries[index].held = false
        }
        save()
        report(held.map { entries[$0].id }, [])
    }

    /// The fields of `local` that differ from `base`, laid over `incoming`, field by field as the
    /// space merges them.
    static func overlay(_ local: BookingType, changedFrom base: BookingType, onto incoming: BookingType) -> BookingType {
        guard let mine = try? CanonicalJSON.fields(of: local), let theirs = try? CanonicalJSON.fields(of: base),
              var merged = try? CanonicalJSON.fields(of: incoming) else { return local }
        for key in Set(mine.keys).union(theirs.keys) where mine[key] != theirs[key] {
            merged[key] = mine[key] ?? .null
        }
        return (try? SyncShape.fields.decode(BookingType.self, from: merged)) ?? local
    }

    func removeSynced(_ ids: [String]) {
        let gone = Set(ids)
        guard entries.contains(where: { gone.contains($0.id) }) else { return }
        entries.removeAll { gone.contains($0.id) }
        save()
    }

    // MARK: - The file

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([BookingTypeEntry].self, from: data) else { return }
        entries = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    #if DEBUG
    /// Sample types for the screenshot routes (`--booking-preview`), in memory only.
    func injectPreview(zone: String = BookingType.deviceZone()) {
        var intro = BookingType.standard(zone: zone)
        intro.title = "Intro call"
        intro.slug = "intro-call"
        intro.minutes = 15
        intro.order = 1
        intro.locations = [BookingPlace(kind: .zoom, url: "https://us02web.zoom.us/j/1234567890"), BookingPlace(kind: .phoneHostCalls)]
        var coffee = BookingType.standard(zone: zone)
        coffee.title = "Coffee"
        coffee.slug = "coffee"
        coffee.minutes = 45
        coffee.order = 2
        coffee.active = false
        coffee.locations = [BookingPlace(kind: .inPerson, address: "Blue Bottle, 160 Berry St, Brooklyn")]
        entries = [BookingTypeEntry(id: Self.defaultID, type: .standard(zone: zone), editedAt: now()),
                   BookingTypeEntry(id: "intro", type: intro, editedAt: now()),
                   BookingTypeEntry(id: "coffee", type: coffee, editedAt: now())]
        report = { _, _ in }
    }
    #endif
}
