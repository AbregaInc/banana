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
/// chevron Day and Week (the Mac adds 3 and 5 days). The middle of Plan's paging group in every
/// shell (`PlanPagingToolbar`, `PlanPagingRow`), so no two of them can drift.
struct PlanPeriodMenu: View {
    /// The dates on screen (`PlanPaging.dates`): its spoken value, and shown beside the name, or
    /// under it and then not at all where the row is narrow (`datesPlace`).
    let dates: String
    var datesPlace = DatesPlace.beside
    enum DatesPlace: Hashable { case beside, under, hidden }
    /// What needs attention (the bottom-bar shell, which has no row for it): a count beside the
    /// name and the list first under the chevron (`PlanAttentivePeriodMenu`).
    var attentionCount = 0
    var attentionSummary = ""
    var openAttention: (() -> Void)? = nil
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
        PageTitleMenu(title: name(choice.wrappedValue), subtitle: datesPlace != .hidden && !dates.isEmpty ? dates : nil,
                      badge: attentionCount, identifier: Self.identifier) {
            if attentionCount > 0, let openAttention {
                Button { openAttention() } label: {
                    Label("Needs attention", systemImage: "tray.full")
                    Text(attentionSummary)
                }
                .accessibilityIdentifier("plan.attention")
            }
            Picker("View", selection: choice) {
                ForEach(Self.choices, id: \.self) { Text(name($0)).tag($0) }
            }
            .pickerStyle(.inline)
        }
        // Beside or under the name as asked, whatever width class the bar reports.
        .environment(\.layoutClass, datesPlace == .under ? .compact : .regular)
        .accessibilityValue(dates)
        #if os(macOS)
        .help("Day, several days or week (D, 2–7, W)")
        #endif
    }
}

/// "‹" or "›" of Plan's paging group: a day in Day, the span in Week. `framed` gives it a 44-point
/// target of its own where no toolbar sizes it (`PlanPagingRow`).
struct PlanStepButton: View {
    let delta: Int
    let days: Int
    var framed = false
    let step: (Int) -> Void

    var body: some View {
        let labels = PlanTopRow.stepLabels(days: days)
        let name = delta < 0 ? labels.previous : labels.next
        Button { step(delta) } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .frame(width: framed ? 44 : nil, height: framed ? 44 : nil)
                .contentShape(Rectangle())
        }
        .help(PlanPaging.help(name, key: delta < 0 ? "K" : "J"))
        .accessibilityLabel(name)
        .accessibilityIdentifier(delta < 0 ? "plan.previous" : "plan.next")
    }
}

/// Today of Plan's paging group: always there, so the group never shifts; idle on the current period.
struct PlanTodayButton: View {
    let isCurrent: Bool
    var framed = false
    let toCurrent: () -> Void

    var body: some View {
        Button { toCurrent() } label: {
            Text("Today")
                .padding(.horizontal, framed ? DS.Space.m : 0)
                .frame(minHeight: framed ? 44 : nil)
                .contentShape(Rectangle())
        }
        .disabled(!PlanPaging.todayEnabled(isCurrent: isCurrent))
        .help(PlanPaging.help("Go to today", key: "T"))
        .accessibilityIdentifier("plan.today")
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

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: Self.leading) {
            PlanStepButton(delta: -1, days: days, step: step)
            PlanPeriodMenu(dates: dates)
            PlanStepButton(delta: 1, days: days, step: step)
        }
        ToolbarSpacer(.fixed, placement: Self.leading)
        ToolbarItem(placement: Self.leading) {
            PlanTodayButton(isCurrent: isCurrent, toCurrent: toCurrent)
        }
        ToolbarItem(placement: Self.leading) {
            HStack(spacing: DS.Space.s) { accessory }.fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

#if os(iOS)
/// The same group as a row of its own: the bottom-bar shell's top row (a phone, an iPad upright),
/// whose hidden bar would fold it into an overflow menu. Glass capsules, as the bar's would be;
/// the period picker carries what needs attention there (`PlanAttentivePeriodMenu`).
struct PlanPagingRow: View {
    let days: Int
    let dates: String
    let isCurrent: Bool
    var datesPlace = PlanPeriodMenu.DatesPlace.beside
    let step: (Int) -> Void
    let toCurrent: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 0) {
                PlanStepButton(delta: -1, days: days, framed: true, step: step)
                PlanAttentivePeriodMenu(dates: dates, datesPlace: datesPlace)
                    .frame(minHeight: 44)
                PlanStepButton(delta: 1, days: days, framed: true, step: step)
            }
            .font(.body.weight(.medium))
            .glassEffect(.regular.interactive(), in: .capsule)
            PlanTodayButton(isCurrent: isCurrent, framed: true, toCurrent: toCurrent)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .fixedSize()
    }
}
#endif

/// The Day · Week switch outside both shells: the page switch every main page uses (`PageSwitch`).
struct PlanModePicker: View {
    var fills = false
    var widest: CGFloat = 204
    @AppStorage("planMode") private var mode: PlanMode = .day

    var body: some View {
        PageSwitch(label: "View", selection: $mode, choices: PlanMode.allCases, title: \.title, fills: fills, widest: widest)
    }
}
