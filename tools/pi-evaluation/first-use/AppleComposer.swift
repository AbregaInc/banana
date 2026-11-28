import Foundation

@main
enum AppleComposer {
    static func main() async throws {
        let renderOnly = CommandLine.arguments.contains("--render-candidate")
        if !renderOnly {
            let status = AppleFoundationModel.availability()
            guard status["available"] as? Bool == true else {
                throw NSError(domain: "Native composer model is unavailable: \(status)", code: 1)
            }
        }
        if CommandLine.arguments.contains("--worker") {
            try write(["ready": true, "availability": AppleFoundationModel.availability()])
        }
        while let line = readLine() {
            let item = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard let id = item?["id"] as? String, let request = item?["request"] as? [String: Any] else {
                throw NSError(domain: "Invalid evaluation case", code: 2)
            }
            if renderOnly {
                let messages = request["messages"] as? [[String: String]]
                let payload = try JSONSerialization.jsonObject(with: Data((messages?.first?["text"] ?? "").utf8)) as? [String: String]
                guard let payload, let task = payload["userInstruction"], let subject = payload["subject"],
                      let quote = payload["quotedEmail"], let draft = payload["workingDraft"] else {
                    throw NSError(domain: "Invalid baseline composer payload", code: 3)
                }
                let candidate = try MailDraftPrompt.request(instruction: task, subject: subject, quotedEmail: quote, workingDraft: draft)
                try write(["id": id, "request": candidate])
                continue
            }
            let start = ContinuousClock.now
            var result: [String: Any] = ["id": id]
            do {
                let requestJSON = try JSONSerialization.data(withJSONObject: request, options: .sortedKeys)
                let response = try await AppleFoundationModel.generate(String(decoding: requestJSON, as: UTF8.self))
                result["result"] = try JSONSerialization.jsonObject(with: Data(response.utf8))
            } catch {
                result["error"] = String(describing: error)
            }
            let elapsed = start.duration(to: .now).components
            result["elapsedMs"] = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            try write(result)
        }
    }

    private static func write(_ row: [String: Any]) throws {
        var encoded = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
        encoded.append(10)
        try FileHandle.standardOutput.write(contentsOf: encoded)
    }
}
