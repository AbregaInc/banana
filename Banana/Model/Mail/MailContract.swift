#if !BANANA_PUBLIC
// The one contract between mail's screens and mail's engine: docs/design/MAIL-ENGINE.md,
// section 13, whose two Swift blocks are this file's text and are kept identical to it.
//
// Every type a view or a UI model may name is declared here, with the one protocol they call.
// Two things implement that protocol — the engine, and an in-memory source built from the same
// fixture mailbox — and both must pass the same tests. That is why there is one file: a screen
// built against it has met everything it will ever meet, and there is no adapter to write the
// day the real engine arrives.
//
// The rules of the file. It imports Foundation and Combine and nothing else. It names nothing
// declared outside itself, so it compiles alone (`swiftc -typecheck` on this one file is part
// of its acceptance). It holds no rule's body: `MailRowRules.apply` and `MailLinkRules.decide`
// are added by extension in files of their own. And it changes only together with the
// contract suite, in one commit.
import Foundation
import Combine

// MARK: - Identity

/// A conversation, named the way it is named everywhere outside one device's store: by the
/// account's address and Gmail's thread id. Never a local row id — those are renumbered when a
/// cache is rebuilt, and this value is kept in `ShellState`.
struct MailConversationID: Hashable, Codable, Sendable {
    /// The account's address, lower-cased.
    let account: String
    /// Gmail's thread id, or `"local:<draft id>"` for a new message that has not been sent yet
    /// and so has no thread.
    let thread: String

    /// One string for `ShellState` and for accessibility identifiers.
    var text: String { account + "|" + thread }

    /// Gmail's own web address for the conversation: "Open in Gmail" and "Copy link". Nil for a
    /// thread that exists only on this device.
    var gmailURL: URL? {
        guard !thread.hasPrefix("local:"),
              let who = account.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://mail.google.com/mail/u/\(who)/#all/\(thread)")
    }
}

extension MailConversationID {
    /// The way back from `text`. It splits at the **last** bar: an address may hold one, and a
    /// thread id cannot. Nil when either half is missing. (In an extension so that the struct
    /// keeps its memberwise initialiser.)
    init?(text: String) {
        guard let bar = text.lastIndex(of: "|") else { return nil }
        let account = String(text[..<bar])
        let thread = String(text[text.index(after: bar)...])
        guard !account.isEmpty, !thread.isEmpty else { return nil }
        self.init(account: account, thread: thread)
    }
}

struct MailMessageID: Hashable, Codable, Sendable {
    let account: String
    let message: String
}

/// The device's own id for a draft, stable for the draft's life. Gmail's draft and message ids
/// change on every save and never reach the UI.
struct MailDraftID: Hashable, Codable, Sendable {
    let raw: String
}

/// A message and a part. Never Gmail's `attachmentId`, which is not stable between reads.
struct MailAttachmentID: Hashable, Codable, Sendable {
    let message: MailMessageID
    let part: String
}

/// Where a row stands in its list.
///
/// **A list is its rows in descending key order, in every place.** The engine chooses what the
/// key means there — the newest message carrying the label; the time a snooze ends, reversed;
/// a search's match — so the UI compares and stores keys and never builds or interprets one.
/// It contains nothing local to one device's store.
struct MailOrderKey: Hashable, Comparable, Codable, Sendable {
    /// 0, or 1 for rows only Gmail found in a search: they sort after everything this device
    /// found itself.
    let group: Int
    let sortKey: Int64
    /// A stable hash of the conversation id, so two rows with one `sortKey` still have an order
    /// that is the same on every device.
    let tie: Int64

    static func < (a: MailOrderKey, b: MailOrderKey) -> Bool {
        (-a.group, a.sortKey, a.tie) < (-b.group, b.sortKey, b.tie)
    }
}

// MARK: - Scope

/// This device's retained history. Older mail stays in Gmail and remains searchable.
enum MailSyncLimit: String, Codable, CaseIterable, Sendable {
    case oneMonth, threeMonths, sixMonths, oneYear, everything
    static let standard = MailSyncLimit.sixMonths
}

enum MailMailbox: String, Codable, CaseIterable, Sendable {
    case inbox, starred, important, drafts, snoozed, sent, outbox, done, all, spam, trash, muted
}

enum MailPlace: Hashable, Codable, Sendable {
    /// One of the built-in three (`MailSplit.importantID`, `.calendarID`, `.otherID`), or a
    /// custom split's id.
    case split(String)
    case mailbox(MailMailbox)
    case label(account: String, id: String)
    /// Text in the query grammar (MAIL-ENGINE 9.1).
    case search(String)
    /// The conversations Gmail says were deleted, held until he has answered (5.7).
    case heldRemoval(account: String)
}

enum MailFilter: String, Codable, Sendable {
    case unread, starred, important, noReply
}

struct MailScope: Hashable, Codable, Sendable {
    var place: MailPlace
    var filters: Set<MailFilter> = []
    /// Narrowed to one account; nil is every account. A place that names its own account
    /// (`.label`, `.heldRemoval`) is that account's whatever this says: the place wins.
    var account: String? = nil
    /// Exclusive keyset boundary for an older browsing window. Retained history
    /// remains on disk; this is not an additional Gmail search term.
    var before: MailOrderKey? = nil
}

