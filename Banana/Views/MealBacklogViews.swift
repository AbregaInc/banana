#if os(iOS) || os(macOS)
import ImageIO
import PhotosUI
import SwiftUI

// The meal backlog on screen: what's waiting ("To log"), adding photos and words for any day,
// and reviewing a day's estimates before they're logged. Shared by the iPhone's Nutrition list
// and the iPad/Mac Nutrition page. See docs/design/MEAL-BACKLOG.md.

/// A day to open a sheet for.
struct MealDayRequest: Identifiable {
    let day: Date
    var id: Date { day }
}

/// "Today 12:40", "Yesterday 19:05", "Mon, Sep 28 · 08:10".
enum MealInboxText {
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) \u{00B7} \(time)"
    }

    static func meals(_ count: Int) -> String { count == 1 ? "1 meal" : "\(count) meals" }
}

// MARK: - Photos

/// One meal photo, or a placeholder while it's still on its way from another device.
struct MealPhotoThumb: View {
    let id: UUID
    var size: CGFloat = 56
    @ObservedObject private var photos = MealPhotoStore.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        Group {
            if let image = photos.thumbnail(id) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.primary.opacity(DS.Tint.subtle))
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// A meal's photos, a few of them, with how many more there are. Each opens full size, the
/// rest a swipe away (`MealPhotoViewer`).
struct MealPhotoStrip: View {
    let ids: [UUID]
    var size: CGFloat = 56
    var limit = 3

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(ids.prefix(limit).enumerated()), id: \.element) { offset, id in
                MealPhotoThumb(id: id, size: size).opensMealPhotos(ids, at: offset)
            }
            if ids.count > limit {
                Text("+\(ids.count - limit)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .opensMealPhotos(ids, at: limit)
            }
        }
    }
}

// MARK: - One waiting meal

/// A backlog meal that isn't estimated yet: asks what it was, shows it being estimated, or says
/// why it couldn't be.
struct MealInboxRow: View {
    let item: MealInboxItem
    var onEnterByHand: (MealInboxItem) -> Void

    @ObservedObject private var inbox = MealInboxStore.shared
    @ObservedObject private var processor = MealBacklogProcessor.shared
    @State private var note = ""

