#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

/// Distinguishes a barcode lookup's outcome in the UI. A genuine miss and a network hiccup are
/// different facts — collapsing them into one gray caption is what made every failed scan read
/// as "nothing happened," so each gets its own color and icon instead.
private enum BarcodeNoteKind {
    case success, notFound, networkError, rateLimited, unavailable

    var color: Color {
        switch self {
        case .success: return .secondary
        case .notFound: return DS.Palette.warning
        case .networkError: return DS.Palette.danger
        case .rateLimited: return DS.Palette.warning
        case .unavailable: return DS.Palette.danger
        }
    }

    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .notFound: return "questionmark.circle.fill"
        case .networkError: return "wifi.exclamationmark"
        case .rateLimited: return "clock.badge.exclamationmark"
        case .unavailable: return "text.badge.xmark"
        }
    }
}

/// One caption row shared by the food and supplement barcode flows, so all five lookup outcomes
/// render in a consistent, clearly distinguishable way without a bigger visual redesign.
private func barcodeNoteLabel(_ text: String, kind: BarcodeNoteKind) -> some View {
    Label(text, systemImage: kind.symbolName)
        .font(.caption)
        .foregroundStyle(kind.color)
}

/// Names the actual source(s) that filled a barcode result, rather than a single hardcoded
/// provider name — the cascade now spans up to four sources, and a merged record can legitimately
/// draw its name from one and its serving from another (see `BarcodeProductLookup.mergeFields`).
/// Appends a plain note when Apple's on-device model was unavailable and the deterministic
/// fallback tidied the name instead, so that never happens silently.
private func barcodeSourceCaption(_ product: BarcodeProduct) -> String {
    var seen = Set<ProductDataSource>()
    let sources = [product.nameSource, product.servingSource].compactMap { $0 }.filter { seen.insert($0).inserted }
        .filter { $0 != .bundledCatalog }
    return sources.isEmpty ? "Filled in from its barcode"
        : "Filled in from \(sources.map(\.displayName).joined(separator: " and "))"
}

struct WellnessView: View {
    @EnvironmentObject private var wellness: WellnessStore
    /// Food / Taken lives in ShellNavigation so coming back from another app (which rebuilds
    /// the tree on iOS) doesn't flip it back to Food.
    @ObservedObject private var shell = ShellNavigation.shared
    private var section: Section {
        get {
            shell.state.nutritionSection.flatMap(Section.init(rawValue:))
                ?? (ProcessInfo.processInfo.arguments.contains("--wellness-taken") ? .supplements : .nutrition)
        }
        nonmutating set { shell.state.nutritionSection = newValue.rawValue }
    }
    @State private var addingSupplement = false
    @ObservedObject private var badges = ActionBadges.shared
    @Environment(\.addOpensList) private var addOpensList

    /// What you eat, and what you take — supplements and prescriptions share the second tab
    /// because they share a schedule, a log, and a reminder. The guided plans ("Coach") moved to
    /// the Workouts tab, where the sessions they produce live; the a11y ids kept their `wellness.`
    /// prefix on purpose, including `addSupplement`, which now adds either kind.
    private enum Section: String, CaseIterable { case nutrition = "Food", supplements = "Taken" }

    var body: some View {
        let _ = RenderStats.note("WellnessView")
        VStack(spacing: 0) {
            switch section {
            case .nutrition: NutritionView()
            case .supplements:
                SupplementsView(adding: $addingSupplement)
                    // The page's one +: it was a button at the top right, on this half only.
                    .addButton(identifier: "wellness.addSupplement") { addingSupplement = true }
            }
        }
        .background(Color(.systemGroupedBackground))
        // From the + on the tab bar's row, which has switched to Taken on the way.
        .onAdd(.supplement) { _ in addingSupplement = true }
        .navigationTitle("Food")
        .navigationBarTitleDisplayMode(.inline)
        // Anything logged on the Mac since, before you read the day.
        .onAppear {
            CloudWellnessSync.shared.refresh()
            // `--wellness-taken` opens on Taken: the switch, which reads the shell, says so too.
            if shell.state.nutritionSection == nil, ProcessInfo.processInfo.arguments.contains("--wellness-taken") {
                shell.state.nutritionSection = Section.supplements.rawValue
            }
        }
        .toolbar {
            ReviewToolbarItem(section: .nutrition)
            // The page's switch, in the top bar like Plan's (`PageSwitch`). It was a full-width
            // row under the bar.
            ToolbarItem(placement: .principal) {
                // Sharing a tab with Workouts, the one switch covers all three (`BodySwitch`).
                if addOpensList {
                    BodySwitch()
                } else {
                    PageSwitch(label: "Nutrition section", selection: Binding(get: { section }, set: { section = $0 }),
                               choices: Section.allCases) { item in
                        // What's waiting in each: meals to log, doses due and not marked.
                        let count = item == .nutrition ? badges.counts.food : badges.counts.taken
                        return count > 0 ? "\(item.rawValue) · \(count)" : item.rawValue
                    }
                }
            }
            ToolbarItem(placement: .automatic) { MoreMenu() }
        }
    }
}

