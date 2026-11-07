import SwiftUI

// The controls around a page: one of each, used by every page (`PageChromeRules.swift`).
// A page never draws its own variant of one of these.

extension View {
    /// Tabs and the sidebar already name root pages. Keep titles for presented screens and
    /// native Mac windows; iPhone/iPad root toolbars reserve the centre for page controls.
    func pageNavigationTitle(_ title: String, presented: Bool = false) -> some View {
        #if os(iOS)
        modifier(PageNavigationTitle(title: title, presented: presented))
        #else
        navigationTitle(title)
        #endif
    }
}

#if os(iOS)
/// A root page's title, and in the new shells (docs/design/BOTTOM-BAR-SHELL.md) no tab bar: the
/// switcher or the rail chooses the page. Set here, inside the page's navigation stack, because
/// an iPad's floating tab strip ignores the setting from outside it.
private struct PageNavigationTitle: ViewModifier {
    let title: String
    let presented: Bool
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell

    func body(content: Content) -> some View {
        content
            .navigationTitle(presented ? title : "")
            .toolbarVisibility(bottomBarShell || wideShell ? .hidden : .automatic, for: .tabBar)
    }
}
#endif

// MARK: - The switch in the top bar

/// A page's views, in the top bar where its title would be. Plan: Day · Week. Nutrition: Food ·
/// Taken. Review: Week · Month · Year. Four words at most.
struct PageSwitch<Choice: Hashable>: View {
    let label: String
    @Binding var selection: Choice
    let choices: [Choice]
    let title: (Choice) -> String

    /// Not in a top bar (the player's): as wide as the room it has.
    var fills = false

    /// The most a phone's top bar gives it. Body's three words need the room a 393 pt screen
    /// leaves between the two buttons ("Workouts" was cut short at 204).
    var widest: CGFloat = 204

    /// Wide enough for its words and no wider: 75 pt a word, which is what Plan's two had, and
    /// never so wide that a phone's top bar pushes it off centre to fit a button beside it.
    private var width: CGFloat? {
        if fills { return nil }
        #if os(macOS)
        return CGFloat(choices.count) * 75
        #else
        return min(CGFloat(choices.count) * 75, widest)
        #endif
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(choices, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: width)
    }
}

// MARK: - The date line

