import SwiftUI

/// Nutrition on the iPad and Mac: the day's calories and macros, the week to move between days,
/// the meal backlog ("To log"), a one-line "What did you eat?" that opens the same review sheet
/// the phone uses, photos and notes for any day (picked, or dropped on the page), the day's meals
/// by part of the day, and the day's supplements to tick off. Meals travel with the phone
/// through `CloudWellnessSync`, the backlog through `CloudControlsSync`.
///
/// Logging goes on the day on screen. Barcode capture stays on the phone, where the camera is.
/// Supplements are edited here too; their reminders ring on the phone and Watch, which
/// reschedule when an edit arrives.
struct WideNutritionView: View {
    @EnvironmentObject private var wellness: WellnessStore
    @EnvironmentObject private var settings: AppSettings
    /// A meal deleted a moment ago stays hidden here until its Undo window closes.
    @ObservedObject private var toasts = ToastCenter.shared

    @ObservedObject private var shell = ShellNavigation.shared
    /// The day on screen — today unless you've gone back. In ShellNavigation, as the phone's is,
    /// so a trip to another app or a resized window doesn't snap it back to today: here it was
    /// the view's own, and an iPad forgot it every time.
    private var day: Date {
        get {
            let today = Calendar.current.startOfDay(for: Date())
            return shell.state.nutritionDay.map { min(Calendar.current.startOfDay(for: $0), today) } ?? today
        }
        nonmutating set {
            shell.state.nutritionDay = Calendar.current.isDateInToday(newValue) ? nil : newValue
        }
    }
    private var dayBinding: Binding<Date> { Binding(get: { day }, set: { day = $0 }) }
    /// A new meal from a scanned package (an iPad has the camera for it).
    @State private var scanning = false
    @State private var phrase = ""
    @State private var capture: Capture?
    @State private var editingMeal: MealEntry?
    @State private var hoveredMeal: UUID?
    @State private var editingSupplement: SupplementSchedule?
    @State private var addingSupplement = false
    @State private var hoveredSupplement: UUID?
    /// A moment came (a workout ended): what waited for it may be due now.
    @ObservedObject private var hub = AnchoredTimingHub.shared
    @ObservedObject private var inbox = MealInboxStore.shared
    @State private var adding: Adding?
    @State private var reviewing: MealDayRequest?
    @State private var enteringByHand: MealInboxItem?
    @State private var dropTargeted = false
    /// Your scanned foods (`MyFoodsView`).
    @State private var showingMyFoods = false
    #if os(iOS)
    @State private var scanningGroceries = false
    #endif
    /// Searching foods by name for a new meal (`FoodSearchView`).
    @State private var showingRecentMeals = false
    @State private var searching = false
    @State private var addingByHand = false

    /// "Add photos & notes", with any images dropped on the page.
    private struct Adding: Identifiable {
        let id = UUID()
        let day: Date
        var images: [Data] = []
    }

