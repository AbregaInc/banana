import CryptoKit
import Foundation

/// A durable native delivery journal. It never falls back to direct Google writes after dispatch.
actor CloudProviderOperationJournal {
    struct Ticket: Codable, Sendable { let key: String; let body: Data }
    /// Sign-in sessions rotate; an outstanding operation belongs to the durable account.
    nonisolated static func context(account: String, host: String) -> String {
        let fields = [host.lowercased(), account]
        return SHA256.hash(data: try! JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isTerminal(status: Int, response: Data, ticket: Ticket) -> Bool {
        if (200..<300).contains(status) { return true }
        guard let sent = try? JSONSerialization.jsonObject(with: ticket.body) as? [String: Any],
              let received = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let receipt = received["bananaOperation"] as? [String: String],
              receipt["state"] == "done", let id = sent["operationID"] as? String else { return false }
        return receipt["id"] == id
    }

    private let directory: URL
    init(directory: URL) { self.directory = directory }

    private var ownership: Set<String>?
    private func ownershipKey(email: String, host: String) -> String {
        SHA256.hash(data: Data((host.lowercased() + "\n" + email.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func loadOwnership() throws -> Set<String> {
        if let ownership { return ownership }
        let file = directory.appendingPathComponent("ownership.json")
        let loaded = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file)) : []
        ownership = loaded
        return loaded
    }
    func requiresCloud(email: String, host: String) throws -> Bool {
        try loadOwnership().contains(ownershipKey(email: email, host: host))
    }
    func claim(email: String, host: String) throws {
        var next = try loadOwnership()
        guard next.insert(ownershipKey(email: email, host: host)).inserted else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("ownership.json"), options: .atomic)
        ownership = next
    }

    func prepare(url: URL, method: String, body: Data?, ifMatch: String?, email: String,
                 context: String) throws -> Ticket {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let move = method == "POST" && parts.percentEncodedPath.hasSuffix("/move")
        if move { parts.percentEncodedPath.removeLast(5) }
        let read = try CloudCalendarRequest(url: parts.url!, email: email)
        let action: String
        switch (method, read.resource, move) {
        case ("POST", "events", false): action = "insert"
        case ("PATCH", "event", false): action = "patch"
        case ("DELETE", "event", false): action = "delete"
        case ("POST", "event", true): action = "move"
        default: throw CloudCalendarSnapshot.Failure.unsupportedResponse
        }
        var envelope: [String: Any] = ["email": email.lowercased(), "calendarID": read.calendarID!, "action": action]
        if let eventID = read.eventID { envelope["eventID"] = eventID }
        if let ifMatch { envelope["ifMatch"] = ifMatch }
        if let body { envelope["body"] = try JSONSerialization.jsonObject(with: body) }
        if move {
            guard let destination = parts.queryItems?.first(where: { $0.name == "destination" })?.value else {
                throw CloudCalendarSnapshot.Failure.unsupportedResponse
            }
            envelope["destination"] = destination
        }
        envelope["query"] = (parts.queryItems ?? []).filter { $0.name != "destination" }
            .map { ["name": $0.name, "value": $0.value ?? ""] }
        return try prepare(envelope: JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys), context: context)
    }

    func prepare(envelope data: Data, context: String) throws -> Ticket {
        guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudCalendarSnapshot.Failure.unsupportedResponse
        }
        envelope.removeValue(forKey: "operationID")
        let canonical = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        let key = SHA256.hash(data: Data(context.utf8) + canonical).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            // Unreadable intent is an error, not permission to replace its operation identity.
            return Ticket(key: key, body: try Data(contentsOf: file))
        }
        envelope["operationID"] = UUID().uuidString.lowercased()
        let encoded = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.write(to: file, options: .atomic)
        return Ticket(key: key, body: encoded)
    }

    /// Remove only an acknowledged delivery. The service keeps its durable receipt independently.
    func acknowledged(_ ticket: Ticket) throws {
        let file = directory.appendingPathComponent(ticket.key + ".json")
        // Another call cannot erase a replacement operation with the same request fingerprint.
        guard try Data(contentsOf: file) == ticket.body else { return }
        try FileManager.default.removeItem(at: file)
    }
}
