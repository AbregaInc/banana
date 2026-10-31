import SwiftUI
import Charts

// MARK: - Grouping and formatting

extension MetricKind {
    /// Where a metric sits on the Trends page.
    enum TrendGroup: String, CaseIterable, Identifiable {
        case activity = "Activity"
        case heart = "Heart & recovery"
        case body = "Body"
        var id: String { rawValue }
    }

    var trendGroup: TrendGroup {
        switch self {
        case .steps, .exercise, .activeEnergy, .flightsClimbed, .walkingSpeed: .activity
        case .restingHR, .hrv, .walkingHeartRate, .respiratory, .vo2Max, .sleep: .heart
        case .bodyMass, .bodyFat, .leanBodyMass, .bodyMassIndex, .basalEnergy, .height: .body
        }
    }

    #if DEBUG
    /// `--trend <trendID>`: open that metric's trend (layout harness, phone and Mac).
    static var launchArgument: MetricKind? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--trend"), i + 1 < args.count else { return nil }
        return MetricKind(trendID: args[i + 1])
    }
    #endif

    /// Height doesn't trend. Grouped as the Trends page shows them: activity first.
    static var trendKinds: [MetricKind] {
        TrendGroup.allCases.flatMap { group in allCases.filter { $0.trendGroup == group && $0 != .height } }
    }

    /// A value split for `StatValue`, with "/day" on totals: ("20,899", "/day"), ("850", "kcal/day").
    func trendValue(_ value: Double?) -> (value: String?, unit: String?) {
        guard let value else { return (nil, nil) }
        let parts = StatValue.split(format(value))
        guard isCumulative else { return parts }
        return (parts.value, (parts.unit ?? "") + "/day")
    }
}

extension MetricTrend {
    var tint: Color {
        switch isBetter {
        case true?: DS.Palette.success
        case false?: DS.Palette.danger
        case nil: .secondary
        }
    }

    /// "↑ 19%", "↓ 4%", "Flat" — nil when there's nothing to compare.
    var changeText: String? {
        guard let change, let direction else { return nil }
        switch direction {
        case .flat: return "Flat"
        case .up: return "\u{2191} \(Int((abs(change) * 100).rounded()))%"
        case .down: return "\u{2193} \(Int((abs(change) * 100).rounded()))%"
        }
    }
}

/// The trends shown for a period, from the synced daily series — the same on the phone and Mac.
@MainActor enum TrendsData {
    static func trends(_ health: HealthKitStore, current: TrendSpan, previous: TrendSpan,
                       now: Date = Date()) -> [MetricTrend] {
        MetricKind.trendKinds.compactMap { kind in
            let daily = kind.series(health.trends)
            guard !daily.isEmpty else { return nil }
            let trend = MetricTrends.trend(kind, daily: daily, current: current, previous: previous,
                                           calendar: .app, now: now)
            return trend.currentValue == nil && trend.previousValue == nil ? nil : trend
        }
    }
}

// MARK: - Pieces

/// "↑ 19%" in the colour of good or bad news.
struct TrendChangeBadge: View {
    let trend: MetricTrend

    var body: some View {
        Text(trend.changeText ?? DS.placeholder)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(trend.changeText == nil ? .secondary : trend.tint)
    }
}

/// Two windows drawn over each other: this one in colour, the one before faded behind it.
struct TrendSparkline: View {
    let current: [MetricTrends.ChartPoint]
    let previous: [MetricTrends.ChartPoint]
    let days: Int
    var color: Color = DS.Palette.accent

