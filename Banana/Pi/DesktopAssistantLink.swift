#if BANANA_AI && BANANA_BETA && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
import Foundation
import Network
import Security

@MainActor
final class DesktopAssistantLink: ObservableObject {
    static let shared = DesktopAssistantLink()

    struct Model: Codable, Equatable, Sendable {
        let modelId: String
        let name: String
        let contextWindow: Int
        let maxTokens: Int
        let thinkingLevel: String

        var agent: [String: Any] {
            ["modelId": modelId, "name": name, "contextWindow": contextWindow,
             "maxTokens": maxTokens, "thinkingLevel": thinkingLevel]
        }

        var status: [String: Any] {
            ["available": true, "reason": name, "contextWindow": contextWindow, "modelName": name]
        }
    }

    private static let hello = "desktop.hello.v1"
    private static let describe = "assistant.model.v1"
    private static let infer = "assistant.generate.v1"
    private static let addressKey = "desktopLink.tailscaleAddress"
    private static let pairingKey = "desktopLink.hasPairing"

    /// Skip Keychain and network work at launch on devices that have never opted in.
    static var hasSavedPairing: Bool { UserDefaults.standard.bool(forKey: pairingKey) }

    @Published private(set) var isPaired = false
    @Published private(set) var status = ""
    private var pairing: DesktopPeerLink.Pairing? {
        didSet { isPaired = pairing != nil }
    }

    private init() {
        pairing = Self.loadPairing()
        isPaired = pairing != nil
    }

    // The pairing is per installation. Never put the secret in synced preferences or logs.
    private static var keychain: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "desktop-peer-v1",
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "banana.beta",
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func loadPairing() -> DesktopPeerLink.Pairing? {
        var query = keychain
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return DesktopPeerLink.Pairing(code: data.base64EncodedString())
    }

