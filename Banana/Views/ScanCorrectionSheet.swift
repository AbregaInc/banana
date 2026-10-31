#if os(iOS) || os(macOS)
import PhotosUI
import SwiftUI

/// What a scan corrects a meal with: one of your foods, how much of it, and the item it replaces
/// (nil: added as a new item).
struct ScanCorrectionResult {
    var food: MyFood
    var grams: Double
    var replacing: UUID?

    /// The item it becomes — in the replaced item's place, under its id.
    var item: MealItem { ScanCorrection.item(food: food, grams: grams, id: replacing ?? UUID()) }
}

/// Correcting a meal with the package it came from, without typing: scan its barcode, or
/// photograph its Nutrition Facts when no database has it (Trader Joe's, mostly), or pick one of
/// your foods. It becomes one of your foods (`MyFoodsStore`), finds the item it is
/// (`ScanCorrection.target` — asking with one tap only when the names don't say), and works out
/// how much from the meal's photo, your usual, or the estimate (`ScanCorrection.startingGrams`).
struct ScanCorrectionSheet: View {
    struct Item: Identifiable {
        var id: UUID
        var name: String
        var grams: Double?
    }

    let items: [Item]
    /// The meal's photos, for how much was on the plate.
    let photos: [CGImage]
    /// The item being scanned for, when it was chosen first ("Scan its package" on one item of a
    /// meal): what's scanned replaces it, whatever the names say.
    var target: UUID? = nil
    /// A barcode already read (the groceries scanner's, for one no database has): looked up at
    /// once, so what's left is its label.
    var startingBarcode: String? = nil
    /// A photo already picked (the groceries list's, one with no barcode in it): read at once.
    var startingPhoto: Data? = nil
    let onApply: (ScanCorrectionResult) -> Void

    private var targetName: String? { target.flatMap { id in items.first { $0.id == id }?.name } }

