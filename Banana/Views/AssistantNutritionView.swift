import SwiftUI
import Charts

/// One stable workspace surface. Both agent patches and native controls edit the Pi document.
struct AssistantNutritionView: View {
    let surface: AssistantNutritionSurface
    @ObservedObject private var assistant = AssistantStore.shared
    @ObservedObject private var wellness = WellnessStore.shared
    private var days: [AssistantNutrition.Day] { AssistantNutrition.days(surface, meals: wellness.meals) }
    private var selectedMeals: [MealEntry] {
        days.filter { surface.selectedDay == nil || $0.id == surface.selectedDay }.flatMap(\.meals)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if PI_DEVELOPMENT
            if wellness.meals.contains(where: PiSampleMeals.contains) {
                Label("Sample meal history · fictional test data", systemImage: "flask")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant.samples.badge")
            }
            #endif
            // A meal being logged again leads: it's the task in hand, the chart is context.
            if let id = surface.draftMealID, let day = surface.draftDate, let raw = surface.draftID, let operation = UUID(uuidString: raw),
               let meal = wellness.meals.first(where: { $0.id.uuidString == id }) {
                let saved = wellness.meals.first(where: { $0.id == operation })
                VStack(alignment: .leading, spacing: 14) {
                    WorkspaceObjectHeader(title: (saved ?? meal).name.isEmpty ? (saved ?? meal).items.map(\.name).joined(separator: ", ") : (saved ?? meal).name,
                                          status: saved == nil ? .draft : .saved,
                                          request: "Logging again from \(Self.day(meal.date))",
                                          dismissID: "assistant.copy.dismiss") {
                        change(["draftMealID": NSNull(), "draftDate": NSNull()])
                    }
                    if let saved {
                        SavedMealSummary(meal: saved) { AssistantWorkspace.open(.nutrition, itemID: "meal:\(saved.id)") }
                    } else if let date = try? AssistantNutrition.date(day) {
                        FoodTextCaptureView(copying: meal, on: date, operationID: operation, embedded: true)
                            .environmentObject(wellness)
                            .id(operation)
                    }
                }
                .padding(.bottom, 12)
                .id("assistant.copy.top")
            }
            if surface.draftMealID == nil {
            Group {
            VStack(alignment: .leading, spacing: 2) {
                // The metric is the title, and the title is its menu: one control, not two.
                Menu {
                    Picker("Nutrient", selection: Binding(get: { surface.metric }, set: { change(["metric": $0.rawValue]) })) {
                        ForEach(AssistantNutritionSurface.Metric.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(surface.metric.title).font(.title3.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("assistant.nutrition.metric")
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant.nutrition.summary")
            }
            HStack {
                Toggle("Weekdays only", isOn: Binding(get: { surface.weekdaysOnly }, set: { change(["weekdaysOnly": $0]) }))
                    .accessibilityIdentifier("assistant.nutrition.weekdays")
                Toggle("Compare prior period", isOn: Binding(get: { surface.compare }, set: { change(["compare": $0]) }))
                    .accessibilityIdentifier("assistant.nutrition.compare")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            if !surface.search.isEmpty {
                HStack {
                    Label("Meals matching “\(surface.search)”", systemImage: "magnifyingglass")
                    Button("Clear filter") { change(["search": ""]) }
                }.font(.caption)
            }
            Chart {
                ForEach(days) { day in
                    if let value = day.value {
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value(surface.metric.unit, value))
                            .foregroundStyle(Color.accentColor.opacity(surface.selectedDay == nil || surface.selectedDay == day.id ? 1 : 0.35))
                    }
                    if surface.compare, let previous = day.previous {
                        PointMark(x: .value("Day", day.date, unit: .day), y: .value(surface.metric.unit, previous))
                            .foregroundStyle(.secondary).symbol(.diamond)
                    }
                }
            }
            .chartXScale(domain: chartDomain)
            // Days, never hours: the bars are days.
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, days.count / 4))) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            #if os(iOS)
            .chartXSelection(value: Binding<Date?>(get: {
                surface.selectedDay.flatMap { try? AssistantNutrition.date($0) }
            }, set: { value in
                guard let value else { return }
                let key = AssistantNutrition.key(value)
                guard days.contains(where: { $0.id == key }), key != surface.selectedDay else { return }
                change(["selectedDay": key])
            }))
            #endif
            .frame(height: 180)
            .accessibilityLabel("\(surface.metric.title), \(days.filter { $0.value != nil }.count) logged days")
            .accessibilityIdentifier("assistant.nutrition.chart")
            if surface.compare {
                Label("Previous period", systemImage: "diamond").font(.caption).foregroundStyle(.secondary)
            }
            if surface.compare && days.allSatisfy({ $0.previous == nil }) {
                Text("Nothing logged in the previous period to compare.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(surface.selectedDay.flatMap { try? AssistantNutrition.date($0) }.map { "Meals on \(Self.day($0))" } ?? "Meals")
                    .font(.headline).accessibilityIdentifier("assistant.nutrition.selection")
                Spacer()
                // An accessible day picker complements chart scrubbing and works without precision gestures.
                Picker("Day", selection: Binding(get: { surface.selectedDay ?? "" }, set: {
                    change(["selectedDay": $0.isEmpty ? NSNull() : $0 as Any])
                })) {
                    Text("All days").tag("")
                    ForEach(days.filter { $0.value != nil }) { day in Text(Self.day(day.date)).tag(day.id) }
                }
                .accessibilityIdentifier("assistant.nutrition.day")
            }
            if selectedMeals.isEmpty {
                Text("No logged meals match this view.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(selectedMeals.prefix(30))) { meal in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meal.name.isEmpty ? meal.items.map(\.name).joined(separator: ", ") : meal.name)
                            Text("\(Self.day(meal.date)) · \(meal.isConfident ? "" : "~")\(surface.metric.value(meal.totals), specifier: "%.0f") \(surface.metric.unit)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use again") {
                            // Logged again today: copying what you ate is almost always for now.
                            change(["draftMealID": meal.id.uuidString, "draftDate": AssistantNutrition.key(Date())])
                        }
                        .accessibilityIdentifier("assistant.nutrition.copy.\(meal.id)")
                    }
                    Divider()
                }
                if selectedMeals.count > 30 { Text("Showing 30 meals. Select a day or narrow your search.").font(.caption) }
            }
            }
            }
            #if DEBUG
            if assistant.isDiagnostic && !AppSupport.isDesignCapture {
                Text("\(wellness.meals.count) logged meals").font(.caption)
                    .accessibilityIdentifier("assistant.test.meals")
            }
            #endif
        }
        .disabled(assistant.updatingSurface)
        .task {
            await wellness.whenLoaded()
            #if DEBUG
            if AppSupport.isPiVerification && ProcessInfo.processInfo.arguments.contains("--assistant-nutrition-verify") {
                let state: [String: Any] = ["run": AssistantVerification.runIdentifier, "revision": surface.revision]
                if let url = try? AssistantVerification.reportURL("pi-nutrition-view-ready.json") {
                    try? JSONSerialization.data(withJSONObject: state).write(to: url, options: .atomic)
                }
            }
            #endif
        }
    }

