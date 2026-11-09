import XCTest
import GRDB

/// The composer's suggestions from the live index (`MailCorrespondents`, `MailLiveSource.people`):
/// counted once per message as its headers arrive, his own addresses never offered, people he
/// writes to before people who only wrote to him, a keystroke well under ten milliseconds.
final class MailCorrespondentsTests: XCTestCase {
    private let me = "noor@plan.example"

    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-people-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }

    private func message(_ id: String, from: String, to: String, cc: String? = nil, date: Int64) -> GmailMessage {
        var headers = [GmailHeader(name: "From", value: from), GmailHeader(name: "To", value: to),
                       GmailHeader(name: "Subject", value: "Subject \(id)"), GmailHeader(name: "Date", value: "Mon, 5 Oct 2026 09:12:00 +0000"),
                       GmailHeader(name: "Message-ID", value: "<\(id)@plan.example>")]
        if let cc { headers.append(GmailHeader(name: "Cc", value: cc)) }
        return GmailMessage(id: id, threadId: "t-\(id)", labelIds: ["INBOX"], historyId: 1, internalDate: date,
                            payload: GmailPart(headers: headers))
    }

    private func importing(_ messages: [GmailMessage], into stores: MailStores) async throws {
        let me = self.me
        _ = try await MailWriter(stores: stores, sink: nil).transact { db in
            var change = MailStoreChange()
            for wire in messages {
                change.formUnion(try MailMessageImporter.apply(FetchedMessage(wire: wire, floor: 1, headers: MessageHeaders(payload: wire.payload),
                    structure: nil), account: me, myAddresses: [me], in: db))
            }
            return change
        }
    }

    private func search(_ text: String, _ stores: MailStores, now: Date = Date(timeIntervalSince1970: 1_794_042_000)) async throws -> [MailPerson] {
        let me = self.me
        return try await stores.index.read { try MailCorrespondents.search(text, limit: 8, mine: [me], now: now, in: $0) }
    }

    func testPeopleHeWritesToComeFirstAndHisOwnAddressNever() async throws {
        let stores = try await stores()
        let day: Int64 = 86_400_000, now: Int64 = 1_794_042_000_000
        try await importing([
            message("a", from: "Jane Park <jane@parkdesign.example>", to: "Noor Haddad <\(me)>", cc: "Janet Ruiz <janet@ruiz.example>", date: now - day),
            message("b", from: "Noor Haddad <\(me)>", to: "Jane Park <jane@parkdesign.example>", date: now - 2 * day),
            message("c", from: "Jan Okafor <jan@okafor.example>", to: "Noor Haddad <\(me)>", date: now - day),
        ], into: stores)
        let found = try await search("ja", stores)
        XCTAssertEqual(found.first?.address, "jane@parkdesign.example", "he has written to Jane: she is first")
        XCTAssertEqual(found.first?.name, "Jane Park")
        XCTAssertTrue(found.first?.isKnown == true)
        XCTAssertEqual(Set(found.dropFirst().map(\.address)), ["jan@okafor.example", "janet@ruiz.example"])
        XCTAssertTrue(found.dropFirst().allSatisfy { $0.fromTheirMail && !$0.isKnown }, "only had mail from them: offered by address, last")
        let mine = try await search("noor", stores)
        XCTAssertTrue(mine.isEmpty, "his own address is never offered")
    }

    func testFoundByAnyWordTheAddressAndTheDomain() async throws {
        let stores = try await stores()
        try await importing([message("b", from: "Noor Haddad <\(me)>", to: "Jane Park <jane@parkdesign.example>", date: 1_794_000_000_000)], into: stores)
        for typed in ["Park", "jane@", "parkdes", "JANE PA"] {
            let found = try await search(typed, stores)
            XCTAssertEqual(found.map(\.address), ["jane@parkdesign.example"], typed)
        }
        let nobody = try await search("zz", stores)
        XCTAssertTrue(nobody.isEmpty)
    }

    func testAMessageReadAgainIsCountedOnce() async throws {
        let stores = try await stores()
        let sent = message("b", from: "Noor Haddad <\(me)>", to: "Jane Park <jane@parkdesign.example>", date: 1_794_000_000_000)
        try await importing([sent], into: stores)
        try await importing([sent], into: stores)
        let count = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT sent FROM correspondent WHERE addr='jane@parkdesign.example'") }
        XCTAssertEqual(count, 1)
    }

    func testMoreAndMoreRecentMailRanksHigher() async throws {
        let stores = try await stores()
        let now: Int64 = 1_794_042_000_000, day: Int64 = 86_400_000
        var messages: [GmailMessage] = []
        for n in 0..<5 { messages.append(message("s\(n)", from: "Noor Haddad <\(me)>", to: "Sam Lee <sam@lee.example>", date: now - Int64(n) * day)) }
        messages.append(message("o", from: "Noor Haddad <\(me)>", to: "Sam Ortiz <sam@ortiz.example>", date: now - 200 * day))
        try await importing(messages, into: stores)
        let found = try await search("sam", stores)
        XCTAssertEqual(found.map(\.address), ["sam@lee.example", "sam@ortiz.example"])
    }

    func testAKeystrokeOverManyPeopleIsUnderTenMilliseconds() async throws {
        let budget = CostBudget(self)
        let stores = try await stores()
        try await stores.index.write { db in
            for n in 0..<20_000 {
                try MailCorrespondents.record(sender: nil, recipients: [.init(address: "person\(n)@example\(n % 50).example", name: "Person \(n) Name")],
                                              fromMe: true, date: Int64(n), mine: [], in: db)
            }
        }
        // The first keystroke opens the reader and prepares the statement; the ones after it are
        // what a person waits on while typing. Timed twice: the search in the database (the work a
        // keystroke adds), and the whole call, which also waits its turn on the index's reader.
        _ = try await search("q", stores)
        let typed = ["p", "pe", "person1", "name", "example7"]
        let me = self.me
        let inDatabase = try await stores.index.read { db -> Double in
            var worst: Double = 0
            for text in typed {
                let start = ContinuousClock.now
                _ = try MailCorrespondents.search(text, limit: 8, mine: [me], in: db)
                let elapsed = start.duration(to: .now).components
                worst = max(worst, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            return worst
        }
        var roundTrip: Double = 0
        for text in typed {
            let start = ContinuousClock.now
            _ = try await search(text, stores)
            let elapsed = start.duration(to: .now).components
            roundTrip = max(roundTrip, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("MAIL_PEOPLE_SEARCH_WORST_MS", "database", inDatabase, "call", roundTrip)
        budget.expect(inDatabase, below: 10, "a keystroke's suggestions in under ten milliseconds")
        try budget.finish()
    }
}
