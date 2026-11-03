import SwiftUI

/// Where a workspace object's actions go. Inline in a scrolling page (the default); in the
/// sheet's own toolbar when the sheet is the draft (the + sheet: Discard and Save always in
/// reach, the same for every kind); on an answer page, where Back is the only way out.
enum WorkspaceChrome { case inline, sheetToolbar, answer }

private struct WorkspaceChromeKey: EnvironmentKey { static let defaultValue = WorkspaceChrome.inline }
extension EnvironmentValues {
    var workspaceChrome: WorkspaceChrome {
        get { self[WorkspaceChromeKey.self] }
        set { self[WorkspaceChromeKey.self] = newValue }
    }
}

#if BANANA_AI
/// The one header every workspace object uses: what it is, where it stands, and Dismiss at the
/// top right. Meals, events, search results and copied meals all read the same way, so the
/// person learns one place to look and one way to close.
struct WorkspaceObjectHeader: View {
    enum Status {
        case draft, saved, blocked(String), results
        var label: String? {
            switch self {
            case .draft: "Draft"
            case .saved: "Saved"
            case .blocked(let reason): reason
            case .results: nil
            }
        }
        var symbol: String {
            switch self {
            case .draft: "pencil"
            case .saved: "checkmark.circle.fill"
            case .blocked: "exclamationmark.circle"
            case .results: "magnifyingglass"
            }
        }
        var isDraft: Bool {
            switch self { case .draft, .blocked: true; default: false }
        }
        var tint: Color {
            switch self {
            case .saved: .green
            case .blocked: .orange
            default: .secondary
            }
        }
    }

    let title: String
    let status: Status
    var request: String? = nil
    var dismissID = "assistant.workspace.dismiss"
    let dismiss: () -> Void
    @Environment(\.workspaceChrome) private var chrome

    /// In the + sheet the bar already says "New meal" and the Name field holds the name; on an
    /// answer page the question heads the page.
    private var showsTitle: Bool {
        switch chrome {
        case .inline: true
        case .sheetToolbar: !status.isDraft
        case .answer: status.isDraft
        }
    }

