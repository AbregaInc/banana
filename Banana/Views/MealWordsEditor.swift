import SwiftUI

/// What you said a meal was, as something you can change: the words under a photo meal waiting
/// to be logged, tapped to edit. New words estimate it again — your words win over the photo — and
/// the toast's Undo puts back the words and the estimate it had.
struct MealWordsButton: View {
    let item: MealInboxItem
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                if item.trimmedNote.isEmpty {
                    Label("Say what it was", systemImage: "text.bubble")
                } else {
                    // The pencil follows the last word, however the words wrap.
                    (Text("\u{201C}\(item.trimmedNote)\u{201D} ") + Text(Image(systemName: "pencil")))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .font(.caption)
            .foregroundStyle(item.trimmedNote.isEmpty ? DS.Palette.accent : .secondary)
        }
        .buttonStyle(.inline)
        .accessibilityLabel(item.trimmedNote.isEmpty ? "Say what it was" : "Change what you said: \(item.trimmedNote)")
        .accessibilityIdentifier("mealWords")
        .sheet(isPresented: $editing) { MealWordsEditor(item: item) }
    }
}

struct MealWordsEditor: View {
    let item: MealInboxItem
    @Environment(\.dismiss) private var dismiss
    @State private var words: String
    @FocusState private var focused: Bool

    init(item: MealInboxItem) {
        self.item = item
        _words = State(initialValue: item.note)
    }

    private var trimmed: String { words.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What was this?", text: $words, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                        .accessibilityIdentifier("mealWords.field")
                } footer: {
                    Text(item.hasPhotos
                         ? "It\u{2019}s estimated again with these words; where they and the photo disagree, your words win. Left empty, it goes on the photo alone."
                         : "It\u{2019}s estimated again with these words.")
                }
            }
            .editingFormStyle()
            .navigationTitle("What it was")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 420, minHeight: 240)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Estimate again", action: save)
                        .disabled(trimmed.isEmpty && !item.hasPhotos)
                        .accessibilityIdentifier("mealWords.save")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let inbox = MealInboxStore.shared
        if let before = inbox.changeNote(item.id, to: trimmed) {
            Task {
                await ToastCenter.shared.offerUndo("Estimating again with your words") { @MainActor in
                    MealInboxStore.shared.restore(before)
                    return nil
                }
            }
        } else if item.state == .proposed || item.state == .failed {
            // The same words: just estimate it again.
            inbox.retry(item.id)
        }
        dismiss()
    }
}
