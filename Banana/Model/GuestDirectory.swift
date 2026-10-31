import Foundation

/// Someone an event can be with: from your calendars (the people you meet), your contacts, or an
/// email typed in.
struct GuestPerson: Hashable, Sendable, Identifiable {
    /// Lowercased: Google treats addresses without case, and so does matching here.
    var email: String
    var name: String?
    /// Events with them on your calendars, in the weeks Banana has read (a few back, several ahead).
    var met = 0
    var lastMet: Date?
    var inContacts = false

    var id: String { email }
    var displayName: String { name ?? email }
    /// Someone you meet often: put first, and marked.
    var isFavorite: Bool { met >= GuestDirectory.favoriteMeetings }

    init(email: String, name: String? = nil, met: Int = 0, lastMet: Date? = nil, inContacts: Bool = false) {
        self.email = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
        self.met = met
        self.lastMet = lastMet
        self.inContacts = inContacts
    }
}

/// Who "Sam" is, when an event is typed "Lunch with Sam tomorrow at 1". Your favourites first:
/// iOS doesn't let apps see the Phone or Contacts favourites, so they're the people you meet most —
/// and, above everyone, the Sam you picked the last times you typed "Sam" (`GuestPicks`). Pure.
enum GuestDirectory {
    /// Meeting someone this many times in the weeks read makes them a favourite.
    static let favoriteMeetings = 3

    // MARK: - Who there is

    /// One person per address: what the calendars know (how often you meet) and what your
    /// contacts know (their name), together.
    static func merged(calendar: [GuestPerson], contacts: [GuestPerson]) -> [GuestPerson] {
        var byEmail: [String: GuestPerson] = [:]
        for person in calendar { byEmail[person.email] = person }
        for contact in contacts {
            if var known = byEmail[contact.email] {
                known.name = contact.name ?? known.name
                known.inContacts = true
                byEmail[contact.email] = known
            } else {
                byEmail[contact.email] = contact
            }
        }
        return Array(byEmail.values)
    }

    /// Every other guest on these events, by address, counted — rooms, groups and your own
    /// addresses left out.
    static func fromEvents(_ events: [(attendees: [(email: String, name: String?, isSelf: Bool)], start: Date?)],
                           own: Set<String>) -> [GuestPerson] {
        var people: [String: GuestPerson] = [:]
        let own = Set(own.map { $0.lowercased() })
        for event in events {
            for attendee in event.attendees {
                let email = attendee.email.lowercased()
                guard !attendee.isSelf, !own.contains(email), isPerson(email) else { continue }
                var person = people[email] ?? GuestPerson(email: email)
                person.met += 1
                if person.name == nil, let name = attendee.name { person.name = name }
                if let start = event.start, person.lastMet.map({ start > $0 }) ?? true { person.lastMet = start }
                people[email] = person
            }
        }
        return Array(people.values)
    }

    /// An address that's a person, not a room, a calendar group or a robot.
    static func isPerson(_ email: String) -> Bool {
        let email = email.lowercased()
        guard email.contains("@") else { return false }
        let robots = ["resource.calendar.google.com", "group.calendar.google.com", "group.v.calendar.google.com",
                      "noreply", "no-reply", "calendar-notification", "calendly.com"]
        return !robots.contains { email.contains($0) }
    }

    // MARK: - Who's meant

