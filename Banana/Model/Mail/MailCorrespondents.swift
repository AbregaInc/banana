#if !BANANA_PUBLIC
import Foundation
import GRDB

/// The people in his mail, for the composer's To, Cc and Bcc (MAIL-UX 6.3.3): who he writes to and
/// who writes to him, how often and how lately, kept in the index's `correspondent` tables as each
/// message's headers arrive (the first time only, so a message read again counts once).
///
/// A keystroke reads at most a few hundred rows by an indexed prefix of the name's words, the
/// address or its domain, off the main thread, and ranks them: people he has written to first,
/// then by how much and how lately they have been in his mail.
enum MailCorrespondents {
    struct Mailbox: Equatable, Sendable { var address: String; var name: String? }

    /// What a person's words and address are found by: each word of the name, the whole name, the
    /// address and its domain, lower-cased.
    static func keys(name: String?, address: String) -> Set<String> {
        let address = address.lowercased()
        var keys: Set<String> = [address]
        if let at = address.lastIndex(of: "@") { keys.insert(String(address[address.index(after: at)...])) }
        if let name = name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            keys.insert(name)
            for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where !word.isEmpty {
                keys.insert(String(word))
            }
        }
        return keys
    }

    /// One message's people, counted once, when its headers first arrive: the people he wrote to
    /// (sent), or its sender (received). The others on someone else's message are kept, uncounted,
    /// so they can be offered by address, last. His own addresses are never kept.
    static func record(sender: Mailbox?, recipients: [Mailbox], fromMe: Bool, date: Int64,
                       mine: Set<String>, in db: Database) throws {
        func keep(_ person: Mailbox, sent: Int, received: Int) throws {
            let address = person.address.lowercased()
            guard !address.isEmpty, !mine.contains(address) else { return }
            try db.execute(sql: """
                INSERT INTO correspondent(addr,name,sent,received,last_date) VALUES(?,?,?,?,?)
                ON CONFLICT(addr) DO UPDATE SET sent=sent+excluded.sent,received=received+excluded.received,
                  last_date=max(last_date,excluded.last_date),name=coalesce(excluded.name,correspondent.name)
                """, arguments: [address, person.name, sent, received, date])
            let stored = try String.fetchOne(db, sql: "SELECT name FROM correspondent WHERE addr=?", arguments: [address])
            for key in keys(name: stored ?? person.name, address: address) {
                try db.execute(sql: "INSERT OR IGNORE INTO correspondent_key(key,addr) VALUES(?,?)", arguments: [key, address])
            }
        }
        if fromMe {
            for person in recipients { try keep(person, sent: 1, received: 0) }
        } else {
            if let sender { try keep(sender, sent: 0, received: 1) }
            for person in recipients { try keep(person, sent: 0, received: 0) }
        }
    }

    /// The people whose words, address or domain begin with what is typed, best first.
    static func search(_ text: String, limit: Int, mine: Set<String>, now: Date = Date(), in db: Database) throws -> [MailPerson] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, limit > 0 else { return [] }
        // One indexed range of the keys, joined to the people it names; a person found by two of
        // their keys (a word and the address) is one candidate.
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT c.addr,c.name,c.sent,c.received,c.last_date FROM correspondent_key k
            CROSS JOIN correspondent c ON c.addr=k.addr WHERE k.key>=? AND k.key<? LIMIT 400
            """), arguments: [needle, needle + "\u{FFFF}"])
        var seen = Set<String>()
        let nowMS = now.timeIntervalSince1970 * 1000
        struct Candidate { var person: MailPerson; var score: Double }
        var candidates: [Candidate] = []
        for row in rows {
            let address: String = row[0]
            guard !mine.contains(address), seen.insert(address).inserted else { continue }
            let sent: Int = row[2], received: Int = row[3], last: Int64 = row[4]
            let name: String? = row[1]
            // Frequency, damped by how long ago: a month away halves it.
            let days = max(0, (nowMS - Double(last)) / 86_400_000)
            let score = Double(sent * 3 + received + 1) / (1 + days / 30)
            let known = sent > 0
            candidates.append(Candidate(person: MailPerson(name: known ? name : nil, address: address, isMe: false,
                                                           isKnown: known, fromTheirMail: !known), score: score))
        }
        candidates.sort {
            if $0.person.isKnown != $1.person.isKnown { return $0.person.isKnown }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.person.address < $1.person.address
        }
        return candidates.prefix(limit).map(\.person)
    }

    /// For a cache that had mail before these tables were kept: the same counts, from what the
    /// messages already hold. Names of people he wrote to arrive as they write back.
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-composer-correspondents") { db in
            let mine = Set(try String.fetchAll(db, sql: "SELECT email FROM account"))
            let rows = try Row.fetchAll(db, sql: """
                SELECT from_addr,from_name,flags,recipients,internal_date FROM message
                WHERE fetch_state>0 AND vis IN (0,4)
                """)
            let decoder = JSONDecoder()
            for row in rows {
                let flags = MailMessageFlags(rawValue: row[2])
                let json: String? = row[3]
                let recipients = json.flatMap { try? decoder.decode(MailMessageImporter.Recipients.self, from: Data($0.utf8)) }
                let people = ((recipients?.to ?? []) + (recipients?.cc ?? [])).map { Mailbox(address: $0, name: nil) }
                let sender: String? = row[0]
                try record(sender: sender.map { Mailbox(address: $0, name: row[1]) }, recipients: people,
                           fromMe: flags.contains(.fromMe), date: row[4], mine: mine, in: db)
            }
        }
    }
}

#endif
