#if BANANA_AI && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
import CryptoKit
import Foundation

/// Authenticated, one-request frames over Banana Cloud. The relay sees routing identifiers and
/// ciphertext. A fresh Mac connection's challenge is included in every authenticated frame.
enum DesktopCloudRelay {
    static let maximumFrame = 4 * 1024 * 1024 + 64

    static func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func valid(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func identifier(of frame: Data) throws -> String {
        guard (60...maximumFrame).contains(frame.count),
              let id = String(data: frame.prefix(32), encoding: .ascii), valid(id) else {
            throw DesktopPeerLink.Failure.invalidMessage
        }
        return id
    }

    static func seal<Value: Encodable>(_ value: Value, id: String, challenge: String,
                                       pairing: DesktopPeerLink.Pairing, response: Bool) throws -> Data {
        guard valid(id), valid(challenge) else { throw DesktopPeerLink.Failure.invalidMessage }
        let encoded = try JSONEncoder().encode(value)
        let sealed = try ChaChaPoly.seal(encoded, using: key(pairing), authenticating: context(id, challenge, response))
        let frame = Data(id.utf8) + sealed.combined
        guard frame.count <= maximumFrame else { throw DesktopPeerLink.Failure.invalidMessage }
        return frame
    }

    static func open<Value: Decodable>(_ type: Value.Type, frame: Data, id: String, challenge: String,
                                        pairing: DesktopPeerLink.Pairing, response: Bool) throws -> Value {
        guard try identifier(of: frame) == id, valid(challenge) else { throw DesktopPeerLink.Failure.invalidMessage }
        let sealed = try ChaChaPoly.SealedBox(combined: frame.dropFirst(32))
        return try JSONDecoder().decode(type, from: ChaChaPoly.open(sealed, using: key(pairing),
                                       authenticating: context(id, challenge, response)))
    }

    private static func key(_ pairing: DesktopPeerLink.Pairing) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: pairing.key),
                              info: Data("banana-desktop-relay-v1".utf8), outputByteCount: 32)
    }

    private static func context(_ id: String, _ challenge: String, _ response: Bool) -> Data {
        Data((challenge + id + (response ? "response" : "request")).utf8)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    final class Socket: @unchecked Sendable {
        let task: URLSessionWebSocketTask
        private let session: URLSession

        init(_ request: URLRequest) {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            task = session.webSocketTask(with: request)
            task.maximumMessageSize = maximumFrame
            task.resume()
        }

        func close() {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }

    static func exchange(_ request: DesktopPeerLink.Request, over url: URLRequest, pairing: DesktopPeerLink.Pairing,
                         timeout: Duration) async throws -> DesktopPeerLink.Response {
        let socket = Socket(url)
        defer { socket.close() }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: DesktopPeerLink.Response.self) { group in
                group.addTask {
                    guard case .string(let challenge) = try await socket.task.receive(), valid(challenge) else {
                        throw DesktopPeerLink.Failure.invalidMessage
                    }
                    let id = nonce()
                    try await socket.task.send(.data(try seal(request, id: id, challenge: challenge, pairing: pairing, response: false)))
                    guard case .data(let frame) = try await socket.task.receive() else {
                        throw DesktopPeerLink.Failure.invalidMessage
                    }
                    return try open(DesktopPeerLink.Response.self, frame: frame, id: id, challenge: challenge,
                                    pairing: pairing, response: true)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    socket.close()
                    throw DesktopPeerLink.Failure.timeout
                }
                defer { group.cancelAll(); socket.close() }
                guard let result = try await group.next() else { throw DesktopPeerLink.Failure.unavailable }
                return result
            }
        } onCancel: {
            socket.close()
        }
    }
}
#endif
