import SwiftUI

/// Keeps typing local to the search control. Query adapters receive one settled, validated
/// definition; canceled input never starts a second request or replaces newer results.
struct LiveFilterSearch: View {
    let scope: String
    var sources: [LiveFilterParser.Source] = []
    @Binding var filter: LiveFilter
    @State private var sentence = ""
    @State private var typing = false
    @State private var editing: LiveFilter.Term?
    @State private var editorIndex = 0
    @State private var manualEdit = false

    private struct ParseKey: Hashable { var sentence: String; var sources: [LiveFilterParser.Source] }
    private let dateChoices = ["today", "yesterday", "tomorrow", "thisWeek", "nextWeek", "lastWeek", "thisMonth", "lastMonth", "7days", "30days"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Describe what you want to see…", text: $sentence)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier(scope == "mail" ? "mail.search.query" : "filters.\(scope).query")
                if !sentence.isEmpty || !filter.isEmpty {
                    Button { manualEdit = !sentence.isEmpty; sentence = ""; filter = LiveFilter(scope: scope) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel(scope == "mail" ? "Clear mail search" : "Clear filters")
                }
            }
            .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            if typing { Text("Updating filters…").font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            if !filter.terms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filter.terms) { term in
                            HStack(spacing: 0) {
                                Button { editorIndex = filter.terms.firstIndex(where: { $0.id == term.id }) ?? 0; editing = term } label: { Text(term.title).padding(.leading, 10).padding(.vertical, 9) }
                                    .accessibilityLabel("Edit \(term.title)")
                                Button { replace(term, with: nil) } label: { Image(systemName: "xmark").font(.caption).padding(10) }
                                    .accessibilityLabel("Remove \(term.title)")
                            }.buttonStyle(.plain).foregroundStyle(.tint)
                                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.disabled(typing)
            }
            ForEach(filter.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: sentence) { _, _ in if !manualEdit { typing = true } }
        .task(id: ParseKey(sentence: sentence, sources: sources)) {
            if manualEdit { manualEdit = false; typing = false; return }
            guard typing || !sentence.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            let input = sentence, module = scope, catalog = sources
            let parser = Task.detached(priority: .userInitiated) {
                LiveFilterParser.parse(input, scope: module, sources: catalog)
            }
            var next = await withTaskCancellationHandler { await parser.value } onCancel: { parser.cancel() }
            guard !Task.isCancelled else { return }
            next.firstWeekday = Calendar.app.firstWeekday
            filter = next
            typing = false
        }
        .sheet(item: $editing) { term in
            NavigationStack {
                Form {
                    if term.field == "date" {
                        ForEach(dateChoices, id: \.self) { value in choice(term, value: value) }
                    } else if term.field == "calendar" {
                        ForEach(sources, id: \.self) { source in choice(term, value: source.id, label: source.name) }
                    } else if ["archived", "unread", "starred", "important", "allDay"].contains(term.field) {
                        choice(term, value: "true"); choice(term, value: "false")
                    } else if term.field == "status" {
                        ForEach(term.op == "not" ? ["accepted", "tentative", "declined", "canceled"] : ["accepted", "tentative", "declined"], id: \.self) { choice(term, value: $0) }
                    } else if term.field == "kind", scope == "workouts" {
                        ForEach(["strength", "running", "walking", "cycling", "swimming", "yoga"], id: \.self) { choice(term, value: $0) }
                    } else {
                        TextField(term.field == "duration" ? "Minutes" : "Contains", text: Binding(get: {
                            filter.terms.indices.contains(editorIndex) ? filter.terms[editorIndex].value : term.value
                        }, set: { value in
                            guard !value.isEmpty else { return }
                            var changed = term; changed.value = value; changed.label = nil
                            guard filter.terms.indices.contains(editorIndex) else { return }
                            replace(filter.terms[editorIndex], with: changed, close: false)
                        }))
                    }
                }
                .navigationTitle("Edit filter")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { editing = nil } } }
            }
            .presentationDetents([.medium, .large])
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 340)
            #endif
        }
    }
    private func choice(_ term: LiveFilter.Term, value: String, label: String? = nil) -> some View {
        var changed = term
        changed.value = value; changed.label = label
        return Button { replace(term, with: changed) } label: {
            HStack { Text(changed.title).foregroundStyle(.primary); Spacer(); if term.value == value { Image(systemName: "checkmark") } }
        }
    }
    private func replace(_ term: LiveFilter.Term, with replacement: LiveFilter.Term?, close: Bool = true) {
        manualEdit = !sentence.isEmpty; sentence = ""; typing = false
        if let index = filter.terms.firstIndex(where: { $0.id == term.id }) {
            if let replacement { filter.terms[index] = replacement } else { filter.terms.remove(at: index) }
        }
        if close { editing = nil }
    }
}
