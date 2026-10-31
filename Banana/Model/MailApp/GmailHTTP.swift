#if !BANANA_PUBLIC
import Foundation

/// Native URLSession transport; uses existing forgiving wire decoders without inventing a new HTTP stack.
/// Streaming limits are enforced before decoding. No automatic retries, cookies or redirects.
final class GmailHTTP: GmailAPI, @unchecked Sendable {
    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let session: URLSession
    private let allowed: @Sendable () -> Bool
    private let maximumBytes: Int

    init(configuration: URLSessionConfiguration = .ephemeral, maximumBytes: Int = 40 * 1024 * 1024,
         networkAllowed: @escaping @Sendable () -> Bool) {
        precondition(maximumBytes > 0)
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false; config.httpMaximumConnectionsPerHost = 4
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        allowed = networkAllowed; self.maximumBytes = maximumBytes
    }
    deinit { session.invalidateAndCancel() }

    func profile(token: String) async throws -> GmailProfile { try await get(["profile"], token: token) }
    func labels(token: String) async throws -> [GmailLabel] {
        let list: GmailLabelList = try await get(["labels"], token: token)
        guard let labels = list.labels else { throw GmailError.malformed }
        return labels
    }
    func listMessages(token: String, labelIDs: [String], query: String?, includeSpamTrash: Bool,
                      pageToken: String?, maxResults: Int) async throws -> GmailIDPage {
        guard (1...500).contains(maxResults) else { throw GmailError.refused(.invalidArgument) }
        var queryItems = labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        queryItems += [.init(name: "maxResults", value: String(maxResults)),
                       .init(name: "includeSpamTrash", value: String(includeSpamTrash))]
        if let query { queryItems.append(.init(name: "q", value: query)) }
        if let pageToken { queryItems.append(.init(name: "pageToken", value: pageToken)) }
        return try await get(["messages"], token: token, query: queryItems)
    }
    func history(token: String, start: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryPage {
        guard (1...500).contains(maxResults), GmailNumber.unsigned(start) != nil else { throw GmailError.refused(.invalidArgument) }
        var query: [URLQueryItem] = [.init(name: "startHistoryId", value: start), .init(name: "maxResults", value: String(maxResults))]
        if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
        return try await get(["history"], token: token, query: query)
    }
    func message(token: String, id: String, format: GmailFormat) async throws -> GmailMessage {
        let read: GmailReadMessage = try await get(["messages", id], token: token, query: formatQuery(format))
        return read.value
    }
    func thread(token: String, id: String, format: GmailFormat) async throws -> GmailThread {
        let read: GmailReadThread = try await get(["threads", id], token: token, query: formatQuery(format))
        return read.value
    }
    func attachment(token: String, messageID: String, attachmentID: String) async throws -> GmailPartBody {
        try await get(["messages", messageID, "attachments", attachmentID], token: token)
    }
    private func formatQuery(_ format: GmailFormat) -> [URLQueryItem] {
        var result = [URLQueryItem(name: "format", value: format.apiValue)]
        if format == .header {
            for name in ["From", "To", "Cc", "Bcc", "Subject", "Date", "Message-ID", "In-Reply-To",
                         "References", "List-ID", "List-Unsubscribe", "List-Unsubscribe-Post", "Authentication-Results"] {
                result.append(.init(name: "metadataHeaders", value: name))
            }
        }
        return result
    }
    func modify(token: String, id: String, add: [String], remove: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["addLabelIds": add, "removeLabelIds": remove])
        _ = try await send(["messages", id, "modify"], token: token, method: "POST", body: body)
    }
    func trash(token: String, id: String) async throws {
        _ = try await send(["messages", id, "trash"], token: token, method: "POST")
    }
    func untrash(token: String, id: String) async throws {
        _ = try await send(["messages", id, "untrash"], token: token, method: "POST")
    }

    private func get<T: Decodable>(_ path: [String], token: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, token: token, query: query)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GmailError.malformed }
    }

    static func request(_ path: [String], token: String, query: [URLQueryItem] = [],
                        method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard !token.isEmpty, !path.isEmpty, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GmailError.refused(.invalidArgument)
        }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var url = URLComponents(string: "https://gmail.googleapis.com")!
        url.percentEncodedPath = "/gmail/v1/users/me/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved)! }.joined(separator: "/")
        if !query.isEmpty { url.queryItems = query; url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Banana-Mail gzip", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ path: [String], token: String, query: [URLQueryItem] = [],
                      method: String = "GET", body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard allowed() else { throw GmailError.networkDisabled }
        let request = try Self.request(path, token: token, query: query, method: method, body: body)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw GmailError.malformed }
            let cap = (200..<300).contains(http.statusCode) ? maximumBytes : min(maximumBytes, 64 * 1024)
            guard response.expectedContentLength <= Int64(cap) else { throw GmailError.responseTooLarge }
            var data = Data(); data.reserveCapacity(min(cap, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                if data.count % 4096 == 0 {
                    try Task.checkCancellation()
                    guard allowed() else { throw GmailError.networkDisabled }
                }
                guard data.count < cap else { throw GmailError.responseTooLarge }
                data.append(byte)
            }
            guard (200..<300).contains(http.statusCode) else {
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                throw GmailHTTPRules.failure(status: http.statusCode, data: data, retryAfter: retry)
            }
            return data
        } catch let error as GmailError { throw error }
        catch { throw GmailHTTPRules.transport(error) }
    }
}

#endif