    @ObservedObject private var store = MyFoodsStore.shared
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case start
        case working(String)
        /// No database has its nutrition: the label, photographed. `name` when the barcode knew it.
        case needLabel(name: String?, barcode: String?, note: String)
        /// The label is read (`reading`): its numbers to check, and its name (`name`).
        case review(barcode: String?)
        /// Which item it is, when the names don't say.
        case choosing(MyFood)
        /// Looking at the meal's photo for how much.
        case sizing(MyFood)
    }

    private enum Capture { case label, front }

    @State private var stage: Stage = .start
    @State private var capture: Capture = .label
    @State private var cameraOpen = false
    @State private var scannerOpen = false
    @State private var picked: PhotosPickerItem?
    @State private var finished = false
    @State private var problem: String?
    /// The label as read, as you correct it.
    @State private var reading: ParsedNutritionLabel?
    @State private var name = ""
    #if os(iOS)
    @State private var cameraImage: UIImage?
    #endif

    var body: some View {
        NavigationStack {
            List { content }
                .navigationTitle(targetName.map { "Scan for \($0)" } ?? "Scan a package")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #else
                .frame(minWidth: 440, idealWidth: 480, minHeight: 460, idealHeight: 560)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finished = true; dismiss() } }
                    if isReviewing {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { save() }
                                .disabled((reading?.servingGrams ?? 0) < 1)
                                .accessibilityIdentifier("scan.saveLabel")
                        }
                    }
                }
        }
        #if os(iOS)
        .sheet(isPresented: $scannerOpen) {
            BarcodeScannerView(onScan: { code in
                scannerOpen = false
                Task { await scanned(code) }
            }, onError: { message in
                scannerOpen = false
                problem = message
            })
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraPicker(image: $cameraImage).ignoresSafeArea()
        }
        .onChange(of: cameraImage) { _, image in
            guard let image, let data = image.jpegData(compressionQuality: 0.9) else { return }
            cameraImage = nil
            Task { await read(data) }
        }
        #endif
        .task {
            guard case .start = stage else { return }
            #if DEBUG
            // `--my-foods --label-read`: a label just read, to check; `--label-read-missed`: one
            // whose fat, carbs and protein weren't.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--label-read") || args.contains("--label-read-missed") {
                let missed = args.contains("--label-read-missed")
                reading = ParsedNutritionLabel(servingLabel: "2/3 cup", servingGrams: 80, servingsPerContainer: 5.5,
                                               perServing: NutritionMacros(calories: 60, proteinGrams: missed ? 0 : 4,
                                                                           carbohydrateGrams: missed ? 0 : 11, fatGrams: 0))
                stage = .review(barcode: nil)
                return
            }
            #endif
            if let startingBarcode {
                await scanned(startingBarcode, photo: startingPhoto.flatMap(PackagePhoto.image))
            } else if let startingPhoto {
                await read(startingPhoto)
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await read(data)
            }
        }
    }

    // MARK: - Stages

    @ViewBuilder private var content: some View {
        switch stage {
        case .start:
            startSections
        case .working(let note):
            Section { HStack(spacing: DS.Space.m) { ProgressView(); Text(note) } }
        case .needLabel(_, _, let note):
            Section {
                Text(note).font(.callout)
                photoButtons(camera: "Photograph the Nutrition Facts", library: "Choose a photo of the label", for: .label)
            } footer: {
                Text("Read on this device. Flat on, close enough to fill the frame.")
            }
        case .review:
            if let label = Binding($reading) { review(label) }
        case .choosing(let food):
            Section {
                ForEach(ScanCorrection.ranked(foodName: food.name, standsFor: food.standsFor,
                                              items: items.map { ($0.id, $0.name) }), id: \.self) { id in
                    if let item = items.first(where: { $0.id == id }) {
                        Button { Task { await size(food, replacing: id) } } label: {
                            Label(item.name, systemImage: "arrow.triangle.2.circlepath")
                        }
                        .accessibilityIdentifier("scan.choose")
                    }
                }
                Button { Task { await size(food, replacing: nil) } } label: {
                    Label("Add as new item", systemImage: "plus")
                }
                .accessibilityIdentifier("scan.addNew")
            } header: {
                Text("Which is \(food.name)?")
            }
        case .sizing(let food):
            Section {
                HStack(spacing: DS.Space.m) { ProgressView(); Text("Looking at the photo for how much \(food.name)\u{2026}") }
                Button("Skip") { Task { await apply(food, replacing: sizingTarget, photoServings: nil) } }
            }
        }
        if let problem {
            Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(DS.Palette.warning) }
        }
    }

    @ViewBuilder private var startSections: some View {
        #if os(iOS)
        Section {
            if BarcodeScannerView.isSupported {
                Button {
                    Task {
                        if await requestBarcodeCameraAccess() { scannerOpen = true } else {
                            problem = "Camera access is off. Allow it in Settings, or photograph the label from Photos."
                        }
                    }
                } label: {
                    Label("Scan its barcode", systemImage: "barcode.viewfinder")
                }
                .accessibilityIdentifier("scan.barcode")
            }
            photoButtons(camera: "Photograph the Nutrition Facts", library: "Choose a photo of the package", for: .label)
        } footer: {
            Text("The barcode finds most packages. For one no database has, the label on the back has everything.")
        }
        #else
        Section {
            photoButtons(camera: nil, library: "Choose a photo of the package", for: .label)
        } footer: {
            Text("Its barcode or its Nutrition Facts.")
        }
        #endif
        // Correcting a meal: one you've had before is a tap. (Adding to the list: it's already there.)
        if !store.foods.isEmpty, !items.isEmpty {
            Section("Your foods") {
                ForEach(store.foods.prefix(12)) { food in
                    Button { Task { await proceed(food) } } label: { MyFoodRow(food: food) }
                    .accessibilityIdentifier("scan.myFood")
                }
            }
        }
    }

    @ViewBuilder
    private func photoButtons(camera: String?, library: String, for kind: Capture) -> some View {
        #if os(iOS)
        if let camera, UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
                capture = kind
                Task {
                    if await requestBarcodeCameraAccess() { cameraOpen = true } else {
                        problem = "Camera access is off. Allow it in Settings, or choose a photo instead."
                    }
                }
            } label: {
                Label(camera, systemImage: "camera")
            }
            .accessibilityIdentifier(kind == .label ? "scan.labelPhoto" : "scan.frontPhoto")
        }
        #endif
        PhotosPicker(selection: Binding(get: { picked }, set: { capture = kind; picked = $0 }), matching: .images) {
            Label(library, systemImage: "photo")
        }
    }

    private var isReviewing: Bool {
        if case .review = stage { return true }
        return false
    }

    /// The label as read, laid out as it's printed, every number yours to correct; then its name.
    @ViewBuilder private func review(_ label: Binding<ParsedNutritionLabel>) -> some View {
        Section {
            LabeledContent("Servings per container") {
                number(label.servingsPerContainer, unit: nil)
            }
            LabeledContent("Serving size") {
                HStack(spacing: DS.Space.xs) {
                    TextField("Serving size", text: label.servingLabel, prompt: Text("1 cup"))
                        .multilineTextAlignment(.trailing)
                        #if os(macOS)
                        .labelsHidden()
                        #endif
                    number(label.servingGrams, unit: "g")
                }
            }
            LabeledContent { number(label.perServing.calories, unit: "kcal") } label: { Text("Calories").bold() }
            LabeledContent("Total fat") { number(label.perServing.fatGrams, unit: "g") }
            LabeledContent("Total carbohydrate") { number(label.perServing.carbohydrateGrams, unit: "g") }
            LabeledContent("Protein") { number(label.perServing.proteinGrams, unit: "g") }
        } header: {
            Text("Nutrition Facts")
        } footer: {
            if !LabelCheck.addsUp(label.wrappedValue.perServing) {
                Label("Calories don\u{2019}t match the fat, carbs and protein. Check them against the label.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.Palette.warning)
                    .accessibilityIdentifier("scan.labelOff")
            }
        }
        Section("Name") {
            TextField("Name", text: $name, prompt: Text(fallbackName))
                .accessibilityIdentifier("scan.labelName")
                #if os(macOS)
                .labelsHidden()
                #endif
            photoButtons(camera: "Read it off the front", library: "Choose a photo of the front", for: .front)
        }
    }

    /// A number off the label, to correct: "11", "2.5".
    private func number(_ value: Binding<Double>, unit: String?) -> some View {
        number(Binding<Double?>(get: { value.wrappedValue }, set: { value.wrappedValue = $0 ?? 0 }), unit: unit)
    }

    private func number(_ value: Binding<Double?>, unit: String?) -> some View {
        HStack(spacing: DS.Space.xs) {
            TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #else
                .labelsHidden()
                #endif
                .frame(width: 64)
            // Always the unit's room, so every number on the panel ends in one column.
            Text(unit ?? "").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
        }
    }

    private func save() {
        guard case .review(let barcode) = stage, let reading, reading.servingGrams >= 1 else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        problem = nil
        Task { await found(MyFoods.food(label: reading, name: typed.isEmpty ? fallbackName : typed, barcode: barcode)) }
    }

    // MARK: - Steps

    private var fallbackName: String { items.count == 1 ? items[0].name : "Packaged food" }

    @State private var sizingTarget: UUID?

    /// A barcode, read live or off a photo. With the photo, a package no database has nutrition
    /// for is first read from it: the label is often beside the barcode.
    private func scanned(_ raw: String, photo: CGImage? = nil) async {
        problem = nil
        if let barcode = try? BarcodeProductLookup.normalizedBarcode(raw), let mine = store.food(barcode: barcode) {
            await proceed(mine)
            return
        }
        stage = .working("Looking it up\u{2026}")
        let photoLabel = "Photograph its Nutrition Facts \u{2014} that\u{2019}s all it takes."
        do {
            switch try await BarcodeProductLookup.lookup(raw) {
            case .foundLocally(let product), .foundOnline(let product):
                if let food = MyFoods.food(product: product) {
                    await found(food)
                } else if !(await labelled(photo, name: product.name, barcode: product.barcode)) {
                    stage = .needLabel(name: product.name, barcode: product.barcode,
                                       note: "\(product.name): no nutrition on file. \(photoLabel)")
                }
            case .notFound:
                if await labelled(photo, name: nil, barcode: raw) { return }
                stage = .needLabel(name: nil, barcode: raw, note: "No database has this one. \(photoLabel)")
            case .networkError, .rateLimited:
                if await labelled(photo, name: nil, barcode: raw) { return }
                stage = .needLabel(name: nil, barcode: raw, note: "Couldn\u{2019}t reach the databases. \(photoLabel)")
            }
        } catch {
            stage = .needLabel(name: nil, barcode: nil, note: "That barcode didn\u{2019}t read. \(photoLabel)")
        }
    }

    /// The Nutrition Facts in a photo of the package, when they're in it. False when they aren't,
    /// to ask for them.
    private func labelled(_ photo: CGImage?, name: String?, barcode: String?) async -> Bool {
        guard let photo else { return false }
        stage = .working("Reading the label\u{2026}")
        guard let label = await NutritionLabelReader.label(in: photo) else { return false }
        reading = label
        self.name = name ?? ""
        stage = .review(barcode: barcode)
        return true
    }

    /// A photo: the package (its barcode, when one shows), the label, or the front for its name.
    private func read(_ data: Data) async {
        problem = nil
        guard let image = PackagePhoto.image(data) else { return }
        // A first photo with a barcode in it is that product, as if scanned.
        if case .start = stage, let code = await PackagePhoto.barcodes(in: image).first {
            return await scanned(code, photo: image)
        }
        switch (capture, stage) {
        case (.front, .review(let barcode)):
            stage = .working("Reading its name\u{2026}")
            if let read = await NutritionLabelReader.productName(in: image) {
                name = read
            } else {
                problem = "Couldn\u{2019}t read a name off that. Type it instead."
            }
            stage = .review(barcode: barcode)
        default:
            var name: String?
            var barcode: String?
            if case .needLabel(let known, let code, _) = stage { (name, barcode) = (known, code) }
            if !(await labelled(image, name: name, barcode: barcode)) {
                stage = .needLabel(name: name, barcode: barcode,
                                   note: "Couldn\u{2019}t read the Nutrition Facts. Try again closer, flat on, in good light.")
            }
        }
    }

    /// A newly scanned food: kept, then applied.
    private func found(_ food: MyFood) async {
        await proceed(store.save(food))
    }

    /// Which item it is: the clear one, or ask.
    private func proceed(_ food: MyFood) async {
        guard !items.isEmpty else { return await size(food, replacing: nil) }
        if let target, items.contains(where: { $0.id == target }) { return await size(food, replacing: target) }
        switch ScanCorrection.target(foodName: food.name, standsFor: food.standsFor, items: items.map { ($0.id, $0.name) }) {
        case .item(let id): await size(food, replacing: id)
        case .ask: stage = .choosing(food)
        }
    }

    /// How much: what the photo shows, when a model can see it; else the usual.
    private func size(_ food: MyFood, replacing: UUID?) async {
        var photoServings: Double?
        // Counting servings in the photo needs a serving to count.
        if !photos.isEmpty, food.servingStated, ServingsFromPhoto.canLook {
            sizingTarget = replacing
            stage = .sizing(food)
            photoServings = await ServingsFromPhoto.servings(of: food, in: photos)
        }
        await apply(food, replacing: replacing, photoServings: photoServings)
    }

    private func apply(_ food: MyFood, replacing: UUID?, photoServings: Double?) async {
        guard !finished else { return }
        finished = true
        let estimated = items.first { $0.id == replacing }?.grams
        let grams = ScanCorrection.startingGrams(photoServings: photoServings, food: food, estimatedGrams: estimated)
        onApply(ScanCorrectionResult(food: food, grams: grams, replacing: replacing))
        dismiss()
    }
}

