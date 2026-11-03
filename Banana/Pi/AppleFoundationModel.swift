import Foundation
import FoundationModels

private struct AppleProviderFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Deliberately stops Apple's automatic tool loop before any application capability runs.
private struct ReturnToolIntentToPi: Error {}

/// A session's respond(to:) always appends a prompt, but Pi may be continuing
/// directly from a committed tool result. Forward that continuation unchanged to
/// Apple's executor instead of inserting an extra user turn into model history.
@available(iOS 27.0, macOS 27.0, *)
private struct PiSystemLanguageModel: LanguageModel {
    var capabilities: LanguageModelCapabilities { SystemLanguageModel.default.capabilities }
    var executorConfiguration: SystemLanguageModel.Executor.Configuration { SystemLanguageModel.default.executorConfiguration }
    struct Executor: LanguageModelExecutor {
        typealias Model = PiSystemLanguageModel
        let native: SystemLanguageModel.Executor
        init(configuration: SystemLanguageModel.Executor.Configuration) { native = .init(configuration: configuration) }
        func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            var request = request
            let entries = Array(request.transcript)
            if entries.count >= 2, case .prompt(let prompt) = entries.last,
               prompt.segments.allSatisfy({ if case .text(let text) = $0 { return text.content.isEmpty }; return false }),
               case .toolOutput = entries[entries.count - 2] {
                request.transcript = FoundationModels.Transcript(entries: entries.dropLast())
            }
            try await native.respond(to: request, model: SystemLanguageModel.default, streamingInto: channel)
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct IntentOnlyTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    func call(arguments: GeneratedContent) async throws -> String { throw ReturnToolIntentToPi() }
}

@available(iOS 26.0, macOS 26.0, *)
enum AppleFoundationModel {
    static func availability() -> [String: Any] {
        let model = SystemLanguageModel.default
        guard #available(iOS 27.0, macOS 27.0, *) else {
            return ["available": false, "reason": "requiresOS27", "contextWindow": model.contextSize]
        }
        return ["available": model.availability == .available, "reason": String(describing: model.availability),
                "contextWindow": model.contextSize]
    }

