import CoreGraphics
import Foundation
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads a package photo: the Nutrition Facts panel, or the product's name off the front.
///
/// A panel is read twice: its text, recognised and parsed (`NutritionLabelParser`), and the photo
/// with that text shown to Apple's model, which fills in the same fields (`GeneratedNutritionLabel`).
/// `LabelCheck` decides between them — every number has to be printed on the label and the
/// calories have to agree with the fat, carbs and protein — and fills one's gaps from the other.
/// Where the model isn't available, the parser's reading is used as it is.
enum NutritionLabelReader {
    static func label(in image: CGImage) async -> ParsedNutritionLabel? {
        let lines = await recognized(image)
        // The panel's rows put back together first: text recognition returns "Calories" and its
        // big "210" as two pieces, the number first because its top is higher, and the same for
        // "Serving size" and its bold "1 cup (140g)" — read piece by piece, no label ever parsed.
        let rows = TextRows.rows(lines.map(\.piece), aspect: Double(image.width) / Double(max(image.height, 1)))
        let parsed = NutritionLabelParser.parse(rows) ?? NutritionLabelParser.parse(lines.map(\.text))
        let printed = rows.joined(separator: "\n")
        // Read cleanly, it's done: the model takes seconds, and would only say the same.
        if let parsed, LabelCheck.settled(parsed, printed: printed) {
            await Telemetry.shared.record(.feature(.labelRead, .parser))
            return parsed
        }
        let read = await modelLabel(image, text: rows)
        let chosen = LabelCheck.choose(parsed: parsed, read: read, printed: printed)
        await Telemetry.shared.record(chosen == nil ? .failure(.labelRead)
                                      : .feature(.labelRead, chosen == parsed ? .parser : .model))
        return chosen
    }

    /// The panel as Apple's model reads it off the photo, shown the recognised text too. Nil
    /// where no model can look at a photo, or it gives up or takes too long.
    static func modelLabel(_ image: CGImage, text rows: [String]) async -> ParsedNutritionLabel? {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return nil }
        guard let (session, route) = await Intelligence.session(for: .vision, instructions: labelInstructions) else { return nil }
        // Small print needs the pixels: larger than a meal photo is sent.
        let photo = GroundedFoodEstimate.scaled(image, maxPixels: 1_280)
        let text = String(rows.joined(separator: "\n").prefix(2_400))
        do {
            let answer = try await Intelligence.withTimeout(seconds: 25, route: route) {
                try await session.respond(generating: GeneratedNutritionLabel.self, options: .init(temperature: 0)) {
                    "Read this Nutrition Facts panel. Text recognised on it, row by row:\n\(text)"
                    Attachment(photo).label("photo of a Nutrition Facts panel")
                }.content
            }
            return answer.label
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static let labelInstructions = """
    You read US Nutrition Facts panels from photos and copy their numbers exactly as printed, \
    per serving. Never estimate or calculate a number that isn't printed; use 0 for one that isn't.
    """

    /// The product's name from a photo of its front: the biggest words on it, in reading order.
    /// "TRADER JOE'S" over "PUMPKIN GNOCCHI" → "Trader Joe's Pumpkin Gnocchi". Weights, claims and
    /// small print are smaller and left out.
    static func productName(in image: CGImage) async -> String? {
        let lines = await recognized(image)
        return ProductNameReading.name(from: lines.map { ($0.text, $0.height, $0.top) })
    }

    private struct Line {
        var text: String
        var height: Double
        var top: Double
        var piece: TextRows.Piece
    }

    private static func recognized(_ image: CGImage) async -> [Line] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap { observation -> Line? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                // Vision's boxes are normalised with the origin at the bottom left.
                // Its corners follow the text's slant, top down like the rest.
                func flipped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
                return Line(text: text, height: observation.boundingBox.height, top: 1 - observation.boundingBox.maxY,
                            piece: TextRows.Piece(text: text, topLeft: flipped(observation.topLeft),
                                                  topRight: flipped(observation.topRight),
                                                  bottomLeft: flipped(observation.bottomLeft),
                                                  bottomRight: flipped(observation.bottomRight)))
            }.sorted { $0.top < $1.top }
        }.value
    }
}

