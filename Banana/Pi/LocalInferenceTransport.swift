import Foundation

/// Pure OpenAI chat protocol translation. No native app capability is reachable here.
enum LocalInferenceTransport {
    static func payload(_ request: [String: Any], serverModel: String, maxTokens: Int,
                        temperature: Double = 0.6, topP: Double = 0.95, topK: Int = 20) throws -> [String: Any] {
        let temperature = request["temperature"] as? Double ?? temperature
        guard temperature.isFinite, temperature >= 0, topP.isFinite, topP > 0, topP <= 1, topK >= 0 else {
            throw AssistantFailure(message: "Invalid local sampling settings.")
        }
        guard let instructions = request["instructions"] as? String,
              let tools = request["tools"] as? [[String: Any]],
              let source = request["messages"] as? [[String: Any]] else {
            throw AssistantFailure(message: "Invalid local inference request.")
        }
        var messages: [[String: Any]] = [["role": "system", "content": instructions]]
        for item in source {
            switch item["role"] as? String {
            case "user":
                guard let text = item["text"] as? String else { throw AssistantFailure(message: "Invalid user message.") }
                messages.append(["role": "user", "content": text])
            case "assistant":
                guard let content = item["content"] as? [[String: Any]] else { throw AssistantFailure(message: "Invalid assistant message.") }
                var texts: [String] = [], thoughts: [String] = [], calls: [[String: Any]] = []
                for part in content {
                    switch part["type"] as? String {
                    case "text": texts.append(try string(part["text"]))
                    case "thinking": thoughts.append(try string(part["thinking"]))
                    case "toolCall":
                        guard let args = part["arguments"] as? [String: Any] else { throw AssistantFailure(message: "Invalid tool arguments.") }
                        let raw = String(decoding: try JSONSerialization.data(withJSONObject: args, options: .sortedKeys), as: UTF8.self)
                        calls.append(["id": try string(part["id"]), "type": "function", "function": ["name": try string(part["name"]), "arguments": raw]])
                    default: throw AssistantFailure(message: "Unsupported local model input block.")
                    }
                }
                var message: [String: Any] = ["role": "assistant", "content": texts.joined(separator: "\n")]
                if !thoughts.isEmpty { message["reasoning_content"] = thoughts.joined(separator: "\n") }
                if !calls.isEmpty { message["tool_calls"] = calls }
                messages.append(message)
            case "toolResult":
                let text = try string(item["text"])
                messages.append(["role": "tool", "tool_call_id": try string(item["toolCallId"]),
                                 "content": (item["isError"] as? Bool == true ? "Tool failed: " : "") + text])
            default: throw AssistantFailure(message: "Unsupported local model message role.")
            }
        }
        let reasoning = request["reasoning"] as? String ?? "off"
        guard ["off", "minimal", "low", "medium", "high", "xhigh"].contains(reasoning) else {
            throw AssistantFailure(message: "Unsupported local reasoning effort.")
        }
        let budget = request["maxTokens"] as? Int ?? maxTokens
        guard budget > 0 else { throw AssistantFailure(message: "Invalid response budget.") }
        var result: [String: Any] = ["model": serverModel, "messages": messages, "stream": false,
            "max_tokens": min(budget, maxTokens), "temperature": temperature,
            "top_p": topP, "top_k": topK, "reasoning_effort": reasoning == "off" ? "none" : reasoning,
            "chat_template_kwargs": ["enable_thinking": reasoning != "off", "preserve_thinking": true]]
        if !tools.isEmpty {
            result["tools"] = try tools.map { tool -> [String: Any] in
                guard let parameters = tool["parameters"] as? [String: Any] else { throw AssistantFailure(message: "Missing tool parameters.") }
                return ["type": "function", "function": ["name": try string(tool["name"]), "description": try string(tool["description"]), "parameters": parameters]]
            }
            result["tool_choice"] = "auto"
            // View mutations share one captured revision. Request one intent per
            // generation; Pi can continue with another tool round when required.
            result["parallel_tool_calls"] = false
        }
        return result
    }

    static func content(_ response: [String: Any]) throws -> String {
        guard let choices = response["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, let message = choice["message"] as? [String: Any], message["role"] as? String == "assistant",
              let finish = choice["finish_reason"] as? String, ["stop", "tool_calls"].contains(finish) else {
            throw AssistantFailure(message: "The local model did not finish its answer. No tool intent was accepted.")
        }
        if let calls = message["tool_calls"], !(calls is NSNull), !(calls is [[String: Any]]) {
            throw AssistantFailure(message: "The local model returned malformed tool calls.")
        }
        if let text = message["content"], !(text is NSNull), !(text is String) {
            throw AssistantFailure(message: "The local model returned unsupported response content.")
        }
        var content: [[String: Any]] = []
        if let thought = message["reasoning_content"] as? String, !thought.isEmpty { content.append(["type": "thinking", "thinking": thought]) }
        if let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.append(["type": "text", "text": text]) }
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            guard call["type"] as? String == "function", let function = call["function"] as? [String: Any], let raw = function["arguments"] as? String,
                  let args = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw AssistantFailure(message: "The local model returned malformed tool arguments.")
            }
            content.append(["type": "toolCall", "id": try string(call["id"]), "name": try string(function["name"]), "arguments": args])
        }
        guard content.contains(where: { $0["type"] as? String != "thinking" }) else {
            throw AssistantFailure(message: "The local model returned reasoning without an answer.")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["content": content]), as: UTF8.self)
    }

    private static func string(_ value: Any?) throws -> String {
        guard let text = value as? String else { throw AssistantFailure(message: "Missing local model text field.") }
        return text
    }
}
