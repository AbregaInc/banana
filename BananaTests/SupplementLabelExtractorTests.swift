import XCTest
import CoreGraphics
import UIKit

/// `SupplementLabelExtractor.confidence(forValue:in:)` and the deterministic (model-unavailable)
/// fallback — both pure and Vision/FoundationModels-free, so they're testable without a camera,
/// a device, or Apple Intelligence being available in the test environment.
final class SupplementLabelExtractorTests: XCTestCase {
    private typealias Line = RecognizedLabelLine

    func testValueTracedToTheExactLineUsesThatLinesConfidence() {
        let lines = [Line(text: "NOW Foods", confidence: 0.98), Line(text: "Zinc Picolinate 50 mg", confidence: 0.61)]
        XCTAssertEqual(SupplementLabelExtractor.confidence(forValue: "Zinc Picolinate 50 mg", in: lines), 0.61)
    }

    func testValueFoundAsSubstringOfALineUsesThatLinesConfidence() {
        let lines = [Line(text: "Zinc Picolinate 50 mg — 120 Veg Capsules", confidence: 0.42)]
        XCTAssertEqual(SupplementLabelExtractor.confidence(forValue: "Zinc Picolinate 50 mg", in: lines), 0.42)
    }

    func testUnattributableValueFallsBackToWeakestOverlappingLineNotAnAssumedGoodDefault() {
        // The model paraphrased/reformatted, so no line contains the exact text — but "zinc" and
        // "picolinate" both appear, split across two lines with different confidences. The score
        // must never just assume the strongest (or a fixed high) confidence.
        let lines = [Line(text: "Zinc", confidence: 0.95), Line(text: "Picolinate 50 milligrams", confidence: 0.30)]
        XCTAssertEqual(SupplementLabelExtractor.confidence(forValue: "Zinc Picolinate 50mg", in: lines), 0.30)
    }

    func testCompletelyUnattributableValueFallsBackToTheWeakestLineOnThePanel() {
        let lines = [Line(text: "Supplement Facts", confidence: 0.9), Line(text: "Serving Size 1 Capsule", confidence: 0.25)]
        XCTAssertEqual(SupplementLabelExtractor.confidence(forValue: "Something entirely unrelated", in: lines), 0.25)
    }

    func testEmptyValueOrNoLinesScoresZero() {
        XCTAssertEqual(SupplementLabelExtractor.confidence(forValue: "", in: [Line(text: "x", confidence: 1)]), 0)
        XCTAssertEqual(SupplementLabelExtractor.confidence(forValue: "Zinc", in: []), 0)
    }

    func testConfidentThresholdMatchesTheFoodEntryReviewScreensCutoff() {
        XCTAssertTrue(SupplementLabelField(value: "Zinc", confidence: 0.9).isConfident)
        XCTAssertFalse(SupplementLabelField(value: "Zinc", confidence: 0.89).isConfident)
    }

    // MARK: - Deterministic fallback (model unavailable)

    func testDeterministicRecordWithNoGeometryStillFallsBackToTheLongestLine() {
        let lines = [
            Line(text: "NOW", confidence: 0.99),
            Line(text: "Zinc Picolinate 50 mg", confidence: 0.7),
            Line(text: "120 Veg Capsules", confidence: 0.5),
        ]
        let record = SupplementLabelExtractor.deterministicRecord(from: lines)
        XCTAssertEqual(record.name?.value, "Zinc Picolinate 50 mg")
        XCTAssertEqual(record.dose?.value, "Zinc Picolinate 50 mg")
    }

    func testDeterministicRecordLeavesDoseNilWhenNoLineLooksLikeADose() {
        let lines = [Line(text: "NOW Foods", confidence: 0.9), Line(text: "Premium Quality Supplement", confidence: 0.8)]
        let record = SupplementLabelExtractor.deterministicRecord(from: lines)
        XCTAssertNil(record.dose)
    }

