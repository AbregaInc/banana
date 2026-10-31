#if os(iOS) || os(macOS)
import SwiftUI

/// Search for a food by name and add it at an amount (`FoodSearch`): what you've had before, the
/// bundled USDA foods, and packaged products — that brand's, when you name one — with Open Food
/// Facts searched online as you type. Tap a result to choose how much; + adds it as shown.
struct FoodSearchView: View {
    /// Words to start from: a row's name, when it's the one being replaced.
    var initialQuery = ""
    /// The weight of what's being replaced: the food found starts at it.
    var replacingGrams: Double?
    var onPick: (MealItem) -> Void
    /// "Enter it by hand": a blank row to fill in. Nil leaves it out.
    var onManual: (() -> Void)?

    @EnvironmentObject private var wellness: WellnessStore
    @ObservedObject private var myFoods = MyFoodsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var yours: [FoodSearch.Result] = []
    @State private var foods: [FoodSearch.Result] = []
    @State private var products: [FoodSearch.Result] = []
    @State private var brand: FoodSearch.Brand?
    @State private var online: Online = .idle
    @State private var searchedOnce = false
    @State private var chosen: FoodSearch.Result?
    @FocusState private var fieldFocused: Bool

    private enum Online { case idle, loading, done, failed }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if trimmed.isEmpty {
                    resultsSection("Suggested", yours)
                } else {
                    resultsSection("Yours", yours)
                    // A brand named: its products are what was asked for, before any food.
                    if brand != nil { productsSection }
                    resultsSection("Foods", foods, footer: foods.isEmpty ? nil : "USDA, on this device.")
                    if brand == nil { productsSection }
                    if searchedOnce, online != .loading, yours.isEmpty, foods.isEmpty, products.isEmpty {
                        Section { ContentUnavailableView.search(text: trimmed) }
                    }
                }

                if let onManual {
                    Section {
                        Button {
                            dismiss()
                            onManual()
                        } label: {
                            Label("Enter it by hand", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("foodSearch.manual")
                    }
                }
            }
            .navigationTitle("Add food")
            // The system's search field, always showing: searching is all this sheet does.
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search foods \u{2014} \u{201C}baby carrots\u{201D}")
            // The bar stays while the field is in use: its Cancel is the sheet's way out.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .textInputAutocapitalization(.never)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .searchable(text: $query, prompt: "Search foods \u{2014} \u{201C}baby carrots\u{201D}")
            .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640)
            #endif
            .searchFocused($fieldFocused)
            .autocorrectionDisabled()
            .navigationDestination(item: $chosen) { result in
                FoodAmountView(result: result, startGrams: replacingGrams) { item in pick(item, from: result) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task(id: trimmed) { await search(trimmed) }
            .onAppear {
                if query.isEmpty { query = initialQuery }
                #if DEBUG
                // `--food-search --food-search-query "trader joes carrots"`: searched, to look at.
                let arguments = ProcessInfo.processInfo.arguments
                if query.isEmpty, let at = arguments.firstIndex(of: "--food-search-query"), at + 1 < arguments.count {
                    query = arguments[at + 1]
                    return   // no keyboard over the results
                }
                #endif
                fieldFocused = true
            }
        }
    }

