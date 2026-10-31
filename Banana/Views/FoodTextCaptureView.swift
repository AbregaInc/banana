#if os(iOS) || os(macOS)
import SwiftUI

/// Natural-language food entry review sheet, and — reusing the exact same row editor rather than
/// a second, divergent one — the editor for a meal already saved. `init(initialPhrase:)` starts
/// from a typed/dictated phrase and runs it through `FoodTextExtractor`; `init(editing:)` instead
/// seeds the rows straight from an already-saved `MealEntry`'s items. Everything below the
/// phrase/parse step — the whole-meal summary, the per-item rows, add/delete, the confidence
/// treatment — is identical between the two, because a saved meal and a meal under review are the
/// same thing. All extraction and macro-resolution logic lives in `FoodTextExtractor` — this view
/// only presents and edits its output.
struct FoodTextCaptureView: View {
    @EnvironmentObject private var wellness: WellnessStore
    @Environment(\.dismiss) private var dismiss

    /// The saved record to update rather than creating a second meal.
    private let editingMealID: UUID?
    /// Set when reviewing a backlog meal's estimate (`MealInboxStore`): Save keeps the edit on
    /// the proposal, for its day to be logged together.
    private let reviewingInboxID: UUID?
    /// The day a new meal is logged on — the one the Nutrition page was showing.
    private let day: Date?
    /// The meal's photos, for how much of a scanned package was on the plate.
    private let photoIDs: [UUID]

    @State private var showingRecentMeals = false
    @State private var phrase: String
    @State private var mealName: String
    @State private var eatenAt = Date()
    @State private var rows: [EditableFoodRow]
    @State private var thinking = false
    /// Which model the last parse actually used, so the spinner can say so rather than assert
    /// on-device processing that may not be happening.
    @State private var parseRoute: Intelligence.Route = .device
    @State private var confirmed: Bool
    @State private var hasParsed: Bool
    /// Which item rows are open for editing. A meal is a list to check, not a wall of fields:
    /// rows read as one scannable line each and open on tap. Rows the model only guessed at open
    /// themselves, so the ones that actually need a human land in front of you already unfolded.
    @State private var openRows: Set<UUID> = []
    /// The phrase `rows` were built from, so tapping Parse again on unchanged text can't silently
    /// throw away edits already made to them.
    @State private var parsedPhrase = ""
    /// The rows as first parsed, kept with the meal as its estimate (`MealEstimate`).
    @State private var parsedItems: [ResolvedFoodItem] = []
    /// What you usually have around this time (`UsualFoods`), offered as one-tap rows.
    @State private var usualNow: [UsualFoods.Food] = []
    /// Rows added from those, kept when the phrase is read.
    @State private var usualRowIDs: Set<UUID> = []
    /// Read the phrase as soon as the sheet opens — the Mac's inline "What did you eat?" field
    /// has already been typed into and submitted by then.
    private var parseOnOpen = false
    @FocusState private var focus: Field?
    /// A sheet for the whole meal (`target` nil) or for one item of it. The sheet is presented
    /// with this, not with a flag beside a separate target: a sheet built from a flag can be
    /// built before the target set a line earlier has landed, and "Scan its package" on the
    /// salad opened a scan for nothing in particular.
    private struct ItemRequest: Identifiable {
        let id = UUID()
        var target: UUID?
    }

    /// Correcting an item with the package it came from (`ScanCorrectionSheet`).
    @State private var scanRequest: ItemRequest?
    /// Rows a scanned food replaced, with the name each had — remembered on Save, so that name
    /// finds the food next time (`MyFoodsStore.note`). Not on Undo or Cancel.
    @State private var scanReplaced: [UUID: ScanReplacement] = [:]
    @State private var scanToast: String?
    /// The row a scan just changed, to scroll to.
    @State private var scannedRow: UUID?
    @ObservedObject private var myFoods = MyFoodsStore.shared
    /// Searching for a food by name (`FoodSearchView`): to add, or for the row it names.
    @State private var searchRequest: ItemRequest?
    /// A new meal started from a search rather than a phrase: no phrase to read, nothing to vouch for.
    private var startsWithSearch = false
    /// A new meal begun by scanning a package: the scanner opens at once.
    private var startsWithScan = false
    /// A new meal entered by hand: one blank row, open, its name field ready.
    private var startsByHand = false

    private struct ScanReplacement {
        var food: UUID
        var name: String
    }

    /// Every focusable field in the sheet. Row fields carry their row's id so the keyboard bar's
    /// Next walks down one item and into the following one, rather than dead-ending per row.
    private enum Field: Hashable {
        case phrase, mealName
        case name(UUID), serving(UUID), amount(UUID)
        case calories(UUID), protein(UUID), carbs(UUID), fat(UUID)
    }