    /// How well a person's name answers what was typed: 3 their name or first name exactly, 2 every
    /// typed word starting one of their names, 1 their address containing it; 0 not at all.
    static func quality(_ query: String, _ person: GuestPerson) -> Int {
        let typed = words(query)
        guard !typed.isEmpty else { return 0 }
        if query.contains("@") { return person.email == query.lowercased() ? 3 : 0 }
        let names = person.name.map(words) ?? []
        if !names.isEmpty {
            if typed == names || (typed.count == 1 && typed[0] == names[0]) { return 3 }
            if typed.allSatisfy({ word in names.contains { $0.hasPrefix(word) } }) { return 2 }
        }
        let local = String(person.email.split(separator: "@").first ?? "")
        // No name to go on: the address's own words ("sam.lee@…").
        let fromAddress = words(local.replacingOccurrences(of: #"[._\-+0-9]"#, with: " ", options: .regularExpression))
        if names.isEmpty, typed.allSatisfy({ word in fromAddress.contains { $0.hasPrefix(word) } }) { return 2 }
        let squashed = typed.joined()
        return squashed.count >= 3 && local.contains(squashed) ? 1 : 0
    }

    /// Everyone who answers to `query`, best first: the one picked before for these words, then
    /// how well the name fits, then the people you meet most and most lately, then contacts.
    static func matches(_ query: String, in people: [GuestPerson], picks: [String: Int] = [:]) -> [GuestPerson] {
        let scored = people.compactMap { person -> (GuestPerson, Int)? in
            let fit = quality(query, person)
            return fit > 0 ? (person, fit) : nil
        }
        return scored.sorted { a, b in
            let pickedA = picks[a.0.email] ?? 0, pickedB = picks[b.0.email] ?? 0
            if pickedA != pickedB { return pickedA > pickedB }
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.met != b.0.met { return a.0.met > b.0.met }
            if a.0.lastMet != b.0.lastMet { return (a.0.lastMet ?? .distantPast) > (b.0.lastMet ?? .distantPast) }
            if a.0.inContacts != b.0.inContacts { return a.0.inContacts }
            return a.0.displayName < b.0.displayName
        }.map(\.0)
    }

    /// The one person meant, when it's clear: the one picked before for these words; else the only
    /// good fit; else a favourite you meet at least twice as often as the next. Nil when it isn't
    /// clear — then the form asks "Which Sam?".
    static func best(_ query: String, in people: [GuestPerson], picks: [String: Int] = [:]) -> GuestPerson? {
        if query.contains("@"), isPerson(query) {
            return people.first { $0.email == query.lowercased() } ?? GuestPerson(email: query)
        }
        let ranked = matches(query, in: people, picks: picks)
        guard let top = ranked.first else { return nil }
        if (picks[top.email] ?? 0) > 0 { return top }
        let fit = quality(query, top)
        let rivals = ranked.dropFirst().filter { quality(query, $0) == fit }
        guard let next = rivals.first else { return top }
        return top.isFavorite && top.met >= 2 * next.met ? top : nil
    }

    // MARK: - Names in the words

    /// "Lunch with Sam tomorrow at 1" → ["Sam"]; "dinner w/ Jess and Ana Lee on Friday" →
    /// ["Jess", "Ana Lee"]. What follows "with", up to the when or the where.
    static func names(in text: String) -> [String] {
        guard let range = text.range(of: #"\b(?:with|w/)\s+"#, options: [.regularExpression, .caseInsensitive]) else { return [] }
        var rest = String(text[range.upperBound...])
        let stops = #"(?i)\s*(?:\b(?:at|on|tomorrow|today|tonight|next|this|for|every|each|from|in|by|to|about|re|until|till|before|after|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|noon|midnight|morning|afternoon|evening)\b|@|\d|[.;:!?()]).*$"#
        rest = rest.replacingOccurrences(of: stops, with: "", options: .regularExpression)
        let pieces = rest.replacingOccurrences(of: #"\s+(?:and|&|\+)\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let notPeople: Set<String> = ["the", "my", "a", "an", "our", "your", "his", "her", "their", "everyone", "team", "me", "us"]
        return pieces.filter { piece in
            let pieceWords = words(piece)
            return (1...3).contains(pieceWords.count) && !notPeople.contains(pieceWords[0])
        }
    }

    /// Addresses typed out in full.
    static func emails(in text: String) -> [String] {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }

    /// The same words however they're written: what a pick is remembered under.
    static func key(_ text: String) -> String { words(text).joined(separator: " ") }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }
}