    @ViewBuilder private func resultsSection(_ title: String, _ results: [FoodSearch.Result], footer: String? = nil) -> some View {
        if !results.isEmpty {
            Section {
                ForEach(results) { row($0) }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    @ViewBuilder private var productsSection: some View {
        if !products.isEmpty || online == .loading || online == .failed {
            Section {
                ForEach(products) { row($0) }
                if online == .loading {
                    HStack(spacing: DS.Space.s) {
                        ProgressView()
                        Text("Searching Open Food Facts\u{2026}").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(brand.map { "\($0.name) products" } ?? "Products")
            } footer: {
                if online == .failed {
                    Text("Couldn\u{2019}t reach Open Food Facts \u{2014} these are the products on this device.")
                } else if brand != nil, !foods.isEmpty {
                    Text("Not here? A brand\u{2019}s plain foods have the same numbers as anyone\u{2019}s: the foods below count too.")
                }
            }
        }
    }

    private func row(_ result: FoodSearch.Result) -> some View {
        HStack(spacing: DS.Space.m) {
            Button { chosen = result } label: {
                HStack(spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(result.name).foregroundStyle(.primary).lineLimit(2)
                        Text([result.item.serving, result.detail].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.s)
                    StatValue(label: nil, value: result.item.macros.calories.rounded().formatted(.number.precision(.fractionLength(0))),
                              unit: "kcal", size: .row)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("foodSearch.result")
            Button { pick(FoodSearch.item(result, amount: start(result), name: result.name), from: result) } label: {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .iconButton()
            .tint(DS.Palette.accent)
            .accessibilityLabel("Add \(result.name), \(result.item.serving)")
            .accessibilityIdentifier("foodSearch.quickAdd")
        }
    }

    /// Where a result starts: at the weight of what it replaces, when it replaces something.
    private func start(_ result: FoodSearch.Result) -> FoodSearch.Amount {
        guard let replacingGrams, FoodSearch.grams(result.start) != nil else { return result.start }
        return FoodSearch.converted(FoodSearch.Amount(count: replacingGrams, unit: .grams), to: result.start.unit)
    }

    private func pick(_ item: MealItem, from result: FoodSearch.Result) {
        if let id = item.reference?.id { FoodSearchPicks.record(query: trimmed, referenceID: id) }
        onPick(item)
        dismiss()
    }

    // MARK: - Searching

    private func search(_ text: String) async {
        let picked = FoodSearchPicks.picks(for: text)
        let meals = wellness.meals
        let scanned = myFoods.foods
        guard !text.isEmpty else {
            let usual = UsualFoods.foods(at: Date(), meals: meals, myFoods: scanned)
            yours = await Task.detached { FoodSearch.usual(usual, portions: FoodSearchSources.portions) }.value
            foods = []; products = []; brand = nil; online = .idle
            return
        }
        // Let the typing settle.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let index = await FoodSearchSources.brandIndex()
        let (local, mine) = await Task.detached { () -> (FoodSearchSources.Local, [FoodSearch.Result]) in
            let local = FoodSearchSources.local(text, index: index)
            let mine = FoodSearch.yours(text, meals: meals, myFoods: scanned, picked: picked, brand: local.brand,
                                        portions: FoodSearchSources.portions)
            return (local, mine)
        }.value
        guard !Task.isCancelled else { return }
        let yoursIDs = Set(mine.compactMap { $0.item.reference?.id })
        yours = mine
        brand = local.brand
        foods = FoodSearch.pickedFirst(local.foods.filter { !yoursIDs.contains($0.id) }, picked: picked)
        products = FoodSearch.pickedFirst(local.products.filter { !yoursIDs.contains($0.id) }, picked: picked)
        searchedOnce = true
        online = .loading
        #if DEBUG
        // `--food-search-pick`: the first food opened, to look at its amount.
        if ProcessInfo.processInfo.arguments.contains("--food-search-pick"), chosen == nil { chosen = foods.first }
        // `--food-search-add`: the first food added as shown, to look at the meal it makes.
        if ProcessInfo.processInfo.arguments.contains("--food-search-add"), let first = foods.first {
            pick(FoodSearch.item(first, amount: start(first), name: first.name), from: first)
            return
        }
        #endif

        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let found = try await FoodSearchSources.online(text, brand: local.brand, food: local.food)
            guard !Task.isCancelled else { return }
            PlaybackDiagnostics.shared.log("🔎 food search", "\u{201C}\(text)\u{201D}: \(local.foods.count) foods, "
                + "\(local.products.count) + \(found.count) products" + (local.brand.map { " of \($0.name)" } ?? "")
                + (found.isEmpty ? "" : " \u{2014} " + found.prefix(4).map(\.name).joined(separator: "; ")))
            var seen = Set(products.map { FoodSearch.key($0.name) })
            let fresh = found.filter { !yoursIDs.contains($0.id) && seen.insert(FoodSearch.key($0.name)).inserted }
            products = FoodSearch.pickedFirst(products + fresh, picked: picked)
            online = .done
        } catch {
            guard !Task.isCancelled else { return }
            PlaybackDiagnostics.shared.log("🔎 food search", "Open Food Facts failed: \(error.localizedDescription)")
            online = .failed
        }
    }
}

/// How much of a food found: a measure and a count of it, the numbers following live.
struct FoodAmountView: View {
    let result: FoodSearch.Result
    var onAdd: (MealItem) -> Void

    @State private var amount: FoodSearch.Amount
    @FocusState private var countFocused: Bool?

    init(result: FoodSearch.Result, startGrams: Double? = nil, onAdd: @escaping (MealItem) -> Void) {
        self.result = result
        self.onAdd = onAdd
        var start = result.start
        if let startGrams, FoodSearch.grams(start) != nil {
            start = FoodSearch.converted(FoodSearch.Amount(count: startGrams, unit: .grams), to: start.unit)
        }
        _amount = State(initialValue: start)
    }

    private var item: MealItem { FoodSearch.item(result, amount: amount, name: result.name) }

    private var units: [FoodSearch.Amount.Unit] {
        FoodSearch.units(portions: result.portions, weighable: FoodSearch.grams(result.start) != nil)
    }

    var body: some View {
        Form {
            Section {
                FoodAmountControl(amount: $amount, units: units, serving: result.item.serving,
                                  focus: $countFocused, field: true)
            } header: {
                Text("How much")
            } footer: {
                Text(item.serving)
            }
            Section {
                NutritionSummary(macros: item.macros)
                    .padding(.vertical, DS.Space.xs)
            }
        }
        .settingsFormStyle()
        .navigationTitle(result.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { onAdd(item) }
                    .disabled(amount.count <= 0)
                    .accessibilityIdentifier("foodAmount.add")
            }
        }
    }
}

/// How much of something: a count, stepped or typed, and the measure it's counted in — the food's own, grams or
/// ounces. One control wherever an amount is chosen: a food found by name, and every item of a
/// meal, so nothing is stuck in steps of whatever measure it was first guessed in.
struct FoodAmountControl<Focus: Hashable>: View {
    @Binding var amount: FoodSearch.Amount
    let units: [FoodSearch.Amount.Unit]
    /// One of what was logged, for something counted in servings ("1 can").
    var serving = ""
    let focus: FocusState<Focus?>.Binding
    let field: Focus
    /// Its name at the start of the row, where nothing above says what the number is.
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                if let title { Text(title) }
                TextField("Amount", value: $amount.count, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.leading)
                    .font(.body.monospacedDigit())
                    // Bordered, so the number reads as something to type into.
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #else
                    .labelsHidden()
                    #endif
                    .focused(focus, equals: field)
                    #if os(iOS)
                    // Tap the number and type the new one: it's selected, so typing replaces it.
                    // Left to the caret, "150" typed into "60" made "15060".
                    .onChange(of: focus.wrappedValue == field) { _, focused in
                        guard focused else { return }
                        // Once it is the first responder: select-all goes to whoever that is.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            guard focus.wrappedValue == field else { return }
                            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                        }
                    }
                    #endif
                    .accessibilityLabel("Amount")
                    .accessibilityIdentifier("foodAmount.count")
                // A serving's name is already said above it; here, only what the number counts.
                Text(amount.unit == .servings ? (amount.count == 1 ? "serving" : "servings") : FoodSearch.unitChip(amount.unit))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Stepper("Amount", onIncrement: { amount = FoodSearch.stepped(amount, by: 1) },
                        onDecrement: { amount = FoodSearch.stepped(amount, by: -1) })
                    .labelsHidden()
                    .accessibilityIdentifier("foodAmount.stepper")
            }
            if units.count > 1 { chips }
        }
    }

    /// Every measure a tap away, wrapping onto a second line rather than running off the edge:
    /// grams and ounces first, whatever the food, then its own.
    private var chips: some View {
        let weights = units.filter { $0 == .grams || $0 == .ounces }
        let own = units.filter { $0 != .grams && $0 != .ounces }
        return WorkoutFlowLayout(spacing: DS.Space.xs, lineSpacing: DS.Space.xs, fitsWidth: true) {
            ForEach(weights + own, id: \.self) { chip($0) }
        }
    }

    @ViewBuilder private func chip(_ unit: FoodSearch.Amount.Unit) -> some View {
        let selected = unit == amount.unit
        let button = Button { amount = FoodSearch.converted(amount, to: unit) } label: {
            Text(FoodSearch.unitChip(unit)).lineLimit(1)
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(FoodSearch.unitName(unit, serving: serving))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("foodAmount.unit")
        if selected { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }
}
#endif
