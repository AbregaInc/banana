#if !BANANA_PUBLIC
import Foundation

// Gmail's REST JSON, as Swift values (MAIL-ENGINE 5.1, Appendix A).
//
// Everything the engine learns about a message arrives through these types, and the answer
// that decides what it does is often *which fields were there*. So they are written to be read
// the way Gmail's responses are, not the way a schema promises:
//
// - Every property is optional. Gmail sends different fields for different formats and does not
//   document exactly which (research dossier 2.1, "could not verify" 2), and a field it did
//   not send is *unknown*, not empty (invariant 1): `labelIds` nil is a message whose labels
//   were not read, which must never be taken for one with none.
// - An unknown key is ignored.
// - A key that has the wrong type, or `null`, is nil. It does not fail the object it is in, and
//   so does not lose the message it came with. (An array is all or nothing: one element that
//   cannot be read makes the array nil, not shorter, because a label list that lost one label
//   looks exactly like a message that never had it.) **A page is different**: Gmail leaves a
//   page's list out when it is empty, so a list that is *there* and cannot be read is not
//   "nothing happened" — the page types, and a thread's messages, throw, and the transport
//   reports `malformed`. Their elements stay lenient.
// - `historyId` and `internalDate` arrive as decimal strings and are parsed to `UInt64` and
//   `Int64`; a value that does not parse is nil, never zero. A JSON number is read too, in
//   case a response or a fake ever sends one.
//
// What cannot be tolerated is a response that is not JSON, or whose outermost value is not an
// object, or that nests deeper than the JSON reader allows (about 250 levels, so a MIME tree
// more than about 120 parts deep): those throw a `DecodingError`, which the transport reports
// as `GmailError.malformed`. **And mail has a limit of its own**, so that what stops a hostile
// tree is not a number somebody else may raise: a `GmailPart` nested deeper than
// `GmailPart.maxDepth` (64) throws `GmailDecodeLimit.partsTooDeep` through every forgiving layer
// above it. A message stopped there is the undecodable message of 5.6.
//
// The fixtures that drive these types are written by hand from the documented shapes. None was
// captured from a live mailbox.

// MARK: - Reading helpers

/// What stops a hostile response that is not Foundation's own limit (MAIL-ENGINE 5.6).
enum GmailDecodeLimit: Error, Equatable {
    /// A `GmailPart` nested deeper than `GmailPart.maxDepth`.
    case partsTooDeep
}

extension KeyedDecodingContainer {

    /// The value under `key`, or nil when it is missing, `null`, or not the type asked for.
    /// The one thing that is not forgiven is mail's own depth limit, which stops the decode.
    func gmail<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch let limit as GmailDecodeLimit {
            throw limit
        } catch {
            return nil
        }
    }

    /// A 64-bit unsigned number sent as a decimal string, or as a JSON number.
    func gmailUInt64(_ key: Key) -> UInt64? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return GmailNumber.unsigned(text) }
        return try? decodeIfPresent(UInt64.self, forKey: key)
    }

    /// A 64-bit signed number sent as a decimal string, or as a JSON number.
    func gmailInt64(_ key: Key) -> Int64? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return GmailNumber.signed(text) }
        return try? decodeIfPresent(Int64.self, forKey: key)
    }

    /// An integer sent as a JSON number, or as a decimal string.
    func gmailInt(_ key: Key) -> Int? {
        if let number = try? decodeIfPresent(Int.self, forKey: key) { return number }
        if let text = try? decodeIfPresent(String.self, forKey: key), let value = GmailNumber.signed(text) {
            return Int(exactly: value)
        }
        return nil
    }
}

enum GmailNumber {
    /// `text` as an unsigned decimal number: digits only, nothing else, and not out of range.
    /// Not "0x10", not " 5", not "+5", not "".
    static func unsigned(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.count <= 20, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else { return nil }
        return UInt64(text)
    }

    /// `text` as a signed decimal number: optional "-", then digits only.
    static func signed(_ text: String) -> Int64? {
        let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        guard !digits.isEmpty, digits.utf8.count <= 19, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else { return nil }
        return Int64(text)
    }
}

// MARK: - Format

/// How much of a message a read asks for (`messages.get` and `threads.get`'s `format`).
///
/// `header` is Gmail's `metadata`: ids, labels and the headers asked for. The three cost the same
/// 20 units (5.6), so which is asked for is a question of bytes and of what is wanted, not of
/// quota.
enum GmailFormat: String, Equatable, Hashable, Sendable {
    case minimal, header, full

