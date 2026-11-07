import SwiftUI

// The regular-width shell (docs/design/BOTTOM-BAR-SHELL.md, Wide): a slim rail of round page
// buttons at the left edge, and one top toolbar per page — its title menu at the left, "Search or
// ask" in the middle, the assistant and "…" at the right. An iPad in either orientation and the
// Mac. The field, its results and the assistant are the phone's (`ShellSearch`).

/// The rail: the pages that are on, as round buttons with no labels; Settings at its foot.
struct ShellRail: View {
    let pages: [ShellPage]
    let current: ShellPage?
    let open: (ShellPage) -> Void

    static let width: CGFloat = 72

    var body: some View {
        VStack(spacing: DS.Space.m) {
            ForEach(pages.filter { $0 != .settings }) { page in
                button(page)
            }
            Spacer(minLength: DS.Space.m)
            if pages.contains(.settings) { button(.settings) }
        }
        .padding(.vertical, DS.Space.l)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.rail")
    }

    private func button(_ page: ShellPage) -> some View {
        let selected = page == current
        return Button { open(page) } label: {
            Image(systemName: page.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(selected ? DS.Palette.onAccent : Color.primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(DS.Palette.accent).interactive() : .regular.interactive(), in: .circle)
        .help(page.title)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("shell.page.\(page.rawValue)")
    }
}

/// "Search or ask" in a page's toolbar: the phone's field, as wide as the toolbar's middle allows.
struct ShellToolbarField: View {
    @ObservedObject private var search = ShellSearch.shared

    var body: some View {
        ShellWideField(search: search)
            .frame(minWidth: 240, idealWidth: 520, maxWidth: 560)
    }
}

/// The field itself, for a toolbar: focusing it shows what can be added under it, typing shows
/// what is found (`ShellWideResults`, drawn by the shell under the toolbar).
struct ShellWideField: View {
    @ObservedObject var search: ShellSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Editing is reported by the field itself: in a toolbar item `@FocusState` takes the
            // keyboard but its change never arrives, and the add list never opened.
            TextField("Search or ask", text: $search.text, onEditingChanged: { editing in
                if search.focused != editing { search.focused = editing }
            })
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if ShellAssistant.isAvailable, ShellSearchRules.query(search.text) != nil, search.groups.isEmpty {
                        search.ask()
                    }
                }
                #if os(macOS)
                .onExitCommand { search.clear() }
                #endif
                .accessibilityIdentifier("shell.field")
            if !search.text.isEmpty || search.focused {
                Button { search.clear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(search.text.isEmpty ? "Close search" : "Clear")
                .accessibilityIdentifier("shell.field.clear")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 36)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onChange(of: search.text) { _, _ in search.textChanged() }
        .onChange(of: focused) { _, now in if search.focused != now { search.focused = now } }
        .onReceive(search.focusRequests) { focused = $0 }
    }
}

extension View {
    /// The wide shell's field and assistant on a split view's detail column (Notes, Library on an
    /// iPad), whose list column is too narrow for them. Nothing elsewhere.
    func shellDetailToolbar() -> some View {
        modifier(ShellDetailToolbar())
    }
}

private struct ShellDetailToolbar: ViewModifier {
    @Environment(\.wideShell) private var wideShell

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            if wideShell {
                ToolbarItem(placement: .principal) { ShellToolbarField() }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { ShellAIButton() }
            }
        }
        #else
        content
        #endif
    }
}

/// The round assistant button of a wide toolbar. Not there without an assistant in the build.
struct ShellAIButton: View {
    var body: some View {
        if ShellAssistant.isAvailable {
            Button { ShellAssistant.open() } label: {
                Image(systemName: "sparkle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DS.Palette.accent)
            }
            .help("Ask Banana")
            .accessibilityLabel("Ask Banana")
            .accessibilityIdentifier("shell.ai")
        }
    }
}

/// What the field found, as a panel hanging under the toolbar's middle. Solid: it is content.
struct ShellWideResults: View {
    let section: AppSection
    @ObservedObject private var search = ShellSearch.shared

    var body: some View {
        if search.mode != .idle {
            ZStack(alignment: .top) {
                // A click beside the panel puts it away.
                Color.black.opacity(0.0001)
                    .onTapGesture { search.clear() }
                    .accessibilityHidden(true)
                ShellSearchResults(search: search, section: section)
                    .frame(maxWidth: 560, maxHeight: 520)
                    .background(DS.Palette.page, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .padding(.top, DS.Space.s)
                    .padding(.horizontal, DS.Space.l)
            }
        }
    }
}