/// A count that says when it cannot be vouched for: `isAtLeast` while a scan stopped early or a
/// listing is incomplete, or Gmail has more in this place than the device holds.
/// "40+" is drawn from this, never guessed.
struct MailCount: Equatable, Codable, Sendable {
    var value: Int
    var isAtLeast: Bool
}

// MARK: - Text

/// Text the engine hands to the screens and takes back from the composer: meaning, no fonts.
/// The UI maps it to attributed text with its own type styles, in one place — so no screen
/// ever parses a message's HTML, and no HTML-to-attributed-string conversion exists anywhere.
struct MailText: Equatable, Codable, Sendable {
    var blocks: [MailTextBlock]
}

struct MailTextBlock: Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case paragraph
        case quote(depth: Int)
        case item(ordered: Bool, depth: Int, number: Int?)
        case heading(level: Int)
        case preformatted
        case rule
    }
    var kind: Kind
    var runs: [MailTextRun]
}

struct MailTextRun: Equatable, Codable, Sendable {
    var text: String
    var style: MailTextStyle = []
    /// `http`, `https` or `mailto` only — and opened only through `MailLinkRules` (10.7).
    var link: URL?
}

struct MailTextStyle: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let bold = MailTextStyle(rawValue: 1)
    static let italic = MailTextStyle(rawValue: 2)
    static let underline = MailTextStyle(rawValue: 4)
    static let strikethrough = MailTextStyle(rawValue: 8)
    static let code = MailTextStyle(rawValue: 16)
}

/// HTML that has been through the sanitiser. Only the engine makes one; the UI stores it and
/// hands it back untouched, and never reads what is inside.
struct MailFragment: Equatable, Codable, Sendable {
    let html: String
}

// MARK: - Rows

struct MailPerson: Hashable, Codable, Sendable {
    /// Cleaned of invisible and direction characters; nil when the address must be shown
    /// instead, because the name itself looks like an address or a link (10.8).
    var name: String?
    /// A non-ASCII domain arrives in its `xn--` form.
    var address: String
    var isMe: Bool
    /// He has written to this address.
    var isKnown: Bool
    /// Set only by `people(matching:)`: known from mail he received and never written to, so it
    /// is offered last, by address, and marked.
    var fromTheirMail: Bool
}

struct MailLabelRef: Hashable, Codable, Sendable {
    /// Gmail's id, or `"local:<name>"` until Gmail has made the label. Both stay valid in every
    /// call for the life of the process.
    ///
    /// **An id is one account's.** Gmail numbers a person's labels per mailbox (`Label_12`), so
    /// the same id names a different label in another account. Whatever takes a label id
    /// therefore takes its account beside it: a place, a change, a suggestion. A ref on a row
    /// or a conversation is of that conversation's account.
    var id: String
    var name: String
    var colorHex: String?
}

/// Why something did not happen. A closed list — never Google's words, which echo what was
/// sent and so may carry an address or a subject into a log (invariant 21).
enum MailFailure: String, Codable, Sendable {
    case tooLarge, addressRejected, signedOut, accessMissing, notAllowedByAdmin
    case labelMissing, limitReached, internalError, other
}

/// The one line under a row's subject, when there is something to say. At most one per row; the
/// cases are in the order they outrank each other.
enum MailRowReason: Equatable, Codable, Sendable {
    /// A question about it is open. The kind is carried so the row alone says which line to
    /// draw: equal rows must make equal displays.
    case asking(MailQuestion.ID, MailQuestion.Kind)
    case failedToSend(MailFailure)
    /// A change to it was refused for good (6.9).
    case changeRefused(MailFailure)
    /// Sent, and still inside the undo hold: "Sending…" with Undo.
    case held(until: Date)
    case waitingToSend, sending, checkingSent
    case scheduled(Date, onThisDevice: Bool, isLate: Bool)
    case draft(firstLine: String)
    case backFromSnooze(due: Date, wasIfNoReply: Bool)
    case snoozed(until: Date, ifNoReply: Bool)
    /// Gmail no longer has it; it is kept on this device by his choice (5.7).
    case keptAfterRemoval
}

struct MailRow: Identifiable, Equatable, Codable, Sendable {
    let id: MailConversationID
    var key: MailOrderKey
    /// The date the row shows. Not the key: where a row sorts and what date it shows differ in
    /// Snoozed and for a conversation back from a snooze.
    var date: Date
    /// Authors in order of first appearance, at most six — recipients instead, in Sent, Drafts
    /// and Outbox.
    var people: [MailPerson]
    var peopleTotal: Int
    var messageCount: Int
    /// As sent, cleaned (10.8). The UI removes "Re:" and "Fwd:".
    var subject: String
    /// Gmail's own; in a search, the excerpt around the match.
    var snippet: String
    var isUnread, isStarred, isImportant, hasAttachment, isInvitation, inInbox, isMuted: Bool
    /// Something about it has not reached Gmail yet.
    var hasPendingChange: Bool
    /// Found by Gmail, not by this device: a search match or a place's older mail.
    var fromGmailSearch: Bool
    /// His own labels only.
    var labels: [MailLabelRef]
    var reason: MailRowReason?
    /// False for a Gmail-only result. Opening fetches its conversation before it can change.
    var isOnDevice: Bool = true
    /// Opaque engine snapshot boundary for actions; nil for fixtures/older cached rows.
    var actionBoundary: Int64? = nil
}