private struct NutritionView: View {
    @EnvironmentObject private var wellness: WellnessStore
    /// Which "log food" sheet is open, kept in ShellNavigation so a half-typed meal is still
    /// open after switching apps (the iOS tree is rebuilt on return).
    private var captureMode: MealCaptureMode? {
        get {
            shell.state.nutritionCapture.flatMap(MealCaptureMode.init(rawValue:))
        }
        nonmutating set { shell.state.nutritionCapture = newValue?.rawValue }
    }
    @ObservedObject private var shell = ShellNavigation.shared
    /// Search foods (`FoodSearchView`). Not kept in ShellNavigation like `captureMode`: a meal
    /// started from a search holds nothing until a food is picked, so there's nothing to come back
    /// to after the app was away. (`--food-search` opens it, to look at.)
    @State private var showingRecentMeals = false
    @State private var searchingFood = ProcessInfo.processInfo.arguments.contains("--food-search")
    /// The meal a tap on a Today row opens for editing. Separate from `captureMode`, which only
    /// ever starts a *new* meal — this reuses `FoodTextCaptureView(editing:)` instead.
    @State private var editingMeal: MealEntry?
    /// A meal deleted a moment ago stays hidden here until its Undo window closes.
    @ObservedObject private var toasts = ToastCenter.shared
    @ObservedObject private var inbox = MealInboxStore.shared
    /// "Add photos & notes" for the day on screen.
    @State private var adding: MealDayRequest?
    #if DEBUG
    /// `--meal-photo-viewer` (with `--meal-backlog`): the logged meal's photos full size.
    @State private var previewPhotos: MealPhotoViewing?
    @State private var describePreview = false
    #endif
    /// A day's estimates open for review.
    @State private var reviewing: MealDayRequest?
    /// A backlog meal entered by hand after estimating it failed.
    @State private var enteringByHand: MealInboxItem?
    /// Your scanned foods (`MyFoodsView`).
    @State private var showingMyFoods = false
    @State private var scanningGroceries = false
    @ObservedObject private var myFoods = MyFoodsStore.shared
    /// The day on screen — today unless you've gone back. In ShellNavigation so a trip to another
    /// app doesn't snap it back to today.
    private var day: Date {
        get {
            let today = Calendar.current.startOfDay(for: Date())
            return shell.state.nutritionDay.map { min(Calendar.current.startOfDay(for: $0), today) } ?? today
        }
        nonmutating set {
            shell.state.nutritionDay = Calendar.current.isDateInToday(newValue) ? nil : newValue
        }
    }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var visibleMeals: [MealEntry] {
        wellness.meals.filter { !toasts.hiddenIDs.contains($0.id.uuidString) }
    }
    /// The day's meals (named `today` from before there were other days to look at).
    private var today: [MealEntry] { NutritionDays.meals(visibleMeals, on: day) }
    private var total: NutritionMacros { today.reduce(.init()) { $0 + $1.totals } }

    var body: some View {
        let _ = RenderStats.note("NutritionView")
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // The one date line (`PageChrome`). Back is for filling in a day that was missed.
                DateLine(current: "Today", dates: day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                         isCurrent: isToday, canGoForward: !isToday, titleIdentifier: "nutrition.day",
                         step: { day = NutritionDays.step(day, by: $0) },
                         toCurrent: { day = Calendar.current.startOfDay(for: Date()) })
                list
            }
            // The one + (`PageChrome`): every way to log, where the four tiles and "Enter by
            // hand" were. Logging adds to the day on screen.
            .addMenu(identifier: "wellness.add") {
                Button { showingRecentMeals = true } label: { Label("Recent meals", systemImage: "clock.arrow.circlepath") }
                    .accessibilityIdentifier("wellness.recentMeals")
                // Describe first: one sentence, typed or dictated, covers a whole meal.
                Button { captureMode = .text } label: { Label("Describe", systemImage: "text.bubble") }
                    .accessibilityIdentifier("wellness.textMeal")
                // By name, from what you've had, USDA's foods and packaged products.
                Button { searchingFood = true } label: { Label("Search", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("wellness.searchFood")
                Button { captureMode = .barcode } label: { Label("Scan", systemImage: "barcode.viewfinder") }
                    .accessibilityIdentifier("wellness.barcodeMeal")
                Button { adding = MealDayRequest(day: day) } label: { Label("Photos", systemImage: "photo.on.rectangle.angled") }
                    .accessibilityIdentifier("wellness.photoMeal")
                Button { captureMode = .manual } label: { Label("By hand", systemImage: "square.and.pencil") }
                    .accessibilityIdentifier("wellness.manualMeal")
                // Not a meal: what you bought, into your foods, before you've had any of it.
                Button { scanningGroceries = true } label: { Label("Groceries", systemImage: "cart") }
                    .accessibilityIdentifier("add.groceries")
            }
            // The same five, picked from the + on the tab bar's row.
            .onAdd(.recentMeal, .describeMeal, .searchFood, .scanFood, .mealPhotos, .mealByHand, .groceries) { kind in
                switch kind {
                case .recentMeal: showingRecentMeals = true
                case .describeMeal: captureMode = .text
                case .searchFood: searchingFood = true
                case .scanFood: captureMode = .barcode
                case .groceries: scanningGroceries = true
                case .mealPhotos: adding = MealDayRequest(day: day)
                default: captureMode = .manual
                }
            }
                #if DEBUG
                // `--energy-balance`: down to the card, so it can be looked at without a scroll.
                .task {
                    guard EnergyBalance.Preview.requested() != nil else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo(EnergyBalanceCard.title, anchor: .center)
                }
                #endif
        }
    }