/// Pieces of recognised text put back into the rows they were printed on: pieces that share most
/// of their height are one row, read left to right — measured along the text's own slant, since a
/// label photographed a few degrees off level otherwise pairs each number with the row above.
/// Corners are the image's, 0–1, top down; `aspect` is its width over its height. Pure, for tests.
enum TextRows {
    struct Piece {
        var text: String
        var topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint
    }

    static func rows(_ pieces: [Piece], aspect: Double = 1) -> [String] {
        // The slant: the middle of the pieces' baselines, the longer ones counting (short ones,
        // a "4%", are a few pixels wide and their angle is noise).
        let angles = pieces.compactMap { piece -> Double? in
            let dx = Double(piece.bottomRight.x - piece.bottomLeft.x) * aspect
            let dy = Double(piece.bottomRight.y - piece.bottomLeft.y)
            return dx > 0.05 * aspect ? atan2(dy, dx) : nil
        }.sorted()
        let angle = angles.isEmpty ? 0 : angles[angles.count / 2]
        let (c, s) = (cos(angle), sin(angle))
        // Turned level: down the turned page, and across it.
        func level(_ p: CGPoint) -> (x: Double, y: Double) {
            let x = Double(p.x) * aspect, y = Double(p.y)
            return (x * c + y * s, y * c - x * s)
        }

        struct Row { var top: Double; var bottom: Double; var pieces: [(text: String, left: Double)] }
        let levelled = pieces.map { piece -> (text: String, left: Double, top: Double, bottom: Double) in
            let corners = [piece.topLeft, piece.topRight, piece.bottomLeft, piece.bottomRight].map(level)
            return (piece.text, corners.map(\.x).min() ?? 0, corners.map(\.y).min() ?? 0, corners.map(\.y).max() ?? 0)
        }
        var rows: [Row] = []
        for piece in levelled.sorted(by: { $0.top + $0.bottom < $1.top + $1.bottom }) {
            let height = max(piece.bottom - piece.top, 0.000_1)
            // The row this piece shares the most height with, if it shares at least half of the
            // shorter of the two: a tall "210" beside a shorter "Calories" is one row; the next
            // line of small print, overlapping a few pixels, isn't.
            let best = rows.indices.map { index -> (index: Int, overlap: Double) in
                let row = rows[index]
                let overlap = min(row.bottom, piece.bottom) - max(row.top, piece.top)
                return (index, overlap / min(height, row.bottom - row.top))
            }.max { $0.overlap < $1.overlap }
            if let best, best.overlap >= 0.5 {
                rows[best.index].pieces.append((piece.text, piece.left))
                rows[best.index].top = min(rows[best.index].top, piece.top)
                rows[best.index].bottom = max(rows[best.index].bottom, piece.bottom)
            } else {
                rows.append(Row(top: piece.top, bottom: piece.bottom, pieces: [(piece.text, piece.left)]))
            }
        }
        return rows.sorted { $0.top < $1.top }
            .map { $0.pieces.sorted { $0.left < $1.left }.map(\.text).joined(separator: " ") }
    }
}

