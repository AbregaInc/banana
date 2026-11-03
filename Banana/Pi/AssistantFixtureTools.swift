#if DEBUG
import Foundation

/// Isolated, file-backed tools for deterministic app UI tests; never reaches user stores.
@MainActor
enum AssistantFixtureTools {
    static func execute(_ raw: String, directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let request = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let name = request["name"] as? String, let args = request["arguments"] as? [String: Any] else {
            throw AssistantFailure(message: "Invalid diagnostic action")
        }
        let file = directory.appendingPathComponent("fixture-notes.json")
        var notes = (try? JSONDecoder().decode([VoiceNote].self, from: Data(contentsOf: file))) ?? []
        let value: Any
        switch name {
        case "create_note":
            guard let operation = request["operationId"] as? String, let id = UUID(uuidString: operation), let text = args["text"] as? String else {
                throw AssistantFailure(message: "Invalid diagnostic note")
            }
            if !notes.contains(where: { $0.id == id }) {
                notes.append(VoiceNote(id: id, audioFilename: "", transcript: text, status: .transcribed))
                try JSONEncoder().encode(notes).write(to: file, options: .atomic)
            }
            value = ["id": id.uuidString, "saved": true, "count": notes.count] as [String: Any]
        case "list_notes": value = notes.map { ["id": $0.id.uuidString, "text": $0.transcript ?? ""] }
        case "read_note": value = notes.first { $0.id.uuidString == args["id"] as? String }?.transcript ?? ""
        case "day_plan": value = ["date": args["date"] as? String ?? "", "items": []] as [String: Any]
        default: throw AssistantFailure(message: "Unknown diagnostic action")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }
}
#endif