    @ViewBuilder private var list: some View {
        // Each read of these filters every logged meal, and one pass read them a dozen times: once
        // per pass now. (The preview hooks below keep reading the live properties — they wait on them.)
        let visible = visibleMeals
        let dayMeals = today
        List {
            Section {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    NutritionWeekStrip(day: Binding(get: { day }, set: { day = $0 }), meals: visible)
                    Divider()
                    daySummary
                    Button { showingRecentMeals = true } label: {
                        Label("Recent meals", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("nutrition.recentMeals")
                }
                .padding(.vertical, DS.Space.xs)
            }

            if !inbox.items.isEmpty {
                Section {
                    MealBacklogPanel(onReviewDay: { reviewing = MealDayRequest(day: $0) },
                                     onEnterByHand: { enteringByHand = $0 }, inList: true)
                } header: {
                    Text("To log")
                }
            }

            if dayMeals.isEmpty {
                Section {
                    // An empty page: one line, and a button that does what + does.
                    ContentUnavailableView {
                        Label("No food logged", systemImage: "fork.knife")
                    } actions: {
                        Button("Log food") { captureMode = .text }
                            .buttonStyle(.primary)
                            .accessibilityIdentifier("wellness.empty.log")
                    }
                }
            } else {
                // The day as a timeline: meals under the part of the day they were eaten in, each
                // part with its subtotal, each meal with its time in a column of its own.
                ForEach(DayPart.allCases, id: \.self) { part in
                    let meals = dayMeals.filter { DayPart.of($0.date) == part }.sorted { $0.date < $1.date }
                    if !meals.isEmpty {
                        Section {
                            ForEach(meals) { meal in mealRow(meal) }
                        } header: {
                            HStack {
                                Text(part.rawValue)
                                Spacer()
                                Text(NutritionText.kcal(meals.reduce(.init()) { $0 + $1.totals }))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }

            Section {
                Button { showingMyFoods = true } label: {
                    HStack {
                        logRow("My foods", "basket")
                        Spacer()
                        if !myFoods.foods.isEmpty {
                            Text("\(myFoods.foods.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .accessibilityIdentifier("wellness.myFoods")
            }

            // The logs against the weight trend were here: looking back, so in Review now.

            EstimateLearningSection(meals: visibleMeals)

            MealPhotoScanSettingsSection()
        }
        // The first section has no header: without this it sat a blank band below the date line.
        .contentMargins(.top, DS.Space.s, for: .scrollContent)
        .sheet(item: Binding(get: { captureMode }, set: { captureMode = $0 })) { mode in
            // One sheet for every way in, the same one the iPad and the Mac open. Scan and
            // "Enter by hand" opened an older sheet here: it had no amount control, and what it
            // scanned never became one of your foods.
            switch mode {
            case .text: FoodTextCaptureView(day: day)
            case .barcode: FoodTextCaptureView(scanningOn: day)
            case .manual: FoodTextCaptureView(byHandOn: day)
            }
        }
        .sheet(isPresented: $showingRecentMeals) { RecentMealsView(day: day) }
        .sheet(isPresented: $searchingFood) { FoodTextCaptureView(searchingOn: day) }
        .sheet(item: $adding) { request in MealDumpView(day: request.day) }
        .sheet(item: $reviewing) { request in MealDayReviewView(day: request.day) }
        .sheet(item: $enteringByHand) { item in FoodTextCaptureView(reviewing: item) }
        .sheet(item: $editingMeal) { meal in
            // Same row editor a new meal review uses — see FoodTextCaptureView's header comment.
            FoodTextCaptureView(editing: meal)
        }
        .sheet(isPresented: $showingMyFoods) { MyFoodsView() }
        .fullScreenCover(isPresented: $scanningGroceries) { GroceryScanView() }
        #if DEBUG
        .fullScreenCover(item: $previewPhotos) { MealPhotoViewer(ids: $0.ids, start: $0.start) }
        .sheet(isPresented: $describePreview) { FoodTextCaptureView(day: day) }
        #endif
        // Opens the row editor on today's first meal, so the editor itself can be looked at
        // without a tap.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            #if DEBUG
            // `--meal-review` / `--meal-dump`: open the day review (yesterday) or Add photos &
            // notes (with drawn photos), so each can be looked at without a tap.
            if args.contains("--meal-review") {
                reviewing = MealDayRequest(day: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            }
            if args.contains("--meal-dump") { adding = MealDayRequest(day: day) }
            // `--scan-correct-preview`: a meal whose estimate said "Gnocchi", open for correcting with
            // a food of yours as if scanned (`MyFoodsStore.injectPreview`). `--my-foods`: the list.
            if args.contains("--scan-correct-preview") {
                // Long enough for a UI test to step the amount and still reach Undo.
                ToastCenter.window = .seconds(30)
                editingMeal = MyFoodsStore.shared.injectPreview()
            }
            if args.contains("--my-foods") {
                ToastCenter.window = .seconds(30)
                MyFoodsStore.shared.injectPreview()
                showingMyFoods = true
            }
            // `--meal-amount-editor`: that cucumber open in the editor, for its amount.
            if args.contains("--meal-amount-editor") {
                editingMeal = MealEntry(date: Date(), items: [MealInboxStore.previewCucumber], source: .photo,
                                        name: "Cucumber wrapped seaweed")
            }
            // `--meal-amount-scanned`: a pack of seaweed scanned from a package that says no
            // serving — beside a cucumber — open in the editor with its amount still to say.
            if args.contains("--meal-amount-scanned") {
                // Not kept among your foods: a preview that saved one left it there for every
                // later launch, first in the list other screens show.
                let nori = MyFood(
                    name: "Sushi Nori Roasted Seaweed", barcode: "0087703011274",
                    per100g: NutritionMacros(calories: 416.67, proteinGrams: 41.67, carbohydrateGrams: 41.67, fatGrams: 0),
                    servingLabel: "100 g", servingGrams: 100, packageGrams: 72, servingStated: false, source: .barcode)
                editingMeal = MealEntry(date: Date(), items: [ScanCorrection.item(food: nori, grams: 0),
                                                              MealInboxStore.previewCucumber],
                                        source: .photo, name: "Cucumber wrapped seaweed")
            }
            if args.contains("--meal-photo-viewer"), let ids = today.first?.photoIDs, !ids.isEmpty {
                previewPhotos = MealPhotoViewing(ids: ids, start: 0)
            }
            #endif
        }
        #if DEBUG
        .task {
            // `--describe-preview`: a week of meals and a habit at this time of day, with
            // "Describe what you ate" open on them, so "Usually around now" has something to
            // offer. After the route's own sample meals are in: they replace the list, and put in
            // first, these were gone by the time the sheet looked.
            guard ProcessInfo.processInfo.arguments.contains("--describe-preview") else { return }
            for _ in 0..<30 where today.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            wellness.injectWeekPreview()
            // Injected, not logged: logging saves, and a saved week of sample meals was still
            // there on the next launch — where the editor's preview opened one of them instead.
            wellness.injectPreviewMeals((1...3).map { offset in
                MealEntry(id: UUID(uuidString: String(format: "BA9A9A00-0000-4000-8000-%012d", 900 + offset))!,
                          date: Date().addingTimeInterval(-Double(offset) * 86_400), items: [
                    MealItem(name: "Greek yogurt", serving: "1 cup", macros: .init(calories: 160, proteinGrams: 18,
                             carbohydrateGrams: 9, fatGrams: 4), grams: 245),
                    MealItem(name: "Blueberries", serving: "\u{00BD} cup", macros: .init(calories: 42, proteinGrams: 1,
                             carbohydrateGrams: 11, fatGrams: 0), grams: 74),
                ], source: .text)
            })
            // Its own sheet: the real one is restored state, and would reopen on every launch.
            describePreview = true
        }
        .task {
            // `--meal-editor-preview`: the preview's meal open in the editor — once the preview
            // meals are in. They're put in by the route around this view, whose onAppear can come
            // after this one's: opening at once found no meal and opened nothing. Debug only,
            // like the preview meals themselves.
            guard ProcessInfo.processInfo.arguments.contains("--meal-editor-preview") else { return }
            // The preview's own meal, by its id — not whichever of today's comes first, which
            // is something else whenever the store already holds meals for today.
            var sample: MealEntry? { today.first { $0.id == WellnessStore.previewMealID } }
            for _ in 0..<30 where sample == nil { try? await Task.sleep(for: .milliseconds(100)) }
            editingMeal = sample ?? today.first
        }
        #endif
    }

    private func mealTitle(_ meal: MealEntry) -> String { NutritionText.mealTitle(meal) }

    /// The day's calories and macros, in the day's own card — the same figure as the iPad and
    /// Mac page, a meal and a food. Nothing logged: "—", not zeros.
    private var daySummary: some View {
        NutritionSummary(label: isToday ? "So far today" : "Total", macros: today.isEmpty ? nil : total, size: .tile)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("nutrition.dayTotal")
    }

    private func logRow(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(DS.Palette.accent)
        }
    }

    private func mealRow(_ meal: MealEntry) -> some View {
        // A tap, not a Button: a Button row swallows the tap on the meal's photo, which shows the
        // photo full size (`opensMealPhotos`).
        MealRowLabel(meal: meal)
            .onTapGesture { editingMeal = meal }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editingMeal = meal }
            .accessibilityIdentifier("nutrition.meal")
        // Gone at once, removed for real when the Undo window closes.
        .swipeActions { Button("Delete", role: .destructive) { delete(meal) } }
        // Press-and-hold offers what tap and swipe do, on every row (`PageChrome`).
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editingMeal = meal }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(meal) }
        }
    }

    private func delete(_ meal: MealEntry) {
        let wellness = wellness
        Task {
            await ToastCenter.shared.deferRemoval(
                id: meal.id.uuidString,
                message: "Deleted \u{201C}\(mealTitle(meal))\u{201D}",
                failure: { "Couldn\u{2019}t delete: \($0)" }
            ) {
                wellness.deleteMeal(meal.id)
                return nil
            }
        }
    }

}

/// Which way into the one "log food" sheet: a sentence, a package scanned, or by hand.
private enum MealCaptureMode: String, Identifiable {
    case text, barcode, manual
    var id: String { rawValue }
}

/// The camera, for one photo: a meal (`MealDumpView`) or a supplement label.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            parent.image = info[.originalImage] as? UIImage; parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

private struct SupplementsView: View {
    @EnvironmentObject private var wellness: WellnessStore
    /// When things are due around a moment (after your workout), and redraws when one comes.
    @ObservedObject private var hub = AnchoredTimingHub.shared
    /// The minute, so a dose turns due when its time comes with the list open. (A TimelineView
    /// around the rows made them one row, and lost each row's background.)
    @State private var now = Date()
    @State private var editing: SupplementSchedule?
    /// One deleted a moment ago stays hidden until its Undo window closes.
    @ObservedObject private var toasts = ToastCenter.shared
    @Binding var adding: Bool
    @ObservedObject private var shell = ShellNavigation.shared

    /// The day on screen: Food's (`nutritionDay`), so the switch keeps it. A past day shows what
    /// was taken then, as the iPad and Mac page does; ticking one logs it at its time that day.
    private var day: Date {
        get {
            let today = Calendar.current.startOfDay(for: Date())
            return shell.state.nutritionDay.map { min(Calendar.current.startOfDay(for: $0), today) } ?? today
        }
        nonmutating set {
            shell.state.nutritionDay = Calendar.current.isDateInToday(newValue) ? nil : newValue
        }
    }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(spacing: 0) {
            // The one date line (`PageChrome`), as Food has.
            DateLine(current: "Today", dates: day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                     isCurrent: isToday, canGoForward: !isToday, titleIdentifier: "taken.day",
                     step: { day = NutritionDays.step(day, by: $0) },
                     toCurrent: { day = Calendar.current.startOfDay(for: Date()) })
            doses
        }
    }

    private var doses: some View {
        List {
            // What Banana noticed: a reminder that's something taken, a moment one follows.
            if isToday { TakenTimingOffers(inList: true) }
            if schedule.isEmpty {
                Section {
                    // An empty page: one line, and a button that does what + does.
                    ContentUnavailableView {
                        Label("Nothing scheduled", systemImage: "pills")
                    } actions: {
                        Button("Add something you take") { adding = true }
                            .buttonStyle(.primary)
                            .accessibilityIdentifier("taken.empty.add")
                    }
                }
            } else {
                // Clashes are about today's times.
                if isToday { timingSection }
                ForEach(SupplementSchedule.Kind.allCases, id: \.self) { kind in
                    let items = schedule.filter { $0.kind == kind }
                    if !items.isEmpty { section(kind, items) }
                }
            }
        }
        .sheet(isPresented: $adding) { SupplementEditor(supplement: nil) }
        // Opens the add sheet straight away, so the editor can be looked at without a tap. Same
        // convention as `--meal-editor-preview`.
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--supplement-editor-preview") { adding = true }
            #if DEBUG
            // `--supplement-anchored-preview`: Creatine due after your workout, open to edit.
            if ProcessInfo.processInfo.arguments.contains("--supplement-anchored-preview") {
                editing = SupplementSchedule(name: "Creatine", dose: "5 g", hour: 20,
                                             anchor: TimingAnchor(moment: .workout, minutes: 15))
            }
            #endif
        }
        .sheet(item: $editing) { SupplementEditor(supplement: $0) }
        .task { await AnchorSuggestionStore.shared.refreshIfStale(maxAge: 2 * 60) }
        .task {
            while !Task.isCancelled {
                now = Date()
                let next = 60 - Calendar.current.component(.second, from: now)
                try? await Task.sleep(for: .seconds(next))
            }
        }
    }

    /// What's listed: everything scheduled, less one deleted a moment ago.
    private var schedule: [SupplementSchedule] {
        wellness.supplements.filter { !toasts.hiddenIDs.contains($0.id.uuidString) }
    }

    /// Gone at once, removed for real — its dose history with it, on every device — when the
    /// Undo window closes. As on the wide Nutrition page: this swipe used to delete outright.
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

    private func section(_ kind: SupplementSchedule.Kind, _ items: [SupplementSchedule]) -> some View {
        Section {
            ForEach(items) { supplement in
                row(supplement, now: now)
            }
        } header: {
            Text(kind.plural)
        }
    }

    /// One dose: tick it, what and when, edit it. Due and not yet marked, the whole row is amber
    /// and its time says since when — the same rule as the Nutrition badge (`ActionItems.dueSince`); one
    /// waiting for its moment ("After your workout") isn't due yet.
    private func row(_ supplement: SupplementSchedule, now: Date) -> some View {
        let status = wellness.supplementStatus(supplement.id, on: isToday ? now : day)
        // A past day shows what happened, not what's due.
        let dueSince = isToday ? ActionItems.dueSince(supplement, marked: status != nil,
                                                      due: hub.dueDate(supplement, now: now), now: now) : nil
        let when = dueSince.map { ActionItems.dueText(since: $0, now: now) } ?? hub.timeText(supplement, now: now)
        return HStack(spacing: DS.Space.m) {
            Button {
                wellness.logSupplement(supplement.id, status: status == .taken ? .skipped : .taken,
                                       at: NutritionDays.doseDate(for: supplement, on: day))
            } label: {
                Image(systemName: status == .taken ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(status == .taken ? DS.Palette.success : .secondary)
            }.iconButton().accessibilityLabel(status == .taken ? "Mark not taken" : "Mark taken")
            // Tap opens it, like every row (`PageChrome`): it had a slider icon of its own.
            Button { editing = supplement } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(supplement.name)
                        Text([supplement.dose, when].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                            .font(.caption.weight(dueSince == nil ? .regular : .semibold))
                            .foregroundStyle(dueSince == nil ? Color.secondary : DS.Palette.warning)
                    }
                    Spacer()
                    // Skipped on purpose reads differently from not yet marked, as on the wide page.
                    if status == .skipped {
                        Text("Skipped").font(.caption).foregroundStyle(.secondary)
                    }
                    RowChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("taken.edit")
        }
        // The row, not only its words: a due dose is found at a glance. (The amber wash means
        // only this now: a meal's estimate has its own mark.)
        .listRowBackground(dueSince == nil ? nil : DS.Palette.warning.opacity(DS.Tint.soft))
        .accessibilityElement(children: .contain)
        .accessibilityValue(dueSince == nil ? "" : "Due")
        .accessibilityIdentifier(dueSince == nil ? "taken.row" : "taken.row.due")
        .swipeActions { Button("Delete", role: .destructive) { delete(supplement) } }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = supplement }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(supplement) }
        }
    }