    var body: some View {
        GeometryReader { geo in
            let values = (current + previous).map(\.value)
            if let lo = values.min(), let hi = values.max() {
                let range = hi - lo
                let pad: CGFloat = 3
                let point = { (p: MetricTrends.ChartPoint) -> CGPoint in
                    let x = geo.size.width * CGFloat(p.day) / CGFloat(max(1, days - 1))
                    let norm = range > 0 ? (p.value - lo) / range : 0.5
                    return CGPoint(x: x, y: pad + (1 - CGFloat(norm)) * (geo.size.height - 2 * pad))
                }
                ZStack {
                    path(previous.map(point))
                        .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 2]))
                    path(current.map(point))
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func path(_ points: [CGPoint]) -> Path {
        var p = Path()
        guard points.count > 1 else { return p }
        p.addLines(points)
        return p
    }
}

/// One metric in a list: this window's value, how it compares, and the two windows drawn over
/// each other.
struct TrendCard: View {
    let trend: MetricTrend
    let daily: [MetricPoint]
    let window: Int

    var body: some View {
        let chart = MetricTrends.overlay(trend.kind, daily: daily, current: trend.current, previous: trend.previous,
                                         bucketDays: Self.bucketDays(window), calendar: .app)
        let value = trend.kind.trendValue(trend.currentValue)
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Label(trend.kind.title, systemImage: trend.kind.icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    StatValue(label: nil, value: value.value, unit: value.unit, size: .row)
                    TrendChangeBadge(trend: trend)
                }
                if let previous = trend.previousValue {
                    Text("was \(trend.kind.trendText(previous))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s)
            TrendSparkline(current: chart.current, previous: chart.previous, days: window,
                           color: trend.tint == .secondary ? DS.Palette.accent : trend.tint)
                .frame(width: 84, height: 32)
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
    }

    static func bucketDays(_ window: Int) -> Int {
        window <= 31 ? 1 : window <= 92 ? 7 : 14
    }
}

extension MetricKind {
    /// Flat text for a value with its per-day unit: "17,578/day".
    func trendText(_ value: Double) -> String {
        let parts = trendValue(value)
        return [parts.value, parts.unit].compactMap { $0 }.joined(separator: parts.unit?.hasPrefix("/") == true ? "" : " ")
    }
}

// MARK: - A metric in full

/// One metric: the window you pick drawn against the one before it, what each came to, and
/// every window side by side — this week's move next to this year's.
struct TrendDetailView: View {
    @EnvironmentObject private var health: HealthKitStore
    let kind: MetricKind
    @State var window: TrendWindow

    var body: some View {
        let daily = kind.series(health.trends)
        let now = Date()
        let spans = MetricTrends.spans(window: window, calendar: .app, now: now)
        let trend = MetricTrends.trend(kind, daily: daily, current: spans.current, previous: spans.previous,
                                       calendar: .app, now: now)
        let ladder = MetricTrends.ladder(kind, daily: daily, calendar: .app, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                // No span picker here: Review's switch is the app's one (`ReviewSpan`), and this
                // opens on the span it was set to. "Every window" below still compares them all.
                headline(trend)
                chart(trend, daily: daily)
                    .frame(height: 220)
                stats(trend)
                ladderTable(ladder)
                    .accessibilityHint(method)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .groupedPage()
        .navigationTitle(kind.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var method: String {
        kind.isCumulative
            ? "Finished days only \u{2014} today counts once it\u{2019}s over. Each window is its daily average, so a week and a month compare fairly; a day with nothing recorded counts as nothing done."
            : "Finished days only \u{2014} today counts once it\u{2019}s over. Each window is the average of its readings."
    }

    private func headline(_ trend: MetricTrend) -> some View {
        let value = kind.trendValue(trend.currentValue)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Last \(window.title)").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                StatValue(label: nil, value: value.value, unit: value.unit, size: .hero)
                TrendChangeBadge(trend: trend).font(.title3)
            }
            if let previous = trend.previousValue {
                Text("The \(window.title) before: \(kind.trendText(previous))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The window in colour, the one before it dashed, on the same days of the axis.
    private func chart(_ trend: MetricTrend, daily: [MetricPoint]) -> some View {
        let points = MetricTrends.overlay(kind, daily: daily, current: trend.current, previous: trend.previous,
                                          bucketDays: window.chartBucketDays, calendar: .app)
        let start = trend.current.start
        func date(_ day: Int) -> Date { Calendar.app.date(byAdding: .day, value: day, to: start) ?? start }
        return Chart {
            ForEach(points.previous, id: \.day) { p in
                LineMark(x: .value("Day", date(p.day)), y: .value(kind.title, kind.displayValue(p.value)),
                         series: .value("Window", "Before"))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            ForEach(points.current, id: \.day) { p in
                LineMark(x: .value("Day", date(p.day)), y: .value(kind.title, kind.displayValue(p.value)),
                         series: .value("Window", "This"))
                    .foregroundStyle(DS.Palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .interpolationMethod(.monotone)
            }
            if let current = trend.currentValue {
                RuleMark(y: .value("Average", kind.displayValue(current)))
                    .foregroundStyle(DS.Palette.accent.opacity(DS.Tint.strong))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: .automatic(includesZero: kind.isCumulative))
        .chartLegend(.hidden)
    }

    private func stats(_ trend: MetricTrend) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: DS.Space.s)], spacing: DS.Space.s) {
            // The averages and the change are the headline's; the tiles add only what it doesn't say.
            tile(kind.isCumulative ? "Days recorded" : "Readings", "\(trend.currentReadings) vs \(trend.previousReadings)")
            if let today = trend.today {
                tile("Today so far", kind.format(today))
            }
        }
    }

    private func tile(_ label: String, _ value: String?) -> some View {
        StatValue(label: label, value: value ?? DS.placeholder, size: .tile)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.m)
            .dsCard()
    }

    private func ladderTable(_ ladder: [TrendWindow: MetricTrend]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Every window").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(TrendWindow.allCases.enumerated()), id: \.element) { index, w in
                    if index > 0 { Divider() }
                    if let t = ladder[w] {
                        // One line per window; where the "vs" column doesn't fit (a phone),
                        // it goes rather than wrapping every cell.
                        ViewThatFits(in: .horizontal) {
                            ladderRow(w, t, showsPrevious: true)
                            ladderRow(w, t, showsPrevious: false)
                        }
                        .font(.subheadline)
                        .padding(DS.Space.m)
                        .background(w == window ? DS.Palette.accent.opacity(DS.Tint.subtle) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { window = w }
                    }
                }
            }
            .dsCard()
        }
    }

    private func ladderRow(_ w: TrendWindow, _ t: MetricTrend, showsPrevious: Bool) -> some View {
        HStack {
            Text("Last \(w.title)")
            Spacer(minLength: DS.Space.s)
            Text(t.currentValue.map(kind.trendText) ?? DS.placeholder)
                .monospacedDigit()
            if showsPrevious {
                Text("vs \(t.previousValue.map(kind.trendText) ?? DS.placeholder)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 110, alignment: .trailing)
            }
            TrendChangeBadge(trend: t)
                .frame(width: 64, alignment: .trailing)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Every metric

/// Every Health metric's trend. Narrow (a phone), a list of cards for the window you pick;
/// wide (the Mac, a big phone), a table with every window side by side — short-term and
/// long-term at a glance — and the two windows drawn over each other.
struct TrendsView: View {
    @EnvironmentObject private var health: HealthKitStore
    @State var window: TrendWindow = .month
    /// How a metric opens on the phone: a route in the Workouts stack, which is typed and kept
    /// across launches. Nil (the Mac): this view's own destination.
    var link: ((MetricKind, TrendWindow) -> ShellState.WorkoutsRoute)? = nil

    /// Wide enough for the table.
    private static let tableWidth: CGFloat = 720

    var body: some View {
        let _ = RenderStats.note("TrendsView")
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if health.trends.isEmpty {
                        ContentUnavailableView("No Health data yet", systemImage: "heart.text.square",
                                               description: Text("Trends appear once your iPhone has read Apple Health."))
                            .frame(maxWidth: .infinity)
                    } else if geo.size.width >= Self.tableWidth {
                        table
                    } else {
                        cards
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .groupedPage()
        .navigationTitle("All measures")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: MetricKind.self) { TrendDetailView(kind: $0, window: window) }
    }

    @ViewBuilder private func open(_ kind: MetricKind, @ViewBuilder label: () -> some View) -> some View {
        if let link {
            NavigationLink(value: link(kind, window), label: label)
        } else {
            NavigationLink(value: kind, label: label)
        }
    }

    private func grouped() -> [(MetricKind.TrendGroup, [MetricTrend])] {
        let spans = MetricTrends.spans(window: window, calendar: .app, now: Date())
        let all = TrendsData.trends(health, current: spans.current, previous: spans.previous)
        return MetricKind.TrendGroup.allCases.compactMap { group in
            let inGroup = all.filter { $0.kind.trendGroup == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    private var cards: some View {
        ForEach(grouped(), id: \.0) { group, trends in
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(group.rawValue).font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(trends.enumerated()), id: \.element.id) { index, trend in
                        if index > 0 { Divider() }
                        open(trend.kind) {
                            TrendCard(trend: trend, daily: trend.kind.series(health.trends), window: window.days)
                                .padding(.horizontal, DS.Space.m)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .dsCard()
            }
        }
    }

    private var table: some View {
        let now = Date()
        return ForEach(grouped(), id: \.0) { group, trends in
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(group.rawValue).font(.headline)
                VStack(spacing: 0) {
                    header
                    ForEach(trends) { trend in
                        Divider()
                        open(trend.kind) {
                            row(trend, ladder: MetricTrends.ladder(trend.kind, daily: trend.kind.series(health.trends),
                                                                   calendar: .app, now: now))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .dsCard()
            }
        }
    }

    private static let windowColumn: CGFloat = 76

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Text("Metric").frame(maxWidth: .infinity, alignment: .leading)
            Text("Last \(window.title)").frame(width: 150, alignment: .trailing)
            ForEach(TrendWindow.allCases) { w in
                Text(w.shortTitle)
                    .fontWeight(w == window ? .semibold : .regular)
                    .frame(width: Self.windowColumn, alignment: .trailing)
            }
            Text("\(window.shortTitle) vs the one before")
                .frame(width: 150, alignment: .leading)
                .padding(.leading, DS.Space.m)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    private func row(_ trend: MetricTrend, ladder: [TrendWindow: MetricTrend]) -> some View {
        let daily = trend.kind.series(health.trends)
        let chart = MetricTrends.overlay(trend.kind, daily: daily, current: trend.current, previous: trend.previous,
                                         bucketDays: window.chartBucketDays, calendar: .app)
        let value = trend.kind.trendValue(trend.currentValue)
        return HStack(spacing: DS.Space.m) {
            Label(trend.kind.title, systemImage: trend.kind.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatValue(label: nil, value: value.value, unit: value.unit, size: .row, alignment: .trailing)
                .frame(width: 150, alignment: .trailing)
            ForEach(TrendWindow.allCases) { w in
                Group {
                    if let t = ladder[w] {
                        TrendChangeBadge(trend: t)
                            .help(t.previousValue.map { "\(t.currentValue.map(trend.kind.trendText) ?? DS.placeholder) vs \(trend.kind.trendText($0))" } ?? "")
                    } else {
                        Text(DS.placeholder).foregroundStyle(.secondary)
                    }
                }
                .frame(width: Self.windowColumn, alignment: .trailing)
                .background(w == window ? DS.Palette.accent.opacity(DS.Tint.subtle) : .clear)
            }
            TrendSparkline(current: chart.current, previous: chart.previous,
                           days: window.days, color: trend.tint == .secondary ? DS.Palette.accent : trend.tint)
                .frame(width: 150, height: 28)
                .padding(.leading, DS.Space.m)
        }
        .font(.subheadline)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .contentShape(Rectangle())
    }
}
