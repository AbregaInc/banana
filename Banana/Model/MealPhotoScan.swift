import CryptoKit
import Foundation

// Finding meal photos in the library: which labels mean food, which photos a pass looks at, how
// new photos join a meal already waiting, the same photo found on two devices, how the Mac and the
// iPhone share the looking, what a device remembers between passes, and the words the scanner
// says. Pure, for tests; the scanning itself is `MealPhotoScanner` (every device with Photos
// access) and the questions `MealPhotoNotifications` (the iPhone). See docs/design/MEAL-BACKLOG.md.

// MARK: - The setting

/// "Find meal photos automatically", as the scanner reads it. One synced setting (`AppSettings`),
/// the same switch on every device; each device with full Photos access looks.
struct MealPhotoScanPrefs: Equatable, Sendable {
    var enabled = false
    /// How far back the scan starts. Nil until it's first turned on.
    var since: Date?
    /// Ask about new meal photos found in the background (notifications).
    var ask = true

    /// How far back a scan starts when it's turned on: long enough to catch the last week or two of
    /// meals, short enough that the first pass doesn't turn a year of dinners into a backlog.
    static let lookBack: TimeInterval = 14 * 86_400

    /// The start of the day `lookBack` before `now` — what "Starting from" shows once it's turned on.
    static func defaultSince(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-lookBack))
    }

    func effectiveSince(now: Date = Date(), calendar: Calendar = .current) -> Date {
        since ?? Self.defaultSince(now: now, calendar: calendar)
    }
}

// MARK: - Is it food?

/// Whether `VNClassifyImageRequest` (revision 2) thinks a photo is of something eaten or drunk.
///
/// Measured on ~95 photos (Wikipedia lead images, 512 px, as the scanner reads them): every
/// plated dish scored `food` ≥ 0.31 (a steak on a busy plate, the lowest), most 0.6–1.0; nothing
/// that wasn't a meal scored above 0.18 (a fridge, a deli counter, a farmers' market, a
/// grocery). Drinks don't score as `food` — a glass of wine is `wine` 0.96 and `food` 0.00 — so
/// they have their own labels: every coffee, beer, wine and cocktail scored ≥ 0.26 on its own
/// label (an espresso cup from above, the lowest), and nothing else above 0.05.
///
/// What a meal is photographed with — `table`, `plate`, `tableware`, `restaurant`,
/// `dining_room`, `kitchen` — is deliberately not here: an empty restaurant scores
/// `restaurant` 0.64 and `table` 0.54, and is not a meal. Nor is a bare `drink` (a glass of
/// water is a drink) or ingredients that are mostly seen growing or in jars (`grain`, `herb`,
/// `seasonings`, `honey`, `mushroom`).
enum MealPhotoClassifier {
    static let foodThreshold: Float = 0.3
    static let drinkThreshold: Float = 0.25

    /// Food: the taxonomy's own parents, then dishes, desserts, baked goods, fruit and vegetables.
    /// The parent `food` carries nearly every decision (it scores at least as high as the dish it
    /// contains); the rest keep a clear dish counting if a photo's parent label comes out low.
    static let foodLabels: Set<String> = [
        "food", "dessert", "baked_goods", "frozen_dessert", "fruit", "vegetable", "meat", "seafood",
        "shellfish_prepared",
        // Dishes
        "antipasti", "bacon", "beef", "biryani", "bruschetta", "burrito", "caprese", "casserole",
        "cereal", "cheese", "coleslaw", "curry", "dumpling", "edamame", "egg", "falafel", "fondue",
        "fried_chicken", "fried_egg", "fries", "grilled_chicken", "guacamole", "gyoza", "ham",
        "hamburger", "hotdog", "hummus", "kebab", "meatball", "nachos", "oatmeal", "omelet", "paella",
        "pasta", "pepperoni", "pierogi", "pizza", "popcorn", "quesadilla", "quinoa", "ramen", "rice",
        "risotto", "roe", "salad", "salami", "samosa", "sandwich", "satay", "sauerkraut", "sausage",
        "scrambled_eggs", "shawarma", "soup", "souvlaki", "spaghetti", "spareribs", "springroll",
        "steak", "stir_fry", "sushi", "tabbouleh", "taco", "tapas", "tempura", "teriyaki", "wonton",
        "yogurt",
        // Desserts and sweets
        "baklava", "birthday_cake", "brownie", "cake", "cake_regular", "candy", "cheesecake",
        "chocolate", "chocolate_chip", "cookie", "crepe", "cupcake", "donut", "flan", "fruitcake",
        "gingerbread", "ice_cream", "jello", "jelly", "pie", "popsicle", "pudding", "souffle",
        "strudel", "tiramisu", "waffle", "wedding_cake",
        // Baked goods
        "bagel", "biscotti", "biscuit", "bread", "croissant", "matzo", "muffin", "naan", "pancake",
        "pastry", "pita", "pretzel", "scone", "tortilla", "white_bread",
        // Fruit
        "apple", "apricot", "avocado", "banana", "berry", "blackberry", "blueberry", "cantaloupe",
        "cherry", "coconut", "fig", "grape", "grapefruit", "guava", "honeydew", "kiwi", "lychee",
        "mandarine", "mango", "melon", "nectarine", "oranges", "papaya", "peach", "pear",
        "pineapple", "plum", "pomegranate", "raspberry", "strawberry", "watermelon",
        // Vegetables
        "artichoke", "asparagus", "broccoli", "carrot", "cauliflower", "corn", "cucumber",
        "eggplant", "green_beans", "lettuce", "potato", "spinach", "tomato", "zucchini",
    ]

