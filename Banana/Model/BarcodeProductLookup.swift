import Foundation
import OSLog
import SQLite3

struct BarcodeProduct: Equatable, Codable, Sendable {
    var barcode: String
    var name: String
    var serving: String
    /// `nil` when the source had no calorie/macro data at all — the normal case for a dietary
    /// supplement, which carries an FDA Supplement Facts panel rather than a Nutrition Facts
    /// label. Never coerce this to zeroed macros: a missing value and a verified zero are
    /// different facts, and a confident "0 kcal" for, say, a multivitamin would be a claim the
    /// label never made. Callers must treat `nil` as "no data", not as failure — the product
    /// itself (name, brand, serving) is still a successful match.
    ///
    /// **For one `serving`** — from every source. The bundled catalog stores it that way; Open
    /// Food Facts gives nutrition per 100 g, which is scaled to the serving on the way in
    /// (`BarcodeProductLookup.servingAndMacros`). It wasn't, once: a 50 g egg was 140 kcal.
    var macros: NutritionMacros?
    /// Which source contributed the final `name` and `serving` text, so a caller can tell the
    /// person where a value came from instead of a single opaque "found online" caption — see
    /// `ProductDataSource`. `Optional` (rather than a plain default) purely so an on-disk cache
    /// entry written before this field existed still decodes: a missing key becomes `nil`
    /// automatically for an `Optional` property, no custom `Codable` needed.
    var nameSource: ProductDataSource?
    var servingSource: ProductDataSource?
    /// `false` when Apple's on-device model was unavailable (or failed) and the deterministic
    /// fallback tidied `name` instead — see `ProductRecordCleaner`. `nil`/`true` both read as
    /// "the model did it" so a legacy cache entry, which predates this field, isn't misreported
    /// as a fallback that never actually ran.
    var nameCleanedByModel: Bool?
    /// The active ingredients, as NIH's DSLD normalises them — "Zinc", "Cholecalciferol",
    /// "Ferrous Fumarate" — empty for every other source, none of which carries a structured
    /// Supplement Facts panel.
    ///
    /// This is what lets `SupplementInteractions` see inside a bottle whose NAME gives nothing
    /// away. "Men's Daily Multivitamin" contains iron, calcium and zinc and says none of them;
    /// matching on the name alone would never flag it against a calcium tablet, and a warning
    /// system that silently misses the single most common supplement in the cupboard is worse
    /// than no warning at all. `Optional` so cache entries written before this field decode.
    var ingredients: [String]?
    /// The same nutrition per 100 g, when the source gives it that way (Open Food Facts) — so
    /// nothing downstream has to work it back out from the serving.
    var per100g: NutritionMacros?
    /// The package's net weight in grams ("72 g"), when the source gives one. Not a serving.
    var packageGrams: Double?
    /// `false` when the source gives nutrition per 100 g and no serving: `serving` is then
    /// "100 g", the one amount the numbers are true of. `nil` reads as stated — the bundled
    /// catalog, and anything cached before this field.
    var servingStated: Bool?
}

/// Where one field of a `BarcodeProduct` came from. Surfaced in the UI so a reviewer can tell a
/// curated supplement-label transcription from a crowd-sourced grocery database entry.
enum ProductDataSource: String, Codable, Hashable, Sendable {
    case bundledCatalog
    case openFoodFacts
    case dsld
    case upcItemDB

    var displayName: String {
        switch self {
        case .bundledCatalog: return "Banana's bundled catalog"
        case .openFoodFacts: return "Open Food Facts"
        case .dsld: return "NIH's supplement label database"
        case .upcItemDB: return "UPCitemdb"
        }
    }
}

/// The five things a scan can resolve to. Deliberately not `BarcodeProduct?` — collapsing this
/// to an optional is exactly the bug this type replaces: a network hiccup and "this product
/// genuinely isn't in any source" looked identical to the person standing in their kitchen, so
/// both silently read as "nothing happened."
enum BarcodeLookupOutcome: Equatable, Sendable {
    /// Matched the bundled offline catalog — instant, no network involved.
    case foundLocally(BarcodeProduct)
    /// Matched an online source, either just now or from a previous scan's on-disk cache.
    case foundOnline(BarcodeProduct)
    /// Every reachable source was checked (or the cache had a prior online miss) and none has it.
    case notFound
    /// A source could not be reached or reasoned about (offline, timeout, server error,
    /// unparseable response). Distinct from `.notFound` on purpose: "no signal" must never read
    /// to the person scanning as "no such product."
    case networkError
    /// UPCitemdb's trial-tier limit was reached or about to be — locally paced, or reported by
    /// the service itself. Distinct from both `.notFound` and `.networkError` on purpose: a
    /// throttled scan is neither "this product doesn't exist" nor "the network is down," and
    /// collapsing it into either would misinform the person exactly the way the original
    /// `.notFound`/`.networkError` split already guards against.
    case rateLimited
}

enum BarcodeProductLookup {
    enum LookupError: LocalizedError {
        case invalidBarcode
        case catalogUnavailable
        case queryFailed

        var errorDescription: String? {
            switch self {
            case .invalidBarcode: return "That code is not a supported product barcode."
            case .catalogUnavailable: return "The local product catalog is unavailable."
            case .queryFailed: return "The local product catalog could not be read."
            }
        }
    }

    private static let log = Logger(subsystem: "com.boris.banana", category: "barcode")

