import SwiftUI

/// Keep presentation state and the popover anchor on the control that opened it.
struct CalendarOverflowButton<Label: View, Content: View>: View {
    @State private var isPresented = false
    let content: (@escaping () -> Void) -> Content
    let label: Label

    init(@ViewBuilder content: @escaping (@escaping () -> Void) -> Content,
         @ViewBuilder label: () -> Label) {
        self.content = content
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: { label }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                content { isPresented = false }
            }
    }
}