struct MailListSnapshot: Equatable, Codable, Sendable {
    var scope: MailScope
    /// The first `limit` rows, in order.
    var rows: [MailRow]
    var total: MailCount
    var hasMore: Bool
    /// Conversations known to belong here whose first message has not arrived yet. An empty
    /// `rows` with this above zero is "still loading", not "nothing here".
    var stillLoading: Int
    /// A split whose membership is being recomputed.
    var isRebuilding: Bool
    /// Any list: nil when Gmail was not asked.
    var remote: MailRemoteSearch?
    /// A search: how much of the mailbox this device could look through.
    var coverage: MailCoverage?
    /// Every command with a sequence up to this is in the rows.
    var appliedThrough: UInt64
    /// This list holds mail since then; older mail may be in Gmail. Nil: the list is whole.
    var heldSince: Date? = nil
}

enum MailRemoteSearch: Equatable, Codable, Sendable {
    case pending, failed, offline, done(added: Int, more: Bool)
}

struct MailCoverage: Equatable, Codable, Sendable {
    var searched: Int
    var of: Int
}

// MARK: - A conversation

/// What kind of body a message has, without the body: the conversation carries this for every
/// message, and the body itself is asked for only when a message is opened.
enum MailBodyState: String, Codable, Sendable {
    case notOnDevice, preparing, text, designed, tooLarge
}

enum MailBodyNotice: String, Codable, Sendable {
    case tooLarge, truncated, shownAsText
}

struct MailPictureBox: Equatable, Sendable {
    var key: String
    var width: Int?
    var height: Int?
}

enum MailPictureGrant: String, Codable, Sendable {
    case sender, domain, everyone
}

enum MailPictureRule: Hashable, Codable, Sendable {
    case sender(String), domain(String), everyone
}

struct MailPictures: Equatable, Sendable {
    /// Every remote picture with the size its sender declared, so the layout does not jump
    /// when pictures arrive.
    var boxes: [MailPictureBox]
    /// Not shown yet.
    var waiting: Int
    /// Held back; zero when tracker blocking is off.
    var trackersRemoved: Int
    /// Sender/domain are offered only when Gmail vouched for the sender; none in Spam.
    var offers: [MailPictureGrant] = []
    var sender: String? = nil
    var domain: String? = nil
    /// The persistent rule showing these pictures, for its matching undo control.
    var shownBy: MailPictureRule? = nil
}

/// A body, ready-made: decided and prepared when the message was fetched, so opening is a read.
/// From `MailSource.body(_:)`, not carried in `MailMessage`.
enum MailBody: Equatable, Sendable {
    case notOnDevice
    case text(MailText, quoteStartsAt: Int?, notices: [MailBodyNotice])
    /// `document` is a whole HTML document for one web view (10.5). It holds no script and no
    /// reachable remote reference; its pictures come only from `MailSource.resource`.
    case designed(document: String, pictures: MailPictures, hasQuote: Bool,
                  plain: MailText, notices: [MailBodyNotice])
}

/// Whether what asks for a picture is in front of him. A picture is never fetched from its
/// sender for a message that is only being made ready (invariant 30).
enum MailPresentation: Sendable {
    case onScreen, warming
}

struct MailResource: Equatable, Sendable {
    var data: Data
    var mimeType: String
}

enum MailDelivery: Equatable, Sendable {
    case held(until: Date), waitingForNetwork, scheduled(Date), sending, checking
    case failed(MailFailure), asking(MailQuestion.ID, MailQuestion.Kind), sentLate(due: Date)
}

struct MailAttachment: Identifiable, Equatable, Sendable {
    let id: MailAttachmentID
    /// Safe to show and to save under (10.8).
    var name: String
    /// What the bytes are, once they are known; what the sender said until then.
    var mimeType: String
    /// The bytes are not what the sender said they were: show a generic icon.
    var typeMismatch: Bool
    var bytes: Int
    /// Non-nil when it is on this device.
    var localFile: URL?
    var isInline: Bool
    var isExecutable: Bool
}

struct MailMessage: Identifiable, Equatable, Sendable {
    let id: MailMessageID
    var from: MailPerson
    var to, cc, bcc, replyTo: [MailPerson]
    /// Which of his addresses received it.
    var deliveredTo: String?
    var listName: String?
    var date: Date
    var isUnread, isMine: Bool
    /// The folded row.
    var firstLine: String
    var body: MailBodyState
    var attachments: [MailAttachment]
    /// His own message, still in the outbox or sent late. Nil once it has simply been sent.
    var delivery: MailDelivery?
    /// Set while it can be reopened.
    var draft: MailDraftID?
}

struct MailInvite: Equatable, Sendable {
    enum Method: String, Sendable {
        case request, cancel, reply, other
    }
    var method: Method
    /// The event is found by the calendar's own lookup of this id — never read from the
    /// sender's file.
    var uid: String
}

enum MailUnsubscribe: Equatable, Sendable {
    case oneClick(host: String), openPage(URL), compose(to: String, subject: String?)
}

struct MailConversation: Equatable, Sendable {
    let id: MailConversationID
    var subject: String
    var labels: [MailLabelRef]
    var inInbox, isStarred, isImportant, isMuted: Bool
    var snoozedUntil: Date?
    /// `.trash` or `.spam` when it is there.
    var system: MailMailbox?
    /// Oldest first; his unsent ones last.
    var messages: [MailMessage]
    var invite: MailInvite?
    var unsubscribe: MailUnsubscribe?
    /// An unsent reply attached to this conversation.
    var draft: MailDraftID?
    var newestIsMine: Bool
    var appliedThrough: UInt64
}