/// The line under the top bar on a page that shows a day or a period: back, what is showing, a
/// way home when away from now, forward. Plan's row, lifted out so Nutrition and Review are the
/// same row and not a likeness of it.
struct DateLine<Trailing: View>: View {
    /// "Today", "This week" — what the current period is called.
    let current: String
    /// The dates on screen: "Sat, Oct 10", "Oct 5–11".
    let dates: String
    let isCurrent: Bool
    var canGoForward = true
    var loading = false
    /// "day", "week": for the arrows' spoken names.
    var unit = "day"
    /// The pill that returns to now.
    var home = "Today"
    var titleIdentifier = "dateLine.title"
    var titleValue: String?
    let step: (Int) -> Void
    let toCurrent: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        #if os(macOS)
        windowControls
        #else
        line
        #endif
    }

    #if os(macOS)
    /// On the Mac the date line is the window's (DESIGN-SYSTEM.md, the standard, 5): back,
    /// forward and the way home in the toolbar's leading group, what's showing as the window's
    /// subtitle under the page's title — the system's own places, the same on every dated page.
    private var windowControls: some View {
        let words = DateLineWording.parts(current: current, dates: dates, isCurrent: isCurrent)
        return Color.clear
            .frame(height: 0)
            .navigationSubtitle(words.dates.flatMap { $0.isEmpty ? nil : "\(words.name) \u{00B7} \($0)" } ?? words.name)
            .toolbar {
                // Plain buttons, not a ControlGroup: the window moved a group out of the leading
                // place to the far end of the toolbar, away from Today.
                ToolbarItemGroup(placement: .navigation) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .help("Previous \(unit)")
                        .accessibilityLabel("Previous \(unit)")
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .help("Next \(unit)")
                        .accessibilityLabel("Next \(unit)")
                        .disabled(!canGoForward)
                    Button(home) { toCurrent() }
                        .disabled(isCurrent)
                        .accessibilityLabel("Return to \(home.lowercased())")
                        .accessibilityIdentifier("dateLine.home")
                }
                ToolbarItem(placement: .automatic) { trailing }
            }
            .accessibilityIdentifier(titleIdentifier)
            .accessibilityValue(titleValue ?? dates)
    }
    #endif

    private var line: some View {
        let words = DateLineWording.parts(current: current, dates: dates, isCurrent: isCurrent)
        return HStack(spacing: 4) {
            arrow("chevron.left", "Previous \(unit)") { step(-1) }

            HStack(spacing: 6) {
                Text(words.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let dates = words.dates {
                    Text(dates)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if loading {
                    ProgressView().controlSize(.mini)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(titleIdentifier)
            .accessibilityValue(titleValue ?? dates)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isCurrent { toCurrent() }
            }

            Spacer(minLength: 0)
            trailing
            if !isCurrent {
                Button(home) { toCurrent() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Return to \(home.lowercased())")
                    .accessibilityIdentifier("dateLine.home")
            }
            arrow("chevron.right", "Next \(unit)") { step(1) }
                .disabled(!canGoForward)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .contentShape(Rectangle())
        // On the line and not the page under it, which scrolls.
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            let horizontal = value.translation.width
            guard abs(horizontal) > abs(value.translation.height) * 1.4 else { return }
            let delta = DateLineWording.step(forSwipe: horizontal)
            if delta < 0 || canGoForward { step(delta) }
        })
    }

    private func arrow(_ symbol: String, _ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .help(name)
    }
}

extension DateLine where Trailing == EmptyView {
    init(current: String, dates: String, isCurrent: Bool, canGoForward: Bool = true, loading: Bool = false,
         unit: String = "day", home: String = "Today", titleIdentifier: String = "dateLine.title",
         titleValue: String? = nil, step: @escaping (Int) -> Void, toCurrent: @escaping () -> Void) {
        self.init(current: current, dates: dates, isCurrent: isCurrent, canGoForward: canGoForward,
                  loading: loading, unit: unit, home: home, titleIdentifier: titleIdentifier,
                  titleValue: titleValue, step: step, toCurrent: toCurrent) { EmptyView() }
    }
}

// MARK: - Add

/// A page's +, in its top bar on every device (DESIGN-SYSTEM.md, the standard): the system's
/// toolbar button, so it wears the bar's glass. On a phone it opens the one list of everything
/// that can be added, this page's own first (`AddList`). On an iPad and the Mac, the page's own:
/// one kind opens at once, several open a short menu, and a page with nothing of its own to add
/// opens that same list (on an iPad; the Mac's has no +).
private struct AddButton<Items: View>: ViewModifier {
    let identifier: String
    let action: (() -> Void)?
    /// Whether the page has anything of its own to add (Workouts has none: on a phone and an iPad
    /// its + is the list's; the Mac's has no +).
    var ownItems = true
    @ViewBuilder let items: Items

    /// A phone's shell: one list of every kind of thing, behind every page's +.
    @Environment(\.addOpensList) private var phoneShell
    /// Both new shells add from their field (focused with nothing typed): no + in the top row.
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell

    func body(content: Content) -> some View {
        if bottomBarShell || wideShell {
            content
        } else {
            classic(content)
        }
    }

    @ViewBuilder private func classic(_ content: Content) -> some View {
        #if os(macOS) && PI_DEVELOPMENT
        // The window's Ask or add control owns the single desktop entry point.
        content
        #elseif os(macOS)
        content.toolbar {
            if ownItems { ToolbarItem(placement: .primaryAction) { control } }
        }
        #elseif PI_DEVELOPMENT
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { PageChrome.shared.showAssistant = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                    .accessibilityLabel("Ask or add")
                    .accessibilityIdentifier(identifier)
            }
        }
        #else
        content.toolbar {
            if phoneShell || !ownItems {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { PageChrome.shared.showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add")
                        .accessibilityIdentifier(identifier)
                }
            } else if ownItems {
                ToolbarItem(placement: .topBarTrailing) { control }
            }
        }
        #endif
    }

    @ViewBuilder private var control: some View {
        #if PI_DEVELOPMENT
        // The same sheet as a phone's +: words first, this page's kinds right under them.
        Button { PageChrome.shared.showAdd = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("Add")
            .accessibilityIdentifier(identifier)
        #else
        if let action {
            Button(action: action) { Image(systemName: "plus") }
                .accessibilityLabel("Add")
                .accessibilityIdentifier(identifier)
        } else {
            Menu { items } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add")
                .accessibilityIdentifier(identifier)
        }
        #endif
    }
}

extension View {
    /// A page that adds one kind of thing.
    func addButton(identifier: String = "page.add", action: @escaping () -> Void) -> some View {
        modifier(AddButton(identifier: identifier, action: action) { EmptyView() })
    }

    /// A page that adds more than one kind of thing: the menu's items. (`clearsList` is from
    /// when the + floated over the page's last row; it's in the bar now.)
    func addMenu<Items: View>(identifier: String = "page.add", clearsList: Bool = true,
                              @ViewBuilder _ items: () -> Items) -> some View {
        modifier(AddButton(identifier: identifier, action: nil, items: items))
    }

    /// A page with nothing of its own to add: on a phone its + still opens the list of
    /// everything, as every page's does.
    func addListButton(identifier: String) -> some View {
        modifier(AddButton(identifier: identifier, action: nil, ownItems: false) { EmptyView() })
    }
}

// MARK: - The list of everything a + can add

extension EnvironmentValues {
    /// Whether every page's + opens the one list of everything (`AddList`): a shell with its tab
    /// bar at the bottom of the screen (a phone, an iPad narrowed into a split), not a sidebar.
    @Entry var addOpensList = false
    /// The page is in the bottom-bar shell (docs/design/BOTTOM-BAR-SHELL.md): its top row is a
    /// title menu and "…", Review and Settings are in the switcher, and adding is in the field.
    @Entry var bottomBarShell = false
    /// The page is in the wide shell (the rail and one toolbar): its toolbar is its title menu,
    /// "Search or ask" in the middle, the assistant and "…"; Review and Settings are in the rail.
    @Entry var wideShell = false
    /// A split view's list column in the wide shell: its narrow bar drops a centre item, so the
    /// field and the assistant go on the detail column's bar (`shellDetailToolbar`).
    @Entry var shellFieldInDetail = false
}

/// A page's answer to the list a + opens: the kinds it starts, and how.
private struct AddHandler: ViewModifier {
    let kinds: Set<AddKind>
    let perform: (AddKind) -> Void
    @ObservedObject private var chrome = PageChrome.shared

    func body(content: Content) -> some View {
        content
            // A tab not opened yet is built by the pick, and finds it waiting.
            .onAppear(perform: take)
            .onChange(of: chrome.pendingAdd) { _, _ in take() }
    }

    private func take() {
        guard let kind = chrome.pendingAdd, kinds.contains(kind) else { return }
        chrome.pendingAdd = nil
        perform(kind)
    }
}

extension View {
    /// Starts these kinds when they are picked from the list a + opens.
    func onAdd(_ kinds: AddKind..., perform: @escaping (AddKind) -> Void) -> some View {
        modifier(AddHandler(kinds: Set(kinds), perform: perform))
    }
}

/// The list a + opens: everything that can be added, this tab's own first.
struct AddList: View {
    let current: AppSection
    let pick: (AddKind) -> Void
    @ObservedObject private var modules = ModuleStore.shared

    var body: some View {
        List {
            ForEach(AddKind.groups(for: current, with: modules.effectiveChoice), id: \.section) { group in
                // Nutrition's page and tab say Food.
                Section(group.section == .nutrition ? "Food" : group.section.title) {
                    ForEach(group.kinds) { kind in
                        Button { pick(kind) } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                        .tint(.primary)
                        .accessibilityIdentifier(kind.identifier)
                    }
                }
            }
        }
        .accessibilityIdentifier("page.add.list")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Workouts and Nutrition share a tab where the bar is at the bottom: the one switch across
/// both (`BodyPage`), where the page's title was.
struct BodySwitch: View {
    var wide = false
    @ObservedObject private var shell = ShellNavigation.shared
    @ObservedObject private var badges = ActionBadges.shared
    @ObservedObject private var modules = ModuleStore.shared

    private var selection: Binding<BodyPage> {
        Binding(
            get: { BodyPage(section: shell.state.tab, nutritionSection: shell.state.nutritionSection, wide: wide) },
            set: { page in
                if !wide, let half = page.nutritionSection { shell.state.nutritionSection = half }
                shell.state.tab = page.section
            })
    }

    var body: some View {
        PageSwitch(label: "Body section", selection: selection, choices: BodyPage.choices(wide: wide, with: modules.effectiveChoice), title: { page in
            // What's waiting in each: meals to log, doses due and not marked.
            let count = wide ? 0 : page == .food ? badges.counts.food : page == .taken ? badges.counts.taken : 0
            return count > 0 ? "\(page.title(wide: wide)) · \(count)" : page.title(wide: wide)
        }, widest: 214)
        .accessibilityIdentifier("body.switch")
    }
}

private struct BodySwitchToolbar: ViewModifier {
    let wide: Bool
    @Environment(\.addOpensList) private var inTabBar
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell
    @ObservedObject private var modules = ModuleStore.shared

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            if bottomBarShell || wideShell {
                // The page's name, with the other Body pages under its chevron.
                ToolbarItem(placement: .topBarLeading) { BodyTitleMenu(wide: wide) }
            } else if inTabBar, BodyPage.choices(wide: wide, with: modules.effectiveChoice).count > 1 {
                // One page left (Workouts alone) has nothing to switch to: no principal item, so
                // the centre stays clear; the selected tab already names the page.
                ToolbarItem(placement: .principal) { BodySwitch(wide: wide) }
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    /// For a Body page with no switch of its own in the top bar.
    func bodySwitch(wide: Bool = false) -> some View { modifier(BodySwitchToolbar(wide: wide)) }
}

// MARK: - Review, Settings and Routines from any page

/// What a page's chrome can open that belongs to the whole app: Review from the chart button,
/// Settings and Routines from "…". Shown by the shell, so every tab opens the same thing.
@MainActor
final class PageChrome: ObservableObject {
    static let shared = PageChrome()

    /// Review, open on the tab it was asked for from.
    @Published var review: AppSection?
    /// The tab Review was last asked for from, for where it is a sidebar section and not a sheet.
    var reviewFrom: AppSection = .plan
    @Published var showSettings = false
    /// A page's + was tapped: the list of everything is up.
    @Published var showAdd = false
    /// Words typed on a page for the + sheet to start on (Nutrition's line, with Pi).
    var agentPrefill: String?
    /// What was picked from it, for its page to start.
    @Published var pendingAdd: AddKind?
    /// Picked, and waiting for the list to be gone: a page's sheet cannot open under it.
    var pickedAdd: AddKind?
    @Published var showRoutines = false
    @Published var showAssistant = false
    var assistantDestination: AppSection?
}

/// The chart button at the top left of every main page: Review, on this page's subject.
struct ReviewToolbarItem: ToolbarContent {
    let section: AppSection
    @ObservedObject private var modules = ModuleStore.shared
    /// In the bottom-bar shell Review is in the switcher.
    @Environment(\.bottomBarShell) private var bottomBarShell
    /// In the wide shell Review is in the rail, and every page's toolbar has the field and the
    /// assistant in its place: this item, which every main page has, puts them there.
    @Environment(\.wideShell) private var wideShell
    @Environment(\.shellFieldInDetail) private var fieldInDetail

    var body: some ToolbarContent {
        #if os(iOS)
        if wideShell, !fieldInDetail {
            ToolbarItem(placement: .principal) { ShellToolbarField() }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { ShellAIButton() }
        }
        ToolbarItem(placement: .topBarLeading) {
            // Nothing to look back on with every module that Review covers switched off.
            if !bottomBarShell, !wideShell, !ReviewSubject.shown(with: modules.effectiveChoice).isEmpty {
                Button { PageChrome.shared.review = section } label: {
                    Image(systemName: "chart.bar.fill")
                }
                .accessibilityLabel("Review")
                .accessibilityIdentifier("page.review")
            }
        }
        #else
        // The Mac's sidebar lists Review; a second way in would be noise.
        ToolbarItemGroup(placement: .automatic) {}
        #endif
    }
}

/// "…" at the top right of a main page: what this page offers beyond its main job, then
/// Settings, always last.
struct MoreMenu<Items: View>: View {
    var identifier = "page.more"
    @ViewBuilder var items: Items
    /// A sidebar shell has Routines as a tab of its own.
    @Environment(\.addOpensList) private var tabBarShell
    /// The bottom-bar shell has Settings in the switcher and the assistant on the bar; the wide
    /// shell has them in the rail and the toolbar, and Routines here (it has no rail button).
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell

    var body: some View {
        Menu {
            items
            #if os(iOS)
            Divider()
            if tabBarShell || wideShell || bottomBarShell {
                Button { PageChrome.shared.showRoutines = true } label: {
                    Label("Routines", systemImage: "repeat")
                }
                .accessibilityIdentifier("page.more.routines")
            }
            if !bottomBarShell && !wideShell {
                #if BANANA_AI && !PI_DEVELOPMENT
                Button { PageChrome.shared.showAssistant = true } label: {
                    Label("Assistant", systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityIdentifier("page.more.assistant")
                #endif
                Button { PageChrome.shared.showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("page.more.settings")
            }
            #else
            // The rail has no Routines button: it is here, as on a phone.
            if wideShell {
                Divider()
                Button { MacNavigator.shared.section = .routines } label: {
                    Label("Routines", systemImage: "repeat")
                }
                .accessibilityIdentifier("page.more.routines")
            }
            #endif
        } label: {
            // The plain glyph: the bar draws the glass circle around it, as the system's own do.
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier(identifier)
    }
}

extension MoreMenu where Items == EmptyView {
    init(identifier: String = "page.more") {
        self.init(identifier: identifier) { EmptyView() }
    }
}


// MARK: - The bottom-bar shell's top row

/// A page's one top row in the bottom-bar shell: its name, and under the chevron what the page
/// switches between (Plan: Day and Week; Mail: places and accounts; Body: its pages). A count
/// beside it says what is waiting. The bar draws the glass around it.
struct PageTitleMenu<Items: View>: View {
    let title: String
    var subtitle: String? = nil
    var badge = 0
    var identifier = "page.title"
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            PageTitleLabel(title: title, subtitle: subtitle, badge: badge, chevron: true)
        }
        .menuIndicator(.hidden)
        // The name in ink, as the approved design has it: a toolbar tints its items' labels.
        .tint(.primary)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) waiting" : title)
        .accessibilityIdentifier(identifier)
    }
}

/// A page name with nothing under it (Notes, Library): the same words, no chevron.
struct PageTitleText: View {
    let title: String
    var identifier = "page.title"

    var body: some View {
        PageTitleLabel(title: title, subtitle: nil, badge: 0, chevron: false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }
}

private struct PageTitleLabel: View {
    let title: String
    let subtitle: String?
    let badge: Int
    let chevron: Bool
    /// A page with room (an iPad upright) has the dates beside the name on one line ("This week
    /// ⌄ Nov 2–8"); a phone has them under it.
    @Environment(\.layoutClass) private var layoutClass

    var body: some View {
        HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                if let subtitle, layoutClass == .compact {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            if let subtitle, layoutClass == .regular {
                Text(subtitle).font(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            if badge > 0 {
                Text("\(badge)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DS.Palette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DS.Palette.accent.opacity(DS.Tint.soft), in: Capsule())
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .fixedSize()
    }
}

extension View {
    /// The page's name at the left of its top row in the bottom-bar shell (a page with nothing
    /// to switch between). Nothing elsewhere: the tab or the sidebar names it there.
    func shellPageTitle(_ title: String) -> some View {
        modifier(ShellPageTitle(title: title))
    }
}

private struct ShellPageTitle: ViewModifier {
    let title: String
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            if bottomBarShell || wideShell {
                ToolbarItem(placement: .topBarLeading) { PageTitleText(title: title) }
            }
        }
        #else
        content
        #endif
    }
}

/// Body's title in the bottom-bar shell: the page showing (Workouts, Food or Taken), and the
/// others under its chevron, with what is waiting in each.
struct BodyTitleMenu: View {
    /// Workouts and Food alone (a wide screen keeps Taken inside Food).
    var wide = false
    @ObservedObject private var shell = ShellNavigation.shared
    @ObservedObject private var badges = ActionBadges.shared
    @ObservedObject private var modules = ModuleStore.shared

    var body: some View {
        let current = BodyPage(section: shell.state.tab, nutritionSection: shell.state.nutritionSection, wide: wide)
        let choices = BodyPage.choices(wide: wide, with: modules.effectiveChoice)
        let waiting = badges.counts.food + badges.counts.taken
        if choices.count > 1 {
            PageTitleMenu(title: current.title(wide: wide), badge: waiting, identifier: "body.title") {
                Picker("Body section", selection: Binding(
                    get: { current },
                    set: { page in
                        if !wide, let half = page.nutritionSection { shell.state.nutritionSection = half }
                        shell.state.tab = page.section
                    })) {
                    ForEach(choices, id: \.self) { page in
                        let count = page == .food ? badges.counts.food : page == .taken ? badges.counts.taken : 0
                        Text(count > 0 ? "\(page.title(wide: wide)) · \(count)" : page.title(wide: wide)).tag(page)
                    }
                }
                .pickerStyle(.inline)
            }
        } else {
            PageTitleText(title: current.title(wide: wide), identifier: "body.title")
        }
    }
}
