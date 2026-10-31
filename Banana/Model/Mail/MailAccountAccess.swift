#if !BANANA_PUBLIC
import Foundation

/// What the engine needs from whoever holds mail's credentials, and the plain values it is
/// answered in (MAIL-ENGINE 3.3).
///
/// The engine never sees a refresh token. It asks for an access token by account and gets back
/// a value that says how long it may be believed and which scopes Google put on it, and it asks
/// what this device holds for an account and gets one of three answers. Everything that touches
/// GoogleSignIn, the keychain or a window lives behind this protocol in `MailApp/`
/// (`MailGoogleAccess`, 3.3), which is why the engine, which compiles into the tests, can name
/// none of it — and why this file, which names only Foundation, is the whole of the engine's
/// view of Google's accounts.
///
/// Mail holds its own credential, separate from the calendar's (3.2, option C), so nothing in
/// here reads or writes the calendar's. Whether the account's calendar works and whether its
/// mail works are two questions with two answers.
///
/// The engine re-reads `connectedAccountIDs` and each `mailGrant` at the start of every pass
/// and on `resume()`, so there is no change signal here to miss.
@MainActor
protocol MailAccountAccess: AnyObject {
    /// Every account connected to Banana (lower-cased addresses), in the calendar's order.
    var connectedAccountIDs: [String] { get }
    /// What this device holds for an account's mail.
    func mailGrant(accountID: String) -> MailGrant
    /// From mail's own cache, minting if needed; one mint in flight per account.
    func mailAccessToken(accountID: String) async throws -> MailAccessToken
    /// After a 401: forget the cached token so the next call mints.
    func dropMailAccessToken(accountID: String)
    /// Google's consent for Gmail, for this account, on this device. Needs a window in front.
    func requestMailAccess(accountID: String) async -> MailAccessOutcome
    /// Durably delete this device's mail credential. Revokes nothing at Google.
    /// Failure leaves the previous grant intact and must be shown to the user.
    func forgetMailAccess(accountID: String) async throws
    /// Mail is leaving the foreground: end every token request in the air. Nothing is
    /// remembered of them; the next call mints again.
    func cancelMailTokenRequests()
}

/// What this device holds for one account's mail.
enum MailGrant: Equatable, Sendable {
    /// Never allowed on this device.
    case none
    /// A credential is stored.
    case granted
    /// Google refused it: revoked, password changed, expired.
    case rejected(reason: MailGrantRejection)
}

/// Why Google refused a stored credential. Only this is kept: Google's own words are not
/// stored, shown or logged, because the cure does not depend on them and they may carry the
/// account's address.
enum MailGrantRejection: String, Codable, Sendable {
    case invalidGrant, clientRejected, emptyCredential
}

extension MailGrantRejection {
    /// The kind of a rejection, read from the minter's summary — `GoogleTokenMinter`'s
    /// `credentialRejected(reason:)` carries Google's error code, a colon, then its sentence
    /// (`invalid_grant: Token has been expired or revoked.`), or the code alone.
    ///
    /// Only the code, the text before the first colon, is looked at; the sentence is never read
    /// and the summary is not kept. `invalid_client` and `unauthorized_client` both mean the
    /// OAuth client itself was not accepted. Anything else, and no summary at all, is
    /// `invalidGrant`, the commonest cause and the one whose cure — allow Mail again — is the
    /// right thing to offer when we cannot tell. `emptyCredential` is never read from a
    /// summary: it is what the access object says of a credential that holds no refresh token.
    init(oauthSummary: String?) {
        let code = oauthSummary?
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch code {
        case "invalid_client", "unauthorized_client":
            self = .clientRejected
        default:
            self = .invalidGrant
        }
    }
}

/// An access token and what Google said it carries. The expiry is not here: how long a token
/// is believed is `MailTokenFlight`'s business, not the engine's.
struct MailAccessToken: Equatable, Sendable {
    var value: String
    /// Scopes Google says the token carries, when the token response said. Nil: unknown.
    var scopes: Set<String>?
}

enum MailAccessError: Error, Equatable {
    /// Not in `connectedAccountIDs`.
    case unknownAccount
    /// `MailGrant.none`.
    case notGranted
    /// `MailGrant.rejected`.
    case rejected
    /// This build has no OAuth client id.
    case notConfigured
    /// The token endpoint could not be reached or answered 5xx.
    case transport
    /// The device could not durably read or save Mail's credential.
    case credentialStorage
}

enum MailAccessOutcome: Equatable, Sendable {
    case granted
    /// Consent finished without the Gmail scope ticked.
    case declined
    /// The sheet was closed.
    case cancelled
    /// Google signed in another address.
    case differentAccount
    /// Nothing to present from.
    case noWindow
    case failed(MailAccessError)
}

enum MailScopes {
    static let gmailModify = "https://www.googleapis.com/auth/gmail.modify"

    /// The scopes in a token response's space-separated `scope` field.
    ///
    /// **Nil means unknown, and nothing else does.** A token response need not carry the field
    /// at all, and an empty one says nothing either, so both read as "Google did not say" —
    /// never as the empty set. The difference matters: a set known to lack Gmail marks the
    /// account withdrawn (`MailAccountRules.state`), and a working account must never be marked
    /// withdrawn because one response was terse. A field of nothing but blanks is the same as
    /// an empty one.
    static func parse(_ scopeField: String?) -> Set<String>? {
        guard let scopeField else { return nil }
        let scopes = scopeField.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return scopes.isEmpty ? nil : Set(scopes)
    }
}

#endif