// MARK: - Writing

struct MailIdentity: Hashable, Codable, Sendable {
    var account: String
    var address: String
    var name: String?
    var isDefault: Bool
    /// The signature itself arrives on the draft, in a form that can be drawn.
    var hasSignature: Bool
}

/// A draft's signature or quote: the fragment that is stored and sent, and a way to draw it.
/// `body` is one of the two forms a message's body has (never `.notOnDevice`), prepared by the
/// engine; the UI draws it as it draws a message and hands `fragment` back untouched.
struct MailDraftPart: Equatable, Sendable {
    let fragment: MailFragment
    var body: MailBody
}

struct MailDraftAttachment: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var name: String
    var bytes: Int
    /// Nil for a forwarded attachment that has not been downloaded yet.
    var file: URL?
    var isExecutable: Bool
}

enum MailDraftKind: Equatable, Sendable {
    case new(account: String?)
    case reply(to: MailMessageID), replyAll(to: MailMessageID), forward(MailMessageID)
    /// From a `mailto:` link: To and Subject, and nothing else a link might ask for.
    case toAddress([String], subject: String?)
}

struct MailSchedule: Equatable, Codable, Sendable {
    var at: Date
    var onThisDevice: Bool
    var isLate: Bool
}

struct MailDraft: Identifiable, Equatable, Sendable {
    /// `banana`: written here, as text. `foreign`: written elsewhere in a form the text editor
    /// cannot hold; shown and sendable as it is (7.1).
    enum Format: String, Codable, Sendable {
        case banana, foreign
    }
    let id: MailDraftID
    var conversation: MailConversationID
    var account: String
    var isReply: Bool
    var isForward: Bool
    var from: MailIdentity
    var to, cc, bcc: [MailPerson]
    var subject: String
    var body: MailText
    /// Set nil to send without it.
    var signature: MailDraftPart?
    /// Set nil to remove it; `quoteAsText(in:)` to edit it.
    var quote: MailDraftPart?
    var attachments: [MailDraftAttachment]
    var format: Format
    var schedule: MailSchedule?
    var remindIfNoReply: Date?
    /// Nil while it is simply a draft.
    var delivery: MailDelivery?
    /// What it would weigh as sent. The limit is `MailTuning.maxEncodedBytes`.
    var encodedBytes: Int
    var editedAt: Date
}

// MARK: - Accounts and places

/// What is true of one account's mail on this device (the rules are MAIL-ENGINE 3.4).
enum MailAccountState: Equatable, Sendable {
    /// Mail is not turned on for this account.
    case off
    /// Turned on, but this device has not opened Mail yet: nothing has been fetched.
    case waitingForFirstOpen
    /// Turned on, but this device cannot reach its mail.
    case needsAccess(MailAccessGap)
    /// Usable. How sync is going is `MailSyncHealth`.
    case connected
}

enum MailAccessGap: Equatable, Sendable {
    /// Never allowed on this device.
    case notAllowedHere
    /// Google refused the stored credential, or the scope.
    case withdrawn
}

enum MailSyncHealth: Equatable, Codable, Sendable {
    case live, offline, firstSync, catchingUp
    case limited(until: Date), bytesSpent(until: Date)
    /// Gmail's history ran out: the cache is being compared with Gmail. Nothing disappears
    /// while it is.
    case checking
    case apiDisabled, notAllowedByAdmin, wrongAccount
}

struct MailAccount: Identifiable, Equatable, Sendable {
    /// The address, lower-cased.
    var id: String
    var shortName: String
    /// The synced choice.
    var wantsMail: Bool
    /// What is true on this device.
    var state: MailAccountState
    /// Meaningful when `state == .connected`.
    var health: MailSyncHealth
    var lastSyncAt: Date?
    var identities: [MailIdentity]
    /// Messages he kept though Gmail says they are gone (5.7). Above zero, Settings offers to
    /// remove them.
    var keptAfterRemoval: Int
}

struct MailSplit: Identifiable, Equatable, Codable, Sendable {
    /// The ids of the built-in three. A custom split's id is never one of them.
    static let importantID = "important"
    static let calendarID = "calendar"
    static let otherID = "other"

    var id: String
    var name: String
    /// Nil for the built-in three, which are the engine's rules. Fields and flags only (9.3).
    var query: String?
}

struct MailLabelNode: Identifiable, Equatable, Sendable {
    /// Unique among every account's labels — `"<account>|<label id>"` — so that two accounts'
    /// trees can be drawn in one list. The id a change or a place takes is `ref.id`.
    var id: String
    var ref: MailLabelRef
    var children: [MailLabelNode]
}

/// Two counts for one place. `total` is conversations, read or not — what is left to triage.
/// `total.isAtLeast` while it cannot be vouched for: the inbox still holds conversations whose
/// first message has not arrived (a conversation cannot be put in a split before then), the
/// split is being rebuilt, or the count stopped at 10,000.
struct MailPlaceCount: Equatable, Sendable {
    /// Counts are lower bounds when Gmail holds more in this place than the device does.
    var unread: MailCount
    var total: MailCount
}

