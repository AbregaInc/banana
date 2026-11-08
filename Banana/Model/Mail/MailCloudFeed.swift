#if !BANANA_PUBLIC
import Foundation

/// One page of Banana Cloud's shared mailbox feed (MAIL-CLOUD-SYNC §4). Each entry is a message's
/// latest state as the cloud has it — its label set exact, `history` the Gmail position that set
/// reflects — or a deletion Gmail stated. Each message appears once, at its newest state.
struct MailCloudFeedPage: Decodable, Equatable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        var id: String
        var thread: String?
        var history: String
        var date: Int64?
        var labels: [String]?
        var deleted: Bool?
        /// The cloud holds this message's content: pull it (`contents`) rather than read Gmail.
        var content: Bool? = nil
    }
    var epoch: String
    var cursor: String
    var more: Bool
    var complete: Bool
    var entries: [Entry]
}

enum MailCloudFeedError: Error, Equatable, Sendable {
    /// The service has no feed for this account (one not yet upgraded): the Gmail path stays.
    case unavailable
    /// The cursor is older than what the feed keeps: start again from zero.
    case expired
}

/// One message's answer in a bulk content pull (MAIL-CLOUD-SYNC §5a).
enum MailCloudContent: Equatable, Sendable {
    /// Gmail's `full` message as the cloud stored it, with the cloud's labels and position.
    case message(GmailMessage)
    /// Not stored in the cloud (yet): read it one by one, or wait for the feed to say it is.
    case missing(String)
    /// Gmail deleted it; the deletion arrives through the feed.
    case gone(String)
    /// The answer was full: ask again.
    case later(String)

    var id: String {
        switch self {
        case .message(let m): return m.id ?? ""
        case .missing(let id), .gone(let id), .later(let id): return id
        }
    }
}

/// The feed and the catch-up check, one request each. Retries and state belong above this.
protocol MailCloudFeedSource: Sendable {
    func page(account: String, after: String?, limit: Int, fresh: Bool) async throws -> MailCloudFeedPage
    /// Names ids this device holds that the feed never did; the answers arrive through the feed.
    func check(account: String, ids: [String]) async throws
    /// Many messages' stored content at once (at most `MailCloudPull.batch`). Asks Google nothing.
    func contents(account: String, ids: [String]) async throws -> [MailCloudContent]
}

extension MailCloudFeedSource {
    /// A source without bulk content (an older service): everything comes the per-message way.
    func contents(account: String, ids: [String]) async throws -> [MailCloudContent] { throw MailCloudFeedError.unavailable }
}

#endif
