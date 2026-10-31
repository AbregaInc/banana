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

#if os(macOS)
/// The Mac planner's one view control: Day, a few days or Week. The same two modes as the phone's switch (`PlanMode`), with
/// the Mac's choice of how many days Week shows.
struct MacPlannerViewMenu: View {
    @AppStorage("planMode") private var mode: PlanMode = .day
    @AppStorage("macWeekSpan") private var span: MacWeekSpan = .sevenDays

    enum Choice: Hashable { case day, days(Int), week }

    private var choice: Binding<Choice> {
        Binding {
            switch mode {
            case .day: return .day
            case .week: return span.isAlignedWeek ? .week : .days(span.rawValue)
            }
        } set: { new in
            switch new {
            case .day: mode = .day
            case .days(let n): mode = .week; span = MacWeekSpan(rawValue: n) ?? .sevenDays
            case .week: mode = .week; span = .sevenDays
            }
        }
    }

    var body: some View {
        // The page's switch, in the top bar, as on every device (`PageSwitch`): it was a menu
        // here, with the choice hidden until opened.
        PageSwitch(label: "View", selection: choice,
                   choices: [Choice.day, .days(3), .days(5), .week]) { choice in
            switch choice {
            case .day: PlanMode.day.title
            case .days(let n): "\(n) days"
            case .week: PlanMode.week.title
            }
        }
        .help("Day, several days or week (D, 2–7, W)")
        .accessibilityIdentifier("mac.planner.view")
    }


}
#endif

/// The Day · Week switch, in the top bar: the page switch every main page uses (`PageSwitch`).
struct PlanModePicker: View {
    var fills = false
    @AppStorage("planMode") private var mode: PlanMode = .day

    var body: some View {
        PageSwitch(label: "View", selection: $mode, choices: PlanMode.allCases, title: \.title, fills: fills)
    }
}