    /// The value of the `format` query parameter.
    var apiValue: String {
        switch self {
        case .minimal: return "minimal"
        case .header: return "metadata"
        case .full: return "full"
        }
    }
}

// MARK: - Profile and labels

struct GmailProfile: Codable, Equatable, Sendable {
    var emailAddress: String?
    var messagesTotal: Int?
    var threadsTotal: Int?
    var historyId: UInt64?

    private enum CodingKeys: String, CodingKey {
        case emailAddress, messagesTotal, threadsTotal, historyId
    }

    init(emailAddress: String? = nil, messagesTotal: Int? = nil, threadsTotal: Int? = nil,
         historyId: UInt64? = nil) {
        self.emailAddress = emailAddress
        self.messagesTotal = messagesTotal
        self.threadsTotal = threadsTotal
        self.historyId = historyId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emailAddress = try c.gmail(String.self, .emailAddress)
        messagesTotal = c.gmailInt(.messagesTotal)
        threadsTotal = c.gmailInt(.threadsTotal)
        historyId = c.gmailUInt64(.historyId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(emailAddress, forKey: .emailAddress)
        try c.encodeIfPresent(messagesTotal, forKey: .messagesTotal)
        try c.encodeIfPresent(threadsTotal, forKey: .threadsTotal)
        try c.encodeIfPresent(historyId.map { String($0) }, forKey: .historyId)
    }
}

struct GmailLabelColor: Codable, Equatable, Sendable {
    var textColor: String?
    var backgroundColor: String?

    init(textColor: String? = nil, backgroundColor: String? = nil) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }

    private enum CodingKeys: String, CodingKey { case textColor, backgroundColor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textColor = try c.gmail(String.self, .textColor)
        backgroundColor = try c.gmail(String.self, .backgroundColor)
    }
}

/// A label. `labels.list` sends only the first five fields; the counts come from `labels.get`
/// (4.2), so a count that is nil is a label whose counts were not asked for, not a label with
/// none.
struct GmailLabel: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    /// "system" or "user"; other values are kept as sent.
    var type: String?
    var messageListVisibility: String?
    var labelListVisibility: String?
    var messagesTotal: Int?
    var messagesUnread: Int?
    var threadsTotal: Int?
    var threadsUnread: Int?
    var color: GmailLabelColor?

    init(id: String? = nil, name: String? = nil, type: String? = nil,
         messageListVisibility: String? = nil, labelListVisibility: String? = nil,
         messagesTotal: Int? = nil, messagesUnread: Int? = nil, threadsTotal: Int? = nil,
         threadsUnread: Int? = nil, color: GmailLabelColor? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.messageListVisibility = messageListVisibility
        self.labelListVisibility = labelListVisibility
        self.messagesTotal = messagesTotal
        self.messagesUnread = messagesUnread
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, messageListVisibility, labelListVisibility
        case messagesTotal, messagesUnread, threadsTotal, threadsUnread, color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.gmail(String.self, .id)
        name = try c.gmail(String.self, .name)
        type = try c.gmail(String.self, .type)
        messageListVisibility = try c.gmail(String.self, .messageListVisibility)
        labelListVisibility = try c.gmail(String.self, .labelListVisibility)
        messagesTotal = c.gmailInt(.messagesTotal)
        messagesUnread = c.gmailInt(.messagesUnread)
        threadsTotal = c.gmailInt(.threadsTotal)
        threadsUnread = c.gmailInt(.threadsUnread)
        color = try c.gmail(GmailLabelColor.self, .color)
    }
}

// MARK: - Messages

struct GmailHeader: Codable, Equatable, Sendable {
    var name: String?
    var value: String?

    init(name: String? = nil, value: String? = nil) {
        self.name = name
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case name, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.gmail(String.self, .name)
        value = try c.gmail(String.self, .value)
    }
}

/// A part's body. `data` is base64url and, on a large part, absent: `attachmentId` is then how
/// it is fetched (`messages.attachments.get`). Neither being present says nothing of the part's
/// content, only of what this read carried.
struct GmailPartBody: Codable, Equatable, Sendable {
    var attachmentId: String?
    var size: Int?
    var data: String?

    init(attachmentId: String? = nil, size: Int? = nil, data: String? = nil) {
        self.attachmentId = attachmentId
        self.size = size
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case attachmentId, size, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attachmentId = try c.gmail(String.self, .attachmentId)
        size = c.gmailInt(.size)
        data = try c.gmail(String.self, .data)
    }
}

