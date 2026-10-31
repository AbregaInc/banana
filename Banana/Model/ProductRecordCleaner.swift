import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tidies a merged product record's `name`/`brand`/`serving` text before it reaches the person —
/// the "records that do come back have poor names" half of the barcode-scanner fix. Every
/// candidate database record has already been through `BarcodeProductLookup.mergeFields(_:)`;
/// this is purely a text-cleanup pass on the winner, never a second chance to pick a different
/// value. It never invents a fact: given "Fish oil" it stays "Fish oil" (a genuinely generic name
/// is left alone rather than embellished), and it never touches a nutrition number at all — only
/// `name`, `brand`, and `serving` pass through here.
///
/// Same call shape as `CreditsExtractor`/`FoodTextExtractor`: try Apple's on-device model first,
/// fall back to a deterministic cleanup when it's unavailable or fails for any reason. Unlike
/// those two, the fallback here isn't a blank/manual state — `deterministicClean(name:brand:serving:)`
/// is a complete, always-available implementation of the same three measured rules (strip a
/// repeated brand, strip pack size/count, fix an all-caps field), so a device without Apple
/// Intelligence still gets real cleanup, just a less nuanced one. `usedModel` on the result says
/// which path ran, so the UI can say so rather than silently presenting a fallback as if the
/// model had reviewed it.
enum ProductRecordCleaner {
    struct CleanedFields: Equatable, Sendable {
        var name: String
        var brand: String
        var serving: String
        var usedModel: Bool
    }

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    static func clean(name: String, brand: String, serving: String) async -> CleanedFields {
        guard modelAvailable else {
            return deterministicClean(name: name, brand: brand, serving: serving)
        }

        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let prompt = """
                Raw name: \(name.prefix(300))
                Raw brand: \(brand.prefix(150))
                Raw serving: \(serving.prefix(150))
                """
                let response = try await session.respond(to: prompt, generating: GeneratedCleanRecord.self)
                return response.content.asCleanedFields(fallbackName: name, fallbackBrand: brand, fallbackServing: serving)
            } catch {
                // Refusal, decoding failure, exceeded context window (this prompt is short, but
                // never assume) — every failure lands on the deterministic cleanup rather than
                // presenting the raw, uncleaned text.
                return deterministicClean(name: name, brand: brand, serving: serving)
            }
        }
        #endif
        return deterministicClean(name: name, brand: brand, serving: serving)
    }

    // MARK: - Deterministic fallback

    /// Rule-based cleanup covering exactly the three patterns the measurement identified as
    /// common and mechanical enough to fix without a model: a name that repeats the brand it's
    /// already shown next to, a name that embeds the pack size or unit count ("- 250ct", "150
    /// Tablets"), and a field that's SHOUTING because a source stored it as all-caps. Never
    /// rewrites a name it isn't confident about — a mixed-case oddity like "grass fed COLLAGEN
    /// PEPTIDES" is left as the source wrote it rather than guessed at, which is exactly the
    /// model's job when it's available.
    static func deterministicClean(name: String, brand: String, serving: String) -> CleanedFields {
        let cleanedBrand = BarcodeProductLookup.displayText(brand)

        var cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedName = strippingLeadingBrand(cleanedName, brand: cleanedBrand)
        cleanedName = strippingPackSizeAndCount(cleanedName)
        cleanedName = collapsingWhitespace(cleanedName)
        cleanedName = BarcodeProductLookup.displayText(cleanedName)
        if cleanedName.isEmpty { cleanedName = BarcodeProductLookup.displayText(name) }

        return CleanedFields(name: cleanedName, brand: cleanedBrand,
                             serving: serving.trimmingCharacters(in: .whitespacesAndNewlines), usedModel: false)
    }

    /// Drops a brand mention from the *start* of a name — the shape every real duplicate in the
    /// measurement data took ("Solgar Fórmula Vm-75-60" next to brand "Solgar", "NATURE MADE
    /// Melatonin…" next to brand "Nature Made"). Deliberately anchored to the start rather than
    /// stripping any occurrence anywhere: a brand name that happens to also be a common word
    /// ("NOW Foods") could otherwise strip a legitimate part of the product name mid-string.
    private static func strippingLeadingBrand(_ name: String, brand: String) -> String {
        guard !brand.isEmpty,
              let range = name.range(of: brand, options: [.caseInsensitive, .diacriticInsensitive, .anchored])
        else { return name }
        let rest = name[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "-:|,·—").union(.whitespaces))
        // Never reduce the name to nothing — a source that only ever wrote the brand name itself
        // (no separate product text at all) should keep showing that text rather than go blank.
        return rest.isEmpty ? name : rest
    }

    /// Strips a trailing/parenthetical pack size or unit count — "- 250ct", ", 240 Softgels",
    /// "(150ct)" — while leaving a per-serving dose amount like "2000 IU" or "400 mg" alone: the
    /// pattern only matches count-style units (tablets, capsules, softgels, count, servings,
    /// packs…), never the mass/potency units a real dose is expressed in.
    private static func strippingPackSizeAndCount(_ name: String) -> String {
        let cleaned = packSizePattern.stringByReplacingMatches(
            in: name, options: [], range: NSRange(name.startIndex..., in: name), withTemplate: "")
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-:|,()").union(.whitespaces))
    }

    private static let packSizePattern = try! NSRegularExpression(
        pattern: #"[\s,;:\-–\(]*\b\d+(\.\d+)?\s*-?\s*(ct|count|tabs?|tablets?|capsules?|caps?|vcaps?|softgels?|gummy|gummies|lozenges?|servings?|packs?)\.?\)?\b"#,
        options: [.caseInsensitive])

    private static func collapsingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static let instructions = """
    You clean up a dietary supplement's name, brand, and serving text pulled from a product \
    database. Fix these exact problems, and nothing else: if the name repeats the brand (the \
    brand will be shown separately, right next to the name), remove that repeated part from the \
    name. Remove pack size and unit counts from the name (e.g. "- 250ct", "150 Tablets 50 \
    Servings") — but never remove a dose amount like "5000 IU" or "400 mg", that is part of the \
    product's identity. If a field is written in ALL CAPITALS, fix its capitalization to normal \
    title case. If the name is already short and generic (e.g. "Fish oil"), leave it exactly as \
    is — do not invent extra detail, a category, or a flavor that wasn't in the source text. \
    Never invent, calculate, or guess a number, dose, or fact that is not already present in the \
    raw text you were given. Keep the serving text as given, just trimmed and formatted.
    """
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedCleanRecord {
    @Guide(description: "The cleaned product name: brand removed if it was repeated, pack size/count removed, capitalization fixed. Never invented or embellished.")
    var name: String
    @Guide(description: "The cleaned brand name, capitalization fixed.")
    var brand: String
    @Guide(description: "The serving text, trimmed and formatted, unchanged in meaning.")
    var serving: String?

    /// Falls back to the un-cleaned raw text per field when the model leaves that field blank —
    /// a blank name/brand from the model reads as "nothing to say," not "delete this," so the
    /// person still sees the original text rather than an empty row.
    func asCleanedFields(fallbackName: String, fallbackBrand: String, fallbackServing: String) -> ProductRecordCleaner.CleanedFields {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedServing = (serving ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            name: cleanedName.isEmpty ? fallbackName : cleanedName,
            brand: cleanedBrand.isEmpty ? fallbackBrand : cleanedBrand,
            serving: cleanedServing.isEmpty ? fallbackServing : cleanedServing,
            usedModel: true)
    }
}
#endif
