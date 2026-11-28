#if !BANANA_PUBLIC
import Foundation

/// What the mail assistant produced for one reply request.
enum MailAIOutcome: Equatable {
    case draft(String)
    /// Questions only the owner can answer, already checked against the email.
    case questions(MailReplyPicker.Picker)
    /// A private note to the owner instead of a reply.
    case note(String)
    /// The email needs no reply; the reason is for the owner.
    case noReply(String)
}

enum MailAIThinking: String { case off, low }

struct MailAIFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The model Pi generates with: a native request JSON in, a native result JSON out.
struct MailAIModel {
    var provider: String
    var modelId: String?
    var contextWindow: Int?
    var maxTokens: Int?
    var generate: (String) async throws -> String

    /// A same-device model given as a request-dictionary closure (tests, injected providers).
    static func wrapping(_ generate: @escaping ([String: Any]) async throws -> String) -> MailAIModel {
        MailAIModel(provider: "apple-foundation", generate: { raw in
            guard let request = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw MailAIFailure(message: "Invalid model request")
            }
            return try await generate(request)
        })
    }
}

/// Runs one mail reply on Banana's bundled Pi (pi-mail.js). Pi owns the step loop; Banana supplies the
/// banana-mail tools (read_thread, search_mail, read_attachments, check_time, find_free_time, check_reply,
/// check_picker) and a model.
enum MailPiReply {
    typealias Failure = MailAIFailure

    /// The native side of the banana-mail tools for one reply.
    struct Tools {
        /// Earlier messages in this thread plus audience-checked mail with the same correspondent.
        var readThread: () async throws -> [MailDraftWorkflow.Evidence]
        /// Other threads with this correspondent that match a short literal phrase.
        var search: (String) async throws -> [MailDraftWorkflow.Evidence]
        var attachments: () async throws -> [MailDraftWorkflow.Evidence]
        /// Throws when the body states something the supplied text and the passages read do not support.
        var checkReply: (_ body: String, _ passages: [String]) throws -> Void
        /// The email text the picker's quotes and options must come from.
        var selectedText: String
        /// The owner's calendar: check_time and find_free_time, each a JSON result. Nil when no calendar is available.
        var calendar: ((_ name: String, _ arguments: [String: Any]) async throws -> String)? = nil
    }

    static let calendarTools: Set<String> = ["check_time", "find_free_time"]

    struct Email {
        var subject: String
        var from: String
        var fromName: String?
        var account: String
        var to: [String]
        var cc: [String]
        var text: String
    }

    static let maxRecords = 8

    /// Passages the model has read in this reply; check_reply accepts facts from them.
    final class Passages { var texts: [String] = [] }

    /// One native tool call from pi-mail.js: {name, arguments} → result object.
    static func handle(_ raw: String, tools: Tools, passages: Passages) async throws -> [String: Any] {
        guard let request = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let name = request["name"] as? String else { return ["error": "bad request"] }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        if calendarTools.contains(name) {
            guard let calendar = tools.calendar else { return ["error": "The calendar is unavailable. Ask the owner about the time instead."] }
            do {
                let raw = try await calendar(name, arguments)
                guard let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    return ["error": "Banana couldn’t read the calendar."]
                }
                // The reply may state the times the calendar returned: they are grounded like mail passages.
                passages.texts.append(raw)
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as LocalizedError {
                return ["error": failure.errorDescription ?? "Banana couldn’t read the calendar."]
            } catch {
                return ["error": "Banana couldn’t read the calendar."]
            }
        }
        let items: [MailDraftWorkflow.Evidence]
        do {
            switch name {
            case "read_thread": items = try await tools.readThread()
            case "search_mail":
                let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...80).contains(query.count) else { return ["error": "query must be 2-80 characters"] }
                items = try await tools.search(query)
            case "read_attachments": items = try await tools.attachments()
            case "check_reply":
                do {
                    try tools.checkReply(arguments["body"] as? String ?? "", passages.texts)
                    return ["ok": true]
                } catch let failure as Failure {
                    return ["ok": false, "problem": failure.message]
                } catch {
                    return ["ok": false, "problem": "The reply states a number, date, link, amount or commitment that is not in the email, the mail you read, or the owner's words."]
                }
            case "check_picker":
                // Banana's picker validator: quotes and options must come from the email; ungrounded ones are dropped.
                let payload = try JSONSerialization.data(withJSONObject: ["reply": arguments["reply"] ?? "needed", "questions": arguments["questions"] ?? []])
                let wrapped = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": String(decoding: payload, as: UTF8.self)]]])
                do {
                    let picker = try MailReplyPicker.parse(String(decoding: wrapped, as: UTF8.self), selectedText: tools.selectedText)
                    return ["ok": true, "picker": encode(picker)]
                } catch {
                    return ["ok": false, "problem": "Each question needs question, control, options and an exact quote from the email."]
                }
            default: return ["error": "unknown tool"]
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let issue as MailDraftWorkflow.NeedsInput {
            return ["error": issue.message]
        } catch {
            return ["error": "Banana couldn’t read that mail."]
        }
        let read = items.prefix(maxRecords)
        passages.texts += read.map(\.text)
        return ["records": read.map(record)]
    }

    static func record(_ item: MailDraftWorkflow.Evidence) -> [String: Any] {
        let outgoing = item.source.hasPrefix("Outgoing")
        return ["kind": item.kind, "from": outgoing ? "owner" : "correspondent", "about": item.source, "text": String(item.text.prefix(1500))]
    }

    static func encode(_ picker: MailReplyPicker.Picker) -> [String: Any] {
        ["reply": picker.reply.rawValue, "questions": picker.questions.map {
            ["question": $0.question, "control": $0.control.rawValue, "options": $0.options, "quote": $0.quote]
        }]
    }

    static func decode(_ object: [String: Any]) throws -> MailAIOutcome {
        if let body = object["body"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .draft(body) }
        if object["noReply"] as? Bool == true { return .noReply(object["reason"] as? String ?? "") }
        if let items = object["questions"] as? [[String: Any]] {
            let questions = items.compactMap { item -> MailReplyPicker.Question? in
                guard let question = item["question"] as? String, let control = (item["control"] as? String).flatMap(MailReplyPicker.Control.init),
                      let quote = item["quote"] as? String else { return nil }
                return .init(question: question, control: control, options: item["options"] as? [String] ?? [], quote: quote)
            }
            if !questions.isEmpty { return .questions(.init(reply: .needed, questions: questions)) }
        }
        if let note = object["note"] as? String, !note.isEmpty { return .note(note) }
        throw Failure(message: object["error"] as? String ?? "Banana couldn’t write that")
    }

}

#endif
