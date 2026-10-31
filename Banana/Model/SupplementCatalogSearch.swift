import Foundation
import os

/// One product found by searching NIH's Dietary Supplement Label Database by name.
///
/// Carries its ingredient panel, because DSLD's search endpoint already returns it — which makes
/// picking a product here strictly better than typing its name: the app learns what is actually in
/// the bottle, and `SupplementInteractions` can see a multivitamin's iron without the label ever
/// saying "iron" in its title.
struct SupplementCatalogEntry: Equatable, Identifiable, Sendable {
    var id: String
    var brand: String
    var product: String
    /// NIH's normalised ingredient names, active ingredients first.
    var ingredients: [String]
    /// Filled in only once a result is actually chosen — the serving size lives on the full label
    /// record, not on a search hit, and fetching 20 labels to render one list would be rude to a
    /// free public API and slow for no gain.
    var dose: String = ""

    var displayName: String { BarcodeProductLookup.combinedName(brand: brand, product: product) }

    /// A one-line preview of the panel for the search row. A multivitamin has twenty-five actives
    /// and they will not fit; the count says so rather than trailing off, because "+19 more" is
    /// itself the useful signal that this is a multi rather than a single-ingredient bottle. The
    /// full list is what gets stored and what the interaction check reads.
    var ingredientSummary: String {
        guard !ingredients.isEmpty else { return "" }
        let shown = ingredients.prefix(4).joined(separator: " · ")
        let rest = ingredients.count - min(4, ingredients.count)
        return rest > 0 ? "\(shown) +\(rest) more" : shown
    }
}

/// Name search against NIH's DSLD, for adding a supplement without a barcode to scan.
///
/// The barcode path in `BarcodeProductLookup` answers "what is this bottle?"; this answers "which
/// of these is my bottle?", which is the question you actually have when the barcode is worn off,
/// the product is a repackaged import, or you are adding something from memory. Same database,
/// same free public API, same US-only caveat.
enum SupplementCatalogSearch {
    private static let log = Logger(subsystem: "com.boris.banana", category: "supplement-search")
    private static let requestTimeout: TimeInterval = 12
    private static let userAgent = "Banana/1.0 (+https://bananatheapp.com)"

    enum Outcome: Equatable {
        case results([SupplementCatalogEntry])
        case none
        case networkError
    }

    /// `status=1` is DSLD's on-market filter — verified against the live API, whose hits come back
    /// with `offMarket: 0`. Someone adding a supplement is holding a bottle they can buy; ranking
    /// a discontinued 2014 formulation alongside it would be noise.
    static func searchURL(for query: String, limit: Int = 20) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        var components = URLComponents(string: "https://api.ods.od.nih.gov/dsld/v9/search-filter")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "status", value: "1"),
            URLQueryItem(name: "size", value: String(limit)),
        ]
        return components?.url
    }

    static func search(_ query: String) async -> Outcome {
        guard let url = searchURL(for: query) else { return .none }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.notice("dsld name search: unexpected status")
                return .networkError
            }
            let entries = parseSearchResponse(data)
            return entries.isEmpty ? .none : .results(entries)
        } catch {
            return .networkError
        }
    }

    /// Pure and network-free, so the response shape is covered by tests against captured JSON.
    static func parseSearchResponse(_ data: Data) -> [SupplementCatalogEntry] {
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        return decoded.hits.compactMap { hit in
            let product = (hit.source.fullName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !product.isEmpty else { return nil }
            return SupplementCatalogEntry(
                id: hit.id,
                brand: (hit.source.brandName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                product: product,
                ingredients: activeIngredients(hit.source.allIngredients))
        }
    }

    /// Keeps the ingredients someone would recognise as the point of the bottle and drops the
    /// excipients. DSLD's own `category` does the work: "mineral", "vitamin", "amino acid" and
    /// the botanicals are actives; starch, stearates and colourings come back categorised as
    /// non-nutrient and are dropped. Order is preserved — a label lists its actives first.
    static func activeIngredients(_ rows: [SearchResponse.Ingredient]?) -> [String] {
        guard let rows else { return [] }
        var found: [String] = []
        for row in rows {
            let category = (row.category ?? "").lowercased()
            guard !excipientCategories.contains(where: category.contains) else { continue }
            let name = (row.ingredientGroup?.isEmpty == false ? row.ingredientGroup : row.name) ?? ""
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !found.contains(trimmed) { found.append(trimmed) }
        }
        return found
    }

    private static let excipientCategories = [
        "non-nutrient", "complex carbohydrate", "other ingredient",
    ]

    /// Fills in the serving size for a chosen result, from its full label record. Failure is not
    /// an error the person needs to see — they picked a product and got its name and ingredients;
    /// the dose field is simply left for them to type.
    static func withDose(_ entry: SupplementCatalogEntry) async -> SupplementCatalogEntry {
        guard let url = URL(string: "https://api.ods.od.nih.gov/dsld/v9/label/\(entry.id)") else { return entry }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return entry }
        var filled = entry
        filled.dose = BarcodeProductLookup.dsldServingPhrase(data)
        return filled
    }

    struct SearchResponse: Decodable {
        struct Ingredient: Decodable {
            let name: String?
            let ingredientGroup: String?
            let category: String?
        }
        struct Source: Decodable {
            let fullName: String?
            let brandName: String?
            let allIngredients: [Ingredient]?
        }
        struct Hit: Decodable {
            let id: String
            let source: Source
            enum CodingKeys: String, CodingKey { case id = "_id", source = "_source" }
        }
        let hits: [Hit]
    }
}