    // Fail closed on unsupported JSON Schema features. Pi still validates actual tool arguments.
    static func schema(_ json: [String: Any], name: String, depth: Int = 0) throws -> DynamicGenerationSchema {
        guard depth < 20 else { throw AppleProviderFailure("Tool schema exceeds nesting limit") }
        let common: Set<String> = ["type", "description", "title", "$schema", "additionalProperties"]
        let type = json["type"] as? String
        var allowed = common
        switch type {
        case "object": allowed.formUnion(["properties", "required"])
        case "array": allowed.insert("items")
        case "string": allowed.insert("enum")
        case "number", "integer", "boolean": break
        default: throw AppleProviderFailure("Unsupported tool schema type at \(name)")
        }
        guard Set(json.keys).isSubset(of: allowed) else { throw AppleProviderFailure("Unsupported schema keywords at \(name): \(Set(json.keys).subtracting(allowed).sorted())") }
        if let additional = json["additionalProperties"], !(additional is Bool && (additional as? Bool) == false) {
            throw AppleProviderFailure("Open object schemas are unsupported at \(name)")
        }
        switch type {
        case "object":
            guard let properties = json["properties"] as? [String: [String: Any]] else { throw AppleProviderFailure("Missing object properties at \(name)") }
            if let required = json["required"], !(required is [String]) { throw AppleProviderFailure("Invalid required list at \(name)") }
            let required = Set(json["required"] as? [String] ?? [])
            guard required.isSubset(of: Set(properties.keys)) else { throw AppleProviderFailure("Unknown required property at \(name)") }
            return DynamicGenerationSchema(name: name, description: json["description"] as? String,
                properties: try properties.keys.sorted().map { key in
                    .init(name: key, description: properties[key]?["description"] as? String,
                          schema: try schema(properties[key]!, name: name + "_" + key, depth: depth + 1), isOptional: !required.contains(key))
                })
        case "array":
            guard let items = json["items"] as? [String: Any] else { throw AppleProviderFailure("Missing array items at \(name)") }
            return DynamicGenerationSchema(arrayOf: try schema(items, name: name + "_item", depth: depth + 1))
        case "string":
            if let choices = json["enum"] {
                guard let choices = choices as? [String], !choices.isEmpty else { throw AppleProviderFailure("Invalid string enum at \(name)") }
                return DynamicGenerationSchema(name: name, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: throw AppleProviderFailure("Unsupported tool schema")
        }
    }

    private static func text(_ value: Any?) throws -> String {
        guard let value = value as? String else { throw AppleProviderFailure("Expected text in model request") }
        return value
    }
    private static func segment(_ text: String) -> FoundationModels.Transcript.Segment { .text(.init(content: text)) }

    @MainActor
    static func generate(_ request: String,
                         makeSession: (([any Tool], FoundationModels.Transcript) -> LanguageModelSession)? = nil) async throws -> String {
        try Task.checkCancellation()
        guard makeSession != nil || SystemLanguageModel.default.availability == .available else {
            throw AppleProviderFailure("On-device model unavailable: \(SystemLanguageModel.default.availability)")
        }
        guard let request = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
              let declarations = request["tools"] as? [[String: Any]], let messages = request["messages"] as? [[String: Any]] else {
            throw AppleProviderFailure("Invalid Apple model request")
        }
        if #unavailable(iOS 27.0, macOS 27.0), !declarations.isEmpty {
            throw AppleProviderFailure("Reliable Apple tool continuation requires iOS or macOS 27 or later.")
        }
        let tools: [IntentOnlyTool] = try declarations.map { tool in
            let name = try text(tool["name"])
            guard let parameters = tool["parameters"] as? [String: Any] else { throw AppleProviderFailure("Missing parameters for \(name)") }
            return IntentOnlyTool(name: name, description: try text(tool["description"]),
                                  parameters: try GenerationSchema(root: schema(parameters, name: name), dependencies: []))
        }
        var entries: [FoundationModels.Transcript.Entry] = [.instructions(.init(segments: [segment(try text(request["instructions"]))],
            toolDefinitions: tools.map { FoundationModels.Transcript.ToolDefinition(tool: $0) }))]
        var prompt = ""
        for (index, message) in messages.enumerated() {
            switch try text(message["role"]) {
            case "user":
                let content = try text(message["text"])
                if index == messages.count - 1 { prompt = content }
                else { entries.append(.prompt(.init(segments: [segment(content)]))) }
            case "assistant":
                guard let content = message["content"] as? [[String: Any]] else { throw AppleProviderFailure("Invalid assistant content") }
                // Preserve text/tool ordering, grouping consecutive tool calls into one entry.
                var calls: [FoundationModels.Transcript.ToolCall] = []
                func flush() { if !calls.isEmpty { entries.append(.toolCalls(.init(calls))); calls.removeAll() } }
                for part in content {
                    switch try text(part["type"]) {
                    case "text":
                        flush()
                        entries.append(.response(.init(assetIDs: [], segments: [segment(try text(part["text"]))])))
                    case "toolCall":
                        guard let arguments = part["arguments"] as? [String: Any] else { throw AppleProviderFailure("Invalid tool arguments") }
                        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                        calls.append(.init(id: try text(part["id"]), toolName: try text(part["name"]), arguments: try GeneratedContent(json: json)))
                    default: throw AppleProviderFailure("Unsupported assistant block")
                    }
                }
                flush()
            case "toolResult":
                let value = try text(message["text"])
                let output = (message["isError"] as? Bool) == true ? "Tool failed: " + value : value
                entries.append(.toolOutput(.init(id: try text(message["toolCallId"]), toolName: try text(message["toolName"]), segments: [segment(output)])))
            default: throw AppleProviderFailure("Unsupported transcript role")
            }
        }
        let session: LanguageModelSession
        if let makeSession {
            session = makeSession(tools, FoundationModels.Transcript(entries: entries))
            if #available(iOS 27.0, macOS 27.0, *) { session.transcriptErrorHandlingPolicy = .preserveTranscript }
        } else if #available(iOS 27.0, macOS 27.0, *) {
            session = LanguageModelSession(model: PiSystemLanguageModel(), tools: tools, transcript: FoundationModels.Transcript(entries: entries))
            session.transcriptErrorHandlingPolicy = .preserveTranscript
        } else {
            session = LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: FoundationModels.Transcript(entries: entries))
        }
        let start = session.transcript.endIndex
        let options = GenerationOptions(temperature: request["temperature"] as? Double, maximumResponseTokens: request["maxTokens"] as? Int)
        do {
            let response = try await session.respond(to: prompt, options: options)
            try Task.checkCancellation()
            return try encoded([["type": "text", "text": response.content]])
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is ReturnToolIntentToPi {
            try Task.checkCancellation()
            var content: [[String: Any]] = []
            var hasToolIntent = false
            for entry in session.transcript.dropFirst(start) {
                if case .toolCalls(let calls) = entry {
                    hasToolIntent = true
                    for call in calls {
                        let arguments = try JSONSerialization.jsonObject(with: Data(call.arguments.jsonString.utf8))
                        content.append(["type": "toolCall", "id": call.id, "name": call.toolName, "arguments": arguments])
                    }
                } else if case .response(let response) = entry {
                    for segment in response.segments {
                        guard case .text(let text) = segment else { throw AppleProviderFailure("Unsupported generated response segment") }
                        if !text.content.isEmpty { content.append(["type": "text", "text": text.content]) }
                    }
                }
            }
            guard hasToolIntent else { throw AppleProviderFailure("Apple discarded tool intent after capture; refusing to execute") }
            return try encoded(content)
        } catch {
            if #available(iOS 27.0, macOS 27.0, *), let failure = error as? LanguageModelError,
               case .contextSizeExceeded = failure {
                // Pi's public provider protocol classifies overflow from this
                // conventional error marker and runs its existing compaction path.
                throw AppleProviderFailure("context_length_exceeded: The conversation exceeds the context window. Summarize the context or start a new conversation.")
            }
            throw error
        }
    }

    private static func encoded(_ content: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["content": content]), as: UTF8.self)
    }
}