    func testDeterministicRecordEveryFieldTracesToARealLinesOwnConfidence() {
        let lines = [Line(text: "A short line", confidence: 0.4), Line(text: "A very much longer descriptive product line here", confidence: 0.77)]
        let record = SupplementLabelExtractor.deterministicRecord(from: lines)
        XCTAssertEqual(record.name?.confidence, 0.77)
    }

    // MARK: - Reading order and print size (the "it picks a random line" fix)

    /// A line at the top of a bottle photo has a HIGH y in Vision's space (origin bottom-left).
    private func line(_ text: String, _ confidence: Double, y: CGFloat, height: CGFloat, x: CGFloat = 0.1) -> Line {
        Line(text: text, confidence: confidence, box: CGRect(x: x, y: y, width: 0.5, height: height))
    }

    func testReadingOrderSortsTopToBottomWhateverOrderVisionDetectedThemIn() {
        let shuffled = [
            line("Serving Size 1 Softgel", 0.6, y: 0.40, height: 0.02),
            line("NOW", 0.99, y: 0.88, height: 0.10),
            line("Vitamin D-3", 0.95, y: 0.74, height: 0.07),
        ]
        XCTAssertEqual(SupplementLabelExtractor.inReadingOrder(shuffled).map(\.text),
                       ["NOW", "Vitamin D-3", "Serving Size 1 Softgel"])
    }

    func testReadingOrderKeepsATwoColumnFactsPanelRowOnItsOwnRowLeftToRight() {
        // A Supplement Facts panel is a table: nutrient on the left, amount on the right. Reading
        // it as one column and then the other is how a dose ends up attached to the wrong nutrient.
        let panel = [
            line("500 mcg", 0.7, y: 0.402, height: 0.02, x: 0.62),
            line("Vitamin B12", 0.8, y: 0.400, height: 0.02, x: 0.08),
            line("Vitamin D-3", 0.8, y: 0.440, height: 0.02, x: 0.08),
            line("125 mcg", 0.7, y: 0.441, height: 0.02, x: 0.62),
        ]
        XCTAssertEqual(SupplementLabelExtractor.inReadingOrder(panel).map(\.text),
                       ["Vitamin D-3", "125 mcg", "Vitamin B12", "500 mcg"])
    }

    func testReadingOrderIsANoOpWhenThereIsNoGeometryToUse() {
        let plain = [Line(text: "one", confidence: 1), Line(text: "two", confidence: 1), Line(text: "three", confidence: 1)]
        XCTAssertEqual(SupplementLabelExtractor.inReadingOrder(plain).map(\.text), ["one", "two", "three"])
    }

    func testSizeRankPutsTheBiggestPrintAtNineAndTheSmallestAtOne() {
        let lines = [
            line("NOW", 0.99, y: 0.88, height: 0.10),
            line("Vitamin D-3", 0.95, y: 0.74, height: 0.06),
            line("These statements have not been evaluated by the FDA.", 0.3, y: 0.05, height: 0.01),
        ]
        XCTAssertEqual(SupplementLabelExtractor.sizeRank(lines[0], in: lines), 9)
        XCTAssertEqual(SupplementLabelExtractor.sizeRank(lines[2], in: lines), 1)
        XCTAssertEqual(SupplementLabelExtractor.sizeRank(Line(text: "x", confidence: 1), in: lines), 0)
    }

    func testDeterministicRecordPicksTheBiggestPrintAsNameNotTheLongestLine() {
        // The longest line on a real supplement label is the disclaimer or the ingredient list.
        // Picking it as the product name is the bug this rule exists to prevent.
        let lines = [
            line("Vitamin D-3", 0.95, y: 0.74, height: 0.09),
            line("Other Ingredients: Olive Oil, Gelatin, Glycerin, Purified Water.", 0.4, y: 0.05, height: 0.01),
            line("Serving Size 1 Softgel", 0.6, y: 0.40, height: 0.02),
        ]
        let record = SupplementLabelExtractor.deterministicRecord(from: lines)
        XCTAssertEqual(record.name?.value, "Vitamin D-3")
        XCTAssertEqual(record.name?.confidence, 0.95)
        XCTAssertEqual(record.dose?.value, "Serving Size 1 Softgel")
    }