/// One node of a message's MIME tree, as Gmail has already parsed it (no MIME parser is built;
/// never `format=raw`). A `metadata` read has a `payload` with headers and a `mimeType` and no
/// `parts` and no `body` (UNVERIFIED); a `minimal` one has no payload at all.
struct GmailPart: Codable, Equatable, Sendable {
    var partId: String?
    var mimeType: String?
    /// Only on attachments.
    var filename: String?
    var headers: [GmailHeader]?
    var body: GmailPartBody?
    var parts: [GmailPart]?

    init(partId: String? = nil, mimeType: String? = nil, filename: String? = nil,
         headers: [GmailHeader]? = nil, body: GmailPartBody? = nil, parts: [GmailPart]? = nil) {
        self.partId = partId
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }

    private enum CodingKeys: String, CodingKey {
        case partId, mimeType, filename, headers, body, parts
    }

    /// How deep a tree of parts may be decoded: the root is depth 0, its children 1. Mail's own
    /// number, well over the walk's 20 and well under Foundation's limit.
    static let maxDepth = 64

    init(from decoder: Decoder) throws {
        // The depth is the number of `parts` keys on the way here: nothing else is counted, and
        // it costs a pass over a path that is never longer than the limit allows.
        let depth = decoder.codingPath.reduce(0) { $0 + ($1.stringValue == "parts" ? 1 : 0) }
        if depth > Self.maxDepth { throw GmailDecodeLimit.partsTooDeep }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partId = try c.gmail(String.self, .partId)
        mimeType = try c.gmail(String.self, .mimeType)
        filename = try c.gmail(String.self, .filename)
        headers = try c.gmail([GmailHeader].self, .headers)
        body = try c.gmail(GmailPartBody.self, .body)
        parts = try c.gmail([GmailPart].self, .parts)
    }
}

/// A message, or — in a listing, a history record, a draft's stub — the few fields of one.
///
/// Which fields a `minimal` and a `metadata` read carry beyond the ids and labels is not
/// documented (dossier 2.1) and every one of them is optional here. A field the read did not
/// carry is nil, which is *unknown*: a nil `labelIds` is not a message with no labels, a nil
/// `internalDate` is not a message from 1970 (the engine keeps a stub's order until it has
/// one).
struct GmailMessage: Codable, Equatable, Sendable {
    var id: String?
    var threadId: String?
    var labelIds: [String]?
    var snippet: String?
    /// The last history record that modified this message.
    var historyId: UInt64?
    /// Epoch milliseconds, when Google accepted the message; the order of the inbox.
    var internalDate: Int64?
    var sizeEstimate: Int?
    var payload: GmailPart?

    init(id: String? = nil, threadId: String? = nil, labelIds: [String]? = nil,
         snippet: String? = nil, historyId: UInt64? = nil, internalDate: Int64? = nil,
         sizeEstimate: Int? = nil, payload: GmailPart? = nil) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.snippet = snippet
        self.historyId = historyId
        self.internalDate = internalDate
        self.sizeEstimate = sizeEstimate
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadId, labelIds, snippet, historyId, internalDate, sizeEstimate, payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.gmail(String.self, .id)
        threadId = try c.gmail(String.self, .threadId)
        labelIds = try c.gmail([String].self, .labelIds)
        snippet = try c.gmail(String.self, .snippet)
        historyId = c.gmailUInt64(.historyId)
        internalDate = c.gmailInt64(.internalDate)
        sizeEstimate = c.gmailInt(.sizeEstimate)
        payload = try c.gmail(GmailPart.self, .payload)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(threadId, forKey: .threadId)
        try c.encodeIfPresent(labelIds, forKey: .labelIds)
        try c.encodeIfPresent(snippet, forKey: .snippet)
        try c.encodeIfPresent(historyId.map { String($0) }, forKey: .historyId)
        try c.encodeIfPresent(internalDate.map { String($0) }, forKey: .internalDate)
        try c.encodeIfPresent(sizeEstimate, forKey: .sizeEstimate)
        try c.encodeIfPresent(payload, forKey: .payload)
    }
}

struct GmailThread: Codable, Equatable, Sendable {
    var id: String?
    var historyId: UInt64?
    /// Oldest first. Nil when the read carried none (`threads.list`'s stubs have none).
    var messages: [GmailMessage]?

