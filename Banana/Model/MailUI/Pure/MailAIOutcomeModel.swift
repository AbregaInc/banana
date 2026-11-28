#if !BANANA_PUBLIC
import Foundation

/// One assistant reply request as the composer and a report see it: what came back, and how it was
/// made (the model, the thinking level and which banana-mail tools ran, by name and count).
struct MailAIRun: Equatable {
    var outcome: MailAIOutcome
    var model: String?
    var thinking: MailAIThinking
    var tools: [String: Int] = [:]
}

/// A route's assistant outcome for a screenshot (`--mail-state ai-*`); `noting` opens 👎's note.
struct MailAIPicture: Equatable {
    var run: MailAIRun
    var noting = false

    static func named(_ state: String) -> MailAIPicture? {
        let picker = MailReplyPicker.Picker(reply: .needed, questions: [
            .init(question: "Cancel the Friday pickup too?", control: .yesNo, options: [], quote: ""),
            .init(question: "Which day works for the swap?", control: .pickOne,
                  options: ["Tuesday morning before the market opens", "Thursday after lunch"], quote: ""),
            .init(question: "Which address should they use?", control: .text, options: [], quote: ""),
        ])
        let tools = ["read_thread": 1, "check_reply": 1]
        switch state {
        case "ai-picker": return .init(run: .init(outcome: .questions(picker), model: "sample", thinking: .off, tools: tools))
        case "ai-note": return .init(run: .init(outcome: .note("They already paid the invoice on Monday."), model: "sample", thinking: .off))
        case "ai-noreply": return .init(run: .init(outcome: .noReply("A shipping notice; nothing to answer."), model: "sample", thinking: .off))
        case "ai-draft", "ai-draft-down":
            return .init(run: .init(outcome: .draft("Yes, please cancel Friday too. Thursday after lunch works for the swap."),
                                    model: "sample", thinking: .off, tools: tools), noting: state == "ai-draft-down")
        default: return nil
        }
    }
}

/// Counts the native tool calls of one reply. Tool closures may run off the main actor.
final class MailAIToolTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    var snapshot: [String: Int] { lock.withLock { counts } }
}

/// What the composer shows for an outcome. A draft goes into the text; questions become the picker;
/// a note or a no-reply reason is one line.
enum MailAIDisplay: Equatable {
    case draft(String)
    case picker(MailReplyPicker.Picker)
    case line(String)

    static let noReplyDefault = "This email doesn’t need a reply."

    var isDraft: Bool { if case .draft = self { true } else { false } }

    init(_ outcome: MailAIOutcome) {
        switch outcome {
        case .draft(let text): self = .draft(text)
        case .questions(let picker): self = .picker(picker)
        case .note(let note): self = .line(note)
        case .noReply(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .line(trimmed.isEmpty ? Self.noReplyDefault : trimmed)
        }
    }
}

/// The owner's answers to the picker, as he gives them. Only answered questions go into the
/// instruction; the free answer field is added last.
struct MailPickerForm: Equatable {
    let picker: MailReplyPicker.Picker
    /// Yes/No and the option buttons, by question index.
    var choices: [Int: [String]] = [:]
    var dates: [Int: Date] = [:]
    /// Amount and text fields, by question index.
    var texts: [Int: String] = [:]
    /// The short answer under the questions.
    var other = ""

    init(_ picker: MailReplyPicker.Picker) { self.picker = picker }

    static let yes = "Yes", no = "No"

    func options(_ index: Int) -> [String] {
        let question = picker.questions[index]
        return question.control == .yesNo ? [Self.yes, Self.no] : question.options
    }

    func isChosen(_ option: String, at index: Int) -> Bool { choices[index]?.contains(option) == true }

    /// Yes/no and pick one replace the choice; pick many toggles it. Tapping the chosen one clears it.
    mutating func choose(_ option: String, at index: Int) {
        var current = choices[index] ?? []
        if picker.questions[index].control == .pickMany {
            if let at = current.firstIndex(of: option) { current.remove(at: at) } else { current.append(option) }
            // Keep the email's order whatever order they were tapped in.
            let order = options(index)
            current.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        } else {
            current = current == [option] ? [] : [option]
        }
        choices[index] = current.isEmpty ? nil : current
    }

