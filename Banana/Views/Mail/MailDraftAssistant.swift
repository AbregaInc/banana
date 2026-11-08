#if !BANANA_PUBLIC
import Foundation

/// The box's sparkle: a draft written from a one-line instruction, through the assistant path the
/// app already has (the on-device model the assistant runs on, `AppleFoundationModel`). Only where
/// the assistant is available (`ShellAssistant.isAvailable`, the `BANANA_AI` gate); elsewhere the
/// sparkle is not drawn. No backend of its own.
enum MailDraftAssistant {
    struct Unavailable: Error {}

    static var isAvailable: Bool { ShellAssistant.isAvailable }

    /// The instruction, what he has written so far, and the message he is answering go to the model;
    /// the text it answers with is the new body. Nothing is sent and nothing leaves the device here.
    @MainActor
    static func write(instruction: String, model: MailComposerModel) async throws -> String {
        #if BANANA_AI
        if #available(iOS 26.0, macOS 26.0, *) {
            var context = "Subject: \(model.subject)\n"
            if let quote = model.quote, let text = quote.text {
                context += "The message being answered:\n\(MailPlainText.string(text))\n"
            }
            if !MailPlainText.isBlank(model.body) { context += "What is written so far:\n\(model.body)\n" }
            let request: [String: Any] = [
                "instructions": "You write the body of an email for the person using this app. Answer with the body text only: no subject line, no greeting unless asked, no signature, no explanation. Keep it short and in their voice.",
                "tools": [[String: Any]](),
                "messages": [["role": "user", "text": context + "\nInstruction: " + instruction]],
                "temperature": 0.4,
                "maxTokens": 400,
            ]
            let raw = try await AppleFoundationModel.generate(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self))
            guard let answer = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let content = answer["content"] as? [[String: Any]] else { throw Unavailable() }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            guard !MailPlainText.isBlank(text) else { throw Unavailable() }
            return text
        }
        #endif
        throw Unavailable()
    }
}

#endif
