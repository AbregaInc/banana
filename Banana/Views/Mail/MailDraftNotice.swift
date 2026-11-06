#if !BANANA_PUBLIC
import SwiftUI

struct MailDraftNotice: View {
    let session: MailSession
    @ObservedObject var status: MailStatus
    @State private var answering = Set<MailQuestion.ID>()
    @State private var subjects: [MailDraftID: String] = [:]

    var body: some View {
        ForEach(status.value.questions) { question in
            switch question.kind {
            case .draftChangedElsewhere(let id):
                VStack(alignment: .leading) {
                    Text("\(subjects[id] ?? "Draft") changed elsewhere")
                    HStack {
                        action("Keep mine", question: question, draft: id, choice: .keepMine)
                        action("Use Gmail's", question: question, draft: id, choice: .useOther)
                    }
                }
                .task(id: id) { await loadSubject(id) }
            case .sendUnconfirmed(let id, _):
                VStack(alignment: .leading) {
                    Text("Send not confirmed: \(subjects[id] ?? "Draft")")
                    action("Check again", question: question, draft: id, choice: .checkAgain)
                }
                .task(id: id) { await loadSubject(id) }
            default: EmptyView()
            }
        }
    }

    private func loadSubject(_ id: MailDraftID) async {
        if let draft = await session.source.draft(id) {
            subjects[id] = draft.subject.isEmpty ? "Untitled draft" : draft.subject
        }
    }

    private func action(_ title: String, question: MailQuestion, draft: MailDraftID, choice: MailChoice) -> some View {
        Button(title) {
            answering.insert(question.id)
            Task { @MainActor in
                await session.resolveDraftQuestion(draft, choice: choice)
                answering.remove(question.id)
            }
        }
        .disabled(answering.contains(question.id) || !question.choices.contains(choice))
        .accessibilityIdentifier("mail.draft." + choice.rawValue)
    }
}
#endif