/// Picking a product's name out of the text on its front. Pure, for tests.
enum ProductNameReading {
    static func name(from lines: [(text: String, height: Double, top: Double)]) -> String? {
        let words = lines.filter { line in
            let letters = line.text.filter(\.isLetter).count
            return letters >= 2 && Double(letters) >= Double(line.text.count) * 0.6
                && line.text.range(of: #"\b(net\s*wt|oz|g|kcal|calories|per)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
        guard let tallest = words.map(\.height).max(), tallest > 0 else { return nil }
        let big = words.filter { $0.height >= tallest * 0.55 }.sorted { $0.top < $1.top }.prefix(4)
        let name = big.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard name.count >= 3 else { return nil }
        return titled(String(name.prefix(60)))
    }

    /// "TRADER JOE'S PUMPKIN GNOCCHI" → "Trader Joe's Pumpkin Gnocchi". Mixed case is left alone.
    static func titled(_ text: String) -> String {
        guard text == text.uppercased() else { return text }
        return text.lowercased().split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// Choosing between two readings of a panel — the parser's and the model's — by what's printed
/// and what adds up. Pure, for tests.
enum LabelCheck {
    /// The parser's reading where it holds up, with any fat, carbs or protein it missed taken from
    /// the model's (when printed); else the model's where that holds up; else the parser's as it is.
    static func choose(parsed: ParsedNutritionLabel?, read: ParsedNutritionLabel?, printed: String) -> ParsedNutritionLabel? {
        let numbers = printedNumbers(printed)
        let parsedHolds = parsed.map { holds($0, numbers: numbers) } ?? false
        let readHolds = read.map { holds($0, numbers: numbers) } ?? false
        if parsedHolds, var label = parsed {
            if let read, readHolds {
                var macros = label.perServing
                if macros.fatGrams == 0, numbers.contains(read.perServing.fatGrams) { macros.fatGrams = read.perServing.fatGrams }
                if macros.carbohydrateGrams == 0, numbers.contains(read.perServing.carbohydrateGrams) {
                    macros.carbohydrateGrams = read.perServing.carbohydrateGrams
                }
                if macros.proteinGrams == 0, numbers.contains(read.perServing.proteinGrams) { macros.proteinGrams = read.perServing.proteinGrams }
                var filled = label
                filled.perServing = macros
                if label.servingsPerContainer == nil { filled.servingsPerContainer = read.servingsPerContainer }
                if holds(filled, numbers: numbers) { label = filled }
            }
            return label
        }
        if readHolds { return read }
        return parsed
    }

    /// Read cleanly: it holds up, and fat, carbs and protein were all found. (A 0 might be a line
    /// that wasn't read; the model is asked then.)
    static func settled(_ label: ParsedNutritionLabel, printed: String) -> Bool {
        let m = label.perServing
        return holds(label, numbers: printedNumbers(printed)) && m.fatGrams > 0 && m.carbohydrateGrams > 0 && m.proteinGrams > 0
    }

    /// Believable as a panel: a serving's weight and calories that are printed on it, nothing
    /// heavier than the serving, and calories within a fifth (or 25) of 4 per gram of carbs and
    /// protein and 9 of fat — labels round, and fibre counts for less.
    static func holds(_ label: ParsedNutritionLabel, numbers: Set<Double>) -> Bool {
        let m = label.perServing
        guard label.servingGrams >= 1, label.servingGrams <= 2_000,
              m.calories >= 0, m.calories <= 2_000,
              numbers.contains(label.servingGrams), numbers.contains(m.calories),
              [m.fatGrams, m.carbohydrateGrams, m.proteinGrams].allSatisfy({ $0 >= 0 }),
              m.fatGrams + m.carbohydrateGrams + m.proteinGrams <= label.servingGrams * 1.05 else { return false }
        return addsUp(m)
    }

    /// The calories within a fifth (or 25) of 4 per gram of carbs and protein and 9 of fat. A
    /// reading with its fat, carbs or protein missed doesn't.
    static func addsUp(_ m: NutritionMacros) -> Bool {
        let fromMacros = 4 * (m.carbohydrateGrams + m.proteinGrams) + 9 * m.fatGrams
        return abs(fromMacros - m.calories) <= max(25, 0.2 * m.calories)
    }

    /// Every number printed: "3.5g" → 3.5, "1,200" → 1200.
    static func printedNumbers(_ text: String) -> Set<Double> {
        let plain = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return [] }
        return Set(regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap {
            Range($0.range, in: plain).flatMap { Double(plain[$0]) }
        })
    }
}

/// How many servings of a scanned food the meal's photo shows — asked of the on-device model,
/// which sees the photo and is told what one serving is. Nil when there's no model that can see,
/// it can't tell, or it takes too long: the amount then comes from your usual
/// (`ScanCorrection.startingGrams`).
enum ServingsFromPhoto {
    static let timeoutSeconds: UInt64 = 20

    /// Whether this device's own model can look at a photo.
    @MainActor
    static var canLook: Bool {
        #if canImport(FoundationModels)
        guard #available(iOS 27, macOS 27, visionOS 27, watchOS 27, *) else { return false }
        let availability = Intelligence.current
        return availability.deviceAvailable && availability.deviceSupportsVision
        #else
        return false
        #endif
    }

    @MainActor
    static func servings(of food: MyFood, in photos: [CGImage]) async -> Double? {
        #if canImport(FoundationModels)
        guard !photos.isEmpty, #available(iOS 27, macOS 27, visionOS 27, watchOS 27, *) else { return nil }
        let availability = Intelligence.current
        guard availability.deviceAvailable, availability.deviceSupportsVision else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let small = photos.prefix(2).map { GroundedFoodEstimate.scaled($0, maxPixels: 768) }
        let prompt = prompt(for: food)
        do {
            let answer: GeneratedServings = try await Intelligence.withTimeout(seconds: timeoutSeconds, route: .device) {
                let attachments = small.map { Attachment($0).label("photo of the meal") }
                return try await session.respond(generating: GeneratedServings.self, options: .init(temperature: 0)) {
                    prompt
                    for attachment in attachments { attachment }
                }.content
            }
            return plausible(answer.servings, food: food)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static func prompt(for food: MyFood) -> String {
        var text = "The food: \(food.name). One serving is \(food.servingLabel) (\(Int(food.servingGrams.rounded())) g)."
        if let package = food.packageGrams, food.servingGrams > 0 {
            let servings = package / food.servingGrams
            text += " A whole package is about \(String(format: "%g", (servings * 4).rounded() / 4)) servings."
        }
        return text + " How many servings of it are in the photo?"
    }

    /// In quarters, between a quarter and a package and a half (or eight servings without one).
    /// Zero — it isn't in the photo — is no answer.
    static func plausible(_ servings: Double, food: MyFood) -> Double? {
        guard servings.isFinite, servings > 0 else { return nil }
        let most = food.packageGrams.map { max(1, $0 / max(food.servingGrams, 1) * 1.5) } ?? 8
        let quarters = (servings / ScanCorrection.step).rounded() * ScanCorrection.step
        return min(max(ScanCorrection.step, quarters), most)
    }

    static let instructions = """
    You look at photos of a meal and say how much of one packaged food is in it, in servings as \
    its label defines them. Judge by the plate, bowl and the food's own size. If the food isn't \
    in the photo, answer 0.
    """
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedNutritionLabel {
    @Guide(description: "The serving size as printed, without its weight, e.g. \"1 cup\", \"2/3 cup\", \"6 pieces\"")
    var servingSize: String
    @Guide(description: "The serving's weight in grams, as printed in brackets after the serving size, e.g. 140 for \"(140g)\"; 0 if not printed")
    var servingGrams: Double
    @Guide(description: "Servings per container as printed; 0 if not printed")
    var servingsPerContainer: Double
    @Guide(description: "Calories per serving")
    var calories: Double
    @Guide(description: "Total Fat per serving, in grams")
    var fatGrams: Double
    @Guide(description: "Total Carbohydrate per serving, in grams")
    var carbohydrateGrams: Double
    @Guide(description: "Protein per serving, in grams")
    var proteinGrams: Double

    var label: ParsedNutritionLabel? {
        guard servingGrams > 0 else { return nil }
        let size = servingSize.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedNutritionLabel(servingLabel: size.isEmpty ? "1 serving" : size, servingGrams: servingGrams,
                                    servingsPerContainer: servingsPerContainer > 0 ? servingsPerContainer : nil,
                                    perServing: NutritionMacros(calories: calories, proteinGrams: proteinGrams,
                                                                carbohydrateGrams: carbohydrateGrams, fatGrams: fatGrams))
    }
}

@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedServings {
    @Guide(description: "How many servings of the food are in the photo, in quarters, e.g. 1.5; 0 if it isn't there")
    var servings: Double
}
#endif