    /// Absorption clashes in today's actual schedule, with the fix attached.
    ///
    /// Only shown when there is something to say. A permanent, usually-empty "Interactions" header
    /// is a box people learn to skip, which is the same failure as a warning that cries wolf.
    @ViewBuilder
    private var timingSection: some View {
        let intakes = wellness.todaysIntakes()
        let conflicts = SupplementInteractions.conflicts(among: intakes)
        if !conflicts.isEmpty {
            let suggestions = SupplementInteractions.suggestions(among: intakes)
            Section {
                ForEach(conflicts) { conflict in
                    SupplementClashRow(conflict: conflict, fix: SupplementClashRow.fix(for: conflict, in: suggestions))
                        .padding(.vertical, DS.Space.xs)
                }
            } header: {
                Text("Timing")
            }
        }
    }

    private func time(_ item: SupplementSchedule) -> String {
        Calendar.current.date(from: .init(hour: item.safeHour, minute: item.safeMinute))?.formatted(date: .omitted, time: .shortened) ?? ""
    }
}

/// Where a `SupplementEditor` field's current value came from, so the form can give a
/// photographed-label value the amber-vs-plain emphasis the food entry review screen already
/// uses for its own AI-derived rows (see `barcodeNoteLabel`), driven by the OCR recognition
/// confidence rather than one blanket warning for the whole panel.
private enum SupplementFieldOrigin: Equatable {
    case typed
    case barcode
    case labelPhoto(confidence: Double)

