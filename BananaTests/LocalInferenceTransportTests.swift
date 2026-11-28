import XCTest

final class LocalInferenceTransportTests: XCTestCase {
    private func input(_ messages: [[String: Any]] = [["role": "user", "text": "Hello"]]) -> [String: Any] {
        ["instructions": "Be helpful", "tools": [], "messages": messages, "reasoning": "medium", "maxTokens": 8192]
    }
    private func response(_ message: [String: Any], finish: String = "stop") -> [String: Any] {
        ["choices": [["finish_reason": finish, "message": message.merging(["role": "assistant"]) { original, _ in original }]]]
    }
    func testPairedTransportRequiresTheGrantedRecipientAndKeepsItsMarkerLocal() throws {
        let message = #"{"pairedRecipient":"fixture-peer","messages":[{"role":"user","text":"hello"}]}"#
        let payload = try LocalInferenceTransport.pairedPayload(message, recipient: "fixture-peer")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertNil(parsed["pairedRecipient"])
        XCTAssertEqual((parsed["messages"] as? [[String: String]])?.first?["text"], "hello")
        XCTAssertThrowsError(try LocalInferenceTransport.pairedPayload(message, recipient: "another-peer"))
        XCTAssertThrowsError(try LocalInferenceTransport.pairedPayload(#"{"messages":[]}"#, recipient: "fixture-peer"))
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
    private var tool: [String: Any] {
        ["name": "write_reply", "description": "Write the reply", "parameters": ["type": "object", "properties": [:]]]
    }
    func testRequiredToolChoiceReachesBothBackends() throws {
        var request = input(); request["tools"] = [tool]; request["toolChoice"] = "required"
        for backend in [LocalInferenceTransport.Backend.worker, .mlxServe] {
            let payload = try LocalInferenceTransport.payload(request, serverModel: "mlxserve/test", maxTokens: 4096, backend: backend)
            XCTAssertEqual(payload["tool_choice"] as? String, "required")
        }
        request["toolChoice"] = nil
        XCTAssertEqual(try LocalInferenceTransport.payload(request, serverModel: "locals/test", maxTokens: 4096)["tool_choice"] as? String, "auto")
    }
    func testRejectsUnknownOrToollessToolChoice() {
        var request = input(); request["tools"] = [tool]; request["toolChoice"] = "none"
        XCTAssertThrowsError(try LocalInferenceTransport.payload(request, serverModel: "locals/test", maxTokens: 4096))
        var toolless = input(); toolless["toolChoice"] = "required"
        XCTAssertThrowsError(try LocalInferenceTransport.payload(toolless, serverModel: "locals/test", maxTokens: 4096))
    }
    func testMlxServeGetsTopLevelThinkingControls() throws {
        var request = input(); request["reasoning"] = "off"
        let off = try LocalInferenceTransport.payload(request, serverModel: "mlxserve/test", maxTokens: 4096, backend: .mlxServe)
        XCTAssertEqual(off["enable_thinking"] as? Bool, false)
        XCTAssertEqual(off["reasoning_effort"] as? String, "none")
        XCTAssertNil(off["chat_template_kwargs"])
        XCTAssertNil(off["reasoning_budget_tokens"])
        request["reasoning"] = "low"; request["reasoningBudget"] = 512
        let low = try LocalInferenceTransport.payload(request, serverModel: "mlxserve/test", maxTokens: 4096, backend: .mlxServe)
        XCTAssertEqual(low["enable_thinking"] as? Bool, true)
        XCTAssertEqual(low["reasoning_effort"] as? String, "low")
        XCTAssertEqual(low["reasoning_budget_tokens"] as? Int, 512)
        request["reasoningBudget"] = 0
        XCTAssertThrowsError(try LocalInferenceTransport.payload(request, serverModel: "mlxserve/test", maxTokens: 4096, backend: .mlxServe))
    }
    func testWorkerKeepsChatTemplateThinkingControls() throws {
        var request = input(); request["reasoningBudget"] = 512
        let payload = try LocalInferenceTransport.payload(request, serverModel: "locals/test", maxTokens: 4096)
        XCTAssertEqual((payload["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, true)
        XCTAssertNil(payload["enable_thinking"])
        XCTAssertNil(payload["reasoning_budget_tokens"])
    }
    func testMacTierNeedsThirtyTwoGiBAndTheLargeEngine() {
        let gib: UInt64 = 1 << 30
        XCTAssertEqual(MacInferenceTier.select(physicalBytes: 32 * gib, supportsLargeEngine: true), .large)
        XCTAssertEqual(MacInferenceTier.select(physicalBytes: 64 * gib, supportsLargeEngine: true), .large)
        XCTAssertEqual(MacInferenceTier.select(physicalBytes: 24 * gib, supportsLargeEngine: true), .compact)
        XCTAssertEqual(MacInferenceTier.select(physicalBytes: 64 * gib, supportsLargeEngine: false), .compact)
        XCTAssertEqual(MacInferenceTier.large.manifestResource, "pi-local-model-gemma")
        XCTAssertEqual(MacInferenceTier.compact.manifestResource, "pi-local-model")
    }
    func testGemmaPinDecodesWithShardedWeightsAndMlxServeEngine() throws {
        let url = SourceTree.root.appendingPathComponent("Banana/Pi/Resources/pi-local-model-gemma.json")
        let manifest = try JSONDecoder().decode(PinnedModelFiles.Manifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(manifest.revision, "0d77464eeb233a2da68ebf9d7dc4edaac7db956d")
        XCTAssertTrue(manifest.profile.serverModel.hasPrefix("mlxserve/"))
        XCTAssertNotNil(manifest.files["model.safetensors.index.json"])
        XCTAssertEqual(manifest.files.keys.filter { $0.hasSuffix(".safetensors") }.count, 3)
        XCTAssertTrue(manifest.files.values.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        XCTAssertLessThan(manifest.profile.maxTokens, manifest.profile.contextWindow)
    }
}