    private struct Capture: Identifiable {
        let id = UUID()
        let phrase: String
    }

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(day) }
    private var visibleMeals: [MealEntry] {
        wellness.meals.filter { !toasts.hiddenIDs.contains($0.id.uuidString) }
    }
    private var dayMeals: [MealEntry] { NutritionDays.meals(visibleMeals, on: day) }

    var body: some View {
        ScrollViewReader { proxy in
            page
                #if DEBUG
                // `--energy-balance`: down to the card, so a window shorter than the page shows it.
                .task {
                    guard EnergyBalance.Preview.requested() != nil else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo(EnergyBalanceCard.title, anchor: .center)
                }
                // `--timing-suggestions`: down to Taken, where its offers are.
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--timing-suggestions") else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo(Self.takenID, anchor: .top)
                }
                #endif
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                // The week and the day's total in one card, then what's waiting: the phone's order.
                dayCard
                if !inbox.items.isEmpty { backlog }
                logField
                meals
                EstimateLearningCard(meals: visibleMeals)
                taken
                syncNote
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Food")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // What the cards sit on, as a list's rows do (`dsCard` is the row colour on iOS).
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ReviewToolbarItem(section: .nutrition)
            ToolbarItem(placement: .automatic) { MoreMenu() }
        }
        .bodySwitch(wide: true)
        #endif
        // The one + (`PageChrome`): every way to add other than typing in the field above.
        // They were a row of buttons beside the field, and an "Add" at the head of Taken.
        .addMenu(identifier: "nutrition.add") {
            Button { showingRecentMeals = true } label: { Label("Recent meals", systemImage: "clock.arrow.circlepath") }
                .accessibilityIdentifier("wellness.recentMeals")
            Button { searching = true } label: { Label("Search", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("nutrition.search")
            #if os(iOS)
            Button { scanning = true } label: { Label("Scan", systemImage: "barcode.viewfinder") }
                .accessibilityIdentifier("nutrition.scan")
            #endif
            Button { adding = Adding(day: day) } label: { Label("Photos", systemImage: "photo.on.rectangle.angled") }
                .accessibilityIdentifier("nutrition.addPhotos")
            Divider()
            Button { addingSupplement = true } label: { Label("Something you take", systemImage: "pills") }
                .accessibilityIdentifier("nutrition.addSupplement")
        }
        // The same, picked from the + on the tab bar's row. Describing is the field at the top
        // of this page, so its two ways of typing a meal open search here.
        .onAdd(.recentMeal, .describeMeal, .searchFood, .scanFood, .mealPhotos, .mealByHand, .groceries, .supplement) { kind in
            switch kind {
            #if os(iOS)
            case .scanFood: scanning = true
            case .groceries: scanningGroceries = true
            #endif
            case .recentMeal: showingRecentMeals = true
            case .mealByHand: addingByHand = true
            case .describeMeal: capture = Capture(phrase: "")
            case .mealPhotos: adding = Adding(day: day)
            case .supplement: addingSupplement = true
            default: searching = true
            }
        }
        // Photos dropped anywhere on the page: added for the day on screen, each at its own time.
        .dropDestination(for: DroppedMealImage.self) { images, _ in
            guard !images.isEmpty else { return false }
            adding = Adding(day: day, images: images.map(\.data))
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(DS.Space.s)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showingRecentMeals) { RecentMealsView(day: day).environmentObject(wellness) }
        .sheet(isPresented: $addingByHand) {
            FoodTextCaptureView(byHandOn: day).environmentObject(wellness)
        }
        .sheet(isPresented: $searching) {
            FoodTextCaptureView(searchingOn: day)
                .environmentObject(wellness)
        }
        .sheet(isPresented: $scanning) {
            FoodTextCaptureView(scanningOn: day)
                .environmentObject(wellness)
        }
        .sheet(item: $capture) { capture in
            FoodTextCaptureView(initialPhrase: capture.phrase, parseOnOpen: !capture.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, day: day)
                .environmentObject(wellness)
        }
        .sheet(item: $adding) { adding in
            MealDumpView(day: adding.day, initialImages: adding.images)
                .environmentObject(settings)
        }
        .sheet(item: $reviewing) { request in
            MealDayReviewView(day: request.day).environmentObject(wellness)
        }
        .sheet(item: $enteringByHand) { item in
            FoodTextCaptureView(reviewing: item).environmentObject(wellness)
        }
        .sheet(item: $editingMeal) { meal in
            FoodTextCaptureView(editing: meal)
                .environmentObject(wellness)
        }
        .sheet(item: $editingSupplement) { supplement in
            MacSupplementEditor(supplement: supplement, onDelete: { delete(supplement) })
                .environmentObject(wellness)
        }
        .sheet(isPresented: $showingMyFoods) { MyFoodsView() }
        #if os(iOS)
        .fullScreenCover(isPresented: $scanningGroceries) { GroceryScanView() }
        #endif
        .sheet(isPresented: $addingSupplement) {
            MacSupplementEditor(supplement: nil, onDelete: nil)
                .environmentObject(wellness)
        }
        .onAppear { CloudWellnessSync.shared.refresh() }
    }

    // MARK: - Day

    /// The one date line (`PageChrome`). Back is for filling in a day that was missed.
    private var header: some View {
        DateLine(current: "Today", dates: day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                 isCurrent: isToday, canGoForward: !isToday, titleIdentifier: "nutrition.day",
                 step: { day = NutritionDays.step(day, by: $0) },
                 toCurrent: { day = Calendar.current.startOfDay(for: Date()) })
    }

    /// The week strip and the day's total under it, in one card as on the phone.
    private var dayCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            NutritionWeekStrip(day: dayBinding, meals: visibleMeals)
            Divider()
            totals
                .padding(.horizontal, DS.Space.s)
                .padding(.bottom, DS.Space.s)
        }
        .padding(DS.Space.xs)
        .dsCard()
    }

    private var totals: some View {
        let total = NutritionDays.total(dayMeals)
        return NutritionSummary(label: isToday ? "So far today" : "Total", macros: dayMeals.isEmpty ? nil : total)
    }

    // MARK: - Logging

    private var trimmedPhrase: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var logField: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "text.bubble")
                .foregroundStyle(DS.Palette.accent)
            TextField("What did you eat? \u{201C}2 eggs, toast and a flat white\u{201D}", text: $phrase)
                .textFieldStyle(.plain)
                .onSubmit(log)
                .accessibilityIdentifier("nutrition.phrase")
            Button("Log", action: log)
                .buttonStyle(.secondary)
                .disabled(trimmedPhrase.isEmpty)
            Button { showingRecentMeals = true } label: { Label("Recent meals", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(.secondary)
                .accessibilityIdentifier("nutrition.recentMeals")
            Button { showingMyFoods = true } label: {
                Label("My foods", systemImage: "basket")
            }
            .buttonStyle(.secondary)
            .help("Packages you\u{2019}ve scanned")
            .accessibilityIdentifier("nutrition.myFoods")
        }
        .padding(DS.Space.m)
        .dsCard()
    }

    private func log() {
        guard !trimmedPhrase.isEmpty else { return }
        capture = Capture(phrase: trimmedPhrase)
        phrase = ""
    }

    // MARK: - Backlog

    private var backlog: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("To log").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, DS.Space.xs)
            MealBacklogPanel(onReviewDay: { reviewing = MealDayRequest(day: $0) },
                             onEnterByHand: { enteringByHand = $0 })
                .padding(DS.Space.m)
                .dsCard()
        }
    }

    // MARK: - Meals

    @ViewBuilder private var meals: some View {
        if dayMeals.isEmpty {
            ContentUnavailableView {
                Label("No food logged", systemImage: "fork.knife")
            } description: {
                Text(isToday ? "Meals you log here or on your iPhone show up in both places."
                             : "Nothing was logged on this day.")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.l)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                ForEach(DayPart.allCases, id: \.self) { part in
                    let meals = dayMeals.filter { DayPart.of($0.date) == part }
                    if !meals.isEmpty { partSection(part, meals) }
                }
            }
        }
    }

    private func partSection(_ part: DayPart, _ meals: [MealEntry]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text(part.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(NutritionText.kcal(NutritionDays.total(meals)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.xs)
            VStack(spacing: 0) {
                ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                    if index > 0 { Divider().padding(.leading, DS.Space.m + 58 + DS.Space.m) }
                    mealRow(meal)
                }
            }
            .clipShape(cardShape)
            .dsCard()
        }
    }

    private func mealRow(_ meal: MealEntry) -> some View {
        // A tap, not a Button: a Button row swallows the click on the meal's photo, which shows
        // the photo full size (`opensMealPhotos`).
        MealRowLabel(meal: meal)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s + 2)
            .frame(minHeight: DS.Row.minHeight)
            .background(hoveredMeal == meal.id ? DS.Palette.selection : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { editingMeal = meal }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editingMeal = meal }
        .onHover { hoveredMeal = $0 ? meal.id : (hoveredMeal == meal.id ? nil : hoveredMeal) }
        .contextMenu {
            Button("Edit\u{2026}") { editingMeal = meal }
            Divider()
            Button("Delete", role: .destructive) { delete(meal) }
        }
        .accessibilityIdentifier("nutrition.meal")
    }

    private func delete(_ meal: MealEntry) {
        let wellness = wellness
        Task {
            await ToastCenter.shared.deferRemoval(
                id: meal.id.uuidString,
                message: "Deleted \u{201C}\(NutritionText.mealTitle(meal))\u{201D}",
                failure: { "Couldn\u{2019}t delete: \($0)" }
            ) {
                wellness.deleteMeal(meal.id)
                return nil
            }
        }
    }

    // (The logs against the weight trend were here: looking back, so in Review › Food now.)

    // MARK: - Supplements and medications

    /// Everything scheduled, reminder on or off — turning a reminder off doesn't mean you stopped
    /// taking it. A supplement deleted a moment ago stays hidden until its Undo window closes.
    private var schedule: [SupplementSchedule] {
        wellness.supplements.filter { !toasts.hiddenIDs.contains($0.id.uuidString) }
    }

    private var taken: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Taken")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs)
            // What Banana noticed: a reminder that's something taken, a moment one follows.
            TakenTimingOffers()
            if schedule.isEmpty {
                Text("Nothing to take yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.m)
                    .dsCard()
            } else {
                timingClashes
                // Each minute: a dose's time arrives, and its row turns.
                TimelineView(.everyMinute) { minute in
                    VStack(spacing: 0) {
                        ForEach(Array(schedule.enumerated()), id: \.element.id) { index, supplement in
                            if index > 0 { Divider().padding(.leading, DS.Space.m + DS.Row.minHeight + DS.Space.m) }
                            doseRow(supplement, now: minute.date)
                        }
                    }
                    .clipShape(cardShape)
                    .dsCard()
                }
            }
        }
        .id(Self.takenID)
        .task { await AnchorSuggestionStore.shared.refreshIfStale(maxAge: 2 * 60) }
    }

    private static let takenID = "nutrition.taken"

    /// Absorption clashes in today's schedule, each with its fix, as on the phone's Taken tab.
    /// Only when there is one, and only on today's page: they're about today's times.
    @ViewBuilder private var timingClashes: some View {
        if Calendar.current.isDateInToday(day) {
            let intakes = wellness.todaysIntakes()
            let conflicts = SupplementInteractions.conflicts(among: intakes)
            if !conflicts.isEmpty {
                let suggestions = SupplementInteractions.suggestions(among: intakes)
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Timing")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(conflicts.enumerated()), id: \.element.id) { index, conflict in
                            if index > 0 { Divider() }
                            SupplementClashRow(conflict: conflict, fix: SupplementClashRow.fix(for: conflict, in: suggestions))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DS.Space.m)
                        }
                    }
                    .dsCard()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nutrition.timing")
            }
        }
    }

    /// One dose: tick it, what and when, open it. Due today and not yet marked, the whole row is
    /// amber and its time says since when — the phone's Taken tab does the same, by the same rule as the
    /// Nutrition badge (`ActionItems.dueSince`). A past day's page shows what happened, not what's due.
    private func doseRow(_ supplement: SupplementSchedule, now: Date) -> some View {
        let status = wellness.supplementStatus(supplement.id, on: day)
        let isTaken = status == .taken
        let dueSince = Calendar.current.isDate(day, inSameDayAs: now)
            ? ActionItems.dueSince(supplement, marked: status != nil, due: hub.dueDate(supplement, now: now), now: now)
            : nil
        return HStack(spacing: DS.Space.m) {
            Button {
                wellness.logSupplement(supplement.id, status: isTaken ? .skipped : .taken,
                                       at: NutritionDays.doseDate(for: supplement, on: day))
            } label: {
                Image(systemName: isTaken ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isTaken ? DS.Palette.success : .secondary)
            }
            .iconButton()
            .accessibilityLabel(isTaken ? "Mark \(supplement.name) not taken" : "Mark \(supplement.name) taken")
            // The rest of the row opens the editor, as a meal row does.
            Button { editingSupplement = supplement } label: {
                HStack(spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(supplement.name)
                        Text(doseLine(supplement, dueSince: dueSince, now: now))
                            .font(.caption.weight(dueSince == nil ? .regular : .semibold))
                            .foregroundStyle(dueSince == nil ? Color.secondary : DS.Palette.warning)
                    }
                    Spacer()
                    if status == .skipped {
                        Text("Skipped").font(.caption).foregroundStyle(.secondary)
                    }
                    RowChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s + 2)
        .frame(minHeight: DS.Row.minHeight)
        .background(hoveredSupplement == supplement.id ? DS.Palette.selection : Color.clear)
        .background(dueSince == nil ? Color.clear : DS.Palette.warning.opacity(DS.Tint.soft))
        .accessibilityElement(children: .contain)
        .accessibilityValue(dueSince == nil ? "" : "Due")
        .accessibilityIdentifier(dueSince == nil ? "taken.row" : "taken.row.due")
        .onHover { hoveredSupplement = $0 ? supplement.id : (hoveredSupplement == supplement.id ? nil : hoveredSupplement) }
        .contextMenu {
            Button("Edit\u{2026}") { editingSupplement = supplement }
            Divider()
            Button("Delete", role: .destructive) { delete(supplement) }
        }
    }

    /// "1 capsule · 8:00 AM", and "reminder off" when it is. Due and not marked: "Due since 8:00 AM"
    /// in the time's place.
    private func doseLine(_ supplement: SupplementSchedule, dueSince: Date?, now: Date) -> String {
        [supplement.dose,
         dueSince.map { ActionItems.dueText(since: $0, now: now) } ?? scheduledTime(supplement),
         supplement.enabled ? "" : "reminder off"]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    /// Gone at once, removed for real — its dose history with it, on every device — when the
    /// Undo window closes.
    private func delete(_ supplement: SupplementSchedule) {
        let wellness = wellness
        Task {
            await ToastCenter.shared.deferRemoval(
                id: supplement.id.uuidString,
                message: "Deleted \u{201C}\(supplement.name)\u{201D}",
                failure: { "Couldn\u{2019}t delete: \($0)" }
            ) {
                wellness.deleteSupplement(supplement.id)
                return nil
            }
        }
    }

    private func scheduledTime(_ supplement: SupplementSchedule) -> String {
        AnchoredTimingHub.shared.timeText(supplement, on: day)
    }

    /// Rows that fill their card to its edge (a hovered or due row) are cut to its corners.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
    }

    // MARK: - Sync

    /// Only when something is wrong: iCloud off, so nothing here reaches the iPhone.
    @ViewBuilder private var syncNote: some View {
        if !CloudWellnessSync.shared.isRunning {
            Label("iCloud is off on this \(DeviceRole.current.name)", systemImage: "icloud.slash")
                .font(.footnote)
                .foregroundStyle(DS.Palette.warning)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, DS.Space.s)
        }
    }
}