    /// `>= 0.9` mirrors `ResolvedFoodItem.isConfident`'s cutoff. Typed and barcode-database
    /// values have no OCR ambiguity to flag, so they always read as confident.
    var isConfident: Bool {
        if case .labelPhoto(let confidence) = self { return confidence >= 0.9 }
        return true
    }

    /// Only a doubtful read says anything.
    var caption: String? {
        guard case .labelPhoto = self, !isConfident else { return nil }
        return "Check this against the bottle"
    }
}

private struct SupplementEditor: View {
    @EnvironmentObject private var wellness: WellnessStore
    @Environment(\.dismiss) private var dismiss
    let existingID: UUID
    @State private var name: String
    @State private var kind: SupplementSchedule.Kind
    @State private var dose: String
    @State private var time: Date
    @State private var enabled: Bool
    @State private var note: String
    /// Kept out of sight — there is nothing to edit here — but carried through save so the
    /// interaction check can see what is actually in the bottle.
    @State private var ingredients: [String]
    /// Due around a moment instead of at its time (`TimingAnchor`).
    @State private var anchor: TimingAnchor?
    @State private var nameOrigin: SupplementFieldOrigin = .typed
    @State private var doseOrigin: SupplementFieldOrigin = .typed
    @State private var showBarcodeScanner = false
    @State private var lookingUpBarcode = false
    @State private var barcodeNote = ""
    @State private var barcodeNoteKind: BarcodeNoteKind = .success
    @State private var showCatalogSearch = false
    @State private var showLabelCamera = false
    @State private var labelImage: UIImage?
    @State private var analyzingLabel = false
    @State private var labelNote = ""
    @State private var labelNoteKind: BarcodeNoteKind = .success
    @State private var errorMessage: String?
    /// Tracked so a network lookup is cancelled — not left running against a dismissed sheet —
    /// the moment the person backs out of this screen.
    @State private var lookupTask: Task<Void, Never>?

