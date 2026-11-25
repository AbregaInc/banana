#if BANANA_AI && os(macOS)
import CryptoKit
import Foundation

/// The service distributes signed data for the inference runtime shipped in the app.
enum ModelCatalog {
    static let maximumBytes = 128 * 1024
    static let runtimeABI = 1
    static let publicKey = Data(base64Encoded: "0Sa0Emfz/5BshbHio0o902k5mJ5LsVZUPaeKReBTIyM=")!

    struct Envelope: Decodable {
        let payload: Data
        let signature: Data
    }

    struct Entry: Decodable, Sendable {
        let pin: PinnedModelFiles.Manifest
        let minimumBuild: Int
        let minimumMemoryGiB: Int
        let runtimeABI: Int

        func supports(build: Int, memory: UInt64) -> Bool {
            runtimeABI == ModelCatalog.runtimeABI && minimumBuild <= build
                && UInt64(minimumMemoryGiB) * (1 << 30) <= memory
        }
    }

    struct Listing: Decodable, Sendable {
        let schema: Int
        let channel: String
        let sequence: Int
        /// Most recommended first. Empty is a deliberate pause on new downloads.
        let models: [Entry]
    }

    static func verify(_ raw: Data, channel: String, key: Data = publicKey) -> Listing? {
        guard raw.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: raw),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              key.isValidSignature(envelope.signature, for: envelope.payload),
              let listing = try? JSONDecoder().decode(Listing.self, from: envelope.payload),
              listing.schema == 1, listing.channel == channel, listing.sequence > 0,
              listing.models.count <= 12,
              listing.models.allSatisfy({
                  $0.minimumBuild > 0 && (1...256).contains($0.minimumMemoryGiB) && $0.pin.isCatalogSafe
              }),
              Set(listing.models.map { $0.pin.installationID }).count == listing.models.count else { return nil }
        return listing
    }

    static func file(named name: String, in folder: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(name)) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maximumBytes + 1)
    }

    static func save(_ data: Data, as name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    static func refresh(host: String, channel: String, in folder: URL) async -> (Listing, Data)? {
        let cached = file(named: "catalog.json", in: folder).flatMap { data in
            verify(data, channel: channel).map { ($0, data) }
        }
        guard let url = URL(string: "https://\(host)/v1/assistant/model-catalog"), url.host == host else { return cached }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpShouldHandleCookies = false
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (temporary, response) = try? await session.download(for: request) else { return cached }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let size = PinnedModelFiles.size(of: temporary), size <= maximumBytes,
              let data = try? Data(contentsOf: temporary),
              let listing = verify(data, channel: channel),
              listing.sequence > (cached?.0.sequence ?? 0) else { return cached }
        try? save(data, as: "catalog.json", in: folder)
        return (listing, data)
    }
}
#endif