    private var showsButton: Bool {
        switch chrome {
        case .inline: true
        case .sheetToolbar: !status.isDraft   // the sheet's toolbar has Discard
        case .answer: status.isDraft          // Back leaves results; a draft still discards
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if showsTitle { Text(title).font(.title3.weight(.semibold)).lineLimit(2) }
                Spacer()
                // What leaving does, said on the button: a draft is discarded, a saved record or
                // results only close (the record stays where it was saved).
                if showsButton {
                    Button(status.isDraft ? "Discard" : "Close", role: status.isDraft ? .destructive : nil, action: dismiss)
                        .accessibilityIdentifier(dismissID)
                }
            }
            if let label = status.label {
                Label(label, systemImage: status.symbol)
                    .font(.subheadline)
                    .foregroundStyle(status.tint)
                    .accessibilityIdentifier("assistant.workspace.status")
            }
            if let request, !request.isEmpty {
                // What asked for this object: the agent's work stays traceable to the words.
                Text("“\(request)”").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Pi selects descriptors; the shared native editors review and save in place.
struct AssistantWorkspaceView: View {
    let action: AssistantAction
    var request: String? = nil
    @ObservedObject private var assistant = AssistantStore.shared
    @ObservedObject private var wellness = WellnessStore.shared
    @ObservedObject private var occurrences = OccurrenceStore.shared
    @ObservedObject private var noteStore = VoiceNoteStore.shared
    @State private var noteText = ""
    @State private var eventSubmitted = false
    @State private var expandedResult: String?
    @State private var editingSaved: MealEntry?
    @Environment(\.workspaceChrome) private var chrome


    private var savedMeal: MealEntry? { wellness.meals.first { $0.id == UUID(uuidString: action.id) } }
    private var savedNote: VoiceNote? { noteStore.notes.first { $0.id == UUID(uuidString: action.id) } }
    private var eventQueued: Bool {
        eventSubmitted || (UUID(uuidString: action.id).map { id in
            occurrences.pendingWrites.pending.contains(where: { $0.input.assistantOperationID == id })
        } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceObjectHeader(title: title, status: status, request: request) {
                Task { await assistant.dismissWorkspace(actionID: action.id) }
            }
            switch action.kind {
            case .meal:
                if let savedMeal {
                    SavedMealSummary(meal: savedMeal) { open("nutrition", itemID: "meal:\(savedMeal.id)") }
                        edit: { editingSaved = savedMeal }
                } else if let day = action.day.flatMap({ try? AssistantNutrition.date($0) }), let id = UUID(uuidString: action.id) {
                    FoodTextCaptureView(assistantItems: AssistantWorkspace.mealItems(action), name: action.title, day: day, operationID: id, embedded: true)
                        .environmentObject(wellness)
                        .disabled(assistant.busy)
                }
            case .event:
                if eventQueued {
                    Button("Show in Plan") { open("plan") }
                } else {
                    NewCalendarEventSheet(assistantDraft: action, words: action.sourceRequest, embedded: true) { eventSubmitted = true }
                        .environmentObject(OccurrenceStore.shared)
                        .disabled(assistant.busy)
                }
            case .note:
                if let savedNote {
                    Text(savedNote.transcript ?? "").textSelection(.enabled)
                    Button("Show in Notes") { open("notes", itemID: "note:\(savedNote.id)") }
                } else {
                    TextEditor(text: $noteText).frame(minHeight: 140)
                        .accessibilityLabel("Note text")
                        .onAppear { noteText = action.notes ?? "" }
                    Button("Save note") {
                        do {
                            guard let id = UUID(uuidString: action.id) else { return }
                            try noteStore.addAssistantNote(id: id, text: noteText)
                        } catch { assistant.error = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(assistant.busy || noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("assistant.note.save")
                }
            case .search:
                searchResults
            case .navigation:
                Button("Open \(action.title)") { open(action.section ?? "plan") }
                    .accessibilityIdentifier("assistant.workspace.openPage")
            }
        }
        .toolbar {
            if chrome == .sheetToolbar && status.isDraft {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { Task { await assistant.dismissWorkspace(actionID: action.id) } }
                        .accessibilityIdentifier("assistant.workspace.dismiss")
                }
            }
        }
        // The app's own meal editor, as Nutrition opens it: a correction is one tap from the result.
        .sheet(item: $editingSaved) { meal in
            FoodTextCaptureView(editing: meal).environmentObject(wellness)
        }
    }

    private var title: String {
        switch action.kind {
        case .meal: savedMeal.map { $0.name.isEmpty ? "Meal" : $0.name } ?? (action.title.isEmpty ? "Meal" : action.title)
        case .event: eventQueued ? "Event added" : "New event"
        case .note: savedNote == nil ? "New note" : "Note saved"
        case .search: action.title
        case .navigation: action.title
        }
    }

    private var status: WorkspaceObjectHeader.Status {
        switch action.kind {
        case .meal: return savedMeal == nil ? .draft : .saved
        case .note: return savedNote == nil ? .draft : .saved
        case .event:
            // A missing calendar is said on the Calendar row, which owns it; the draft is a draft.
            return eventQueued ? .saved : .draft
        case .search, .navigation: return .results
        }
    }

    @ViewBuilder private var searchResults: some View {
        let results = action.results ?? []
        if results.isEmpty {
            Text("Nothing in notes, meals, workouts, routines, podcasts or the plan matches.").foregroundStyle(.secondary)
        }
        let sections = Dictionary(grouping: results, by: \.section)
        ForEach(AppSection.allCases.filter { sections[$0.rawValue] != nil }, id: \.self) { section in
            VStack(alignment: .leading, spacing: 10) {
                Text(section.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                ForEach(sections[section.rawValue] ?? []) { result in resultRow(result) }
            }
        }
    }

    @ViewBuilder private func resultRow(_ result: AssistantAction.Result) -> some View {
        let previews = result.id.hasPrefix("meal:") || result.id.hasPrefix("note:")
        let open = expandedResult == result.id
        Button {
            if previews { withAnimation(.snappy(duration: 0.2)) { expandedResult = open ? nil : result.id } }
            else { self.open(result.section, itemID: result.id) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(result.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(open ? nil : 1)
                }
                Spacer()
                Image(systemName: previews ? (open ? "chevron.up" : "chevron.down") : "chevron.forward")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(previews ? (open ? "Hides details" : "Shows details") : "Opens it")
        .accessibilityIdentifier("assistant.workspace.result.\(result.id)")
        if open {
            AssistantSearchDetail(result: result)
            Button("Show in \(AppSection(rawValue: result.section)?.title ?? "Banana")") {
                self.open(result.section, itemID: result.id)
            }
            .accessibilityIdentifier("assistant.workspace.openResult.\(result.id)")
        }
        Divider()
    }

    private func open(_ raw: String, itemID: String? = nil) {
        guard let section = AppSection(rawValue: raw) else { return }
        AssistantWorkspace.open(section, itemID: itemID)
    }
}

/// What a saved meal is, at a glance, after Pi's draft became a real entry. Undo stays in the
/// toast above the input; this is the record you can check and open.
struct SavedMealSummary: View {
    let meal: MealEntry
    let show: () -> Void
    var edit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meal.date.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(meal.items) { item in
                Text("\(item.name) · \(item.serving)")
            }
            Text(MealTotalsLine.text(meal)).font(.callout.weight(.medium))
            HStack(spacing: 20) {
                if let edit {
                    Button("Edit", action: edit).accessibilityIdentifier("assistant.workspace.editMeal")
                }
                Button("Show in Nutrition", action: show)
                    .accessibilityIdentifier("assistant.workspace.showMeal")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.workspace.savedMeal")
    }
}

/// One line for a meal's totals, rounded the way a person reads them: "800 kcal · 61 g protein".
/// An estimate says so with "~" instead of a separate caption.
enum MealTotalsLine {
    static func text(_ meal: MealEntry) -> String {
        let t = meal.totals
        let approx = meal.isConfident ? "" : "~"
        return "\(approx)\(Int(t.calories.rounded())) kcal · \(Int(t.proteinGrams.rounded())) g protein · "
            + "\(Int(t.carbohydrateGrams.rounded())) g carbs · \(Int(t.fatGrams.rounded())) g fat"
    }
}

/// Read saved records directly; expanding a result never starts inference or changes stores.
private struct AssistantSearchDetail: View {
    let result: AssistantAction.Result
    @ObservedObject private var wellness = WellnessStore.shared
    @ObservedObject private var notes = VoiceNoteStore.shared
    private var recordID: UUID? { result.id.split(separator: ":", maxSplits: 1).last.flatMap { UUID(uuidString: String($0)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.id.hasPrefix("meal:") {
                if let meal = wellness.meals.first(where: { $0.id == recordID }) {
                    ForEach(meal.items) { item in
                        Text("\(item.name) · \(item.serving)")
                    }
                    Text(MealTotalsLine.text(meal)).font(.callout.weight(.medium))
                } else {
                    Text("This meal is no longer available.")
                }
            } else if result.id.hasPrefix("note:") {
                if let note = notes.notes.first(where: { $0.id == recordID && $0.archivedAt == nil }) {
                    let text = note.transcript ?? ""
                    Text(text.isEmpty ? "No transcript yet." : String(text.prefix(10_000)))
                    if text.count > 10_000 { Text("Open Notes to read the rest.").font(.caption) }
                } else {
                    Text("This note is no longer available.")
                }
            } else {
                Text(result.detail)
            }
        }
        .padding(.leading, 2)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.workspace.searchDetail")
    }
}

#endif
