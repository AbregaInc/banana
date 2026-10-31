import SwiftUI

/// The data platform's two questions (`SpaceSyncQuestions`), as system alerts over the app: the
/// Health consent, and whether to clear this device for another account. Only with the data platform on (`SpaceSyncFlag`).
struct SpaceSyncQuestionsModifier: ViewModifier {
    @ObservedObject private var questions = SpaceSyncQuestions.shared

    func body(content: Content) -> some View {
        if SpaceSyncFlag.isOn {
            content
                .alert("Sync Health between your devices?", isPresented: $questions.askingConsent) {
                    Button("Sync") { questions.answerConsent(true) }
                    Button("Keep on this device", role: .cancel) { questions.answerConsent(false) }
                } message: {
                    Text("Your workouts, meals and Health data are stored on Banana\u{2019}s service. Stop any time in Settings.")
                }
                .alert("Clear this device\u{2019}s Banana data first?", isPresented: $questions.askingAccountChange) {
                    Button("Clear", role: .destructive) { questions.answerAccountChange(clear: true) }
                    Button("Don\u{2019}t sync", role: .cancel) { questions.answerAccountChange(clear: false) }
                }
        } else {
            content
        }
    }
}

extension View {
    func spaceSyncQuestions() -> some View { modifier(SpaceSyncQuestionsModifier()) }
}
