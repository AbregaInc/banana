import Foundation

/// Deterministic fixture: 5,200 conversations from a seeded generator. Id 0 is the newest; ids
/// grow toward older mail. New mail (the `prepend` scenario) takes negative ids, so an id is
/// stable for the life of the process no matter what is inserted above it.

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Conversation: Identifiable, Equatable, Sendable {
    let id: Int
    let sender: String
    let subject: String
    let snippet: String
    let date: String
    let unread: Bool
}

enum Fixture {
    static let count = 5_200
    static let seed: UInt64 = 0xBA_4A4A_2026

    private static let senders = [
        "Maria Okafor", "Daniel Reuter", "Priya Raman", "GitHub", "Linear", "Stripe", "Anna Lindqvist",
        "Tomasz Nowak", "Sofia Marchetti", "Calendly", "Figma", "Hannah Weiss", "Kenji Watanabe",
        "Lucas Ferreira", "Nadia Haddad", "Apple Developer", "Vercel", "Elena Petrova", "Omar Siddiqui",
        "Grace Liu", "Postmark", "Jonas Berg", "Amara Nwosu", "Sentry", "Noah Fischer", "Isabel Cruz",
    ]
    private static let subjects = [
        "Q3 numbers before Thursday", "Re: Invoice 4471", "Your build finished", "Lunch next week?",
        "Fwd: contract draft v3", "Security alert for your account", "Weekly digest", "Re: Re: schedule",
        "Photos from the weekend", "Action needed: renew certificate", "Meeting notes", "Quick question",
        "Receipt for your payment", "New sign-in from Safari", "Roadmap review", "Flight confirmation",
        "Re: release checklist", "Welcome aboard", "Your order has shipped", "Draft for review",
    ]
    private static let words = [
        "thanks", "attached", "please", "review", "tomorrow", "numbers", "looks", "good", "can", "you",
        "send", "the", "latest", "version", "before", "noon", "agenda", "updated", "we", "should",
        "meet", "again", "about", "pricing", "and", "timeline", "see", "below", "for", "details",
    ]
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Everything the generator produces for one id. Pure function of the id and the seed.
    static func make(id: Int) -> Conversation {
        var rng = SplitMix64(seed: seed ^ UInt64(bitPattern: Int64(id)) &* 0x2545_F491_4F6C_DD1D)
        let sender = senders[Int(rng.next() % UInt64(senders.count))]
        let subject = subjects[Int(rng.next() % UInt64(subjects.count))]
        var snippet = ""
        let n = 9 + Int(rng.next() % 8)
        for i in 0..<n {
            if i > 0 { snippet += " " }
            snippet += words[Int(rng.next() % UInt64(words.count))]
        }
        let unread = rng.next() % 3 == 0
        // Newest first: id 0 is "now", each later id is a bit older.
        let minutesAgo = max(0, id) * 41 + 3
        let date: String
        if id < 0 { date = "now" }
        else if minutesAgo < 24 * 60 {
            let h = (23 * 60 + 59 - minutesAgo % (24 * 60)) / 60, m = (minutesAgo * 7) % 60
            date = String(format: "%d:%02d", h, m)
        } else if minutesAgo < 7 * 24 * 60 { date = days[(minutesAgo / (24 * 60)) % 7] }
        else { date = "Sep \(1 + (minutesAgo / (24 * 60)) % 28)" }
        return Conversation(id: id, sender: sender, subject: subject, snippet: snippet, date: date, unread: unread)
    }

    static let all: [Conversation] = (0..<count).map { make(id: $0) }

    private static var fresh: [Int: Conversation] = [:]
    /// The conversation for any id the model hands out (fixture or new mail).
    static func conversation(_ id: Int) -> Conversation {
        if id >= 0 && id < count { return all[id] }
        if let c = fresh[id] { return c }
        let c = make(id: id)
        fresh[id] = c
        return c
    }
}