/// Adding or changing a supplement or medication on the Mac. The phone's editor also scans a
/// barcode or reads a photographed label; those need the camera, so here it's typing, or filling
/// in from NIH's label database by name.
struct MacSupplementEditor: View {
    @EnvironmentObject private var wellness: WellnessStore
    @Environment(\.dismiss) private var dismiss
    /// Deletes through the page, so it gets the same Undo as a right-click delete.
    let onDelete: (() -> Void)?

    private let existingID: UUID
    private let isNew: Bool
    @State private var name: String
    @State private var kind: SupplementSchedule.Kind
    @State private var dose: String
    @State private var time: Date
    @State private var enabled: Bool
    @State private var note: String
    /// Not shown, but carried through save: the interaction check reads what's in the bottle.
    @State private var ingredients: [String]
    /// Due around a moment instead of at its time (`TimingAnchor`).
    @State private var anchor: TimingAnchor?
    @State private var searching = false
    @State private var filledNote = ""

    init(supplement: SupplementSchedule?, onDelete: (() -> Void)?) {
        self.onDelete = onDelete
        existingID = supplement?.id ?? UUID()
        isNew = supplement == nil
        _name = State(initialValue: supplement?.name ?? "")
        _kind = State(initialValue: supplement?.kind ?? .supplement)
        _dose = State(initialValue: supplement?.dose ?? "")
        _time = State(initialValue: Calendar.current.date(from: .init(hour: supplement?.safeHour ?? 8,
                                                                      minute: supplement?.safeMinute ?? 0)) ?? Date())
        _enabled = State(initialValue: supplement?.enabled ?? true)
        _note = State(initialValue: supplement?.note ?? "")
        _ingredients = State(initialValue: supplement?.ingredients ?? [])
        _anchor = State(initialValue: supplement?.anchor)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                // A new one starts from its bottle; one already set up, from what it is.
                if isNew { fillIn }
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(SupplementSchedule.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    TextField("Name", text: $name, prompt: Text("Vitamin D3"))
                    TextField("Dose", text: $dose, prompt: Text("1 capsule"))
                }
                Section("When") {
                    TimingFields(anchor: $anchor, time: $time,
                                 others: AnchoredTimingHub.otherMoments(excluding: existingID, supplements: wellness.supplements))
                    Toggle("Reminder", isOn: $enabled)
                }
                NotesField(title: "Note (optional)", text: $note)
                if !isNew { fillIn }
                if let onDelete, !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            dismiss()
                            onDelete()
                        }
                    }
                }
            }
            .editingFormStyle()
            .navigationTitle(isNew ? "Add" : "Edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .sheet(isPresented: $searching) {
                SupplementCatalogSearchView { entry in
                    name = entry.displayName
                    if !entry.dose.isEmpty { dose = entry.dose }
                    if !entry.ingredients.isEmpty { ingredients = entry.ingredients }
                    filledNote = "Filled in from NIH\u{2019}s label database"
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 540, idealHeight: 620)
    }

    /// Search NIH's label database by name. Scanning and the label's photo need a camera: the
    /// iPhone's editor.
    private var fillIn: some View {
        Section("Fill in") {
            Button { searching = true } label: {
                Label("Search by name", systemImage: "magnifyingglass")
            }
            if !filledNote.isEmpty {
                Label(filledNote, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.success)
            }
        }
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        wellness.upsertSupplement(.init(id: existingID, name: name, kind: kind, dose: dose,
                                        hour: parts.hour ?? 8, minute: parts.minute ?? 0,
                                        enabled: enabled, note: note, ingredients: ingredients, anchor: anchor))
        dismiss()
    }
}
