#if !BANANA_PUBLIC
import Foundation
import Combine

/// One small observable per row: "does this row have the cursor". A row draws its cursor by
/// observing its own mark, so moving the cursor flips two marks and re-evaluates two small leaf
/// views, and nothing the list container reads changes (MAIL-UX 8.3, G2; measured in prototype P1).
@MainActor
final class MailRowMark: ObservableObject {
    @Published fileprivate(set) var hasCursor: Bool

    fileprivate init(hasCursor: Bool) {
        self.hasCursor = hasCursor
    }
}

/// The marks of every row the list has drawn, kept in step with the triage model's cursor.
@MainActor
final class MailRowMarks {
    private var marks: [MailConversationID: MailRowMark] = [:]
    private let model: MailListModel
    private var sink: AnyCancellable?

    init(model: MailListModel) {
        self.model = model
        sink = model.markChanges.sink { [weak self] change in
            guard case .cursor(let from, let to) = change, let self else { return }
            if let from { self.marks[from]?.hasCursor = false }
            if let to { self.marks[to]?.hasCursor = true }
        }
    }

    /// The row's mark. A row drawn for the first time is made already right.
    func mark(for id: MailConversationID) -> MailRowMark {
        if let existing = marks[id] { return existing }
        let made = MailRowMark(hasCursor: model.cursor == id)
        marks[id] = made
        return made
    }
}

#endif
