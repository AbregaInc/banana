#if !BANANA_PUBLIC
import Foundation

/// Gmail owns the draft; these IDs survive edits while the message version changes.
struct GmailDraftReference: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable { var id: String; var threadId: String? }
    var id: String
    var message: Message
}
struct GmailDraftValue: Decodable, Sendable {
    var id: String
    var message: GmailMessage
    init(id: String, message: GmailMessage) { self.id = id; self.message = message }
    private enum CodingKeys: String, CodingKey { case id, message }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        message = try fields.decode(GmailReadMessage.self, forKey: .message).value
    }
}
struct GmailDraftComposition: Codable, Equatable, Sendable {
    struct Person: Codable, Equatable, Sendable { var address: String; var name: String? }
    struct Attachment: Codable, Equatable, Sendable {
        var name: String; var mimeType: String; var bytes: Int; var chunks: [String]
    }
    var from: Person
    var to: [Person]; var cc: [Person]; var bcc: [Person]
    var subject: String; var plain: String; var html: String
    var attachments: [Attachment]
    var inReplyTo: String?; var references: [String]?; var threadID: String?
}
struct GmailDraftMutation: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case create, update, delete, send }
    var operationID: String
    var email: String
    var action: Action
    var id: String?
    var expectedMessageID: String?
    var content: GmailDraftComposition?
}
struct GmailDraftRejection: Error, Sendable {
    var status: Int
    var body: Data
    var terminal: Bool {
        struct Envelope: Decodable { struct Operation: Decodable { var state: String }; var bananaOperation: Operation? }
        return (try? JSONDecoder().decode(Envelope.self, from: body).bananaOperation?.state) == "done"
    }
}
protocol GmailDraftAPI: Sendable {
    func uploadDraftPart(token: String, operationID: String, hash: String, data: Data) async throws
    func drafts(token: String, pageToken: String?) async throws -> GmailDraftPage
    func draft(token: String, id: String) async throws -> GmailDraftValue
    /// The caller must persist this exact operation before dispatch and reuse it after a lost reply.
    func mutateDraft(token: String, request: GmailDraftMutation) async throws -> Data
}
extension GmailDraftAPI {
    func uploadDraftPart(token: String, operationID: String, hash: String, data: Data) async throws { throw GmailError.networkDisabled }
}
#endif
