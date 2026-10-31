import SwiftUI

/// How much room a screen has — the only thing a layout decision may depend on.
///
/// Not the device: an iPad in a narrow split, a folded phone and an iPhone all get the compact
/// arrangement; an iPad, an unfolded phone and a Mac window get the regular one. A layout that
/// asks "am I on an iPad?" breaks the first time the iPad is shown in a third of the screen, and
/// every new device shape needs another branch. See docs/design/ADAPTIVE-LAYOUT.md.
enum LayoutClass: Int, Comparable, Sendable {
    /// Under 600 pt: one column, phone-shaped.
    case compact
    /// 600 pt and up: room for a sidebar, a table, two columns side by side.
    case regular

    /// The line between them: wider than any phone in portrait, narrower than any iPad full
    /// screen, and about where a list stops reading well at full width.
    static let regularWidth: CGFloat = 600

    init(width: CGFloat) {
        self = width >= Self.regularWidth ? .regular : .compact
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// How wide a list or a form reads well: past this, rows stretch into lines too long to
    /// follow from label to value.
    static let readableWidth: CGFloat = 720

    /// The margin each side that makes `width` of room into a column `readable` wide, in the
    /// middle. Nothing where the room is no wider than that.
    static func readableMargin(width: CGFloat, readable: CGFloat = readableWidth) -> CGFloat {
        max(0, ((width - readable) / 2).rounded(.down))
    }

    /// Room for an event to open beside the calendar, as the Mac's drawer does: an iPad on its
    /// side, with the sidebar showing or not. Anything narrower (an iPad upright, a phone, a
    /// split) opens it as a sheet over the calendar, which a side panel would squeeze to a strip.
    static let besideWidth: CGFloat = 1050

    static func opensBeside(width: CGFloat) -> Bool { width >= besideWidth }
}

extension EnvironmentValues {
    /// The room the enclosing screen has; set by the shell from its actual width, and re-set by
    /// anything that narrows its content (a sidebar, a split).
    @Entry var layoutClass: LayoutClass = .compact
}

extension View {
    /// Measures this view's width and tells everything inside it which `LayoutClass` it is in.
    func measuresLayoutClass() -> some View {
        modifier(LayoutClassReader())
    }

    /// A list or a form as a readable column in the middle of its room, instead of rows
    /// stretched from edge to edge of an iPad or a wide window. On a phone it changes nothing.
    func readableColumn(_ readable: CGFloat = LayoutClass.readableWidth) -> some View {
        modifier(ReadableColumn(readable: readable))
    }
}

private struct ReadableColumn: ViewModifier {
    let readable: CGFloat
    @State private var margin: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(macOS)
        // A Mac list takes no content margins: the list itself is the column, in the middle.
        content
            .frame(maxWidth: readable)
            .frame(maxWidth: .infinity)
        #else
        content
            .contentMargins(.horizontal, margin > 0 ? margin : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) {
                LayoutClass.readableMargin(width: $0.size.width, readable: readable)
            } action: { margin = $0 }
        #endif
    }
}

private struct LayoutClassReader: ViewModifier {
    @State private var layoutClass: LayoutClass = .compact

    func body(content: Content) -> some View {
        content
            .environment(\.layoutClass, layoutClass)
            .onGeometryChange(for: LayoutClass.self) { LayoutClass(width: $0.size.width) } action: {
                layoutClass = $0
            }
    }
}

/// Native list and detail columns shared by document-style sections.
struct WorkspaceColumns<Content: View, Detail: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var detail: Detail

    var body: some View {
        #if os(macOS)
        HSplitView {
            content.frame(minWidth: 260, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        NavigationSplitView {
            content
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        #endif
    }
}
