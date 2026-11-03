// An OpenAI-shaped server over Banana Pi's in-app model path, for tools/pi-evaluation:
// Pi's own Foundation Models bridge (AppleFoundationModel.swift, copied unchanged) on MLXLanguageModel.
import Foundation
import FoundationModels
import MLX
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Network
import Tokenizers

struct Bridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
struct Loader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer { Bridge(upstream: try await AutoTokenizer.from(modelFolder: directory)) }
}

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var modelPath = "", port: UInt16 = 41790
while let flag = arguments.next() {
    if flag == "--model" { modelPath = arguments.next() ?? "" }
    if flag == "--port" { port = UInt16(arguments.next() ?? "") ?? port }
}
let folder = URL(fileURLWithPath: modelPath, isDirectory: true)
let model = MLXLanguageModel(configuration: ModelConfiguration(directory: folder), capabilities: [.toolCalling, .guidedGeneration],
                             weightsLocation: { _ in folder },
                             load: { _, _ in try await loadModelContainer(from: folder, using: Loader()) })

// Load before announcing readiness, so readiness ~ load time.
let loadStart = Date()
_ = try await LanguageModelSession(model: model).respond(to: "Say ok.", options: GenerationOptions(maximumResponseTokens: 4))
FileHandle.standardError.write("loaded in \(Date().timeIntervalSince(loadStart))s\n".data(using: .utf8)!)

/// OpenAI chat payload → Pi's request; Pi's {"content": [...]} → an OpenAI response.
@MainActor func complete(_ body: [String: Any]) async throws -> [String: Any] {
    let messages = body["messages"] as? [[String: Any]] ?? []
    let instructions = messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
    let piMessages = messages.filter { $0["role"] as? String != "system" }.map { ["role": $0["role"] as? String ?? "user", "text": $0["content"] as? String ?? ""] }
    let tools = (body["tools"] as? [[String: Any]] ?? []).compactMap { $0["function"] as? [String: Any] }
    var request: [String: Any] = ["instructions": instructions, "tools": tools, "messages": piMessages]
    if let t = body["temperature"] as? Double { request["temperature"] = t }
    if let m = body["max_tokens"] as? Int { request["maxTokens"] = m }
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    let out = try await AppleFoundationModel.generate(raw) { tools, transcript in
        LanguageModelSession(model: model, tools: tools, transcript: transcript)
    }
    let content = (try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["content"] as? [[String: Any]] ?? []
    let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
    let calls: [[String: Any]] = content.filter { $0["type"] as? String == "toolCall" }.map { call in
        let args = String(decoding: (try? JSONSerialization.data(withJSONObject: call["arguments"] ?? [:])) ?? Data("{}".utf8), as: UTF8.self)
        return ["id": call["id"] as? String ?? "call", "type": "function", "function": ["name": call["name"] as? String ?? "", "arguments": args]]
    }
    var message: [String: Any] = ["role": "assistant", "content": text]
    if !calls.isEmpty { message["tool_calls"] = calls }
    return ["choices": [["index": 0, "finish_reason": calls.isEmpty ? "stop" : "tool_calls", "message": message]]]
}

func respond(_ connection: NWConnection, _ status: String, _ json: Any) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    var head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
    head.append(body)
    connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
}

func receive(_ connection: NWConnection, _ buffer: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
        var buffer = buffer; if let data { buffer.append(data) }
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { if !done { receive(connection, buffer) }; return }
        let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
        let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = buffer[split.upperBound...]
        if body.count < length && !done { receive(connection, buffer); return }
        let line = head.split(separator: "\r\n").first ?? ""
        if line.hasPrefix("GET /v1/models") { respond(connection, "200 OK", ["data": [["id": "mlx/qwen35-4b"]]]); return }
        if line.hasPrefix("GET /stats") {
            respond(connection, "200 OK", ["memory": ["gpu_peak_mb": Double(Memory.peakMemory) / 1e6, "gpu_active_mb": Double(Memory.activeMemory) / 1e6]]); return
        }
        if line.hasPrefix("POST /v1/chat/completions") {
            let json = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] ?? [:]
            Task { @MainActor in
                do { respond(connection, "200 OK", try await complete(json)) }
                catch { respond(connection, "500 Internal Server Error", ["error": ["message": String(describing: error)]]) }
            }
            return
        }
        respond(connection, "404 Not Found", ["error": ["message": "not found"]])
    }
}

let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
listener.newConnectionHandler = { connection in connection.start(queue: .main); receive(connection) }
listener.start(queue: .main)
FileHandle.standardError.write("listening on \(port)\n".data(using: .utf8)!)
while true { try await Task.sleep(for: .seconds(3600)) }
