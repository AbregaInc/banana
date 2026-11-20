#if BANANA_AI && BANANA_BETA && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
import CryptoKit
import Foundation
import Network
import Security

/// Versioned, authenticated transport shared by future desktop capabilities. One request per
/// connection, so a dropped connection can cancel the work and a request is never replayed.
enum DesktopPeerLink {
    static let port = NWEndpoint.Port(rawValue: 47979)!
    static let serviceType = "_banana-link._tcp"
    private static let limit = 4 * 1024 * 1024

    struct Pairing: Equatable, Sendable {
        private static let qrPrefix = "BANANA-DESKTOP-LINK/1/"
        let key: Data

        init() {
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }

        init?(code: String) {
            guard let value = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)),
                  value.count == 32 else { return nil }
            key = value
        }

        var code: String { key.base64EncodedString() }
        var qrPayload: String { Self.qrPrefix + code }

        init?(qrPayload: String) {
            guard qrPayload.hasPrefix(Self.qrPrefix) else { return nil }
            self.init(code: String(qrPayload.dropFirst(Self.qrPrefix.count)))
        }

        var serviceName: String { "Banana-" + SHA256.hash(data: key).prefix(12).map { String(format: "%02x", $0) }.joined() }
        func parameters(localOnly: Bool = false) -> NWParameters {
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            // Network.framework's external PSK API is TLS 1.2. Offer only the PSK cipher.
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00a8)!)
            let psk = key.withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
            let identity = Data("banana-peer-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
            sec_protocol_options_add_pre_shared_key(options, psk, identity)
            let parameters = NWParameters(tls: tls, tcp: .init())
            if localOnly {
                parameters.prohibitedInterfaceTypes = [.cellular, .other]
            }
            return parameters
        }
    }

    struct Request: Codable {
        let version: Int
        let operation: String
        let payload: String?
        init(_ operation: String, payload: String? = nil) {
            self.version = 1
            self.operation = operation
            self.payload = payload
        }
    }

    struct Response: Codable {
        let payload: String?
        let error: String?
    }

    enum Route: String { case local = "Local network", tailscale = "Tailscale" }

    enum Failure: LocalizedError {
        case unavailable, timeout, invalidMessage, incompatible, busy
        case rejected(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Can’t reach your Mac. Make sure Banana Beta is open."
            case .timeout: "Your Mac didn’t respond in time."
            case .invalidMessage: "The desktop link received an invalid message."
            case .incompatible: "Update Banana Beta on both devices."
            case .busy: "Your Mac is busy. Try again in a moment."
            case let .rejected(reason): reason
            }
        }
    }

    /// Only an explicit Tailscale IPv4 address is accepted. This path never resolves public DNS.
    static func tailnetEndpoint(_ input: String) -> NWEndpoint? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = IPv4Address(value) else { return nil }
        let bytes = Array(address.rawValue)
        guard bytes[0] == 100, (64...127).contains(bytes[1]) else { return nil }
        return .hostPort(host: .ipv4(address), port: port)
    }

    /// If Bonjour finds the Mac, this request stays on the LAN even after a connection failure.
    /// A caller can opt in to Tailscale for a Mac that isn't advertised on the local network.
    @MainActor static func connect(to pairing: Pairing, tailscaleAddress: String?) async throws -> (NWConnection, Route) {
        if let endpoint = try await discover(pairing, timeout: .seconds(2)) {
            let connection = try await open(endpoint, pairing: pairing, localOnly: true, timeout: .seconds(4))
            return (connection, .local)
        }
        guard let tailscaleAddress, let endpoint = tailnetEndpoint(tailscaleAddress) else {
            throw Failure.unavailable
        }
        let connection = try await open(endpoint, pairing: pairing, localOnly: false, timeout: .seconds(4))
        return (connection, .tailscale)
    }

    @MainActor static func discover(_ pairing: Pairing, timeout: Duration) async throws -> NWEndpoint? {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: parameters)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var deadline: Task<Void, Never>?
                var finished = false
                let finish: (Result<NWEndpoint?, Error>) -> Void = { result in
                    guard !finished else { return }
                    finished = true
                    deadline?.cancel()
                    browser.stateUpdateHandler = nil
                    browser.browseResultsChangedHandler = nil
                    browser.cancel()
                    continuation.resume(with: result)
                }
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        if case .service(let name, _, _, _) = result.endpoint, name == pairing.serviceName {
                            finish(.success(result.endpoint))
                            return
                        }
                    }
                }
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error): finish(.failure(error))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                deadline = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    finish(.success(nil))
                }
                browser.start(queue: .main)
            }
        } onCancel: {
            browser.cancel()
        }
    }

    @MainActor static func open(_ endpoint: NWEndpoint, pairing: Pairing, localOnly: Bool,
                                timeout: Duration) async throws -> NWConnection {
        try Task.checkCancellation()
        let connection = NWConnection(to: endpoint, using: pairing.parameters(localOnly: localOnly))
        do {
            try await within(timeout, connection: connection) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.stateUpdateHandler = nil
                            continuation.resume()
                        case .failed(let error):
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        case .cancelled:
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                    connection.start(queue: .main)
                }
            }
            if localOnly, let path = connection.currentPath,
               path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                return connection
            }
            if !localOnly { return connection }
            throw Failure.unavailable
        } catch {
            connection.cancel()
            throw error
        }
    }

    @MainActor static func within<Value: Sendable>(_ timeout: Duration, connection: NWConnection,
                                                  _ work: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await work() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Failure.timeout
                }
                defer { group.cancelAll() }
                do {
                    guard let result = try await group.next() else { throw Failure.unavailable }
                    return result
                } catch {
                    connection.cancel()
                    throw error
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func send<T: Encodable>(_ value: T, to connection: NWConnection) async throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= limit else { throw Failure.invalidMessage }
        var length = UInt32(payload.count).bigEndian
        var message = withUnsafeBytes(of: &length) { Data($0) }
        message.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from connection: NWConnection) async throws -> T {
        let header = try await read(4, from: connection)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...limit).contains(length) else { throw Failure.invalidMessage }
        let payload = try await read(length, from: connection)
        return try JSONDecoder().decode(type, from: payload)
    }

    private static func read(_ length: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == length { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Failure.unavailable) }
            }
        }
    }
}
#endif
