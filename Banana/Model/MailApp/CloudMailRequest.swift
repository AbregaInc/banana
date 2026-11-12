#if !BANANA_PUBLIC
import Foundation

/// An opaque local routing reference, not a Google access token. Only Banana's service authenticates it.
struct CloudMailReference: Codable, Sendable {
    let email: String
    let context: String
    var value: String { "banana-mail:" + (try! JSONEncoder().encode(self)).base64EncodedString() }
    init(email: String, context: String) { self.email = email.lowercased(); self.context = context }
    init(value: String) throws {
        guard value.hasPrefix("banana-mail:"), let data = Data(base64Encoded: String(value.dropFirst(12))) else {
            throw GmailError.unauthorized
        }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard !email.isEmpty, !context.isEmpty else { throw GmailError.unauthorized }
    }
}

struct CloudMailSenderPolicy: MailSenderPolicyAPI {
    let feed: CloudMailFeed
    func read(account: String, sender: String) async throws -> MailSenderPolicyRemote {
        try await request(account: account, values: ["sender": sender])
    }
    func write(account: String, sender: String, blocked: Bool, revision: Int, operation: String) async throws -> MailSenderPolicyRemote {
        try await request(account: account, values: ["sender": sender, "blocked": blocked, "revision": revision, "operation": operation])
    }
    private func request(account: String, values: [String: Any]) async throws -> MailSenderPolicyRemote {
        var value = values; value["email"] = account.lowercased()
        let body = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        let reference = try await feed.reference(account)
        let (data, status) = try await feed.transport("sender-policy", reference, body)
        if status == 200 || status == 409 {
            let remote = try JSONDecoder().decode(MailSenderPolicyRemote.self, from: data)
            guard remote.revision >= 0 else { throw GmailError.malformed }
            if status == 409 { throw MailSenderPolicyError.conflict(remote) }
            return remote
        }
        throw GmailHTTPRules.failure(status: status, data: data, retryAfter: nil)
    }
}

enum CloudMailRequest {
    static func body(path: [String], email: String, query: [URLQueryItem], method: String, body: Data?) throws -> Data {
        var request: [String: Any] = ["email": email.lowercased()]
        if method == "GET" {
            let resource: String
            switch path.count {
            case 1 where ["profile", "labels", "messages", "history", "drafts"].contains(path[0]): resource = path[0]
            case 2 where path[0] == "messages" || path[0] == "threads" || path[0] == "drafts":
                resource = path[0] == "messages" ? "message" : path[0] == "drafts" ? "draft" : "thread"; request["id"] = path[1]
            case 4 where path[0] == "messages" && path[2] == "attachments":
                resource = "attachment"; request["id"] = path[1]; request["attachmentID"] = path[3]
            default: throw GmailError.refused(.invalidArgument)
            }
            request["resource"] = resource
            request["query"] = query.map { ["name": $0.name, "value": $0.value ?? ""] }
        } else if method == "POST", path == ["labels"], query.isEmpty {
            // Banana's own hidden labels only (the service refuses any other name); the service
            // returns the label that already has the name, or makes it.
            guard let body, let label = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let name = label["name"] as? String, name.hasPrefix("Banana/") else { throw GmailError.refused(.invalidArgument) }
            request["action"] = "createLabel"; request["name"] = name
        } else {
            guard method == "POST", path.count == 3, path[0] == "messages",
                  ["modify", "trash", "untrash"].contains(path[2]), query.isEmpty else { throw GmailError.refused(.invalidArgument) }
            request["id"] = path[1]; request["action"] = path[2]
            if path[2] == "modify" {
                guard let body, let labels = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    throw GmailError.refused(.invalidArgument)
                }
                request["add"] = labels["addLabelIds"] ?? []
                request["remove"] = labels["removeLabelIds"] ?? []
            }
        }
        return try JSONSerialization.data(withJSONObject: request, options: .sortedKeys)
    }
}
/// Banana Cloud's shared mailbox feed and catch-up check (MAIL-CLOUD-SYNC §4), over the same
/// account-scoped routing reference as every other cloud Mail request. A service without the
/// route (404) is `unavailable`; a cursor past the feed's horizon (410) is `expired`.
struct CloudMailFeed: MailCloudFeedSource {
    /// (path, routing reference, JSON body) → (body, status). Throws when the request never got an answer.
    typealias Transport = @Sendable (String, String, Data) async throws -> (Data, Int)
    let reference: @Sendable (String) async throws -> String
    let transport: Transport

    static func pageBody(email: String, after: String?, limit: Int, fresh: Bool) throws -> Data {
        var body: [String: Any] = ["email": email.lowercased(), "limit": limit]
        if let after { body["after"] = after }
        if fresh { body["fresh"] = true }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    func page(account: String, after: String?, limit: Int, fresh: Bool) async throws -> MailCloudFeedPage {
        guard (1...1000).contains(limit) else { throw GmailError.refused(.invalidArgument) }
        let route = try await reference(account)
        let (data, status) = try await transport("feed", route, try Self.pageBody(email: account, after: after, limit: limit, fresh: fresh))
        switch status {
        case 200:
            do { return try JSONDecoder().decode(MailCloudFeedPage.self, from: data) }
            catch { throw GmailError.malformed }
        case 404: throw MailCloudFeedError.unavailable
        case 410: throw MailCloudFeedError.expired
        default: throw GmailHTTPRules.failure(status: status, data: data, retryAfter: nil)
        }
    }

    /// The answer of `/v1/mail/content`: one entry per id asked.
    struct ContentAnswer: Decodable {
        struct Item: Decodable {
            var id: String
            var message: GmailMessage?
            var missing: Bool?
            var gone: Bool?
            var later: Bool?
        }
        var messages: [Item]
    }

    func contents(account: String, ids: [String]) async throws -> [MailCloudContent] {
        guard !ids.isEmpty, ids.count <= 50 else { throw GmailError.refused(.invalidArgument) }
        let route = try await reference(account)
        let body = try JSONSerialization.data(withJSONObject: ["email": account.lowercased(), "ids": ids], options: .sortedKeys)
        let (data, status) = try await transport("content", route, body)
        switch status {
        case 200:
            let answer: ContentAnswer
            do { answer = try JSONDecoder().decode(ContentAnswer.self, from: data) } catch { throw GmailError.malformed }
            let asked = Set(ids)
            return answer.messages.compactMap { item in
                guard asked.contains(item.id) else { return nil }
                if let message = item.message { return message.id == item.id ? .message(message) : .missing(item.id) }
                if item.gone == true { return .gone(item.id) }
                if item.later == true { return .later(item.id) }
                return .missing(item.id)
            }
        case 404, 409: throw MailCloudFeedError.unavailable
        default: throw GmailHTTPRules.failure(status: status, data: data, retryAfter: nil)
        }
    }

    func check(account: String, ids: [String]) async throws {
        guard !ids.isEmpty, ids.count <= 100 else { throw GmailError.refused(.invalidArgument) }
        let route = try await reference(account)
        let body = try JSONSerialization.data(withJSONObject: ["email": account.lowercased(), "ids": ids], options: .sortedKeys)
        let (data, status) = try await transport("check", route, body)
        guard status == 200 else {
            if status == 404 || status == 409 { throw MailCloudFeedError.unavailable }
            throw GmailHTTPRules.failure(status: status, data: data, retryAfter: nil)
        }
    }
}
#endif