    // MARK: - What actually reaches the model

    func testPromptPayloadIsReadingOrderedAndSizePrefixed() {
        let lines = [
            line("Serving Size 1 Softgel", 0.6, y: 0.40, height: 0.01),
            line("NOW", 0.99, y: 0.88, height: 0.09),
        ]
        XCTAssertEqual(SupplementLabelExtractor.promptPayload(from: lines),
                       "9| NOW\n1| Serving Size 1 Softgel")
    }

    func testPromptPayloadCarriesNoSizePrefixWhenThePhotoCarriedNoGeometry() {
        let plain = [Line(text: "NOW Foods", confidence: 0.9), Line(text: "Zinc 50 mg", confidence: 0.8)]
        XCTAssertEqual(SupplementLabelExtractor.promptPayload(from: plain), "NOW Foods\nZinc 50 mg")
    }

    func testPromptPayloadDropsSmallPrintFirstAndKeepsDoseLinesAndNeverCutsMidLine() {
        let disclaimer = String(repeating: "legal boilerplate ", count: 30)
        let lines = [
            line("NOW", 0.99, y: 0.88, height: 0.09),
            line(disclaimer, 0.3, y: 0.05, height: 0.01),
            line("Zinc Picolinate 50 mg", 0.7, y: 0.40, height: 0.02),
        ]
        let payload = SupplementLabelExtractor.promptPayload(from: lines, characterBudget: 120)
        XCTAssertFalse(payload.contains("legal boilerplate"), "smallest, non-dose print goes first")
        XCTAssertTrue(payload.contains("Zinc Picolinate 50 mg"), "a dose line survives whatever its size")
        XCTAssertTrue(payload.contains("NOW"))
        // Whole lines only — a half-word would be text the label never carried.
        for row in payload.split(separator: "\n") {
            XCTAssertTrue(lines.contains { row.hasSuffix($0.text) }, "unexpected fragment: \(row)")
        }
    }

    // MARK: - Confidence attribution

    func testConfidenceIgnoresALineThatOnlyEchoesOneIncidentalWord() {
        // "Not a source of vitamin K" shares the word "vitamin" and nothing else. Letting it set
        // the score flagged a perfectly well-read field as an unreliable guess.
        let lines = [
            Line(text: "Vitamin D-3", confidence: 0.93),
            Line(text: "5000 IU per softgel", confidence: 0.88),
            Line(text: "Not a source of vitamin K", confidence: 0.20),
        ]
        XCTAssertEqual(SupplementLabelExtractor.confidence(forValue: "Vitamin D-3 5000 IU", in: lines), 0.88)
    }

    // MARK: - iOS 27 vision path

    /// On anything without a vision-capable model — every OS this app currently runs on — the
    /// photo route must decline rather than fail, so `extract(from:)` falls through to the OCR
    /// pipeline below it. This is the guarantee that adding iOS 27 support did not take anything
    /// away from iOS 26.
    func testTheVisionRouteDeclinesWhenNoModelCanSee() async {
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let record = await SupplementLabelExtractor.visionRecord(from: blank)
        XCTAssertNil(record, "no vision-capable model here, so the OCR pipeline must get the photo")
    }

    /// A value the model read off a photograph has no recognized line to trace to, so it must not
    /// be presented with the same authority as one that does.
    func testAPhotoReadValueIsNotPresentedAsConfident() {
        XCTAssertFalse(SupplementLabelField(value: "Zinc 30 mg",
                                            confidence: SupplementLabelExtractor.visionConfidence).isConfident)
    }
}
