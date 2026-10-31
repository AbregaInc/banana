import Foundation

/// Where `FoodSearch` looks: the bundled USDA foods and products (offline), Open Food Facts
/// (online), and what you picked before (`FoodSearchPicks`).
enum FoodSearchSources {
    /// The bundled half of a search: the brand it names, if any, and the words left; the USDA
    /// foods for those words and the products of that brand. SQLite: call off the main thread.
    struct Local: Sendable {
        var brand: FoodSearch.Brand?
        var food: [String]
        var foods: [FoodSearch.Result]
        var products: [FoodSearch.Result]
    }

    static let foodsShown = 15
    /// Searched for, to keep the `foodsShown` about the food (`FoodSearch.focused`).
    static let foodsLooked = 40

    static func local(_ query: String, index: FoodSearch.BrandIndex) -> Local {
        let found = FoodSearch.brand(in: query, index: index) { phrase in
            FoodSearch.names(phrase, among: FoodDatabase.search(phrase, limit: 5))
        }
        let food = found?.food ?? FoodSearch.words(query)
        let head = FoodSearch.head(of: query, brand: found?.brand)
        // The food without its brand: Trader Joe's carrots are carrots.
        let generic = found.map { $0.food.joined(separator: " ") } ?? query
        var split = FoodSearch.split(FoodDatabase.search(generic, limit: foodsLooked), brand: nil, head: head, limit: foodsShown)
        if let brand = found?.brand {
            // That brand's own products, from the whole words.
            split.products = FoodSearch.split(FoodDatabase.search(query, limit: foodsLooked), brand: brand, head: head,
                                              limit: foodsShown).products
        }
        return Local(brand: found?.brand, food: food, foods: split.foods, products: split.products)
    }

    /// Open Food Facts' products for the words: of the brand named, or with every word.
    static func online(_ query: String, brand: FoodSearch.Brand?, food: [String]) async throws -> [FoodSearch.Result] {
        guard let url = FoodSearch.onlineURL(query, brand: brand) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        // Open Food Facts answers anonymous traffic with 503s: say who's asking.
        request.setValue("Banana/1.0 (+https://bananatheapp.com)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return FoodSearch.products(fromSearch: data, food: food, brand: brand)
    }

    /// A bundled food's household measures, for something of yours that came from it.
    static func portions(_ referenceID: String) -> [FoodPortion] {
        guard !referenceID.hasPrefix("off:"), !referenceID.hasPrefix(MyFoods.referencePrefix) else { return [] }
        return FoodDatabase.food(id: referenceID)?.portions ?? []
    }

    /// The bundled brands, read once.
    static func brandIndex() async -> FoodSearch.BrandIndex { await BrandIndexHolder.shared.index() }

    private actor BrandIndexHolder {
        static let shared = BrandIndexHolder()
        private var loaded: FoodSearch.BrandIndex?

        func index() async -> FoodSearch.BrandIndex {
            if let loaded { return loaded }
            let built = await Task.detached(priority: .userInitiated) {
                FoodSearch.BrandIndex(brands: FoodDatabase.brands(), brandWords: FoodDatabase.brandWords())
            }.value
            loaded = built
            return built
        }
    }
}

/// What was picked for the words searched — "tj carrots" → the baby carrots — so it comes first
/// next time, here and on your other devices (iCloud key-value storage, as `GuestPicks`).
enum FoodSearchPicks {
    private static let key = "foodSearchPicks.v1"
    private static var store: LegacyKVS { .shared }
    /// Searches remembered, at most: beyond this one is let go to make room (KVS holds 1 MB).
    static let kept = 300

    private static var all: [String: [String: Int]] {
        (store.dictionary(forKey: key) as? [String: [String: Int]])
            ?? (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]]) ?? [:]
    }

    /// Times each food (by its reference id) was picked for these words.
    static func picks(for query: String) -> [String: Int] { all[FoodSearch.key(query)] ?? [:] }

    static func record(query: String, referenceID: String) {
        let words = FoodSearch.key(query)
        guard !words.isEmpty, !referenceID.isEmpty else { return }
        var picks = all
        picks[words, default: [:]][referenceID, default: 0] += 1
        // Let go here only: the data platform keeps it (DATA-PLATFORM.md §3, pruning is not deleting).
        if picks.count > kept, let drop = picks.keys.first(where: { $0 != words }) { picks[drop] = nil }
        store.set(picks, forKey: key)
        UserDefaults.standard.set(picks, forKey: key)
        SyncReport.changed(spaceType, [words])
    }

    /// The data platform's record type: one per query, a food's count per field.
    static let spaceType = "food.searchPick"

    /// Every query's picks.
    static var everything: [String: [String: Int]] { all }

    /// Other devices' picks from the data platform (nil: gone), in one write; kept to `kept`.
    static func adoptFromSpace(_ changes: [String: [String: Int]?]) {
        var picks = all
        for (query, counts) in changes { picks[query] = counts }
        while picks.count > kept, let drop = picks.keys.first(where: { changes[$0] == nil }) ?? picks.keys.first {
            picks[drop] = nil
        }
        store.set(picks, forKey: key)
        UserDefaults.standard.set(picks, forKey: key)
    }
}
