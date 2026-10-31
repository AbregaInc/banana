import Foundation

/// `POST /v2/sync` (docs/design/DATA-PLATFORM.md §4): what this device sends.
struct SyncRequest: Encodable, Sendable, Equatable {
    struct Change: Encodable, Sendable, Equatable {
        var type: String
        var id: String
        var set: [String: JSONValue]
        var clocks: [String: String]
        var delete: String?
        var schema: Int = 1

        private enum CodingKeys: String, CodingKey { case type, id, set, clocks, delete, schema }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(set, forKey: .set)
            try container.encode(clocks, forKey: .clocks)
            if let delete { try container.encode(delete, forKey: .delete) } else { try container.encodeNil(forKey: .delete) }
            try container.encode(schema, forKey: .schema)
        }
    }

    /// Nil: the account's own space.
    var space: String?
    var device: String
    var since: Int64
    var changes: [Change]

    /// The body, in the canonical encoding.
    func body() throws -> Data { CanonicalJSON.data(try CanonicalJSON.value(of: self)) }
}

/// The service's answer.
struct SyncAnswer: Decodable, Sendable, Equatable {
    struct Applied: Codable, Sendable, Equatable {
        var type: String
        var id: String
        var clocks: [String: String]
        var deleted: String?
    }

    struct Record: Codable, Sendable, Equatable {
        var type: String
        var id: String
        var fields: [String: JSONValue]
        var clocks: [String: String]
        var deleted: String?
        var seq: Int64
    }

    struct Rejected: Codable, Sendable, Equatable {
        var type: String
        var id: String
        var reason: String
    }

    struct Consents: Codable, Sendable, Equatable {
        var health: Bool?
    }

    /// The service's time, in milliseconds.
    var now: Int64
    /// This life of the space: a new one after a wipe (§4).
    var epoch: String?
    var head: Int64?
    /// The `seq` of the last record in `changes`: the cursor moves only this far.
    var next: Int64?
    var more: Bool
    var applied: [Applied]
    var changes: [Record]
    var rejected: [Rejected]
    var consents: Consents?

    init(now: Int64, epoch: String? = nil, head: Int64? = nil, next: Int64?, more: Bool, applied: [Applied] = [],
         changes: [Record] = [], rejected: [Rejected] = [], consents: Consents? = nil) {
        self.now = now
        self.epoch = epoch
        self.head = head
        self.next = next
        self.more = more
        self.applied = applied
        self.changes = changes
        self.rejected = rejected
        self.consents = consents
    }

    private enum CodingKeys: String, CodingKey { case now, epoch, head, next, more, applied, changes, rejected, consents }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = try c.decode(Int64.self, forKey: .now)
        epoch = try c.decodeIfPresent(String.self, forKey: .epoch)
        head = try c.decodeIfPresent(Int64.self, forKey: .head)
        next = try c.decodeIfPresent(Int64.self, forKey: .next)
        more = try c.decodeIfPresent(Bool.self, forKey: .more) ?? false
        applied = try c.decodeIfPresent([Applied].self, forKey: .applied) ?? []
        changes = try c.decodeIfPresent([Record].self, forKey: .changes) ?? []
        rejected = try c.decodeIfPresent([Rejected].self, forKey: .rejected) ?? []
        consents = try c.decodeIfPresent(Consents.self, forKey: .consents)
    }
}

/// How `SpaceSync` reaches the service: the real one over HTTP, or a stand-in in tests.
protocol SyncTransport: Sendable {
    func sync(_ request: SyncRequest) async throws -> SyncAnswer
    /// Puts a blob from a file, streamed, saying which type's record names it (the service refuses
    /// a T2 blob without the Health consent: `consent`). Already there is fine.
    func putBlob(sha256: String, file: URL, type: String) async throws
    /// Fetches a blob into a temporary file the caller owns.
    func getBlob(sha256: String) async throws -> URL
    func hasBlob(sha256: String) async throws -> Bool
    /// `PUT /v2/devices/:id/sync-state` (§4): when this device's seed was acknowledged, and when
    /// it stopped writing iCloud.
    func reportSyncState(device: String, seededAt: Date?, flippedAt: Date?, seeded: [String]?) async throws
}

enum SyncTransportError: Error, Equatable {
    /// No session: signed out, or not yet signed in.
    case noSession
    case status(Int, String?)
    case malformed

    /// The service refused for want of the Health consent.
    var isConsent: Bool { self == .status(403, "consent") }

    /// The request was too big (413): the next batch is smaller.
    var isTooLarge: Bool { if case .status(413, _) = self { true } else { false } }

    /// A refusal that trying again won't change (a 4xx other than timeouts, throttling and auth).
    var isPermanent: Bool {
        guard case .status(let code, _) = self else { return false }
        return (400..<500).contains(code) && ![401, 403, 408, 409, 425, 429].contains(code)
    }
}

/// The Banana service over HTTPS, with the account's session as `BananaAccount` sends it, bound to
/// the account it was made for: a session for any other account (a sign-in elsewhere, synced by
/// the keychain) never reaches this mirror's space.
struct HTTPSyncTransport: SyncTransport {
    let host: String
    /// The account this transport (and its mirror) belongs to.
    let account: String
    /// The session and the signed-in account's id, read where they live (`BananaAccount`).
    let credentials: @Sendable () async -> (session: String?, account: String?)
    var urlSession: URLSession = .shared
    /// The idle time a sync or a blob may take: longer than the 20 s of an ordinary call.
    var timeout: TimeInterval = 60

    private func request(_ call: BananaService.Call) async throws -> URLRequest {
        let current = await credentials()
        guard let session = current.session, current.account == account else { throw SyncTransportError.noSession }
        var request = BananaService.request(call, host: host, session: session)
        request.timeoutInterval = timeout
        return request
    }

    private func check(_ response: URLResponse, _ data: Data?, ok: Set<Int>) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard ok.contains(status) else {
            throw SyncTransportError.status(status, data.flatMap(BananaService.failure(in:)))
        }
    }

    func sync(_ body: SyncRequest) async throws -> SyncAnswer {
        let request = try await request(.sync(try body.body()))
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data, ok: [200])
        do { return try JSONDecoder().decode(SyncAnswer.self, from: data) }
        catch { throw SyncTransportError.malformed }
    }

    func putBlob(sha256: String, file: URL, type: String) async throws {
        var request = try await request(.blob(method: "PUT", sha256: sha256))
        request.setValue(type, forHTTPHeaderField: "X-Banana-Type")
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await urlSession.upload(for: request, fromFile: file)
        try check(response, data, ok: [200, 201, 204])
    }

    func getBlob(sha256: String) async throws -> URL {
        let request = try await request(.blob(method: "GET", sha256: sha256))
        let (downloaded, response) = try await urlSession.download(for: request)
        try check(response, nil, ok: [200])
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(sha256)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: downloaded, to: kept)
        return kept
    }

    func hasBlob(sha256: String) async throws -> Bool {
        let request = try await request(.blob(method: "HEAD", sha256: sha256))
        let (_, response) = try await urlSession.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 204: return true
        case 404: return false
        case let status: throw SyncTransportError.status(status, nil)
        }
    }

    func reportSyncState(device: String, seededAt: Date?, flippedAt: Date?, seeded: [String]?) async throws {
        let request = try await request(.syncState(device: device, seededAt: seededAt, flippedAt: flippedAt, seeded: seeded))
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data, ok: [200, 204])
    }
}