    /// "74.9 g · 1 of 31 days logged · Oct 1–31": the answer first, then how much it rests on.
    private var summary: String {
        let logged = days.filter { $0.value != nil }
        let total = logged.compactMap(\.value).reduce(0, +)
        let start = (try? AssistantNutrition.date(surface.start)) ?? Date()
        let end = (try? AssistantNutrition.date(surface.end)) ?? start
        let range = (start..<max(end, start)).formatted(.interval.month(.abbreviated).day())
        return "\(total.formatted(.number.precision(.fractionLength(0...1)))) \(surface.metric.unit) · \(logged.count) of \(days.count) days logged · \(range)"
    }

    static func day(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    /// At least a week wide: on the 1st, "this month" is one day, and a one-day domain drew an
    /// hourly axis under a single bar.
    private var chartDomain: ClosedRange<Date> {
        let calendar = AssistantNutrition.calendar()
        let start = (try? AssistantNutrition.date(surface.start)) ?? Date()
        let end = max((try? AssistantNutrition.date(surface.end)) ?? start,
                      calendar.date(byAdding: .day, value: 6, to: start)!)
        return start...calendar.date(byAdding: .day, value: 1, to: end)!
    }
    private func change(_ patch: [String: Any]) { Task { await assistant.updateSurface(patch) } }
}
