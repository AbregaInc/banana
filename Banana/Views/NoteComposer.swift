import SwiftUI

/// Writing a note instead of speaking it, or changing a note's text — a written note, or a voice
/// note whose transcription got words wrong. A new note written while a podcast plays is anchored
/// to the episode and moment, as a spoken one is, with a switch to leave that off.
///
/// What's typed lives in `Drafts` and which composer is open lives in `ShellNavigation`, so a trip
/// to another app (which rebuilds the phone's views) comes back to the same half-written note.
struct NoteComposer: View {
    /// "new", or the id of the note being edited.
    let target: String

    @ObservedObject private var store = VoiceNoteStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var context: VoiceNote.Context?
    @State private var attachContext = true
    @FocusState private var focused: Bool

    static let new = "new"

    init(target: String) {
        self.target = target
        let existing = UUID(uuidString: target).flatMap { id in
            VoiceNoteStore.shared.note(id)
        }
        let draft = Drafts.noteFor == target && !Drafts.note.isEmpty ? Drafts.note : nil
        _text = State(initialValue: draft ?? existing?.transcript ?? "")
        _context = State(initialValue: target == Self.new ? VoiceNoteStore.shared.currentPodcastContext() : nil)
    }

    private var isNew: Bool { target == Self.new }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let context {
                    Toggle(isOn: $attachContext) {
                        Label(Self.contextLine(context), systemImage: "headphones")
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                    .formControls()
                    .accessibilityHint("Keeps the episode and the moment with the note")
                }
                NoteTextEditor(text: $text, focused: $focused)
                    .onChange(of: text) {
                        Drafts.note = text
                        Drafts.noteFor = target
                    }
                    .accessibilityIdentifier("notes.composer")
            }
            .padding(DS.Space.l)
            .safeAreaInset(edge: .bottom) {
                if let error = store.storageError {
                    Text(error).font(.callout).foregroundStyle(.red).padding()
                }
            }
            .navigationTitle(isNew ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 420)
        #endif
    }

    private func save() {
        if isNew {
            guard store.addWrittenNote(text, context: attachContext ? context : nil) != nil else { return }
        } else if let id = UUID(uuidString: target) {
            guard store.updateText(id, to: text) else { return }
        }
        close()
    }

    private func close() {
        Drafts.note = ""
        Drafts.noteFor = ""
        ShellNavigation.shared.state.noteComposer = nil
        dismiss()
    }

    static func contextLine(_ context: VoiceNote.Context) -> String {
        let title = context.episodeTitle ?? context.podcastTitle ?? "This episode"
        guard let timestamp = context.timestamp else { return title }
        return "\(title) at \(VoiceNote.Context.clock(timestamp))"
    }
}

/// `ShellState.noteComposer` as a sheet item.
struct NoteComposerTarget: Identifiable {
    let id: String
}