struct MailPlaces: Equatable, Sendable {
    /// In the order shown; "other" last.
    var splits: [MailSplit]
    var splitCounts: [String: MailPlaceCount]
    var mailboxCounts: [MailMailbox: MailPlaceCount]
    var outboxNeedsAnswer: Bool
    /// By account. Banana's own labels are never listed.
    var labels: [String: [MailLabelNode]]
    /// Keyed by MailLabelNode.id; count changes do not replace the label tree.
    var labelCounts: [String: MailPlaceCount] = [:]
}

// MARK: - Status

/// What is holding a download up, when something is.
enum MailHold: String, Codable, Sendable {
    case limitedByGoogle, bytesSpentToday, onBattery, deviceWarm, lowPowerMode
    case diskNearlyFull, waitingForWiFi, mailNotOnScreen
}

struct MailDownload: Equatable, Sendable {
    var account: String
    /// Every message since then has its text here.
    var backTo: Date?
    var messagesHere, messagesAbout: Int
    var notYetSearchable: Int
    var secondsLeft: TimeInterval?
    var heldBy: MailHold?
    /// Messages on or after this edge are retained; nil means everything.
    /// The two message counts describe mail inside this limit.
    var limitEdge: Date? = nil
}

enum MailCheck: Equatable, Sendable {
    case running, finished(new: Int, at: Date)
}

enum MailStoreProblem: String, Codable, Sendable {
    case diskFull, damaged, newerVersion, unavailable
}

enum MailStoreState: Equatable, Sendable {
    case notOpened, ready, rebuilding
    /// Reading works; changes are refused, and say so.
    case cannotSave(MailStoreProblem)
    case unavailable(MailStoreProblem)
}

/// A change Gmail will never accept (6.9): what to draw for it, and the receipt `retry` and
/// `discard` take. Listed in the status value rather than announced once, so it is still there
/// after a relaunch.
struct MailRefusedChange: Identifiable, Equatable, Sendable {
    let receipt: MailReceipt
    var change: MailChange
    /// Conversations.
    var count: Int
    var failure: MailFailure
    var account: String
    var isUndo: Bool = false

    var id: UInt64 { receipt.sequence }
}

struct MailStatusValue: Equatable, Sendable {
    var isOnline: Bool
    var lastChecked: Date?
    /// Online, and Gmail has not answered since then.
    var unreachableSince: Date?
    /// Google is limiting requests.
    var slowedSince: Date?
    /// A check he asked for.
    var asked: MailCheck?
    /// Changes not yet at Gmail that have waited longer than the delivery debounce's five
    /// seconds, or any at all while offline. So ten quick changes online move nothing here.
    var waitingChanges: Int
    var waitingSince: Date?
    var waitingMessages: Int
    /// One per action.
    var refused: [MailRefusedChange]
    var downloads: [MailDownload]
    var store: MailStoreState
    var questions: [MailQuestion]
    var refusedHasMore: Bool = false
}

/// The tab's two numbers. `needsAnswer` is open questions about a send **plus sends that failed
/// for good** — every message of his that did not go and will not go by itself.
struct MailBadgeCounts: Equatable, Codable, Sendable {
    var unreadInFirstSplit: Int
    var needsAnswer: Int

    /// The launch-time mirror (12.4): two integers in `UserDefaults`, written by the engine and
    /// readable by anyone before any store is open. The key and the stored form are here, in
    /// the contract, so the screen that draws the badge can be built before the engine that
    /// writes it. An array of integers, not JSON: nothing of mail's is decoded at launch.
    static let mirrorKey = "mailBadge"

    static func mirrored(in defaults: UserDefaults) -> MailBadgeCounts? {
        guard let pair = defaults.array(forKey: mirrorKey) as? [Int], pair.count == 2 else {
            return nil
        }
        return MailBadgeCounts(unreadInFirstSplit: pair[0], needsAnswer: pair[1])
    }

    func mirror(to defaults: UserDefaults) {
        defaults.set([unreadInFirstSplit, needsAnswer], forKey: MailBadgeCounts.mirrorKey)
    }
}

struct MailStorage: Equatable, Sendable {
    var bodies, attachments, search, index: Int64
}

/// What an `observe…` call hands back. Letting go of it stops the observation; so does
/// `cancel()`, which may be called more than once and from any thread. The closure it was made
/// with runs once, on whichever thread cancels or lets go — so it must not assume the main one.
final class MailObservation: @unchecked Sendable {
    /// Guards `onCancel`: an observation is handed between threads (the engine's own are), and
    /// two cancels arriving together must still stop it once.
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        let stop = onCancel
        onCancel = nil
        lock.unlock()
        stop?()
    }

    deinit { onCancel?() }
}

/// Status is a leaf: the status line, the foot card and the alert cards observe it, and no
/// shell, tab bar or list container does. It changes at the rate of meaning, never per message.
@MainActor final class MailStatus: ObservableObject {
    @Published var value: MailStatusValue
    init(_ value: MailStatusValue) { self.value = value }
}

/// A leaf, like `MailStatus`. Changes only when a number moves.
@MainActor final class MailBadges: ObservableObject {
    @Published var value: MailBadgeCounts
    init(_ value: MailBadgeCounts) { self.value = value }
}

/// A leaf: one attachment's download, 0 to 1.
@MainActor final class MailProgress: ObservableObject {
    @Published var fraction: Double = 0
    init() {}
}