    init(initialPhrase: String = "", parseOnOpen: Bool = false, day: Date? = nil) {
        editingMealID = nil
        reviewingInboxID = nil
        self.day = day
        photoIDs = []
        self.parseOnOpen = parseOnOpen && !initialPhrase.isEmpty
        // Pick up where a trip to another app left off.
        _phrase = State(initialValue: initialPhrase.isEmpty ? Drafts.foodPhrase : initialPhrase)
        _mealName = State(initialValue: "")
        _rows = State(initialValue: [])
        _confirmed = State(initialValue: false)
        _hasParsed = State(initialValue: false)
    }

    /// A new meal from foods searched for by name: the search opens at once, and each food
    /// picked is a row. Its numbers are the database's and its amount was chosen, so there's no
    /// "I reviewed this" to turn on.
    init(searchingOn day: Date?) {
        editingMealID = nil
        reviewingInboxID = nil
        self.day = day
        photoIDs = []
        startsWithSearch = true
        _phrase = State(initialValue: "")
        _mealName = State(initialValue: "")
        _rows = State(initialValue: [])
        _confirmed = State(initialValue: true)
        _hasParsed = State(initialValue: true)
        _searchRequest = State(initialValue: ItemRequest())
    }

    /// A new meal from a package scanned: the scanner opens at once and what it reads is the first
    /// row. The wide Nutrition page's way in, as the phone's Scan tile is.
    init(scanningOn day: Date?) {
        editingMealID = nil
        reviewingInboxID = nil
        self.day = day
        photoIDs = []
        startsWithSearch = true   // a meal built from picked foods: no phrase, nothing to confirm
        startsWithScan = true
        _phrase = State(initialValue: "")
        _mealName = State(initialValue: "")
        _rows = State(initialValue: [])
        _confirmed = State(initialValue: true)
        _hasParsed = State(initialValue: true)
        _scanRequest = State(initialValue: ItemRequest())
    }

    /// A new meal typed in by hand: no phrase to read and no package, one blank row to fill.
    /// The phone's "Enter by hand" opened an older sheet of its own for this.
    init(byHandOn day: Date?) {
        editingMealID = nil
        reviewingInboxID = nil
        self.day = day
        photoIDs = []
        startsWithSearch = true   // a meal built row by row: no phrase, nothing to confirm
        startsByHand = true
        _phrase = State(initialValue: "")
        _mealName = State(initialValue: "")
        _rows = State(initialValue: [])
        _confirmed = State(initialValue: true)
        _hasParsed = State(initialValue: true)
    }

    /// Editing an already-saved meal (owner request, "no way to edit a meal once its entered?").
    /// Skips straight to the row editor — there's nothing to (re-)parse — seeded from the saved
    /// items. Already reviewed once at the original save, and editing a row is itself the
    /// deliberate act, so there's no second "I reviewed this" gate to clear.
    init(editing meal: MealEntry) {
        editingMealID = meal.id
        _eatenAt = State(initialValue: meal.date)
        reviewingInboxID = nil
        day = nil
        photoIDs = meal.photoIDs
        // Unused in this mode — the phrase/parse section never shows, and save() for an edit
        // never touches the entry's `note` (its original-phrase archive stays exactly as saved).
        _phrase = State(initialValue: "")
        _mealName = State(initialValue: meal.name)
        let rows = meal.items.map(EditableFoodRow.init(saved:))
        _rows = State(initialValue: rows)
        // Same rule as a fresh parse: the rows nobody has vouched for are the ones worth opening.
        // A meal saved with an unconfirmed estimate in it is exactly what someone reopens to fix.
        _openRows = State(initialValue: Set(rows.filter { !$0.isConfident || $0.needsAmount }.map(\.id)))
        _confirmed = State(initialValue: true)
        _hasParsed = State(initialValue: true)
    }

    /// Reviewing what estimating made of a backlog meal. Same row editor; Save keeps the changes
    /// on the proposal until its day is logged. `opening`: the one food to open, asked for by
    /// its amount — only it, so the amount is right there.
    init(reviewing item: MealInboxItem, opening itemID: UUID? = nil) {
        editingMealID = nil
        reviewingInboxID = item.id
        day = nil
        photoIDs = item.photos.map(\.id)
        _phrase = State(initialValue: "")
        _mealName = State(initialValue: item.proposal?.name ?? "")
        let rows = (item.proposal?.items ?? []).map(EditableFoodRow.init(saved:))
        _rows = State(initialValue: rows)
        _openRows = State(initialValue: itemID.map { [$0] }
                          ?? Set(rows.filter { !$0.isConfident || $0.needsAmount }.map(\.id)))
        _confirmed = State(initialValue: true)
        _hasParsed = State(initialValue: true)
    }

