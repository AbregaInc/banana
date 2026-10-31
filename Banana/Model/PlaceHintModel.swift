import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks Apple Intelligence what kind of place an event happens at, as map-search phrases:
/// "Lap Swim: Up to 3 Per Lane" → "swimming pool", "recreation center".
///
/// A location like "Chelsea" names a neighbourhood; searched on its own it finds only the
/// neighbourhood, which is how a swim was timed to a street corner. The event's title says what
/// the place is, and the keyword table that read it before knew about forty English words.
/// The on-device model reads any title in any language. Its answers only widen the search in
/// the place picker — you still choose the place — so a wrong guess costs nothing but a result.
///
/// Routed as `.knowledge`: "Masters practice" is a swim only if you know what masters is, and
/// the on-device model got it wrong (tennis) in testing where Apple's Private Cloud Compute
/// model is the better reader. One request per distinct title, remembered, so the quota barely
/// notices. The on-device model also took 6–20 s per answer on a Mac, so callers show keyword
/// results first and merge these in, and `prefetch` asks as soon as a guessed place appears.
@MainActor
enum PlaceHintModel {
    private static let defaultsKey = "placeHintCache"   // dot-free
    private static var cache: [String: [String]] =
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]]) ?? [:]
    private static var inFlight: [String: Task<[String]?, Never>] = [:]

    private static func key(_ title: String, _ location: String) -> String {
        SavedPlace.key(title) + "|" + SavedPlace.key(location)
    }

    /// An answer already in hand, without asking.
    static func cachedTerms(title: String, location: String) -> [String]? {
        cache[key(title, location)]
    }

    /// Ask now, in the background, so the answer is there by the time the question is shown.
    static func prefetch(title: String, location: String) {
        guard cache[key(title, location)] == nil else { return }
        Task { _ = await terms(title: title, location: location) }
    }

    /// Search phrases for the place `title` happens at, or nil when no model is available (the
    /// caller falls back to the keyword table). Gives up after `timeout`.
    static func terms(title: String, location: String, timeout: Duration = .seconds(30)) async -> [String]? {
        let key = key(title, location)
        if let cached = cache[key] { return cached }
        // One request per question, however many views ask at once.
        if let running = inFlight[key] { return await running.value }
        let task = Task { await askWithTimeout(title: title, location: location, timeout: timeout) }
        inFlight[key] = task
        let found = await task.value
        inFlight[key] = nil
        if let found {
            cache[key] = found
            if cache.count > 300 { cache.removeAll() }
            UserDefaults.standard.set(cache, forKey: defaultsKey)
        }
        return found
    }

    private static func askWithTimeout(title: String, location: String, timeout: Duration) async -> [String]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return nil }
        // A plain task and a timer that cancels it — not a task group, which came back empty
        // from main-actor code in this app before (see GoogleCalendarService).
        let work = Task { await ask(title: title, location: location) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
        }
        let found = await work.value
        timer.cancel()
        return found
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func ask(title: String, location: String) async -> [String]? {
        guard let (session, route) = Intelligence.session(for: .knowledge, instructions: instructions) else {
            return nil
        }
        let prompt = """
        Event: \(title.prefix(200))
        Location: \(location.prefix(200))
        """
        do {
            let response = try await Intelligence.guardingCloud(route) {
                try await session.respond(to: prompt, generating: GeneratedPlaceTypes.self)
            }
            return PlaceSearchHints.sanitize(response.content.placeTypes, location: location)
        } catch {
            Log.travel.notice("[travel] place hint unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let instructions = """
    You help find where a calendar event takes place. Given the event's title and its location \
    text, name the TYPE of place it happens at, as short phrases someone would type into a map \
    search: for example "swimming pool", "recreation center", "yoga studio", "barber shop", \
    "coffee shop". Never repeat the location, and never invent a business name. If the title \
    only names a person, a meeting or a doctor without saying what kind of place, return an \
    empty list rather than guessing.
    """
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct GeneratedPlaceTypes {
    @Guide(description: "Up to three short map-search phrases for the kind of place, most likely first. Empty if unknown.",
           .maximumCount(3))
    var placeTypes: [String]
}
#endif