    /// Drinks worth logging: coffee, tea, juice, and anything with alcohol in it.
    static let drinkLabels: Set<String> = [
        "coffee", "tea_drink", "juice", "smoothie", "milkshake", "bubble_tea", "soda",
        "beer", "wine", "red_wine", "white_wine", "sparkling_wine", "cocktail", "martini",
        "margarita", "mojito", "sangria", "liquor", "tequila",
    ]

    /// Labels and their confidences, as Vision gives them (every label it knows, most near 0).
    static func isMeal(labels: [(String, Float)]) -> Bool {
        labels.contains { label, confidence in
            (foodLabels.contains(label) && confidence >= foodThreshold)
                || (drinkLabels.contains(label) && confidence >= drinkThreshold)
        }
    }
}

// MARK: - Which photos a pass looks at

/// A library photo, as much of it as choosing needs.
struct MealPhotoAsset: Equatable, Sendable {
    var id: String
    var createdAt: Date?
    var isScreenshot: Bool
}

enum MealPhotoScanSelection {
    /// A pass looks again this far before the last one: a photo can reach the library late (from
    /// the iPad over iCloud, or a friend's shared shot), with the time it was taken.
    static let overlap: TimeInterval = 86_400

    struct Plan: Equatable, Sendable {
        /// Library ids to classify, newest first: today's lunch is asked about before last week's.
        var ids: [String]
        /// Candidates left for the next pass.
        var remaining: Int
    }

    /// The photos to classify this pass: taken since `start`, not screenshots, not already looked
    /// at, at most `cap` of them. Undated photos can't be placed in a day, so they're left alone.
    static func select(_ assets: [MealPhotoAsset], skipping: Set<String>, from start: Date, cap: Int) -> Plan {
        let candidates = assets
            .filter { asset in
                guard let created = asset.createdAt, created >= start else { return false }
                return !asset.isScreenshot && !skipping.contains(asset.id)
            }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        let ids = candidates.prefix(max(cap, 0)).map(\.id)
        return Plan(ids: ids, remaining: candidates.count - ids.count)
    }
}

// MARK: - What the phone remembers between passes

/// Kept on each device that scans (Application Support/meal-photo-scan.json), never synced: the
/// library ids it holds mean nothing on another device. What crosses devices is the cloud key
/// (`MealPhotoIdentity`) and the synced list of photos already made into meals (`MealPhotoLedger`).
struct MealPhotoScanState: Codable, Equatable, Sendable {
    /// When the last pass that got through everything in its window started.
    var lastPass: Date?
    /// The start date that pass covered from. A start moved earlier than this means the days in
    /// between were never looked at.
    var coveredFrom: Date?
    /// When a pass last ran, finished or not: the status line, and the foreground throttle.
    var lastCheck: Date?
    /// Every photo already classified, food or not, by library id → when it was taken.
    var seen: [String: Date] = [:]
    /// The photos that became meals. Kept for as long as the start date covers them, so a meal
    /// logged or dismissed (and so gone from the backlog) is never found again.
    var found: [String: Date] = [:]
    /// Meals found since `countingFrom`, for "3 meals found".
    var mealsFound = 0
    var countingFrom: Date?
    /// Photos left for the next pass when the last one hit its cap or its time.
    var remaining = 0

