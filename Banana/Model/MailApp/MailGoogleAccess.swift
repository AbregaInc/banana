#if !BANANA_PUBLIC
import Foundation

struct GoogleConsentResult: Sendable {
    var email: String
    var refreshToken: String
    var grantedScopes: [String]
}
enum GoogleConsentError: Error { case noWindow, cancelled, notConfigured, failed }

/// Credentials and consent are independent of Calendar. The app adapter supplies only
/// connected identities, client configuration, and Google's existing consent presenter.
@MainActor
final class MailGoogleAccess: MailAccountAccess {
    nonisolated final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    typealias Consent = @MainActor (String, [String]) async throws -> GoogleConsentResult
    typealias Mint = @Sendable (String, String, URLSession) async throws -> GoogleTokenMinter.MintedToken
    private let storage: any MailCredentialStorage
    private let accountIDs: @MainActor () -> [String]
    private let clientID: @MainActor () -> String?
    private let consent: Consent
    private let mint: Mint
    private let session: URLSession
    private var credentials: [String: MailCredential] = [:]
    private var stamps: [String: MailGrantLedger.Stamp] = [:]
    private var mutation: Task<Void, Error>?
    private var mutationNumber: UInt64 = 0
    private var consenting = false
    private var consentGeneration: [String: UInt64] = [:]
    private lazy var ledger = MailGrantLedger(clock: SystemMailClock()) { [weak self] account, stamp in
        guard let self, self.stamps[account] == stamp, let credential = self.credentials[account] else {
            throw MailAccessError.notGranted
        }
        guard let client = self.clientID(), !client.isEmpty else { throw MailAccessError.notConfigured }
        do {
            let token = try await self.mint(credential.refreshToken, client, self.session)
            return (token.accessToken, token.expiresAt, token.scopes)
        } catch let error as GoogleTokenMinter.MintError {
            switch error {
            case .credentialRejected(let reason):
                throw MailCredentialRefused(reason: MailGrantRejection(oauthSummary: reason))
            case .transport: throw MailAccessError.transport
            }
        }
    }

    static func load(storage: any MailCredentialStorage,
                     accountIDs: @escaping @MainActor () -> [String],
                     clientID: @escaping @MainActor () -> String?, consent: @escaping Consent,
                     mint: @escaping Mint = { try await GoogleTokenMinter.mint(refreshToken: $0, clientID: $1, session: $2) }) async throws -> MailGoogleAccess {
        let saved: [MailCredential]
        do { saved = try await storage.load() }
        catch { throw MailAccessError.credentialStorage }
        return MailGoogleAccess(storage: storage, saved: saved, accountIDs: accountIDs,
                                clientID: clientID, consent: consent, mint: mint)
    }

    private init(storage: any MailCredentialStorage, saved: [MailCredential],
                 accountIDs: @escaping @MainActor () -> [String],
                 clientID: @escaping @MainActor () -> String?, consent: @escaping Consent,
                 mint: @escaping Mint) {
        self.storage = storage; self.accountIDs = accountIDs; self.clientID = clientID
        self.consent = consent; self.mint = mint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        for credential in saved {
            credentials[credential.id] = credential
            stamps[credential.id] = ledger.stored(account: credential.id, isEmpty: credential.refreshToken.isEmpty)
        }
    }

    deinit { session.invalidateAndCancel() }

    var connectedAccountIDs: [String] { accountIDs().map { $0.lowercased() } }
    func mailGrant(accountID: String) -> MailGrant { ledger.grant(for: accountID.lowercased()) }
    func mailAccessToken(accountID: String) async throws -> MailAccessToken {
        let id = accountID.lowercased()
        guard connectedAccountIDs.contains(id) else { throw MailAccessError.unknownAccount }
        let token = try await ledger.token(for: id)
        guard connectedAccountIDs.contains(id) else { throw MailAccessError.unknownAccount }
        return token
    }
    func dropMailAccessToken(accountID: String) { ledger.dropToken(account: accountID.lowercased()) }
    func cancelMailTokenRequests() { ledger.cancelMints() }

    func requestMailAccess(accountID: String) async -> MailAccessOutcome {
        let id = accountID.lowercased()
        guard connectedAccountIDs.contains(id) else { return .failed(.unknownAccount) }
        guard let client = clientID(), !client.isEmpty else { return .failed(.notConfigured) }
        guard !consenting else { return .cancelled }
        consenting = true; defer { consenting = false }
        let generation = consentGeneration[id, default: 0]
        do {
            let result = try await consent(id, [MailScopes.gmailModify])
            try Task.checkCancellation()
            guard consentGeneration[id, default: 0] == generation else { return .cancelled }
            guard result.email.lowercased() == id else { return .differentAccount }
            guard result.grantedScopes.contains(MailScopes.gmailModify) else { return .declined }
            guard !result.refreshToken.isEmpty else { return .failed(.rejected) }
            guard connectedAccountIDs.contains(id) else { return .failed(.unknownAccount) }
            let credential = MailCredential(email: id, refreshToken: result.refreshToken,
                                            scopes: result.grantedScopes, grantedAt: Date())
            try await persist { $0[id] = credential }
            return .granted
        } catch is CancellationError { return .cancelled }
        catch let error as GoogleConsentError {
            switch error {
            case .noWindow: return .noWindow
            case .cancelled: return .cancelled
            case .notConfigured: return .failed(.notConfigured)
            case .failed: return .failed(.transport)
            }
        } catch let error as MailAccessError { return .failed(error) }
        catch { return .failed(.transport) }
    }

    func forgetMailAccess(accountID: String) async throws {
        let id = accountID.lowercased()
        consentGeneration[id, default: 0] += 1
        try await persist { $0.removeValue(forKey: id) }
    }

    private func persist(_ change: @escaping @MainActor (inout [String: MailCredential]) -> Void) async throws {
        let previous = mutation
        mutationNumber += 1; let number = mutationNumber
        let task = Task { @MainActor in
            _ = await previous?.result
            var next = credentials
            change(&next)
            do { try await storage.save(next.values.sorted { $0.id < $1.id }) }
            catch { throw MailAccessError.credentialStorage }
            for id in Set(credentials.keys).union(next.keys) where credentials[id] != next[id] {
                if let value = next[id] {
                    stamps[id] = ledger.stored(account: id, isEmpty: value.refreshToken.isEmpty)
                } else { ledger.deleted(account: id); stamps.removeValue(forKey: id) }
            }
            credentials = next
        }
        mutation = task
        defer { if mutationNumber == number { mutation = nil } }
        try await task.value
    }
}

#endif