    init(id: String? = nil, historyId: UInt64? = nil, messages: [GmailMessage]? = nil) {
        self.id = id
        self.historyId = historyId
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey { case id, historyId, messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.gmail(String.self, .id)
        historyId = c.gmailUInt64(.historyId)
        // Present and unreadable is not "no messages": it throws (see the top of this file).
        messages = try c.decodeIfPresent([GmailMessage].self, forKey: .messages)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(historyId.map { String($0) }, forKey: .historyId)
        try c.encodeIfPresent(messages, forKey: .messages)
    }
}

// MARK: - Listings

/// What `messages.list` gives for each message: its id and its thread, nothing else (dossier
/// 14.6; every row of a list needs a `get`).
struct GmailMessageRef: Codable, Equatable, Sendable {
    var id: String?
    var threadId: String?

    init(id: String? = nil, threadId: String? = nil) {
        self.id = id
        self.threadId = threadId
    }

    private enum CodingKeys: String, CodingKey { case id, threadId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.gmail(String.self, .id)
        threadId = try c.gmail(String.self, .threadId)
    }
}

/// One page of `messages.list`. `resultSizeEstimate` is an estimate and is never a count.
struct GmailIDPage: Codable, Equatable, Sendable {
    var messages: [GmailMessageRef]?
    var nextPageToken: String?
    var resultSizeEstimate: Int?

    init(messages: [GmailMessageRef]? = nil, nextPageToken: String? = nil,
         resultSizeEstimate: Int? = nil) {
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }

    private enum CodingKeys: String, CodingKey { case messages, nextPageToken, resultSizeEstimate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([GmailMessageRef].self, forKey: .messages)
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
        resultSizeEstimate = c.gmailInt(.resultSizeEstimate)
    }
}

// MARK: - History

/// One entry of a history record's `messagesAdded`, `messagesDeleted`, `labelsAdded` or
/// `labelsRemoved`. `message` carries only ids and, on a label record, its labels as they now
/// are or were; `labelIds` is the labels that changed, and only on the two label records.
struct GmailHistoryChange: Codable, Equatable, Sendable {
    var message: GmailMessage?
    var labelIds: [String]?

    init(message: GmailMessage? = nil, labelIds: [String]? = nil) {
        self.message = message
        self.labelIds = labelIds
    }

    private enum CodingKeys: String, CodingKey { case message, labelIds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.gmail(GmailMessage.self, .message)
        labelIds = try c.gmail([String].self, .labelIds)
    }
}

struct GmailHistoryRecord: Codable, Equatable, Sendable {
    var id: UInt64?
    var messagesAdded: [GmailHistoryChange]?
    var messagesDeleted: [GmailHistoryChange]?
    var labelsAdded: [GmailHistoryChange]?
    var labelsRemoved: [GmailHistoryChange]?

    init(id: UInt64? = nil, messagesAdded: [GmailHistoryChange]? = nil,
         messagesDeleted: [GmailHistoryChange]? = nil, labelsAdded: [GmailHistoryChange]? = nil,
         labelsRemoved: [GmailHistoryChange]? = nil) {
        self.id = id
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }

    private enum CodingKeys: String, CodingKey {
        case id, messagesAdded, messagesDeleted, labelsAdded, labelsRemoved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.gmailUInt64(.id)
        // These are change lists, like the outer history page. Forgiving a malformed
        // list as nil would let a checkpoint advance past changes we never read.
        messagesAdded = try c.decodeIfPresent([GmailHistoryChange].self, forKey: .messagesAdded)
        messagesDeleted = try c.decodeIfPresent([GmailHistoryChange].self, forKey: .messagesDeleted)
        labelsAdded = try c.decodeIfPresent([GmailHistoryChange].self, forKey: .labelsAdded)
        labelsRemoved = try c.decodeIfPresent([GmailHistoryChange].self, forKey: .labelsRemoved)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id.map { String($0) }, forKey: .id)
        try c.encodeIfPresent(messagesAdded, forKey: .messagesAdded)
        try c.encodeIfPresent(messagesDeleted, forKey: .messagesDeleted)
        try c.encodeIfPresent(labelsAdded, forKey: .labelsAdded)
        try c.encodeIfPresent(labelsRemoved, forKey: .labelsRemoved)
    }
}

/// One page of `history.list`. A missing `history` is a page with no records *read*; whether
/// there were none to read is what `historyId` and the absence of `nextPageToken` say, and
/// that is the engine's to decide (5.5).
struct GmailHistoryPage: Codable, Equatable, Sendable {
    var history: [GmailHistoryRecord]?
    var nextPageToken: String?
    /// The mailbox's current history id.
    var historyId: UInt64?