    /// One row like any list's: the photo, when it was eaten, what it needs, and everything else
    /// it can do in its menu — also on a right-click on the Mac and, in a list, a swipe.
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            if item.hasPhotos {
                MealPhotoStrip(ids: item.photos.map(\.id), size: 56, limit: 1)
            } else {
                Image(systemName: "text.bubble")
                    .font(.title3)
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 56, height: 56)
                    .background(DS.Palette.accent.opacity(DS.Tint.subtle),
                                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(MealInboxText.when(item.eatenAt)).font(.subheadline.weight(.semibold))
                    if item.photos.count > 1 {
                        Text("\(item.photos.count) photos").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if item.state != .proposed {
                        Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .buttonStyle(.borderless)
                            .fixedSize()
                            .accessibilityLabel("More")
                            .accessibilityIdentifier("mealInbox.more")
                    }
                }
                state
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DS.Space.xs)
        #if os(macOS)
        // A right-click; on a phone the … is the menu (a long-press one on the row stopped its
        // items from doing anything).
        .contextMenu { if item.state != .proposed { actions } }
        #endif
        .swipeActions(edge: .trailing) {
            if item.state != .proposed {
                Button("Not a meal", systemImage: "trash", role: .destructive) { DeleteUndo.notAMeal(item.id, in: inbox) }
            }
        }
    }

    /// What else a waiting meal can do, by its state.
    @ViewBuilder private var actions: some View {
        switch item.state {
        case .awaitingNote:
            Button("Use photo only", systemImage: "photo") { inbox.usePhotoOnly(item.id) }
                .accessibilityIdentifier("mealInbox.photoOnly")
            Button("Enter by hand", systemImage: "square.and.pencil") { onEnterByHand(item) }
        case .ready:
            Button("Enter by hand", systemImage: "square.and.pencil") { onEnterByHand(item) }
                .accessibilityIdentifier("mealInbox.waiting.byHand")
        case .failed:
            Button("Try again", systemImage: "arrow.clockwise") { inbox.retry(item.id) }
            Button("Enter by hand", systemImage: "square.and.pencil") { onEnterByHand(item) }
        case .proposed:
            EmptyView()
        }
        Divider()
        Button("Not a meal", systemImage: "trash", role: .destructive) { DeleteUndo.notAMeal(item.id, in: inbox) }
    }

    @ViewBuilder private var state: some View {
        switch item.state {
        case .awaitingNote: asking
        case .ready: estimating
        case .proposed: proposed
        case .failed: failed
        }
    }

    private var trimmed: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The question, answered in place: a field like any list's, sent with Return or Add.
    private var asking: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            TextField("What was this?", text: $note, axis: .vertical)
                .lineLimit(1...3)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #else
                .textFieldStyle(.plain)
                #endif
                .submitLabel(.done)
                .onSubmit(submit)
                .accessibilityIdentifier("mealInbox.note")
            if !trimmed.isEmpty {
                Button("Add", action: submit)
                    .buttonStyle(.primarySmall)
                    .accessibilityIdentifier("mealInbox.add")
            }
        }
        .task(id: item.id) {
            // A photo like a meal logged before comes with its words, ready to Add.
            guard item.hasPhotos, let words = await processor.suggestedWords(for: item), trimmed.isEmpty else { return }
            note = words
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        inbox.answer(item.id, note: trimmed)
        note = ""
    }

    @ViewBuilder private var estimating: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if MealBacklogRouting.waitsElsewhere(item, here: processor.here, working: processor.working.contains(item.id)) {
                Label("Waiting to estimate", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                // Words can be added or changed while it waits.
                MealWordsButton(item: item)
            } else {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Estimating\u{2026}").foregroundStyle(.secondary)
                }
                if !item.trimmedNote.isEmpty { MealWordsButton(item: item) }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var proposed: some View {
        if let proposal = item.proposal {
            Text("\(proposal.name) \u{00B7} \(NutritionText.kcal(proposal.totals))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// What went wrong, and the one thing most worth doing about it; the rest is in the menu.
    private var failed: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // Mostly passing (the model was busy, no network): a warning, not an error.
            Label(item.failure ?? "Couldn\u{2019}t estimate it.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(DS.Palette.warning)
            if item.hasPhotos || !item.trimmedNote.isEmpty { MealWordsButton(item: item) }
            Button("Try again") { inbox.retry(item.id) }
                .buttonStyle(.inline)
        }
    }
}

// MARK: - The backlog

/// Everything waiting: days with estimates to check, then meals still needing words or being
/// estimated. Empty when there's nothing — the page hides it then.
struct MealBacklogPanel: View {
    var onReviewDay: (Date) -> Void
    var onEnterByHand: (MealInboxItem) -> Void
    @ObservedObject private var inbox = MealInboxStore.shared

    /// In a `List` each is its own row, with its separator and swipe; elsewhere they're stacked.
    var inList = false

    var body: some View {
        if inList {
            rows
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                rows
            }
        }
    }

    @ViewBuilder private var rows: some View {
        let proposed = inbox.items.filter { $0.state == .proposed }
        let open = inbox.items.filter { $0.state != .proposed }.sorted { $0.eatenAt > $1.eatenAt }
        ForEach(MealBacklogDays.days(proposed), id: \.self) { day in
            reviewRow(day, MealBacklogDays.items(proposed, on: day))
        }
        ForEach(open) { item in
            MealInboxRow(item: item, onEnterByHand: onEnterByHand)
        }
    }

    private func reviewRow(_ day: Date, _ items: [MealInboxItem]) -> some View {
        let total = items.compactMap(\.proposal).reduce(NutritionMacros()) { $0 + $1.totals }
        return Button { onReviewDay(day) } label: {
            HStack(spacing: DS.Space.m) {
                MealPhotoStrip(ids: items.flatMap { $0.photos.map(\.id) }, size: 40, limit: 3)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(NutritionDays.title(for: day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(MealInboxText.meals(items.count)) to check \u{00B7} about \(NutritionText.kcal(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mealInbox.reviewDay")
    }
}

// MARK: - Reviewing a day

/// A day's estimated meals, checked and logged together. Each keeps its own time; its items open
/// in the same editor a typed meal uses.
struct MealDayReviewView: View {
    let day: Date
    @EnvironmentObject private var wellness: WellnessStore
    @ObservedObject private var inbox = MealInboxStore.shared
    @Environment(\.dismiss) private var dismiss
    /// A meal opened to be checked, and the food to open in it when it was opened for one
    /// ("Other…" on its portion question). One value, for the reason `ScanRequest` is one.
    private struct CheckRequest: Identifiable {
        let id = UUID()
        var item: MealInboxItem
        var food: UUID?
    }

    @State private var checking: CheckRequest?
    /// A meal being corrected with the package it came from (`ScanCorrectionSheet`): the whole
    /// meal (`target` nil) or one item of it ("Scan its package"). One value, not a meal and a
    /// target beside it: a sheet can be built before a target set a line earlier has landed.
    private struct ScanRequest: Identifiable {
        let id = UUID()
        var item: MealInboxItem
        var target: UUID?
    }

    @State private var scanRequest: ScanRequest?
    /// Derived from the current proposals, including meals arriving after the review opens.
    /// Keeping a second state copy can leave a newly arrived meal without its question.
    private var questions: [PortionQuestion.Question] {
        PortionQuestion.questions(proposed, portions: { FoodDatabase.food(id: $0)?.portions ?? [] })
    }

    private var items: [MealInboxItem] { MealBacklogDays.items(inbox.items, on: day) }
    private var proposed: [MealInboxItem] { items.filter { $0.state == .proposed } }

    var body: some View {
        NavigationStack {
            let questions = self.questions
            List {
                summary
                ForEach(proposed) { item in
                    Section { card(item, questions: questions) }
                }
                let rest = items.filter { $0.state != .proposed }
                if !rest.isEmpty {
                    Section("Still to do") {
                        ForEach(rest) { MealInboxRow(item: $0, onEnterByHand: { checking = CheckRequest(item: $0) }) }
                    }
                }
            }
            .navigationTitle(NutritionDays.title(for: day))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 680)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(proposed.count > 1 ? "Log \(proposed.count)" : "Log") {
                        inbox.log(proposed.map(\.id), into: wellness)
                        if items.isEmpty { dismiss() }
                    }
                    .disabled(proposed.isEmpty)
                    .accessibilityIdentifier("mealReview.logAll")
                }
            }
            .sheet(item: $checking) { request in
                FoodTextCaptureView(reviewing: request.item, opening: request.food).environmentObject(wellness)
            }
            .sheet(item: $scanRequest) { request in
                let item = request.item
                ScanCorrectionSheet(items: (item.proposal?.items ?? []).map { .init(id: $0.id, name: $0.name, grams: $0.grams) },
                                    photos: item.photos.prefix(2).compactMap { MealPhotoStore.shared.image($0.id) },
                                    target: request.target,
                                    onApply: { applyScan($0, to: item.id) })
            }
            .onChange(of: items.isEmpty) { _, empty in if empty { dismiss() } }
            // A sheet sits above the app's own toast; a scan's Undo has to show here.
            .toastHost()
        }
    }

    /// A scanned food in the estimate, at once — with Undo.
    private func applyScan(_ result: ScanCorrectionResult, to id: UUID) {
        guard let proposal = inbox.item(id)?.proposal else { return }
        let before = proposal.items
        let foods = MyFoodsStore.shared
        let foodBefore = foods.food(result.food.id)
        var items = proposal.items
        let message: String
        if let replacing = result.replacing, let index = items.firstIndex(where: { $0.id == replacing }) {
            let old = items[index].name
            items[index] = result.item
            foods.note(result.food.id, standsFor: old)
            message = "\(old) \u{2192} \(result.food.name)"
        } else {
            items.append(result.item)
            message = "Added \(result.food.name)"
        }
        inbox.editProposal(id, items: items.map(MealEntry.sanitizedItem), name: proposal.name)
        // Its package doesn't say a serving and nothing else says how much: asked, in the editor.
        if (result.item.grams ?? 0) <= 0 {
            checking = inbox.item(id).map { CheckRequest(item: $0, food: result.item.id) }
        }
        Task {
            await ToastCenter.shared.offerUndo(message) { @MainActor in
                inbox.editProposal(id, items: before, name: proposal.name)
                if let foodBefore { foods.restore(foodBefore) }
                return nil
            }
        }
    }

    private var summary: some View {
        let logged = NutritionDays.total(NutritionDays.meals(wellness.meals, on: day))
        let adding = proposed.compactMap(\.proposal).reduce(NutritionMacros()) { $0 + $1.totals }
        return Section {
            StatValue(label: "With these", value: (logged.calories + adding.calories).rounded()
                        .formatted(.number.precision(.fractionLength(0))), unit: "kcal",
                      footnote: logged.calories > 0 ? "\(NutritionText.kcal(logged)) already logged" : nil, size: .hero)
        }
    }

    /// One food of a meal, with what can be done to it alone: scan the package it came in, or take
    /// it out. A tap opens them on the phone; on the Mac they're on the row's right-click.
    @ViewBuilder private func foodActions(_ food: MealItem, in item: MealInboxItem) -> some View {
        #if os(iOS)
        Menu {
            foodMenu(food, in: item)
        } label: {
            foodRow(food).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mealReview.food")
        #else
        foodRow(food)
            .contentShape(Rectangle())
            .contextMenu { foodMenu(food, in: item) }
            .accessibilityIdentifier("mealReview.food")
        #endif
    }

    @ViewBuilder private func foodMenu(_ food: MealItem, in item: MealInboxItem) -> some View {
        Button("Scan its package", systemImage: "barcode.viewfinder") {
            scanRequest = ScanRequest(item: item, target: food.id)
        }
        // The only food in it: that's "Not a meal", in the card's menu.
        if (item.proposal?.items.count ?? 0) > 1 {
            Button("Take it out", systemImage: "minus.circle", role: .destructive) { remove(food, from: item.id) }
        }
    }

    /// A food that wasn't there, out of the estimate at once — with Undo.
    private func remove(_ food: MealItem, from id: UUID) {
        guard let proposal = inbox.item(id)?.proposal else { return }
        let before = proposal.items
        inbox.editProposal(id, items: before.filter { $0.id != food.id }, name: proposal.name)
        Task {
            await ToastCenter.shared.offerUndo("Took out \(food.name)") { @MainActor in
                inbox.editProposal(id, items: before, name: proposal.name)
                return nil
            }
        }
    }

    private func foodRow(_ food: MealItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            // The model's own figures, with no USDA food behind them: worth a look. The slot is
            // there either way, so every name starts in one column.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(DS.Palette.warning)
                .opacity(food.reference == nil && (food.confidence ?? 1) < 0.9 ? 1 : 0)
                .accessibilityHidden(!(food.reference == nil && (food.confidence ?? 1) < 0.9))
                .accessibilityLabel("Estimate")
                .frame(width: 14)
            Text(food.name).lineLimit(1)
            Text(food.serving).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: DS.Space.s)
            Text(NutritionText.kcal(food.macros)).monospacedDigit()
        }
        .font(.callout)
    }

    /// How much of a food there was, asked once: an answer is the best thing to learn from.
    private func portionQuestion(_ question: PortionQuestion.Question) -> some View {
        // Wraps: "1½ miniature" and Other… don't fit one line of a phone's card.
        WorkoutFlowLayout(spacing: DS.Space.s, lineSpacing: DS.Space.xs) {
            Text("How much?").font(.caption).foregroundStyle(.secondary)
            ForEach(question.choices, id: \.self) { choice in
                Button(choice.label) {
                    inbox.answerPortion(question.mealID, itemID: question.itemID, grams: choice.grams,
                                        serving: choice.label)
                }
                .buttonStyle(.secondarySmall)
                .accessibilityIdentifier("mealReview.portion")
            }
            // None of those: any amount, in any of its measures or grams, in the editor.
            Button("Other\u{2026}") {
                checking = inbox.items.first { $0.id == question.mealID }
                    .map { CheckRequest(item: $0, food: question.itemID) }
            }
            .buttonStyle(.inline)
            .accessibilityLabel("Another amount")
            .accessibilityIdentifier("mealReview.portionOther")
        }
    }

    @ViewBuilder private func card(_ item: MealInboxItem, questions: [PortionQuestion.Question]) -> some View {
        if let proposal = item.proposal {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    if item.hasPhotos { MealPhotoStrip(ids: item.photos.map(\.id), size: 64, limit: 2) }
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text(proposal.name).font(.headline)
                        Text("\(NutritionText.kcal(proposal.totals)) \u{00B7} \(NutritionText.macroLine(proposal.totals))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        // What the photos' depth measured, which the estimate was told.
                        if let measured = MealPhotoDepth.caption(item.photos.compactMap(\.depth)) {
                            Text(measured).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .accessibilityIdentifier("mealReview.measured")
                        }
                        // What you said it was — tap to change it and estimate again.
                        if !item.trimmedNote.isEmpty || item.hasPhotos { MealWordsButton(item: item) }
                    }
                }
                ForEach(proposal.items) { food in
                    foodActions(food, in: item)
                    if let question = questions.first(where: { $0.itemID == food.id }) {
                        portionQuestion(question)
                    }
                }
                ForEach(proposal.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.warning)
                }
                // A meal from before, by its photo: one tap estimates it fresh.
                if proposal.repeatOf != nil {
                    Button("Not the same") { inbox.notTheSame(item.id) }
                        .buttonStyle(.inline)
                        .accessibilityIdentifier("mealReview.notSame")
                }
                HStack {
                    // The day is the sheet's: only the time is the meal's own.
                    TimeField("Time", selection: Binding(get: { item.eatenAt }, set: { inbox.setEatenAt(item.id, $0) }))
                        .labelsHidden()
                    Spacer()
                    Button("Edit") { checking = CheckRequest(item: item) }
                        .buttonStyle(.inline)
                        .accessibilityIdentifier("mealReview.edit")
                    Menu {
                        Button("Scan a package", systemImage: "barcode.viewfinder") { scanRequest = ScanRequest(item: item) }
                            .accessibilityIdentifier("mealReview.scan")
                        Button("Estimate again") { inbox.retry(item.id) }
                        Button("Not a meal", role: .destructive) { DeleteUndo.notAMeal(item.id, in: inbox) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
            .padding(.vertical, DS.Space.xs)
        }
    }
}

// MARK: - Adding photos and words

/// Photos and words for a day, all at once. Photos go on the day and time they were taken, close
/// ones together as one meal; each asks what it was (left blank, it waits in To log). Words are
/// split into the meals they name.
struct MealDumpView: View {
    let day: Date
    /// Images dropped on the page (Mac, iPad), to start from.
    var initialImages: [Data] = []

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var picked: [PhotosPickerItem: UUID] = [:]
    @State private var photos: [Picked] = []
    @State private var notes: [UUID: String] = [:]
    @State private var photoOnly: Set<UUID> = []
    @State private var words = ""
    /// Meals (keyed by their first photo) already looked up against the meals logged before.
    @State private var lookedUp: Set<UUID> = []
    @State private var reading = 0
    #if os(iOS)
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    #endif

    struct Picked: Identifiable {
        let id: UUID
        let jpeg: Data
        let takenAt: Date?
        let thumbnail: CGImage?
        /// What its depth measured (`MealPhotoDepth`), for the meal's photo.
        var depth: PhotoDepth?
        /// It carried a depth map, measurable or not.
        var carriesDepth = false
    }

    private var groups: [[Picked]] { MealPhotoGrouping.group(photos, takenAt: \.takenAt) }
    private var pieces: [MealTextSplitter.Piece] { MealTextSplitter.split(words) }
    private var dayWords: String {
        Calendar.current.isDateInToday(day) ? "today" : "on \(NutritionDays.title(for: day))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The photo as it is (a HEIC stays one), so a Portrait photo keeps its depth.
                    PhotosPicker(selection: $pickerItems, matching: .images, preferredItemEncoding: .current,
                                 photoLibrary: .shared()) {
                        Label(photos.isEmpty ? "Choose photos" : "Choose more photos", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("mealDump.pick")
                    #if os(iOS)
                    Button { showCamera = true } label: { Label("Take a photo", systemImage: "camera") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    #endif
                    if reading > 0 {
                        HStack(spacing: DS.Space.s) { ProgressView(); Text("Reading \(reading) photo\(reading == 1 ? "" : "s")\u{2026}") }
                    }
                }

                ForEach(groups, id: \.first?.id) { group in
                    if let key = group.first?.id { groupSection(group, key: key) }
                }

                Section {
                    TextField("Anything else you ate \(dayWords)? \u{201C}Oatmeal for breakfast, chicken caesar at lunch\u{201D}",
                              text: $words, axis: .vertical)
                        .lineLimit(2...8)
                        .accessibilityIdentifier("mealDump.words")
                } header: {
                    Text("Words")
                } footer: {
                    if !pieces.isEmpty {
                        Text(pieces.map { "\($0.part?.title ?? "Meal"): \($0.text)" }.joined(separator: "\n"))
                    }
                }
            }
            .editingFormStyle()
            .navigationTitle("Add photos & notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled((photos.isEmpty && pieces.isEmpty) || reading > 0)
                        .accessibilityIdentifier("mealDump.add")
                }
            }
            .onChange(of: pickerItems) { _, items in Task { await load(items) } }
            .task(id: groups.map { $0.map(\.id) }) { await suggest() }
            .task { await loadDropped() }
            #if os(iOS)
            .sheet(isPresented: $showCamera) {
                // Banana's own camera keeps the depth in the photo, so the plate can be measured;
                // the system's can't, and is there for phones without a depth camera.
                if MealDepthCamera.isAvailable {
                    MealDepthCameraView { data, source in addCameraPhoto(data, depthSource: source) }
                } else {
                    CameraPicker(image: $cameraImage).ignoresSafeArea()
                }
            }
            .onChange(of: cameraImage) { _, image in
                guard let image, let data = image.jpegData(compressionQuality: 0.9) else { return }
                cameraImage = nil
                addCameraPhoto(data)
            }
            #endif
        }
    }

    private func groupSection(_ group: [Picked], key: UUID) -> some View {
        let note = Binding(get: { notes[key] ?? "" }, set: { notes[key] = $0 })
        let empty = (notes[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(group) { photo in
                        if let thumbnail = photo.thumbnail {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        }
                    }
                }
            }
            TextField("What was this?", text: note, axis: .vertical)
                .lineLimit(1...3)
            if empty {
                Toggle("Estimate from the photo alone", isOn: Binding(
                    get: { photoOnly.contains(key) },
                    set: { if $0 { photoOnly.insert(key) } else { photoOnly.remove(key) } }))
            }
        } header: {
            Text(group.first?.takenAt.map { MealInboxText.when($0) } ?? "No time on the photo \u{2014} goes \(dayWords)")
        }
    }

    /// Fills in each meal's words from the logged meal its photos look like, once per meal.
    private func suggest() async {
        for group in groups {
            guard let key = group.first?.id, lookedUp.insert(key).inserted else { continue }
            if let words = await MealBacklogProcessor.shared.suggestedWords(forPhotos: group.map(\.jpeg)),
               (notes[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes[key] = words
            }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        // Deselected in the picker: gone here too.
        let kept = Set(items)
        for (item, id) in picked where !kept.contains(item) {
            photos.removeAll { $0.id == id }
            picked[item] = nil
        }
        let fresh = items.filter { picked[$0] == nil }
        reading += fresh.count
        for item in fresh {
            defer { reading -= 1 }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  var photo = await Self.prepare(data) else { continue }
            // An edited Portrait photo may have left its depth behind; the library's original has it.
            if !photo.carriesDepth, let id = item.itemIdentifier {
                photo.depth = await MealPhotoLibraryReader.originalDepth(localIdentifier: id)
            }
            picked[item] = photo.id
            photos.append(photo)
        }
    }

    #if os(iOS)
    /// A photo just taken. It may carry no date of its own here: it was taken just now.
    private func addCameraPhoto(_ data: Data, depthSource: PhotoDepth.Source = .portrait) {
        Task {
            reading += 1
            defer { reading -= 1 }
            if let photo = await Self.prepare(data, takenAt: Date(), depthSource: depthSource) { photos.append(photo) }
        }
    }
    #endif

    private func loadDropped() async {
        var images = initialImages
        #if DEBUG
        if images.isEmpty, ProcessInfo.processInfo.arguments.contains("--meal-dump") { images = Self.previewImages() }
        #endif
        guard photos.isEmpty, !images.isEmpty else { return }
        reading = images.count
        for data in images {
            defer { reading -= 1 }
            if let photo = await Self.prepare(data) { photos.append(photo) }
        }
    }

    /// The small copy kept, its time, what its depth measured, and a thumbnail — off the main thread.
    private static func prepare(_ data: Data, takenAt fallback: Date? = nil,
                                depthSource: PhotoDepth.Source = .portrait) async -> Picked? {
        await Task.detached(priority: .userInitiated) {
            guard let prepared = MealPhotoImage.prepare(data, depthSource: depthSource) else { return nil }
            return Picked(id: UUID(), jpeg: prepared.jpeg, takenAt: prepared.takenAt ?? fallback,
                          thumbnail: MealPhotoImage.downscaled(prepared.jpeg, maxPixels: 240),
                          depth: prepared.depth, carriesDepth: prepared.carriesDepth)
        }.value
    }

    private func add() {
        var new: [MealInboxItem] = []
        for group in groups {
            guard let key = group.first?.id else { continue }
            for photo in group { MealPhotoStore.shared.save(photo.jpeg, id: photo.id) }
            let note = (notes[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let eatenAt = group.compactMap(\.takenAt).min() ?? MealLogTime.date(on: day, part: nil)
            new.append(MealInboxItem(eatenAt: eatenAt,
                                     photos: group.map { MealPhotoRef(id: $0.id, takenAt: $0.takenAt, depth: $0.depth) },
                                     note: note,
                                     state: note.isEmpty && !photoOnly.contains(key) ? .awaitingNote : .ready,
                                     origin: .picked))
        }
        for piece in pieces {
            new.append(MealInboxItem(eatenAt: MealLogTime.date(on: day, part: piece.part), note: piece.text,
                                     state: .ready, origin: .typed))
        }
        MealInboxStore.shared.add(new)
        dismiss()
    }
}

#if DEBUG
extension MealDumpView {
    /// Three drawn "photos" with camera times: two at lunch yesterday, one at dinner.
    static func previewImages(now: Date = Date()) -> [Data] {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let times = [(12, 31), (12, 44), (19, 5)].compactMap {
            calendar.date(bySettingHour: $0.0, minute: $0.1, second: 0, of: yesterday)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.85, 0.55, 0.2), (0.9, 0.8, 0.5), (0.35, 0.2, 0.15)]
        return zip(times, colors).compactMap { time, color in
            let context = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.5, green: 0.38, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
            context.fillEllipse(in: CGRect(x: 60, y: 60, width: 480, height: 480))
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: 160, y: 190, width: 280, height: 200))
            guard let image = context.makeImage() else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
            let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: time)]
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}
#endif

/// An image dropped on the Nutrition page: file data from Finder or Photos.
struct DroppedMealImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { DroppedMealImage(data: $0) }
        FileRepresentation(importedContentType: .image) { file in
            DroppedMealImage(data: try Data(contentsOf: file.file))
        }
    }
}
#endif
