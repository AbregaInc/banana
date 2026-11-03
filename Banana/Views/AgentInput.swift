import SwiftUI

/// The agent as a way to put data into the fixed app or get answers out of it, never a screen
/// of its own. The + sheet uses it to add ("2 eggs and a banana" becomes a meal draft), Review
/// uses it to ask ("protein this month"). What Pi makes appears as the app's own editor or view;
/// once saved, the sheet closes and the item is on its page.
enum AgentPurpose {
    case add, ask, refine

    var placeholder: String {
        switch self {
        case .add: "Type it: 2 eggs and a banana, lunch Friday at 1…"
        case .ask: "Ask: protein this month, find yogurt…"
        case .refine: "Refine it…"
        }
    }
}

/// Where a saved result lives, for the host to go to once its sheet is gone.
struct AgentDestination: Equatable {
    let section: AppSection
    let itemID: String?
}

/// One input line: words in, Send; Stop in the same place while Pi works.
struct AgentInputField: View {
    let purpose: AgentPurpose
    var placeholder: String? = nil
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    @ObservedObject private var assistant = AssistantStore.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder ?? purpose.placeholder, text: $text, axis: .vertical)
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
                .accessibilityIdentifier(purpose == .refine ? "agent.refine" : "agent.input")
            if assistant.busy {
                Button { Task { await assistant.stop() } } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier(purpose == .refine ? "agent.refine.stop" : "agent.stop")
            } else {
                // The sparkle is the button: it says what sending does, and the line keeps the room.
                Button(action: send) { AgentSendGlyph() }
                    .buttonStyle(.plain)
                    .accessibilityLabel(purpose == .add ? "Add" : "Ask")
                    .accessibilityIdentifier(purpose == .refine ? "agent.refine.send" : "agent.send")
                    .disabled(!assistant.available || assistant.sending
                              || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// What Pi made of the words: a draft to approve, a saved record, results or an answer.
struct AgentResult: View {
    let purpose: AgentPurpose
    let finished: (AgentDestination) -> Void
    @ObservedObject private var assistant = AssistantStore.shared
    @ObservedObject private var wellness = WellnessStore.shared
    @ObservedObject private var occurrences = OccurrenceStore.shared

    private var request: String? { assistant.messages.last(where: { $0.role == "user" })?.text }

    private var reply: AssistantMessage? {
        guard let user = assistant.messages.lastIndex(where: { $0.role == "user" }) else { return nil }
        return assistant.messages.suffix(from: assistant.messages.index(after: user))
            .last(where: { $0.role == "assistant" || $0.role == "error" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let action = assistant.workspace?.action {
                // The words the draft came from, on the draft: what Pi was told, beside what it made.
                AssistantWorkspaceView(action: action, request: purpose == .add ? action.sourceRequest : nil).id(action.id)
            } else if let surface = assistant.surface {
                AssistantNutritionView(surface: surface)
            } else if assistant.busy {
                HStack {
                    Label { Text("Working…") } icon: { ProgressView().controlSize(.small) }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("agent.working")
                    Spacer()
                    // On an answer page the question line is behind, so Stop is here.
                    if purpose == .ask {
                        Button("Stop") { Task { await assistant.stop() } }
                            .accessibilityIdentifier("agent.stop")
                    }
                }
            }
            if let reply, assistant.workspace?.action == nil {
                Text(reply.text)
                    .foregroundStyle(reply.role == "error" ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("agent.reply")
            }
        }
        // Adding is done when the thing is saved: the sheet closes onto its page.
        .onChange(of: savedDestination) { _, destination in
            guard purpose == .add, let destination else { return }
            finished(destination)
        }
    }

    private var savedDestination: AgentDestination? {
        guard let action = assistant.workspace?.action, let id = UUID(uuidString: action.id) else { return nil }
        switch action.kind {
        case .meal:
            return wellness.meals.contains(where: { $0.id == id }) ? AgentDestination(section: .nutrition, itemID: "meal:\(id)") : nil
        case .event:
            return occurrences.pendingWrites.pending.contains(where: { $0.input.assistantOperationID == id })
                ? AgentDestination(section: .plan, itemID: nil) : nil
        default:
            return nil
        }
    }
}

/// The + sheet: words first, then every kind of thing that can be added by hand. Once Pi has
/// made something, the sheet is that thing until it's saved or discarded.
struct AgentAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: AppSection
    let pick: (AddKind) -> Void
    let finished: (AgentDestination) -> Void
    @ObservedObject private var assistant = AssistantStore.shared
    @State private var text = ""
    @State private var started = false
    @State private var sendWhenReady = false
    @FocusState private var focused: Bool

    /// "meal" or "event" while Pi's draft is open and unsaved.
    private var draftKind: String? {
        guard let action = assistant.workspace?.action else { return nil }
        switch action.kind {
        case .meal: return "meal"
        case .event: return "event"
        case .note: return "note"
        default: return nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if started {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // While a draft is open the sheet is that draft; the line comes back
                            // once it's discarded.
                            if draftKind == nil {
                                AgentInputField(purpose: .add, text: $text, focused: $focused, send: send)
                            }
                            AgentResult(purpose: .add, finished: finished)
                        }
                        .environment(\.workspaceChrome, .sheetToolbar)
                        .padding(20)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .background(DS.Palette.page)
                } else {
                    List {
                        Section {
                            AgentInputField(purpose: .add, text: $text, focused: $focused, send: send)
                        }
                        ForEach(AddKind.groups(for: current), id: \.section) { group in
                            Section(group.section.title) {
                                // "Describe" is the words line above, so it isn't listed twice.
                                ForEach(group.kinds.filter { kind in
                                    #if os(macOS)
                                    kind != .describeMeal && kind != .scanFood && kind != .groceries
                                    #else
                                    kind != .describeMeal
                                    #endif
                                }) { kind in
                                    Button { pick(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                                        .tint(.primary)
                                        .accessibilityIdentifier(kind.identifier)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("page.add.list")
                }
            }
            .toolbar {
                if draftKind == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
            .navigationTitle(draftKind.map { "New \($0)" } ?? "Add")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .presentationDetents(started ? [.large] : [.medium, .large])
        .onChange(of: assistant.busy) { _, busy in
            if !busy && started { text = "" }
        }
        .onChange(of: assistant.available) { _, ready in
            if ready && sendWhenReady { sendWhenReady = false; send() }
        }
        .onAppear {
            // Words typed on a page come with the sheet and are already being read.
            if let words = PageChrome.shared.agentPrefill {
                PageChrome.shared.agentPrefill = nil
                text = words
                // Sent as soon as the on-device model is ready (it may still be starting).
                if assistant.available { send() } else { sendWhenReady = true }
                return
            }
            #if os(iOS)
            // On iPad the keyboard doesn't cover the kinds below, so the line is ready to type.
            if UIDevice.current.userInterfaceIdiom == .pad { focused = true }
            #endif
        }
        .presentationDragIndicator(.visible)
        .task { assistant.activate() }
    }

    private func send() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        Task {
            // Each add starts clean: an earlier draft never stacks under this one.
            if !started { await assistant.newConversation() }
            // The words stay in the line while Pi reads them (cleared once it has answered):
            // an empty placeholder under "Working…" read as if they'd been lost.
            if await assistant.send(words) {
                focused = false
                started = true
            }
        }
    }
}

/// Review's question line: a question about what's logged, answered from the app's own data
/// on a page of its own (`AgentAnswerPage`), pushed like Review's subjects.
struct AgentAskRow: View {
    let asked: () -> Void
    @ObservedObject private var assistant = AssistantStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        AgentInputField(purpose: .ask, text: $text, focused: $focused, send: send)
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

/// The answer to a question asked in Review: the app's own view of it (a chart, results, a line).
struct AgentAnswerPage: View {
    @ObservedObject private var assistant = AssistantStore.shared
    @State private var followUp = ""
    @FocusState private var focused: Bool

    /// Examples that fit what's on the page, not ones the page's own controls already do.
    private var refineHint: String {
        if assistant.surface != nil { return "Refine: just October, carbs instead…" }
        if assistant.workspace?.action?.kind == .search { return "Refine: only notes, from last week…" }
        return "Ask a follow-up…"
    }

    private var title: String {
        if let surface = assistant.surface { return surface.metric.title }
        if assistant.workspace?.action?.kind == .search { return "Search" }
        return "Answer"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let question = assistant.messages.last(where: { $0.role == "user" })?.text {
                    Text(question).font(.title3.weight(.semibold)).accessibilityIdentifier("agent.question")
                }
                AgentResult(purpose: .ask) { _ in }
                // Refine without going back: "only weekdays", "also notes". (While Pi works, the
                // working line has Stop.)
                if !assistant.busy {
                    AgentInputField(purpose: .refine, placeholder: refineHint, text: $followUp, focused: $focused) {
                        let words = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !words.isEmpty else { return }
                        Task { if await assistant.send(words) { followUp = ""; focused = false } }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DS.Palette.page)
        .environment(\.workspaceChrome, .answer)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("agent.answer")
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
