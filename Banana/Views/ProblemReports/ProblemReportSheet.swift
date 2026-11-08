import SwiftUI

/// Report a problem: one optional field, what goes with it, and Send. System controls only.
struct ProblemReportSheet: View {
    @State var draft: ProblemReportDraft
    let send: (ProblemReportDraft) -> Void
    let cancel: () -> Void
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What happened?", text: $draft.note, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($noteFocused)
                        .accessibilityIdentifier("report.note")
                }
                Section {
                    if let screenshot = draft.screenshot {
                        Toggle(isOn: $draft.includeScreenshot) {
                            HStack(spacing: DS.Space.s) {
                                thumbnail(screenshot)
                                Text("Screenshot")
                            }
                        }
                        .accessibilityIdentifier("report.screenshot")
                    }
                    Label("Log", systemImage: "doc.text")
                    if let context = draft.pageContext {
                        switch context.row {
                        case .toggle(let title, _):
                            Toggle(isOn: $draft.includePage) { Label(title, systemImage: "envelope") }
                                .accessibilityIdentifier("report.page")
                        case .fixed(let title):
                            Label(title, systemImage: "info.circle")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Report a Problem")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .accessibilityIdentifier("report.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(draft) }
                        .accessibilityIdentifier("report.send")
                }
            }
        }
    }

    @ViewBuilder private func thumbnail(_ image: PlatformImage) -> some View {
        #if os(iOS)
        Image(uiImage: image).resizable().scaledToFit()
            .frame(width: 28, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        #else
        Image(nsImage: image).resizable().scaledToFit()
            .frame(width: 56, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        #endif
    }
}
