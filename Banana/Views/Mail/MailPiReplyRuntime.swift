#if !BANANA_PUBLIC
import Foundation

// The app-only half of MailPiReply: the model choice and the dedicated Pi runtime. The pure half
// (tools, outcome) is in MailPiReply.swift, which the unit tests also compile.
#if BANANA_AI
extension MailAIModel {
    /// The local Mac model when it is configured and memory admits it, else Apple's on-device model.
    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    static func current() -> MailAIModel {
        #if os(macOS)
        LocalModel.shared.start()
        if let config = MacLocalInference.shared.resolvedConfiguration(), MacLocalInference.shared.memoryAllows(config) {
            return MailAIModel(provider: "mac-local", modelId: config.modelId, contextWindow: config.contextWindow,
                         maxTokens: config.maxTokens, generate: { try await MacLocalInference.shared.generate($0) })
        }
        #endif
        return MailAIModel(provider: "apple-foundation", generate: { try await AppleFoundationModel.generate($0) })
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension MailPiReply {
    private final class Pending {
        var continuation: CheckedContinuation<String, Error>?
        func resume(_ result: Result<String, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    /// Run one reply on a dedicated Pi runtime (own JavaScriptCore context, temporary database path).
    @MainActor
    static func run(task: String, email: Email, tools: Tools, model: MailAIModel, thinking: MailAIThinking = .off,
                    reasoningBudget: Int? = nil, checkAccess: @escaping () throws -> Void = {}) async throws -> MailAIOutcome {
        guard let bootstrap = Bundle.main.url(forResource: "pi-bootstrap", withExtension: "js"),
              let script = Bundle.main.url(forResource: "pi-mail", withExtension: "js") else {
            throw Failure(message: "The mail assistant is unavailable.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = Pending()
        let host = try AppleRuntimeHost(databasePath: directory.appendingPathComponent("pi.sqlite").path) { text, _ in
            pending.resume(.failure(Failure(message: text)))
        }
        defer { host.stop() }
        let passages = Passages()
        host.toolHandler = { raw in
            let result = try await handle(raw, tools: tools, passages: passages)
            return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        }
        // An access failure ends the reply with that error, not a model failure.
        var denied: Error?
        host.modelHandler = { raw in
            do { try checkAccess() } catch { denied = error; throw error }
            let answer = try await model.generate(raw)
            do { try checkAccess() } catch { denied = error; throw error }
            return answer
        }
        try host.load(bootstrap: bootstrap, script: script)
        var request: [String: Any] = [
            "task": task, "provider": model.provider, "thinking": thinking.rawValue, "toolChoice": "required",
            "email": ["subject": String(email.subject.prefix(300)), "from": email.from, "fromName": email.fromName as Any,
                      "account": email.account, "to": email.to, "cc": email.cc, "email": String(email.text.prefix(2400))],
        ]
        if let id = model.modelId { request["modelId"] = id }
        if let window = model.contextWindow { request["contextWindow"] = window }
        if let tokens = model.maxTokens { request["maxTokens"] = tokens }
        if let reasoningBudget, thinking != .off { request["reasoningBudget"] = reasoningBudget }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        guard let function = host.context.objectForKeyedSubscript("bananaMailReply"), !function.isUndefined else {
            throw Failure(message: "The mail assistant is unavailable.")
        }
        let raw: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                let done: @convention(block) (String) -> Void = { pending.resume(.success($0)) }
                function.call(withArguments: [json, done])
            }
        } onCancel: {
            Task { @MainActor in host.stop(); pending.resume(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        if let denied { throw denied }
        guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw Failure(message: "Banana couldn’t write that")
        }
        return try decode(object)
    }
}
#endif
#endif
