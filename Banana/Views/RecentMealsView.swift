#if os(iOS) || os(macOS)
import SwiftUI

/// Selecting a meal logs it once; portions can be edited from the ordinary logged-meal row.
struct RecentMealsView: View {
    let day: Date
    var onLogged: (() -> Void)? = nil
    @EnvironmentObject private var wellness: WellnessStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var toasts = ToastCenter.shared
    @State private var query = ""
    @State private var revision = 0
    @State private var meals: [MealEntry] = []
    @State private var loading = true
    @State private var logDate: Date
    @State private var pending: MealEntry?
    @State private var selectedID: UUID?
    @State private var saving = false
    @State private var saveError: String?

    init(day: Date, onLogged: (() -> Void)? = nil) {
        self.day = day
        self.onLogged = onLogged
        _logDate = State(initialValue: MealLogTime.date(on: day, part: nil))
    }

    private struct Search: Equatable { let query: String; let revision: Int }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("When", selection: $logDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .disabled(saving)
                } footer: {
                    Text("Tap a meal to log the same portions. No photo needed.")
                }
                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                        Button("Retry logging") { save() }.disabled(saving)
                    }
                }
                if loading && meals.isEmpty {
                    ProgressView("Finding your meals…")
                } else if meals.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No past meals yet" : "No matching meals",
                                           systemImage: "fork.knife",
                                           description: Text(query.isEmpty ? "Meals you log will appear here for next time." : "Try a meal name or one of its foods."))
                } else {
                    Section("Recent meals") {
                        ForEach(meals) { meal in
                            Button { selectedID = meal.id; pending = RecentMeals.entry(from: meal, at: logDate); save() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(RecentMeals.title(meal)).foregroundStyle(.primary).lineLimit(2)
                                        Text(meal.items.map { "\($0.serving) \($0.name)" }.joined(separator: " · "))
                                            .foregroundStyle(.secondary).font(.caption).lineLimit(2)
                                        Text(meal.date, format: .dateTime.month(.abbreviated).day())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if saving && selectedID == meal.id { ProgressView() }
                                    else { Text(NutritionText.kcal(meal.totals)).monospacedDigit().foregroundStyle(.secondary) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(saving)
                            .accessibilityIdentifier("recentMeals.meal.\(meal.id.uuidString)")
                            .accessibilityHint("Logs this meal with the same portions")
                        }
                    }
                }
            }
            .navigationTitle("Recent meals")
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Meal name or foods")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationBarTitleDisplayMode(.inline)
            #else
            .searchable(text: $query, prompt: "Meal name or foods")
            .frame(minWidth: 460, idealWidth: 540, minHeight: 480, idealHeight: 640)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
            .task(id: Search(query: query, revision: revision)) {
                await wellness.whenLoaded()
                let history = wellness.meals
                let hidden = toasts.hiddenIDs
                let search = query
                let worker = Task.detached(priority: .userInitiated) {
                    RecentMeals.choices(in: history, query: search, hiddenIDs: hidden)
                }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                meals = result
                loading = false
            }
            .onReceive(wellness.$meals.dropFirst()) { _ in revision &+= 1 }
            .onReceive(toasts.$hiddenIDs.dropFirst()) { _ in revision &+= 1 }
        }
    }

    private func save() {
        guard var pending, !saving else { return }
        pending.date = logDate
        self.pending = pending
        saving = true
        saveError = nil
        Task {
            do {
                try await wellness.addMealDurably(pending)
                ToastCenter.shared.present("Logged “\(RecentMeals.title(pending))” · \(NutritionText.kcal(pending.totals))") {
                    Task {
                        do { try await wellness.deleteMealDurably(pending.id) }
                        catch { ToastCenter.shared.notify("Couldn’t undo logging. The meal is still saved.") }
                    }
                }
                saving = false
                dismiss()
                onLogged?()
            } catch {
                saving = false
                saveError = "Couldn’t save this meal. Your selection is still here; try again."
            }
        }
    }
}
#endif