    private let isNew: Bool

    init(supplement: SupplementSchedule?) {
        existingID = supplement?.id ?? UUID()
        isNew = supplement == nil
        _name = State(initialValue: supplement?.name ?? "")
        _kind = State(initialValue: supplement?.kind ?? .supplement)
        _dose = State(initialValue: supplement?.dose ?? "")
        _time = State(initialValue: Calendar.current.date(from: .init(hour: supplement?.safeHour ?? 8, minute: supplement?.safeMinute ?? 0)) ?? Date())
        _enabled = State(initialValue: supplement?.enabled ?? true)
        _note = State(initialValue: supplement?.note ?? "")
        _ingredients = State(initialValue: supplement?.ingredients ?? [])
        _anchor = State(initialValue: supplement?.anchor)
    }

    var body: some View {
        NavigationStack {
            Form {
                // A new one starts from its bottle; one already set up, from what it is.
                if isNew { fillIn }
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(SupplementSchedule.Kind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("wellness.supplementKind")
                }
                Section {
                    fieldRow(title: "Name", prompt: "Vitamin D3", text: $name, origin: nameOrigin)
                    fieldRow(title: "Dose", prompt: "1 capsule", text: $dose, origin: doseOrigin)
                }
                Section("When") {
                    TimingFields(anchor: $anchor, time: $time,
                                 others: AnchoredTimingHub.otherMoments(excluding: existingID, supplements: wellness.supplements))
                    Toggle("Reminder", isOn: $enabled)
                }
                NotesField(title: "Note (optional)", text: $note)
                if !isNew { fillIn }
            }
            .editingFormStyle()
            .navigationTitle(isNew ? "Add" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { lookupTask?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onDisappear { lookupTask?.cancel() }
            .sheet(isPresented: $showBarcodeScanner) {
                BarcodeScannerView(
                    onScan: { barcode in
                        showBarcodeScanner = false
                        lookupTask = Task { await lookupBarcode(barcode) }
                    },
                    onError: { message in
                        showBarcodeScanner = false
                        errorMessage = message
                    })
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showCatalogSearch) {
                SupplementCatalogSearchView { entry in
                    name = entry.displayName
                    nameOrigin = .barcode
                    if !entry.dose.isEmpty { dose = entry.dose; doseOrigin = .barcode }
                    if !entry.ingredients.isEmpty { ingredients = entry.ingredients }
                    barcodeNoteKind = .success
                    barcodeNote = "Filled in from NIH\u{2019}s label database"
                }
            }
            .sheet(isPresented: $showLabelCamera) { CameraPicker(image: $labelImage) }
            .onChange(of: labelImage) { old, new in
                guard old == nil, let new else { return }
                lookupTask = Task { await analyzeLabel(new) }
            }
            .alert("Couldn’t fill this in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    /// One editable field plus, only when it was filled from a photographed label, a caption
    /// naming its recognition confidence and an amber row background for a value under the
    /// confident threshold — never one blanket warning for the whole panel, since a bottle photo
    /// routinely has some perfectly legible lines next to some genuinely hard ones.
    /// Scan, search or photograph it: filled in from its bottle.
    private var fillIn: some View {
        Section("Fill in") {
            Button { Task { await beginBarcodeScan() } } label: {
                Label("Scan barcode", systemImage: "barcode.viewfinder")
            }
            .accessibilityIdentifier("wellness.scanSupplementBarcode")
            .disabled(lookingUpBarcode)
            Button { showCatalogSearch = true } label: {
                Label("Search by name", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("wellness.searchSupplementCatalog")
            Button { Task { await beginLabelPhoto() } } label: {
                Label("Photograph label", systemImage: "camera.viewfinder")
            }
            .accessibilityIdentifier("wellness.photographSupplementLabel")
            .disabled(analyzingLabel || !UIImagePickerController.isSourceTypeAvailable(.camera))
            if lookingUpBarcode { HStack { ProgressView(); Text("Looking it up\u{2026}") } }
            if analyzingLabel { HStack { ProgressView(); Text("Reading the label\u{2026}") } }
            if !barcodeNote.isEmpty { barcodeNoteLabel(barcodeNote, kind: barcodeNoteKind) }
            if !labelNote.isEmpty { barcodeNoteLabel(labelNote, kind: labelNoteKind) }
        }
    }

    /// A field with its name beside it, so a filled one still says what it is.
    private func fieldRow(title: String, prompt: String, text: Binding<String>, origin: SupplementFieldOrigin) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            LabeledContent(title) {
                TextField(title, text: text, prompt: Text(prompt))
                    .multilineTextAlignment(.trailing)
            }
            if let caption = origin.caption {
                Label(caption, systemImage: origin.isConfident ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(origin.isConfident ? DS.Palette.success : DS.Palette.warning)
            }
        }
        .padding(.vertical, origin.caption == nil ? 0 : DS.Space.xs)
        .listRowBackground(origin.isConfident ? nil : DS.Palette.warning.opacity(DS.Tint.soft))
    }

    @MainActor private func beginBarcodeScan() async {
        guard await requestBarcodeCameraAccess() else {
            errorMessage = "Camera access is off. Allow it in Settings."
            return
        }
        showBarcodeScanner = true
    }

    @MainActor private func beginLabelPhoto() async {
        guard await requestBarcodeCameraAccess() else {
            errorMessage = "Camera access is off. Allow it in Settings."
            return
        }
        labelImage = nil
        showLabelCamera = true
    }

    @MainActor private func lookupBarcode(_ barcode: String) async {
        lookingUpBarcode = true; barcodeNote = ""; barcodeNoteKind = .success
        defer { lookingUpBarcode = false }
        do {
            let outcome = try await BarcodeProductLookup.lookup(barcode)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .foundLocally(let product), .foundOnline(let product):
                fill(from: product, sourceNote: barcodeSourceCaption(product))
            case .notFound:
                barcodeNoteKind = .notFound
                barcodeNote = "No database has this barcode. Photograph the label instead."
            case .networkError:
                barcodeNoteKind = .networkError
                barcodeNote = "Couldn\u{2019}t reach the databases. Try again."
            case .rateLimited:
                barcodeNoteKind = .rateLimited
                barcodeNote = "Lookups are paused for now. Photograph the label instead."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func fill(from product: BarcodeProduct, sourceNote: String) {
        name = product.name
        nameOrigin = .barcode
        if product.serving != "100 g" && product.serving != "1 serving" {
            dose = product.serving
            doseOrigin = .barcode
        }
        if let found = product.ingredients, !found.isEmpty { ingredients = found }
        barcodeNote = sourceNote
    }

    /// Reads a photographed Supplement Facts label via `SupplementLabelExtractor` and fills
    /// whichever of name/dose it could confidently produce — this is the guaranteed fallback for
    /// a barcode no database will ever cover. Every field it fills carries its own recognition
    /// confidence forward into `nameOrigin`/`doseOrigin`, which is what drives the amber-vs-plain
    /// row treatment above: a number read off a photo looks just as authoritative as one from a
    /// database, so a low-confidence read must never be presented identically to a clean one.
    @MainActor private func analyzeLabel(_ image: UIImage) async {
        analyzingLabel = true; labelNote = ""; labelNoteKind = .success
        defer { analyzingLabel = false }
        switch await SupplementLabelExtractor.extract(from: image) {
        case .record(let record):
            guard record.name != nil || record.dose != nil else {
                labelNoteKind = .notFound
                labelNote = "Couldn\u{2019}t read a name or dose. Try closer, on the Supplement Facts."
                return
            }
            if let nameField = record.name {
                name = nameField.value
                nameOrigin = .labelPhoto(confidence: nameField.confidence)
            }
            if let doseField = record.dose {
                dose = doseField.value
                doseOrigin = .labelPhoto(confidence: doseField.confidence)
            }
            labelNoteKind = .success
            labelNote = "Filled in from the label"
        case .noText:
            labelNoteKind = .notFound
            labelNote = "Couldn\u{2019}t read any text. Try closer, in good light."
        case .permanentlyUnavailable:
            labelNoteKind = .unavailable
            labelNote = "Too much text at once. Photograph just the Supplement Facts."
        }
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        wellness.upsertSupplement(.init(id: existingID, name: name, kind: kind, dose: dose, hour: parts.hour ?? 8, minute: parts.minute ?? 0, enabled: enabled, note: note, ingredients: ingredients, anchor: anchor))
        if enabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
        dismiss()
    }
}

#endif