    init(history: [GmailHistoryRecord]? = nil, nextPageToken: String? = nil,
         historyId: UInt64? = nil) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }

    private enum CodingKeys: String, CodingKey { case history, nextPageToken, historyId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        history = try c.decodeIfPresent([GmailHistoryRecord].self, forKey: .history)
        // An unreadable continuation must not turn a partial page into the final page.
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
        historyId = c.gmailUInt64(.historyId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(history, forKey: .history)
        try c.encodeIfPresent(nextPageToken, forKey: .nextPageToken)
        try c.encodeIfPresent(historyId.map { String($0) }, forKey: .historyId)
    }
}

// MARK: - Drafts and aliases

/// A draft: its own id, and the message it holds. A draft's message id changes with every
/// update, so the draft id is the one to key on (dossier 14.1).
struct GmailDraft: Codable, Equatable, Sendable {
    var id: String?
    var message: GmailMessage?

    init(id: String? = nil, message: GmailMessage? = nil) {
        self.id = id
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case id, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.gmail(String.self, .id)
        message = try c.gmail(GmailMessage.self, .message)
    }
}

/// One page of `drafts.list`: each draft's id and the ids of its message and thread.
struct GmailDraftPage: Codable, Equatable, Sendable {
    var drafts: [GmailDraft]?
    var nextPageToken: String?

    init(drafts: [GmailDraft]? = nil, nextPageToken: String? = nil) {
        self.drafts = drafts
        self.nextPageToken = nextPageToken
    }

    private enum CodingKeys: String, CodingKey { case drafts, nextPageToken }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drafts = try c.decodeIfPresent([GmailDraft].self, forKey: .drafts)
        nextPageToken = try c.gmail(String.self, .nextPageToken)
    }
}

/// One of the addresses an account may send from (`settings.sendAs`).
struct GmailSendAs: Codable, Equatable, Sendable {
    var sendAsEmail: String?
    var displayName: String?
    var replyToAddress: String?
    var signature: String?
    var isPrimary: Bool?
    var isDefault: Bool?
    var verificationStatus: String?

    init(sendAsEmail: String? = nil, displayName: String? = nil, replyToAddress: String? = nil,
         signature: String? = nil, isPrimary: Bool? = nil, isDefault: Bool? = nil,
         verificationStatus: String? = nil) {
        self.sendAsEmail = sendAsEmail
        self.displayName = displayName
        self.replyToAddress = replyToAddress
        self.signature = signature
        self.isPrimary = isPrimary
        self.isDefault = isDefault
        self.verificationStatus = verificationStatus
    }

    private enum CodingKeys: String, CodingKey {
        case sendAsEmail, displayName, replyToAddress, signature, isPrimary, isDefault
        case verificationStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sendAsEmail = try c.gmail(String.self, .sendAsEmail)
        displayName = try c.gmail(String.self, .displayName)
        replyToAddress = try c.gmail(String.self, .replyToAddress)
        signature = try c.gmail(String.self, .signature)
        isPrimary = try c.gmail(Bool.self, .isPrimary)
        isDefault = try c.gmail(Bool.self, .isDefault)
        verificationStatus = try c.gmail(String.self, .verificationStatus)
    }
}

/// The envelope of `labels.list`: `{"labels": [...]}`. A page of the same kind as the others: an
/// empty mailbox has no `labels` key, and one that is there and cannot be read throws.
struct GmailLabelList: Codable, Equatable, Sendable {
    var labels: [GmailLabel]?

    init(labels: [GmailLabel]? = nil) { self.labels = labels }

    private enum CodingKeys: String, CodingKey { case labels }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decodeIfPresent([GmailLabel].self, forKey: .labels)
    }
}

/// The envelope of `settings.sendAs.list`: `{"sendAs": [...]}`.
struct GmailSendAsList: Codable, Equatable, Sendable {
    var sendAs: [GmailSendAs]?

    init(sendAs: [GmailSendAs]? = nil) { self.sendAs = sendAs }

    private enum CodingKeys: String, CodingKey { case sendAs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sendAs = try c.decodeIfPresent([GmailSendAs].self, forKey: .sendAs)
    }
}

// MARK: - MIME structure