enum MailSuggestion: Equatable, Sendable {
    case from(MailPerson), to(MailPerson), label(MailLabelRef, account: String), split(MailSplit)
}

enum MailPermissionResult: Equatable, Sendable {
    case granted, notGranted, cancelled, differentAccount, noWindow, failed
}

enum MailUnsubscribeResult: Equatable, Sendable {
    /// A 2xx from the list's server. "Asked", not "unsubscribed": nothing proves the second.
    case asked(host: String)
    case failed, unavailable
}

// MARK: - Commands

enum MailChange: Equatable, Codable, Sendable {
    case done, notDone, trash, restore, spam, notSpam
    case read(Bool), star(Bool), important(Bool), mute(Bool)
    /// Label ids, and the account they are ids in (see `MailLabelRef.id`). The change applies
    /// to the target's conversations **in that account**; any others in the target are
    /// untouched and not counted. One receipt, one undo.
    case label(account: String, add: [String], remove: [String])
    /// Add `to`; leave the inbox, and `from` when the list being looked at is a label's. The
    /// ids are `account`'s, and it applies as `label` does.
    case move(account: String, to: String, from: String?)
    case snooze(until: Date, ifNoReply: Bool), unsnooze
}

struct MailActionReading: Equatable, Sendable {
    let id: MailConversationID
    let asOf: Int64
    let arrivalSequence: Int64
}

enum MailTarget: Equatable, Sendable {
    /// The actual row the UI acted on, even if a newer source snapshot is waiting.
    case reading([MailActionReading])
    /// As of what the newest reading of each showed: a reply that arrives after the key press
    /// is not swept up in the change (6.1).
    case conversations([MailConversationID])
    /// As of that message — a notification's action.
    case message(MailMessageID)
    /// Every conversation in the scope at or after that key, on screen or not.
    case scope(MailScope, from: MailOrderKey?)
}

extension MailTarget {
    static func asShown(_ rows: [MailRow]) -> MailTarget {
        guard !rows.isEmpty, rows.allSatisfy({ $0.actionBoundary != nil }) else {
            return .conversations(rows.map(\.id))
        }
        return .reading(rows.map {
            MailActionReading(id: $0.id, asOf: Int64(($0.date.timeIntervalSince1970 * 1000).rounded()),
                              arrivalSequence: $0.actionBoundary!)
        })
    }
}

/// What a command returns at once.
///
/// `sequence` only grows, and no command is ever given 0: a receipt with `sequence` 0 is the
/// receipt of nothing, which is what a member no source has built returns. `count` is how many
/// conversations the command changed — nil for a `.scope` target until the engine has counted
/// (`MailEvent.applied` follows), and 0 when it changed nothing, in which case a screen shows
/// nothing and offers no undo.
///
/// **A receipt is its sequence.** Two receipts with one sequence are equal whatever their
/// counts. So the receipt a screen kept before the count was known still equals — and, as a
/// dictionary key, still finds — the one that comes back in an event with the count filled in.
struct MailReceipt: Hashable, Sendable {
    let sequence: UInt64
    let count: Int?

    static func == (a: MailReceipt, b: MailReceipt) -> Bool {
        a.sequence == b.sequence
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sequence)
    }
}

struct MailSendOptions: Equatable, Sendable {
    /// The undo hold. Nil: the hold he chose in Settings. 0: Send now.
    var hold: TimeInterval?
    /// Send and Done: one receipt covers both.
    var thenDone: Bool
    /// Send later: nil is now, after the hold. The schedule a draft then carries is
    /// `MailDraft.schedule`, set by the engine (13.10).
    var at: Date? = nil
}

// MARK: - Questions: things only he can decide

struct MailQuestion: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Codable, Sendable {
        let raw: String
    }
    enum Kind: Equatable, Codable, Sendable {
        /// Gmail says many messages were deleted; they are held, not removed (5.7).
        case removalHeld(account: String, count: Int)
        /// A send whose result is unknown and cannot be found in Sent (7.4).
        case sendUnconfirmed(MailDraftID, draftStillInGmail: Bool?)
        /// A message he sent long ago that had not gone (7.4).
        case sendLate(MailDraftID, since: Date)
        case draftChangedElsewhere(MailDraftID)
        case scheduleChangedElsewhere(MailDraftID)
        case scheduleOwnedElsewhere(MailDraftID)
        /// Changes that had not reached Gmail could not all be read back (4.10).
        case changesLost(recovered: Int)
    }
    let id: ID
    var kind: Kind
    /// The ones that apply, in the order to offer them.
    var choices: [MailChoice]
}

enum MailChoice: String, Codable, Sendable {
    /// `removalHeld`.
    case remove, keepHere
    /// `sendUnconfirmed`.
    case checkAgain, sendAgain, keepAsDraft
    /// `sendLate`, with `keepAsDraft`.
    case sendNow
    /// `draftChangedElsewhere`.
    case keepMine, useOther
    /// The two schedule questions.
    case sendFromHere, cancelSchedule
    /// `changesLost`.
    case acknowledge
}

// MARK: - What the engine says unasked