    /// Four-tier lookup: the bundled catalog first (instant, offline, and where every packaged
    /// grocery item already lives), then Open Food Facts and NIH's DSLD supplement-label database
    /// concurrently (both free and effectively unlimited), and only as a last resort — because its
    /// trial tier allows roughly 100 requests a day — UPCitemdb.
    ///
    /// Banana's documented design has always been that barcode lookup makes no network request.
    /// This is the one deliberate exception, and only on a miss: the bundled USDA catalog is
    /// built from Nutrition Facts label submissions for retail groceries, and supplements carry
    /// a Supplement Facts panel under a different FDA regime — they are essentially absent from
    /// it. Without a fallback, roughly half of every supplement scan failed even after the first
    /// online fallback (Open Food Facts alone only covers about 52% of real supplement barcodes);
    /// DSLD and UPCitemdb close most of the remaining gap. The trade is scoped tightly enough to
    /// keep the original guarantee intact for the common case: a catalog hit (most packaged food)
    /// still never touches the network, a miss with no connectivity fails cleanly into
    /// `.networkError` rather than hanging, and every online result — already merged across
    /// whichever sources answered, and tidied by `ProductRecordCleaner` — is cached on disk so the
    /// *next* scan of the same product is offline and instant again, same as the catalog.
    ///
    /// Open Food Facts and DSLD are queried together and merged (see `mergeFields(_:)`) rather
    /// than the first hit winning outright: DSLD's `fullName`/`brandName` are NIH-curated label
    /// transcriptions and are consistently cleaner than Open Food Facts' crowd-sourced
    /// `product_name`, while Open Food Facts' `serving_size` is usually the better-formatted
    /// field when both happen to have it. UPCitemdb is deliberately *not* part of that merge: it
    /// is only ever queried when neither free source found anything, so its scarce daily budget
    /// is spent purely on coverage gaps, not on re-fetching a product the free sources already
    /// answered. Cancellation (the scan sheet being dismissed) propagates the same way it already
    /// did for the single Open Food Facts call: every request here is a plain `await` on
    /// `URLSession`, which aborts the underlying task the moment the enclosing `Task` is
    /// cancelled, and the caller's own `Task.isCancelled` check discards a result that lands after.
    static func lookup(_ rawBarcode: String) async throws -> BarcodeLookupOutcome {
        let barcode = try normalizedBarcode(rawBarcode)

        guard let databaseURL = Bundle.main.url(forResource: "BarcodeProducts", withExtension: "sqlite") else {
            log.error("barcode \(barcode, privacy: .public): bundled catalog missing from bundle")
            throw LookupError.catalogUnavailable
        }
        if let product = try await Task.detached(priority: .userInitiated, operation: {
            try lookup(barcode, databaseURL: databaseURL)
        }).value {
            log.notice("barcode \(barcode, privacy: .public): found locally")
            return .foundLocally(product)
        }

        if let cached = await Task.detached(priority: .userInitiated, operation: {
            BarcodeNetworkCache.product(for: barcode)
        }).value {
            log.notice("barcode \(barcode, privacy: .public): found online (cached)")
            return .foundOnline(cached)
        }

        async let offFetch = fetchFromOpenFoodFacts(barcode)
        async let dsldFetch = fetchFromDSLD(barcode)
        let (off, dsld) = await (offFetch, dsldFetch)

        var raw: [RawProductFields] = []
        var sawNetworkError = false
        for result in [off, dsld] {
            switch result {
            case .found(let fields): raw.append(fields)
            case .error: sawNetworkError = true
            case .notFound, .rateLimited: break
            }
        }

        if let merged = mergeFields(raw) {
            let product = await finishedProduct(barcode: barcode, merged: merged)
            await Task.detached(priority: .utility) { BarcodeNetworkCache.store(product) }.value
            log.notice("barcode \(barcode, privacy: .public): found online (\(merged.nameSource.rawValue, privacy: .public))")
            return .foundOnline(product)
        }

        switch await fetchFromUPCItemDB(barcode) {
        case .found(let fields):
            // `fields.name` is always non-empty here (see `parseUPCItemDBResponse`'s own guard),
            // so `mergeFields` on a single non-empty-named entry always succeeds; the `?? fields`
            // never actually triggers, it just avoids force-unwrapping a `Bool`-shaped guarantee.
            let merged = mergeFields([fields]) ?? MergedProductFields(
                name: fields.name, nameSource: .upcItemDB, brand: fields.brand,
                serving: fields.serving ?? "1 serving", servingSource: .upcItemDB, macros: nil)
            let product = await finishedProduct(barcode: barcode, merged: merged)
            await Task.detached(priority: .utility) { BarcodeNetworkCache.store(product) }.value
            log.notice("barcode \(barcode, privacy: .public): found online (upcItemDB)")
            return .foundOnline(product)
        case .rateLimited:
            log.notice("barcode \(barcode, privacy: .public): UPCitemdb rate-limited")
            return .rateLimited
        case .error:
            sawNetworkError = true
            return .networkError
        case .notFound:
            if sawNetworkError {
                log.error("barcode \(barcode, privacy: .public): lookup failed")
                return .networkError
            }
            log.notice("barcode \(barcode, privacy: .public): not found in any source")
            return .notFound
        }
    }

