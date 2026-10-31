import CoreGraphics
import XCTest

/// A photographed Nutrition Facts panel, put back into its rows before it's parsed
/// (`TextRows`, `NutritionLabelReader.label`). Text recognition hands back "Calories" and its big
/// "210" as two pieces, the number first because its top is higher — and the same for "Serving
/// size" and its bold "1 cup (140g)" — so no photographed label was ever read (15 Oct 2026).
final class LabelRowsTests: XCTestCase {
    /// Pieces as Mac Vision returned them off a drawn label: left, top, right, bottom, 0–1, top down.
    private let label: [(String, CGRect)] = [
        ("Nutrition Facts", CGRect(x: 0.05, y: 0.03, width: 0.75, height: 0.06)),
        ("About 3 servings per container", CGRect(x: 0.05, y: 0.11, width: 0.5, height: 0.025)),
        ("1 cup (140g)", CGRect(x: 0.6, y: 0.145, width: 0.35, height: 0.034)),
        ("Serving size", CGRect(x: 0.05, y: 0.150, width: 0.3, height: 0.028)),
        ("Amount per serving", CGRect(x: 0.05, y: 0.215, width: 0.35, height: 0.02)),
        ("210", CGRect(x: 0.72, y: 0.245, width: 0.23, height: 0.08)),
        ("Calories", CGRect(x: 0.05, y: 0.27, width: 0.35, height: 0.045)),
        ("4%", CGRect(x: 0.88, y: 0.385, width: 0.07, height: 0.024)),
        ("Total Fat 3.5g", CGRect(x: 0.05, y: 0.386, width: 0.33, height: 0.024)),
        ("Total Carbohydrate 40g", CGRect(x: 0.05, y: 0.43, width: 0.5, height: 0.024)),
        ("Protein 5g", CGRect(x: 0.05, y: 0.47, width: 0.22, height: 0.024)),
    ]

    /// The pieces as Vision reports them: corners, turned `degrees` about the middle of an image
    /// `aspect` wide for each unit tall.
    private func pieces(turned degrees: Double = 0, aspect: Double = 0.6) -> [TextRows.Piece] {
        let a = degrees * .pi / 180
        func turn(_ x: Double, _ y: Double) -> CGPoint {
            let (px, py) = ((x - 0.5) * aspect, y - 0.5)
            return CGPoint(x: (px * cos(a) - py * sin(a)) / aspect + 0.5, y: px * sin(a) + py * cos(a) + 0.5)
        }
        return label.map { text, r in
            TextRows.Piece(text: text, topLeft: turn(r.minX, r.minY), topRight: turn(r.maxX, r.minY),
                           bottomLeft: turn(r.minX, r.maxY), bottomRight: turn(r.maxX, r.maxY))
        }
    }

    func testABigNumberBesideItsNameIsOneRow() throws {
        let rows = TextRows.rows(pieces(), aspect: 0.6)
        XCTAssertTrue(rows.contains("Serving size 1 cup (140g)"), "\(rows)")
        XCTAssertTrue(rows.contains("Calories 210"), "\(rows)")
        XCTAssertTrue(rows.contains("Total Fat 3.5g 4%"), "\(rows)")
        let parsed = try XCTUnwrap(NutritionLabelParser.parse(rows))
        XCTAssertEqual(parsed.servingGrams, 140)
        XCTAssertEqual(parsed.perServing, NutritionMacros(calories: 210, proteinGrams: 5, carbohydrateGrams: 40, fatGrams: 3.5))
    }

    func testAPhotoAFewDegreesOffLevelStillPairsEachNumberWithItsRow() {
        for degrees in [-8.0, 4, 12] {
            let rows = TextRows.rows(pieces(turned: degrees), aspect: 0.6)
            XCTAssertTrue(rows.contains("Calories 210"), "\(degrees)°: \(rows)")
            XCTAssertTrue(rows.contains("Serving size 1 cup (140g)"), "\(degrees)°: \(rows)")
            XCTAssertNotNil(NutritionLabelParser.parse(rows), "\(degrees)°")
        }
    }

    func testTheNextLineOfSmallPrintIsItsOwnRow() {
        let rows = TextRows.rows(pieces(), aspect: 0.6)
        XCTAssertTrue(rows.contains("Amount per serving"), "\(rows)")
        XCTAssertTrue(rows.contains("About 3 servings per container"), "\(rows)")
    }

    /// Read piece by piece, as before: the number before its name is found too.
    func testTheParserFindsANumberPrintedBeforeItsName() throws {
        let parsed = try XCTUnwrap(NutritionLabelParser.parse(label.map(\.0)))
        XCTAssertEqual(parsed.servingLabel, "1 cup")
        XCTAssertEqual(parsed.servingGrams, 140)
        XCTAssertEqual(parsed.perServing.calories, 210)
    }
}