/// Events carry ids and closed enums — never a subject, an address or Google's words. The UI
/// looks up what it needs to say, and may show it; neither side may log it.
enum MailEvent: Equatable, Sendable {
    /// A `.scope` target has been counted.
    case applied(MailReceipt, count: Int)
    /// The change could not be saved: it was put back on screen, and nothing was sent.
    case notSaved(MailReceipt, MailStoreProblem)
    /// What he is typing is in memory only, until a save succeeds.
    case draftNotSaved(MailDraftID, MailStoreProblem)
    /// Gmail refused it for good; it is shown as not done.
    case refused(MailReceipt, MailFailure)
    /// Undo arrived after the message had left.
    case sendGone(MailReceipt)
    case sent(MailDraftID, MailConversationID)
    case sentLate(MailDraftID, due: Date, sent: Date)
    case sendFailed(MailDraftID, MailFailure)
    case asked(MailQuestion)
    /// A question answered itself, or was answered elsewhere.
    case settled(MailQuestion.ID)
}

// MARK: - Pure rules the screens share with the engine

struct MailQueryToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case word, phrase, operatorName(String), value, negation, unknownOperator
    }
    /// In UTF-16 units of the typed text.
    var range: Range<Int>
    var kind: Kind
}

/// What a change does to one row of one list, decided from the row and the scope alone — which
/// is what lets a change show in the same turn as the key press, with nothing read.
///
/// `MailRowRules.apply(_:to:in:) -> Outcome` is added by extension in MailRowRules.swift.
enum MailRowRules {
    enum Outcome: Equatable, Sendable {
        /// The row as changed.
        case stays(MailRow)
        /// It no longer belongs here. The row as changed is carried for a list that keeps
        /// showing it until the place is next entered.
        case leaves(MailRow)
        /// Whether it still belongs is not known here. Draw the row as changed, where it is,
        /// and let the next reading decide.
        case unknown(MailRow)
    }
}

enum MailLinkWarning: String, Codable, Sendable {
    case goesElsewhere, lookalikeHost, pictureLink
}

/// What to do with a tapped link (10.7). The only way a link in mail is ever opened.
enum MailLinkDecision: Equatable, Sendable {
    case refuse
    case open(URL)
    case openAfterWarning(URL, MailLinkWarning)
    case compose(to: [String], subject: String?)
}

/// `MailLinkRules.decide(url:shownText:shownIsImage:) -> MailLinkDecision` is added by extension
/// in MailLinkRules.swift, with the HTML packages. Until then nothing can call it, and
/// `decideLink` answers `.refuse`.
enum MailLinkRules {}

// MARK: - The protocol

/// Everything a screen may ask of mail. Every requirement has a default in
/// MailSource+NotYet.swift, so a source builds a member by declaring it and holds no stubs.
@MainActor protocol MailSource: AnyObject {

    // MARK: Life

    /// The first Mail screen calls this. At most 1 ms on the main actor; returns at once.
    func activate()
    /// Whether a Mail screen is in front. Drives polling (12.1); nothing else reads it.
    func setVisible(_ visible: Bool)

    // MARK: Reads

    var accounts: [MailAccount] { get }
    /// This device's history policy, independent of the provider's retained mail.
    var syncLimit: MailSyncLimit { get }
    /// Returns at once: raising fetches more; lowering releases local cached conversations.
    func setSyncLimit(_ limit: MailSyncLimit)
    /// Held conversations this limit would release, for confirmation and progress.
    func conversationsBeyond(_ limit: MailSyncLimit) async -> Int
    func observeAccounts(_ onChange: @escaping @MainActor ([MailAccount]) -> Void) -> MailObservation
    func observePlaces(_ onChange: @escaping @MainActor (MailPlaces) -> Void) -> MailObservation
    /// The one synchronous read. Up to `MailTuning.firstPageRows` rows of the scope last shown,
    /// or nil. It never touches a database.
    func cachedFirstPage(_ scope: MailScope) -> MailListSnapshot?
    /// The first `limit` rows of a scope, kept current. To show more, observe again with a
    /// larger limit (`listStep` more each time, up to `listCap`); the new observation's first
    /// value arrives before the old one is let go.
    func observeList(_ scope: MailScope, limit: Int,
                     _ onChange: @escaping @MainActor (MailListSnapshot) -> Void) -> MailObservation
    /// One conversation, kept current. `nil` means this device holds no such conversation now:
    /// it was never fetched, or it has been removed. It never means "not read yet" — nothing is
    /// delivered before the first reading is done — and the observation stays live, so a
    /// conversation that arrives later is delivered then.
    func observeConversation(
        _ id: MailConversationID,
        _ onChange: @escaping @MainActor (MailConversation?) -> Void
    ) -> MailObservation
    /// One reading of it; `nil` as for `observeConversation`.
    func conversation(_ id: MailConversationID) async -> MailConversation?
    /// A message's body, ready-made. Never fetches; `.notOnDevice` when it is not here.
    func body(_ id: MailMessageID) async -> MailBody
    /// A picture a designed body refers to (10.5). Nil: answer 404. Fetches a remote picture
    /// only when `presentation == .onScreen` and the picture rules allow it.
    func resource(_ url: URL, for message: MailMessageID,
                  presentation: MailPresentation) async -> MailResource?
    func suggestions(for text: String) async -> [MailSuggestion]
    func people(matching text: String, limit: Int) async -> [MailPerson]
    /// Pure; for the search field's chips and highlighting. The UI has no tokenizer of its own.
    func queryTokens(_ text: String) -> [MailQueryToken]
    /// A link tapped in a designed body: looks up what was shown for it, then `MailLinkRules`.
    /// (A web view reports only the address, so the mismatch warning needs this lookup.)
    func decideLink(_ url: URL, in message: MailMessageID) async -> MailLinkDecision
    func draft(_ id: MailDraftID) async -> MailDraft?
    var status: MailStatus { get }
    var badges: MailBadges { get }
    func attachmentProgress(_ id: MailAttachmentID) -> MailProgress
    func storageUsed() async -> MailStorage