/// A message's MIME tree *without its data*: what the engine keeps in `blobs.sqlite`'s
/// `structure` column (4.7), and what everything that needs to know a message's shape — which
/// part is the body, what is attached — reads, without reading a part's bytes.
///
/// **Its whole shape is declared here, once** (MAIL-ENGINE appendix A), because the packages that
/// fill and read it (P03b, P07, P16, P20, P21, P23c) can add functions to it by extension and
/// cannot add a stored field. `MIMEStructure.extract` (P03b) walks Gmail's already-parsed
/// `payload` under the limits of depth 20 and 1,000 parts, and returns the structure beside the
/// two decoded bodies in a type of its own: **no decoded text is in this value**, because the two
/// bodies have columns of their own and a copy here would store every body twice. The four fields
/// after `attachments` are optional, so a value stored without them decodes.
struct MIMEStructure: Codable, Equatable, Sendable {

    /// One part of the tree, as Gmail described it.
    struct Part: Codable, Equatable, Sendable {
        /// Gmail's `partId`: immutable, and the key an attachment is stored under, because its
        /// `attachmentId` is not stable across reads.
        var partID: String
        /// As declared, lower case, parameters removed: "text/html", "multipart/alternative".
        var mimeType: String
        /// As the sender wrote it (cut at 1 KB, as `mimeType` is at 127 bytes and `contentID` at
        /// 255 — they are his, and as long as he likes). Pass it through `MailFileName.safe`
        /// before it is shown or written anywhere.
        var filename: String?
        /// Decoded size in bytes, as Gmail gave it.
        var size: Int?
        /// Gmail's; not stable across reads, so never a key.
        var attachmentID: String?
        /// `Content-ID` without its angle brackets, the target of a `cid:` picture.
        var contentID: String?
        /// `Content-Disposition: inline`.
        var isInline: Bool
        var children: [Part]

        init(partID: String, mimeType: String, filename: String? = nil, size: Int? = nil,
             attachmentID: String? = nil, contentID: String? = nil, isInline: Bool = false,
             children: [Part] = []) {
            self.partID = partID
            self.mimeType = mimeType
            self.filename = filename
            self.size = size
            self.attachmentID = attachmentID
            self.contentID = contentID
            self.isInline = isInline
            self.children = children
        }
    }

    /// A part that is a file: what a chip shows and what is fetched when it is opened.
    struct Attachment: Codable, Equatable, Sendable {
        var partID: String
        /// `MailFileName.safe` of what was written: cleaned when stored, so that no screen has
        /// to remember to, and at most 255 bytes. (The sender's own text is `Part.filename`.)
        var name: String
        /// As the sender declared it; what the bytes really are is found out when they are
        /// fetched.
        var mimeType: String
        /// Nil when Gmail gave none: not a file of no bytes.
        var size: Int?
        var attachmentID: String?
        var contentID: String?
        var isInline: Bool
        /// A `text/calendar` part: an invitation, to be offered as one.
        var isInvite: Bool

        init(partID: String, name: String, mimeType: String, size: Int? = nil,
             attachmentID: String? = nil, contentID: String? = nil, isInline: Bool = false,
             isInvite: Bool = false) {
            self.partID = partID
            self.name = name
            self.mimeType = mimeType
            self.size = size
            self.attachmentID = attachmentID
            self.contentID = contentID
            self.isInline = isInline
            self.isInvite = isInvite
        }
    }

    /// The invitation a message carries, read when the message is (10.10): never the event.
    struct Invite: Codable, Equatable, Sendable {
        /// The `text/calendar` part, a file or an alternative of the body.
        var partID: String
        /// `METHOD`, upper case: REQUEST, CANCEL, REPLY, …; nil if not found.
        var method: String?
        /// `UID`; nil if not found within the bound.
        var uid: String?

        init(partID: String, method: String? = nil, uid: String? = nil) {
            self.partID = partID
            self.method = method
            self.uid = uid
        }
    }

    /// Why the walk stopped short of the whole tree.
    enum Cut: String, Codable, Sendable { case depth, parts }

    var root: Part
    var attachments: [Attachment]
    /// The part chosen as the HTML body; its text is `content.html`.
    var htmlPartID: String?
    /// The part chosen as the plain body; its text is `content.plain`.
    var plainPartID: String?
    var invite: Invite?
    /// Nil: the tree is whole.
    var cut: Cut?

    init(root: Part, attachments: [Attachment] = [], htmlPartID: String? = nil,
         plainPartID: String? = nil, invite: Invite? = nil, cut: Cut? = nil) {
        self.root = root
        self.attachments = attachments
        self.htmlPartID = htmlPartID
        self.plainPartID = plainPartID
        self.invite = invite
        self.cut = cut
    }
}

#endif