    /// Runs the merged record through `ProductRecordCleaner` and assembles the final
    /// `BarcodeProduct`. Split out of `lookup(_:)` purely so the two "found" branches above (the
    /// free-source merge and the UPCitemdb-alone fallback) share one code path.
    private static func finishedProduct(barcode: String, merged: MergedProductFields) async -> BarcodeProduct {
        let cleaned = await ProductRecordCleaner.clean(name: merged.name, brand: merged.brand, serving: merged.serving)
        var serving = displayServing(cleaned.serving)
        var macros = merged.macros
        var servingStated: Bool?
        if let per100g = merged.per100g {
            let worked = servingAndMacros(per100g: per100g, serving: merged.servingStated ? serving : nil,
                                          servingGrams: merged.servingGrams)
            serving = worked.serving
            macros = worked.macros
            servingStated = worked.stated ? nil : false
        }
        return BarcodeProduct(
            barcode: barcode,
            name: combinedName(brand: cleaned.brand, product: cleaned.name),
            serving: serving,
            macros: macros,
            nameSource: merged.nameSource,
            servingSource: merged.servingSource,
            nameCleanedByModel: cleaned.usedModel,
            ingredients: merged.ingredients.isEmpty ? nil : merged.ingredients,
            per100g: merged.per100g,
            packageGrams: merged.packageGrams,
            servingStated: servingStated)
    }

    static func normalizedBarcode(_ raw: String) throws -> String {
        guard raw.allSatisfy(\.isNumber), raw.count >= 8, raw.count <= 14 else {
            log.notice("barcode scan: not a recognised product barcode format")
            throw LookupError.invalidBarcode
        }
        return raw
    }

    static func lookup(_ normalizedBarcode: String, databaseURL: URL) throws -> BarcodeProduct? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { throw LookupError.catalogUnavailable }
        defer { sqlite3_close(database) }

        let sql = "SELECT barcode, name, brand, serving, calories, protein, carbs, fat FROM products WHERE barcode = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw LookupError.queryFailed }
        defer { sqlite3_finalize(statement) }

