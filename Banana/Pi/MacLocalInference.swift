#if BANANA_AI
#if os(macOS) && PI_DEVELOPMENT
import Foundation

/// Owns a loopback-only inference worker; Pi and all application effects stay in Banana.
///
/// Everything it runs is the app's own: Python, Locals and the pinned packages inside the app
/// (Contents/Resources/PiRuntime, tools/pi-mac-inference/build-runtime.sh) and the model files
/// `LocalModel` downloads and checks. Nothing to install or configure.
@MainActor
final class MacLocalInference {
    struct Configuration: Codable {
        let python: String
        let modelDirectory: String
        let modelId: String
        let serverModel: String
        let name: String
        let revision: String
        let port: Int
        let contextWindow: Int
        let maxTokens: Int
        let thinkingLevel: String
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        var engine: String { String(serverModel.split(separator: "/", maxSplits: 1).first ?? "") }
        var agent: [String: Any] {
            ["modelId": modelId, "name": name, "contextWindow": contextWindow,
             "maxTokens": maxTokens, "thinkingLevel": thinkingLevel]
        }
    }
    static let shared = MacLocalInference()
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Banana Pi/LocalInference", isDirectory: true)
    /// A verification run may name another profile to qualify (`--assistant-inference-configuration`).
    static var verificationConfigurationURL: URL? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if AppSupport.isPiVerification, let index = args.firstIndex(of: "--assistant-inference-configuration"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1])
        }
        #endif
        return nil
    }
    /// Python inside the app.
    static var runtimePython: URL? { Bundle.main.resourceURL?.appendingPathComponent("PiRuntime/bin/python3") }

    /// The app's own model once `LocalModel` has its files ready; nil until then (Pi uses Apple's).
    func resolvedConfiguration() -> Configuration? {
        if let configuration { return configuration }
        if let url = Self.verificationConfigurationURL {
            return try? JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        }
        let store = LocalModel.shared
        guard store.state == .ready, let manifest = store.manifest, let python = Self.runtimePython,
              FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        let profile = manifest.profile
        return Configuration(python: python.path, modelDirectory: PinnedModelFiles.folder(for: manifest).path,
                             modelId: profile.modelId, serverModel: profile.serverModel, name: profile.name,
                             revision: manifest.revision, port: profile.port, contextWindow: profile.contextWindow,
                             maxTokens: profile.maxTokens, thinkingLevel: profile.thinkingLevel,
                             temperature: nil, topP: nil, topK: nil)
    }
    private(set) var configuration: Configuration?
    private var process: Process?
    private var ready = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()
    var status: [String: Any] {
        ["available": ready, "reason": ready ? "\(configuration?.name ?? "Local model") · On this Mac" : "Local model unavailable. Try again.",
         "contextWindow": configuration?.contextWindow ?? 32768, "modelName": configuration?.name ?? "Local Mac model"]
    }

    func startIfConfigured() async throws {
        if configuration == nil {
            guard let candidate = resolvedConfiguration() else { return }
            guard (1024...65535).contains(candidate.port), candidate.contextWindow >= 4096,
                  candidate.maxTokens > 0, candidate.maxTokens < candidate.contextWindow,
                  ["off", "low", "medium", "high", "xhigh"].contains(candidate.thinkingLevel),
                  ["locals", "mlx"].contains(candidate.engine), candidate.serverModel.split(separator: "/").count == 2,
                  !candidate.modelId.isEmpty,
                  (candidate.temperature ?? 0.6).isFinite, (candidate.temperature ?? 0.6) >= 0,
                  (candidate.topP ?? 0.95).isFinite, (0...1).contains(candidate.topP ?? 0.95), (candidate.topP ?? 0.95) > 0,
                  (candidate.topK ?? 20) >= 0,
                  candidate.modelDirectory.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: candidate.python),
                  FileManager.default.fileExists(atPath: candidate.modelDirectory + "/model.safetensors.index.json") else {
                throw AssistantFailure(message: "This Mac's model isn't complete. Banana Pi will fetch it again.")
            }
            configuration = candidate
        }
        guard let config = configuration else { return }
        if ready && (process == nil || process?.isRunning == true) { return }
        if let ids = try? await models(config) {
            guard ids.contains(config.serverModel) else { throw AssistantFailure(message: "Another model is using Banana Pi's inference port.") }
            ready = true
            return
        }
        if process?.isRunning != true {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let log = Self.directory.appendingPathComponent("engine.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            guard let worker = Bundle.main.url(forResource: "pi-inference-worker", withExtension: "py") else {
                throw AssistantFailure(message: "The local inference worker is missing from this build.")
            }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: config.python)
            // -I: only the app's own Python and packages; -B: never write inside the app.
            child.arguments = ["-I", "-B", worker.path, String(ProcessInfo.processInfo.processIdentifier), "--model", config.modelDirectory,
                "--engines", config.engine, "--preload", config.engine, "--host", "127.0.0.1", "--port", String(config.port),
                "--slots", "1", "--cache-gb", "2", "--max-context", String(config.contextWindow), "--max-tokens", String(config.maxTokens),
                "--temp", String(config.temperature ?? 0.6), "--top-p", String(config.topP ?? 0.95), "--top-k", String(config.topK ?? 20)]
            child.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": NSTemporaryDirectory(), "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1"]
            child.standardOutput = output; child.standardError = output
            try child.run()
            try output.close()
            process = child
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process?.isRunning == true else { throw AssistantFailure(message: "The local inference worker stopped. See Banana Pi/LocalInference/engine.log.") }
            if let ids = try? await models(config) {
                guard ids.contains(config.serverModel) else {
                    stop()
                    throw AssistantFailure(message: "The local worker loaded a different model than this build expects. Update Banana Pi and try again.")
                }
                ready = true
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw AssistantFailure(message: "The local model did not become ready within four minutes.")
    }

    func generate(_ raw: String) async throws -> String {
        guard let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw AssistantFailure(message: "Invalid local inference request.")
        }
        if input["backend"] == nil { return try await AppleFoundationModel.generate(raw) }
        guard input["backend"] as? String == "mac-local" else {
            throw AssistantFailure(message: "Unsupported inference backend. No fallback was used.")
        }
        try await startIfConfigured()
        guard ready, let config = configuration, input["modelId"] as? String == config.modelId else {
            throw AssistantFailure(message: "The requested local model is not configured on this Mac.")
        }
        var request = URLRequest(url: endpoint(config, "/v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: LocalInferenceTransport.payload(input, serverModel: config.serverModel, maxTokens: config.maxTokens,
            temperature: config.temperature ?? 0.6, topP: config.topP ?? 0.95, topK: config.topK ?? 20), options: .sortedKeys)
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AssistantFailure(message: "Invalid response from the local inference worker.")
            }
            guard http.statusCode == 200 else {
                let error = json["error"] as? [String: Any]
                throw AssistantFailure(message: "Local inference (\(http.statusCode)): \(error?["message"] as? String ?? "Request failed")")
            }
            #if DEBUG
            if AppSupport.isPiVerification {
                let trace = AppSupport.directory.appendingPathComponent("model-turns.jsonl")
                let elapsed = started.duration(to: .now).components
                let record: [String: Any] = ["request": input, "response": json,
                    "verificationRun": AssistantVerification.runIdentifier,
                    "transportMilliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                    "requestBytes": request.httpBody?.count ?? 0]
                var line = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
                line.append(10)
                if !FileManager.default.fileExists(atPath: trace.path) { FileManager.default.createFile(atPath: trace.path, contents: nil) }
                let file = try FileHandle(forWritingTo: trace)
                try file.seekToEnd(); try file.write(contentsOf: line); try file.close()
            }
            #endif
            return try LocalInferenceTransport.content(json)
        } catch {
            if let failure = error as? URLError, failure.code != .cancelled { ready = false }
            throw error
        }
    }

    func stop() {
        ready = false
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
    #if DEBUG
    func activeRequestCount() async throws -> Int {
        guard let config = configuration else { return 0 }
        let (data, _) = try await session.data(from: endpoint(config, "/stats"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let active = json["active"] as? [Any] else {
            throw AssistantFailure(message: "Cannot inspect the local inference worker.")
        }
        return active.count
    }
    #endif
    private func endpoint(_ config: Configuration, _ path: String) -> URL { URL(string: "http://127.0.0.1:\(config.port)\(path)")! }
    private func models(_ config: Configuration) async throws -> [String] {
        var request = URLRequest(url: endpoint(config, "/v1/models")); request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = json["data"] as? [[String: Any]] else {
            throw AssistantFailure(message: "The local inference worker is not ready.")
        }
        return models.compactMap { $0["id"] as? String }
    }
}
#endif

#endif
