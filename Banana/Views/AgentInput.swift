#if BANANA_AI
import SwiftUI

/// One input line: words in, Send; Stop in the same place while Pi works.
struct AgentInputField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    @ObservedObject private var assistant = AssistantStore.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Banana", text: $text,
                      prompt: Text("Ask: protein this month, find yogurt…"), axis: .vertical)
                .labelsHidden()
                .lineLimit(1...4)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(send)
                // A field that grows to several lines takes Return as a new line and never
                // submits: here Return sends, as its key says.
                .onChange(of: text) { _, value in
                    guard value.hasSuffix("\n") else { return }
                    text = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
                    send()
                }
                // Read-only while Pi works on what's in it.
                .disabled(assistant.busy)
                .accessibilityIdentifier("agent.input")
            if assistant.busy {
                Button { Task { await assistant.stop() } } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("agent.stop")
            } else {
                // The sparkle is the button: it says what sending does, and the line keeps the room.
                Button(action: send) { AgentSendGlyph() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask")
                    .accessibilityIdentifier("agent.send")
                    .disabled(!assistant.available || assistant.sending
                              || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// Review's question line opens the shared Assistant conversation.
struct AgentAskRow: View {
    let asked: () -> Void
    @ObservedObject private var assistant = AssistantStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        AgentInputField(text: $text, focused: $focused, send: send)
            .task { assistant.activate() }
    }

    private func send() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        Task {
            await assistant.newConversation()
            if await assistant.send(words) {
                text = ""
                focused = false
                asked()
            }
        }
    }
}

/// Questions asked before, under Review's ask line: each reopens its answer.
struct AgentRecentQuestions: View {
    let open: () -> Void
    @ObservedObject private var assistant = AssistantStore.shared

    var body: some View {
        // Only conversations that asked something; a fresh one is titled "New conversation".
        ForEach(assistant.conversations.filter { !$0.title.isEmpty && $0.title != "New conversation" }.prefix(3)) { conversation in
            Button {
                Task { await assistant.select(conversation.id); open() }
            } label: {
                HStack(spacing: DS.Space.m) {
                    IconTile(systemImage: "clock.arrow.circlepath", tint: DS.Palette.accent)
                    Text(conversation.title).lineLimit(1)
                }
            }
            .tint(.primary)
            .accessibilityIdentifier("agent.recent.\(conversation.id)")
        }
    }
}

/// The agent's send button: a sparkle on the accent, the size of a send arrow.
struct AgentSendGlyph: View {
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(enabled ? DS.Palette.accent : Color.secondary.opacity(0.4)))
            .accessibilityHidden(true)
    }
}

#endif
