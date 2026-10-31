import SwiftUI
import Charts

/// Looking back: everything about the past, in one place (`PageChromeRules.swift`).
///
/// The tabs are for doing: today and what's next. They used to carry their own history as well
/// (Workouts had a period switch and trends, Sleep and Trends were pages inside it, the Library
/// kept listening history, the iPad's Nutrition kept a month of logs), each with its own way of
/// choosing a span. All of that is here, under the app's one span switch.
struct ReviewView: View {
    /// The tab the chart button was on: its subject leads.
    var from: AppSection = .plan
    /// Shown as a sheet (a phone), so it needs a way out.
    var showsDoneButton = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var wellness: WellnessStore
    @EnvironmentObject private var history: ListenHistoryStore
    @EnvironmentObject private var smart: SmartScheduleStore
    @AppStorage("reviewSpan") private var span: ReviewSpan = .week
    /// How many periods back from now. Not kept: Review opens on now.
    @State private var offset = 0
    @ObservedObject private var modules = ModuleStore.shared

    private var period: RhythmPeriod { RhythmPeriod(granularity: span.granularity, offset: offset) }

    var body: some View {
        NavigationStack {
            List {
                // One group, as the system's own lists of places to go are.
                Section {
                    ForEach(ReviewSubject.ordered(for: from, with: modules.choice)) { subject in
                        NavigationLink(value: subject) { row(subject) }
                            .accessibilityIdentifier("review.\(subject.rawValue)")
                    }
                }
            }
            // A column in the middle of an iPad or a wide window, not rows stretched across it.
            .readableColumn()
            // A small gap under the date line, not the grouped list's full top band.
            .contentMargins(.top, DS.Space.s, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) { dateLine }
            .navigationTitle("Review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PageSwitch(label: "Span", selection: Binding(get: { span }, set: { span = $0; offset = 0 }),
                               choices: ReviewSpan.allCases, title: \.title)
                        .accessibilityIdentifier("review.span")
                }
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: ReviewSubject.self) { page($0) }
        }
    }

    private var dateLine: some View {
        DateLine(current: "This \(span.rawValue)",
                 dates: offset == 0 || span == .week ? period.rangeLabel() : period.label(),
                 isCurrent: offset == 0, canGoForward: period.canGoForward, unit: span.rawValue,
                 home: "Now", titleIdentifier: "review.period",
                 step: { offset = min(0, offset + $0) }, toCurrent: { offset = 0 })
            // On the page, as Food's and Taken's are: a drawn bar under the system's read as a
            // second toolbar.
            .background(DS.Palette.page)
    }

    // MARK: - One line per subject

    private func row(_ subject: ReviewSubject) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(systemImage: subject.symbol, tint: tint(subject), style: .soft)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(subject.title).font(.body.weight(.medium))
                Text(summary(subject))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func tint(_ subject: ReviewSubject) -> Color {
        switch subject {
        case .fitness: DS.Palette.accent
        case .sleep: DS.Palette.Feature.wake
        case .food: DS.Palette.Brand.green
        case .listening: DS.Palette.Brand.purple
        }
    }

    private func summary(_ subject: ReviewSubject) -> String {
        let (start, end) = period.range()
        switch subject {
        case .fitness:
            let workouts = WorkoutEntry.merge(summaries: fitness.summaries, health: health.workouts,
                                              hiddenHealthIDs: health.hiddenWorkoutIDs)
                .filter { $0.start >= start && $0.start < end }
            guard !workouts.isEmpty else { return "No workouts" }
            let minutes = workouts.reduce(0) { $0 + $1.duration } / 60
            return "\(workouts.count) \(workouts.count == 1 ? "workout" : "workouts") \u{00B7} \(ReviewMath.clock(minutes: minutes))"
        case .sleep:
            let nights = health.trends.nights.filter { $0.wake >= start && $0.wake < end }
            guard !nights.isEmpty else { return "No nights" }
            let average = nights.reduce(0) { $0 + $1.asleepMinutes } / Double(nights.count)
            return "\(ReviewMath.clock(minutes: average)) a night"
        case .food:
            let days = ReviewMath.perDay(wellness.meals.map { ($0.date, $0.totals.calories) }, from: start, to: end)
            guard let average = ReviewMath.averageOfLoggedDays(days.map(\.value)) else { return "Nothing logged" }
            let logged = days.filter { $0.value > 0 }.count
            return "\(Int(average.rounded()).formatted()) kcal a day \u{00B7} \(logged) \(logged == 1 ? "day" : "days") logged"
        case .listening:
            let events = history.events.filter { $0.date >= start && $0.date < end }
            guard !events.isEmpty else { return "Nothing played" }
            let minutes = events.reduce(0) { $0 + $1.duration } / 60
            return "\(ReviewMath.clock(minutes: minutes)) \u{00B7} \(events.count) \(events.count == 1 ? "episode" : "episodes")"
        }
    }

    // MARK: - Pages

    @ViewBuilder private func page(_ subject: ReviewSubject) -> some View {
        // A page left open while its module is switched off goes blank rather than show it.
        if modules.includes(subject.module) { subjectPage(subject) }
    }

    @ViewBuilder private func subjectPage(_ subject: ReviewSubject) -> some View {
        let range = period.range()
        let span = TrendSpan(start: range.start, end: range.end)
        switch subject {
        case .fitness: ReviewFitnessPage(period: period)
        case .sleep: SleepView()
        case .food: ReviewFoodPage(period: period, onOpenDay: showsDoneButton ? { dismiss() } : nil)
        case .listening: ListenHistoryView(span: span)
        }
    }
}

