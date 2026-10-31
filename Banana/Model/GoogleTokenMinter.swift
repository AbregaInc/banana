import Foundation

/// Mints Google access tokens from a stored refresh token.
///
/// `GIDSignIn` will happily refresh the ONE account it considers current, which is precisely the
/// limitation being removed here. A refresh token is not device-bound — it is bound to the OAuth
/// client — so any device holding one can mint access tokens for that account. That is what lets
/// a second Google account work at all, and what lets a synced credential work on the iPhone
/// without signing in there.
///
/// Installed-app OAuth clients (iOS and macOS) have no client secret, so the refresh grant is just
/// the client id and the token.
enum GoogleTokenMinter {
    private static let endpoint = URL(string: "https://oauth2.googleapis.com/token")!

    struct MintedToken: Equatable, Sendable {
        var accessToken: String
        var expiresAt: Date
        /// Google's signed statement of who the account is, when the grant includes `openid`
        /// (Google Sign-In's always does). It lets the Banana service know the person without a
        /// sign-in sheet (`BananaAccount`).
        var idToken: String? = nil
        var scopes: Set<String>? = nil
    }

    enum MintError: LocalizedError {
        /// Google rejected the refresh token outright — revoked, or the account's access was
        /// removed. Distinct from a transient failure because the only cure is signing in again,
        /// and retrying forever would just look like the account silently not working.
        ///
        /// `reason` is Google's own words (`invalid_grant: Token has been expired or revoked.`).
        /// Kept because the cause decides the cure: a consumer account on an OAuth app still in
        /// "Testing" loses its token every seven days; a Workspace domain with session control
        /// expires it on the admin's schedule; neither is fixed by anything in Banana.
        case credentialRejected(reason: String?)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .credentialRejected(let reason):
                let base = "Google signed this account out. Connect it again in Settings."
                return reason.map { "\(base) (Google said: \($0))" } ?? base
            case .transport(let message):
                return message
            }
        }
    }

    static func mint(refreshToken: String, clientID: String, session: URLSession = .shared) async throws -> MintedToken {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = refreshBody(refreshToken: refreshToken, clientID: clientID)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw MintError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MintError.transport("Unexpected response from Google.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let oauth = OAuthError.parse(data)
            if Self.isCredentialRejection(status: http.statusCode, error: oauth?.error) {
                throw MintError.credentialRejected(reason: oauth?.summary)
            }
            throw MintError.transport(
                "Google returned \(http.statusCode) refreshing this account"
                    + (oauth?.summary.map { ": \($0)" } ?? "."))
        }
        guard let token = token(from: data, now: Date()) else {
            throw MintError.transport("Couldn’t read Google’s token response.")
        }
        return token
    }

    static func refreshBody(refreshToken: String, clientID: String) -> Data {
        // Form values are opaque credentials: +, &, = and % must never become delimiters.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return Data("client_id=\(encode(clientID))&refresh_token=\(encode(refreshToken))&grant_type=refresh_token".utf8)
    }

    static func token(from data: Data, now: Date) -> MintedToken? {
        guard let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !decoded.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.expires_in > 0 else { return nil }
        let values = decoded.scope?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        // Expire a minute early so a token is never used in the last moments of its life.
        return MintedToken(
            accessToken: decoded.access_token,
            expiresAt: now.addingTimeInterval(TimeInterval(max(0, decoded.expires_in - 60))),
            idToken: decoded.id_token, scopes: values.isEmpty ? nil : Set(values))
    }

    /// Whether a failed refresh means this credential can no longer be used, as opposed to
    /// something worth retrying.
    ///
    /// Only an OAuth error Google defines as "this grant or client is not accepted" counts. A bare
    /// 400 used to be enough, which let any malformed-request or rate-limit answer mark a working
    /// account as signed out.
    static func isCredentialRejection(status: Int, error: String?) -> Bool {
        switch error {
        case "invalid_grant", "unauthorized_client", "invalid_client":
            return true
        case .some:
            return false
        case nil:
            // No parseable body: fall back to the status alone, but only the one that means
            // unauthenticated.
            return status == 401
        }
    }

    struct OAuthError: Decodable, Equatable {
        let error: String
        let error_description: String?

        var summary: String? {
            error_description.map { "\(error): \($0)" } ?? error
        }

        static func parse(_ data: Data) -> OAuthError? {
            try? JSONDecoder().decode(OAuthError.self, from: data)
        }
    }

    private struct RefreshResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let id_token: String?
        let scope: String?
    }
}
