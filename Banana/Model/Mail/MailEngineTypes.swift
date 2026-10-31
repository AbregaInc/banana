#if !BANANA_PUBLIC
import Foundation

// Shared engine records from MAIL-ENGINE appendix A and section 4.4.
enum MailViewKey: Hashable, Codable, Sendable {
    case label(account: String, labelID: String)   // one account's Gmail label, system or user
    case unified(SystemLabel)                       // the same system label across every account
    case allMail(account: String?)                  // nil: every account
    case done(account: String?)                     // everything not in the inbox, Spam or Trash
    case split(id: String)                          // a saved query over the inbox (9.3)
    case snoozed, muted                             // section 8
}

struct MessageFacts: Equatable, Sendable {      // one message as the rules see it
    var gmailID: String
    /// Local message primary key; supplies undated stub ordering before headers arrive.
    var rowID: Int64 = 0
    var arrivalSequence: Int64 = 0
    var internalDate: Int64            // ms; 0 for a stub
    var fetchState: Int                // 0 stub, 1 header, 2 full
    var vis: Int                       // 4.3
    var labels: Set<String>            // Gmail label ids, effective: Gmail's with the overlay applied
    var labelsKnown: Bool              // a per-message read has described the whole set (6.1); nothing else sets it
    var bananaLabels: [String]         // names of the labels of kind 2 on it
    var fromName: String?, fromAddress: String
    var isFromMe: Bool
    var toAddresses: [String], ccAddresses: [String]
    var subject: String, snippet: String
    var hasAttachment: Bool, hasInvite: Bool
    var listID: String?
    var hasUndeliveredIntent: Bool, hasRefusedIntent: Bool
}
struct SummaryPerson: Equatable, Codable, Sendable {
    var n: String?; var a: String; var u: Bool
    /// Explicit own-address identity; never inferred from a name that says "me".
    var isMe: Bool = false
}
struct ThreadSummary: Equatable, Sendable {
    var lastDate: Int64, messageCount: Int, fetchedCount: Int, unreadCount: Int
    var flags: MailThreadFlags
    var subject: String, snippet: String
    var people: [SummaryPerson], peopleTotal: Int
    var labels: Set<String>
    var wakeAt: Int64?, returnedAt: Int64?, waitingUntil: Int64?
    var pending: Int                   // 0, 1, 2
    var recipients: [SummaryPerson] = []
    var recipientsTotal: Int = 0
    var attendedAt: Int64? = nil
    /// Message-derived claims. The writer also merges durable local draft/send/question claims.
    var claims: MailClaims = []
}
struct MailThreadFlags: OptionSet, Sendable {   // thread.flags
    let rawValue: Int
    static let starred = Self(rawValue: 1), important = Self(rawValue: 2), hasAttachment = Self(rawValue: 4)
    static let hasInvite = Self(rawValue: 8), hasDraft = Self(rawValue: 16), lastIsMine = Self(rawValue: 32)
    static let isList = Self(rawValue: 64), muted = Self(rawValue: 128), keptAfterRemoval = Self(rawValue: 256)
    static let inInbox = Self(rawValue: 512)
}
struct MailMessageFlags: OptionSet, Sendable {  // message.flags
    let rawValue: Int
    static let fromMe = Self(rawValue: 1), hasAttachment = Self(rawValue: 2), hasInvite = Self(rawValue: 4)
    static let labelsKnown = Self(rawValue: 8)
}
enum SystemLabel: String, Codable, CaseIterable, Sendable {
    case inbox = "INBOX", unread = "UNREAD", starred = "STARRED", important = "IMPORTANT", sent = "SENT"
    case draft = "DRAFT", trash = "TRASH", spam = "SPAM"
    case personal = "CATEGORY_PERSONAL", social = "CATEGORY_SOCIAL", promotions = "CATEGORY_PROMOTIONS"
    case updates = "CATEGORY_UPDATES", forums = "CATEGORY_FORUMS"
}
struct ViewMembership: Equatable, Sendable { var view: MailViewKey; var sortKey: Int64; var unread: Bool }

// The outbox
enum AssertionOrigin: Int, Codable, Sendable { case person = 0, rule = 1 }
enum AssertionState: Int, Codable, Sendable { case pending = 0, inFlight = 1, settling = 2, refused = 3 }
struct Assertion: Equatable, Sendable {
    var account: String, messageID: String
    var labelRef: String               // a Gmail label id, or "name:<label name>"
    var want: Bool
    var origin: AssertionOrigin
}
struct StoredAssertion: Equatable, Sendable {
    var assertion: Assertion
    var seq: Int64, sentSeq: Int64?, groupSeq: Int64
    var state: AssertionState
    var attempts: Int, nextAttemptAt: Int64?
    var failure: MailFailure?
    var createdAt: Int64
}
struct SentKey: Hashable, Sendable { var account: String, messageID: String, labelRef: String; var sentSeq: Int64 }
struct LabelBatch: Equatable, Sendable {
    enum Call: Equatable, Sendable { case modifyEach, batchModify, trashEach, untrashEach }
    var account: String
    var messageIDs: [String]
    var add: [String], remove: [String]          // Gmail label ids
    var call: Call
    var keys: [SentKey]
}
struct EchoedIntent: Equatable, Sendable { var account: String, messageID: String, labelID: String; var want: Bool; var recordID: UInt64 }

