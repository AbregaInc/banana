import Foundation

/// What the listen adapter needs of the listening history (`ListenHistoryStore`).
@MainActor
protocol ListenSyncSource: AnyObject {
    /// Every listen, without route points (those live in their own files).
    var syncListens: [ListenEvent] { get }
    /// The listen's route file, once the listen has ended and has points; nil before.
    func syncRouteFile(_ event: ListenEvent) -> URL?
    /// Another device's version of a listen, through the store's usual path.
    func applySyncedListen(_ event: ListenEvent)
    /// Another device's route for a listen: the file's bytes.
    func storeSyncedRoute(_ id: UUID, data: Data)
    /// Deleted elsewhere: the listen and its route leave this device.
    func removeSyncedListens(_ ids: [UUID])
    /// The listen's last edit as the Controls sync knows it, for its seed clock.
    func syncEditedAt(_ id: UUID) -> Date?
}

/// `podcast.listen`: one record per listening session, the store's `ListenEvent` without its
/// points, plus the route as the blob field `route` (§3 "Blobs"). The route is handed over only
/// once the listen has ended, so a route that grows leaves no blob per update: until then the
/// field isn't there and the record's other fields go up meanwhile.
enum ListenAdapter {
    static let type = "podcast.listen"
    static let routeField = "route"

    @MainActor
    static func adapter(_ source: ListenSyncSource) -> BoundAdapter {
        BoundAdapter("listens", [binding(source)])
    }

    @MainActor
    static func binding(_ source: ListenSyncSource) -> SyncBinding {
        weak var weakSource = source
        // Each listen's own time, from the last list handed over: a seed asks for every one.
        var times: [String: Date] = [:]
        func items(_ events: [ListenEvent]) -> [String: any Encodable & Sendable] {
            guard let source = weakSource else { return [:] }
            var found: [String: any Encodable & Sendable] = [:]
            for event in events {
                let id = event.id.uuidString
                found[id] = item(event, route: source.syncRouteFile(event))
                times[id] = event.endedAt ?? event.date
            }
            return found
        }
        var binding = SyncBinding(
            type: type,
            snapshot: { items(weakSource?.syncListens ?? []) },
            items: { ids in items((weakSource?.syncListens ?? []).filter { ids.contains($0.id.uuidString) }) },
            apply: { records in
                var results: [String: SyncApplied] = [:]
                for record in records {
                    results[record.id] = .taken
                    guard let source = weakSource, let event = try? decode(record.fields),
                          event.id.uuidString == record.id else { continue }
                    source.applySyncedListen(event)
                }
                return results
            },
            remove: { ids in weakSource?.removeSyncedListens(ids.compactMap(UUID.init(uuidString:))) })
        binding.seedClock = { id in
            guard let uuid = UUID(uuidString: id), let source = weakSource else { return nil }
            if let edited = source.syncEditedAt(uuid) { return edited }
            if let time = times[id] { return time }
            return source.syncListens.first { $0.id == uuid }.map { $0.endedAt ?? $0.date }
        }
        binding.blobFile = { id, field in
            guard field == routeField, let source = weakSource,
                  let event = source.syncListens.first(where: { $0.id.uuidString == id }) else { return nil }
            return source.syncRouteFile(event)
        }
        binding.storeBlob = { id, field, file in
            guard field == routeField, let uuid = UUID(uuidString: id),
                  let data = try? Data(contentsOf: file) else { return }
            weakSource?.storeSyncedRoute(uuid, data: data)
        }
        return binding
    }

    /// A listen's record: its fields without points, and its route once ended.
    static func item(_ event: ListenEvent, route: URL?) -> PreparedItem {
        var metadata = event
        metadata.route = []
        let carried = Carried(metadata)
        return PreparedItem {
            guard case .object(var fields) = try CanonicalJSON.value(of: carried.value) else {
                throw CanonicalJSON.NotAnObject()
            }
            fields[routeField] = nil
            if let route, let reference = BlobFiles.reference(route, ext: "route") {
                fields[routeField] = reference.value
            }
            return .object(fields)
        }
    }

    /// A record's fields as a listen: the route is the store's own file, not points.
    static func decode(_ fields: [String: JSONValue]) throws -> ListenEvent {
        var plain = fields
        plain[routeField] = nil
        return try SyncShape.fields.decode(ListenEvent.self, from: plain)
    }
}