    // MARK: Changes to conversations

    /// A conversation this device does not hold is not changed; its receipt counts zero.
    @discardableResult func apply(_ change: MailChange, to target: MailTarget) -> MailReceipt
    @discardableResult func undo(_ receipt: MailReceipt) -> MailReceipt
    /// A refused change: try again.
    func retry(_ receipt: MailReceipt)
    /// A refused change: give it up.
    func discard(_ receipt: MailReceipt)

    // MARK: Drafts and sending

    /// A new draft, durable before this returns, addressed by the engine's reply rules.
    func newDraft(_ kind: MailDraftKind) async -> MailDraft
    /// Nothing waits on it.
    func save(_ draft: MailDraft)
    func addAttachment(_ file: URL, to draft: MailDraftID) async -> MailDraftAttachment?
    func removeAttachment(_ id: String, from draft: MailDraftID)
    /// A foreign draft, made editable.
    func rewriteAsText(_ draft: MailDraftID) async -> MailDraft?
    /// "Edit the quote": its text joins `body` as quoted blocks and `quote` becomes nil. Its
    /// design and pictures are lost, and the UI says so before calling.
    func quoteAsText(in draft: MailDraftID) async -> MailDraft?
    /// Send from another of his addresses: `from` and the signature are replaced together.
    func changeIdentity(of draft: MailDraftID, to address: String) async -> MailDraft?
    /// A picture a draft's designed signature or quote refers to; as the other `resource`.
    func resource(_ url: URL, forDraft draft: MailDraftID,
                  presentation: MailPresentation) async -> MailResource?
    /// Undoable.
    @discardableResult func discard(_ draft: MailDraftID) -> MailReceipt
    @discardableResult func send(_ draft: MailDraftID, _ options: MailSendOptions) -> MailReceipt
    /// True: it is a draft again, durably. False: it has left.
    func cancelSend(_ draft: MailDraftID) async -> Bool
    func retrySend(_ draft: MailDraftID)
    /// Whether leaving now would strand a message (the Mac's quit; 7.5).
    var hasUnfinishedSends: Bool { get }
    /// Ends every undo hold and sends. Returns when nothing is left to hand over, or after
    /// `limit`.
    func finishSends(within limit: TimeInterval) async

    // MARK: Questions

    func answer(_ question: MailQuestion.ID, _ choice: MailChoice)

    // MARK: Fetching: hints and requests; none is waited on

    func checkNow()
    /// Ask Gmail for search matches or a place's mail older than the local edge (9.4).
    /// Again requests the next page or retries. Bounded-history searches also ask automatically.
    func askGmail(_ scope: MailScope)
    /// The cursor rests here: have these ready. Never fetches anything from a sender.
    /// A conversation not held here is fetched whole from Gmail and then retained.
    func wants(_ ids: [MailConversationID])
    func fetchBody(_ id: MailMessageID)
    func fetchAttachment(_ id: MailAttachmentID)
    /// Nil means this message only; otherwise the explicit persistent permission chosen.
    func showPictures(in id: MailMessageID, always grant: MailPictureGrant?)
    /// Every persistent picture permission, including everyone, and the way back from each.
    func pictureRules() async -> [MailPictureRule]
    func removePictureRule(_ rule: MailPictureRule)

    // MARK: Accounts, splits, labels

    func setWantsMail(_ on: Bool, account: String)
    /// The one interactive call: Google's consent for this account's mail, on this device.
    func requestPermission(account: String) async -> MailPermissionResult
    /// This device's credential. Revokes nothing at Google.
    func forgetPermission(account: String)
    /// Returns the ids of splits whose query cannot be kept as a view (free text); they are
    /// not saved.
    @discardableResult func saveSplits(_ splits: [MailSplit]) -> [String]
    func createLabel(named name: String, account: String) -> MailLabelRef
    /// After the UI's confirmation, for a `.oneClick` offer only.
    func unsubscribe(_ id: MailConversationID) async -> MailUnsubscribeResult
    func removeDownloadedMail(account: String?) async
    /// Settings' "Remove mail that Gmail no longer has": raises `removalHeld` again for the
    /// messages he kept (`MailAccount.keptAfterRemoval`), to be answered like the first time.
    func reconsiderKeptMail(account: String)

    // MARK: What the engine has to say unasked

    func observeEvents(_ onEvent: @escaping @MainActor (MailEvent) -> Void) -> MailObservation
}

/// Every number a screen and the engine share.
enum MailTuning {
    static let firstPageRows = 50
    static let listStep = 100
    /// Maximum rows in one browsing window, not a retained-history limit.
    static let listCap = 2_000
    static let searchMinimumCharacters = 2
    static let maxOpenDesignedBodies = 6
    /// A message as sent; about 25 MB of attachments.
    static let maxEncodedBytes = 35 * 1_048_576
}

#endif
