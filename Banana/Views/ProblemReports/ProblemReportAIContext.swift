#if BANANA_AI
import SwiftUI

/// An answer as a report carries it: the prompt before it, the answer, the conversation up to it
/// and the tool calls made in it. For an eval case (tools/reports/ai_case.py).
struct AssistantAnswerReport: Encodable {
    struct Message: Encodable { var role: String; var text: String }
    var conversation: String?
    var model: String?
    var prompt: String?
    var answer: String
    var messages: [Message]
    var tools: [AssistantStore.ToolCall]
}

extension ProblemReportPageContext {
    /// The answer `id`, or the newest one. `rating` is "down" for a 👎.
    @MainActor
    static func assistant(answer id: String? = nil, rating: String? = nil) -> ProblemReportPageContext? {
        let store = AssistantStore.shared
        let messages = store.messages
        guard let index = id.flatMap({ id in messages.firstIndex { $0.id == id } })
                ?? messages.lastIndex(where: { $0.role == "assistant" }) else { return nil }
        let answer = messages[index]
        let facts = store.reportFacts
        let report = AssistantAnswerReport(
            conversation: facts.conversation, model: facts.model,
            prompt: messages[..<index].last(where: { $0.role == "user" })?.text,
            answer: answer.text,
            messages: messages[...index].suffix(40).map { AssistantAnswerReport.Message(role: $0.role, text: $0.text) },
            tools: facts.tools)
        var context: [String: ProblemReport.Value] = ["answerId": .text(answer.id), "tools": .number(Double(facts.tools.count))]
        if let rating { context["rating"] = .text(rating) }
        if let model = facts.model { context["model"] = .text(model) }
        return ProblemReportPageContext(row: .fixed("Prompt and answer"), context: context,
                                        attachments: { [ProblemReport.Attachment.json(.ai, report)].compactMap { $0 } })
    }
}

/// A quiet 👍 / 👎 under an answer. 👍 is counted; 👎 opens Report a problem with the answer.
struct AnswerRating: View {
    let messageID: String
    @State private var rated: ProblemReport.Rating?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            button(.up, "hand.thumbsup", "Good answer")
            button(.down, "hand.thumbsdown", "Bad answer")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private func button(_ rating: ProblemReport.Rating, _ symbol: String, _ label: String) -> some View {
        Button {
            rated = rating
            ProblemReporter.shared.rate(rating)
            if rating == .down {
                ProblemReportCenter.shared.open(context: ProblemReportPageContext.assistant(answer: messageID, rating: "down"), page: .assistant)
            }
        } label: {
            Image(systemName: rated == rating ? symbol + ".fill" : symbol)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier("assistant.rate.\(rating.rawValue)")
    }
}
#endif
