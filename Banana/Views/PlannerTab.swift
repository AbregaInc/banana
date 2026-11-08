import SwiftUI

#if os(macOS)
enum MacWeekSpan: Int, CaseIterable, Identifiable {
    case twoDays = 2
    case threeDays = 3
    case fourDays = 4
    case fiveDays = 5
    case sixDays = 6
    case sevenDays = 7

    var id: Int { rawValue }
    var title: String { isAlignedWeek ? "Week" : "\(rawValue) Days" }

    /// "Week" is the calendar week (honors the configured week start; pages by week).
    /// Every other span is a rolling window whose anchor puts TODAY in the first
    /// column — usable on any day, weekend included, and "Today" always lands on today.
    var isAlignedWeek: Bool { self == .sevenDays }
}
#endif

/// The primary tab: one timeline at two zoom levels (`PlanMode`). The phone's Day · Week switch
/// and the Mac's view menu flip between them; the choice persists.
struct PlannerTab: View, Equatable {
    @AppStorage("planMode") private var mode: PlanMode = .day
    @ObservedObject private var visibility = AppVisibility.shared
    /// The old "agenda" layout of Week — a "…" setting on the phone, a Calendar/Agenda choice on
    /// the Mac. It is the List now on both: whoever had picked it starts there.
    @AppStorage(PlannerTab.legacyLayoutKey) private var legacyLayout = "calendar"
    #if os(macOS)
    private static let legacyLayoutKey = "macWeekLayout"
    #else
    private static let legacyLayoutKey = "mobileWeekLayout"
    #endif

    static func == (_ lhs: PlannerTab, _ rhs: PlannerTab) -> Bool { true }

    var body: some View {
        let _ = RenderStats.note("PlannerTab")

        // The timeline does not exist while nobody is looking at it.
        //
        // This app plays audio, so it keeps running with the screen off and the phone in a pocket —
        // and it kept RENDERING there too. The journal caught the whole day: the tree re-rendering
        // ~7x/second in the background, and once, 154x/second, until iOS killed the process for
        // burning a core. Three kills in one day.
        //
        // I could not find the publisher driving it, and I could not reproduce it on a test rig that
        // matched every condition I could control. So rather than keep guessing at the cause, remove
        // the consequence: a backgrounded view has nothing to draw and nobody to draw it for, so
        // give SwiftUI a body with nothing in it. Whatever is publishing can then invalidate an
        // empty view as fast as it likes and it costs nothing — the storm still happens, but it
        // stops being fatal.
        //
        // It costs nothing to come back: the view rebuilds on foreground, which is exactly what a
        // fresh `.task` and a re-read of the occurrence store already do.
        Group {
        if visibility.rendersContent {
            // What the old agenda setting meant, before `onAppear` has stored it: no frame of
            // the Week grid first.
            switch mode.retiringAgendaLayout(legacyLayout == "agenda") {
            case .day:
                #if os(macOS)
                MacWeekView(dayMode: true)
                #else
                WeekView(dayMode: true)
                #endif
            case .week:
                #if os(macOS)
                MacWeekView()
                #else
                WeekView()
                #endif
            }
        } else {
            Color.clear   // in your pocket
        }
        }
        .onAppear {
            guard legacyLayout == "agenda" else { return }
            mode = mode.retiringAgendaLayout(true)
            legacyLayout = "calendar"
        }
    }
}

/// Plan's period picker: the period's name with a chevron and its dates beside it; under the
/// chevron Day and Week (the Mac adds 3 and 5 days). The middle of the wide toolbar's paging
/// group (`PlanPagingToolbar`): one view on an iPad on its side and the Mac, so they can't drift.
struct PlanPeriodMenu: View {
    /// The dates on screen (`PlanPaging.dates`): beside the name, and its spoken value.
    let dates: String
    @AppStorage("planMode") private var mode: PlanMode = .day
    #if os(macOS)
    @AppStorage("macWeekSpan") private var span: MacWeekSpan = .sevenDays
    static let identifier = "mac.planner.view"
    static let choices: [Choice] = [.day, .days(3), .days(5), .week]
    #else
    static let identifier = "plan.mode"
    static let choices: [Choice] = [.day, .week]
    #endif