    /// Where the next pass starts looking: a little before the last complete pass, never before the
    /// start date — or right at the start date when it was moved earlier than anything looked at.
    func windowStart(since: Date) -> Date {
        guard let lastPass, let coveredFrom, coveredFrom <= since else { return since }
        return max(since, lastPass.addingTimeInterval(-MealPhotoScanSelection.overlap))
    }

    /// Photos not to classify again.
    var skipping: Set<String> { Set(seen.keys).union(found.keys) }

    /// Meals found under this start date: moving the start date starts the count again.
    func meals(countingFrom since: Date) -> Int { countingFrom == since ? mealsFound : 0 }

    /// What one pass found.
    struct Pass: Equatable, Sendable {
        var startedAt: Date
        /// Photos classified (food or not), library id → taken.
        var classified: [String: Date] = [:]
        /// The ones that became meals.
        var food: [String: Date] = [:]
        /// New meals (joining a waiting meal isn't a new one).
        var newMeals = 0
        var remaining = 0
        /// Got through everything in its window: no cap, no deadline, not cancelled.
        var complete: Bool
    }

    /// Takes in a pass, and forgets what no pass will look at again: seen photos from before the
    /// next window, found ones from before the start date.
    mutating func record(_ pass: Pass, since: Date) {
        if countingFrom != since {
            countingFrom = since
            mealsFound = 0
        }
        seen.merge(pass.classified) { $1 }
        found.merge(pass.food) { $1 }
        mealsFound += pass.newMeals
        lastCheck = pass.startedAt
        remaining = pass.remaining
        if pass.complete {
            lastPass = pass.startedAt
            coveredFrom = since
        }
        seen = Self.pruned(seen, before: windowStart(since: since))
        found = Self.pruned(found, before: since)
    }

    static func pruned(_ ids: [String: Date], before cutoff: Date) -> [String: Date] {
        ids.filter { $0.value >= cutoff }
    }
}

// MARK: - New photos into the backlog

enum MealPhotoScanMerge {
    enum Decision: Equatable, Sendable {
        /// Add these photos to a scanned meal already waiting for words.
        case join(UUID, [MealPhotoRef])
        /// A meal of its own.
        case new([MealPhotoRef])
    }

    /// For each group of new photos (`MealPhotoGrouping`): join the nearest scanned meal still
    /// waiting for words when it's within `gap` of it — the dessert found an hour after the plate
    /// was asked about is the same dinner — or start a meal of its own. A meal already answered,
    /// estimated or picked by hand is never added to.
    static func plan(groups: [[MealPhotoRef]], existing: [MealInboxItem],
                     gap: TimeInterval = MealPhotoGrouping.gap) -> [Decision] {
        var spans: [(id: UUID, first: Date, last: Date)] = existing
            .filter { $0.state == .awaitingNote && $0.origin == .scanned }
            .map { item in
                let times = item.photos.compactMap(\.takenAt)
                return (item.id, times.min() ?? item.eatenAt, times.max() ?? item.eatenAt)
            }
        var decisions: [Decision] = []
        for group in groups where !group.isEmpty {
            let times = group.compactMap(\.takenAt)
            guard let first = times.min(), let last = times.max() else {
                decisions.append(.new(group))
                continue
            }
            let nearest = spans.indices
                .map { index in (index, distance(first, last, spans[index].first, spans[index].last)) }
                .filter { $0.1 <= gap }
                .min { $0.1 < $1.1 }
            if let (index, _) = nearest {
                spans[index].first = min(spans[index].first, first)
                spans[index].last = max(spans[index].last, last)
                decisions.append(.join(spans[index].id, group))
            } else {
                decisions.append(.new(group))
            }
        }
        return decisions
    }

    /// How far apart two stretches of time are; 0 when they overlap.
    private static func distance(_ aFirst: Date, _ aLast: Date, _ bFirst: Date, _ bLast: Date) -> TimeInterval {
        if aLast < bFirst { return bFirst.timeIntervalSince(aLast) }
        if bLast < aFirst { return aFirst.timeIntervalSince(bLast) }
        return 0
    }
}