// MARK: - Fitness

/// The measures Workouts used to list under its period switch: each against the period before,
/// opening its own page.
private struct ReviewFitnessPage: View {
    let period: RhythmPeriod
    @EnvironmentObject private var health: HealthKitStore

    var body: some View {
        let now = Date()
        let spans = MetricTrends.spans(for: period, calendar: .app, now: now)
        let trends = TrendsData.trends(health, current: spans.current, previous: spans.previous, now: now)
        let days = Calendar.app.dateComponents([.day], from: spans.current.start, to: spans.current.end).day ?? 7
        let window = TrendWindow(period.granularity)
        List {
            if trends.isEmpty {
                ContentUnavailableView("No Health data yet", systemImage: "heart.text.square",
                                       description: Text("Measures appear once your iPhone has read Apple Health."))
            } else {
                Section {
                    ForEach(trends) { trend in
                        NavigationLink {
                            TrendDetailView(kind: trend.kind, window: window)
                        } label: {
                            TrendCard(trend: trend, daily: trend.kind.series(health.trends), window: days)
                        }
                    }
                    NavigationLink {
                        TrendsView(window: window)
                    } label: {
                        Label("All measures", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .accessibilityIdentifier("review.fitness.all")
                } header: {
                    Text(MetricTrends.comparisonLabel(for: period, calendar: .app, now: now))
                }
            }
        }
        .readableColumn()
        .navigationTitle("Fitness")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await health.refresh() }
    }
}

// MARK: - Food

/// What was logged over the period: a bar a day (a bar a month over a year), the average of the
/// days that were logged, and the logs against the weight trend.
private struct ReviewFoodPage: View {
    let period: RhythmPeriod
    /// Closes Review when a day is opened in Nutrition (a sheet has to get out of the way).
    var onOpenDay: (() -> Void)?
    @EnvironmentObject private var wellness: WellnessStore
    @ObservedObject private var shell = ShellNavigation.shared

    var body: some View {
        let (start, end) = period.range()
        let days = ReviewMath.perDay(wellness.meals.map { ($0.date, $0.totals.calories) }, from: start, to: end)
            .filter { $0.day <= Date() }
        let average = ReviewMath.averageOfLoggedDays(days.map(\.value))
        // Over a year, a bar a month: that month's average logged day.
        let bars = period.granularity == .year ? ReviewMath.monthlyAverages(days) : days
        List {
            if average == nil {
                ContentUnavailableView("Nothing logged", systemImage: "fork.knife",
                                       description: Text("Meals you log in Nutrition show up here."))
            } else {
                Section {
                    Chart(bars, id: \.day) { day in
                        BarMark(x: .value("Day", day.day, unit: period.granularity == .year ? .month : .day),
                                y: .value("Calories", day.value))
                            .foregroundStyle(DS.Palette.accent)
                    }
                    .frame(height: 160)
                    .padding(.vertical, DS.Space.s)
                    .accessibilityIdentifier("review.food.chart")
                    if let average {
                        LabeledContent("Average", value: "\(Int(average.rounded()).formatted()) kcal a day")
                    }
                    LabeledContent("Days logged", value: "\(days.filter { $0.value > 0 }.count) of \(days.count)")
                }
                if period.granularity != .year {
                    Section("Days") {
                        ForEach(days.reversed(), id: \.day) { day in
                            Button { open(day.day) } label: {
                                LabeledContent(day.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                               value: day.value > 0 ? "\(Int(day.value.rounded()).formatted()) kcal" : "Not logged")
                            }
                            .tint(.primary)
                        }
                    }
                }
                EnergyBalanceReport(meals: wellness.meals) { balance in
                    Section {
                        EnergyBalanceCard(balance: balance)
                    } header: {
                        Text(EnergyBalanceCard.title)
                    } footer: {
                        if balance.status != .gathering { Text(EnergyBalanceCard.footnote) }
                    }
                }
            }
        }
        .readableColumn()
        .navigationTitle("Food")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The day, in Nutrition, where it can be changed.
    private func open(_ day: Date) {
        shell.state.nutritionDay = Calendar.current.isDateInToday(day) ? nil : day
        #if os(macOS)
        MacNavigator.shared.section = .nutrition
        #else
        shell.state.tab = .nutrition
        #endif
        onOpenDay?()
    }
}
