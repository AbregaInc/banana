#if !BANANA_PUBLIC
import SwiftUI

/// What the assistant gave back, inline in the composer: the owner's questions with their controls
/// and one Write, or a note or no-reply line. Every outcome carries 👍 / 👎.
struct MailAIOutcomePanel: View {
    let display: MailAIDisplay
    let feedback: MailAIFeedback
    @Binding var form: MailPickerForm?
    let writing: Bool
    let write: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            switch display {
            case .picker:
                if let form { picker(form) }
            case .line(let text):
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Image(systemName: "sparkle").foregroundStyle(DS.Palette.accent)
                    Text(text).font(.subheadline).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    MailAIFeedbackRow(feedback: feedback)
                    closeButton
                }
                .accessibilityIdentifier(MailID.composerAssistantLine)
            case .draft:
                MailAIFeedbackRow(feedback: feedback)
            }
        }
    }

    private var closeButton: some View {
        Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier(MailID.composerAssistantDismiss)
    }

    @ViewBuilder private func picker(_ value: MailPickerForm) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(value.picker.questions.indices, id: \.self) { index in
                question(value, index)
            }
            // A free answer only where no question already takes text.
            if !value.picker.questions.contains(where: { $0.control == .text }) {
                TextField("Other answer", text: binding(\.other))
                    .textFieldStyle(.roundedBorder)
                    .disabled(writing)
                    .onSubmit { if value.canWrite { write() } }
                    .accessibilityIdentifier(MailID.composerAssistantOther)
            }
            HStack(spacing: DS.Space.s) {
                if writing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Write", action: write)
                        .buttonStyle(.borderedProminent)
                        .disabled(!value.canWrite)
                        .accessibilityIdentifier(MailID.composerAssistantWrite)
                }
                Spacer(minLength: 0)
                MailAIFeedbackRow(feedback: feedback)
                closeButton
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.composerAssistantPicker)
    }

    @ViewBuilder private func question(_ value: MailPickerForm, _ index: Int) -> some View {
        let item = value.picker.questions[index]
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(item.question).font(.subheadline.weight(.medium))
            switch item.control {
            case .yesNo:
                HStack(spacing: DS.Space.s) { options(value, index) }
            case .pickOne, .pickMany:
                // Options may be whole sentences from the email: one per line, wrapping.
                VStack(alignment: .leading, spacing: DS.Space.xs) { options(value, index) }
            case .dateTime:
                DatePicker(item.question, selection: Binding(
                    get: { form?.dates[index] ?? Self.nextHour },
                    set: { form?.dates[index] = $0 }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            case .amount:
                TextField("Amount", text: textBinding(index))
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            case .text:
                TextField("Answer", text: textBinding(index))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .disabled(writing)
    }

    @ViewBuilder private func options(_ value: MailPickerForm, _ index: Int) -> some View {
        ForEach(value.options(index), id: \.self) { option in
            let chosen = value.isChosen(option, at: index)
            Button { form?.choose(option, at: index) } label: {
                Text(option).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(MailChoiceButtonStyle(chosen: chosen))
            .controlSize(.small)
            .accessibilityAddTraits(chosen ? .isSelected : [])
        }
    }

    private func binding(_ path: WritableKeyPath<MailPickerForm, String>) -> Binding<String> {
        Binding(get: { form?[keyPath: path] ?? "" }, set: { form?[keyPath: path] = $0 })
    }

    private func textBinding(_ index: Int) -> Binding<String> {
        Binding(get: { form?.texts[index] ?? "" }, set: { form?.texts[index] = $0 })
    }

    private static var nextHour: Date {
        let calendar = Calendar.current
        let now = Date()
        return calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
    }
}

/// The system's bordered button, prominent when chosen.
private struct MailChoiceButtonStyle: PrimitiveButtonStyle {
    let chosen: Bool
    func makeBody(configuration: Configuration) -> some View {
        if chosen {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.bordered)
        }
    }
}

/// 👍 counts; 👎 opens a note field and sends the outcome with it (never the email).
struct MailAIFeedbackRow: View {
    let feedback: MailAIFeedback
    @State private var rated: ProblemReport.Rating?
    @State private var noting: Bool
    @State private var note = ""
    @FocusState private var focused: Bool

    init(feedback: MailAIFeedback, noting: Bool = false) {
        self.feedback = feedback
        _noting = State(initialValue: noting)
        _rated = State(initialValue: noting ? .down : nil)
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if noting {
                TextField("What was wrong?", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                    .frame(minWidth: 160)
                    .accessibilityIdentifier(MailID.composerAssistantFeedbackNote)
                Button("Send", action: send)
                    .accessibilityIdentifier(MailID.composerAssistantFeedbackSend)
            } else {
                thumb(.up, "hand.thumbsup", "Good")
                thumb(.down, "hand.thumbsdown", "Bad")
            }
        }
        .font(.caption)
        .foregroundStyle(DS.Palette.quietText)
        .onChange(of: feedback) { _, _ in rated = nil; noting = false; note = "" }
    }

    private func thumb(_ rating: ProblemReport.Rating, _ symbol: String, _ label: String) -> some View {
        Button {
            guard rated == nil else { return }
            rated = rating
            if rating == .up {
                ProblemReporter.shared.rate(feedback.rating(.up))
            } else {
                noting = true
                focused = true
            }
        } label: {
            Image(systemName: rated == rating ? symbol + ".fill" : symbol)
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityAddTraits(rated == rating ? .isSelected : [])
        .accessibilityIdentifier("mail.composer.assistant.rate.\(rating.rawValue)")
    }

    private func send() {
        ProblemReporter.shared.rate(feedback.rating(.down))
        ProblemReporter.shared.send(feedback.report(note: note))
        noting = false
        note = ""
    }
}
#endif
