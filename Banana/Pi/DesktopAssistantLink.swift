#if BANANA_AI && !PI_DEVELOPMENT && !BANANA_DEVELOPMENT
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
    private static let tailscalePreferenceKey = "desktopLink.allowTailscale"
    private static let pairingKey = "desktopLink.hasPairing"

    /// Skip Keychain and network work at launch on devices that have never opted in.
    static var hasSavedPairing: Bool { UserDefaults.standard.bool(forKey: pairingKey) }

    @Published private(set) var isPaired = false
    private var pairing: DesktopPeerLink.Pairing? {
        didSet { isPaired = pairing != nil }
    }

    private init() {
        pairing = Self.loadPairing()
        isPaired = pairing != nil
        #if os(iOS)
        restoreTailscaleSettings()
        #endif
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
        setCloudRelayEnabled(false)
        stopHosting()
        status = ""
        #else
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
        UserDefaults.standard.removeObject(forKey: Self.tailscalePreferenceKey)
        restoreTailscaleSettings()
        #endif
        pairing = nil
        UserDefaults.standard.removeObject(forKey: Self.pairingKey)
    }

    #if os(macOS)
    @Published private(set) var status = ""
    @Published private(set) var hosting = false
    @Published private(set) var cloudEnabled = UserDefaults.standard.bool(forKey: "desktopLink.cloudEnabled")
    @Published private(set) var cloudConnected = false
    private var cloudHost: Task<Void, Never>?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var inferenceInProgress = false

    var pairingCode: String? { pairing?.code }

    func enableHosting() throws {
        if pairing == nil { try save(.init()) }
        startHosting()
    }

    func startHosting() {
        guard let pairing else { return }
        startCloudHost(pairing)
        guard listener == nil else { return }
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

    func setCloudRelayEnabled(_ enabled: Bool) {
        guard cloudEnabled != enabled else { return }
        cloudEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "desktopLink.cloudEnabled")
        if enabled, let pairing {
            startCloudHost(pairing)
        } else {
            cloudHost?.cancel()
            cloudHost = nil
            cloudConnected = false
        }
    }

    private func startCloudHost(_ pairing: DesktopPeerLink.Pairing) {
        guard cloudEnabled, cloudHost == nil else { return }
        cloudHost = Task { [weak self] in
            var delay = 1
            while let self, !Task.isCancelled {
                let challenge = DesktopCloudRelay.nonce()
                if let request = BananaAccount.shared.desktopRelaySocket(link: pairing.serviceName, hostChallenge: challenge) {
                    do { try await self.serveCloud(request, pairing: pairing, challenge: challenge) }
                    catch is CancellationError { return }
                    catch {}
                }
                guard !Task.isCancelled else { return }
                self.cloudConnected = false
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }

    private func serveCloud(_ request: URLRequest, pairing: DesktopPeerLink.Pairing, challenge: String) async throws {
        let socket = DesktopCloudRelay.Socket(request)
        let lease = Task {
            try await Task.sleep(for: .seconds(900))
            socket.close()
        }
        var seen: Set<String> = []
        var jobs: [String: Task<Void, Never>] = [:]
        defer {
            lease.cancel()
            socket.close()
            for job in jobs.values { job.cancel() }
        }
        try await withTaskCancellationHandler {
            guard case .string("ready") = try await socket.task.receive() else { throw DesktopPeerLink.Failure.unavailable }
            cloudConnected = true
            while !Task.isCancelled {
                switch try await socket.task.receive() {
                case .string(let control):
                    let id = String(control.dropFirst(7))
                    if control.hasPrefix("cancel:"), DesktopCloudRelay.valid(id) {
                        jobs[id]?.cancel()
                    }
                case .data(let frame):
                    guard let id = try? DesktopCloudRelay.identifier(of: frame),
                          let value = try? DesktopCloudRelay.open(DesktopPeerLink.Request.self, frame: frame,
                              id: id, challenge: challenge, pairing: pairing, response: false),
                          seen.insert(id).inserted else { continue }
                    guard seen.count < 1_024 else { return }
                    guard jobs.count < 4 else { continue }
                    jobs[id] = Task {
                        defer { jobs[id] = nil }
                        do {
                            let response: DesktopPeerLink.Response
                            do { response = .init(payload: try await answer(value), error: nil) }
                            catch is CancellationError { return }
                            catch { response = .init(payload: nil, error: error.localizedDescription) }
                            try Task.checkCancellation()
                            let reply = try DesktopCloudRelay.seal(response, id: id, challenge: challenge,
                                                                  pairing: pairing, response: true)
                            try await socket.task.send(.data(reply))
                        } catch {}
                    }
                @unknown default: throw DesktopPeerLink.Failure.invalidMessage
                }
            }
        } onCancel: { socket.close() }
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
    @Published private(set) var allowTailscale = false
    @Published private(set) var tailscaleAddress = ""

    private var tailscalePreference: Bool? {
        UserDefaults.standard.object(forKey: Self.tailscalePreferenceKey) as? Bool
    }

    private func restoreTailscaleSettings() {
        let address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        tailscaleAddress = DesktopPeerLink.tailscaleFallback(address: address, preference: nil) ?? ""
        allowTailscale = DesktopPeerLink.tailscaleFallback(address: tailscaleAddress, preference: tailscalePreference) != nil
    }

    private var awayAddress: String? { allowTailscale ? tailscaleAddress : nil }

    func setTailscaleAllowed(_ enabled: Bool) {
        guard !tailscaleAddress.isEmpty else { return }
        UserDefaults.standard.set(enabled, forKey: Self.tailscalePreferenceKey)
        restoreTailscaleSettings()
    }

    private func validatedAddress(_ value: String) throws -> String {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty || DesktopPeerLink.tailnetEndpoint(address) != nil else {
            throw DesktopPeerLink.Failure.rejected("Enter the Mac’s Tailscale IPv4 address.")
        }
        return address
    }

    func setTailscaleAddress(_ value: String) throws {
        let address = try validatedAddress(value)
        UserDefaults.standard.set(address, forKey: Self.addressKey)
        restoreTailscaleSettings()
    }

    private func savePairing(_ candidate: DesktopPeerLink.Pairing, address: String?) throws {
        let sameMac = pairing == candidate
        try save(candidate)
        if !sameMac { UserDefaults.standard.removeObject(forKey: Self.tailscalePreferenceKey) }
        if !sameMac || address != nil { try setTailscaleAddress(address ?? "") }
    }

    func pair(with code: String, tailscaleAddress: String) async throws -> DesktopPeerLink.Route {
        guard let candidate = DesktopPeerLink.Pairing(code: code) else {
            throw DesktopPeerLink.Failure.rejected("Enter the pairing code shown on your Mac.")
        }
        let address = try validatedAddress(tailscaleAddress)
        let fallback = DesktopPeerLink.tailscaleFallback(address: address, preference: pairing == candidate ? tailscalePreference : nil)
        let route = try await authenticate(candidate, tailscaleAddress: fallback)
        try savePairing(candidate, address: address)
        return route
    }

    /// QR setup authenticates the Mac on the LAN before saving its optional away address.
    func pair(_ qr: DesktopPeerLink.PairingQR) async throws -> DesktopPeerLink.Route {
        let route = try await authenticate(qr.pairing, tailscaleAddress: nil, allowCloud: false)
        try savePairing(qr.pairing, address: qr.tailscaleAddress)
        return route
    }

    func checkConnection() async throws -> DesktopPeerLink.Route {
        guard let pairing else { throw DesktopPeerLink.Failure.unavailable }
        return try await authenticate(pairing, tailscaleAddress: awayAddress)
    }

    private func authenticate(_ pairing: DesktopPeerLink.Pairing, tailscaleAddress: String?,
                              allowCloud: Bool = true) async throws -> DesktopPeerLink.Route {
        let reply = try await call(.init(Self.hello), pairing: pairing, tailscaleAddress: tailscaleAddress,
                                   timeout: .seconds(8), allowCloud: allowCloud)
        guard reply.payload == "ready" else { throw DesktopPeerLink.Failure.invalidMessage }
        return reply.route
    }

    func model() async -> Model? {
        guard let pairing else { return nil }
        return try? await model(using: pairing)
    }

    private func model(using pairing: DesktopPeerLink.Pairing) async throws -> Model {
        let reply = try await call(.init(Self.describe), pairing: pairing, tailscaleAddress: awayAddress, timeout: .seconds(8))
        let value = try JSONDecoder().decode(Model.self, from: Data(reply.payload.utf8))
        guard !value.modelId.isEmpty, (4096...1_048_576).contains(value.contextWindow),
              (1..<value.contextWindow).contains(value.maxTokens),
              ["off", "low", "medium", "high", "xhigh"].contains(value.thinkingLevel) else {
            throw DesktopPeerLink.Failure.invalidMessage
        }
        return value
    }

    func generate(_ raw: String) async throws -> String {
        guard let pairing else { throw DesktopPeerLink.Failure.unavailable }
        return try await call(.init(Self.infer, payload: raw), pairing: pairing, tailscaleAddress: awayAddress, timeout: .seconds(180)).payload
    }

    private func call(_ request: DesktopPeerLink.Request, pairing: DesktopPeerLink.Pairing,
                      tailscaleAddress: String?, timeout: Duration, allowCloud: Bool = true) async throws -> (payload: String, route: DesktopPeerLink.Route) {
        let relay = allowCloud ? BananaAccount.shared.desktopRelaySocket(link: pairing.serviceName) : nil
        let response: DesktopPeerLink.Response
        let path: DesktopPeerLink.Route
        if let direct = try await DesktopPeerLink.connect(to: pairing, tailscaleAddress: tailscaleAddress, cloudFallback: relay != nil) {
            let (connection, route) = direct
            path = route
            defer { connection.cancel() }
            response = try await DesktopPeerLink.within(timeout, connection: connection) {
                try await DesktopPeerLink.send(request, to: connection)
                return try await DesktopPeerLink.read(DesktopPeerLink.Response.self, from: connection)
            }
        } else if let relay {
            path = .cloud
            response = try await DesktopCloudRelay.exchange(request, over: relay, pairing: pairing, timeout: timeout)
        } else {
            throw DesktopPeerLink.Failure.unavailable
        }
        if let error = response.error { throw DesktopPeerLink.Failure.rejected(error) }
        guard let payload = response.payload else { throw DesktopPeerLink.Failure.invalidMessage }
        return (payload, path)
    }
    #endif
}
#endif
