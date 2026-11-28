#if BANANA_AI
#if os(macOS)
import CryptoKit
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
        let promptCacheGiB: Double?
        /// Preserve the legacy 2 GiB worker cache for unqualified profiles.
        var promptCacheArgument: String {
            guard let promptCacheGiB, promptCacheGiB.isFinite, promptCacheGiB > 0,
                  promptCacheGiB <= 2 else { return "2" }
            return String(promptCacheGiB)
        }
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        /// The bundled mlx-serve executable, for the `mlxserve` engine (32 GiB Macs); nil for the Python worker.
        var server: String? = nil
        var engine: String { String(serverModel.split(separator: "/", maxSplits: 1).first ?? "") }
        var usesMlxServe: Bool { engine == "mlxserve" }
        var agent: [String: Any] {
            ["modelId": modelId, "name": name, "contextWindow": contextWindow,
             "maxTokens": maxTokens, "thinkingLevel": thinkingLevel]
        }
    }
    static let shared = MacLocalInference()
    private let currentMemory: () -> MacInferenceMemory?
    private let now: () -> ContinuousClock.Instant
    private var retryAfter: ContinuousClock.Instant?
    static let memoryStopped = Notification.Name("BananaMacModelStoppedForMemory")
    init(currentMemory: @escaping () -> MacInferenceMemory? = MacInferenceMemory.current,
         now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.currentMemory = currentMemory
        self.now = now
    }
    static let directory = AppSupport.directory.appendingPathComponent("LocalInference", isDirectory: true)
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
    /// mlx-serve inside the app (Contents/Resources/MlxServe, tools/pi-mac-inference/embed-mlx-serve.sh).
    static var mlxServeExecutable: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MlxServe/mlx-serve"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
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
        guard store.state == .ready, let manifest = store.manifest else { return nil }
        let profile = manifest.profile
        var server: String?
        let python: URL
        if store.tier == .large {
            guard let executable = Self.mlxServeExecutable else { return nil }
            server = executable.path
            python = executable
        } else {
            guard let runtime = Self.runtimePython, FileManager.default.isExecutableFile(atPath: runtime.path) else { return nil }
            python = runtime
        }
        var configuration = Configuration(python: python.path, modelDirectory: PinnedModelFiles.folder(for: manifest).path,
                             modelId: profile.modelId, serverModel: profile.serverModel, name: profile.name,
                             revision: manifest.revision, port: profile.macWorkerPort, contextWindow: profile.contextWindow,
                             maxTokens: profile.maxTokens, thinkingLevel: profile.thinkingLevel,
                             promptCacheGiB: profile.promptCacheGiB, temperature: nil, topP: nil, topK: nil)
        configuration.server = server
        return configuration
    }
    struct MemoryUnavailable: LocalizedError, CustomStringConvertible {
        var description: String { "The local model is paused because this Mac needs more available memory." }
        var errorDescription: String? { description }
    }
    private var measuredWeights: (directory: String, revision: String, bytes: UInt64)?
    private func weightBytes(_ config: Configuration) -> UInt64 {
        if let cached = measuredWeights, cached.directory == config.modelDirectory,
           cached.revision == config.revision { return cached.bytes }
        // Normal builds already have a verified manifest, including the exact sizes of all shards.
        let bytes: UInt64
        if Self.verificationConfigurationURL == nil, let manifest = LocalModel.shared.manifest,
           config.revision == manifest.revision {
            bytes = manifest.files.filter { $0.key.hasSuffix(".safetensors") }
                .reduce(0) { $0 + UInt64($1.value.bytes) }
        } else {
            let dir = URL(fileURLWithPath: config.modelDirectory)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var total: UInt64 = 0
            for file in files where file.pathExtension == "safetensors" {
                guard let size = PinnedModelFiles.size(of: file), size > 0 else { return 0 }
                total += UInt64(size)
            }
            bytes = total
        }
        if bytes > 0 { measuredWeights = (config.modelDirectory, config.revision, bytes) }
        return bytes
    }
    private var pressureEvents: DispatchSourceMemoryPressure?
    private var memoryCheck: Task<Void, Never>?
    private var swapWindow = MacInferenceMemory.SwapWindow()
    private var activeGenerations = 0
    private var stopping = false
    private var stopGeneration: UInt64 = 0
    private var stoppedForMemory = false

    func memoryAllows(_ config: Configuration) -> Bool {
        if let retryAfter, now() < retryAfter { return false }
        let alive = process?.isRunning == true
        guard !(alive && stopping), let state = currentMemory() else { return false }
        return state.admits(weightBytes: alive ? 0 : weightBytes(config), resident: alive)
    }

    private func residentMemoryAllows(_ state: MacInferenceMemory?) -> Bool {
        guard let state, state.admits(weightBytes: 0, resident: true) else { return false }
        guard !ready || activeGenerations > 0 else { swapWindow.clear(); return true }
        return !swapWindow.exceedsLimit(state.swapoutBytes, at: now())
    }

    private func checkMemory(_ config: Configuration) throws {
        if stopping, process?.isRunning == true {
            if stoppedForMemory { throw MemoryUnavailable() }
            throw AssistantFailure(message: "The local inference worker is stopping. Try again.")
        }
        if process?.isRunning == true {
            guard residentMemoryAllows(currentMemory()) else { stopForMemory(); throw MemoryUnavailable() }
        } else if !memoryAllows(config) {
            stopForMemory()
            throw MemoryUnavailable()
        }
    }

    private func monitorMemory(of child: Process) {
        pressureEvents?.cancel()
        memoryCheck?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak child] in
            MainActor.assumeIsolated {
                guard let self, let child, self.process === child else { return }
                self.stopForMemory()
            }
        }
        pressureEvents = source
        source.activate()
        memoryCheck = Task { [weak self, weak child] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let child, self.process === child, child.isRunning else { return }
                guard self.residentMemoryAllows(self.currentMemory()) else {
                    self.stopForMemory()
                    return
                }
            }
        }
    }

    private func stopForMemory() {
        let shouldNotify = !stoppedForMemory
        if !stopping, process?.isRunning == true {
            retryAfter = now().advanced(by: .seconds(30))
        }
        stoppedForMemory = true
        stop(immediate: true)
        if shouldNotify { NotificationCenter.default.post(name: Self.memoryStopped, object: self) }
    }
    private(set) var configuration: Configuration?
    private var process: Process?
    private var ready = false
    /// This launch's secret, given to the worker Banana starts: every request carries it, and every
    /// answer must carry the proof made from it (pi-inference-worker.py). Another program that took
    /// the port first can do neither.
    private let workerToken: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()
    private var workerProof: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("banana-worker".utf8), using: SymmetricKey(data: Data(workerToken.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
    /// A request to the worker: its address, with this launch's secret. mlx-serve takes it as its
    /// strict API key, so it serves no request without it.
    private func workerRequest(_ config: Configuration, _ path: String) -> URLRequest {
        var request = URLRequest(url: endpoint(config, path))
        if config.usesMlxServe {
            request.setValue("Bearer \(workerToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(workerToken, forHTTPHeaderField: "X-Banana-Token")
        }
        return request
    }
    /// The answer came from the worker Banana started. mlx-serve signs no answers: the port was
    /// free before Banana started it (`portAnswers`), and it exits if it can't bind, which
    /// `requireCurrent` sees.
    private func fromOwnWorker(_ response: URLResponse) -> Bool {
        if configuration?.usesMlxServe == true { return response is HTTPURLResponse }
        guard let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Banana-Worker") else { return false }
        return value.utf8.count == workerProof.utf8.count && zip(value.utf8, workerProof.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
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
        ["available": ready, "reason": ready ? "\(configuration?.name ?? "Local model") · On this Mac" : (stoppedForMemory ? MemoryUnavailable().localizedDescription : "Local model unavailable. Try again."),
         "contextWindow": configuration?.contextWindow ?? 32768, "modelName": configuration?.name ?? "Local Mac model"]
    }

    func startIfConfigured() async throws {
        if configuration == nil {
            guard let candidate = resolvedConfiguration() else { return }
            guard (1024...65535).contains(candidate.port), candidate.contextWindow >= 4096,
                  candidate.maxTokens > 0, candidate.maxTokens < candidate.contextWindow,
                  ["off", "low", "medium", "high", "xhigh"].contains(candidate.thinkingLevel),
                  ["locals", "mlx", "mlxserve"].contains(candidate.engine), candidate.serverModel.split(separator: "/").count == 2,
                  !candidate.modelId.isEmpty,
                  (candidate.temperature ?? 0.6).isFinite, (candidate.temperature ?? 0.6) >= 0,
                  (candidate.topP ?? 0.95).isFinite, (0...1).contains(candidate.topP ?? 0.95), (candidate.topP ?? 0.95) > 0,
                  (candidate.topK ?? 20) >= 0,
                  candidate.modelDirectory.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: candidate.usesMlxServe ? (candidate.server ?? "") : candidate.python),
                  FileManager.default.fileExists(atPath: candidate.modelDirectory + "/model.safetensors.index.json") else {
                throw AssistantFailure(message: "This Mac's model isn't complete. Banana will fetch it again.")
            }
            configuration = candidate
        }
        guard let config = configuration else { return }
        try checkMemory(config)
        if ready && process?.isRunning == true { return }
        if process?.isRunning != true {
            if config.usesMlxServe { await Self.stopOrphanedServer(config) }
            let generation = stopGeneration
            let occupied = await portAnswers(config)
            try Task.checkCancellation()
            if stopGeneration != generation {
                if stoppedForMemory { throw MemoryUnavailable() }
                throw CancellationError()
            }
            // Another caller may have started our worker while the probe was suspended.
            if occupied && process?.isRunning != true {
                throw AssistantFailure(message: "Another program is using Banana's inference port. Quit it, or restart the Mac, and try again.")
            }
        }
        try checkMemory(config)
        if process?.isRunning != true {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let log = Self.directory.appendingPathComponent("engine.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let child = Process()
            if config.usesMlxServe, let server = config.server {
                // Its own HOME: mlx-serve otherwise keeps state in ~/.mlx-serve.
                let home = Self.directory.appendingPathComponent("mlx-serve-home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                child.executableURL = URL(fileURLWithPath: server)
                child.arguments = ["--model", config.modelDirectory, "--host", "127.0.0.1", "--port", String(config.port),
                    "--no-vision", "--ctx-size", String(config.contextWindow), "--max-tokens", String(config.maxTokens),
                    // The key from the environment, not argv: the process table is readable by others.
                    "--api-key-env", "BANANA_WORKER_TOKEN", "--api-key-strict"]
                child.environment = ["BANANA_WORKER_TOKEN": workerToken, "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
            } else {
                guard let worker = Bundle.main.url(forResource: "pi-inference-worker", withExtension: "py") else {
                    throw AssistantFailure(message: "The local inference worker is missing from this build.")
                }
                child.executableURL = URL(fileURLWithPath: config.python)
                // -I: only the app's own Python and packages; -B: never write inside the app.
                child.arguments = ["-I", "-B", worker.path, String(ProcessInfo.processInfo.processIdentifier), "--model", config.modelDirectory,
                    "--engines", config.engine, "--preload", config.engine, "--host", "127.0.0.1", "--port", String(config.port),
                    "--slots", "1", "--cache-gb", config.promptCacheArgument, "--max-context", String(config.contextWindow), "--max-tokens", String(config.maxTokens),
                    "--temp", String(config.temperature ?? 0.6), "--top-p", String(config.topP ?? 0.95), "--top-k", String(config.topK ?? 20)]
                child.environment = ["BANANA_WORKER_TOKEN": workerToken,
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": NSTemporaryDirectory(), "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1"]
            }
            child.standardOutput = output; child.standardError = output
            swapWindow.clear()
            guard let sample = currentMemory(), sample.admits(weightBytes: weightBytes(config), resident: false) else {
                stopForMemory(); throw MemoryUnavailable()
            }
            _ = swapWindow.exceedsLimit(sample.swapoutBytes, at: now())
            try child.run()
            if config.usesMlxServe {
                try? Data("\(child.processIdentifier)".utf8).write(to: Self.serverPIDFile, options: .atomic)
            }
            process = child
            ready = false
            stopping = false
            stoppedForMemory = false
            monitorMemory(of: child)
        }
        guard let child = process else { throw MemoryUnavailable() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try requireCurrent(child)
            if let ids = try? await models(config) {
                try requireCurrent(child)
                try checkMemory(config)
                // mlx-serve serves the one folder it was given, under its own name for it.
                guard config.usesMlxServe ? !ids.isEmpty : ids.contains(config.serverModel) else {
                    stop()
                    throw AssistantFailure(message: "The local worker loaded a different model than this build expects. Update Banana and try again.")
                }
                ready = true
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try requireCurrent(child)
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
        guard ready, let child = process, let config = configuration, input["modelId"] as? String == config.modelId else {
            throw AssistantFailure(message: "The requested local model is not configured on this Mac.")
        }
        activeGenerations += 1
        defer {
            activeGenerations -= 1
            if activeGenerations == 0 { swapWindow.clear() }
        }
        try checkMemory(config)
        var request = workerRequest(config, "/v1/chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: LocalInferenceTransport.payload(input, serverModel: config.serverModel, maxTokens: config.maxTokens,
            temperature: config.temperature ?? 0.6, topP: config.topP ?? 0.95, topK: config.topK ?? 20,
            backend: config.usesMlxServe ? .mlxServe : .worker), options: .sortedKeys)
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            try requireCurrent(child)
            try checkMemory(config)
            guard fromOwnWorker(response) else {
                ready = false
                throw AssistantFailure(message: "Something other than Banana's own worker answered on its inference port.")
            }
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
            try Task.checkCancellation()
            try requireCurrent(child)
            if let failure = error as? URLError, failure.code != .cancelled { ready = false }
            throw error
        }
    }

    private func requireCurrent(_ child: Process) throws {
        if stoppedForMemory { throw MemoryUnavailable() }
        guard process === child, child.isRunning, !stopping else {
            throw AssistantFailure(message: "The local inference worker stopped. Try again.")
        }
    }

    func stop() { stop(immediate: false) }

    private func stop(immediate: Bool) {
        stopGeneration &+= 1
        pressureEvents?.cancel()
        pressureEvents = nil
        memoryCheck?.cancel()
        memoryCheck = nil
        ready = false
        guard let child = process, child.isRunning else { return }
        stopping = true
        // Keep the Process until it exits. No replacement can be started while this child
        // holds the port. A memory stop must release a busy native inference kernel promptly.
        if immediate {
            kill(child.processIdentifier, SIGKILL)
        } else {
            child.terminate()
            Task { [weak self, weak child] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let child, self.process === child, self.stopping, child.isRunning else { return }
                kill(child.processIdentifier, SIGKILL)
            }
        }
    }
    #if DEBUG
    func activeRequestCount() async throws -> Int {
        guard let config = configuration else { return 0 }
        let (data, response) = try await session.data(for: workerRequest(config, "/stats"))
        guard fromOwnWorker(response) else { throw AssistantFailure(message: "Cannot inspect the local inference worker.") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let active = json["active"] as? [Any] else {
            throw AssistantFailure(message: "Cannot inspect the local inference worker.")
        }
        return active.count
    }
    #endif
    /// mlx-serve doesn't watch its parent like the Python worker does, so a crash would leave it
    /// holding ~13.5 GB. The next start stops one left behind, only if it is this build's binary.
    static let serverPIDFile = directory.appendingPathComponent("mlx-serve.pid")
    private static func stopOrphanedServer(_ config: Configuration) async {
        guard let server = config.server,
              let text = try? String(contentsOf: serverPIDFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        try? FileManager.default.removeItem(at: serverPIDFile)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == URL(fileURLWithPath: server).resolvingSymlinksInPath().path else { return }
        kill(pid, SIGKILL)
        // Let it release the port before the port check.
        for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(50)) }
    }
    private func endpoint(_ config: Configuration, _ path: String) -> URL { URL(string: "http://127.0.0.1:\(config.port)\(path)")! }
    /// Something answers on the port at all (without sending it anything of the person's).
    private func portAnswers(_ config: Configuration) async -> Bool {
        var request = URLRequest(url: endpoint(config, "/v1/models")); request.timeoutInterval = 2
        return (try? await session.data(for: request)) != nil
    }
    private func models(_ config: Configuration) async throws -> [String] {
        var request = workerRequest(config, "/v1/models"); request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        guard fromOwnWorker(response), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = json["data"] as? [[String: Any]] else {
            throw AssistantFailure(message: "The local inference worker is not ready.")
        }
        return models.compactMap { $0["id"] as? String }
    }
}
#endif

#endif
