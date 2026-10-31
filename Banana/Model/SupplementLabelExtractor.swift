#if os(iOS)
import Foundation
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One line of text Vision recognized on a supplement label photo, plus its own OCR confidence
/// (0...1). Kept as its own small value rather than folded straight into the model's structured
/// output so a field can be traced back to the specific photographed line it was read from — see
/// `SupplementLabelExtractor.confidence(forValue:in:)`.
struct RecognizedLabelLine: Equatable, Sendable {
    var text: String
    var confidence: Double
    /// Where the line sits on the photo, in Vision's normalized space (origin bottom-left, 0...1
    /// on both axes). Defaults to `.zero` so fixtures and tests can describe a label as plain
    /// text; every geometry-driven rule below degrades to a text-only one when it's absent.
    ///
    /// This is the field whose absence caused the original bug. Vision returns observations in
    /// detection order, not reading order, so the model was handed a shuffled bag of lines with
    /// no way to tell a product name set in 40-point type from a footnote set in 5-point — and
    /// picked what looked, from the outside, like a line at random.
    var box: CGRect = .zero
}

/// One field the label reader filled, carrying its own recognition confidence and — implicitly,
/// by existing at all — the fact that it came from a photographed label rather than a database.
/// Deliberately per-field rather than one whole-panel confidence: a bottle photo routinely has
/// some perfectly legible lines (a bold product name) next to some genuinely hard ones (small
/// print at an angle), and one blanket warning for the whole panel would either hide the risky
/// field or cry wolf on the reliable one.
struct SupplementLabelField: Equatable, Sendable {
    var value: String
    /// 0...1, the OCR confidence of the recognized line(s) this value traces back to — 0 when it
    /// can't be traced to any specific line (the model paraphrased or merged several lines), on
    /// purpose: this score exists specifically so the app never claims confidence it can't back
    /// up with an actual photographed line.
    var confidence: Double
    /// `>= 0.9` mirrors `ResolvedFoodItem.isConfident`'s cutoff — the same amber-vs-plain
    /// treatment the food-entry review screen already uses for its own AI-estimated rows.
    var isConfident: Bool { confidence >= 0.9 }
}

struct SupplementLabelRecord: Equatable, Sendable {
    var name: SupplementLabelField?
    /// Serving size and active dose combined into one short phrase — `SupplementSchedule.dose`
    /// is a single free-text field, so there is nowhere else for a separate dose value to go in
    /// this pass. See the extractor's report for what a fuller structured record would need.
    var dose: SupplementLabelField?
}