// Sync
struct ListedID: Equatable, Sendable { var id: String, threadID: String }
struct NewStub: Equatable, Sendable { var gmailID: String, threadID: String; var fetchClass: Int, listRank: Int; var historyID: UInt64 }
struct LabelChange: Equatable, Sendable { var messageID: String; var add: Set<String>, remove: Set<String>; var recordID: UInt64 }
struct StoredMessageState: Equatable, Sendable {
    var msgPK: Int64
    var fetchState: Int, vis: Int
    var labels: Set<String>, labelsKnown: Bool   // Gmail's, without the overlay
    var historyID: UInt64?
}
struct Membership: Hashable, Sendable { var labelID: String?; var messageID: String }      // nil: the unlabelled listing
struct StoredMembership: Equatable, Sendable { var msgPK: Int64; var messageID: String, labelID: String; var historyID: UInt64? }
struct PagePlan: Equatable, Sendable {
    var stubs: [NewStub]
    var addLabel: [String]             // message ids that gain this listing's label now
    var verify: [String]               // message ids something newer has spoken for
    var marks: [Membership]
}
struct QueuedMessage: Equatable, Sendable { var gmailID: String, threadID: String; var fetchClass: Int; var internalDate: Int64 }
enum FetchCall: Equatable, Sendable {
    case message(id: String, format: GmailFormat)
    case thread(id: String, format: GmailFormat, wanted: [String])
}
struct FetchedMessage: Sendable {
    var wire: GmailMessage
    var floor: UInt64                  // 5.6
    var headers: MessageHeaders
    var structure: MIMEStructure?      // nil below `full`
}
enum AccountSyncChange: Sendable {
    case checkpoint(String?), profileTotal(Int), enumeration(generation: Int, checkpoint: String?, state: String?)
    case enumerationCompleted(at: Int64), through(headers: Int64?, bodies: Int64?)
    case quota(String), result(MailSyncHealth, at: Int64), sendAs(String, at: Int64), labelsAt(Int64), removals(String)
}

// Reads and change notices
struct PageRequest: Sendable { var view: MailViewKey; var account: String?; var filters: Set<MailFilter>; var before: MailOrderKey?; var limit: Int }
struct IndexRow: Sendable {            // the page query's columns, decoded by index
    var threadPK: Int64; var account: String, thread: String
    var sortKey: Int64, tie: Int64; var unread: Bool
    var messageCount: Int; var flags: MailThreadFlags
    var subject: String, snippet: String; var people: [SummaryPerson], peopleTotal: Int
    var labelPKs: [Int64]; var wakeAt: Int64?, returnedAt: Int64?, waitingUntil: Int64?; var pending: Int
    /// Display date is independent of a view's sort key (especially Snoozed).
    var lastDate: Int64
    var recipients: [SummaryPerson]
    var recipientsTotal: Int
    var actionBoundary: Int64? = nil
}
struct ViewCounts: Equatable, Sendable { var unread: Int; var total: MailCount; var stillLoading: Int }
struct StoredLabel: Equatable, Sendable { var labelPK: Int64; var account: String, gmailID: String, name: String; var kind: Int; var colorHex: String? }
// MailStoreChange — what one index transaction touched — is declared in M/MailWriter.swift (P02; 18.4).

/// A draft as MIMEBuilder and the send driver see it: the row of 4.8, decoded.
struct StoredDraft: Equatable, Sendable {
    var localID: String, account: String, fromAlias: String?
    var kind: String                   // new, reply, replyAll, forward
    var to: [MailPerson], cc: [MailPerson], bcc: [MailPerson]
    var subject: String
    var body: MailText
    var signature: MailFragment?, quote: MailFragment?
    var format: MailDraft.Format
    var rfcMessageID: String, mimeDate: Date
    var sourceMessageID: String?, threadID: String?, inReplyTo: String?, references: String?
    var contentRev: Int
    var attachments: [StoredDraftAttachment]
}
struct StoredDraftAttachment: Equatable, Sendable {
    var id: String, filename: String, mime: String; var size: Int
    var contentID: String?; var source: String?      // nil: a file in Intent/Attachments; else "forward:<msg>:<part>"
}
/// One change of his, as intent.sqlite keeps it while any of its assertions is undelivered (4.8).
struct StoredChangeGroup: Equatable, Sendable {
    var groupSeq: Int64; var account: String; var change: MailChange; var conversations: Int; var createdAt: Int64
}

#endif