    private func save(_ pair: DesktopPeerLink.Pairing) throws {
        let values = [kSecValueData as String: pair.key]
        let result = SecItemUpdate(Self.keychain as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            let insertion = Self.keychain.merging(values) { _, value in value }
                .merging([kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, value in value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw keychainFailure }
        } else if result != errSecSuccess {
            throw keychainFailure
        }
        pairing = pair
        UserDefaults.standard.set(true, forKey: Self.pairingKey)
    }

    private var keychainFailure: DesktopPeerLink.Failure {
        .rejected("Banana couldn’t save the pairing on this device.")
    }

    func forget() throws {
        let result = SecItemDelete(Self.keychain as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw keychainFailure }
        #if os(macOS)
        stopHosting()
        #else
        allowTailscale = false
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
        #endif
        pairing = nil
        UserDefaults.standard.removeObject(forKey: Self.pairingKey)
        status = ""
    }

    #if os(macOS)
    @Published private(set) var hosting = false
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var inferenceInProgress = false

    var pairingCode: String? { pairing?.code }

    func enableHosting() throws {
        if pairing == nil { try save(.init()) }
        startHosting()
    }

    func startHosting() {
        guard let pairing, listener == nil else { return }
        do {
            let next = try NWListener(using: pairing.parameters(), on: DesktopPeerLink.port)
            next.service = .init(name: pairing.serviceName, type: DesktopPeerLink.serviceType)
            next.stateUpdateHandler = { [weak self, weak next] state in
                MainActor.assumeIsolated {
                    guard let self, let next, self.listener === next else { return }
                    switch state {
                    case .ready: self.hosting = true; self.status = "Ready to connect"
                    case .failed:
                        self.stopHosting()
                        self.status = "Couldn’t start the link. Check Local Network access and try again."
                    default: break
                    }
                }
            }
            next.newConnectionHandler = { [weak self, weak next] connection in
                MainActor.assumeIsolated {
                    guard let self, let next, self.listener === next else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener = next
            status = "Starting desktop link…"
            next.start(queue: .main)
            LocalModel.shared.start()
        } catch {
            status = "Couldn’t start the desktop link."
        }
    }

    private func stopHosting() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        hosting = false
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        Task {
            defer { connection.cancel(); connections.removeValue(forKey: id) }
            do {
                let request = try await DesktopPeerLink.within(.seconds(8), connection: connection) {
                    try await DesktopPeerLink.read(DesktopPeerLink.Request.self, from: connection)
                }
                guard connections[id] != nil else { return }
                // The client's only legal write was the request. A close cancels in-flight inference.
                let task = Task { try await answer(request) }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in task.cancel() }
                let response: DesktopPeerLink.Response
                do { response = .init(payload: try await task.value, error: nil) }
                catch is CancellationError { return }
                catch let error as DesktopPeerLink.Failure { response = .init(payload: nil, error: error.localizedDescription) }
                catch { response = .init(payload: nil, error: "The model on your Mac couldn’t finish this request.") }
                try await DesktopPeerLink.within(.seconds(8), connection: connection) {
                    try await DesktopPeerLink.send(response, to: connection)
                }
            } catch {
                // Unauthenticated, malformed and interrupted connections are discarded.
            }
        }
    }

    private func answer(_ request: DesktopPeerLink.Request) async throws -> String {
        guard request.version == 1 else { throw DesktopPeerLink.Failure.incompatible }
        if request.operation == Self.hello { return "ready" }
        guard request.operation == Self.describe || request.operation == Self.infer else {
            throw DesktopPeerLink.Failure.incompatible
        }
        guard let config = MacLocalInference.shared.resolvedConfiguration() else {
            throw DesktopPeerLink.Failure.rejected("The model on your Mac is still getting ready.")
        }
        if request.operation == Self.describe {
            let model = Model(modelId: config.modelId, name: config.name, contextWindow: config.contextWindow,
                              maxTokens: config.maxTokens, thinkingLevel: config.thinkingLevel)
            return String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
        }
        guard let raw = request.payload,
              let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              input["backend"] as? String == "mac-local", input["modelId"] as? String == config.modelId else {
            throw DesktopPeerLink.Failure.invalidMessage
        }
        guard !inferenceInProgress else { throw DesktopPeerLink.Failure.busy }
        inferenceInProgress = true
        defer { inferenceInProgress = false }
        try Task.checkCancellation()
        return try await MacLocalInference.shared.generate(raw)
    }
    #else
    /// Away access is opt-in for the current launch. The local address is always tried first.
    @Published var allowTailscale = false
    @Published private(set) var route: DesktopPeerLink.Route?

    var tailscaleAddress: String { UserDefaults.standard.string(forKey: Self.addressKey) ?? "" }

    func setTailscaleAddress(_ value: String) throws {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty || DesktopPeerLink.tailnetEndpoint(address) != nil else {
            throw DesktopPeerLink.Failure.rejected("Enter the Mac’s Tailscale IPv4 address.")
        }
        UserDefaults.standard.set(address, forKey: Self.addressKey)
    }

    func pair(with code: String) async throws {
        guard let candidate = DesktopPeerLink.Pairing(code: code) else {
            throw DesktopPeerLink.Failure.rejected("Enter the pairing code shown on your Mac.")
        }
        _ = try await call(.init(Self.hello), pairing: candidate, timeout: .seconds(8))
        try save(candidate)
    }

    /// QR setup authenticates the Mac on the LAN before saving an optional away address.
    func pair(_ qr: DesktopPeerLink.PairingQR) async throws {
        _ = try await call(.init(Self.hello), pairing: qr.pairing, timeout: .seconds(8), localOnly: true)
        let sameMac = pairing == qr.pairing
        try save(qr.pairing)
        if !sameMac || qr.tailscaleAddress != nil {
            allowTailscale = false
            try setTailscaleAddress(qr.tailscaleAddress ?? "")
        }
    }

    func model() async -> Model? {
        guard let pairing else { return nil }
        do { return try await model(using: pairing) }
        catch is CancellationError { return nil }
        catch { status = error.localizedDescription; route = nil; return nil }
    }

    private func model(using pairing: DesktopPeerLink.Pairing) async throws -> Model {
        let reply = try await call(.init(Self.describe), pairing: pairing, timeout: .seconds(8))
        let value = try JSONDecoder().decode(Model.self, from: Data(reply.utf8))
        guard !value.modelId.isEmpty, (4096...1_048_576).contains(value.contextWindow),
              (1..<value.contextWindow).contains(value.maxTokens),
              ["off", "low", "medium", "high", "xhigh"].contains(value.thinkingLevel) else {
            throw DesktopPeerLink.Failure.invalidMessage
        }
        status = value.name
        return value
    }

    func generate(_ raw: String) async throws -> String {
        guard let pairing else { throw DesktopPeerLink.Failure.unavailable }
        return try await call(.init(Self.infer, payload: raw), pairing: pairing, timeout: .seconds(180))
    }

    private func call(_ request: DesktopPeerLink.Request, pairing: DesktopPeerLink.Pairing,
                      timeout: Duration, localOnly: Bool = false) async throws -> String {
        let (connection, path) = try await DesktopPeerLink.connect(to: pairing,
            tailscaleAddress: !localOnly && allowTailscale ? tailscaleAddress : nil)
        defer { connection.cancel() }
        let response = try await DesktopPeerLink.within(timeout, connection: connection) {
            try await DesktopPeerLink.send(request, to: connection)
            return try await DesktopPeerLink.read(DesktopPeerLink.Response.self, from: connection)
        }
        if let error = response.error { throw DesktopPeerLink.Failure.rejected(error) }
        guard let payload = response.payload else { throw DesktopPeerLink.Failure.invalidMessage }
        route = path
        return payload
    }
    #endif
}
#endif
