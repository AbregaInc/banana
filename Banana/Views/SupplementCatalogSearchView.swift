import SwiftUI

/// Search NIH's supplement label database by name, for a bottle with no barcode worth scanning.
/// Shared by the phone's supplement editor and the Mac's.
///
/// The ingredient lines under each result are not decoration: choosing a product here is how the
/// app learns what is inside a bottle whose name gives nothing away, which is the difference
/// between spotting a multivitamin's iron against a calcium tablet and missing it entirely.
struct SupplementCatalogSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (SupplementCatalogEntry) -> Void

    @State private var query = ""
    @State private var results: [SupplementCatalogEntry] = []
    @State private var searching = false
    @State private var picking: String?
    @State private var note = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack { ProgressView(); Text("Searching NIH’s database…") }
                } else if !note.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(results) { entry in
                    Button { pick(entry) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.product).font(.headline).foregroundStyle(.primary)
                            if !entry.brand.isEmpty {
                                Text(entry.brand).font(.subheadline).foregroundStyle(.secondary)
                            }
                            if !entry.ingredientSummary.isEmpty {
                                Text(entry.ingredientSummary)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .disabled(picking != nil)
                    .overlay(alignment: .trailing) {
                        if picking == entry.id { ProgressView() }
                    }
                }
            }
            .searchable(text: $query, prompt: "Brand or product name")
            .onSubmit(of: .search) { run() }
            .onChange(of: query) { _, _ in note = "" }
            .navigationTitle("Search supplements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { searchTask?.cancel(); dismiss() }
                }
            }
            .overlay {
                if results.isEmpty && !searching && note.isEmpty {
                    ContentUnavailableView("Search by name", systemImage: "magnifyingglass",
                                           description: Text("NIH’s Dietary Supplement Label Database covers US products. Type a brand or product name, then Search."))
                }
            }
            .onDisappear { searchTask?.cancel() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }

    private func run() {
        searchTask?.cancel()
        searchTask = Task {
            searching = true; note = ""; results = []
            defer { searching = false }
            switch await SupplementCatalogSearch.search(query) {
            case .results(let found):
                guard !Task.isCancelled else { return }
                results = found
            case .none:
                note = "Nothing matched “\(query)” in NIH’s database. It covers US products only — scanning the barcode or photographing the label works for anything it doesn’t have."
            case .networkError:
                note = "Couldn’t reach NIH’s database. Check your connection and try again, or photograph the label instead."
            }
        }
    }

    /// The serving size lives on the full label record rather than the search hit, so it is
    /// fetched only for the one product actually chosen.
    private func pick(_ entry: SupplementCatalogEntry) {
        picking = entry.id
        searchTask = Task {
            let filled = await SupplementCatalogSearch.withDose(entry)
            guard !Task.isCancelled else { return }
            picking = nil
            onPick(filled)
            dismiss()
        }
    }
}
