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

/// All cells showing the same row observe the same mark. The cells own its lifetime.
@MainActor
final class MailRowMarks {
    private struct WeakMark { weak var value: MailRowMark? }
    private var marks: [MailConversationID: WeakMark] = [:]
    private var nextCleanup = 128
    private let model: MailListModel
    private var sink: AnyCancellable?

    init(model: MailListModel) {
        self.model = model
        sink = model.markChanges.sink { [weak self] change in
            guard case .cursor(let from, let to) = change, let self else { return }
            if let from { self.marks[from]?.value?.hasCursor = false }
            if let to { self.marks[to]?.value?.hasCursor = true }
        }
    }

    /// The row's mark. A row drawn for the first time is made already right.
    func mark(for id: MailConversationID) -> MailRowMark {
        if let existing = marks[id]?.value { return existing }
        // Release old lookup keys in batches. A large set of simultaneously displayed rows
        // doubles the interval between sweeps, so binding them does linear work overall.
        if marks.count >= nextCleanup {
            marks = marks.filter { $0.value.value != nil }
            nextCleanup = max(128, marks.count * 2)
        }
        let made = MailRowMark(hasCursor: model.cursor == id)
        marks[id] = WeakMark(value: made)
        return made
    }
}

#endif