    func answer(_ index: Int, formatDate: (Date) -> String = MailPickerForm.dateText) -> String? {
        switch picker.questions[index].control {
        case .yesNo, .pickOne, .pickMany:
            guard let chosen = choices[index], !chosen.isEmpty else { return nil }
            return chosen.joined(separator: ", ")
        case .dateTime:
            return dates[index].map(formatDate)
        case .amount, .text:
            let text = (texts[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    func answers(formatDate: (Date) -> String = MailPickerForm.dateText) -> [(MailReplyPicker.Question, String)] {
        picker.questions.indices.compactMap { index in answer(index, formatDate: formatDate).map { (picker.questions[index], $0) } }
    }

    var canWrite: Bool { !answers().isEmpty || !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The next instruction for the assistant, within its 1000-character limit.
    func instruction(formatDate: (Date) -> String = MailPickerForm.dateText) -> String {
        var text = MailReplyPicker.instruction(answers(formatDate: formatDate))
        let extra = other.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { text += (answers(formatDate: formatDate).isEmpty ? " " : "; ") + extra }
        return String(text.prefix(1000))
    }

    /// The answers as the report carries them: question → answer, one per line.
    func summary(formatDate: (Date) -> String = MailPickerForm.dateText) -> String {
        var lines = answers(formatDate: formatDate).map { "\($0.0.question) → \($0.1)" }
        let extra = other.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
    }
}

/// An overnight outcome kept for the morning, as the intent store holds it (JSON in one column).
struct MailAIStoredOutcome: Codable, Equatable {
    struct Question: Codable, Equatable {
        var question: String
        var control: String
        var options: [String]
        var quote: String
    }
    enum Kind: String, Codable { case draft, questions, note, noReply }
    var kind: Kind
    /// The draft, the note or the no-reply reason. Empty for questions.
    var text: String
    var questions: [Question]
    var model: String?
    var thinking: String
    var tools: [String: Int]
    /// The message the outcome answers; shown only while the reply is to that message.
    var anchor: String

    init(_ run: MailAIRun, anchor: String) {
        self.anchor = anchor
        model = run.model
        thinking = run.thinking.rawValue
        tools = run.tools
        questions = []
        switch run.outcome {
        case .draft(let body): kind = .draft; text = body
        case .note(let note): kind = .note; text = note
        case .noReply(let reason): kind = .noReply; text = reason
        case .questions(let picker):
            kind = .questions; text = ""
            questions = picker.questions.map { .init(question: $0.question, control: $0.control.rawValue, options: $0.options, quote: $0.quote) }
        }
    }

    var run: MailAIRun? {
        let outcome: MailAIOutcome
        switch kind {
        case .draft: outcome = .draft(text)
        case .note: outcome = .note(text)
        case .noReply: outcome = .noReply(text)
        case .questions:
            let parsed = questions.compactMap { item in
                MailReplyPicker.Control(rawValue: item.control).map {
                    MailReplyPicker.Question(question: item.question, control: $0, options: item.options, quote: item.quote)
                }
            }
            guard !parsed.isEmpty else { return nil }
            outcome = .questions(.init(reply: .needed, questions: parsed))
        }
        return MailAIRun(outcome: outcome, model: model, thinking: MailAIThinking(rawValue: thinking) ?? .off, tools: tools)
    }

    var data: Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> MailAIStoredOutcome? { try? JSONDecoder().decode(Self.self, from: data) }
}

/// 👍 / 👎 on one assistant outcome. The report carries the outcome, the owner's instruction or
/// picker answers, the model, the thinking level and the tools that ran. Never the email.
struct MailAIFeedback: Equatable {
    struct Payload: Encodable, Equatable {
        var outcome: String
        var text: String
        var questions: [String]?
        var instruction: String?
        var answers: String?
        var model: String?
        var thinking: String
        var tools: [String: Int]
        var overnight: Bool
    }

    var run: MailAIRun
    var instruction: String?
    var answers: String?
    var overnight = false

    static let page = "mail"

    var payload: Payload {
        let kind: String, text: String
        var questions: [String]?
        switch run.outcome {
        case .draft(let body): kind = "draft"; text = body
        case .note(let note): kind = "note"; text = note
        case .noReply(let reason): kind = "noReply"; text = reason
        case .questions(let picker):
            kind = "questions"; questions = picker.questions.map(\.question); text = questions?.joined(separator: "\n") ?? ""
        }
        let words = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = answers?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Payload(outcome: kind, text: text, questions: questions, instruction: words?.isEmpty == false ? words : nil,
                       answers: given?.isEmpty == false ? given : nil, model: run.model, thinking: run.thinking.rawValue,
                       tools: run.tools, overnight: overnight)
    }

    /// The facts a count may carry: kinds and numbers, no text of the owner's or the model's.
    var facts: [String: ProblemReport.Value] {
        let payload = payload
        var facts: [String: ProblemReport.Value] = [
            "outcome": .text(payload.outcome), "thinking": .text(payload.thinking), "overnight": .flag(overnight),
            "tools": .number(Double(run.tools.values.reduce(0, +))),
        ]
        if let model = run.model { facts["model"] = .text(model) }
        return facts
    }

    /// 👍: a count with the facts.
    func rating(_ rating: ProblemReport.Rating) -> ProblemReport {
        ProblemReport(kind: .rating, rating: rating, page: Self.page, context: facts)
    }

    /// 👎 sent: the owner's note and the outcome as an `ai` attachment.
    func report(note: String) -> ProblemReport {
        var context = facts
        context["rating"] = .text(ProblemReport.Rating.down.rawValue)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProblemReport(kind: .problem, page: Self.page, note: trimmed.isEmpty ? nil : trimmed, context: context,
                             attachments: [ProblemReport.Attachment.json(.ai, payload)].compactMap { $0 })
    }
}
#endif
