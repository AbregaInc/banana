#if os(macOS)
import SwiftUI

/// Pages supply controls bound to their own state. The window owns the items, their order and
/// their widths, so swapping pages does not ask the native toolbar to arrange a new set of items.
struct MacSharedToolbar: ViewModifier {
    let section: AppSection
    let railShown: Bool
    let rightPanelVisible: Bool
    let toggleRightPanel: () -> Void
    @State private var layout = Layout.standard

    private enum Layout: Equatable {
        case narrow, standard, wide

        init(width: CGFloat) {
            // Leave room for AppKit's item margins before moving to the wider slots.
            if width < 715 { self = .narrow }
            else if width < 825 { self = .standard }
            else { self = .wide }
        }

        var leading: CGFloat { self == .narrow ? 248 : 304 }
        var search: CGFloat {
            switch self {
            case .narrow: 136
            case .standard: 176
            case .wide: 272
            }
        }
        var trailing: CGFloat { self == .narrow ? 128 : self == .standard ? 136 : 168 }
    }

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(MacToolbarSlotsKey.self) { slots in
                Color.clear
                    .frame(width: 0, height: 0)
                    .toolbar {
                        ToolbarItem(placement: .navigation) { ShellRailToggle() }
                        ToolbarItem(placement: .navigation) {
                            leading(slots.leading)
                                .frame(width: layout.leading, height: 36, alignment: .leading)
                                .environment(\.wideShell, true)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .principal) {
                            ShellWideField(search: .shared)
                                .frame(width: layout.search)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .primaryAction) {
                            HStack(spacing: DS.Space.s) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: DS.Space.s) {
                                        slots.status
                                        slots.actions
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                    HStack(spacing: DS.Space.s) { slots.actions }
                                }
                                .labelStyle(.iconOnly)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                                Button(action: toggleRightPanel) {
                                    Image(systemName: "sidebar.trailing")
                                        .frame(width: 36, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .glassEffect(.regular.interactive(), in: .capsule)
                                .help(rightPanelVisible ? "Hide Right Panel" : "Show Right Panel")
                                .accessibilityLabel(rightPanelVisible ? "Hide right panel" : "Show right panel")
                                .accessibilityIdentifier("shell.rightPanel.toggle")
                            }
                            .frame(width: layout.trailing, height: 36, alignment: .trailing)
                            .environment(\.wideShell, true)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
            }
            .toolbar(removing: .title)
            // The resize divider between list and detail belongs below this bar.
            .toolbarBackground(.background, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .onGeometryChange(for: Layout.self) { geometry in
                Layout(width: geometry.size.width - (railShown ? 0 : 78))
            } action: { layout = $0 }
    }

    @ViewBuilder private func leading(_ page: AnyView?) -> some View {
        if let page {
            page
        } else {
            PageTitleText(title: section.sidebarHome.title)
        }
    }
}

private struct MacToolbarSlotsKey: PreferenceKey {
    struct Value {
        var leading: AnyView?
        var status: AnyView?
        var actions: AnyView?
    }

    static let defaultValue = Value()

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        if let leading = next.leading { value.leading = leading }
        if let status = next.status { value.status = status }
        if let actions = next.actions { value.actions = actions }
    }
}

extension View {
    func macToolbarLeading<Controls: View>(@ViewBuilder _ controls: () -> Controls) -> some View {
        let view = AnyView(controls())
        return transformPreference(MacToolbarSlotsKey.self) { $0.leading = view }
    }

    func macToolbarActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        let view = AnyView(actions())
        return transformPreference(MacToolbarSlotsKey.self) { $0.actions = view }
    }

    func macToolbarStatus<Status: View>(@ViewBuilder _ status: () -> Status) -> some View {
        let view = AnyView(status())
        return transformPreference(MacToolbarSlotsKey.self) { $0.status = view }
    }
}
#endif
