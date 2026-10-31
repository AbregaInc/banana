#if !BANANA_PUBLIC
import Foundation

/// Only direct, unfiltered message reads imply an empty label set when the field
/// is omitted. History/listing messages keep the forgiving, unknown-field model.
struct GmailReadMessage: Decodable, Sendable {
    var value: GmailMessage
    private enum CodingKeys: String, CodingKey { case labelIds }
    init(from decoder: Decoder) throws {
        value = try GmailMessage(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        value.labelIds = try fields.decodeIfPresent([String].self, forKey: .labelIds) ?? []
        guard value.labelIds!.allSatisfy({ !$0.isEmpty }) else {
            throw DecodingError.dataCorruptedError(forKey: .labelIds, in: fields, debugDescription: "Empty label identity")
        }
    }
}

struct GmailReadThread: Decodable, Sendable {
    var value: GmailThread
    private enum CodingKeys: String, CodingKey { case id, historyId, messages }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        value = GmailThread(id: try fields.gmail(String.self, .id), historyId: fields.gmailUInt64(.historyId),
            messages: try fields.decodeIfPresent([GmailReadMessage].self, forKey: .messages)?.map(\.value))
    }
}

#endif
