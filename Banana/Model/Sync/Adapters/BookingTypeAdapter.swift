import Foundation

/// `plan.bookingType` (docs/design/BOOKING.md §4): one record per booking type, its fields the
/// `BookingType`'s keys, which are the names the service reads (`Service/src/booking/types.js`).
/// Merged field by field; seeded at each type's own `editedAt`. The default type a device shows
/// before it has pulled is never sent as it is, and a change to it waits for the pull
/// (`BookingTypeStore.pullCompleted`). No legacy channel ever carried
/// it (`LegacyInventory.withoutLegacy`): `SpaceSyncLaunch` seeds it when the adapter joins.
enum BookingTypeAdapter {
    static let type = BookingTypeStore.syncType

    @MainActor
    static func adapter(_ source: BookingTypeSyncSource) -> BoundAdapter {
        BoundAdapter("booking types", [binding(source)])
    }

    @MainActor
    static func binding(_ source: BookingTypeSyncSource) -> SyncBinding {
        weak var weakSource = source
        func items(_ entries: [BookingTypeEntry]) -> [String: any Encodable & Sendable] {
            Dictionary(entries.map { entry -> (String, any Encodable & Sendable) in
                let carried = Carried(entry.type)
                return (entry.id, PreparedItem { try SyncShape.fields.encode(carried.value) })
            }, uniquingKeysWith: { first, _ in first })
        }
        var binding = SyncBinding(
            type: type,
            snapshot: { items(Array((weakSource?.syncTypes ?? [:]).values)) },
            items: { ids in items((weakSource?.syncTypes ?? [:]).filter { ids.contains($0.key) }.map(\.value)) },
            apply: { records in
                var results: [String: SyncApplied] = [:]
                for record in records {
                    results[record.id] = .taken
                    // A record that can't be a type (no slug) is left out, as the service leaves it out.
                    guard let incoming = try? SyncShape.fields.decode(BookingType.self, from: record.fields),
                          record.fields["slug"]?.stringValue != nil else { continue }
                    if weakSource?.applySynced(record.id, incoming) == true { results[record.id] = .keptOwn }
                }
                return results
            },
            remove: { ids in weakSource?.removeSynced(ids) })
        binding.seedClock = { id in weakSource?.syncTypes[id]?.editedAt }
        binding.pullCompleted = { weakSource?.pullCompleted() }
        return binding
    }
}
