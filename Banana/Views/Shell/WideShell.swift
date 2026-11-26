import Combine
import SwiftUI

// The regular-width shell (docs/design/BOTTOM-BAR-SHELL.md, Wide): a slim rail of round page
// buttons at the left edge, and one top toolbar per page — its title menu at the left, "Search or
// ask" in the middle, the assistant and "…" at the right. An iPad in either orientation and the
// Mac. The field, its results and the assistant are the phone's (`ShellSearch`).

/// The red capsule on a page's circle (`ShellBadge`): the system's badge colours, "99+" past 99.
struct ShellBadgeMark: View {
    let count: Int

    var body: some View {
        if let text = ShellBadge.text(count) {
            Text(text)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color.red))
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}

/// An account selection changes the calendar viewport, independent of sync and availability.
@MainActor @Observable
final class ShellCalendarScope {
    static let shared = ShellCalendarScope()

    struct Account: Equatable, Identifiable {
        let id: String
        let calendarIDs: Set<String>
    }

    private(set) var accounts: [Account] = []
    private(set) var selected: String?
    private(set) var calendarIDs: Set<String>?
    @ObservationIgnored private var observation: AnyCancellable?

    private init() {
        observation = GoogleCalendarService.shared.$calendars.sink { [weak self] calendars in
            guard let self else { return }
            let groups = Dictionary(grouping: calendars.filter { !$0.isDeleted && !$0.isHidden }) {
                $0.accountEmail.lowercased()
            }
            let next = groups.keys.filter { !$0.isEmpty }.sorted().map { account in
                Account(id: account, calendarIDs: Set(groups[account, default: []].map {
                    GoogleCalendarService.calendarInfoID($0.id)
                }))
            }
            if accounts != next { accounts = next }
            select(selected)
        }
    }

    func select(_ id: String?) {
        let account = accounts.first { $0.id == id }
        if selected != account?.id { selected = account?.id }
        if calendarIDs != account?.calendarIDs { calendarIDs = account?.calendarIDs }
    }

    static func visible(_ occurrences: [Occurrence], in calendarIDs: Set<String>?) -> [Occurrence] {
        guard let calendarIDs else { return occurrences }
        return occurrences.filter {
            ShellCalendarRules.includes($0.meeting?.calendarID, alsoOn: $0.meeting?.alsoOnCalendarIDs ?? [], in: calendarIDs)
        }
    }
}

/// Labeled sidebar rows, with independent disclosures for a page's accounts and places.
struct ShellSidebar: View {
    let pages: [ShellPage]
    let current: ShellPage?
    let open: (ShellPage) -> Void
    var dismiss: () -> Void = {}
    #if os(macOS)
    var bodyPages: [BodyPage] = []
    var bodyCurrent: BodyPage? = nil
    var openBody: (BodyPage) -> Void = { _ in }
    @SceneStorage("shell.sidebar.bodyExpanded") private var bodyExpanded = true
    #endif
    @ObservedObject private var badges = ActionBadges.shared
    @SceneStorage("shell.sidebar.planExpanded") private var planExpanded = true
    #if BANANA_UNRELEASED
    @SceneStorage("shell.sidebar.mailExpanded") private var mailExpanded = false
    #endif
    private let scope = ShellCalendarScope.shared

