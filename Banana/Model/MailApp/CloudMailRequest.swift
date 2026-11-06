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
#endif
