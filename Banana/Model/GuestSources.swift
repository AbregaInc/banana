import Contacts
import Foundation

/// Where the people an event can be with come from (`GuestDirectory`): your calendars — every
/// guest on the events Banana has read, counted, which is what makes someone a favourite — and
/// your contacts, for names, once you've allowed it.
@MainActor
enum GuestSources {
    /// Everyone, merged. Contacts only when access was already given: asking happens where it
    /// makes sense (`requestContactsIfNeeded`), not on opening a form.
    static func people() async -> [GuestPerson] {
        #if DEBUG
        if let fixture { return fixture }
        #endif
        async let calendar = calendarPeople()
        async let contacts = contactsAllowed ? contactPeople() : []
        return GuestDirectory.merged(calendar: await calendar, contacts: await contacts)
    }

    #if DEBUG
    /// `--guest-fixtures`: people to match without calendars or contacts — two Sams, one of them
    /// met often.
    static var fixture: [GuestPerson]? {
        guard ProcessInfo.processInfo.arguments.contains("--guest-fixtures") else { return nil }
        return [
            GuestPerson(email: "sam.lee@example.com", name: "Sam Lee", met: 6, lastMet: Date(), inContacts: true),
            GuestPerson(email: "sam.ortiz@example.com", name: "Sam Ortiz", met: 1, inContacts: true),
            GuestPerson(email: "jess.park@example.com", name: "Jess Park", met: 2),
            GuestPerson(email: "ana.lee@example.com", name: "Ana Lee", inContacts: true),
        ]
    }
    #endif

    // MARK: Calendars

    /// The guests on every calendar's saved read, off the main actor.
    static func calendarPeople() async -> [GuestPerson] {
        let google = GoogleCalendarService.shared
        let calendarIDs = google.calendars.map(\.id)
        let own = Set(google.accounts.map(\.email))
        return await Task.detached(priority: .utility) {
            var events: [(attendees: [(email: String, name: String?, isSelf: Bool)], start: Date?)] = []
            var seen = Set<String>()
            for id in calendarIDs {
                guard let snapshot = GoogleEventDiskCache.load(calendarID: id) else { continue }
                for event in snapshot.events where event.status != "cancelled" {
                    // The same meeting on two of your calendars is one meeting.
                    let key = event.iCalUID ?? event.id ?? UUID().uuidString
                    let when = event.start?.dateTime ?? event.start?.date ?? ""
                    guard seen.insert(key + when).inserted else { continue }
                    let attendees = (event.attendees ?? []).compactMap { a -> (email: String, name: String?, isSelf: Bool)? in
                        guard let email = a.email else { return nil }
                        return (email, a.displayName, a.selfAttendee == true)
                    }
                    guard !attendees.isEmpty else { continue }
                    let start = (event.start?.dateTime).flatMap { ISO8601DateFormatter().date(from: $0) }
                    events.append((attendees, start))
                }
            }
            return GuestDirectory.fromEvents(events, own: own)
        }.value
    }

    // MARK: Contacts

    static var contactsAllowed: Bool {
        #if DEBUG
        if fixture != nil { return true }
        #endif
        let status = CNContactStore.authorizationStatus(for: .contacts)
        #if os(iOS)
        if #available(iOS 18, *), status == .limited { return true }
        #endif
        return status == .authorized
    }

    /// Asks for contacts the first time names have to be matched; true when they can be read.
    static func requestContactsIfNeeded() async -> Bool {
        if contactsAllowed { return true }
        #if DEBUG
        if fixture != nil { return true }
        #endif
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return false }
        return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Every contact with an address, one person per address.
    static func contactPeople() async -> [GuestPerson] {
        await Task.detached(priority: .utility) {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                        CNContactEmailAddressesKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
            var people: [GuestPerson] = []
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: request) { contact, _ in
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let name = full.isEmpty ? (contact.nickname.isEmpty ? contact.organizationName : contact.nickname) : full
                for address in contact.emailAddresses {
                    let email = String(address.value)
                    guard GuestDirectory.isPerson(email) else { continue }
                    people.append(GuestPerson(email: email, name: name.isEmpty ? nil : name, inContacts: true))
                }
            }
            return people
        }.value
    }
}

/// Who you meant by a name before — "Sam" was sam.lee@… — so the next "Sam" is them without
/// asking. In iCloud key-value storage, so a name learned on the phone works on the Mac.
@MainActor
enum GuestPicks {
    private static let key = "guestPicks.v1"
    private static var store: LegacyKVS { .shared }

    private static var all: [String: [String: Int]] {
        (store.dictionary(forKey: key) as? [String: [String: Int]])
            ?? (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]]) ?? [:]
    }

    /// Times each address was chosen for these words.
    static func picks(for name: String) -> [String: Int] { all[GuestDirectory.key(name)] ?? [:] }

    static func record(name: String, email: String) {
        let nameKey = GuestDirectory.key(name)
        guard !nameKey.isEmpty, !name.contains("@") else { return }
        var picks = all
        picks[nameKey, default: [:]][email.lowercased(), default: 0] += 1
        store.set(picks, forKey: key)
        UserDefaults.standard.set(picks, forKey: key)
        SyncReport.changed(syncType, [nameKey])
    }

    // MARK: - The data platform (docs/design/DATA-PLATFORM.md, `KeyValueAdapters`): one record
    // per name, a field per address

    static let syncType = "core.guestPick"

    static var syncEntries: [String: [String: Int]] { all }

    /// Other devices' picks (nil: forgotten there), kept the usual way.
    static func applySynced(_ changes: [String: [String: Int]?]) {
        var picks = all
        for (name, counts) in changes { picks[name] = counts }
        store.set(picks, forKey: key)
        UserDefaults.standard.set(picks, forKey: key)
    }
}