/// How a food of yours reads in a list.
enum MyFoodsText {
    /// "2/3 cup · 80 g · had 6 times · bought 14 Oct"; "per 100 g" when its package states no
    /// serving. The calories go on the right of the row (`MyFoodRow`).
    static func detail(_ food: MyFood) -> String {
        var parts = [food.servingStated ? NutritionText.serving(food.servingLabel, grams: food.servingGrams) : "per 100 g"]
        if !food.uses.isEmpty {
            parts.append("had \(food.uses.count == 1 ? "once" : "\(food.uses.count) times")")
        }
        // Bought since you last had it: when.
        if !food.bought.isEmpty, (food.lastUsed ?? .distantPast) < food.lastBought {
            parts.append("bought \(food.lastBought.formatted(.dateTime.day().month(.abbreviated)))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// A serving's calories, or 100 g's when no serving is stated.
    static func calories(_ food: MyFood) -> Double {
        food.reference.macros(grams: food.servingStated ? food.servingGrams : 100).calories
    }
}

/// One of your foods as a row: its name, its serving and when you had it, its calories on the
/// right. The same in My foods and in a scan's list.
struct MyFoodRow: View {
    let food: MyFood

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(food.name).foregroundStyle(.primary)
                Text(MyFoodsText.detail(food)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            StatValue(label: nil, value: MyFoodsText.calories(food).rounded().formatted(.number.precision(.fractionLength(0))),
                      unit: "kcal", size: .row)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