/// Reads a photographed Supplement Facts label: Vision OCR for the raw text, then Apple's
/// on-device model to turn those lines into a structured, still-editable record. This is the
/// guaranteed fallback for a barcode that no database — bundled catalog, Open Food Facts, DSLD,
/// or UPCitemdb — will ever have, which is unavoidably some real bottle in every scan session.
///
/// Two hazards specific to this input, both guarded explicitly:
/// - The model's context window (4096 tokens, shared across instructions + prompt + output) can
///   be exceeded by a long ingredients panel plus OCR noise, the same risk `CreditsExtractor`
///   guards against for long show notes — handled the same way, with a length cap on the OCR text
///   and a distinct `.permanentlyUnavailable` outcome when the model throws anyway.
/// - European packaging routinely repeats the whole panel in two or three languages on one
///   label. Vision's `automaticallyDetectsLanguage` lets the recognizer itself switch per line,
///   and the model is explicitly told the panel may be multilingual so it picks one language's
///   line per field instead of quietly splicing words from two languages together.
enum SupplementLabelExtractor {
    enum Outcome {
        case record(SupplementLabelRecord)
        /// Vision recognized no text at all — a blank/mislabeled photo or an unreadable angle.
        case noText
        /// The on-device model threw `exceededContextWindowSize` for this exact recognized-text
        /// payload. Deterministic for this input, so a caller can present this as a dead end
        /// (try a closer photo of just the facts panel) rather than inviting an identical retry.
        case permanentlyUnavailable
    }

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    static func extract(from image: UIImage) async -> Outcome {
        // iOS 27 can hand the photo to the model directly. Everything below this — reading order,
        // print-size ranking, the line budget — exists because an iOS 26 model could only be given
        // text, so the OCR had to be reassembled into something a blind reader could interpret.
        // With vision, that reconstruction is guesswork standing between the model and the thing
        // it could just look at. It stays as the fallback, which is what iOS 26 keeps using.
        if let record = await visionRecord(from: image) { return .record(record) }

        let lines: [RecognizedLabelLine]
        do {
            lines = try await recognizeText(in: image)
        } catch {
            return .noText
        }
        guard !lines.isEmpty else { return .noText }

        guard modelAvailable else { return .record(deterministicRecord(from: lines)) }

        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: promptPayload(from: lines),
                                                         generating: GeneratedSupplementLabel.self)
                return .record(structuredRecord(from: response.content, lines: lines))
            } catch {
                // iOS 27 renamed this: `GenerationError.exceededContextWindowSize` is deprecated
                // in favour of `LanguageModelError.contextSizeExceeded`. Both are matched so the
                // "don't invite an identical retry" outcome survives the OS update.
                if isContextOverflow(error) { return .permanentlyUnavailable }
                return .record(deterministicRecord(from: lines))
            }
        }
        #endif
        return .record(deterministicRecord(from: lines))
    }

    /// Reads the label by showing the model the photograph, on any OS and model that can take one.
    ///
    /// Returns nil — not a failure — whenever this route isn't available or doesn't produce
    /// anything, so the caller falls through to the OCR pipeline rather than losing the scan.
    ///
    /// Confidence is the honest difference from the OCR path. There, every field traces to a
    /// recognized line with its own OCR score. Here there are no lines to trace to: the model read
    /// the picture. Rather than invent a number, these come back at the `.aiEstimate` bar, so the
    /// review screen flags them amber for checking against the bottle — which is what you want for
    /// a value nothing has vouched for.
    static func visionRecord(from image: UIImage) async -> SupplementLabelRecord? {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return nil }
        guard let cgImage = image.cgImage else { return nil }
        guard let (session, route) = Intelligence.session(for: .vision,
                                                      instructions: visionInstructions) else { return nil }
        do {
            let response = try await Intelligence.withTimeout(seconds: 25, route: route) {
                try await session.respond(generating: GeneratedSupplementLabel.self,
                                          options: .init(temperature: 0.2)) {
                    "Read this Supplement Facts label."
                    Attachment(cgImage).label("supplement label photograph")
                }
            }
            let generated = response.content
            func trimmed(_ value: String?) -> String? {
                guard let value else { return nil }
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            let product = trimmed(generated.productName)
            let brand = trimmed(generated.brand)
            let name: SupplementLabelField? = {
                switch (product, brand) {
                case (nil, nil): return nil
                case (let product?, nil): return .init(value: product, confidence: visionConfidence)
                case (nil, let brand?): return .init(value: brand, confidence: visionConfidence)
                case (let product?, let brand?):
                    return .init(value: BarcodeProductLookup.combinedName(brand: brand, product: product),
                                 confidence: visionConfidence)
                }
            }()
            let dose = trimmed(generated.servingAndDose)
                .map { SupplementLabelField(value: $0, confidence: visionConfidence) }
            guard name != nil || dose != nil else { return nil }
            return SupplementLabelRecord(name: name, dose: dose)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Below `SupplementLabelField.isConfident`'s 0.9 bar on purpose — see `visionRecord`.
    static let visionConfidence = 0.6

    // MARK: - Vision OCR

    private static func recognizeText(in image: UIImage) async throws -> [RecognizedLabelLine] {
        guard let cgImage = image.cgImage else { throw ExtractionError.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { observation -> RecognizedLabelLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedLabelLine(text: candidate.string,
                                               confidence: Double(candidate.confidence),
                                               box: observation.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            // European supplement packaging routinely repeats the panel in two or three
            // languages on one label — automatic detection lets the recognizer switch per line
            // instead of committing to whatever language the first line happens to be in.
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum ExtractionError: Error { case invalidImage }

    /// Did this request overflow the model's context window?
    ///
    /// Matched across both spellings. iOS 27 deprecates
    /// `LanguageModelSession.GenerationError.exceededContextWindowSize` in favour of
    /// `LanguageModelError.contextSizeExceeded`, and the app runs on both — so catching only one
    /// would silently turn a deterministic dead end back into an inviting "try again", which is
    /// exactly the outcome `.permanentlyUnavailable` exists to prevent. (No deprecation warning
    /// here: the deployment target is below 27, so the old spelling is not yet deprecated for us.)
    static func isContextOverflow(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            if let modelError = error as? LanguageModelError,
               case .contextSizeExceeded = modelError { return true }
        }
        if #available(iOS 26, macOS 26, *) {
            if let generationError = error as? LanguageModelSession.GenerationError,
               case .exceededContextWindowSize = generationError { return true }
        }
        #endif
        return false
    }

    // MARK: - Layout: turning a bag of observations back into a label

    /// Vision hands back observations in detection order, which on a bottle photo is neither
    /// top-to-bottom nor grouped into columns. Restoring reading order is the single largest fix
    /// to "it picks a random line": `productName` is a question about which line comes FIRST and
    /// LARGEST, and the model previously had neither fact.
    ///
    /// Lines whose vertical centres fall within half a line-height of each other are treated as
    /// one visual row and ordered left-to-right, so a two-column Supplement Facts panel reads
    /// across rather than down one column and back up the other. Ties — and the all-`.zero` boxes
    /// a text-only fixture produces — fall back to the original order, so this is a no-op rather
    /// than a shuffle when there's no geometry to use.
    static func inReadingOrder(_ lines: [RecognizedLabelLine]) -> [RecognizedLabelLine] {
        let byHeight = lines.enumerated().sorted { lhs, rhs in
            if lhs.element.box.midY != rhs.element.box.midY { return lhs.element.box.midY > rhs.element.box.midY }
            return lhs.offset < rhs.offset
        }
        var rows: [[(offset: Int, element: RecognizedLabelLine)]] = []
        for entry in byHeight {
            if let anchor = rows.last?.first {
                let tolerance = max(anchor.element.box.height, entry.element.box.height) * 0.5
                if abs(anchor.element.box.midY - entry.element.box.midY) < tolerance {
                    rows[rows.count - 1].append(entry)
                    continue
                }
            }
            rows.append([entry])
        }
        return rows.flatMap { row in
            row.sorted { lhs, rhs in
                if lhs.element.box.minX != rhs.element.box.minX { return lhs.element.box.minX < rhs.element.box.minX }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    /// How big this line is printed, 1...9 against the largest text on the label — or 0 when the
    /// photo carried no geometry at all.
    ///
    /// On a supplement bottle, print size *is* the hierarchy: the brand and product name are set
    /// large, the Supplement Facts panel small, the disclaimer smallest. Giving the model that
    /// ranking replaces guesswork with the same cue a person reads the bottle by.
    static func sizeRank(_ line: RecognizedLabelLine, in lines: [RecognizedLabelLine]) -> Int {
        let heights = lines.map(\.box.height).filter { $0 > 0 }
        guard let largest = heights.max(), let smallest = heights.min(), line.box.height > 0 else { return 0 }
        guard largest > smallest else { return 9 }
        let position = (line.box.height - smallest) / (largest - smallest)
        return min(9, max(1, Int((position * 8).rounded()) + 1))
    }

    /// The text actually sent to the model: reading order, each line prefixed with its print size.
    ///
    /// Replaces a blind `prefix(4000)` on the joined text, which cut mid-word and mid-panel — the
    /// Supplement Facts block sits in the middle of many labels, so a front-truncation could drop
    /// exactly the dose being looked for while keeping the marketing copy. When the panel doesn't
    /// fit, whole lines are dropped instead, smallest print first, and any line that reads like a
    /// dose is kept to last regardless of size.
    static func promptPayload(from lines: [RecognizedLabelLine],
                              characterBudget: Int = defaultPromptBudget) -> String {
        let ordered = inReadingOrder(lines)
        let ranks = ordered.map { sizeRank($0, in: ordered) }
        func render(_ index: Int) -> String {
            ranks[index] > 0 ? "\(ranks[index])| \(ordered[index].text)" : ordered[index].text
        }
        var kept = Set(ordered.indices)
        var length = ordered.indices.reduce(0) { $0 + render($1).count + 1 }
        // Least useful first: small print that doesn't look like a dose. Ties break toward
        // dropping the longest line, which on a label is the ingredients list or the disclaimer.
        let droppingOrder = ordered.indices.sorted { lhs, rhs in
            let lhsDose = looksLikeDose(ordered[lhs].text), rhsDose = looksLikeDose(ordered[rhs].text)
            if lhsDose != rhsDose { return !lhsDose }
            if ranks[lhs] != ranks[rhs] { return ranks[lhs] < ranks[rhs] }
            return ordered[lhs].text.count > ordered[rhs].text.count
        }
        for index in droppingOrder where length > characterBudget && kept.count > 1 {
            kept.remove(index)
            length -= render(index).count + 1
        }
        return ordered.indices.filter(kept.contains).map(render).joined(separator: "\n")
    }

    /// Was a hand-picked 3,600, reverse-engineered from an assumed 4,096-token window. Now asked
    /// of the model that will actually read it, which on iOS 27 is a real number rather than a
    /// guess — and grows by itself if the label goes to a model with more room.
    static var defaultPromptBudget: Int {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return Intelligence.promptCharacterBudget(for: .device)
        }
        #endif
        return 3_600
    }

    static func looksLikeDose(_ text: String) -> Bool {
        doseLikePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Deterministic fallback (model unavailable)

    /// No FoundationModels: "the biggest print is probably the product name, the first line that
    /// reads like a dose is probably the serving." Crude, but it never invents text, and every
    /// field it produces traces to exactly one recognized line — so its confidence is that line's
    /// own OCR confidence, not a guess about extraction quality.
    ///
    /// Biggest print, specifically — not the longest line, which is what this used to pick. The
    /// longest line on a supplement label is the "Other Ingredients" list or the FDA disclaimer,
    /// essentially never the product name, so the old rule was close to guaranteed to be wrong on
    /// exactly the labels that reach this path. With no geometry at all (a text-only fixture),
    /// length is the only signal left and the old rule still applies.
    static func deterministicRecord(from lines: [RecognizedLabelLine]) -> SupplementLabelRecord {
        let ordered = inReadingOrder(lines)
        let largest = ordered.max { lhs, rhs in
            lhs.box.height == rhs.box.height ? lhs.text.count < rhs.text.count : lhs.box.height < rhs.box.height
        }
        let name = largest.map { SupplementLabelField(value: $0.text, confidence: $0.confidence) }
        let dose = ordered.first { looksLikeDose($0.text) }
            .map { SupplementLabelField(value: $0.text, confidence: $0.confidence) }
        return SupplementLabelRecord(name: name, dose: dose)
    }

    private static let doseLikePattern = try! NSRegularExpression(
        pattern: #"\d+\s*(mg|mcg|iu|billion|cfu|capsule|tablet|softgel|serving)"#, options: [.caseInsensitive])

    // MARK: - Structured extraction -> confidence attribution

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private static func structuredRecord(from generated: GeneratedSupplementLabel, lines: [RecognizedLabelLine]) -> SupplementLabelRecord {
        func trimmed(_ value: String?) -> String? {
            guard let value else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        let productName = trimmed(generated.productName)
        let brand = trimmed(generated.brand)
        let name: SupplementLabelField? = {
            switch (productName, brand) {
            case (nil, nil): return nil
            case (let name?, nil): return .init(value: name, confidence: confidence(forValue: name, in: lines))
            case (nil, let brand?): return .init(value: brand, confidence: confidence(forValue: brand, in: lines))
            case (let name?, let brand?):
                let combined = BarcodeProductLookup.combinedName(brand: brand, product: name)
                let nameConfidence = confidence(forValue: name, in: lines)
                let brandConfidence = confidence(forValue: brand, in: lines)
                return .init(value: combined, confidence: min(nameConfidence, brandConfidence))
            }
        }()

        let dose = trimmed(generated.servingAndDose).map {
            SupplementLabelField(value: $0, confidence: confidence(forValue: $0, in: lines))
        }

        return SupplementLabelRecord(name: name, dose: dose)
    }
    #endif

    /// Traces a value the model extracted back to the recognized line(s) it most likely came
    /// from, and uses THAT line's OCR confidence — never a model-side confidence, which doesn't
    /// exist for this kind of structured generation and would be the wrong signal even if it
    /// did. A value that can't be traced to any single line at all (the model paraphrased,
    /// combined two languages' lines, or normalized punctuation) falls back to the weakest
    /// overlapping line's confidence rather than an assumed-good default — the whole point of
    /// this score is to never claim confidence the pipeline can't actually back up. Pure and
    /// independent of FoundationModels/Vision, so it's covered directly by tests.
    static func confidence(forValue value: String, in lines: [RecognizedLabelLine]) -> Double {
        guard !value.isEmpty, !lines.isEmpty else { return 0 }
        if let exact = lines.first(where: {
            $0.text.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }) {
            return exact.confidence
        }
        // Weighted by how much of the value each line actually accounts for, not by whether any
        // single word happens to appear. A bare `isDisjoint` check let one incidental word — the
        // "vitamin" inside a disclaimer, the "mg" inside a footnote — drag a well-read field down
        // to that unrelated line's confidence, which reads to the person as a good field wrongly
        // flagged amber. Lines are taken best-coverage-first until the value is accounted for,
        // and the score is the weakest line that genuinely contributed.
        let valueWords = wordSet(value)
        guard !valueWords.isEmpty else { return lines.map(\.confidence).min() ?? 0 }
        let scored = lines.map { (line: $0, covered: wordSet($0.text).intersection(valueWords)) }
            .filter { !$0.covered.isEmpty }
            .sorted { $0.covered.count > $1.covered.count }
        guard !scored.isEmpty else { return lines.map(\.confidence).min() ?? 0 }
        var accounted: Set<String> = []
        var contributors: [Double] = []
        for entry in scored {
            // A line that adds nothing new isn't a contributor, however many words it echoes.
            guard !entry.covered.isSubset(of: accounted) else { continue }
            accounted.formUnion(entry.covered)
            contributors.append(entry.line.confidence)
            if Double(accounted.count) / Double(valueWords.count) >= 0.8 { break }
        }
        return contributors.min() ?? scored[0].line.confidence
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private static let visionInstructions = """
    You are looking at a photograph of a dietary supplement bottle. Read what is printed on it. \
    Extract only text that is actually visible — never invent, calculate, or guess a dose, count, \
    or percentage that is not printed, and leave a field blank rather than guessing at it. The \
    label may be printed in more than one language; pick whichever language's text is clearest for \
    each field and never merge words from two languages into one field. Combine the serving size \
    and its active dose into one short phrase, e.g. '2 capsules — 1000 mg'.
    """

    private static let instructions = """
    You read a dietary supplement's label from OCR text captured off a bottle photo, one \
    recognized line per line of input. The lines are in reading order, top of the label first. \
    Each line is prefixed with "N| " where N is how large that text is printed, 9 being the \
    largest type on the label and 1 the smallest. Use that: on a supplement bottle the brand and \
    product name are set in the largest type, the Supplement Facts panel in small type, and the \
    disclaimer and ingredient list smallest of all. The longest line is almost never the product \
    name. Do not include the "N| " prefix in any value you return. The panel may be printed in \
    more than one \
    language on the same label — European packaging routinely repeats every line in two or three \
    languages; pick whichever single language's line is clearest for each field and never merge \
    words from two languages into one field. Extract only text that is actually present in the \
    lines below — never invent, calculate, or guess a dose, count, or percentage that is not \
    printed. If a field isn't legible or present, leave it blank rather than guessing. Combine \
    the serving size and its active dose into one short phrase, e.g. '2 capsules — 1000 mg'.
    """
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
private struct GeneratedSupplementLabel {
    @Guide(description: "The product name as printed, without the brand name and without pack size or count — normally among the largest type on the label (a high size prefix), near the top. E.g. 'Zinc Picolinate'. Blank if not legible.")
    var productName: String?
    @Guide(description: "The brand name as printed — normally the largest type of all, at the very top. E.g. 'NOW Foods'. Blank if not legible.")
    var brand: String?
    @Guide(description: "The serving size and active dose combined into one short phrase exactly as printed, e.g. '2 capsules — 1000 mg'. Both normally come from the small-type Supplement Facts panel, not from the large-type front of the bottle. Blank if not legible.")
    var servingAndDose: String?
}
#endif
#endif