        for candidate in barcodeCandidates(normalizedBarcode) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, candidate, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                throw LookupError.queryFailed
            }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let barcode = text(statement, column: 0)
                let rawName = text(statement, column: 1)
                let brand = text(statement, column: 2)
                let serving = displayServing(text(statement, column: 3))
                return BarcodeProduct(
                    barcode: barcode,
                    name: combinedName(brand: brand, product: rawName),
                    serving: serving,
                    macros: .init(
                        calories: sqlite3_column_double(statement, 4),
                        proteinGrams: sqlite3_column_double(statement, 5),
                        carbohydrateGrams: sqlite3_column_double(statement, 6),
                        fatGrams: sqlite3_column_double(statement, 7)).sanitized,
                    nameSource: .bundledCatalog,
                    servingSource: .bundledCatalog,
                    nameCleanedByModel: nil)
            case SQLITE_DONE:
                continue
            default:
                throw LookupError.queryFailed
            }
        }
        return nil
    }

    // MARK: - Per-source raw fields + merge (requirement: merge across sources, not first-wins)

    /// One source's contribution before merge. `name`/`brand` are the source's own text, not yet
    /// combined into one display string (that happens once, after cleanup, in
    /// `finishedProduct(barcode:merged:)`) — kept separate here specifically so
    /// `ProductRecordCleaner` can still see which part of a source's name is a redundant brand
    /// mention even after two sources' fields have already been picked apart and recombined.
    struct RawProductFields: Equatable, Sendable {
        var source: ProductDataSource
        var name: String
        var brand: String
        /// `nil` when this source had no serving/size text at all — distinct from an empty
        /// string, which would incorrectly win a "first non-empty" merge against a real value
        /// from another source.
        var serving: String?
        /// Per serving. No online source gives it: Open Food Facts' is `per100g`.
        var macros: NutritionMacros?
        /// Only DSLD populates this — it is the one source with a structured ingredient panel.
        var ingredients: [String] = []
        /// Nutrition per 100 g — how Open Food Facts gives it.
        var per100g: NutritionMacros? = nil
        /// What the serving weighs in grams, when the source says so apart from its text.
        var servingGrams: Double? = nil
        /// The package's net weight in grams.
        var packageGrams: Double? = nil
    }

    struct MergedProductFields: Equatable, Sendable {
        var name: String
        var nameSource: ProductDataSource
        var brand: String
        var serving: String
        var servingSource: ProductDataSource
        var macros: NutritionMacros?
        var ingredients: [String] = []
        var per100g: NutritionMacros? = nil
        var servingGrams: Double? = nil
        var packageGrams: Double? = nil
        /// Whether any source said what a serving is; false when `serving` is only the default.
        var servingStated = true
    }

    /// Combines however many sources answered for one barcode into a single record, taking the
    /// best non-empty value per field instead of letting whichever source answered first win
    /// outright. Order matters per field, not globally: DSLD is tried first for `name`/`brand`
    /// (its label transcriptions were 100% complete and consistently clean on every measured
    /// hit — Open Food Facts' `product_name` was bare-generic on roughly a third of its hits by
    /// comparison), while Open Food Facts is tried first for `serving` (its `serving_size` field,
    /// when present, is already a clean short phrase like "1 scoop (35 g)"; DSLD's structured
    /// serving sizes are reliable but need synthesis into a string that reads a little more like
    /// a database export). `macros` only ever comes from Open Food Facts — neither DSLD nor
    /// UPCitemdb carry a Nutrition Facts panel at all.
    ///
    /// Pure and source-agnostic: called with `[openFoodFacts, dsld]` results from the main
    /// cascade, and again with a single-element `[upcItemDB]` array for the last-resort tier —
    /// both go through the exact same field-selection logic.
    static func mergeFields(_ results: [RawProductFields]) -> MergedProductFields? {
        guard !results.isEmpty else { return nil }
        let dsldFirst = results.sorted { rank(dsldFirst: true, $0) < rank(dsldFirst: true, $1) }
        let offFirst = results.sorted { rank(dsldFirst: false, $0) < rank(dsldFirst: false, $1) }

        func firstNonEmpty(_ ordered: [RawProductFields], _ field: (RawProductFields) -> String?) -> (String, ProductDataSource)? {
            for candidate in ordered {
                if let value = field(candidate), !value.isEmpty { return (value, candidate.source) }
            }
            return nil
        }

        guard let (name, nameSource) = firstNonEmpty(dsldFirst, { $0.name }) else { return nil }
        let brand = firstNonEmpty(dsldFirst, { $0.brand })?.0 ?? ""
        let serving = firstNonEmpty(offFirst, { $0.serving })
        let macros = results.first { $0.macros != nil }?.macros
        // No "first non-empty" contest here: exactly one source ever has these.
        let ingredients = results.first { !$0.ingredients.isEmpty }?.ingredients ?? []
        let nutrition = results.first { $0.per100g != nil }

        return MergedProductFields(
            name: name, nameSource: nameSource, brand: brand,
            serving: serving?.0 ?? "1 serving", servingSource: serving?.1 ?? nameSource,
            macros: macros, ingredients: ingredients,
            per100g: nutrition?.per100g, servingGrams: nutrition?.servingGrams,
            packageGrams: results.compactMap(\.packageGrams).first, servingStated: serving != nil)
    }

    // MARK: - Per 100 g to per serving

    /// A product's serving and the nutrition in it, from numbers given per 100 g.
    ///
    /// Open Food Facts gives nutrition per 100 g, and everything downstream reads `macros` as
    /// one serving's. With the serving's weight — in its own text, or from the source — the
    /// numbers are scaled to it. With no serving, or one that has no weight, 100 g is the
    /// serving: the one amount the numbers are true of. The package's size is never taken for a
    /// serving: a 72 g pack of seaweed was once "one serving", 417 kcal of it.
    static func servingAndMacros(per100g: NutritionMacros, serving: String?, servingGrams: Double?)
        -> (serving: String, macros: NutritionMacros, stated: Bool) {
        if let serving, !serving.isEmpty, let grams = grams(in: serving) ?? servingGrams, grams > 0 {
            let factor = grams / 100
            return (serving,
                    NutritionMacros(calories: per100g.calories * factor, proteinGrams: per100g.proteinGrams * factor,
                                    carbohydrateGrams: per100g.carbohydrateGrams * factor,
                                    fatGrams: per100g.fatGrams * factor),
                    true)
        }
        return ("100 g", per100g, false)
    }

    /// The weight in grams a serving's text states: 140 of "1 cup (140 g)", 30 of "30 gram".
    /// The first one, as `MyFoods.serving` reads it. Nil without one ("500 mg" isn't).
    static func grams(in text: String) -> Double? {
        let lower = text.lowercased()
        guard let range = lower.range(of: #"(\d+(?:\.\d+)?)\s*(?:g|grams?)\b"#, options: .regularExpression) else { return nil }
        let digits = lower[range].prefix { $0.isNumber || $0 == "." }
        guard let grams = Double(digits), grams > 0 else { return nil }
        return grams
    }

    private static func rank(dsldFirst: Bool, _ fields: RawProductFields) -> Int {
        switch fields.source {
        case .dsld: return dsldFirst ? 0 : 1
        case .openFoodFacts: return dsldFirst ? 1 : 0
        case .bundledCatalog, .upcItemDB: return 2
        }
    }

    // MARK: - Open Food Facts

    private enum NetworkFetchResult {
        case found(RawProductFields)
        case notFound
        case error
        case rateLimited
    }

    private static let requestTimeout: TimeInterval = 10

    /// Open Food Facts rate-limits anonymous traffic to a 503 — an identifying User-Agent is
    /// required, not just polite. Verified against the live API during diagnosis. Reused for
    /// every source below: DSLD and UPCitemdb are both public/no-key APIs that behave the same
    /// way in practice.
    private static let userAgent = "Banana/1.0 (+https://bananatheapp.com)"

    private static func fetchFromOpenFoodFacts(_ barcode: String) async -> NetworkFetchResult {
        guard let url = URL(string:
            "https://world.openfoodfacts.org/api/v2/product/\(barcode).json"
            + "?fields=code,product_name,brands,quantity,product_quantity,serving_size,serving_quantity,nutriments"
        ) else { return .error }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Covers offline, timeout, and a cancelled scan (sheet dismissed mid-request) alike —
            // none of them mean "no such product," so none of them may report as `.notFound`.
            return .error
        }

        guard let http = response as? HTTPURLResponse else { return .error }
        if http.statusCode == 404 { return .notFound }
        guard (200..<300).contains(http.statusCode) else { return .error }

        guard let fields = parseOpenFoodFactsRawFields(data) else { return .notFound }
        return .found(fields)
    }

    private struct OpenFoodFactsResponse: Decodable {
        let status: Int
        let product: Product?

        struct Product: Decodable {
            let productName: String?
            let brands: String?
            let quantity: String?
            let servingSize: String?
            let nutriments: Nutriments?
            let servingQuantity: Number?
            let productQuantity: Number?

            enum CodingKeys: String, CodingKey {
                case productName = "product_name"
                case brands, quantity
                case servingSize = "serving_size"
                case nutriments
                case servingQuantity = "serving_quantity"
                case productQuantity = "product_quantity"
            }

            /// Nutrition per 100 g, when there is any.
            var per100g: NutritionMacros? {
                nutriments.flatMap { nutriments -> NutritionMacros? in
                    guard let calories = nutriments.caloriesPer100g else { return nil }
                    return NutritionMacros(
                        calories: calories,
                        proteinGrams: nutriments.proteinPer100g ?? 0,
                        carbohydrateGrams: nutriments.carbohydratePer100g ?? 0,
                        fatGrams: nutriments.fatPer100g ?? 0
                    ).sanitized
                }
            }

            /// What a serving is, in the product's own words. A product with nutrition has one
            /// only if it says so; one without (a supplement) falls back on its package text —
            /// "120 softgels" — as it always has.
            var statedServing: String? {
                let own = servingSize.flatMap { $0.isEmpty ? nil : $0 }
                if per100g != nil { return own }
                return own ?? quantity.flatMap { $0.isEmpty ? nil : $0 }
            }

            /// The package's net weight in grams: Open Food Facts' own number, else its text.
            var packageGrams: Double? {
                if let grams = productQuantity?.value, grams > 0 { return grams }
                return quantity.flatMap(BarcodeProductLookup.grams(in:))
            }
        }

        /// A number Open Food Facts sends as a number or as text ("72").
        struct Number: Decodable {
            let value: Double?

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) {
                    value = number
                } else if let text = try? container.decode(String.self) {
                    value = Double(text)
                } else {
                    value = nil
                }
            }
        }

        /// Open Food Facts' `nutriments` object mixes numbers, unit strings, and modifier flags
        /// under dozens of keys per nutrient. Naming only the four per-100g fields Banana uses
        /// means every other key — and every non-numeric one — is simply ignored by the decoder
        /// rather than needing to be modeled.
        struct Nutriments: Decodable {
            let caloriesPer100g: Double?
            let proteinPer100g: Double?
            let carbohydratePer100g: Double?
            let fatPer100g: Double?

            enum CodingKeys: String, CodingKey {
                case caloriesPer100g = "energy-kcal_100g"
                case proteinPer100g = "proteins_100g"
                case carbohydratePer100g = "carbohydrates_100g"
                case fatPer100g = "fat_100g"
            }
        }
    }

    /// Parses one Open Food Facts v2 product response into a single, already-combined
    /// `BarcodeProduct`. Pure and network-free, so it is exercised directly in tests against
    /// captured JSON rather than invented shapes. Kept — unchanged — as its own entry point for
    /// backward compatibility and its existing test coverage; the live cascade in `lookup(_:)`
    /// instead calls `parseOpenFoodFactsRawFields(_:)` below, which decodes the same response but
    /// keeps brand and product name separate (not yet combined, not yet defaulted) for
    /// `mergeFields(_:)` and `ProductRecordCleaner` to work with upstream of this function's own
    /// combining and defaulting.
    ///
    /// A supplement routinely has a `product` with no `nutriments` at all, or a `nutriments`
    /// object present but missing every energy/macro key — there is no Nutrition Facts panel to
    /// source it from. Both are success with `macros == nil`, never a parse failure. Only
    /// `status == 0` (Open Food Facts' own "not found"), a missing `product`, or a product with
    /// neither a brand nor a name count as absent. Anything else that fails to decode — an HTML
    /// error page, a truncated body, an empty payload — also falls through to `nil` here so a
    /// malformed response degrades to "not found" rather than crashing the scan.
    static func parseOpenFoodFactsResponse(_ data: Data, barcode: String) -> BarcodeProduct? {
        guard let response = try? JSONDecoder().decode(OpenFoodFactsResponse.self, from: data),
              response.status == 1,
              let product = response.product else { return nil }

        let name = combinedName(brand: product.brands ?? "", product: product.productName ?? "")
        guard !name.isEmpty else { return nil }

        var serving = displayServing(product.statedServing ?? "1 serving")
        var macros: NutritionMacros?
        var servingStated: Bool?
        if let per100g = product.per100g {
            let worked = servingAndMacros(per100g: per100g, serving: product.statedServing.map(displayServing),
                                          servingGrams: product.servingQuantity?.value)
            serving = worked.serving
            macros = worked.macros
            servingStated = worked.stated ? nil : false
        }

        return BarcodeProduct(barcode: barcode, name: name, serving: serving, macros: macros,
                              nameSource: .openFoodFacts, servingSource: .openFoodFacts, nameCleanedByModel: nil,
                              per100g: product.per100g, packageGrams: product.packageGrams, servingStated: servingStated)
    }

    static func parseOpenFoodFactsRawFields(_ data: Data) -> RawProductFields? {
        guard let response = try? JSONDecoder().decode(OpenFoodFactsResponse.self, from: data),
              response.status == 1, let product = response.product else { return nil }

        let name = displayText(product.productName ?? "")
        let brand = displayText(product.brands ?? "")
        guard !name.isEmpty || !brand.isEmpty else { return nil }

        return RawProductFields(source: .openFoodFacts, name: name, brand: brand, serving: product.statedServing,
                                macros: nil, per100g: product.per100g, servingGrams: product.servingQuantity?.value,
                                packageGrams: product.packageGrams)
    }

    // MARK: - NIH Dietary Supplement Label Database (DSLD)

    /// Regroups a barcode into DSLD's required quoted "1-5-5-1" search form
    /// (`"0 31604 02678 3"`), or `nil` when the barcode isn't reducible to a 12-digit UPC-A —
    /// DSLD's catalog is US-only, and against 42 real barcodes only the bare 12-digit form and
    /// its zero-padded 13-digit EAN form (stripped back to 12) ever matched; a genuine 13-digit
    /// EAN barcode (the common case for European products, which never start with a padding
    /// zero) matched zero times under any grouping tried, so DSLD is simply not attempted for
    /// those rather than guessing a grouping the measurement never validated. Unquoted search
    /// text returns noise and unspaced digits return nothing — both are documented API behavior,
    /// not a formatting nicety.
    static func dsldSearchQuery(forBarcode barcode: String) -> String? {
        guard let upcA12 = upcA12Digits(from: barcode) else { return nil }
        let digits = Array(upcA12)
        let grouped = "\(digits[0]) \(String(digits[1...5])) \(String(digits[6...10])) \(digits[11])"
        return "\"\(grouped)\""
    }

    static func dsldSearchURL(forBarcode barcode: String) -> URL? {
        guard let query = dsldSearchQuery(forBarcode: barcode) else { return nil }
        var components = URLComponents(string: "https://api.ods.od.nih.gov/dsld/v9/search-filter")
        components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "status", value: "2")]
        return components?.url
    }

    private static func upcA12Digits(from barcode: String) -> String? {
        guard barcode.allSatisfy(\.isNumber) else { return nil }
        if barcode.count == 12 { return barcode }
        if barcode.count == 13, barcode.hasPrefix("0") { return String(barcode.dropFirst()) }
        return nil
    }

    /// True when a DSLD label's `upcSku` (itself grouped with spaces, e.g. `"7 33739 00373 7"`)
    /// digitally matches the barcode being looked up, accounting for the UPC-A/EAN-13
    /// zero-padding difference either direction. DSLD's search endpoint ranks by text relevance
    /// against the quoted query, not by barcode equality, so its top hit can legitimately be a
    /// different product that merely sorted first — this is the check that keeps a coincidental
    /// rank match from being accepted as a real one.
    static func matchesDSLDUpcSku(_ upcSku: String, barcode: String) -> Bool {
        let skuDigits = upcSku.filter(\.isNumber)
        guard !skuDigits.isEmpty else { return false }
        var acceptable: Set<String> = [barcode]
        if let a12 = upcA12Digits(from: barcode) { acceptable.insert(a12) }
        if barcode.count == 12 { acceptable.insert("0" + barcode) }
        return acceptable.contains(skuDigits)
    }

    private struct DSLDSearchResponse: Decodable {
        struct Hit: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "_id" }
        }
        let hits: [Hit]
    }

    struct DSLDLabelResponse: Decodable {
        let upcSku: String?
        let fullName: String?
        let brandName: String?
        let servingSizes: [ServingSize]?
        let ingredientRows: [IngredientRow]?

        /// One row of the Supplement Facts panel. `ingredientGroup` is NIH's own normalisation —
        /// every zinc salt on every label rolls up to "Zinc" — which is exactly the vocabulary
        /// `SupplementInteractions.substances(in:)` already matches against, so it is preferred
        /// over the label's own wording.
        struct IngredientRow: Decodable {
            let name: String?
            let ingredientGroup: String?
            let category: String?
            let nestedRows: [IngredientRow]?
        }

        struct ServingSize: Decodable {
            let minQuantity: Double?
            let maxQuantity: Double?
            let unit: String?
            let notes: String?
        }
    }

    /// Parses one DSLD label response and confirms it against the barcode being looked up via
    /// its own `upcSku` field, per `matchesDSLDUpcSku(_:barcode:)` — never accepted on search
    /// rank alone. Pure and network-free, exercised directly in tests against captured label
    /// JSON.
    static func parseDSLDLabelResponse(_ data: Data, barcode: String) -> RawProductFields? {
        guard let label = try? JSONDecoder().decode(DSLDLabelResponse.self, from: data),
              let upcSku = label.upcSku, matchesDSLDUpcSku(upcSku, barcode: barcode) else { return nil }

        let name = (label.fullName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let serving = label.servingSizes?.first.map(dsldServingDisplay)
        return RawProductFields(source: .dsld, name: name, brand: label.brandName ?? "",
                                serving: serving, macros: nil,
                                ingredients: dsldIngredients(label.ingredientRows))
    }

    /// Flattens a DSLD ingredient panel into plain names, preferring NIH's normalised
    /// `ingredientGroup` over the label's own wording. Blends nest their components in
    /// `nestedRows`, which is where the individual minerals of a multivitamin actually live —
    /// walking them is the difference between seeing "Mineral Blend" and seeing the iron in it.
    static func dsldIngredients(_ rows: [DSLDLabelResponse.IngredientRow]?) -> [String] {
        guard let rows else { return [] }
        var found: [String] = []
        for row in rows {
            let label = (row.ingredientGroup?.isEmpty == false ? row.ingredientGroup : row.name) ?? ""
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !found.contains(trimmed) { found.append(trimmed) }
            for nested in dsldIngredients(row.nestedRows) where !found.contains(nested) {
                found.append(nested)
            }
        }
        return found
    }

    /// The serving phrase off a full DSLD label payload, or "" if it has none. Shared with
    /// `SupplementCatalogSearch`, whose search hits carry ingredients but no serving size.
    static func dsldServingPhrase(_ labelData: Data) -> String {
        guard let label = try? JSONDecoder().decode(DSLDLabelResponse.self, from: labelData),
              let serving = label.servingSizes?.first else { return "" }
        return dsldServingDisplay(serving)
    }

    private static func dsldServingDisplay(_ serving: DSLDLabelResponse.ServingSize) -> String {
        guard let minQuantity = serving.minQuantity else { return "" }
        let maxQuantity = serving.maxQuantity ?? minQuantity
        let quantityText = minQuantity == maxQuantity
            ? formattedQuantity(minQuantity)
            : "\(formattedQuantity(minQuantity))–\(formattedQuantity(maxQuantity))"
        let unit = serving.unit ?? ""
        var text = unit.isEmpty ? quantityText : "\(quantityText) \(unit)"
        if let notes = serving.notes, !notes.isEmpty { text += " (\(notes))" }
        return text
    }

    private static func formattedQuantity(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    private static func fetchFromDSLD(_ barcode: String) async -> NetworkFetchResult {
        guard let searchURL = dsldSearchURL(forBarcode: barcode) else { return .notFound }

        var searchRequest = URLRequest(url: searchURL, timeoutInterval: requestTimeout)
        searchRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let searchData: Data
        let searchResponse: URLResponse
        do {
            (searchData, searchResponse) = try await URLSession.shared.data(for: searchRequest)
        } catch { return .error }
        guard let searchHTTP = searchResponse as? HTTPURLResponse, (200..<300).contains(searchHTTP.statusCode) else { return .error }

        guard let decoded = try? JSONDecoder().decode(DSLDSearchResponse.self, from: searchData),
              let hitID = decoded.hits.first?.id else { return .notFound }

        guard let labelURL = URL(string: "https://api.ods.od.nih.gov/dsld/v9/label/\(hitID)") else { return .error }
        var labelRequest = URLRequest(url: labelURL, timeoutInterval: requestTimeout)
        labelRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let labelData: Data
        let labelResponse: URLResponse
        do {
            (labelData, labelResponse) = try await URLSession.shared.data(for: labelRequest)
        } catch { return .error }
        guard let labelHTTP = labelResponse as? HTTPURLResponse, (200..<300).contains(labelHTTP.statusCode) else { return .error }

        guard let fields = parseDSLDLabelResponse(labelData, barcode: barcode) else { return .notFound }
        return .found(fields)
    }

    // MARK: - UPCitemdb (last resort — rate-limited trial tier)

    struct UPCItemDBResponse: Decodable {
        let code: String
        /// `nil`, not just zero, on a quota-exceeded body — that response shape omits `total`
        /// entirely rather than reporting it as `0`, so this must stay optional or the whole
        /// response fails to decode and a rate-limit reads as a decode failure (`.notFound`)
        /// instead of `.rateLimited`.
        let total: Int?
        let items: [Item]?

        struct Item: Decodable {
            let title: String?
            let brand: String?
            let size: String?
        }
    }

    enum UPCItemDBParseResult: Equatable {
        case found(RawProductFields)
        case notFound
        /// The response body itself reports the trial key's quota is exhausted — UPCitemdb's
        /// trial API returns HTTP 200 with a non-`"OK"` `code` for this rather than a 429 in
        /// every observed case, so the body has to be inspected, not just the status line.
        case rateLimited
    }

    /// Parses one UPCitemdb `lookup` response. Pure and network-free, exercised directly in
    /// tests against a captured success response and a captured empty ("OK", zero results)
    /// response.
    static func parseUPCItemDBResponse(_ data: Data) -> UPCItemDBParseResult {
        guard let decoded = try? JSONDecoder().decode(UPCItemDBResponse.self, from: data) else { return .notFound }
        let upperCode = decoded.code.uppercased()
        if upperCode != "OK", upperCode.contains("LIMIT") || upperCode.contains("QUOTA") { return .rateLimited }
        guard decoded.code == "OK", (decoded.total ?? 0) > 0, let item = decoded.items?.first else { return .notFound }
        let name = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .notFound }
        return .found(RawProductFields(source: .upcItemDB, name: name, brand: item.brand ?? "", serving: item.size, macros: nil))
    }

    private static func fetchFromUPCItemDB(_ barcode: String) async -> NetworkFetchResult {
        guard await UPCItemDBRateLimiter.shared.tryAcquire() else { return .rateLimited }

        guard let url = URL(string: "https://api.upcitemdb.com/prod/trial/lookup?upc=\(barcode)") else { return .error }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch { return .error }

        guard let http = response as? HTTPURLResponse else { return .error }
        await UPCItemDBRateLimiter.shared.observe(response: http)
        if http.statusCode == 429 { return .rateLimited }
        guard (200..<300).contains(http.statusCode) else { return .error }

        switch parseUPCItemDBResponse(data) {
        case .found(let fields): return .found(fields)
        case .notFound: return .notFound
        case .rateLimited: return .rateLimited
        }
    }

    // MARK: - Shared helpers

    private static func barcodeCandidates(_ barcode: String) -> [String] {
        var candidates = [barcode]
        for length in [13, 14] where barcode.count < length {
            candidates.append(String(repeating: "0", count: length - barcode.count) + barcode)
        }
        return candidates
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    /// `internal`, not `private`: `SupplementLabelExtractor` reuses this exact brand-folding rule
    /// so a label-photo-derived name is built the same way as a barcode-derived one.
    static func combinedName(brand: String, product: String) -> String {
        let brand = displayText(brand)
        let product = displayText(product)
        guard !brand.isEmpty,
              product.range(of: brand, options: [.caseInsensitive, .diacriticInsensitive]) == nil else {
            return product
        }
        return "\(brand) \(product)"
    }

    static func displayText(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == text.uppercased() ? text.localizedCapitalized : text
    }

    private static func displayServing(_ raw: String) -> String {
        raw.replacingOccurrences(of: " GRM", with: " g", options: .caseInsensitive)
            .replacingOccurrences(of: " MLT", with: " mL", options: .caseInsensitive)
    }
}

/// A small, bounded on-disk cache of successful online lookups, so a repeat scan of the same
/// bottle is instant and works offline afterward — the same guarantee the bundled catalog already
/// gives every packaged grocery item. Deliberately not a mirror of any source: capped well below
/// anything that matters for app size, evicting the oldest entries first. Stores the *finished*
/// product — already merged across sources and already cleaned — so a cache hit never re-runs
/// the on-device model either.
private enum BarcodeNetworkCache {
    private static let maxEntries = 200
    /// "-2": what the first file held had Open Food Facts' per-100 g numbers stored as a
    /// serving's. A new file, so none of it is served again; the old one is removed.
    private static let fileURL = AppSupport.directory.appendingPathComponent("BarcodeNetworkCache-2.json")
    private static let supersededURL = AppSupport.directory.appendingPathComponent("BarcodeNetworkCache.json")
    private static let lock = NSLock()
    private static var entries: [String: Entry]?

    private struct Entry: Codable {
        var product: BarcodeProduct
        var cachedAt: Date
    }

    static func product(for barcode: String) -> BarcodeProduct? {
        lock.lock(); defer { lock.unlock() }
        return loadIfNeeded()[barcode]?.product
    }

    static func store(_ product: BarcodeProduct) {
        lock.lock(); defer { lock.unlock() }
        var store = loadIfNeeded()
        store[product.barcode] = Entry(product: product, cachedAt: Date())
        if store.count > maxEntries {
            let oldest = store.sorted { $0.value.cachedAt < $1.value.cachedAt }
                .prefix(store.count - maxEntries)
                .map(\.key)
            for key in oldest { store.removeValue(forKey: key) }
        }
        entries = store
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadIfNeeded() -> [String: Entry] {
        if let entries { return entries }
        try? FileManager.default.removeItem(at: supersededURL)
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = loaded
        return loaded
    }
}

/// Locally paces UPCitemdb requests to stay inside its trial-tier limits — about 100 requests per
/// day shared across every endpoint, refilled in a burst bucket of 6 within a minute (so roughly
/// one request every 10-13 seconds sustained) — rather than finding those limits by tripping them
/// in production. `tryAcquire()` is non-blocking: it either grants permission to make one request
/// right now or refuses immediately, so a scan never sits waiting out a cooldown it can't explain
/// to the person watching a spinner. Tracks the service's own `X-RateLimit-Remaining` /
/// `X-RateLimit-Reset` response headers as the source of truth once any response has been heard
/// (that header reflects the trial key's *actual* remaining budget, including anything consumed
/// outside this app), falling back to a conservative built-in budget only before the first
/// response teaches it the truth. Persisted to disk so a relaunch mid-day doesn't forget how much
/// budget is already spent — this is the one piece of this feature that writes under
/// `AppSupport.directory`, and only ever from a real device/simulator run of the app, never from
/// a test (see `BarcodeUPCItemDBTests`, which exercises the pure pacing decision in
/// `UPCItemDBRateLimiter.canAcquire` instead of this actor).
actor UPCItemDBRateLimiter {
    static let shared = UPCItemDBRateLimiter()

    /// Comfortably inside both documented constraints at once: a burst bucket of 6 that refills
    /// within a minute needs at least 10s of spacing to never be exceeded, and this already sits
    /// inside the "roughly one request per 10 to 13 seconds sustained" guidance.
    static let minInterval: TimeInterval = 11

    private var remaining: Int
    private var resetAt: Date?
    private var lastRequestAt: Date?

    private static let fileURL = AppSupport.directory.appendingPathComponent("UPCItemDBRateLimit.json")

    private struct State: Codable {
        var remaining: Int
        var resetAt: Date?
        var lastRequestAt: Date?
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            remaining = state.remaining
            resetAt = state.resetAt
            lastRequestAt = state.lastRequestAt
        } else {
            remaining = 100
            resetAt = nil
            lastRequestAt = nil
        }
    }

    /// Pure pacing decision, split out so it's testable without touching the disk-backed actor
    /// (or the real `AppSupport.directory`, which tests must never write to): true exactly when
    /// the daily budget has room left and the sustained pacing interval has elapsed since the
    /// last request.
    static func canAcquire(remaining: Int, lastRequestAt: Date?, now: Date, minInterval: TimeInterval = UPCItemDBRateLimiter.minInterval) -> Bool {
        guard remaining > 0 else { return false }
        if let lastRequestAt, now.timeIntervalSince(lastRequestAt) < minInterval { return false }
        return true
    }

    func tryAcquire() -> Bool {
        let now = Date()
        if let resetAt, now >= resetAt {
            remaining = 100
            self.resetAt = nil
        }
        guard Self.canAcquire(remaining: remaining, lastRequestAt: lastRequestAt, now: now) else { return false }
        remaining -= 1
        lastRequestAt = now
        persist()
        return true
    }

    func observe(response: HTTPURLResponse) {
        if let remainingHeader = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let value = Int(remainingHeader) {
            remaining = value
        }
        if let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let epoch = TimeInterval(resetHeader) {
            resetAt = Date(timeIntervalSince1970: epoch)
        }
        persist()
    }

    private func persist() {
        let state = State(remaining: remaining, resetAt: resetAt, lastRequestAt: lastRequestAt)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