    /// Editing something that already exists — a logged meal or a backlog estimate — rather than
    /// reading a new phrase.
    private var isEditingExisting: Bool { editingMealID != nil || reviewingInboxID != nil }

    /// A new meal from a typed or dictated phrase: the phrase to read, and its estimate to vouch for.
    private var readsPhrase: Bool { !isEditingExisting && !startsWithSearch }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if !isEditingExisting && !hasParsed {
                        Section { Button { showingRecentMeals = true } label: { Label("Recent meals", systemImage: "clock.arrow.circlepath") }
                            .accessibilityIdentifier("capture.recentMeals") }
                    }
                    if readsPhrase { phraseSection }
                    if hasParsed {
                        nameSection
                        if editingMealID != nil {
                            Section {
                                DatePicker("Ate at", selection: $eatenAt, in: ...Date(),
                                           displayedComponents: [.date, .hourAndMinute])
                                    .accessibilityIdentifier("foodText.eatenAt")
                            }
                        }
                        mealSummarySection
                        itemSections
                        if readsPhrase { confirmSection }
                    }
                }
                // A scan lands on its row, amount in view, wherever the list was scrolled to.
                .onChange(of: scannedRow) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                    scannedRow = nil
                }
            }
            .editingFormStyle()
            .navigationTitle(reviewingInboxID != nil ? "Check meal" : isEditingExisting ? "Edit meal"
                             : startsWithSearch ? "New meal" : "Describe what you ate")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640)
            #endif
            .task {
                if readsPhrase {
                    usualNow = UsualFoods.foods(at: logDate, meals: wellness.meals, myFoods: MyFoodsStore.shared.foods)
                }
                guard parseOnOpen, !hasParsed else { return }
                await parse()
            }
            // A sheet sits above the app's own toast; a scan's Undo has to show here.
            .toastHost()
            .onAppear { if startsByHand && rows.isEmpty { addBlankRow() } }
            .sheet(isPresented: $showingRecentMeals) {
                RecentMealsView(day: day ?? Date(), onLogged: { dismiss() }).environmentObject(wellness)
            }
            .sheet(item: $searchRequest, onDismiss: {
                // Searched for nothing to start a meal with: there's no meal.
                if startsWithSearch && rows.isEmpty { dismiss() }
            }) { request in
                let target = rows.first { $0.id == request.target }
                FoodSearchView(initialQuery: target?.name ?? "", replacingGrams: target?.grams,
                               onPick: { applySearch($0, replacing: request.target) },
                               onManual: target == nil ? { addBlankRow() } : nil)
                    .environmentObject(wellness)
            }
            .sheet(item: $scanRequest, onDismiss: {
                // Scanned nothing to start a meal with: there's no meal.
                if startsWithScan && rows.isEmpty { dismiss() }
            }) { request in
                ScanCorrectionSheet(items: rows.map { .init(id: $0.id, name: $0.name, grams: $0.grams) },
                                    photos: photoIDs.prefix(2).compactMap { MealPhotoStore.shared.image($0) },
                                    target: request.target,
                                    onApply: applyScan)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Drafts.foodPhrase = ""; closeScanToast(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
                #if os(iOS)
                // Every number here is a decimal pad, and a decimal pad has no return key — without
                // this bar the only way out of a calorie field is to guess at some inert pixel.
                ToolbarItemGroup(placement: .keyboard) {
                    Button { focus = previousField() } label: { Image(systemName: "chevron.up") }
                        .disabled(previousField() == nil)
                    Button { focus = nextField() } label: { Image(systemName: "chevron.down") }
                        .disabled(nextField() == nil)
                    Spacer()
                    Button("Done") { focus = nil }
                }
                #endif
            }
        }
    }

    private var phraseSection: some View {
        Section {
            TextField("What did you eat?", text: Binding(get: { phrase }, set: {
                phrase = $0
                if editingMealID == nil { Drafts.foodPhrase = $0 }
            }), axis: .vertical)
                .lineLimit(1...4)
                .submitLabel(.done)
                .focused($focus, equals: .phrase)
                .onSubmit { Task { await parse() } }
                .accessibilityIdentifier("foodText.phrase")
            Button {
                Task { await parse() }
            } label: {
                Label(hasParsed ? "Estimate again" : "Estimate", systemImage: "sparkles")
            }
            .disabled(!canParse)
            .accessibilityIdentifier("foodText.parse")
            if thinking {
                HStack { ProgressView(); Text(Intelligence.progressNote(for: parseRoute)) }
            }
            usualRow
        }
    }

    /// "Suggested": what you have around this time of day, and what you bought lately and haven't had yet, a tap each.
    @ViewBuilder private var usualRow: some View {
        let inMeal = Set(rows.map { MyFoods.key($0.name) })
        let offered = usualNow.filter { !inMeal.contains($0.key) }.prefix(8)
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Suggested").font(.caption).foregroundStyle(.secondary)
                // Wrapping, as a food's measures do: a name cut off at the edge reads as broken.
                WorkoutFlowLayout(spacing: DS.Space.s, lineSpacing: DS.Space.xs, fitsWidth: true) {
                    ForEach(Array(offered), id: \.key) { food in
                        Button { addUsual(food) } label: {
                            Label(food.name, systemImage: "plus")
                                .labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
                        }
                        .buttonStyle(.secondarySmall)
                        .accessibilityIdentifier("foodText.usual")
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// A usual food as a row, at your usual amount, its numbers the ones you logged last time.
    private func addUsual(_ food: UsualFoods.Food) {
        let item = food.item
        let row = ResolvedFoodItem(id: item.id, name: item.name, serving: item.serving, macros: item.macros,
                                   confidence: 1, source: .saved, grams: item.grams, reference: item.reference)
        rows.append(EditableFoodRow(row))
        parsedItems.append(row)
        usualRowIDs.insert(row.id)
        hasParsed = true
    }

    private var nameSection: some View {
        Section {
            // Labelled, so a filled name still says what it is.
            LabeledContent("Name") {
                TextField("Name", text: $mealName, prompt: Text("Optional"))
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .mealName)
                    .accessibilityIdentifier("foodText.mealName")
            }
        }
    }

    /// The "so what did I just eat" answer: whole-meal calories and macros, live off `rows` so it
    /// updates the instant a row is edited, deleted, or added. Reuses `NutritionView`'s own
    /// daily-total treatment (`WellnessView.swift`) rather than inventing a new one, so a meal's
    /// total and the day's total read as the same kind of number.
    private var mealSummarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                NutritionSummary(macros: mealTotals)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("foodText.total")
                if let saveBlockReason {
                    Label(saveBlockReason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, DS.Space.xs)
        }
    }

    /// One scannable line per item, opening on tap. This is the whole point of the redesign: a
    /// four-item meal used to be four sections of six always-expanded fields — twenty-four boxes
    /// to scroll past to check one number. Now the meal reads as four lines, and you open the one
    /// that's wrong.
    private var itemSections: some View {
        Section {
            ForEach($rows) { $row in
                itemRow($row)
            }
            .onDelete { offsets in
                for index in offsets { openRows.remove(rows[index].id) }
                rows.remove(atOffsets: offsets)
            }
            Button {
                focus = nil
                searchRequest = ItemRequest()
            } label: {
                Label("Add item", systemImage: "plus")
            }
            .accessibilityIdentifier("foodText.addItem")
        } header: {
            HStack {
                Text(rows.count == 1 ? "1 item" : "\(rows.count) items")
                Spacer()
                // Up here, beside the items: correcting one with its package is the usual reason
                // to open a photo's estimate, and the bottom of the list is under open rows.
                Button {
                    focus = nil
                    scanRequest = ItemRequest()
                } label: {
                    Label("Scan a package", systemImage: "barcode.viewfinder")
                }
                .buttonStyle(.inline)
                .textCase(nil)
                .accessibilityIdentifier("foodText.scan")
            }
        }
    }

    private var confirmSection: some View {
        Section {
            Toggle("I reviewed this", isOn: $confirmed)
                .accessibilityIdentifier("foodText.confirmed")
        }
    }

    private func itemRow(_ row: Binding<EditableFoodRow>) -> some View {
        let id = row.wrappedValue.id
        let isOpen = openRows.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOpen { openRows.remove(id) } else { openRows.insert(id) }
                }
            } label: {
                collapsedLine(row.wrappedValue, isOpen: isOpen)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Collapses this item" : "Opens this item for editing")

            if isOpen { editor(row).padding(.top, DS.Space.m) }
        }
        .padding(.vertical, DS.Space.hair)
    }

    /// Name, what it cost, and — at a glance — whether anyone has vouched for that number.
    private func collapsedLine(_ row: EditableFoodRow, isOpen: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            // Only an estimate is marked; a number someone vouched for needs no badge. The slot
            // stays, so every name starts in one column.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(DS.Palette.warning)
                .opacity(row.isConfident ? 0 : 1)
                .accessibilityHidden(row.isConfident)
                .accessibilityLabel(row.badgeText)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(row.name.isEmpty ? "New item" : row.name)
                    .foregroundStyle(row.name.isEmpty ? .secondary : .primary)
                if row.needsAmount {
                    Text("How much? Its package doesn\u{2019}t say").font(.caption).foregroundStyle(DS.Palette.warning)
                } else if PortionScaling.isImplausible(row.macros) {
                    Text("Check the portion \u{2014} over 2,000 kcal").font(.caption).foregroundStyle(DS.Palette.warning)
                } else {
                    Text(row.macroLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Space.s)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(row.macros.calories.rounded()))")
                    .font(.body.weight(.semibold)).monospacedDigit()
                Text("kcal").font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func editor(_ row: Binding<EditableFoodRow>) -> some View {
        let id = row.wrappedValue.id
        VStack(alignment: .leading, spacing: 10) {
            // Labelled, as every field of the sheet is: a filled one still says what it is.
            LabeledContent("Name") {
                TextField("Food", text: row.name)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .name(id))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("foodText.name")
            }
            if row.wrappedValue.isWeighed {
                // Any number of any of its measures, grams or ounces: "1 regular" cucumber, 150 g,
                // 1¼ servings of something scanned. The serving it comes to is written for you.
                amountControl(row)
                if row.wrappedValue.needsAmount {
                    Text("Its package doesn\u{2019}t say a serving. How many grams did you have?")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.accent)
                        .accessibilityIdentifier("foodText.needsAmount")
                } else {
                    Text(row.wrappedValue.serving)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("foodText.servingText")
                }
            } else {
                // No weight to go by: name the serving, then how many of it.
                LabeledContent("Serving") {
                    TextField("Serving", text: row.serving, prompt: Text("1 cup"))
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .serving(id))
                }
                amountControl(row)
            }
            if PortionScaling.isImplausible(row.wrappedValue.macros) {
                Label("Over 2,000 kcal for one item \u{2014} check the portion.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.warning)
            }
            Divider()
            nutritionField("Calories", value: row.macros.calories, suffix: "kcal", field: .calories(id))
            nutritionField("Protein", value: row.macros.proteinGrams, suffix: "g", field: .protein(id))
            nutritionField("Carbs", value: row.macros.carbohydrateGrams, suffix: "g", field: .carbs(id))
            nutritionField("Fat", value: row.macros.fatGrams, suffix: "g", field: .fat(id))
            rowActions(id, name: row.wrappedValue.name)
            .buttonStyle(.inline)
            .padding(.top, DS.Space.hair)
        }
        // One group per item, under its name: VoiceOver says whose amount this is, and a test
        // can reach the controls of one row among several open.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.wrappedValue.name)
        .accessibilityIdentifier("foodText.editor")
    }

    /// Scan its package, search for it by name, delete it — short enough for one line on a phone;
    /// VoiceOver hears them in full.
    private func rowActions(_ id: UUID, name: String) -> some View {
        HStack(spacing: DS.Space.l) {
            // This one item from its package: a meal of several, scanned for the one that came
            // in a box.
            Button {
                focus = nil
                scanRequest = ItemRequest(target: id)
            } label: {
                Label("Scan", systemImage: "barcode.viewfinder")
            }
            .accessibilityLabel("Scan its package")
            .accessibilityIdentifier("foodText.scanItem")
            .accessibilityValue(name)
            // Or by name: the right food in place of a guess, at the same weight.
            Button {
                focus = nil
                searchRequest = ItemRequest(target: id)
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .accessibilityLabel("Search for it")
            .accessibilityIdentifier("foodText.searchItem")
            Spacer(minLength: DS.Space.s)
            Button(role: .destructive) {
                openRows.remove(id)
                rows.removeAll { $0.id == id }
            } label: {
                Text("Delete item")
            }
            .accessibilityIdentifier("foodText.deleteItem")
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    /// How much of it: a count of one of its measures — the shared control (`FoodAmountControl`).
    private func amountControl(_ row: Binding<EditableFoodRow>) -> some View {
        FoodAmountControl(amount: Binding(get: { row.wrappedValue.amount },
                                          set: { row.wrappedValue.setAmount($0) }),
                          units: row.wrappedValue.units,
                          serving: row.wrappedValue.baseServing,
                          focus: $focus, field: .amount(row.wrappedValue.id), title: "Amount")
    }

    /// A food found by name, in place of the row searched from or as a new one.
    private func applySearch(_ item: MealItem, replacing target: UUID?) {
        let row = EditableFoodRow(saved: item)
        if let id = target, let index = rows.firstIndex(where: { $0.id == id }) {
            openRows.remove(id)
            rows[index] = row
        } else {
            rows.append(row)
        }
        hasParsed = true
        scannedRow = row.id
    }

    /// "Enter it by hand": a blank row, open, its name field ready.
    private func addBlankRow() {
        let fresh = EditableFoodRow()
        rows.append(fresh)
        openRows.insert(fresh.id)
        focus = .name(fresh.id)
    }

    /// A scanned food in place of the item it is (or as a new one), at once — with Undo.
    private func applyScan(_ result: ScanCorrectionResult) {
        let before = rows
        let beforeOpen = openRows
        let beforeReplaced = scanReplaced
        let row = EditableFoodRow(saved: result.item)
        let message: String
        if let id = result.replacing, let index = rows.firstIndex(where: { $0.id == id }) {
            let old = rows[index].name
            rows[index] = row
            // Scanned twice over: what it was first called is the name worth remembering.
            scanReplaced[row.id] = ScanReplacement(food: result.food.id, name: scanReplaced[row.id]?.name ?? old)
            message = "\(old) \u{2192} \(result.food.name)"
        } else {
            rows.append(row)
            message = "Added \(result.food.name)"
        }
        // Open, so the amount is right there to nudge — and asked for, when nothing says it.
        openRows.insert(row.id)
        if row.needsAmount { focus = .amount(row.id) }
        scannedRow = row.id
        scanToast = message
        Task {
            await ToastCenter.shared.offerUndo(message) { @MainActor in
                rows = before
                openRows = beforeOpen
                scanReplaced = beforeReplaced
                return nil
            }
        }
    }

    /// The scan's Undo can't reach this sheet once it's gone: close it with the sheet.
    private func closeScanToast() {
        guard let scanToast, ToastCenter.shared.toast?.message == scanToast else { return }
        ToastCenter.shared.dismiss()
    }

    private func nutritionField(_ title: String, value: Binding<Double>, suffix: String, field: Field) -> some View {
        HStack {
            Text(title)
            Spacer()
            // Calories whole, as everywhere else they're shown; grams to a tenth.
            TextField("0", value: value, format: .number.precision(.fractionLength(suffix == "kcal" ? 0...0 : 0...1)))
                #if os(iOS)
                .keyboardType(.decimalPad)
                #else
                // A Mac form puts a field's title beside it as a label: "0" next to the number.
                .labelsHidden()
                #endif
                .multilineTextAlignment(.trailing).frame(width: 90)
                .focused($focus, equals: field)
            Text(suffix).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
        }
    }

    /// Fields in tab order: the header fields, then every open row's six. A collapsed row has
    /// nothing on screen to focus, so it isn't in the walk.
    private var focusOrder: [Field] {
        var order: [Field] = isEditingExisting ? [.mealName] : [.phrase, .mealName]
        for row in rows where openRows.contains(row.id) {
            order.append(.name(row.id))
            if !row.isWeighed { order.append(.serving(row.id)) }
            order.append(.amount(row.id))
            order += [.calories(row.id), .protein(row.id), .carbs(row.id), .fat(row.id)]
        }
        return order
    }

    private func nextField() -> Field? {
        let order = focusOrder
        guard let focus, let index = order.firstIndex(of: focus), index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    private func previousField() -> Field? {
        let order = focusOrder
        guard let focus, let index = order.firstIndex(of: focus), index > 0 else { return nil }
        return order[index - 1]
    }

    /// Every item, resolved, as it would be saved right now — the shared basis for both the live
    /// total below and the actual save.
    private var liveItems: [MealItem] {
        rows.map { $0.resolved().asMealItem() }
    }

    private var mealTotals: NutritionMacros {
        liveItems.reduce(.init()) { $0 + $1.macros.sanitized }
    }

    private var trimmedPhrase: String { phrase.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var phraseChanged: Bool { trimmedPhrase != parsedPhrase.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canParse: Bool {
        !trimmedPhrase.isEmpty && !thinking && (!hasParsed || phraseChanged)
    }

    private var hasNamedRow: Bool {
        rows.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A food with no amount yet: its package doesn't say a serving, and nothing else did.
    private var rowNeedingAmount: EditableFoodRow? { rows.first(where: \.needsAmount) }

    private var canSave: Bool {
        hasParsed && confirmed && !thinking && hasNamedRow && rowNeedingAmount == nil
    }

    /// Why Save is greyed out. A disabled button with no reason beside it is the thing that makes
    /// a form feel broken rather than strict.
    private var saveBlockReason: String? {
        guard hasParsed, !thinking, !canSave else { return nil }
        if !hasNamedRow { return "Give at least one item a name to save." }
        if let row = rowNeedingAmount { return "Say how much \(row.name) you had to save." }
        if !confirmed { return "Check the numbers, then turn on “I reviewed this” to save." }
        return nil
    }

    @MainActor private func parse() async {
        thinking = true
        focus = nil
        parseRoute = Intelligence.route(.knowledge, given: Intelligence.current)
        let resolved = await FoodTextExtractor.extract(phrase, learned: wellness.learnedLookup(),
                                                       myFoods: MyFoodsStore.shared.foods)
        // Foods added from "Usually around now" stay; the phrase's own rows are read afresh.
        let kept = rows.filter { usualRowIDs.contains($0.id) }
        rows = kept + resolved.map(EditableFoodRow.init)
        parsedItems = parsedItems.filter { usualRowIDs.contains($0.id) } + resolved
        // Open exactly the rows that need a human. A catalog or learned match is a real number
        // and needs no attention; a model guess does.
        openRows = Set(resolved.filter { !$0.isConfident }.map(\.id))
        parsedPhrase = phrase
        hasParsed = true
        confirmed = false
        thinking = false
    }

    /// When a new meal happened: now on today; on another day, at the time of the meal the phrase
    /// names ("…for lunch"), else noon (`MealLogTime`).
    private var logDate: Date {
        guard let day else { return Date() }
        let pieces = MealTextSplitter.split(phrase)
        return MealLogTime.date(on: day, part: pieces.count == 1 ? pieces[0].part : nil)
    }

    private func save() {
        let validRows = rows.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validRows.isEmpty else { return }

        // Any row he edited away from a catalog match, AI estimate, or an already-saved value is
        // a correction candidate — WellnessStore only promotes it to a standing override after it
        // repeats. A manually typed row was never a proposal to correct, and a learned row is
        // already his own confirmed number, so neither counts (see `wasEditedFromProposal`).
        // A row from one of your foods isn't: its numbers are the label's, and the amount is the
        // only thing changed — kept as a fixed correction it would outrank the food itself.
        for row in validRows where row.wasEditedFromProposal && !row.isMyFood {
            wellness.recordEdit(name: row.name, macros: row.macros, serving: row.serving, grams: row.grams)
        }
        for row in validRows {
            if let replaced = scanReplaced[row.id] { myFoods.note(replaced.food, standsFor: replaced.name) }
        }

        let items = validRows.map { $0.resolved().asMealItem() }
        if let reviewingInboxID {
            MealInboxStore.shared.editProposal(reviewingInboxID, items: items.map(MealEntry.sanitizedItem),
                                               name: mealName.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let editingMealID {
            wellness.updateMeal(id: editingMealID, items: items, name: mealName, date: eatenAt)
        } else {
            let meal = startsWithSearch
                ? MealEntry(date: logDate, items: items, source: .manual, name: mealName)
                : MealEntry(date: logDate, items: items, note: phrase, source: .text, name: mealName,
                            estimate: FoodTextExtractor.estimate(parsedItems))
            wellness.addMeal(meal)
            MealLoggedToast.offer(meal, in: wellness)
            Drafts.foodPhrase = ""
        }
        closeScanToast()
        dismiss()
    }
}

/// One row in the review list: an original proposal (for the "did he actually change this?"
/// check at save time) plus the live, editable fields shown in the form.
private struct EditableFoodRow: Identifiable {
    let id: UUID
    private let original: ResolvedFoodItem
    var name: String
    var serving: String
    var macros: NutritionMacros
    var confidence: Double
    var source: ResolvedFoodItem.Source
    /// What a count of servings scales from: the item as it was proposed or saved.
    let baseMacros: NutritionMacros
    let baseServing: String
    /// The weight, for an item that has one — a database-backed item's numbers follow it.
    var grams: Double?
    let baseGrams: Double?
    let reference: FoodReference?
    /// Its food's own measures ("1 regular · 200 g", "1 cup"), when it's a food Banana knows.
    let portions: [FoodPortion]
    /// How much, counted in one of `units` — what the amount control shows.
    var amount: FoodSearch.Amount

    @MainActor init(_ resolved: ResolvedFoodItem) {
        id = resolved.id
        original = resolved
        name = resolved.name
        serving = resolved.serving
        macros = resolved.macros
        confidence = resolved.confidence
        source = resolved.source
        baseMacros = resolved.macros
        baseServing = resolved.serving
        grams = resolved.grams
        baseGrams = resolved.grams
        reference = resolved.reference
        portions = Self.portions(of: resolved.reference)
        amount = Self.amount(of: resolved.asMealItem(), portions: portions)
    }

    /// Something with a weight, or a food its numbers follow, is counted in any of its measures,
    /// grams or ounces; anything else in servings of what was logged.
    var isWeighed: Bool { reference != nil || (baseGrams ?? 0) > 0 }
    /// A food with no amount yet — scanned from a package that states no serving, with nothing
    /// else to go by. It is asked for, never guessed: it can't be saved at nothing.
    var needsAmount: Bool { reference != nil && (grams ?? 0) <= 0 }
    var units: [FoodSearch.Amount.Unit] { FoodSearch.units(portions: portions, weighable: isWeighed) }

    /// A new amount: the weight it comes to, or the servings — numbers and serving follow.
    mutating func setAmount(_ newAmount: FoodSearch.Amount) {
        let current = MealItem(name: name, serving: serving, macros: macros, grams: grams, reference: reference)
        let base = MealItem(name: name, serving: baseServing, macros: baseMacros, grams: baseGrams, reference: reference)
        let updated = FoodSearch.item(current, at: newAmount, base: base)
        amount = newAmount
        macros = updated.macros
        serving = updated.serving
        grams = updated.grams
    }

    /// A food's measures from the database, looked up once per food: rows are rebuilt whenever
    /// the sheet holding them is.
    private static var portionCache: [String: [FoodPortion]] = [:]

    /// One of yours, when that's where a row's numbers come from.
    @MainActor private static func myFood(_ reference: FoodReference?) -> MyFood? {
        guard let id = reference?.id, id.hasPrefix(MyFoods.referencePrefix),
              let uuid = UUID(uuidString: String(id.dropFirst(MyFoods.referencePrefix.count))) else { return nil }
        return MyFoodsStore.shared.food(uuid)
    }

    /// Where a row's amount starts: one of yours in servings of it when that's a round number of
    /// them, anything else in the measure its serving names — else grams.
    @MainActor private static func amount(of item: MealItem, portions: [FoodPortion]) -> FoodSearch.Amount {
        if let food = myFood(item.reference), let grams = item.grams, grams > 0 {
            return ScanCorrection.amount(grams: grams, of: food)
        }
        return FoodSearch.amount(of: item, portions: portions)
    }

    @MainActor private static func portions(of reference: FoodReference?) -> [FoodPortion] {
        // One of yours: its serving and its package, as they are now.
        if let food = myFood(reference) { return MyFoods.measures(food) }
        guard let id = reference?.id, !id.hasPrefix(MyFoods.referencePrefix) else { return [] }
        if let known = portionCache[id] { return known }
        let found = FoodDatabase.food(id: id)?.portions ?? []
        portionCache[id] = found
        return found
    }

    /// A new weight: a database-backed item's numbers are recomputed from its food; any other
    /// item's scale with the weight.
    mutating func setGrams(_ newGrams: Double) {
        let current = MealItem(name: name, serving: serving, macros: macros, grams: grams, reference: reference)
        let updated = current.withGrams(newGrams)
        macros = updated.macros
        grams = updated.grams
    }

    /// A manually added row with no model proposal behind it — the empty "Add item" state.
    @MainActor init() {
        self.init(.init(name: "", serving: "1 serving", macros: .init(), confidence: 0, source: .manual))
    }

    /// Seeds a row from an already-saved item, when editing an existing meal rather than
    /// reviewing a freshly parsed one. There's no model proposal to compare against, so `original`
    /// is the saved value itself — editing it away from what was already logged is exactly the
    /// correction signal `wasEditedFromProposal` exists to catch. A saved item's confidence is
    /// `nil` for anything that never went through `FoodTextExtractor` (barcode/photo/manual
    /// entries) — that's a value the person entered or a lookup returned directly, not a model
    /// guess, so it's treated as fully confident here.
    @MainActor init(saved item: MealItem) {
        id = item.id
        name = item.name
        serving = item.serving
        macros = item.macros
        let savedConfidence = item.confidence ?? 1.0
        confidence = savedConfidence
        source = savedConfidence >= 0.9 ? .saved : item.reference != nil ? .database : .aiEstimate
        baseMacros = item.macros
        baseServing = item.serving
        grams = item.grams
        baseGrams = item.grams
        reference = item.reference
        portions = Self.portions(of: item.reference)
        amount = Self.amount(of: item, portions: portions)
        original = .init(id: id, name: name, serving: serving, macros: macros, confidence: savedConfidence, source: source,
                         grams: item.grams, reference: item.reference)
    }

    var isConfident: Bool { confidence >= 0.9 }
    var badgeText: String { resolved().badgeText }
    var isMyFood: Bool { reference?.id.hasPrefix(MyFoods.referencePrefix) == true }

    /// The collapsed line's second row: serving plus the three macros, short enough to read at a
    /// glance and complete enough that most rows never need opening.
    var macroLine: String {
        let serving = serving.trimmingCharacters(in: .whitespacesAndNewlines)
        let macros = NutritionText.macroLine(macros)
        return serving.isEmpty ? macros : "\(serving) \u{00B7} \(macros)"
    }

    /// Catalog, AI-estimate, and already-saved proposals are corrections in the sense §5 means —
    /// a manually typed row was never a proposal to correct, and a learned row is already his own
    /// confirmed number. `.saved` is included deliberately: changing a number already logged
    /// (editing an existing meal) is itself the correction signal, whatever produced that number
    /// originally.
    var wasEditedFromProposal: Bool {
        guard source == .catalog || source == .aiEstimate || source == .saved || source == .database else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedServing = serving.trimmingCharacters(in: .whitespacesAndNewlines)
        return macros.sanitized != original.macros.sanitized
            || trimmedName != original.name || trimmedServing != original.serving
    }

    func resolved() -> ResolvedFoodItem {
        .init(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
              serving: serving.trimmingCharacters(in: .whitespacesAndNewlines),
              macros: macros, confidence: confidence, source: source, grams: grams, reference: reference)
    }
}
#endif