    enum Choice: Hashable { case day, days(Int), week }

    private var choice: Binding<Choice> {
        Binding {
            #if os(macOS)
            if mode == .week, !span.isAlignedWeek { return .days(span.rawValue) }
            #endif
            return mode == .day ? .day : .week
        } set: { new in
            mode = new == .day ? .day : .week
            #if os(macOS)
            switch new {
            case .day: break
            case .days(let n): span = MacWeekSpan(rawValue: n) ?? .sevenDays
            case .week: span = .sevenDays
            }
            #endif
        }
    }

    private func name(_ choice: Choice) -> String {
        switch choice {
        case .day: PlanMode.day.title
        case .days(let n): "\(n) days"
        case .week: PlanMode.week.title
        }
    }

    var body: some View {
        PageTitleMenu(title: name(choice.wrappedValue), subtitle: dates.isEmpty ? nil : dates,
                      identifier: Self.identifier) {
            Picker("View", selection: choice) {
                ForEach(Self.choices, id: \.self) { Text(name($0)).tag($0) }
            }
            .pickerStyle(.inline)
        }
        // The dates beside the name on one line, whatever width class the toolbar reports.
        .environment(\.layoutClass, .regular)
        .accessibilityValue(dates)
        #if os(macOS)
        .help("Day, several days or week (D, 2–7, W)")
        #endif
    }
}

/// Plan's paging in a wide toolbar (an iPad on its side, the Mac; docs/design/BOTTOM-BAR-SHELL.md):
/// "‹", the period picker and "›" as one group, then Today on its own, idle on the current period
/// (`PlanPaging`). `accessory` follows: the forecast, and a spinner while the dates load.
struct PlanPagingToolbar<Accessory: View>: ToolbarContent {
    /// The days on screen: 1 in Day, the span in Week.
    let days: Int
    let dates: String
    let isCurrent: Bool
    let step: (Int) -> Void
    let toCurrent: () -> Void
    @ViewBuilder let accessory: Accessory

    #if os(macOS)
    private static var leading: ToolbarItemPlacement { .navigation }
    #else
    private static var leading: ToolbarItemPlacement { .topBarLeading }
    #endif

    /// A pointer's tooltip; on the Mac with the key that does the same.
    private static func help(_ text: String, key: String) -> String {
        #if os(macOS)
        "\(text) (\(key))"
        #else
        text
        #endif
    }

    var body: some ToolbarContent {
        let labels = PlanTopRow.stepLabels(days: days)
        ToolbarItemGroup(placement: Self.leading) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .help(Self.help(labels.previous, key: "K"))
                .accessibilityLabel(labels.previous)
                .accessibilityIdentifier("plan.previous")
            PlanPeriodMenu(dates: dates)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .help(Self.help(labels.next, key: "J"))
                .accessibilityLabel(labels.next)
                .accessibilityIdentifier("plan.next")
        }
        ToolbarSpacer(.fixed, placement: Self.leading)
        ToolbarItem(placement: Self.leading) {
            Button("Today") { toCurrent() }
                .disabled(!PlanPaging.todayEnabled(isCurrent: isCurrent))
                .help(Self.help("Go to today", key: "T"))
                .accessibilityIdentifier("plan.today")
        }
        ToolbarItem(placement: Self.leading) {
            HStack(spacing: DS.Space.s) { accessory }.fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// The Day · Week switch outside both shells: the page switch every main page uses (`PageSwitch`).
struct PlanModePicker: View {
    var fills = false
    var widest: CGFloat = 204
    @AppStorage("planMode") private var mode: PlanMode = .day

    var body: some View {
        PageSwitch(label: "View", selection: $mode, choices: PlanMode.allCases, title: \.title, fills: fills, widest: widest)
    }
}