    #if os(macOS)
    static let width = CGFloat(ShellLayout.macRailColumn)
    private static let rowHeight: CGFloat = 30
    #else
    static let width = CGFloat(ShellLayout.railColumn)
    private static let rowHeight: CGFloat = 44
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(pages) { page in
                    HStack(spacing: 0) {
                        pageButton(page)
                        if let expansion = expansion(for: page) {
                            Button {
                                expansion.wrappedValue.toggle()
                            } label: {
                                Image(systemName: expansion.wrappedValue ? "chevron.down" : "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: Self.rowHeight, height: Self.rowHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(expansion.wrappedValue ? "Collapse \(page.title)" : "Expand \(page.title)")
                            .accessibilityValue(expansion.wrappedValue ? "Expanded" : "Collapsed")
                            .accessibilityIdentifier("shell.expand.\(page.rawValue)")
                        }
                    }
                    if page == .plan, planExpanded, !scope.accounts.isEmpty {
                        planAccounts.padding(.leading, DS.Space.m)
                    }
                    #if os(macOS)
                    if page == .body, bodyExpanded {
                        ForEach(bodyPages, id: \.self) { bodyPage in
                            bodyRow(bodyPage).padding(.leading, DS.Space.m)
                        }
                    }
                    #endif
                    #if BANANA_UNRELEASED
                    if page == .mail, mailExpanded {
                        ShellSidebarMail(active: current == .mail, open: { open(.mail) }, dismiss: dismiss)
                        .padding(.leading, DS.Space.m)
                    }
                    #endif
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.m)
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.rail")
    }

    private func expansion(for page: ShellPage) -> Binding<Bool>? {
        if page == .plan, !scope.accounts.isEmpty { return $planExpanded }
        #if os(macOS)
        if page == .body, !bodyPages.isEmpty { return $bodyExpanded }
        #endif
        #if BANANA_UNRELEASED
        if page == .mail { return $mailExpanded }
        #endif
        return nil
    }

    #if os(macOS)
    private func bodyRow(_ page: BodyPage) -> some View {
        let symbol: String
        let count: Int
        switch page {
        case .workouts: (symbol, count) = (AppSection.workouts.outlineSymbol, 0)
        case .food: (symbol, count) = (AppSection.nutrition.outlineSymbol, badges.counts.food)
        case .taken: (symbol, count) = ("pills", badges.counts.taken)
        }
        return Self.row(page.rawValue, symbol: symbol, selected: bodyCurrent == page, count: count) {
            openBody(page)
        }
        .accessibilityIdentifier("shell.body.\(page.rawValue.lowercased())")
    }
    #endif

    private var planAccounts: some View {
        VStack(spacing: 2) {
            calendarAccount(nil)
            ForEach(scope.accounts) { account in calendarAccount(account.id) }
        }
    }

    private func calendarAccount(_ account: String?) -> some View {
        Self.row(account ?? "All calendars", symbol: account == nil ? "calendar" : "person.crop.circle",
                 selected: current == .plan && scope.selected == account) {
            scope.select(account)
            open(.plan)
            dismiss()
        }
        .help(account ?? "All calendars")
        .accessibilityIdentifier(account == nil ? "shell.calendar.all" : "shell.calendar.account")
    }

    private func pageButton(_ page: ShellPage) -> some View {
        let selected = current == page && expansion(for: page)?.wrappedValue != true
        let count = ShellBadge.count(page, badges.counts, mail: badges.mailInbox)
        return Self.row(page.title, symbol: page.symbol, selected: selected, count: count) {
            open(page)
            dismiss()
        }
        .accessibilityIdentifier("shell.page.\(page.rawValue)")
    }

    static func row(_ title: String, symbol: String, selected: Bool, count: Int = 0,
                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                ShellBadgeMark(count: count)
            }
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: Self.rowHeight)
            .foregroundStyle(.primary)
            .background(DS.Palette.accent.opacity(selected ? DS.Tint.soft : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(ShellBadge.spoken(count) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if BANANA_UNRELEASED
private struct ShellSidebarMail: View {
    let active: Bool
    let open: () -> Void
    let dismiss: () -> Void
    @ObservedObject private var application = MailApplication.shared

    var body: some View {
        if let session = application.session {
            ShellSidebarMailPlaces(session: session, navigation: session.navigation, active: active, open: open, dismiss: dismiss)
        } else if application.failed {
            Button("Retry Mail") { application.start() }
        } else {
            ProgressView().controlSize(.small).padding(DS.Space.s)
                .task { application.start() }
        }
    }
}

private struct ShellSidebarMailPlaces: View {
    let session: MailSession
    @ObservedObject var navigation: MailNavigation
    let active: Bool
    let open: () -> Void
    let dismiss: () -> Void
    @State private var accounts: [MailAccount] = []
    @State private var observation: MailObservation?

    var body: some View {
        VStack(spacing: 2) {
            if !accounts.isEmpty {
                Picker("Account", selection: Binding(
                    get: { accounts.contains { $0.id == navigation.scope.account } ? navigation.scope.account : nil },
                    set: { account in
                        show(navigation.scope.mailbox ?? .inbox, account: account)
                    }
                )) {
                    Text("All accounts").tag(nil as String?)
                    ForEach(accounts) { account in
                        Text(account.shortName.isEmpty ? account.id : account.shortName).tag(Optional(account.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("shell.mail.account")
            }
            ForEach(MailPlacesModel.all.filter { [.inbox, .starred, .sent, .drafts].contains($0.mailbox) }) { place in
                ShellSidebar.row(place.title, symbol: place.symbol, selected: active && navigation.scope.mailbox == place.mailbox) {
                    show(place.mailbox, account: navigation.scope.account)
                    dismiss()
                }
                .accessibilityIdentifier("shell.mail.\(place.mailbox.rawValue)")
            }
        }
        .onAppear {
            observation = session.source.observeAccounts { new in
                let usable = new.filter(\.wantsMail)
                if accounts != usable { accounts = usable }
            }
        }
        .onDisappear { observation = nil }
    }

    private func show(_ mailbox: MailMailbox, account: String?) {
        session.switchTo(MailScope(place: .mailbox(mailbox), account: account))
        open()
    }
}
#endif

/// The iPad's way to hide and show the rail, as a system sidebar's button does: at the toolbar's
/// leading edge, ⌃⌘S from a keyboard, kept across launches (`ShellRailVisibility`). The Mac's
/// rail is a split view column driven by the same preference, with its button explicitly leading.
struct ShellRailToggle: View {
    @AppStorage(ShellRailVisibility.key) private var shown = true

    var body: some View {
        Button { withAnimation(.snappy) { shown.toggle() } } label: {
            Image(systemName: "sidebar.leading")
        }
        #if os(iOS)
        .keyboardShortcut("s", modifiers: [.control, .command])
        #endif
        .help(shown ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(shown ? "Hide sidebar" : "Show sidebar")
        .accessibilityIdentifier("shell.railToggle")
    }
}

#if os(iOS)
/// "Search or ask" in an iPad page's toolbar.
struct ShellToolbarField: View {
    var body: some View {
        ShellWideField(search: .shared)
            .frame(minWidth: 240, idealWidth: 520, maxWidth: 560)
    }
}
#endif

/// The field itself, for a toolbar: focusing it shows what can be added under it, typing shows
/// what is found (`ShellWideResults`, drawn by the shell under the toolbar).
struct ShellWideField: View {
    static var prompt: String { ShellAssistant.isAvailable ? "Search or ask" : "Search" }

    @ObservedObject var search: ShellSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Editing is reported by the field itself: in a toolbar item `@FocusState` takes the
            // keyboard but its change never arrives, and the add list never opened.
            TextField(Self.prompt, text: $search.text, onEditingChanged: { editing in
                if search.focused != editing { search.focused = editing }
            })
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if ShellAssistant.isAvailable, ShellSearchRules.isDirectAsk(search.text) { search.ask() }
                }
                #if os(macOS)
                .onExitCommand { search.clear() }
                #endif
                .accessibilityIdentifier("shell.field")
            if search.mode != .idle {
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
        .onAppear { if search.focused { focused = true } }
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
                ToolbarItem(placement: .topBarTrailing) { ShellToolbarField() }
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
