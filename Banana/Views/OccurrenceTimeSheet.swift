import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A small date+time picker sheet for moving an occurrence or scheduling an extra.
struct OccurrenceTimeSheet: View {
    let title: String
    let onSave: (Date) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: Date, onSave: @escaping (Date) -> Void) {
        self.title = title
        self.onSave = onSave
        _date = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.s) {
                    // Time first: rescheduling is usually "same day, different time".
                    TimeField("Time", selection: $date)
                        .padding(.horizontal)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(date); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}
