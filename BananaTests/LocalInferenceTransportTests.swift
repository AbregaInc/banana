import XCTest

final class LocalInferenceTransportTests: XCTestCase {
    private func input(_ messages: [[String: Any]] = [["role": "user", "text": "Hello"]]) -> [String: Any] {
        ["instructions": "Be helpful", "tools": [], "messages": messages, "reasoning": "medium", "maxTokens": 8192]
    }
    private func response(_ message: [String: Any], finish: String = "stop") -> [String: Any] {
        ["choices": [["finish_reason": finish, "message": message.merging(["role": "assistant"]) { original, _ in original }]]]
    }
    func testPreservesReasoningToolsAndFailedResults() throws {
        let request = input([
            ["role": "assistant", "content": [["type": "thinking", "thinking": "Context"], ["type": "text", "text": "Looking"],
                ["type": "toolCall", "id": "call-1", "name": "list_notes", "arguments": ["limit": 3]]]],
            ["role": "toolResult", "toolCallId": "call-1", "toolName": "list_notes", "text": "Unavailable", "isError": true],
        ])
        let payload = try LocalInferenceTransport.payload(request, serverModel: "locals/test", maxTokens: 8192)
        let messages = payload["messages"] as! [[String: Any]]
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, "Context")
        XCTAssertEqual(messages[1]["content"] as? String, "Looking")
        let calls = messages[1]["tool_calls"] as! [[String: Any]]
        XCTAssertEqual(calls[0]["id"] as? String, "call-1")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call-1")
        XCTAssertEqual(messages[2]["content"] as? String, "Tool failed: Unavailable")
    }
    func testRejectsUnsupportedInputBeforeInference() {
        XCTAssertThrowsError(try LocalInferenceTransport.payload(input([["role": "assistant", "content": [["type": "image"]]]]), serverModel: "locals/test", maxTokens: 8192))
        XCTAssertThrowsError(try LocalInferenceTransport.payload(input([["role": "unknown"]]), serverModel: "locals/test", maxTokens: 8192))
    }
    func testUsesProfileSamplingAndHonorsExplicitRequestTemperature() throws {
        var request = input()
        let profile = try LocalInferenceTransport.payload(request, serverModel: "mlx/test", maxTokens: 4096, temperature: 0.1, topP: 1, topK: 0)
        XCTAssertEqual(profile["temperature"] as? Double, 0.1)
        XCTAssertEqual(profile["top_p"] as? Double, 1)
        XCTAssertEqual(profile["top_k"] as? Int, 0)
        request["temperature"] = 0.3
        let explicit = try LocalInferenceTransport.payload(request, serverModel: "mlx/test", maxTokens: 4096, temperature: 0.1)
        XCTAssertEqual(explicit["temperature"] as? Double, 0.3)
        let original = try LocalInferenceTransport.payload(input(), serverModel: "locals/test", maxTokens: 4096)
        XCTAssertEqual(original["temperature"] as? Double, 0.6)
        XCTAssertEqual(original["top_p"] as? Double, 0.95)
        XCTAssertEqual(original["top_k"] as? Int, 20)
    }
    func testRejectsInvalidProfileSamplingBeforeInference() {
        XCTAssertThrowsError(try LocalInferenceTransport.payload(input(), serverModel: "mlx/test", maxTokens: 4096, temperature: .nan))
        XCTAssertThrowsError(try LocalInferenceTransport.payload(input(), serverModel: "mlx/test", maxTokens: 4096, topP: 0))
        XCTAssertThrowsError(try LocalInferenceTransport.payload(input(), serverModel: "mlx/test", maxTokens: 4096, topK: -1))
        var request = input(); request["temperature"] = -1.0
        XCTAssertThrowsError(try LocalInferenceTransport.payload(request, serverModel: "mlx/test", maxTokens: 4096))
    }
    func testCapsBudgetAndPassesExplicitReasoningPolicy() throws {
        var request = input()
        let medium = try LocalInferenceTransport.payload(request, serverModel: "locals/test", maxTokens: 4096)
        XCTAssertEqual(medium["max_tokens"] as? Int, 4096)
        XCTAssertEqual(medium["reasoning_effort"] as? String, "medium")
        request["reasoning"] = "off"
        let off = try LocalInferenceTransport.payload(request, serverModel: "locals/test", maxTokens: 4096)
        XCTAssertEqual(off["reasoning_effort"] as? String, "none")
        XCTAssertEqual((off["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
    }
    func testCapturesIntentWithoutExecutingAndKeepsIdentity() throws {
        let raw = try LocalInferenceTransport.content(response(["reasoning_content": "Think", "content": "Review this", "tool_calls": [
            ["id": "exact-id", "type": "function", "function": ["name": "prepare_meal_copy", "arguments": "{\"day\":\"tomorrow\",\"mealID\":\"exact-meal\"}"]],
        ]], finish: "tool_calls"))
        let content = (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any])["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as! String }, ["thinking", "text", "toolCall"])
        XCTAssertEqual(content[2]["id"] as? String, "exact-id")
        XCTAssertEqual((content[2]["arguments"] as? [String: Any])?["mealID"] as? String, "exact-meal")
    }
    func testRejectsTruncatedToolIntentEvenWhenArgumentsLookComplete() {
        XCTAssertThrowsError(try LocalInferenceTransport.content(response(["tool_calls": [["id": "x", "type": "function", "function": ["name": "create_note", "arguments": "{\"text\":\"x\"}"]]]], finish: "length")))
    }
    func testRejectsMalformedArgumentsAndReasoningWithoutAnswer() {
        for arguments in ["[]", "invalid", "null"] {
            XCTAssertThrowsError(try LocalInferenceTransport.content(response(["tool_calls": [["id": "x", "type": "function", "function": ["name": "create_note", "arguments": arguments]]]])))
        }
        XCTAssertThrowsError(try LocalInferenceTransport.content(response(["reasoning_content": "Still thinking"])))
        XCTAssertThrowsError(try LocalInferenceTransport.content(response(["content": "Done", "tool_calls": ["function": "invalid"]])))
        XCTAssertThrowsError(try LocalInferenceTransport.content(response(["content": "Done", "role": "user"])))
    }
}