// MARK: - How it's going, for every device

/// Photos access on a device, as the settings say it.
enum MealPhotoAccess: String, Codable, Sendable {
    case full, limited, denied, notAsked

    init(from decoder: Decoder) throws {
        self = MealPhotoAccess(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .notAsked
    }
}

/// One device's scanning, shared through iCloud key-value storage (`MealPhotoScanReports`) so each
/// device's setting can say how it's going here and which others are looking.
struct MealPhotoScanReport: Codable, Equatable, Sendable {
    var access: MealPhotoAccess?
    var checkedAt: Date?
    var found: Int?
    var remaining: Int?
    /// "iPhone", "iPad" or "Mac".
    var device: String?
    /// When a pass last got through everything in its window.
    var completedAt: Date?
    /// Looking at recent photos only, while a Mac does the rest (`MealPhotoScanShare`).
    var recentOnly: Bool?
    /// A Mac on mains power (false on battery, in Low Power Mode or hot): only then is it relied on.
    var onPower: Bool?
}

// MARK: - The same photo on every device

/// A photo in iCloud Photos has one cloud identifier on every device. The key made from it names
/// the photo everywhere, and Banana derives the photo's and the meal's ids from it — so when the
/// Mac and the iPhone both find the same lunch, they make the same meal, not two.
enum MealPhotoIdentity {
    /// A short, stable key for a cloud identifier.
    static func key(cloudIdentifier: String) -> String {
        hex(SHA256.hash(data: Data(cloudIdentifier.utf8))).prefix(32).lowercased()
    }

    /// The photo's id: the same on every device that finds it.
    static func photoID(key: String) -> UUID { uuid("photo:" + key) }

    /// The meal's id, from its earliest photo's key: nil when that photo has none (a library
    /// without cloud identifiers), for a random one.
    static func mealID(photos: [MealPhotoRef]) -> UUID? {
        let first = photos.min { ($0.takenAt ?? .distantFuture, $0.cloudKey ?? "") < ($1.takenAt ?? .distantFuture, $1.cloudKey ?? "") }
        return first?.cloudKey.map { uuid("meal:" + $0) }
    }