/// Choosing between the parser's reading of a panel and the model's (`LabelCheck`).
final class LabelCheckTests: XCTestCase {
    private let printed = """
        Nutrition Facts
        About 3 servings per container
        Serving size 1 cup (140g)
        Calories 210
        Total Fat 3.5g 4%
        Total Carbohydrate 40g 15%
        Protein 5g
        """

    private func label(grams: Double = 140, kcal: Double = 210, fat: Double = 3.5, carbs: Double = 40,
                       protein: Double = 5, servings: Double? = 3) -> ParsedNutritionLabel {
        ParsedNutritionLabel(servingLabel: "1 cup", servingGrams: grams, servingsPerContainer: servings,
                             perServing: NutritionMacros(calories: kcal, proteinGrams: protein, carbohydrateGrams: carbs, fatGrams: fat))
    }

    func testTheParsersReadingWinsWhenItHoldsUp() {
        let model = label(kcal: 200)   // misread, but it adds up too
        XCTAssertEqual(LabelCheck.choose(parsed: label(), read: model, printed: printed), label())
    }

    func testWhatTheParserMissedIsTakenFromTheModelWhenPrinted() {
        let parsed = label(protein: 0, servings: nil)   // the protein line and the servings line weren't read
        XCTAssertEqual(LabelCheck.choose(parsed: parsed, read: label(), printed: printed), label())
    }

    func testANumberThatIsntPrintedIsntTaken() {
        let parsed = label(protein: 0)
        let model = label(protein: 6)   // "6" is nowhere on the label
        XCTAssertEqual(LabelCheck.choose(parsed: parsed, read: model, printed: printed)?.perServing.proteinGrams, 0)
    }

    func testTheModelsReadingIsUsedWhenTheParsersDoesntAddUp() {
        let misread = label(kcal: 2_10)   // fine
        XCTAssertEqual(LabelCheck.choose(parsed: misread, read: nil, printed: printed), misread)
        // The parser took the % Daily Value for the fat: 4 g of fat, 15 g carbs — 210 kcal doesn't add up.
        let wrong = label(fat: 4, carbs: 15)
        XCTAssertFalse(LabelCheck.holds(wrong, numbers: LabelCheck.printedNumbers(printed)))
        XCTAssertEqual(LabelCheck.choose(parsed: wrong, read: label(), printed: printed), label())
    }

    func testANumberTheModelMadeUpIsntBelieved() {
        let invented = label(grams: 150)   // no "150" on the label
        XCTAssertNil(LabelCheck.choose(parsed: nil, read: invented, printed: printed))
    }

    func testWithoutAModelTheParsersReadingIsUsedAsItIs() {
        let odd = label(kcal: 90)   // doesn't add up, but it's all there is
        XCTAssertEqual(LabelCheck.choose(parsed: odd, read: nil, printed: printed), odd)
    }

    func testCaloriesWithTheirMacrosMissingDontAddUp() {
        // Peas: 60 kcal, 0 g fat, 11 g carbs, 4 g protein.
        XCTAssertTrue(LabelCheck.addsUp(NutritionMacros(calories: 60, proteinGrams: 4, carbohydrateGrams: 11, fatGrams: 0)))
        XCTAssertFalse(LabelCheck.addsUp(NutritionMacros(calories: 210)), "calories and nothing else, as a half-read label")
        XCTAssertTrue(LabelCheck.addsUp(NutritionMacros(calories: 10)), "a few calories needn't come with macros")
    }

    func testAPanelReadCleanlyNeedsNoModel() {
        XCTAssertTrue(LabelCheck.settled(label(), printed: printed))
        XCTAssertFalse(LabelCheck.settled(label(protein: 0), printed: printed), "a 0 may be a line not read")
        XCTAssertFalse(LabelCheck.settled(label(fat: 4, carbs: 15), printed: printed), "doesn't add up")
    }

    /// A small package's one-paragraph label.
    func testTheOneParagraphLabel() throws {
        let parsed = try XCTUnwrap(NutritionLabelParser.parse([
            "Nutrition Facts",
            "Servings: 1, Serv. size: 1 bar (40g), Amount per serving: Calories 190, Total Fat 7g (9% DV),",
            "Sat. Fat 3g (15% DV), Trans Fat 0g, Cholest. 0mg (0% DV), Sodium 95mg (4% DV), Total Carb. 28g",
            "(10% DV), Fiber 3g (11% DV), Total Sugars 12g (Incl. 10g Added Sugars, 20% DV), Protein 4g,",
        ]))
        XCTAssertEqual(parsed.servingLabel, "1 bar")
        XCTAssertEqual(parsed.servingGrams, 40)
        XCTAssertEqual(parsed.perServing, NutritionMacros(calories: 190, proteinGrams: 4, carbohydrateGrams: 28, fatGrams: 7))
    }

    func testPrintedNumbers() {
        XCTAssertEqual(LabelCheck.printedNumbers("Total Fat 3.5g 4% Sodium 1,200mg"), [3.5, 4, 1200])
    }
}
