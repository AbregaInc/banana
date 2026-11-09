#if BANANA_AI
import SwiftUI

struct AssistantView: View {
    @ObservedObject private var assistant = AssistantStore.shared
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var showingConversations = false
    @State private var confirmingClear = false
    @State private var showingHistory = false
    /// Words handed over by the shell's "Ask Banana" row, sent once the model is ready.
    @State private var sendWhenReady = false
    #if PI_DEVELOPMENT
    @ObservedObject private var wellness = WellnessStore.shared
    #endif
    var showsDoneButton = false
    /// Embedded beside a Mac page; controls stay in the panel rather than the window toolbar.
    var panelClose: (() -> Void)? = nil
    var panelAddSection: AppSection? = nil
    var pickAdd: ((AddKind) -> Void)? = nil
    @ObservedObject private var modules = ModuleStore.shared
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private var draftKey: String {
        if AppSupport.isPiVerification { return "assistant.verification.draft" }
        #if DEBUG
        if (ProcessInfo.processInfo.arguments.contains("--assistant-test") || ProcessInfo.processInfo.arguments.contains("--assistant-test-navigation")) { return "assistant.test.draft" }
        #endif
        return "assistant.draft"
    }

    var body: some View {
        Group {
            if panelClose != nil {
                assistantContent
            } else {
                NavigationStack {
                    assistantContent
                        .navigationTitle(AppSupport.isPiVerification ? "Assistant verification" : panelAddSection != nil ? "Ask or add" : "Assistant")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItemGroup(placement: .automatic) { addFormMenu; conversationControls }
                            if showsDoneButton {
                                SheetClose { dismiss() }
                            }
                        }
                }
            }
        }
        .onAppear { ProblemReportCenter.shared.provide(.assistant) { ProblemReportPageContext.assistant() } }
        .sheet(isPresented: $showingConversations) {
            NavigationStack {
                List {
                    ForEach(assistant.conversations) { conversation in
                        Button {
                            Task { await assistant.select(conversation.id); showingConversations = false }
                        } label: {
                            HStack {
                                Text(conversation.title).lineLimit(2)
                                Spacer()
                                if conversation.id == assistant.selected { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("assistant.conversation.\(conversation.id)")
                    }
                    if assistant.hasMoreConversations {
                        Button("Load more conversations") { Task { await assistant.loadMoreConversations() } }
                    }
                }
                .navigationTitle("Conversations")
                .toolbar { SheetClose { showingConversations = false } }
            }
            #if os(macOS)
            .frame(minWidth: 340, minHeight: 360)
            #endif
        }
        .confirmationDialog("Delete all assistant conversations on this device?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete conversations", role: .destructive) {
                Task { await assistant.clearHistory(); draft = "" }
            }
        } message: { Text("Notes already created by the assistant will stay in Notes.") }
        .alert("Assistant", isPresented: Binding(get: { assistant.error != nil }, set: { if !$0 { assistant.error = nil } })) {
            Button("OK") { assistant.error = nil }
        } message: { Text(assistant.error ?? "") }
        .task {
            draft = UserDefaults.standard.string(forKey: draftKey) ?? ""
            assistant.activate()
            // "Ask Banana: …" under the shell's field: the words are the question, asked at once.
            if let words = PageChrome.shared.agentPrefill {
                PageChrome.shared.agentPrefill = nil
                draft = words
                if assistant.available { send() } else { sendWhenReady = true }
            }
            if panelClose != nil { composerFocused = true }
            #if DEBUG
            await AssistantVerification.runIfRequested(assistant)
            await AssistantLifecycleVerification.runIfRequested(assistant)
            #endif
        }
        .onChange(of: draft) { _, value in UserDefaults.standard.set(value, forKey: draftKey) }
        .onChange(of: assistant.available) { _, ready in
            if ready && sendWhenReady { sendWhenReady = false; send() }
        }
    }

    @ViewBuilder private var addFormMenu: some View {
        #if PI_DEVELOPMENT
        if let section = panelAddSection {
            Menu {
                ForEach(AddKind.groups(for: section, with: modules.effectiveChoice), id: \.section) { group in
                    Section(group.section.title) {
                        ForEach(group.kinds.filter { kind in
                            #if os(macOS)
                            ![AddKind.describeMeal, .scanFood, .groceries].contains(kind)
                            #else
                            kind != .describeMeal
                            #endif
                        }) { kind in
                            Button {
                                if let pickAdd { pickAdd(kind) }
                                else {
                                    if let half = kind.nutritionSection { ShellNavigation.shared.state.nutritionSection = half }
                                    AssistantWorkspace.open(kind.section)
                                    PageChrome.shared.pendingAdd = kind
                                }
                            } label: { Label(kind.title, systemImage: kind.symbol) }
                        }
                    }
                }
            } label: { Image(systemName: "plus") }
            .help("Add using a form")
            .accessibilityLabel("Add using a form")
            .accessibilityIdentifier("assistant.panel.addForm")
        }
        #endif
    }

    @ViewBuilder private var conversationControls: some View {
        Button { showingConversations = true } label: { Image(systemName: "clock.arrow.circlepath") }
            .accessibilityLabel("Conversations")
            .accessibilityIdentifier("assistant.conversations")
        Button { Task { await assistant.newConversation() } } label: { Image(systemName: "square.and.pencil") }
            .accessibilityLabel("New conversation")
            .accessibilityIdentifier("assistant.new")
        Menu {
            Button("Summarize context", systemImage: "text.append") { Task { await assistant.compact() } }
                .disabled(assistant.busy || !assistant.available || assistant.messages.isEmpty)
            #if PI_DEVELOPMENT
            Menu("Sample data", systemImage: "flask") {
                Button(AppSupport.isPiSampleWorkspace ? "Use my data after reopening" : "Use full sample workspace after reopening") {
                    UserDefaults.standard.set(!AppSupport.isPiSampleWorkspace, forKey: "assistant.sampleWorkspace")
                    assistant.error = "Reopen Banana Pi to switch workspaces. Your personal data is kept separately. Sample calendar, workouts, sleep, trends, meals, supplements, notes, routines and library fixtures reset each launch."
                }

            }
            #endif
            ReportProblemMenuItem()
            Divider()
            Button("Delete all conversations…", systemImage: "trash", role: .destructive) { confirmingClear = true }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("Assistant options")
        .accessibilityIdentifier("assistant.options")
    }

    private var assistantContent: some View {
        VStack(spacing: 0) {
            if let panelClose {
                HStack(spacing: 12) {
                    Text("Ask or add").font(.headline)
                    Spacer()
                    addFormMenu
                    conversationControls
                    Button(action: panelClose) { Image(systemName: "xmark") }
                        .accessibilityLabel("Close chat")
                        .accessibilityIdentifier("assistant.panel.close")
                }
                .buttonStyle(.borderless)
                .padding(16)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    workspaceStack
                }
                .id(assistant.selected)
                .accessibilityIdentifier("assistant.messages")
                .scrollDismissesKeyboard(.interactively)
                .background(DS.Palette.page)
                .onChange(of: assistant.messages.count) { _, _ in
                    if assistant.surface == nil && assistant.workspace?.action == nil {
                        proxy.scrollTo("assistant.bottom", anchor: .bottom)
                    }
                }
                .onChange(of: assistant.messages.last?.id) { _, id in
                    if let id, assistant.messages.last?.agenda != nil { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: assistant.workspace?.action?.id) { _, id in
                    if id != nil { proxy.scrollTo("assistant.workspace.top", anchor: .top) }
                }
                .onChange(of: assistant.surface?.draftID) { _, id in
                    if id != nil { proxy.scrollTo("assistant.copy.top", anchor: .top) }
                }
                .onChange(of: assistant.surface != nil) { _, visible in
                    if visible { proxy.scrollTo("assistant.surface.top", anchor: .top) }
                }
            }
            #if os(iOS)
            // Inside the composer's inset, so an Undo toast sits above the input, never on it.
            .toastHost()
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    /// One input for asking, finding and adding. While Pi works its send button is Stop, in the
    /// same place; a status line shows only when the model can't be used.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assistant.loadingLocalModel {
                ProgressView("Loading local model on this Mac…")
                    .progressViewStyle(.linear)
                    .font(.footnote)
                    .accessibilityValue("In progress")
                    .accessibilityIdentifier("assistant.model.loading")
            } else if !assistant.available && !assistant.busy {
                HStack(spacing: 8) {
                    Label(assistant.availabilityReason, systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Try again") { assistant.activate() }.font(.footnote)
                }
            }
            #if DEBUG
            if assistant.isDiagnostic && !AppSupport.isDesignCapture {
                Text("\(assistant.fixtureNoteCount) saved note\(assistant.fixtureNoteCount == 1 ? "" : "s")")
                    .font(.caption).accessibilityIdentifier("assistant.test.notes")
            }
            #endif
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask, find, or add…", text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(send)
                    // Several lines tall, so Return would be a new line: it sends, as its key says.
                    .onChange(of: draft) { _, value in
                        guard value.hasSuffix("\n") else { return }
                        draft = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
                        send()
                    }
                    .accessibilityIdentifier("assistant.input")
                if assistant.busy {
                    Button { Task { await assistant.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("assistant.stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("assistant.send")
                    .disabled(!assistant.available || assistant.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Starting points for each job, on the empty workspace. A suggestion that needs details
    /// starts the sentence in the input; the protein view opens at once, with no model turn.
    private struct Starter: Identifiable {
        let title: String, symbol: String, prefill: String?
        var id: String { title }
    }
    private let starters = [
        Starter(title: "Log a meal", symbol: "fork.knife", prefill: "Log "),
        Starter(title: "Add an event", symbol: "calendar.badge.plus", prefill: "Add "),
        Starter(title: "Find a note or meal", symbol: "magnifyingglass", prefill: "Find "),
    ]

    @ViewBuilder private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What do you need?").font(.title2.weight(.semibold)).padding(.bottom, 8)
            ForEach(starters) { starter in
                Button {
                    draft = starter.prefill ?? ""
                    composerFocused = true
                } label: {
                    Label(starter.title, systemImage: starter.symbol).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("assistant.starter.\(starter.symbol)")
                Divider()
            }
            Button {
                Task { await assistant.updateSurface(["period": "this_month", "metric": "protein"]) }
            } label: {
                Label("Show my protein this month", systemImage: "chart.bar").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("Show my protein this month")
            .disabled(assistant.selected == nil || assistant.busy || assistant.updatingSurface)
        }
        .padding(.top, 12)
    }

    /// A tool step reads as done once anything follows it; only the step in flight is "-ing".
    static func settled(_ activity: String) -> String {
        activity.components(separatedBy: " · ").map { step in
            [
                "Looking up notes": "Looked up notes", "Reading a note": "Read a note", "Saving a note": "Saved a note",
                "Preparing a note": "Prepared a note draft", "Reading the day plan": "Read the day plan", "Updating nutrition view": "Updated the nutrition view",
                "Preparing meal draft": "Prepared a meal draft", "Preparing event draft": "Prepared an event draft",
                "Searching Banana": "Searched Banana", "Opening Banana page": "Opened a Banana page",
            ][step] ?? step
        }.joined(separator: " · ")
    }

    private var currentReply: AssistantMessage? {
        guard let user = assistant.messages.lastIndex(where: { $0.role == "user" }) else { return nil }
        return assistant.messages.suffix(from: assistant.messages.index(after: user)).last(where: { $0.role == "assistant" })
    }

    @ViewBuilder private var workspaceStack: some View {
        #if os(macOS)
        // AppKit needs the complete height when changing from transcript to chart.
        VStack(alignment: .leading, spacing: 20) { workspaceContent }
            .padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        #else
        if hasObject && sizeClass == .regular && !assistant.messages.isEmpty {
            // A wide screen shows the object and the words behind it side by side, instead of
            // one narrow column with the conversation folded away.
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 20) { objectContent(showsRequest: false) }
                    .frame(maxWidth: 640, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Conversation").font(.headline)
                    conversationMessages
                }
                .frame(width: 340, alignment: .leading)
                .accessibilityIdentifier("assistant.conversation.column")
            }
            .padding(24).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
        } else if hasObject {
            // The bounded interactive canvas changes height while charts and drafts
            // update. Lazy placement can cycle during a scroll through those updates.
            VStack(alignment: .leading, spacing: 20) { workspaceContent }
                .padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        } else {
            LazyVStack(alignment: .leading, spacing: 20) { workspaceContent }
                .padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        #endif
    }

    private var hasObject: Bool { assistant.surface != nil || assistant.workspace?.action != nil }

    @ViewBuilder private var workspaceContent: some View {
        if hasObject {
            if panelClose != nil { conversationMessages }
            else if let reply = currentReply {
                Text(.init(reply.text)).font(.callout).textSelection(.enabled)
            }
            objectContent()
            if panelClose == nil { conversationDisclosure }
        } else {
            conversationMessages
        }
        Color.clear.frame(height: 1).id("assistant.bottom")
    }

    /// The object Pi put in the workspace: a draft, a saved record, results, or a nutrition view.
    @ViewBuilder private func objectContent(showsRequest: Bool = true) -> some View {
        if let action = assistant.workspace?.action {
            Color.clear.frame(height: 0).id("assistant.workspace.top")
            // Beside the conversation column the request is already in view.
            AssistantWorkspaceView(action: action, request: showsRequest ? action.sourceRequest : nil).id(action.id)
        } else if let surface = assistant.surface {
            Color.clear.frame(height: 0).id("assistant.surface.top")
            AssistantNutritionView(surface: surface)
        }
    }


    /// The words behind the object, folded below it: one place, the same on every object.
    @ViewBuilder private var conversationDisclosure: some View {
        let count = assistant.messages.filter { $0.role == "user" || $0.role == "assistant" }.count
        if count > 0 {
            DisclosureGroup(isExpanded: $showingHistory) { conversationMessages } label: {
                Text("Conversation · \(count) message\(count == 1 ? "" : "s")").font(.subheadline)
            }
            .accessibilityIdentifier("assistant.conversation.toggle")
        }
    }

    @ViewBuilder private var conversationMessages: some View {
        if assistant.hasEarlier {
            Button("Load earlier messages") { Task { await assistant.loadEarlier() } }
                .accessibilityIdentifier("assistant.earlier")
        }
        if assistant.messages.isEmpty {
            emptyWorkspace
        }
        ForEach(assistant.messages) { message in messageView(message).id(message.id) }
        if assistant.busy {
            Label { Text("Working…") } icon: { ProgressView().controlSize(.small) }
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("assistant.working")
        }
    }

    @ViewBuilder private func messageView(_ message: AssistantMessage) -> some View {
        if let agenda = message.agenda {
            VStack(alignment: .leading, spacing: 12) {
                Text(agenda.heading).font(.headline)
                Text(agenda.zoneLabel + (agenda.sampleData == true ? " · Sample data" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if agenda.items.isEmpty { Text("Nothing scheduled for this day.").foregroundStyle(.secondary) }
                ForEach(Array(agenda.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agenda.time(item)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(item.title).font(.body.weight(.medium))
                        if let origin = item.startTimeZone, let destination = item.endTimeZone,
                           !origin.isEmpty, !destination.isEmpty, origin != destination {
                            if let start = agenda.sourceTime(item.start, zoneID: origin) {
                                Text("Departure: " + start).font(.caption).foregroundStyle(.secondary)
                            }
                            if let end = agenda.sourceTime(item.end, zoneID: destination) {
                                Text("Arrival: " + end).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if agenda.hasMore { Text("More items are available in Plan.").font(.caption).foregroundStyle(.secondary) }
                Button("Open Plan") { AssistantWorkspace.open(.plan) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .textSelection(.enabled)
            .accessibilityIdentifier("assistant.agenda")
        } else if message.role == "activity" {
            let inFlight = assistant.busy && message.id == assistant.messages.last?.id
            if !inFlight, message.text.contains("Saving a note"), let note = savedNote(for: message) {
                // What Pi wrote, as the note it is: its words and the way to it.
                SavedNoteRow(note: note)
            } else {
                Label(inFlight ? message.text : Self.settled(message.text), systemImage: inFlight ? "ellipsis" : "checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == "user" ? "You" : message.role == "error" ? "Couldn’t finish" : "Assistant")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.role == "assistant" ? (try? AttributedString(markdown: message.text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text) : AttributedString(message.text))
                    .textSelection(.enabled)
                    .foregroundStyle(message.role == "error" ? Color.red : Color.primary)
                if message.role == "assistant" { AnswerRating(messageID: message.id) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(message.role == "user" ? 14 : 0)
            .background(message.role == "user" ? Color.secondary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("assistant.message.\(message.role)")
        }
    }

    private func savedNote(for message: AssistantMessage) -> AssistantStore.SavedNote? {
        let steps = assistant.messages.filter { $0.role == "activity" && $0.text.contains("Saving a note") }
        guard let position = steps.lastIndex(where: { $0.id == message.id }) else { return nil }
        return assistant.savedNote(forNoteStepFromNewest: steps.count - 1 - position)
    }

    private func send() {
        let text = draft
        Task {
            if await assistant.send(text) {
                draft = ""
                composerFocused = false
            }
        }
    }
}

/// A note Pi saved, in the conversation where it happened.
struct SavedNoteRow: View {
    let note: AssistantStore.SavedNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Note saved", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            Text(note.text).lineLimit(6).textSelection(.enabled)
            Button("Show in Notes") { AssistantWorkspace.open(.notes, itemID: "note:\(note.id)") }
                .font(.subheadline)
                .accessibilityIdentifier("assistant.savedNote.show")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.savedNote")
    }
}

#endif
