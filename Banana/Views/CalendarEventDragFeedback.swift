import SwiftUI

/// Native gesture state confines per-pointer-update transforms to the dragged event.
/// Persistence and recurrence decisions still run through the existing week-view commit path.
struct CalendarEventDragFeedback: ViewModifier {
    let enabled: Bool
    let columnWidth: CGFloat
    let showProgress: Bool
    let finish: (CGSize) -> Void
    @GestureState private var translation: CGSize = .zero

    static let experimentalEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-local-drag")
        #else
        false
        #endif
    }()

    func body(content: Content) -> some View {
        let active = translation != .zero
        content
            .opacity(active ? 0.75 : 1)
            .shadow(color: .black.opacity(active ? 0.25 : 0), radius: active ? 6 : 0, y: 3)
            .zIndex(active ? 1 : 0)
            .overlay(alignment: .topTrailing) {
                if showProgress { ProgressView().controlSize(.small).padding(3) }
            }
            .offset(x: CGFloat(Int((translation.width / max(columnWidth, 1)).rounded())) * columnWidth,
                    y: translation.height)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .updating($translation) { value, state, _ in
                    if enabled { state = value.translation }
                }
                .onEnded { value in
                    if enabled { finish(value.translation) }
                })
    }
}
