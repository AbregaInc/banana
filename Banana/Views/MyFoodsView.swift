#if os(iOS) || os(macOS)
import SwiftUI

/// Your foods (`MyFoodsStore`): what you've scanned, most had first, with how often and when last.
/// The same list on the iPhone, iPad and Mac — delete, and scan to add.
struct MyFoodsView: View {
    @ObservedObject private var store = MyFoodsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    #if os(iOS)
    @State private var scanningGroceries = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                if store.foods.isEmpty {
                    ContentUnavailableView("No foods yet", systemImage: "barcode.viewfinder")
                } else {
                    Section {
                        ForEach(store.foods) { food in
                            row(food)
                                .swipeActions { Button("Delete", role: .destructive) { delete(food) } }
                                .contextMenu { Button("Delete", role: .destructive) { delete(food) } }
                        }
                    }
                }
                Section {
                    #if os(iOS)
                    // After shopping: package after package, the camera staying open.
                    Button { scanningGroceries = true } label: { Label("Scan what you bought", systemImage: "cart") }
                        .accessibilityIdentifier("myFoods.scan")
                    #else
                    Button { adding = true } label: { Label("Scan to add", systemImage: "barcode.viewfinder") }
                        .accessibilityIdentifier("myFoods.scan")
                    #endif
                }
            }
            .navigationTitle("My foods")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 440, idealWidth: 500, minHeight: 420, idealHeight: 560)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $adding) {
                // No meal to correct: a scan only adds the food.
                ScanCorrectionSheet(items: [], photos: [], onApply: { ToastCenter.shared.notify("Added \($0.food.name)") })
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanningGroceries) { GroceryScanView() }
            #endif
            .toastHost()
            #if DEBUG
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--label-read") || args.contains("--label-read-missed") { adding = true }
            }
            #endif
        }
    }

    private func row(_ food: MyFood) -> some View {
        MyFoodRow(food: food)
            .accessibilityIdentifier("myFoods.row")
    }

    private func delete(_ food: MyFood) {
        store.delete(food.id)
        Task {
            await ToastCenter.shared.offerUndo("Deleted \(food.name)") { @MainActor in
                MyFoodsStore.shared.restore(food)
                return nil
            }
        }
    }
}

#if DEBUG
extension MyFoodsStore {
    static let previewFoodID = UUID(uuidString: "00000000-0000-4000-8000-00000000f00d")!
    static let previewMealID = UUID(uuidString: "00000000-0000-4000-8000-00000000f00e")!

    /// `--scan-correct-preview`: Trader Joe's Pumpkin Gnocchi as if its label had been scanned, and
    /// a meal whose estimate called it "Gnocchi" — for correcting without a camera.
    @discardableResult
    func injectPreview() -> MealEntry {
        if food(Self.previewFoodID) == nil {
            save(MyFood(id: Self.previewFoodID, name: "Trader Joe's Pumpkin Gnocchi", barcode: "00517863",
                        per100g: NutritionMacros(calories: 150, proteinGrams: 3.6, carbohydrateGrams: 28.6, fatGrams: 2.5),
                        servingLabel: "1 cup", servingGrams: 140, packageGrams: 420, source: .label))
        }
        let generic = FoodReference(id: "fndds:11111", name: "Gnocchi, potato",
                                    per100g: NutritionMacros(calories: 133, proteinGrams: 3.2, carbohydrateGrams: 28, fatGrams: 0.6))
        return MealEntry(id: Self.previewMealID, date: Date(), items: [
            MealItem(name: "Gnocchi", serving: "1 plate \u{00B7} 180 g", macros: generic.macros(grams: 180),
                     confidence: 0.6, grams: 180, reference: generic),
            MealItem(name: "Side salad", serving: "1 bowl \u{00B7} 80 g",
                     macros: NutritionMacros(calories: 60, proteinGrams: 1.5, carbohydrateGrams: 5, fatGrams: 4),
                     confidence: 0.6, grams: 80),
            MealItem(name: "Parmesan", serving: "1 tbsp \u{00B7} 5 g",
                     macros: NutritionMacros(calories: 21, proteinGrams: 1.9, carbohydrateGrams: 0.2, fatGrams: 1.4),
                     confidence: 0.95, grams: 5),
        ], name: "Pumpkin gnocchi")
    }
}
#endif
#endif
