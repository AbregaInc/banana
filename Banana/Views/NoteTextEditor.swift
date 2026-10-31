import SwiftUI

/// Shared text surface; storage and drafts belong to the caller's personal or demo profile.
struct NoteTextEditor: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        TextEditor(text: $text)
            .focused(focused)
            .font(.body)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("What’s on your mind?")
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}