    private static func uuid(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Pace

/// How often a device looks, by what it's running on. The Mac on mains power looks every 15 minutes
/// and soon after new photos arrive; on battery only when photos arrive, and less eagerly; in Low
/// Power Mode or hot, not until that passes.
enum MealPhotoScanPace {
    enum Power: Equatable, Sendable { case mains, battery, lowPower, hot }

    /// Whether the regular 15-minute look runs.
    static func timerLooks(_ power: Power) -> Bool { power == .mains }

    /// How long after the last library change to look; nil: don't.
    static func afterChange(_ power: Power) -> TimeInterval? {
        switch power {
        case .mains: 20
        case .battery: 120
        case .lowPower, .hot: nil
        }
    }
}

// MARK: - Sharing the looking

/// The Mac is on power and has the compute: while it keeps up, the iPhone and iPad — on battery —
/// look only at recent photos, enough to ask about today's meals, and leave the rest to it. In the
/// background the iPhone doesn't look at all then: the Mac's finds reach it by push.
enum MealPhotoScanShare {
    /// A Mac on mains power checks every 15 minutes; one that hasn't checked in this long is asleep,
    /// unplugged or closed, and not relied on.
    static let heartbeat: TimeInterval = 45 * 60
    /// What a device on battery still looks at while a Mac keeps up.
    static let recent: TimeInterval = 36 * 3_600

    /// Whether some other device that's a Mac, with Photos access and on mains power, has checked in
    /// lately.
    static func macKeepingUp(_ reports: [String: MealPhotoScanReport], except installID: String,
                             now: Date = Date()) -> Bool {
        reports.contains { id, report in
            id != installID && report.device == "Mac" && report.access == .full && report.onPower != false
                && report.checkedAt.map { now.timeIntervalSince($0) <= heartbeat } == true
        }
    }

    /// Where this device's pass starts: its own window, or — on battery while a Mac keeps up — no
    /// earlier than the last day and a half.
    static func windowStart(own: Date, onBattery: Bool, macKeepingUp: Bool, now: Date = Date()) -> Date {
        guard onBattery, macKeepingUp else { return own }
        return max(own, now.addingTimeInterval(-recent))
    }
}

enum MealPhotoScanStatusText {
    /// The line under "Find meal photos automatically" about this device's own looking.
    static func line(enabled: Bool, report: MealPhotoScanReport?, isMac: Bool, checking: Bool = false,
                     now: Date = Date()) -> String? {
        guard enabled else { return nil }
        switch report?.access {
        case .denied?, .limited?:
            return isMac ? "Allow Banana in System Settings \u{203A} Privacy & Security \u{203A} Photos"
                         : "Allow full Photos access in Settings"
        case .notAsked?, nil:
            return "Waiting for access to your photos"
        case .full?:
            if checking { return "Checking your photos\u{2026}" }
            guard let checked = report?.checkedAt else { return "Not checked yet" }
            var parts = ["Checked \(ago(checked, now: now))"] + counts(report)
            if report?.recentOnly == true { parts.append("recent photos only \u{2014} your Mac does the rest") }
            return parts.joined(separator: " \u{00B7} ")
        }
    }

    /// The other devices looking: "Also looking: Mac, 5 min ago · iPhone, 2 h ago". Nil when none are.
    static func others(_ reports: [String: MealPhotoScanReport], except installID: String,
                       now: Date = Date()) -> String? {
        let looking = reports
            .filter { $0.key != installID && $0.value.access == .full && $0.value.checkedAt != nil }
            .map(\.value)
            .filter { now.timeIntervalSince($0.checkedAt!) < 7 * 86_400 }
            .sorted { $0.checkedAt! > $1.checkedAt! }
        guard !looking.isEmpty else { return nil }
        return "Also looking: " + looking
            .map { "\($0.device ?? "another device"), \(ago($0.checkedAt!, now: now))" }
            .joined(separator: " \u{00B7} ")
    }

    private static func counts(_ report: MealPhotoScanReport?) -> [String] {
        let found = report?.found ?? 0
        var parts = [found == 0 ? "no meals yet" : found == 1 ? "1 meal found" : "\(found) meals found"]
        if let remaining = report?.remaining, remaining > 0 {
            parts.append("\(remaining) more photo\(remaining == 1 ? "" : "s") to check")
        }
        return parts
    }

    /// "just now", "5 min ago", "3 h ago", "2 days ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

// MARK: - The question

enum MealPhotoNotificationText {
    /// "What did you eat at 12:40?" — with the day when it wasn't today: "yesterday at 19:05",
    /// "on Tuesday at 8:10", "on 21 Sep at 13:00".
    static func title(eatenAt: Date, now: Date = Date(), calendar: Calendar = .current,
                      locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        let clock = time.string(from: eatenAt)

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: eatenAt),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let day: String
        switch days {
        case ...0: day = ""
        case 1: day = "yesterday "
        case 2...6: day = "on \(formatted(eatenAt, template: "EEEE", calendar: calendar, locale: locale)) "
        default: day = "on \(formatted(eatenAt, template: "dMMM", calendar: calendar, locale: locale)) "
        }
        return "What did you eat \(day)at \(clock)?"
    }

    static func body(photoCount: Int) -> String {
        photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    }

    private static func formatted(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

enum MealPhotoNotificationPolicy {
    /// A meal older than this waits in the backlog without a notification: asking about last
    /// week's lunch (the first pass going back two weeks) is noise, not a reminder.
    static let freshness: TimeInterval = 2 * 86_400
    /// At most this many questions from one pass, newest first; the rest wait in the backlog.
    static let perPass = 4

    /// How long an item stays in the "already asked" list (longer than `freshness`, so an asked
    /// meal can't come round again).
    static let rememberAsked: TimeInterval = 3 * 86_400

    /// The meals to ask about now, wherever they were found — this iPhone's own pass or the Mac's,
    /// arriving by sync — leaving out any already asked about or already seen in the app.
    static func toAsk(_ items: [MealInboxItem], asked: Set<UUID>, now: Date = Date()) -> [MealInboxItem] {
        worthAsking(items.filter { !asked.contains($0.id) }, now: now)
    }

    static func worthAsking(_ items: [MealInboxItem], now: Date = Date()) -> [MealInboxItem] {
        Array(items
            .filter { $0.state == .awaitingNote && now.timeIntervalSince($0.eatenAt) <= freshness }
            .sorted { $0.eatenAt > $1.eatenAt }
            .prefix(perPass))
    }
}
