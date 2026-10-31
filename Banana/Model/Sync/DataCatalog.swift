import Foundation

/// Every kind of data that syncs (`Shared/DataCatalog.json`, docs/design/DATA-PLATFORM.md §5).
/// The service validates against the same file; here it drives the mirror, the seeding rules and
/// the blob downloads.
struct DataCatalog: Decodable, Sendable {
    enum Tier: String, Decodable, Sendable { case t1 = "T1", t2 = "T2" }
    enum Writers: String, Decodable, Sendable { case any, hub }
    enum Seed: String, Decodable, Sendable { case edited, phoneSet, `default` }
    enum BlobRule: String, Decodable, Sendable { case eager, lazy }

    struct Entry: Decodable, Sendable, Equatable {
        var type: String
        var tier: Tier
        var merge: RecordMerge.Kind
        var writers: Writers
        var seed: Seed
        var blobs: [String: BlobRule]?
        var day: String?
        var analytics: [String]?
        /// Types whose arrival can unblock records of this type a store couldn't take yet: their
        /// arrival replays this type (§5).
        var after: [String]?

        /// Needs the Health consent (§7).
        var isHealth: Bool { tier == .t2 }
        var blobFields: [String: BlobRule] { blobs ?? [:] }
    }

    let version: Int
    let types: [Entry]
    private let byType: [String: Entry]
    private let unblocks: [String: [String]]

    private enum CodingKeys: String, CodingKey { case version, types }

    init(version: Int, types: [Entry]) {
        self.version = version
        self.types = types
        byType = Dictionary(types.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
        var unblocks: [String: [String]] = [:]
        for entry in types { for parent in entry.after ?? [] { unblocks[parent, default: []].append(entry.type) } }
        self.unblocks = unblocks.mapValues { $0.sorted() }
    }

    /// The types to replay when records of `type` arrive (the ones that list it in `after`).
    func replayed(after type: String) -> [String] { unblocks[type] ?? [] }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try container.decode(Int.self, forKey: .version),
                  types: try container.decode([Entry].self, forKey: .types))
    }

    subscript(type: String) -> Entry? { byType[type] }

    var healthTypes: Set<String> { Set(types.filter(\.isHealth).map(\.type)) }

    static func decode(_ data: Data) throws -> DataCatalog {
        try JSONDecoder().decode(DataCatalog.self, from: data)
    }

    /// The copy bundled into the app.
    static func bundled(_ bundle: Bundle = .main) throws -> DataCatalog {
        guard let url = bundle.url(forResource: "DataCatalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }
}
